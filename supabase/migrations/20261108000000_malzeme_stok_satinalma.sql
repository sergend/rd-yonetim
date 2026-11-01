-- =============================================================================
-- RD Yönetim · Aşama 7 · Malzeme, stok ve satın alma
-- =============================================================================
-- Kapsam: malzeme kataloğu (kategori, birim, açık dönüşüm oranları), proje ve
-- genel depolar, stok hareketleri (giriş, kullanım, transfer, iade, sayım,
-- ters kayıt), satın alma siparişi ve parça parça teslim alma.
--
-- Temel kurallar
--   * Stok miktarı hiçbir tabloda elle tutulmaz: stock_entries (değiştirilemez
--     defter) satırlarının toplamıdır (v_stock_balances).
--   * Negatif stok oluşamaz. Çıkış yapan her defter satırı, (depo, malzeme)
--     anahtarında işlem sonuna kadar süren bir kilit alıp toplamı yeniden
--     okur: eşzamanlı iki çıkış sırayla değerlendirilir.
--   * Onaylı hareket silinmez, değişmez; iptal ters kayıtla yapılır.
--   * Kimlikler istemcide üretilir: aynı kimlik + aynı içerik aynı kaydı döner,
--     farklı içerik veya başkasının kimliği 23505 alır.
--   * DEMO depo ile gerçek depo, DEMO cari ile gerçek depo aynı harekette veya
--     siparişte kullanılamaz.
--
-- Finans ile ilişki (kritik)
--   * Bu migration hiçbir finans tablosuna (finance_documents,
--     finance_settlements, cari_entries, cari_allocations, finance_payments,
--     hakedis...) yazmaz ve onlara trigger eklemez.
--   * Satın alma siparişi borç, gider veya ödeme oluşturmaz. Gerçek borç
--     Aşama 5 gider onayından doğar. Gelen fatura (gider kaydı) siparişe
--     purchase_order_expense_links ile bağlanır; bağlantı yalnızca bilgidir ve
--     bir gider en fazla bir siparişe bağlanır.
--   * Stok hareketlerinde tutar yoktur: kullanım, transfer ve iade maliyet
--     oluşturmaz; stok değerlemesi (FIFO, ortalama maliyet, kur farkı) yoktur.
--
-- Önceki migration'lar değiştirilmez.
-- =============================================================================

create type public.warehouse_kind         as enum ('proje', 'genel');
create type public.stock_movement_kind    as enum ('giris', 'kullanim', 'transfer', 'iade_depo', 'iade_tedarikci',
                                                   'sayim', 'ters_kayit');
create type public.stock_movement_status  as enum ('bekliyor', 'onaylandi', 'reddedildi');
create type public.purchase_order_status  as enum ('taslak', 'onaylandi', 'kismi_teslim', 'tamamlandi', 'iptal');

-- -----------------------------------------------------------------------------
-- 1. Katalog: birimler, kategoriler, malzemeler, dönüşüm oranları
-- Başlangıç kayıtları yalnızca ilk kurulum verisidir; uygulamadan düzenlenir.
-- -----------------------------------------------------------------------------
create table public.material_units (
  id         uuid primary key default gen_random_uuid(),
  code       text not null check (length(trim(code)) between 1 and 12),
  name       text not null check (length(trim(name)) between 1 and 60),
  symbol     text not null check (length(trim(symbol)) between 1 and 12),
  -- İzin verilen ondalık hane (adet ve torba 0, kg ve m³ 3).
  decimals   smallint not null default 0 check (decimals between 0 and 3),
  sort_order integer not null default 100,
  is_active  boolean not null default true
);
create unique index material_units_code_uq on public.material_units (lower(code));
select private.add_row_meta('public.material_units');
select audit.enable('public.material_units');

insert into public.material_units (code, name, symbol, decimals, sort_order) values
  ('adet',  'Adet',      'adet',  0, 10),
  ('kg',    'Kilogram',  'kg',    3, 20),
  ('ton',   'Ton',       'ton',   3, 30),
  ('m',     'Metre',     'm',     2, 40),
  ('m2',    'Metrekare', 'm²',    2, 50),
  ('m3',    'Metreküp',  'm³',    3, 60),
  ('torba', 'Torba',     'torba', 0, 70),
  ('lt',    'Litre',     'lt',    2, 80),
  ('paket', 'Paket',     'paket', 0, 90);

create table public.material_categories (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(trim(name)) between 1 and 80),
  sort_order integer not null default 100,
  is_active  boolean not null default true
);
create unique index material_categories_name_uq on public.material_categories (lower(name));
select private.add_row_meta('public.material_categories');
select audit.enable('public.material_categories');

insert into public.material_categories (name, sort_order) values
  ('Kalıp ve iskele', 10), ('Demir', 20), ('Beton', 30), ('Kereste', 40), ('Bağlayıcı', 50),
  ('İnşaat kimyasalları', 60), ('Sarf malzemesi', 70), ('Diğer', 900);

create sequence public.material_code_seq;

create table public.materials (
  id           uuid primary key default gen_random_uuid(),
  code         text not null default ('MLZ-' || lpad(nextval('public.material_code_seq')::text, 4, '0'))
                 check (length(trim(code)) between 1 and 30),
  name         text not null check (length(trim(name)) between 1 and 120),
  category_id  uuid not null references public.material_categories (id) on delete restrict,
  base_unit_id uuid not null references public.material_units (id) on delete restrict,
  description  text,
  is_active    boolean not null default true
);
create unique index materials_code_uq on public.materials (upper(code));
create index materials_name_idx on public.materials (lower(name));
create index materials_category_idx on public.materials (category_id);
select private.add_row_meta('public.materials');
select audit.enable('public.materials');

insert into public.materials (name, category_id, base_unit_id)
select x.name, c.id, u.id
  from (values ('Plywood',        'Kalıp ve iskele', 'adet'),
               ('Demir direk',    'Kalıp ve iskele', 'adet'),
               ('Tahta',          'Kereste',         'm3'),
               ('İnşaat demiri',  'Demir',           'kg'),
               ('Hazır beton',    'Beton',           'm3'),
               ('Çimento',        'Bağlayıcı',       'torba')) as x (name, category, unit)
  join public.material_categories c on c.name = x.category
  join public.material_units u on u.code = x.unit;

-- Açık dönüşüm oranı: 1 <birim> = factor <temel birim>. Otomatik tahmin yok;
-- yalnızca burada tanımlı oranlar kullanılır. Oran sonradan değişmez (pasif
-- edilip yenisi tanımlanır); kullanılan oran harekete ayrıca kopyalanır.
create table public.material_unit_conversions (
  id          uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.materials (id) on delete restrict,
  unit_id     uuid not null references public.material_units (id) on delete restrict,
  factor      numeric(18, 6) not null check (factor > 0),
  note        text,
  is_active   boolean not null default true
);
create unique index material_unit_conversions_active_uq on public.material_unit_conversions (material_id, unit_id)
  where is_active;
select private.add_row_meta('public.material_unit_conversions');
select audit.enable('public.material_unit_conversions');

-- -----------------------------------------------------------------------------
-- 2. Depolar: her projenin bir ana deposu otomatik açılır; şirketin ortak
-- malzemeleri için genel depolar (projesiz) tanımlanır.
-- -----------------------------------------------------------------------------
create table public.warehouses (
  id         uuid primary key default gen_random_uuid(),
  kind       public.warehouse_kind not null,
  project_id uuid references public.projects (id) on delete restrict,
  name       text not null check (length(trim(name)) between 1 and 100),
  is_default boolean not null default false,
  is_active  boolean not null default true,
  is_demo    boolean not null default false,
  notes      text,
  constraint warehouses_scope_ck check ((kind = 'proje') = (project_id is not null)),
  constraint warehouses_default_ck check (not is_default or kind = 'proje')
);
create unique index warehouses_default_uq on public.warehouses (project_id) where is_default;
create unique index warehouses_name_uq on public.warehouses (coalesce(project_id::text, 'genel'), lower(name));
select private.add_row_meta('public.warehouses');
select audit.enable('public.warehouses');

insert into public.warehouses (kind, project_id, name, is_default, is_demo)
select 'proje', p.id, 'Ana depo', true, p.is_demo from public.projects p;

create or replace function private.tg_project_default_warehouse()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.warehouses (kind, project_id, name, is_default, is_demo)
  values ('proje', new.id, 'Ana depo', true, new.is_demo);
  return null;
end;
$$;
create trigger zz_default_warehouse after insert on public.projects
  for each row execute function private.tg_project_default_warehouse();

-- -----------------------------------------------------------------------------
-- 3. Stok hareketleri ve stok defteri
-- -----------------------------------------------------------------------------
create sequence public.stock_movement_no_seq;

-- Hareket: kullanıcının kaydettiği işlem. warehouse_id işlemin deposudur
-- (giriş/iade_depo: alan; kullanım/iade_tedarikçi: veren; transfer: gönderen;
-- sayım: sayılan); target_warehouse_id yalnızca transferde alan depodur.
create table public.stock_movements (
  id                  uuid primary key,  -- istemcide üretilir
  movement_no         text not null unique,
  kind                public.stock_movement_kind not null,
  status              public.stock_movement_status not null,
  movement_date       date not null,
  material_id         uuid not null references public.materials (id) on delete restrict,
  warehouse_id        uuid not null references public.warehouses (id) on delete restrict,
  target_warehouse_id uuid references public.warehouses (id) on delete restrict,
  -- Girilen miktar ve birim; base_quantity temel birimdeki karşılığıdır.
  -- Sayımda quantity = sayılan miktar (temel birim, 0 olabilir).
  quantity            numeric(14, 3) not null check (quantity >= 0),
  unit_id             uuid not null references public.material_units (id) on delete restrict,
  unit_factor         numeric(18, 6) not null check (unit_factor > 0),
  base_quantity       numeric(14, 3) not null check (base_quantity >= 0),
  -- Sayımın onay anındaki farkı (sayılan − mevcut); diğer türlerde boş.
  adjustment          numeric(14, 3),
  description         text,
  reason              text,
  performed_by        text,  -- teslim alan / kullanan kişi (bilgi)
  document_id         uuid references public.documents (id) on delete restrict,
  purchase_order_id   uuid,  -- satın alma teslimi (FK aşağıda)
  purchase_receipt_id uuid,
  reversal_of_id      uuid unique references public.stock_movements (id) on delete restrict,
  reversed_by_id      uuid unique references public.stock_movements (id) on delete restrict,
  approved_at         timestamptz,
  approved_by         uuid,
  rejected_at         timestamptz,
  rejected_by         uuid,
  reject_reason       text,
  is_demo             boolean not null,
  constraint stock_movements_target_ck check (
    (kind = 'transfer') = (target_warehouse_id is not null) and target_warehouse_id is distinct from warehouse_id),
  constraint stock_movements_qty_ck check (kind = 'sayim' or (quantity > 0 and base_quantity > 0)),
  constraint stock_movements_reversal_ck check ((kind = 'ters_kayit') = (reversal_of_id is not null)),
  constraint stock_movements_approved_ck check ((status = 'onaylandi') = (approved_at is not null)),
  constraint stock_movements_adjustment_ck check (
    (kind = 'sayim' and status = 'onaylandi') = (adjustment is not null))
);
create index stock_movements_warehouse_idx on public.stock_movements (warehouse_id, movement_date desc);
create index stock_movements_target_idx on public.stock_movements (target_warehouse_id) where target_warehouse_id is not null;
create index stock_movements_material_idx on public.stock_movements (material_id);
create index stock_movements_pending_idx on public.stock_movements (warehouse_id) where status = 'bekliyor';
create index stock_movements_order_idx on public.stock_movements (purchase_order_id) where purchase_order_id is not null;
select private.add_row_meta('public.stock_movements');
select audit.enable('public.stock_movements');

-- Defter: onaylı hareketlerin depo bazında işaretli miktarları (temel birim).
-- Yalnızca eklenir; güncelleme ve silme trigger ile reddedilir.
create table public.stock_entries (
  id           uuid primary key default gen_random_uuid(),
  movement_id  uuid not null references public.stock_movements (id) on delete restrict,
  warehouse_id uuid not null references public.warehouses (id) on delete restrict,
  material_id  uuid not null references public.materials (id) on delete restrict,
  entry_date   date not null,
  quantity     numeric(14, 3) not null check (quantity <> 0),
  is_demo      boolean not null
);
create index stock_entries_balance_idx on public.stock_entries (warehouse_id, material_id);
create index stock_entries_movement_idx on public.stock_entries (movement_id);
select private.add_row_meta('public.stock_entries');
select audit.enable('public.stock_entries');

create or replace function private.tg_stock_entry_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Stok defteri değiştirilemez veya silinemez; ters kayıt kullanın'
    using errcode = 'insufficient_privilege';
end;
$$;
create trigger stock_entry_immutable before update or delete on public.stock_entries
  for each row execute function private.tg_stock_entry_immutable();

-- (Depo, malzeme) anahtarında işlem sonuna kadar süren kilit.
create or replace function private.lock_stock(p_warehouse uuid, p_material uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('stok:' || p_warehouse::text || ':' || p_material::text, 0));
$$;
revoke execute on function private.lock_stock(uuid, uuid) from public, anon, authenticated;

create or replace function private.stock_balance(p_warehouse uuid, p_material uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(e.quantity), 0) from public.stock_entries e
   where e.warehouse_id = p_warehouse and e.material_id = p_material;
$$;
revoke execute on function private.stock_balance(uuid, uuid) from public, anon, authenticated;

-- Negatif stok engeli (son savunma hattı; RPC'ler aynı denetimi önceden
-- yapıp anlaşılır mesaj verir). Kilit alındıktan sonraki sorgu yeni anlık
-- görüntüyle çalışır: eşzamanlı işlemin işlenmiş çıkışını görür.
create or replace function private.tg_stock_entry_non_negative()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_balance numeric;
begin
  perform private.lock_stock(new.warehouse_id, new.material_id);
  v_balance := private.stock_balance(new.warehouse_id, new.material_id);
  if v_balance < 0 then
    raise exception 'Yetersiz stok: bu işlemden sonra miktar % olurdu', v_balance
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger stock_entry_non_negative after insert on public.stock_entries
  for each row when (new.quantity < 0) execute function private.tg_stock_entry_non_negative();

-- -----------------------------------------------------------------------------
-- 4. Satın alma
-- -----------------------------------------------------------------------------
create sequence public.purchase_order_no_seq;
create sequence public.purchase_receipt_no_seq;

create table public.purchase_orders (
  id              uuid primary key,  -- istemcide üretilir
  order_no        text not null unique,
  status          public.purchase_order_status not null default 'taslak',
  cari_account_id uuid not null references public.cari_accounts (id) on delete restrict,
  warehouse_id    uuid not null references public.warehouses (id) on delete restrict,
  project_id      uuid references public.projects (id) on delete restrict,  -- depodan türetilir
  order_date      date not null,
  expected_date   date,
  currency        char(3) not null default 'TRY' check (currency ~ '^[A-Z]{3}$'),
  description     text,
  notes           text,
  approved_at     timestamptz,
  approved_by     uuid,
  closed_at       timestamptz,
  closed_by       uuid,
  close_reason    text,
  cancelled_at    timestamptz,
  cancelled_by    uuid,
  cancel_reason   text,
  is_demo         boolean not null,
  constraint purchase_orders_expected_ck check (expected_date is null or expected_date >= order_date)
);
create index purchase_orders_project_idx on public.purchase_orders (project_id, order_date desc);
create index purchase_orders_cari_idx on public.purchase_orders (cari_account_id);
select private.add_row_meta('public.purchase_orders');
select audit.enable('public.purchase_orders');

create table public.purchase_order_lines (
  id            uuid primary key,  -- istemcide üretilir
  order_id      uuid not null references public.purchase_orders (id) on delete restrict,
  line_no       integer not null check (line_no > 0),
  material_id   uuid not null references public.materials (id) on delete restrict,
  quantity      numeric(14, 3) not null check (quantity > 0),
  unit_id       uuid not null references public.material_units (id) on delete restrict,
  unit_factor   numeric(18, 6) not null check (unit_factor > 0),
  base_quantity numeric(14, 3) not null check (base_quantity > 0),
  -- Fiyat yalnızca satinalma.read ile görünür (sütun yetkisi kapalı;
  -- purchase_order_prices() ile okunur). Bilgi amaçlıdır: borç doğurmaz.
  unit_price    numeric(14, 4) check (unit_price >= 0),
  line_total    numeric(14, 2) generated always as (round(quantity * unit_price, 2)) stored,
  note          text,
  deleted_at    timestamptz  -- taslaktan çıkarılan satır
);
create unique index purchase_order_lines_no_uq on public.purchase_order_lines (order_id, line_no) where deleted_at is null;
create index purchase_order_lines_material_idx on public.purchase_order_lines (material_id);
select private.add_row_meta('public.purchase_order_lines');
select audit.enable('public.purchase_order_lines');

create table public.purchase_receipts (
  id            uuid primary key,  -- istemcide üretilir: tekrar gönderim ikinci giriş açmaz
  receipt_no    text not null unique,
  order_id      uuid not null references public.purchase_orders (id) on delete restrict,
  warehouse_id  uuid not null references public.warehouses (id) on delete restrict,
  receipt_date  date not null,
  waybill_no    text,
  note          text,
  document_id   uuid references public.documents (id) on delete restrict,
  status        text not null default 'aktif' check (status in ('aktif', 'iptal')),
  cancelled_at  timestamptz,
  cancelled_by  uuid,
  cancel_reason text,
  is_demo       boolean not null
);
create index purchase_receipts_order_idx on public.purchase_receipts (order_id);
select private.add_row_meta('public.purchase_receipts');
select audit.enable('public.purchase_receipts');

create table public.purchase_receipt_lines (
  id                uuid primary key default gen_random_uuid(),
  receipt_id        uuid not null references public.purchase_receipts (id) on delete restrict,
  order_line_id     uuid not null references public.purchase_order_lines (id) on delete restrict,
  quantity          numeric(14, 3) not null check (quantity > 0),  -- sipariş satırı biriminde
  base_quantity     numeric(14, 3) not null check (base_quantity > 0),
  stock_movement_id uuid not null unique references public.stock_movements (id) on delete restrict,
  unique (receipt_id, order_line_id)
);
create index purchase_receipt_lines_line_idx on public.purchase_receipt_lines (order_line_id);
select private.add_row_meta('public.purchase_receipt_lines');
select audit.enable('public.purchase_receipt_lines');

alter table public.stock_movements
  add constraint stock_movements_order_fk foreign key (purchase_order_id)
    references public.purchase_orders (id) on delete restrict,
  add constraint stock_movements_receipt_fk foreign key (purchase_receipt_id)
    references public.purchase_receipts (id) on delete restrict;

-- Gider (fatura) bağlantısı: yalnızca bilgi; finans kaydına dokunmaz.
create table public.purchase_order_expense_links (
  id                  uuid primary key,
  order_id            uuid not null references public.purchase_orders (id) on delete restrict,
  finance_document_id uuid not null references public.finance_documents (id) on delete restrict,
  note                text,
  status              text not null default 'aktif' check (status in ('aktif', 'iptal')),
  cancelled_at        timestamptz,
  cancelled_by        uuid,
  cancel_reason       text
);
-- Bir gider en fazla bir siparişe bağlanır: aynı fatura iki siparişte sayılmaz.
create unique index purchase_order_expense_links_doc_uq on public.purchase_order_expense_links (finance_document_id)
  where status = 'aktif';
create index purchase_order_expense_links_order_idx on public.purchase_order_expense_links (order_id);
select private.add_row_meta('public.purchase_order_expense_links');
select audit.enable('public.purchase_order_expense_links');

-- Belge (Aşama 6 arşivi) bağlantısı: fatura, irsaliye vb. Belgenin kendi
-- erişim kuralları geçerlidir; bağlantı belgeyi görünür yapmaz.
create table public.purchase_order_documents (
  id            uuid primary key,
  order_id      uuid not null references public.purchase_orders (id) on delete restrict,
  document_id   uuid not null references public.documents (id) on delete restrict,
  status        text not null default 'aktif' check (status in ('aktif', 'iptal')),
  cancelled_at  timestamptz,
  cancelled_by  uuid,
  cancel_reason text
);
create unique index purchase_order_documents_uq on public.purchase_order_documents (order_id, document_id)
  where status = 'aktif';
select private.add_row_meta('public.purchase_order_documents');
select audit.enable('public.purchase_order_documents');

-- Değiştirilemez sipariş geçmişi.
create table public.purchase_order_events (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.purchase_orders (id) on delete restrict,
  action      text not null,
  from_status text,
  to_status   text,
  reason      text,
  data        jsonb,
  actor_id    uuid default auth.uid(),
  occurred_at timestamptz not null default clock_timestamp()
);
create index purchase_order_events_order_idx on public.purchase_order_events (order_id, occurred_at);
select private.add_row_meta('public.purchase_order_events');
select audit.enable('public.purchase_order_events');
create trigger purchase_order_event_immutable before update or delete on public.purchase_order_events
  for each row execute function private.tg_finance_event_immutable();

-- -----------------------------------------------------------------------------
-- 5. Değişmezlik (tablolar API'ye yazmaya kapalı; RPC hatalarına karşı ikinci hat)
-- -----------------------------------------------------------------------------
create or replace function private.tg_no_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Kayıt silinemez; pasifleştirin veya iptal edin' using errcode = 'insufficient_privilege';
end;
$$;
create trigger no_delete before delete on public.material_units for each row execute function private.tg_no_delete();
create trigger no_delete before delete on public.material_categories for each row execute function private.tg_no_delete();
create trigger no_delete before delete on public.materials for each row execute function private.tg_no_delete();
create trigger no_delete before delete on public.material_unit_conversions for each row execute function private.tg_no_delete();
create trigger no_delete before delete on public.warehouses for each row execute function private.tg_no_delete();
create trigger no_delete before delete on public.purchase_orders for each row execute function private.tg_no_delete();
create trigger no_delete before delete on public.purchase_order_lines for each row execute function private.tg_no_delete();
create trigger no_delete before delete on public.purchase_receipts for each row execute function private.tg_no_delete();
create trigger no_delete before delete on public.purchase_receipt_lines for each row execute function private.tg_no_delete();
create trigger no_delete before delete on public.purchase_order_expense_links for each row execute function private.tg_no_delete();
create trigger no_delete before delete on public.purchase_order_documents for each row execute function private.tg_no_delete();

-- Birimin ondalık hanesi, kullanılmaya başladıktan sonra değişmez.
create or replace function private.tg_material_unit_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.decimals is distinct from old.decimals
     and (exists (select 1 from public.materials m where m.base_unit_id = old.id)
          or exists (select 1 from public.stock_movements s where s.unit_id = old.id)
          or exists (select 1 from public.purchase_order_lines l where l.unit_id = old.id)) then
    raise exception 'Kullanılan birimin ondalık hanesi değiştirilemez' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger material_unit_guard before update on public.material_units
  for each row execute function private.tg_material_unit_guard();

-- Temel birim, hareket, sipariş satırı veya dönüşüm oranı varken değişmez.
create or replace function private.tg_material_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.base_unit_id is distinct from old.base_unit_id
     and (exists (select 1 from public.stock_movements s where s.material_id = old.id)
          or exists (select 1 from public.purchase_order_lines l where l.material_id = old.id)
          or exists (select 1 from public.material_unit_conversions c where c.material_id = old.id and c.is_active)) then
    raise exception 'Hareketi, siparişi veya dönüşüm oranı olan malzemenin temel birimi değiştirilemez'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger material_guard before update on public.materials
  for each row execute function private.tg_material_guard();

create or replace function private.tg_material_conversion_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.material_id is distinct from old.material_id or new.unit_id is distinct from old.unit_id
     or new.factor is distinct from old.factor then
    raise exception 'Dönüşüm oranı değiştirilemez; pasifleştirip yenisini tanımlayın' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger material_conversion_guard before update on public.material_unit_conversions
  for each row execute function private.tg_material_conversion_guard();

create or replace function private.tg_warehouse_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.kind is distinct from old.kind or new.project_id is distinct from old.project_id
     or new.is_demo is distinct from old.is_demo or new.is_default is distinct from old.is_default then
    raise exception 'Deponun türü, projesi ve DEMO işareti değiştirilemez' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger warehouse_guard before update on public.warehouses
  for each row execute function private.tg_warehouse_guard();

-- Hareket: içerik değişmez; yalnızca bekliyor → onaylandi / reddedildi geçişi
-- ve bir kez ters kayıt bağlantısı yazılır.
create or replace function private.tg_stock_movement_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Stok hareketi silinemez; ters kayıtla iptal edin' using errcode = 'insufficient_privilege';
  end if;
  if new.kind is distinct from old.kind or new.material_id is distinct from old.material_id
     or new.warehouse_id is distinct from old.warehouse_id or new.target_warehouse_id is distinct from old.target_warehouse_id
     or new.quantity is distinct from old.quantity or new.unit_id is distinct from old.unit_id
     or new.unit_factor is distinct from old.unit_factor or new.base_quantity is distinct from old.base_quantity
     or new.movement_date is distinct from old.movement_date or new.reversal_of_id is distinct from old.reversal_of_id
     or new.is_demo is distinct from old.is_demo or new.document_id is distinct from old.document_id
     or new.purchase_order_id is distinct from old.purchase_order_id
     or new.purchase_receipt_id is distinct from old.purchase_receipt_id
     or new.description is distinct from old.description or new.reason is distinct from old.reason
     or new.movement_no is distinct from old.movement_no then
    raise exception 'Stok hareketi değiştirilemez; ters kayıtla iptal edip yeniden girin' using errcode = 'check_violation';
  end if;
  if old.status <> 'bekliyor' and new.status is distinct from old.status then
    raise exception 'Sonuçlanmış hareketin durumu değiştirilemez' using errcode = 'check_violation';
  end if;
  if old.status <> 'bekliyor' and new.adjustment is distinct from old.adjustment then
    raise exception 'Sayım farkı değiştirilemez' using errcode = 'check_violation';
  end if;
  if old.reversed_by_id is not null and new.reversed_by_id is distinct from old.reversed_by_id then
    raise exception 'Ters kayıt bağlantısı değiştirilemez' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger stock_movement_guard before update or delete on public.stock_movements
  for each row execute function private.tg_stock_movement_guard();

create or replace function private.tg_purchase_order_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.is_demo is distinct from old.is_demo then
    raise exception 'DEMO işareti değiştirilemez' using errcode = 'check_violation';
  end if;
  if old.status <> 'taslak' and (
       new.cari_account_id is distinct from old.cari_account_id or new.warehouse_id is distinct from old.warehouse_id
       or new.project_id is distinct from old.project_id or new.order_date is distinct from old.order_date
       or new.currency is distinct from old.currency) then
    raise exception 'Onaylı sipariş değiştirilemez' using errcode = 'check_violation';
  end if;
  if old.status = 'iptal' and new.status <> 'iptal' then
    raise exception 'İptal edilmiş sipariş yeniden açılamaz' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger purchase_order_guard before update on public.purchase_orders
  for each row execute function private.tg_purchase_order_guard();

create or replace function private.tg_purchase_order_line_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.order_id is distinct from old.order_id then
    raise exception 'Sipariş satırı başka siparişe taşınamaz' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.purchase_orders o where o.id = old.order_id and o.status <> 'taslak') then
    raise exception 'Onaylı siparişin satırları değiştirilemez' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger purchase_order_line_guard before update on public.purchase_order_lines
  for each row execute function private.tg_purchase_order_line_guard();

create or replace function private.tg_purchase_receipt_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'purchase_receipt_lines' then
    raise exception 'Teslim satırı değiştirilemez; teslimi iptal edin' using errcode = 'check_violation';
  end if;
  if new.order_id is distinct from old.order_id or new.warehouse_id is distinct from old.warehouse_id
     or new.receipt_date is distinct from old.receipt_date or new.is_demo is distinct from old.is_demo
     or new.receipt_no is distinct from old.receipt_no or (old.status = 'iptal' and new.status <> 'iptal') then
    raise exception 'Teslim alma kaydı değiştirilemez; iptal edip yeniden girin' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger purchase_receipt_guard before update on public.purchase_receipts
  for each row execute function private.tg_purchase_receipt_guard();
create trigger purchase_receipt_line_guard before update on public.purchase_receipt_lines
  for each row execute function private.tg_purchase_receipt_guard();

-- Siparişten fazla teslim (son savunma hattı): sipariş satırı kilitlenir,
-- etkin teslimlerin toplamı sipariş miktarını aşamaz.
create or replace function private.tg_purchase_receipt_line_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ordered  numeric;
  v_received numeric;
begin
  select l.base_quantity into v_ordered from public.purchase_order_lines l where l.id = new.order_line_id for update;
  select coalesce(sum(rl.base_quantity), 0) into v_received
    from public.purchase_receipt_lines rl
    join public.purchase_receipts r on r.id = rl.receipt_id and r.status = 'aktif'
   where rl.order_line_id = new.order_line_id;
  if v_received > v_ordered then
    raise exception 'Teslim alınan miktar sipariş miktarını aşıyor' using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger purchase_receipt_line_limit after insert on public.purchase_receipt_lines
  for each row execute function private.tg_purchase_receipt_line_limit();

-- -----------------------------------------------------------------------------
-- 6. Yetki
--   stok.read        : depo stokları ve hareketleri (proje kapsamlı; genel depo genel izin)
--   stok.write       : hareket hazırlama (giriş, kullanım, transfer, iade, sayım)
--   stok.approve     : hareketi onaylama (stoka işler) veya reddetme
--   stok.cancel      : onaylı hareketi ters kayıtla iptal etme, teslimi geri alma
--   malzeme.manage   : katalog, birim, dönüşüm oranı ve depo tanımlama
--   satinalma.read   : siparişler, fiyatlar ve gider/belge bağlantıları
--   satinalma.write  : sipariş taslağı hazırlama, gider/belge bağlama
--   satinalma.approve: siparişi onaylama ve eksik teslimle kapatma
--   satinalma.receive: onaylı siparişin malzemesini teslim alma (fiyat görmez)
--   satinalma.cancel : onaylı siparişi iptal etme
-- -----------------------------------------------------------------------------
create or replace function private.can_warehouse(p_permission text, p_warehouse uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select private.has_permission(p_permission, w.project_id)
                     from public.warehouses w where w.id = p_warehouse), false);
$$;

create or replace function private.can_see_warehouse(p_warehouse uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.warehouses w
     where w.id = p_warehouse
       and (private.has_permission('stok.read', w.project_id) or private.has_permission('stok.write', w.project_id)
            or private.has_permission('satinalma.read', w.project_id)
            or private.has_permission('satinalma.write', w.project_id)
            or private.has_permission('satinalma.receive', w.project_id)));
$$;

-- Siparişi görebilir mi (fiyatlar ayrıca satinalma.read ister).
create or replace function private.can_see_purchase(p_project uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_permission('satinalma.read', p_project)
      or private.has_permission('satinalma.write', p_project)
      or private.has_permission('satinalma.receive', p_project);
$$;

grant execute on function private.can_warehouse(text, uuid) to authenticated;
grant execute on function private.can_see_warehouse(uuid) to authenticated;
grant execute on function private.can_see_purchase(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 7. RLS
-- -----------------------------------------------------------------------------
alter table public.material_units               enable row level security;
alter table public.material_categories          enable row level security;
alter table public.materials                    enable row level security;
alter table public.material_unit_conversions    enable row level security;
alter table public.warehouses                   enable row level security;
alter table public.stock_movements              enable row level security;
alter table public.stock_entries                enable row level security;
alter table public.purchase_orders              enable row level security;
alter table public.purchase_order_lines         enable row level security;
alter table public.purchase_receipts            enable row level security;
alter table public.purchase_receipt_lines       enable row level security;
alter table public.purchase_order_expense_links enable row level security;
alter table public.purchase_order_documents     enable row level security;
alter table public.purchase_order_events        enable row level security;

-- Katalog parasal bilgi içermez: oturum açmış her etkin kullanıcı görür.
create policy material_units_select on public.material_units
  for select to authenticated using (private.is_active_user());
create policy material_categories_select on public.material_categories
  for select to authenticated using (private.is_active_user());
create policy materials_select on public.materials
  for select to authenticated using (private.is_active_user());
create policy material_unit_conversions_select on public.material_unit_conversions
  for select to authenticated using (private.is_active_user());

create policy warehouses_select on public.warehouses
  for select to authenticated using (private.can_see_warehouse(id));

-- Hareket: deposunu (transferde iki depodan birini) görebilen.
create policy stock_movements_select on public.stock_movements
  for select to authenticated
  using (private.can_warehouse('stok.read', warehouse_id)
         or (target_warehouse_id is not null and private.can_warehouse('stok.read', target_warehouse_id)));
create policy stock_entries_select on public.stock_entries
  for select to authenticated using (private.can_warehouse('stok.read', warehouse_id));

create policy purchase_orders_select on public.purchase_orders
  for select to authenticated using (private.can_see_purchase(project_id));
create policy purchase_order_lines_select on public.purchase_order_lines
  for select to authenticated
  using (exists (select 1 from public.purchase_orders o where o.id = order_id));
create policy purchase_receipts_select on public.purchase_receipts
  for select to authenticated
  using (exists (select 1 from public.purchase_orders o where o.id = order_id));
create policy purchase_receipt_lines_select on public.purchase_receipt_lines
  for select to authenticated
  using (exists (select 1 from public.purchase_receipts r where r.id = receipt_id));
create policy purchase_order_expense_links_select on public.purchase_order_expense_links
  for select to authenticated
  using (exists (select 1 from public.purchase_orders o
                  where o.id = order_id and private.has_permission('satinalma.read', o.project_id)));
create policy purchase_order_documents_select on public.purchase_order_documents
  for select to authenticated
  using (exists (select 1 from public.purchase_orders o where o.id = order_id));
create policy purchase_order_events_select on public.purchase_order_events
  for select to authenticated
  using (exists (select 1 from public.purchase_orders o where o.id = order_id));

-- -----------------------------------------------------------------------------
-- 8. Görünümler (security_invoker: yalnızca kullanıcının görebildiği satırlar)
-- -----------------------------------------------------------------------------
-- Mevcut stok: defterin toplamı. Bakiye alanı yoktur.
create or replace view public.v_stock_balances
with (security_invoker = true)
as
select e.warehouse_id,
       e.material_id,
       sum(e.quantity)   as quantity,
       count(*)::integer as entry_count,
       max(e.entry_date) as last_entry_date,
       bool_or(e.is_demo) as is_demo
  from public.stock_entries e
 group by e.warehouse_id, e.material_id;

-- Onay bekleyen hareketlerin depo bazında etkisi (stoka işlenmemiştir).
create or replace view public.v_stock_pending
with (security_invoker = true)
as
select x.warehouse_id, x.material_id,
       sum(x.qty_out) as pending_out,
       sum(x.qty_in)  as pending_in,
       count(distinct x.movement_id)::integer as movement_count
  from (
    select m.id as movement_id, m.warehouse_id, m.material_id,
           case when m.kind in ('kullanim', 'iade_tedarikci', 'transfer') then m.base_quantity else 0 end as qty_out,
           case when m.kind in ('giris', 'iade_depo') then m.base_quantity else 0 end as qty_in
      from public.stock_movements m where m.status = 'bekliyor' and m.kind <> 'sayim'
    union all
    select m.id, m.target_warehouse_id, m.material_id, 0, m.base_quantity
      from public.stock_movements m where m.status = 'bekliyor' and m.kind = 'transfer'
  ) x
 group by x.warehouse_id, x.material_id;

-- Sipariş satırı teslim durumu (fiyatsız).
create or replace view public.v_purchase_order_line_status
with (security_invoker = true)
as
select l.id as order_line_id,
       l.order_id,
       l.line_no,
       l.material_id,
       l.unit_id,
       l.quantity,
       l.unit_factor,
       l.base_quantity,
       l.note,
       coalesce(r.received, 0)                   as received_base_quantity,
       l.base_quantity - coalesce(r.received, 0) as remaining_base_quantity
  from public.purchase_order_lines l
  left join lateral (
    select sum(rl.base_quantity) as received
      from public.purchase_receipt_lines rl
      join public.purchase_receipts pr on pr.id = rl.receipt_id and pr.status = 'aktif'
     where rl.order_line_id = l.id) r on true
 where l.deleted_at is null;

-- -----------------------------------------------------------------------------
-- 9. Yardımcılar
-- -----------------------------------------------------------------------------
-- Miktar, birimin ondalık hanesine uymalı.
create or replace function private.check_unit_quantity(p_quantity numeric, p_unit uuid, p_allow_zero boolean default false)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_unit public.material_units;
begin
  select * into v_unit from public.material_units where id = p_unit;
  if not found then
    raise exception 'Birim bulunamadı' using errcode = 'foreign_key_violation';
  end if;
  if p_quantity is null or p_quantity < 0 or (p_quantity = 0 and not p_allow_zero) then
    raise exception 'Miktar sıfırdan büyük olmalı' using errcode = 'check_violation';
  end if;
  if p_quantity <> round(p_quantity, v_unit.decimals) then
    raise exception '% biriminde en çok % ondalık hane girilebilir', v_unit.symbol, v_unit.decimals
      using errcode = 'check_violation';
  end if;
  if p_quantity > 99999999999 then
    raise exception 'Miktar çok büyük' using errcode = 'check_violation';
  end if;
end;
$$;
revoke execute on function private.check_unit_quantity(numeric, uuid, boolean) from public, anon, authenticated;

-- Girilen birimden temel birime oran: temel birimde 1, aksi halde yalnızca
-- tanımlı ve etkin dönüşüm oranı. Tahmin yapılmaz.
create or replace function private.material_unit_factor(p_material uuid, p_unit uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_base   uuid;
  v_factor numeric;
begin
  select m.base_unit_id into v_base from public.materials m where m.id = p_material;
  if p_unit is null or p_unit = v_base then
    return 1;
  end if;
  select c.factor into v_factor from public.material_unit_conversions c
   where c.material_id = p_material and c.unit_id = p_unit and c.is_active;
  if v_factor is null then
    raise exception 'Bu malzeme için seçilen birimin dönüşüm oranı tanımlı değil; temel birimle girin veya oran tanımlatın'
      using errcode = 'check_violation';
  end if;
  return v_factor;
end;
$$;
revoke execute on function private.material_unit_factor(uuid, uuid) from public, anon, authenticated;

-- Temel birim karşılığı; temel birimin ondalık hanesine tam uymalı.
create or replace function private.to_base_quantity(p_material uuid, p_quantity numeric, p_factor numeric)
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_decimals smallint;
  v_base     numeric := p_quantity * p_factor;
begin
  select u.decimals into v_decimals
    from public.materials m join public.material_units u on u.id = m.base_unit_id where m.id = p_material;
  if v_base <> round(v_base, v_decimals) then
    raise exception 'Dönüştürülen miktar (%) temel birimin ondalık hanesine uymuyor', v_base
      using errcode = 'check_violation';
  end if;
  return round(v_base, v_decimals);
end;
$$;
revoke execute on function private.to_base_quantity(uuid, numeric, numeric) from public, anon, authenticated;

create or replace function private.next_doc_no(p_prefix text, p_seq regclass)
returns text
language sql
security definer
set search_path = ''
as $$
  select p_prefix || lpad(nextval(p_seq)::text, 6, '0');
$$;
revoke execute on function private.next_doc_no(text, regclass) from public, anon, authenticated;

create or replace function private.purchase_event(p_order uuid, p_action text, p_from text, p_to text,
                                                  p_reason text default null, p_data jsonb default null)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.purchase_order_events (order_id, action, from_status, to_status, reason, data)
  values (p_order, p_action, p_from, p_to, nullif(trim(p_reason), ''), p_data);
$$;
revoke execute on function private.purchase_event(uuid, text, text, text, text, jsonb) from public, anon, authenticated;

-- Harekete/teslime eklenecek belge: görülebilir, yüklenmiş ve aynı kapsamda olmalı.
create or replace function private.check_stock_document(p_document uuid, p_project uuid, p_is_demo boolean)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d public.documents;
begin
  if p_document is null then
    return;
  end if;
  select * into d from public.documents where id = p_document;
  if not found or not private.can_read_document(d.status, d.created_by, d.link_type, d.kind, d.project_id,
                                                d.finance_document_id, d.contract_id) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if d.status not in ('yuklendi', 'arsivlendi') then
    raise exception 'Yalnızca yüklenmiş belge bağlanabilir' using errcode = 'check_violation';
  end if;
  if d.is_demo is distinct from p_is_demo then
    raise exception 'Deneme (DEMO) belgesi gerçek kayda, gerçek belge deneme kaydına bağlanamaz'
      using errcode = 'check_violation';
  end if;
  if d.project_id is distinct from p_project then
    raise exception 'Belge aynı projeye ait olmalı' using errcode = 'check_violation';
  end if;
end;
$$;
revoke execute on function private.check_stock_document(uuid, uuid, boolean) from public, anon, authenticated;

-- Hareketi stoka işler (onay). Çağıran yetkiyi denetler ve satırı kilitler.
create or replace function private.stock_post(p_id uuid)
returns public.stock_movements
language plpgsql
security definer
set search_path = ''
as $$
declare
  m         public.stock_movements;
  v_balance numeric;
  v_delta   numeric;
begin
  select * into m from public.stock_movements where id = p_id;
  if m.kind in ('kullanim', 'iade_tedarikci', 'transfer', 'sayim') then
    perform private.lock_stock(m.warehouse_id, m.material_id);
    v_balance := private.stock_balance(m.warehouse_id, m.material_id);
  end if;

  case m.kind
    when 'giris', 'iade_depo' then
      insert into public.stock_entries (movement_id, warehouse_id, material_id, entry_date, quantity, is_demo)
      values (m.id, m.warehouse_id, m.material_id, m.movement_date, m.base_quantity, m.is_demo);
    when 'kullanim', 'iade_tedarikci' then
      if m.base_quantity > v_balance then
        raise exception 'Yetersiz stok: depoda % var, % isteniyor', v_balance, m.base_quantity
          using errcode = 'check_violation';
      end if;
      insert into public.stock_entries (movement_id, warehouse_id, material_id, entry_date, quantity, is_demo)
      values (m.id, m.warehouse_id, m.material_id, m.movement_date, -m.base_quantity, m.is_demo);
    when 'transfer' then
      if m.base_quantity > v_balance then
        raise exception 'Yetersiz stok: gönderen depoda % var, % isteniyor', v_balance, m.base_quantity
          using errcode = 'check_violation';
      end if;
      insert into public.stock_entries (movement_id, warehouse_id, material_id, entry_date, quantity, is_demo)
      values (m.id, m.warehouse_id, m.material_id, m.movement_date, -m.base_quantity, m.is_demo),
             (m.id, m.target_warehouse_id, m.material_id, m.movement_date, m.base_quantity, m.is_demo);
    when 'sayim' then
      v_delta := m.base_quantity - v_balance;
      if v_delta = 0 then
        raise exception 'Sayılan miktar mevcut stokla aynı (%); düzeltme gerekmez', v_balance
          using errcode = 'check_violation';
      end if;
      insert into public.stock_entries (movement_id, warehouse_id, material_id, entry_date, quantity, is_demo)
      values (m.id, m.warehouse_id, m.material_id, m.movement_date, v_delta, m.is_demo);
    else
      raise exception 'Bu hareket türü onayla işlenmez' using errcode = 'check_violation';
  end case;

  update public.stock_movements
     set status = 'onaylandi', approved_at = now(), approved_by = auth.uid(), adjustment = v_delta
   where id = m.id
  returning * into m;
  return m;
end;
$$;
revoke execute on function private.stock_post(uuid) from public, anon, authenticated;

-- Ters kayıt: orijinal defter satırlarının tam tersi. Kilitler sıralı alınır.
create or replace function private.stock_reverse(p_id uuid, p_reversal_id uuid, p_reason text)
returns public.stock_movements
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.stock_movements;
  r public.stock_movements;
  k record;
begin
  select * into o from public.stock_movements where id = p_id for update;
  if exists (select 1 from public.stock_movements x where x.id = p_reversal_id) then
    raise exception 'Bu kimlikle başka bir hareket var' using errcode = 'unique_violation';
  end if;
  for k in select distinct e.warehouse_id, e.material_id from public.stock_entries e
            where e.movement_id = o.id and e.quantity > 0 order by 1, 2 loop
    perform private.lock_stock(k.warehouse_id, k.material_id);
  end loop;
  for k in select e.warehouse_id, e.quantity, private.stock_balance(e.warehouse_id, e.material_id) as balance
             from public.stock_entries e where e.movement_id = o.id and e.quantity > 0 loop
    if k.quantity > k.balance then
      raise exception 'Yetersiz stok: geri alınacak % miktarın bir kısmı kullanılmış veya aktarılmış (depoda %); önce o hareketleri geri alın',
        k.quantity, k.balance using errcode = 'check_violation';
    end if;
  end loop;

  insert into public.stock_movements (id, movement_no, kind, status, movement_date, material_id, warehouse_id,
                                      target_warehouse_id, quantity, unit_id, unit_factor, base_quantity, description,
                                      reason, purchase_order_id, purchase_receipt_id, reversal_of_id, approved_at,
                                      approved_by, is_demo)
  values (p_reversal_id, private.next_doc_no('SH-', 'public.stock_movement_no_seq'), 'ters_kayit', 'onaylandi',
          private.today(), o.material_id, o.warehouse_id, null,
          case when o.kind = 'sayim' then abs(o.adjustment) else o.quantity end, o.unit_id, o.unit_factor,
          case when o.kind = 'sayim' then abs(o.adjustment) else o.base_quantity end,
          'İptal: ' || o.movement_no, trim(p_reason), o.purchase_order_id, o.purchase_receipt_id, o.id, now(),
          auth.uid(), o.is_demo)
  returning * into r;

  insert into public.stock_entries (movement_id, warehouse_id, material_id, entry_date, quantity, is_demo)
  select r.id, e.warehouse_id, e.material_id, r.movement_date, -e.quantity, e.is_demo
    from public.stock_entries e where e.movement_id = o.id;

  update public.stock_movements set reversed_by_id = r.id where id = o.id;
  return r;
end;
$$;
revoke execute on function private.stock_reverse(uuid, uuid, text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 10. Katalog ve depo RPC'leri (malzeme.manage)
-- -----------------------------------------------------------------------------
create or replace function private.require_catalog_manager()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.has_permission('malzeme.manage', null) then
    raise exception 'Malzeme kataloğunu yönetme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
end;
$$;
revoke execute on function private.require_catalog_manager() from public, anon, authenticated;

create or replace function public.save_material_unit(
  p_id uuid, p_code text, p_name text, p_symbol text, p_decimals integer, p_sort_order integer default 100,
  p_is_active boolean default true)
returns public.material_units
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.material_units;
begin
  perform private.require_catalog_manager();
  if length(coalesce(trim(p_code), '')) = 0 or length(coalesce(trim(p_name), '')) = 0
     or length(coalesce(trim(p_symbol), '')) = 0 then
    raise exception 'Birim kodu, adı ve simgesi zorunlu' using errcode = 'check_violation';
  end if;
  if p_decimals is null or p_decimals not between 0 and 3 then
    raise exception 'Ondalık hane 0 ile 3 arasında olmalı' using errcode = 'check_violation';
  end if;
  insert into public.material_units (id, code, name, symbol, decimals, sort_order, is_active)
  values (coalesce(p_id, gen_random_uuid()), lower(trim(p_code)), trim(p_name), trim(p_symbol), p_decimals,
          coalesce(p_sort_order, 100), coalesce(p_is_active, true))
  on conflict (id) do update
    set code = excluded.code, name = excluded.name, symbol = excluded.symbol, decimals = excluded.decimals,
        sort_order = excluded.sort_order, is_active = excluded.is_active
  returning * into v;
  return v;
end;
$$;

create or replace function public.save_material_category(
  p_id uuid, p_name text, p_sort_order integer default 100, p_is_active boolean default true)
returns public.material_categories
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.material_categories;
begin
  perform private.require_catalog_manager();
  if length(coalesce(trim(p_name), '')) = 0 then
    raise exception 'Kategori adı zorunlu' using errcode = 'check_violation';
  end if;
  insert into public.material_categories (id, name, sort_order, is_active)
  values (coalesce(p_id, gen_random_uuid()), trim(p_name), coalesce(p_sort_order, 100), coalesce(p_is_active, true))
  on conflict (id) do update set name = excluded.name, sort_order = excluded.sort_order, is_active = excluded.is_active
  returning * into v;
  return v;
end;
$$;

-- Yeni malzeme (p_expected_version boş) veya güncelleme (sürüm eşleşmeli).
-- Aynı kimlikle tekrar gönderim: içerik aynıysa aynı kayıt, farklıysa 23505.
create or replace function public.save_material(
  p_id uuid, p_name text, p_category_id uuid, p_base_unit_id uuid, p_code text default null,
  p_description text default null, p_is_active boolean default true, p_expected_version integer default null)
returns public.materials
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.materials;
begin
  perform private.require_catalog_manager();
  if p_id is null then
    raise exception 'Malzeme kimliği zorunlu' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_name), '')) = 0 then
    raise exception 'Malzeme adı zorunlu' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.material_categories c where c.id = p_category_id and c.is_active) then
    raise exception 'Kategori bulunamadı veya pasif' using errcode = 'foreign_key_violation';
  end if;
  if not exists (select 1 from public.material_units u where u.id = p_base_unit_id and u.is_active) then
    raise exception 'Birim bulunamadı veya pasif' using errcode = 'foreign_key_violation';
  end if;

  select * into m from public.materials where id = p_id for update;
  if found then
    if p_expected_version is null then
      if m.name = trim(p_name) and m.category_id = p_category_id and m.base_unit_id = p_base_unit_id
         and (p_code is null or upper(m.code) = upper(trim(p_code)))
         and m.description is not distinct from nullif(trim(p_description), '')
         and m.is_active = coalesce(p_is_active, true) then
        return m;
      end if;
      raise exception 'Bu kimlikle farklı bir malzeme var' using errcode = 'unique_violation';
    end if;
    if m.version <> p_expected_version then
      raise exception 'Malzeme başka biri tarafından değiştirildi; yenileyip tekrar deneyin'
        using errcode = 'serialization_failure';
    end if;
    update public.materials
       set name = trim(p_name), category_id = p_category_id, base_unit_id = p_base_unit_id,
           code = coalesce(nullif(trim(p_code), ''), code), description = nullif(trim(p_description), ''),
           is_active = coalesce(p_is_active, true)
     where id = m.id
    returning * into m;
    return m;
  end if;

  insert into public.materials (id, code, name, category_id, base_unit_id, description, is_active)
  values (p_id, coalesce(nullif(trim(p_code), ''), 'MLZ-' || lpad(nextval('public.material_code_seq')::text, 4, '0')),
          trim(p_name), p_category_id, p_base_unit_id, nullif(trim(p_description), ''), coalesce(p_is_active, true))
  returning * into m;
  return m;
end;
$$;

-- Dönüşüm oranı: 1 <birim> = p_factor <temel birim>. Oran sonradan değişmez.
create or replace function public.save_material_unit_conversion(
  p_id uuid, p_material_id uuid, p_unit_id uuid, p_factor numeric, p_note text default null)
returns public.material_unit_conversions
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.material_unit_conversions;
begin
  perform private.require_catalog_manager();
  select * into c from public.material_unit_conversions where id = p_id;
  if found then
    if c.material_id = p_material_id and c.unit_id = p_unit_id and c.factor = p_factor then
      return c;
    end if;
    raise exception 'Bu kimlikle farklı bir dönüşüm oranı var' using errcode = 'unique_violation';
  end if;
  if not exists (select 1 from public.materials m where m.id = p_material_id) then
    raise exception 'Malzeme bulunamadı' using errcode = 'foreign_key_violation';
  end if;
  if not exists (select 1 from public.material_units u where u.id = p_unit_id and u.is_active) then
    raise exception 'Birim bulunamadı veya pasif' using errcode = 'foreign_key_violation';
  end if;
  if (select m.base_unit_id from public.materials m where m.id = p_material_id) = p_unit_id then
    raise exception 'Temel birim için dönüşüm tanımlanmaz' using errcode = 'check_violation';
  end if;
  if p_factor is null or p_factor <= 0 or p_factor <> round(p_factor, 6) then
    raise exception 'Oran sıfırdan büyük ve en çok 6 ondalıklı olmalı' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.material_unit_conversions x
              where x.material_id = p_material_id and x.unit_id = p_unit_id and x.is_active) then
    raise exception 'Bu birim için etkin bir oran zaten var; önce onu pasifleştirin' using errcode = 'unique_violation';
  end if;
  insert into public.material_unit_conversions (id, material_id, unit_id, factor, note)
  values (coalesce(p_id, gen_random_uuid()), p_material_id, p_unit_id, p_factor, nullif(trim(p_note), ''))
  returning * into c;
  return c;
end;
$$;

create or replace function public.set_material_unit_conversion_active(p_id uuid, p_is_active boolean)
returns public.material_unit_conversions
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.material_unit_conversions;
begin
  perform private.require_catalog_manager();
  update public.material_unit_conversions set is_active = coalesce(p_is_active, false) where id = p_id
  returning * into c;
  if not found then
    raise exception 'Dönüşüm oranı bulunamadı' using errcode = 'no_data_found';
  end if;
  return c;
end;
$$;

-- Depo: proje deposu (proje kapsamı) veya genel depo (projesiz). DEMO işareti
-- proje deposunda projeden alınır; genel depoda yalnızca oluştururken verilir.
create or replace function public.save_warehouse(
  p_id uuid, p_name text, p_project_id uuid default null, p_is_demo boolean default false,
  p_is_active boolean default true, p_notes text default null, p_expected_version integer default null)
returns public.warehouses
language plpgsql
security definer
set search_path = ''
as $$
declare
  w      public.warehouses;
  v_demo boolean;
begin
  if not private.has_permission('malzeme.manage', p_project_id) then
    raise exception 'Depo tanımlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if length(coalesce(trim(p_name), '')) = 0 then
    raise exception 'Depo adı zorunlu' using errcode = 'check_violation';
  end if;
  if p_project_id is not null then
    select pr.is_demo into v_demo from public.projects pr where pr.id = p_project_id and pr.deleted_at is null;
    if not found then
      raise exception 'Proje bulunamadı' using errcode = 'foreign_key_violation';
    end if;
  else
    v_demo := coalesce(p_is_demo, false);
  end if;

  select * into w from public.warehouses where id = p_id for update;
  if found then
    if w.project_id is distinct from p_project_id or w.is_demo is distinct from v_demo then
      raise exception 'Deponun projesi ve DEMO işareti değiştirilemez' using errcode = 'check_violation';
    end if;
    if p_expected_version is null then
      if w.name = trim(p_name) and w.is_active = coalesce(p_is_active, true)
         and w.notes is not distinct from nullif(trim(p_notes), '') then
        return w;
      end if;
      raise exception 'Bu kimlikle farklı bir depo var' using errcode = 'unique_violation';
    end if;
    if w.version <> p_expected_version then
      raise exception 'Depo başka biri tarafından değiştirildi' using errcode = 'serialization_failure';
    end if;
    if not coalesce(p_is_active, true) and exists (select 1 from public.v_stock_balances b
                                                    where b.warehouse_id = w.id and b.quantity <> 0) then
      raise exception 'Stoğu olan depo pasifleştirilemez; önce malzemeyi aktarın' using errcode = 'check_violation';
    end if;
    update public.warehouses set name = trim(p_name), is_active = coalesce(p_is_active, true), notes = nullif(trim(p_notes), '')
     where id = w.id returning * into w;
    return w;
  end if;

  insert into public.warehouses (id, kind, project_id, name, is_active, is_demo, notes)
  values (coalesce(p_id, gen_random_uuid()), case when p_project_id is null then 'genel' else 'proje' end::public.warehouse_kind,
          p_project_id, trim(p_name), coalesce(p_is_active, true), v_demo, nullif(trim(p_notes), ''))
  returning * into w;
  return w;
end;
$$;

-- -----------------------------------------------------------------------------
-- 11. Stok hareketi RPC'leri
-- -----------------------------------------------------------------------------
-- Hareket kaydı. Hareketin tüm depolarında stok.write gerekir (transferde iki
-- depo). Kaydeden tüm depolarda stok.approve sahibiyse hareket hemen stoka
-- işlenir; değilse onay bekler (şantiye şefi hazırlar, proje müdürü onaylar).
-- Sayımda p_quantity sayılan miktardır (temel birim) ve gerekçe zorunludur.
create or replace function public.create_stock_movement(
  p_id                  uuid,
  p_kind                public.stock_movement_kind,
  p_material_id         uuid,
  p_warehouse_id        uuid,
  p_quantity            numeric,
  p_unit_id             uuid    default null,
  p_target_warehouse_id uuid    default null,
  p_movement_date       date    default null,
  p_description         text    default null,
  p_reason              text    default null,
  p_document_id         uuid    default null,
  p_performed_by        text    default null)
returns public.stock_movements
language plpgsql
security definer
set search_path = ''
as $$
declare
  m        public.stock_movements;
  w        public.warehouses;
  t        public.warehouses;
  mat      public.materials;
  v_unit   uuid;
  v_factor numeric;
  v_base   numeric;
  v_date   date := coalesce(p_movement_date, private.today());
  v_avail  numeric;
begin
  if p_id is null then
    raise exception 'Hareket kimliği zorunlu' using errcode = 'check_violation';
  end if;
  if p_kind is null or p_kind = 'ters_kayit' then
    raise exception 'Ters kayıt yalnızca iptal işlemiyle oluşur' using errcode = 'check_violation';
  end if;

  select * into w from public.warehouses where id = p_warehouse_id;
  if not found or not private.can_warehouse('stok.read', w.id) then
    raise exception 'Depo bulunamadı' using errcode = 'no_data_found';
  end if;
  select * into mat from public.materials where id = p_material_id;
  if not found then
    raise exception 'Malzeme bulunamadı' using errcode = 'foreign_key_violation';
  end if;
  v_unit := coalesce(p_unit_id, mat.base_unit_id);

  perform pg_advisory_xact_lock(hashtextextended(p_id::text, 0));

  -- Tekrar gönderim: yalnızca kaydeden, aynı içerikle.
  select * into m from public.stock_movements where id = p_id;
  if found then
    if m.created_by is distinct from (select auth.uid())
       or not (private.can_warehouse('stok.read', m.warehouse_id)
               or private.can_warehouse('stok.read', m.target_warehouse_id)) then
      raise exception 'Bu kimlikle başka bir hareket var' using errcode = 'unique_violation';
    end if;
    if m.kind = p_kind and m.material_id = p_material_id and m.warehouse_id = p_warehouse_id
       and m.target_warehouse_id is not distinct from p_target_warehouse_id and m.quantity = p_quantity
       and m.unit_id = v_unit and m.movement_date = v_date
       and m.description is not distinct from nullif(trim(p_description), '')
       and m.reason is not distinct from nullif(trim(p_reason), '')
       and m.document_id is not distinct from p_document_id
       and m.performed_by is not distinct from nullif(trim(p_performed_by), '') then
      return m;
    end if;
    raise exception 'Bu kimlikle farklı bir hareket var' using errcode = 'unique_violation';
  end if;

  if not private.can_warehouse('stok.write', w.id) then
    raise exception 'Bu depoda stok hareketi girme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if not w.is_active then
    raise exception 'Depo pasif' using errcode = 'check_violation';
  end if;
  if not mat.is_active then
    raise exception 'Malzeme pasif' using errcode = 'check_violation';
  end if;

  if p_kind = 'transfer' then
    if p_target_warehouse_id is null or p_target_warehouse_id = p_warehouse_id then
      raise exception 'Transfer için farklı bir alıcı depo seçilmeli' using errcode = 'check_violation';
    end if;
    select * into t from public.warehouses where id = p_target_warehouse_id;
    if not found or not private.can_see_warehouse(t.id) then
      raise exception 'Alıcı depo bulunamadı' using errcode = 'no_data_found';
    end if;
    if not private.can_warehouse('stok.write', t.id) then
      raise exception 'Alıcı depoya stok hareketi girme yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if not t.is_active then
      raise exception 'Alıcı depo pasif' using errcode = 'check_violation';
    end if;
    if t.is_demo is distinct from w.is_demo then
      raise exception 'Deneme (DEMO) deposu ile gerçek depo arasında transfer yapılamaz' using errcode = 'check_violation';
    end if;
  elsif p_target_warehouse_id is not null then
    raise exception 'Alıcı depo yalnızca transferde seçilir' using errcode = 'check_violation';
  end if;

  if v_date > private.today() + 1 then
    raise exception 'Hareket tarihi ileri bir tarih olamaz' using errcode = 'check_violation';
  end if;
  if p_kind = 'sayim' then
    if v_unit <> mat.base_unit_id then
      raise exception 'Sayım temel birimle girilir' using errcode = 'check_violation';
    end if;
    if length(coalesce(trim(p_reason), '')) < 10 then
      raise exception 'Sayım düzeltmesi için en az 10 karakterlik gerekçe zorunlu' using errcode = 'check_violation';
    end if;
    perform private.check_unit_quantity(p_quantity, v_unit, true);
    v_factor := 1;
    v_base := p_quantity;
  else
    perform private.check_unit_quantity(p_quantity, v_unit, false);
    v_factor := private.material_unit_factor(mat.id, v_unit);
    v_base := private.to_base_quantity(mat.id, p_quantity, v_factor);
  end if;
  perform private.check_stock_document(p_document_id, w.project_id, w.is_demo);

  -- Erken uyarı (bağlayıcı denetim stoka işlenirken yapılır).
  if p_kind in ('kullanim', 'iade_tedarikci', 'transfer') then
    v_avail := private.stock_balance(w.id, mat.id);
    if v_base > v_avail then
      raise exception 'Yetersiz stok: depoda % var, % isteniyor', v_avail, v_base using errcode = 'check_violation';
    end if;
  end if;

  insert into public.stock_movements (id, movement_no, kind, status, movement_date, material_id, warehouse_id,
                                      target_warehouse_id, quantity, unit_id, unit_factor, base_quantity, description,
                                      reason, performed_by, document_id, is_demo)
  values (p_id, private.next_doc_no('SH-', 'public.stock_movement_no_seq'), p_kind, 'bekliyor', v_date, mat.id, w.id,
          p_target_warehouse_id, p_quantity, v_unit, v_factor, v_base, nullif(trim(p_description), ''),
          nullif(trim(p_reason), ''), nullif(trim(p_performed_by), ''), p_document_id, w.is_demo)
  returning * into m;

  if private.can_warehouse('stok.approve', w.id)
     and (p_target_warehouse_id is null or private.can_warehouse('stok.approve', p_target_warehouse_id)) then
    m := private.stock_post(m.id);
  end if;
  return m;
end;
$$;

create or replace function public.approve_stock_movement(p_id uuid, p_expected_version integer default null)
returns public.stock_movements
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.stock_movements;
begin
  select * into m from public.stock_movements where id = p_id;
  if not found or not (private.can_warehouse('stok.read', m.warehouse_id)
                       or private.can_warehouse('stok.read', m.target_warehouse_id)) then
    raise exception 'Hareket bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.can_warehouse('stok.approve', m.warehouse_id)
     or (m.target_warehouse_id is not null and not private.can_warehouse('stok.approve', m.target_warehouse_id)) then
    raise exception 'Bu hareketi onaylama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select * into m from public.stock_movements where id = p_id for update;
  if m.status = 'onaylandi' then
    return m;  -- tekrar onay ikinci defter satırı açmaz
  end if;
  if m.status = 'reddedildi' then
    raise exception 'Reddedilmiş hareket onaylanamaz' using errcode = 'check_violation';
  end if;
  if p_expected_version is not null and m.version <> p_expected_version then
    raise exception 'Hareket onaydan önce değişti; yenileyip tekrar inceleyin' using errcode = 'serialization_failure';
  end if;
  return private.stock_post(m.id);
end;
$$;

-- Bekleyen hareketi reddetme (onaylayan) veya geri çekme (kaydeden).
create or replace function public.reject_stock_movement(p_id uuid, p_reason text)
returns public.stock_movements
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.stock_movements;
begin
  select * into m from public.stock_movements where id = p_id for update;
  if not found or not (private.can_warehouse('stok.read', m.warehouse_id)
                       or private.can_warehouse('stok.read', m.target_warehouse_id)) then
    raise exception 'Hareket bulunamadı' using errcode = 'no_data_found';
  end if;
  if m.status = 'reddedildi' then
    return m;
  end if;
  if m.status <> 'bekliyor' then
    raise exception 'Onaylı hareket reddedilemez; ters kayıtla iptal edin' using errcode = 'check_violation';
  end if;
  if not (m.created_by = (select auth.uid()) and private.can_warehouse('stok.write', m.warehouse_id))
     and not private.can_warehouse('stok.approve', m.warehouse_id) then
    raise exception 'Bu hareketi reddetme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if length(coalesce(trim(p_reason), '')) < 3 then
    raise exception 'Gerekçe zorunlu' using errcode = 'check_violation';
  end if;
  update public.stock_movements
     set status = 'reddedildi', rejected_at = now(), rejected_by = auth.uid(), reject_reason = trim(p_reason)
   where id = m.id returning * into m;
  return m;
end;
$$;

-- Onaylı hareketin iptali: ters kayıt (orijinal korunur). Tekrar çağrı aynı
-- ters kaydı döner. Satın alma teslimi buradan değil, teslim iptaliyle geri alınır.
create or replace function public.reverse_stock_movement(p_id uuid, p_reversal_id uuid, p_reason text)
returns public.stock_movements
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.stock_movements;
  r public.stock_movements;
begin
  select * into m from public.stock_movements where id = p_id;
  if not found or not (private.can_warehouse('stok.read', m.warehouse_id)
                       or private.can_warehouse('stok.read', m.target_warehouse_id)) then
    raise exception 'Hareket bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.can_warehouse('stok.cancel', m.warehouse_id)
     or (m.target_warehouse_id is not null and not private.can_warehouse('stok.cancel', m.target_warehouse_id)) then
    raise exception 'Hareket iptal yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select * into m from public.stock_movements where id = p_id for update;
  if m.reversed_by_id is not null then
    select * into r from public.stock_movements where id = m.reversed_by_id;
    if r.id = p_reversal_id then
      return r;
    end if;
    raise exception 'Bu hareket zaten iptal edilmiş' using errcode = 'unique_violation';
  end if;
  if m.kind = 'ters_kayit' then
    raise exception 'Ters kayıt yeniden iptal edilemez' using errcode = 'check_violation';
  end if;
  if m.status <> 'onaylandi' then
    raise exception 'Yalnızca onaylı hareket iptal edilir; bekleyen hareketi reddedin' using errcode = 'check_violation';
  end if;
  if m.purchase_receipt_id is not null then
    raise exception 'Satın alma teslimi, teslim alma kaydı iptal edilerek geri alınır' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_reason), '')) < 10 then
    raise exception 'İptal gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;
  return private.stock_reverse(m.id, p_reversal_id, p_reason);
end;
$$;

-- Depo bazında dönem özeti (miktar; tutar yok). Kullanım pozitif gösterilir.
-- Ters kayıtlar orijinal hareketin türünde netleşir.
create or replace function public.stock_summary(p_warehouse_id uuid, p_from date default null, p_to date default null)
returns table (
  material_id        uuid,
  opening            numeric,
  received           numeric,
  used               numeric,
  transferred        numeric,
  returned_to_stock  numeric,
  returned_to_vendor numeric,
  adjusted           numeric,
  closing            numeric)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.can_warehouse('stok.read', p_warehouse_id) then
    raise exception 'Depo bulunamadı' using errcode = 'no_data_found';
  end if;
  return query
  with e as (
    select x.material_id, x.entry_date, x.quantity, coalesce(o.kind, mv.kind) as kind
      from public.stock_entries x
      join public.stock_movements mv on mv.id = x.movement_id
      left join public.stock_movements o on o.id = mv.reversal_of_id
     where x.warehouse_id = p_warehouse_id and (p_to is null or x.entry_date <= p_to)
  )
  select e.material_id,
         coalesce(sum(e.quantity) filter (where p_from is not null and e.entry_date < p_from), 0),
         coalesce(sum(e.quantity) filter (where (p_from is null or e.entry_date >= p_from) and e.kind = 'giris'), 0),
         coalesce(-sum(e.quantity) filter (where (p_from is null or e.entry_date >= p_from) and e.kind = 'kullanim'), 0),
         coalesce(sum(e.quantity) filter (where (p_from is null or e.entry_date >= p_from) and e.kind = 'transfer'), 0),
         coalesce(sum(e.quantity) filter (where (p_from is null or e.entry_date >= p_from) and e.kind = 'iade_depo'), 0),
         coalesce(-sum(e.quantity) filter (where (p_from is null or e.entry_date >= p_from) and e.kind = 'iade_tedarikci'), 0),
         coalesce(sum(e.quantity) filter (where (p_from is null or e.entry_date >= p_from) and e.kind = 'sayim'), 0),
         sum(e.quantity)
    from e
   group by e.material_id
   order by e.material_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 12. Satın alma RPC'leri
-- -----------------------------------------------------------------------------
-- Satırları doğrulayıp saklanan biçime çevirir (birim boşsa temel birim).
create or replace function private.normalize_po_lines(p_lines jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_line   jsonb;
  v_out    jsonb := '[]'::jsonb;
  mat      public.materials;
  v_unit   uuid;
  v_qty    numeric;
  v_price  numeric;
  v_factor numeric;
  v_ids    uuid[] := '{}';
  v_id     uuid;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Siparişte en az bir malzeme satırı olmalı' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(p_lines) > 200 then
    raise exception 'Bir siparişte en çok 200 satır olabilir' using errcode = 'check_violation';
  end if;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_id := nullif(v_line ->> 'id', '')::uuid;
    if v_id is null or v_id = any (v_ids) then
      raise exception 'Her satırın benzersiz kimliği olmalı' using errcode = 'check_violation';
    end if;
    v_ids := v_ids || v_id;
    select * into mat from public.materials where id = nullif(v_line ->> 'material_id', '')::uuid;
    if not found or not mat.is_active then
      raise exception 'Malzeme bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
    v_unit := coalesce(nullif(v_line ->> 'unit_id', '')::uuid, mat.base_unit_id);
    v_qty := (v_line ->> 'quantity')::numeric;
    perform private.check_unit_quantity(v_qty, v_unit, false);
    v_factor := private.material_unit_factor(mat.id, v_unit);
    v_price := nullif(v_line ->> 'unit_price', '')::numeric;
    if v_price is not null and (v_price < 0 or v_price <> round(v_price, 4)) then
      raise exception 'Birim fiyat sıfır veya pozitif ve en çok 4 ondalıklı olmalı' using errcode = 'check_violation';
    end if;
    v_out := v_out || jsonb_build_object(
      'id', v_id, 'material_id', mat.id, 'quantity', v_qty, 'unit_id', v_unit, 'unit_factor', v_factor,
      'base_quantity', private.to_base_quantity(mat.id, v_qty, v_factor), 'unit_price', v_price,
      'note', nullif(trim(v_line ->> 'note'), ''));
  end loop;
  return v_out;
end;
$$;
revoke execute on function private.normalize_po_lines(jsonb) from public, anon, authenticated;

create or replace function private.stored_po_lines(p_order uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id, 'material_id', l.material_id, 'quantity', l.quantity, 'unit_id', l.unit_id,
           'unit_factor', l.unit_factor, 'base_quantity', l.base_quantity, 'unit_price', l.unit_price,
           'note', l.note) order by l.line_no), '[]'::jsonb)
    from public.purchase_order_lines l where l.order_id = p_order and l.deleted_at is null;
$$;
revoke execute on function private.stored_po_lines(uuid) from public, anon, authenticated;

-- Sipariş taslağı: yeni (p_expected_version boş) veya taslak güncellemesi.
-- Sipariş hiçbir finansal kayıt açmaz.
create or replace function public.save_purchase_order(
  p_id               uuid,
  p_cari_account_id  uuid,
  p_warehouse_id     uuid,
  p_lines            jsonb,
  p_order_date       date    default null,
  p_expected_date    date    default null,
  p_currency         text    default 'TRY',
  p_description      text    default null,
  p_notes            text    default null,
  p_expected_version integer default null)
returns public.purchase_orders
language plpgsql
security definer
set search_path = ''
as $$
declare
  o       public.purchase_orders;
  w       public.warehouses;
  v_lines jsonb;
  v_line  jsonb;
  v_no    integer := 0;
  v_cur   text := upper(coalesce(nullif(trim(p_currency), ''), 'TRY'));
  v_date  date := coalesce(p_order_date, private.today());
begin
  if p_id is null then
    raise exception 'Sipariş kimliği zorunlu' using errcode = 'check_violation';
  end if;
  select * into w from public.warehouses where id = p_warehouse_id;
  if not found or not private.can_see_warehouse(w.id) then
    raise exception 'Depo bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('satinalma.write', w.project_id) then
    raise exception 'Bu kapsamda satın alma siparişi hazırlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.cari_accounts c
                  where c.id = p_cari_account_id and c.deleted_at is null and c.is_active) then
    raise exception 'Tedarikçi (cari) bulunamadı veya pasif' using errcode = 'foreign_key_violation';
  end if;
  if (select c.is_demo from public.cari_accounts c where c.id = p_cari_account_id) is distinct from w.is_demo then
    raise exception 'Deneme (DEMO) carisi gerçek depoya, gerçek cari deneme deposuna sipariş veremez'
      using errcode = 'check_violation';
  end if;
  if v_cur !~ '^[A-Z]{3}$' then
    raise exception 'Para birimi üç harfli kod olmalı' using errcode = 'check_violation';
  end if;
  if p_expected_date is not null and p_expected_date < v_date then
    raise exception 'Beklenen teslim tarihi sipariş tarihinden önce olamaz' using errcode = 'check_violation';
  end if;
  v_lines := private.normalize_po_lines(p_lines);

  perform pg_advisory_xact_lock(hashtextextended(p_id::text, 0));
  select * into o from public.purchase_orders where id = p_id for update;
  if found then
    if not private.can_see_purchase(o.project_id) then
      raise exception 'Bu kimlikle başka bir sipariş var' using errcode = 'unique_violation';
    end if;
    if p_expected_version is null then
      if o.cari_account_id = p_cari_account_id and o.warehouse_id = p_warehouse_id and o.order_date = v_date
         and o.expected_date is not distinct from p_expected_date and o.currency = v_cur
         and o.description is not distinct from nullif(trim(p_description), '')
         and o.notes is not distinct from nullif(trim(p_notes), '')
         and private.stored_po_lines(o.id) = v_lines then
        return o;
      end if;
      raise exception 'Bu kimlikle farklı bir sipariş var' using errcode = 'unique_violation';
    end if;
    if o.status <> 'taslak' then
      raise exception 'Yalnızca taslak sipariş düzenlenir' using errcode = 'check_violation';
    end if;
    if o.version <> p_expected_version then
      raise exception 'Sipariş başka biri tarafından değiştirildi; yenileyip tekrar deneyin'
        using errcode = 'serialization_failure';
    end if;
    if not private.has_permission('satinalma.write', o.project_id) then
      raise exception 'Bu siparişi düzenleme yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if o.is_demo is distinct from w.is_demo then
      raise exception 'Deneme (DEMO) siparişi gerçek depoya taşınamaz (veya tersi)' using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.purchase_order_lines l, jsonb_array_elements(v_lines) x
                where l.id = (x ->> 'id')::uuid and l.order_id <> o.id) then
      raise exception 'Satır kimliği başka bir siparişe ait' using errcode = 'unique_violation';
    end if;
    update public.purchase_orders
       set cari_account_id = p_cari_account_id, warehouse_id = w.id, project_id = w.project_id, order_date = v_date,
           expected_date = p_expected_date, currency = v_cur, description = nullif(trim(p_description), ''),
           notes = nullif(trim(p_notes), '')
     where id = o.id returning * into o;
    -- Çıkarılan satırlar silinmez, işaretlenir; numaralar yeniden verilir.
    update public.purchase_order_lines set deleted_at = now(), line_no = line_no + 100000
     where order_id = o.id and deleted_at is null
       and id not in (select (x ->> 'id')::uuid from jsonb_array_elements(v_lines) x);
    update public.purchase_order_lines set line_no = line_no + 100000
     where order_id = o.id and deleted_at is null;
  else
    if exists (select 1 from public.purchase_order_lines l, jsonb_array_elements(v_lines) x
                where l.id = (x ->> 'id')::uuid) then
      raise exception 'Satır kimliği başka bir siparişe ait' using errcode = 'unique_violation';
    end if;
    insert into public.purchase_orders (id, order_no, status, cari_account_id, warehouse_id, project_id, order_date,
                                        expected_date, currency, description, notes, is_demo)
    values (p_id, private.next_doc_no('SA-', 'public.purchase_order_no_seq'), 'taslak', p_cari_account_id, w.id,
            w.project_id, v_date, p_expected_date, v_cur, nullif(trim(p_description), ''), nullif(trim(p_notes), ''),
            w.is_demo)
    returning * into o;
  end if;

  for v_line in select value from jsonb_array_elements(v_lines) loop
    v_no := v_no + 1;
    insert into public.purchase_order_lines (id, order_id, line_no, material_id, quantity, unit_id, unit_factor,
                                             base_quantity, unit_price, note)
    values ((v_line ->> 'id')::uuid, o.id, v_no, (v_line ->> 'material_id')::uuid, (v_line ->> 'quantity')::numeric,
            (v_line ->> 'unit_id')::uuid, (v_line ->> 'unit_factor')::numeric, (v_line ->> 'base_quantity')::numeric,
            (v_line ->> 'unit_price')::numeric, v_line ->> 'note')
    on conflict (id) do update
      set line_no = excluded.line_no, material_id = excluded.material_id, quantity = excluded.quantity,
          unit_id = excluded.unit_id, unit_factor = excluded.unit_factor, base_quantity = excluded.base_quantity,
          unit_price = excluded.unit_price, note = excluded.note, deleted_at = null;
  end loop;

  perform private.purchase_event(o.id, case when p_expected_version is null then 'olustur' else 'guncelle' end,
                                 null, 'taslak', null, jsonb_build_object('line_count', v_no));
  return o;
end;
$$;

-- Sipariş durumunu teslimlere göre yeniler (elle kapatılmamışsa).
create or replace function private.refresh_purchase_order_status(p_order uuid)
returns public.purchase_orders
language plpgsql
security definer
set search_path = ''
as $$
declare
  o          public.purchase_orders;
  v_any      boolean;
  v_complete boolean;
  v_new      public.purchase_order_status;
begin
  select * into o from public.purchase_orders where id = p_order;
  if o.status in ('taslak', 'iptal') or o.close_reason is not null then
    return o;
  end if;
  select bool_or(s.received_base_quantity > 0), bool_and(s.remaining_base_quantity <= 0)
    into v_any, v_complete
    from public.v_purchase_order_line_status s where s.order_id = p_order;
  v_new := case when v_complete then 'tamamlandi' when v_any then 'kismi_teslim' else 'onaylandi' end;
  if v_new <> o.status then
    update public.purchase_orders set status = v_new where id = o.id returning * into o;
  end if;
  return o;
end;
$$;
revoke execute on function private.refresh_purchase_order_status(uuid) from public, anon, authenticated;

-- onayla (satinalma.approve) · iptal (taslak: satinalma.write; onaylı ve
-- teslimsiz: satinalma.cancel) · kapat (eksik teslimle tamamla: satinalma.approve).
-- Hiçbiri finansal kayıt açmaz.
create or replace function public.purchase_order_transition(
  p_id uuid, p_action text, p_reason text default null, p_expected_version integer default null)
returns public.purchase_orders
language plpgsql
security definer
set search_path = ''
as $$
declare
  o      public.purchase_orders;
  v_from text;
begin
  select * into o from public.purchase_orders where id = p_id;
  if not found or not private.can_see_purchase(o.project_id) then
    raise exception 'Sipariş bulunamadı' using errcode = 'no_data_found';
  end if;
  select * into o from public.purchase_orders where id = p_id for update;
  v_from := o.status::text;
  if p_expected_version is not null and o.version <> p_expected_version then
    raise exception 'Sipariş değişti; yenileyip tekrar deneyin' using errcode = 'serialization_failure';
  end if;

  case p_action
    when 'onayla' then
      if o.status in ('onaylandi', 'kismi_teslim', 'tamamlandi') then
        return o;
      end if;
      if not private.has_permission('satinalma.approve', o.project_id) then
        raise exception 'Sipariş onaylama yetkiniz yok' using errcode = 'insufficient_privilege';
      end if;
      if o.status <> 'taslak' then
        raise exception 'İptal edilmiş sipariş onaylanamaz' using errcode = 'check_violation';
      end if;
      if not exists (select 1 from public.purchase_order_lines l where l.order_id = o.id and l.deleted_at is null) then
        raise exception 'Satırı olmayan sipariş onaylanamaz' using errcode = 'check_violation';
      end if;
      update public.purchase_orders set status = 'onaylandi', approved_at = now(), approved_by = auth.uid()
       where id = o.id returning * into o;
    when 'iptal' then
      if o.status = 'iptal' then
        return o;
      end if;
      if o.status = 'taslak' then
        if not private.has_permission('satinalma.write', o.project_id) then
          raise exception 'Sipariş iptal yetkiniz yok' using errcode = 'insufficient_privilege';
        end if;
        if length(coalesce(trim(p_reason), '')) < 3 then
          raise exception 'İptal gerekçesi zorunlu' using errcode = 'check_violation';
        end if;
      else
        if not private.has_permission('satinalma.cancel', o.project_id) then
          raise exception 'Onaylı siparişi iptal etme yetkiniz yok' using errcode = 'insufficient_privilege';
        end if;
        if exists (select 1 from public.purchase_receipts r where r.order_id = o.id and r.status = 'aktif') then
          raise exception 'Teslim alınmış sipariş iptal edilemez; teslimleri iptal edin veya siparişi kapatın'
            using errcode = 'check_violation';
        end if;
        if length(coalesce(trim(p_reason), '')) < 10 then
          raise exception 'İptal gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
        end if;
      end if;
      update public.purchase_orders set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(),
                                        cancel_reason = trim(p_reason)
       where id = o.id returning * into o;
    when 'kapat' then
      if o.status = 'tamamlandi' then
        return o;
      end if;
      if not private.has_permission('satinalma.approve', o.project_id) then
        raise exception 'Siparişi kapatma yetkiniz yok' using errcode = 'insufficient_privilege';
      end if;
      if o.status not in ('onaylandi', 'kismi_teslim') then
        raise exception 'Yalnızca onaylı sipariş kapatılır' using errcode = 'check_violation';
      end if;
      if length(coalesce(trim(p_reason), '')) < 10 then
        raise exception 'Kapatma gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
      end if;
      update public.purchase_orders set status = 'tamamlandi', closed_at = now(), closed_by = auth.uid(),
                                        close_reason = trim(p_reason)
       where id = o.id returning * into o;
    else
      raise exception 'Geçersiz işlem: %', p_action using errcode = 'invalid_parameter_value';
  end case;
  perform private.purchase_event(o.id, p_action, v_from, o.status::text, p_reason);
  return o;
end;
$$;

-- Teslim alma: onaylı siparişin satırları parça parça teslim alınır; her
-- satır sipariş deposuna onaylı bir stok girişi açar. Sipariş satırı ve
-- sipariş kilitlenir: eşzamanlı iki teslim kalanı birlikte aşamaz. Aynı
-- kimlikle tekrar gönderim ikinci giriş açmaz.
--   p_lines: [{"order_line_id": uuid, "quantity": sayı (sipariş satırı biriminde)}]
create or replace function public.receive_purchase_order(
  p_id           uuid,
  p_order_id     uuid,
  p_lines        jsonb,
  p_receipt_date date default null,
  p_waybill_no   text default null,
  p_note         text default null,
  p_document_id  uuid default null,
  p_performed_by text default null)
returns public.purchase_receipts
language plpgsql
security definer
set search_path = ''
as $$
declare
  o         public.purchase_orders;
  r         public.purchase_receipts;
  l         public.purchase_order_lines;
  v_item    jsonb;
  v_qty     numeric;
  v_base    numeric;
  v_left    numeric;
  v_mov     uuid;
  v_date    date := coalesce(p_receipt_date, private.today());
  v_req     jsonb;
  v_ids     uuid[] := '{}';
begin
  if p_id is null then
    raise exception 'Teslim kimliği zorunlu' using errcode = 'check_violation';
  end if;
  select * into o from public.purchase_orders where id = p_order_id;
  if not found or not private.can_see_purchase(o.project_id) then
    raise exception 'Sipariş bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('satinalma.receive', o.project_id) then
    raise exception 'Malzeme teslim alma yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Teslim alınacak en az bir satır girilmeli' using errcode = 'check_violation';
  end if;
  -- İstek, karşılaştırma için normalleştirilir (satır sırası önemsiz).
  select coalesce(jsonb_agg(jsonb_build_object('order_line_id', (x ->> 'order_line_id')::uuid,
                                               'quantity', (x ->> 'quantity')::numeric)
                            order by (x ->> 'order_line_id')), '[]'::jsonb)
    into v_req from jsonb_array_elements(p_lines) x;

  select * into o from public.purchase_orders where id = p_order_id for update;

  select * into r from public.purchase_receipts where id = p_id;
  if found then
    if r.created_by is distinct from (select auth.uid()) or not private.can_see_purchase(o.project_id) then
      raise exception 'Bu kimlikle başka bir teslim var' using errcode = 'unique_violation';
    end if;
    if r.status = 'iptal' then
      raise exception 'Bu kimlikli teslim iptal edilmiş; yeni teslim için yeniden deneyin' using errcode = 'unique_violation';
    end if;
    if r.order_id = p_order_id and r.receipt_date = v_date
       and r.waybill_no is not distinct from nullif(trim(p_waybill_no), '')
       and r.note is not distinct from nullif(trim(p_note), '')
       and r.document_id is not distinct from p_document_id
       and (select coalesce(jsonb_agg(jsonb_build_object('order_line_id', rl.order_line_id, 'quantity', rl.quantity)
                                      order by rl.order_line_id::text), '[]'::jsonb)
              from public.purchase_receipt_lines rl where rl.receipt_id = r.id) = v_req then
      return r;
    end if;
    raise exception 'Bu kimlikle farklı bir teslim var' using errcode = 'unique_violation';
  end if;

  if o.status not in ('onaylandi', 'kismi_teslim') then
    raise exception 'Yalnızca onaylı ve tamamlanmamış siparişe teslim alınır' using errcode = 'check_violation';
  end if;
  if v_date > private.today() + 1 then
    raise exception 'Teslim tarihi ileri bir tarih olamaz' using errcode = 'check_violation';
  end if;
  if v_date < o.order_date then
    raise exception 'Teslim tarihi sipariş tarihinden önce olamaz' using errcode = 'check_violation';
  end if;
  perform private.check_stock_document(p_document_id, o.project_id, o.is_demo);

  insert into public.purchase_receipts (id, receipt_no, order_id, warehouse_id, receipt_date, waybill_no, note,
                                        document_id, is_demo)
  values (p_id, private.next_doc_no('TS-', 'public.purchase_receipt_no_seq'), o.id, o.warehouse_id, v_date,
          nullif(trim(p_waybill_no), ''), nullif(trim(p_note), ''), p_document_id, o.is_demo)
  returning * into r;

  for v_item in select value from jsonb_array_elements(p_lines) loop
    select * into l from public.purchase_order_lines
     where id = nullif(v_item ->> 'order_line_id', '')::uuid and order_id = o.id and deleted_at is null
       for update;
    if not found then
      raise exception 'Sipariş satırı bulunamadı' using errcode = 'foreign_key_violation';
    end if;
    if l.id = any (v_ids) then
      raise exception 'Aynı sipariş satırı bir teslimde bir kez girilir' using errcode = 'check_violation';
    end if;
    v_ids := v_ids || l.id;
    v_qty := (v_item ->> 'quantity')::numeric;
    perform private.check_unit_quantity(v_qty, l.unit_id, false);
    v_base := private.to_base_quantity(l.material_id, v_qty, l.unit_factor);
    select s.remaining_base_quantity into v_left from public.v_purchase_order_line_status s where s.order_line_id = l.id;
    if v_base > v_left then
      raise exception 'Teslim miktarı sipariş kalanını aşıyor (satır %: kalan %, girilen %)', l.line_no, v_left, v_base
        using errcode = 'check_violation';
    end if;

    v_mov := gen_random_uuid();
    insert into public.stock_movements (id, movement_no, kind, status, movement_date, material_id, warehouse_id,
                                        quantity, unit_id, unit_factor, base_quantity, description, performed_by,
                                        document_id, purchase_order_id, purchase_receipt_id, approved_at, approved_by,
                                        is_demo)
    values (v_mov, private.next_doc_no('SH-', 'public.stock_movement_no_seq'), 'giris', 'onaylandi', v_date,
            l.material_id, o.warehouse_id, v_qty, l.unit_id, l.unit_factor, v_base,
            'Satın alma teslimi · ' || o.order_no || ' · ' || r.receipt_no, nullif(trim(p_performed_by), ''),
            p_document_id, o.id, r.id, now(), auth.uid(), o.is_demo);
    insert into public.stock_entries (movement_id, warehouse_id, material_id, entry_date, quantity, is_demo)
    values (v_mov, o.warehouse_id, l.material_id, v_date, v_base, o.is_demo);
    insert into public.purchase_receipt_lines (receipt_id, order_line_id, quantity, base_quantity, stock_movement_id)
    values (r.id, l.id, v_qty, v_base, v_mov);
  end loop;

  o := private.refresh_purchase_order_status(o.id);
  perform private.purchase_event(o.id, 'teslim', null, o.status::text, null,
                                 jsonb_build_object('receipt_id', r.id, 'receipt_no', r.receipt_no, 'lines', v_req));
  return r;
end;
$$;

-- Teslim iptali: stok girişleri ters kayıtla geri alınır (malzeme kullanılmış
-- veya aktarılmışsa reddedilir), sipariş durumu yeniden hesaplanır.
create or replace function public.cancel_purchase_receipt(p_id uuid, p_reason text)
returns public.purchase_receipts
language plpgsql
security definer
set search_path = ''
as $$
declare
  r  public.purchase_receipts;
  o  public.purchase_orders;
  rl record;
begin
  select * into r from public.purchase_receipts where id = p_id;
  if found then
    select * into o from public.purchase_orders where id = r.order_id;
  end if;
  if r.id is null or not private.can_see_purchase(o.project_id) then
    raise exception 'Teslim bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('satinalma.receive', o.project_id)
     or not private.can_warehouse('stok.cancel', r.warehouse_id) then
    raise exception 'Teslim iptal yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  perform 1 from public.purchase_orders where id = o.id for update;
  select * into r from public.purchase_receipts where id = p_id for update;
  if r.status = 'iptal' then
    return r;
  end if;
  if length(coalesce(trim(p_reason), '')) < 10 then
    raise exception 'İptal gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;
  for rl in select l.stock_movement_id from public.purchase_receipt_lines l
             join public.stock_movements m on m.id = l.stock_movement_id
            where l.receipt_id = r.id
            order by m.warehouse_id, m.material_id loop
    perform private.stock_reverse(rl.stock_movement_id, gen_random_uuid(), p_reason);
  end loop;
  update public.purchase_receipts set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(),
                                      cancel_reason = trim(p_reason)
   where id = r.id returning * into r;
  o := private.refresh_purchase_order_status(o.id);
  perform private.purchase_event(o.id, 'teslim_iptal', null, o.status::text, p_reason,
                                 jsonb_build_object('receipt_id', r.id, 'receipt_no', r.receipt_no));
  return r;
end;
$$;

-- Gelen fatura (Aşama 5 gider kaydı) ile sipariş arasında bilgi bağlantısı.
-- Finans kaydı değişmez; aynı gider ikinci bir siparişe bağlanamaz.
create or replace function public.link_purchase_order_expense(
  p_id uuid, p_order_id uuid, p_finance_document_id uuid, p_note text default null)
returns public.purchase_order_expense_links
language plpgsql
security definer
set search_path = ''
as $$
declare
  o  public.purchase_orders;
  d  public.finance_documents;
  k  public.purchase_order_expense_links;
begin
  select * into o from public.purchase_orders where id = p_order_id;
  if not found or not private.has_permission('satinalma.read', o.project_id) then
    raise exception 'Sipariş bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('satinalma.write', o.project_id) then
    raise exception 'Siparişe gider bağlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select * into d from public.finance_documents where id = p_finance_document_id;
  if not found or not private.can_read_fin_doc(d.kind, d.project_id, d.created_by) then
    raise exception 'Gider kaydı bulunamadı' using errcode = 'no_data_found';
  end if;

  perform 1 from public.purchase_orders where id = o.id for update;
  select * into k from public.purchase_order_expense_links where id = p_id;
  if found then
    if k.order_id = p_order_id and k.finance_document_id = p_finance_document_id and k.status = 'aktif' then
      return k;
    end if;
    raise exception 'Bu kimlikle farklı bir bağlantı var' using errcode = 'unique_violation';
  end if;
  if d.kind <> 'gider' then
    raise exception 'Siparişe yalnızca gider kaydı bağlanır' using errcode = 'check_violation';
  end if;
  if d.status = 'iptal' then
    raise exception 'İptal edilmiş gider bağlanamaz' using errcode = 'check_violation';
  end if;
  if o.status in ('taslak', 'iptal') then
    raise exception 'Gider yalnızca onaylı siparişe bağlanır' using errcode = 'check_violation';
  end if;
  if d.project_id is distinct from o.project_id then
    raise exception 'Gider kaydı siparişle aynı projeye ait olmalı' using errcode = 'check_violation';
  end if;
  if d.cari_account_id is not null and d.cari_account_id <> o.cari_account_id then
    raise exception 'Gider kaydının carisi siparişin tedarikçisiyle aynı olmalı' using errcode = 'check_violation';
  end if;
  if d.is_demo is distinct from o.is_demo then
    raise exception 'Deneme (DEMO) kaydı gerçek kayda bağlanamaz' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.purchase_order_expense_links x
              where x.finance_document_id = d.id and x.status = 'aktif') then
    raise exception 'Bu gider kaydı zaten bir siparişe bağlı' using errcode = 'unique_violation';
  end if;
  insert into public.purchase_order_expense_links (id, order_id, finance_document_id, note)
  values (p_id, o.id, d.id, nullif(trim(p_note), '')) returning * into k;
  perform private.purchase_event(o.id, 'gider_bagla', null, null, null,
                                 jsonb_build_object('finance_document_id', d.id, 'document_no', d.document_no));
  return k;
end;
$$;

create or replace function public.unlink_purchase_order_expense(p_id uuid, p_reason text)
returns public.purchase_order_expense_links
language plpgsql
security definer
set search_path = ''
as $$
declare
  k public.purchase_order_expense_links;
  o public.purchase_orders;
begin
  select * into k from public.purchase_order_expense_links where id = p_id for update;
  if found then
    select * into o from public.purchase_orders where id = k.order_id;
  end if;
  if k.id is null or not private.has_permission('satinalma.read', o.project_id) then
    raise exception 'Bağlantı bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('satinalma.write', o.project_id) then
    raise exception 'Bağlantıyı kaldırma yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if k.status = 'iptal' then
    return k;
  end if;
  if length(coalesce(trim(p_reason), '')) < 3 then
    raise exception 'Gerekçe zorunlu' using errcode = 'check_violation';
  end if;
  update public.purchase_order_expense_links
     set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = trim(p_reason)
   where id = k.id returning * into k;
  perform private.purchase_event(o.id, 'gider_bag_kaldir', null, null, p_reason,
                                 jsonb_build_object('finance_document_id', k.finance_document_id));
  return k;
end;
$$;

-- Siparişe arşiv belgesi bağlama (fatura, irsaliye...). Belge görünürlüğü
-- değişmez: belgeyi göremeyen kullanıcı bağlantıyı görse de dosyayı açamaz.
create or replace function public.link_purchase_order_document(p_id uuid, p_order_id uuid, p_document_id uuid)
returns public.purchase_order_documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.purchase_orders;
  k public.purchase_order_documents;
begin
  select * into o from public.purchase_orders where id = p_order_id;
  if not found or not private.can_see_purchase(o.project_id) then
    raise exception 'Sipariş bulunamadı' using errcode = 'no_data_found';
  end if;
  if not (private.has_permission('satinalma.write', o.project_id)
          or private.has_permission('satinalma.receive', o.project_id)) then
    raise exception 'Siparişe belge bağlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select * into k from public.purchase_order_documents where id = p_id;
  if found then
    if k.order_id = p_order_id and k.document_id = p_document_id and k.status = 'aktif' then
      return k;
    end if;
    raise exception 'Bu kimlikle farklı bir bağlantı var' using errcode = 'unique_violation';
  end if;
  if o.status = 'iptal' then
    raise exception 'İptal edilmiş siparişe belge bağlanamaz' using errcode = 'check_violation';
  end if;
  perform private.check_stock_document(p_document_id, o.project_id, o.is_demo);
  if exists (select 1 from public.purchase_order_documents x
              where x.order_id = o.id and x.document_id = p_document_id and x.status = 'aktif') then
    raise exception 'Bu belge siparişe zaten bağlı' using errcode = 'unique_violation';
  end if;
  insert into public.purchase_order_documents (id, order_id, document_id) values (p_id, o.id, p_document_id)
  returning * into k;
  perform private.purchase_event(o.id, 'belge_bagla', null, null, null, jsonb_build_object('document_id', p_document_id));
  return k;
end;
$$;

create or replace function public.unlink_purchase_order_document(p_id uuid, p_reason text)
returns public.purchase_order_documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  k public.purchase_order_documents;
  o public.purchase_orders;
begin
  select * into k from public.purchase_order_documents where id = p_id for update;
  if found then
    select * into o from public.purchase_orders where id = k.order_id;
  end if;
  if k.id is null or not private.can_see_purchase(o.project_id) then
    raise exception 'Bağlantı bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('satinalma.write', o.project_id) then
    raise exception 'Bağlantıyı kaldırma yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if k.status = 'iptal' then
    return k;
  end if;
  if length(coalesce(trim(p_reason), '')) < 3 then
    raise exception 'Gerekçe zorunlu' using errcode = 'check_violation';
  end if;
  update public.purchase_order_documents
     set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = trim(p_reason)
   where id = k.id returning * into k;
  perform private.purchase_event(o.id, 'belge_bag_kaldir', null, null, p_reason,
                                 jsonb_build_object('document_id', k.document_id));
  return k;
end;
$$;

-- Satır fiyatları (yalnızca satinalma.read). Bilgi amaçlıdır; borç doğurmaz.
create or replace function public.purchase_order_prices(p_order_id uuid)
returns table (order_line_id uuid, unit_price numeric, line_total numeric)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  o public.purchase_orders;
begin
  select * into o from public.purchase_orders where id = p_order_id;
  if not found or not private.has_permission('satinalma.read', o.project_id) then
    raise exception 'Sipariş fiyatlarını görme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  return query
    select l.id, l.unit_price, l.line_total from public.purchase_order_lines l
     where l.order_id = o.id and l.deleted_at is null order by l.line_no;
end;
$$;

-- -----------------------------------------------------------------------------
-- 13. API ayrıcalıkları (önceki tanım + bu aşamanın tabloları)
-- -----------------------------------------------------------------------------
create or replace function private.harden_api_privileges()
returns void
language plpgsql
set search_path = ''
as $$
begin
  revoke all on all tables    in schema public from anon;
  revoke all on all sequences in schema public from anon;
  revoke execute on all functions in schema public  from public, anon;
  revoke execute on all functions in schema private from public, anon;
  revoke execute on all functions in schema audit   from public, anon, authenticated;
  revoke truncate, references, trigger, delete on all tables in schema public from authenticated;

  -- İzin kataloğu yalnızca migration ile değişir.
  revoke insert, update on public.permissions from authenticated;
  -- Profil yalnızca Auth trigger'ı ile oluşur; e-posta ve telefon kapalı.
  revoke select, insert, update on public.profiles from authenticated;
  grant select (id, full_name, is_active, created_at, created_by, updated_at, updated_by, version)
    on public.profiles to authenticated;
  grant update (full_name, phone, is_active) on public.profiles to authenticated;

  -- Cari defter ve eşleştirmeler yalnızca RPC'lerle yazılır.
  revoke insert, update on public.cari_entries     from authenticated;
  revoke insert, update on public.cari_allocations from authenticated;

  -- Puantaj yalnızca RPC'lerle yazılır; durum tanımları migration ile değişir.
  revoke insert, update on public.puantaj_status_definitions from authenticated;
  revoke insert, update on public.puantaj_periods            from authenticated;
  revoke insert, update on public.puantaj_entries            from authenticated;
  revoke insert, update on public.puantaj_period_events      from authenticated;

  -- Sözleşme, imalat, hakediş, teminat ve ödeme yalnızca RPC'lerle yazılır.
  revoke insert, update on public.tax_rules              from authenticated;
  revoke insert, update on public.payment_sources        from authenticated;
  revoke insert, update on public.contracts              from authenticated;
  revoke insert, update on public.contract_versions      from authenticated;
  revoke insert, update on public.contract_items         from authenticated;
  revoke insert, update on public.contract_version_taxes from authenticated;
  revoke insert, update on public.work_quantities        from authenticated;
  revoke insert, update on public.hakedis                from authenticated;
  revoke insert, update on public.hakedis_lines          from authenticated;
  revoke insert, update on public.hakedis_quantity_links from authenticated;
  revoke insert, update on public.hakedis_puantaj_links  from authenticated;
  revoke insert, update on public.hakedis_adjustments    from authenticated;
  revoke insert, update on public.teminat_releases       from authenticated;
  revoke insert, update on public.finance_payments       from authenticated;
  revoke insert, update on public.finance_events         from authenticated;

  -- Gider, gelir, ödeme ve tahsilat yalnızca RPC'lerle yazılır.
  revoke insert, update on public.finance_categories      from authenticated;
  revoke insert, update on public.finance_documents       from authenticated;
  revoke insert, update on public.finance_settlements     from authenticated;
  revoke insert, update on public.finance_document_events from authenticated;

  -- Belge arşivi yalnızca RPC'lerle yazılır.
  revoke insert, update on public.documents       from authenticated;
  revoke insert, update on public.document_events from authenticated;
  -- Sunucu özeti yalnızca belge-dogrula Edge Function'ı (service_role) yazar.
  revoke execute on function public.record_document_server_hash(uuid, text, bigint) from authenticated;

  -- Malzeme, stok ve satın alma yalnızca RPC'lerle yazılır.
  revoke insert, update on public.material_units               from authenticated;
  revoke insert, update on public.material_categories          from authenticated;
  revoke insert, update on public.materials                    from authenticated;
  revoke insert, update on public.material_unit_conversions    from authenticated;
  revoke insert, update on public.warehouses                   from authenticated;
  revoke insert, update on public.stock_movements              from authenticated;
  revoke insert, update on public.stock_entries                from authenticated;
  revoke insert, update on public.purchase_orders              from authenticated;
  revoke insert, update on public.purchase_order_lines         from authenticated;
  revoke insert, update on public.purchase_receipts            from authenticated;
  revoke insert, update on public.purchase_receipt_lines       from authenticated;
  revoke insert, update on public.purchase_order_expense_links from authenticated;
  revoke insert, update on public.purchase_order_documents     from authenticated;
  revoke insert, update on public.purchase_order_events        from authenticated;
  -- Sipariş fiyatı yalnızca purchase_order_prices() ile (satinalma.read) okunur:
  -- teslim alan şantiye şefi miktarları görür, fiyatı görmez.
  revoke select on public.purchase_order_lines from authenticated;
  grant select (id, order_id, line_no, material_id, quantity, unit_id, unit_factor, base_quantity, note, deleted_at,
                created_at, created_by, updated_at, updated_by, version)
    on public.purchase_order_lines to authenticated;
end;
$$;
revoke execute on function private.harden_api_privileges() from public, anon, authenticated;

select private.harden_api_privileges();

grant execute on function public.save_material_unit(uuid, text, text, text, integer, integer, boolean) to authenticated;
grant execute on function public.save_material_category(uuid, text, integer, boolean) to authenticated;
grant execute on function public.save_material(uuid, text, uuid, uuid, text, text, boolean, integer) to authenticated;
grant execute on function public.save_material_unit_conversion(uuid, uuid, uuid, numeric, text) to authenticated;
grant execute on function public.set_material_unit_conversion_active(uuid, boolean) to authenticated;
grant execute on function public.save_warehouse(uuid, text, uuid, boolean, boolean, text, integer) to authenticated;
grant execute on function public.create_stock_movement(uuid, public.stock_movement_kind, uuid, uuid, numeric, uuid, uuid,
                                                       date, text, text, uuid, text) to authenticated;
grant execute on function public.approve_stock_movement(uuid, integer) to authenticated;
grant execute on function public.reject_stock_movement(uuid, text) to authenticated;
grant execute on function public.reverse_stock_movement(uuid, uuid, text) to authenticated;
grant execute on function public.stock_summary(uuid, date, date) to authenticated;
grant execute on function public.save_purchase_order(uuid, uuid, uuid, jsonb, date, date, text, text, text, integer)
  to authenticated;
grant execute on function public.purchase_order_transition(uuid, text, text, integer) to authenticated;
grant execute on function public.receive_purchase_order(uuid, uuid, jsonb, date, text, text, uuid, text) to authenticated;
grant execute on function public.cancel_purchase_receipt(uuid, text) to authenticated;
grant execute on function public.link_purchase_order_expense(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.unlink_purchase_order_expense(uuid, text) to authenticated;
grant execute on function public.link_purchase_order_document(uuid, uuid, uuid) to authenticated;
grant execute on function public.unlink_purchase_order_document(uuid, text) to authenticated;
grant execute on function public.purchase_order_prices(uuid) to authenticated;
grant select on public.v_stock_balances, public.v_stock_pending, public.v_purchase_order_line_status to authenticated;

-- -----------------------------------------------------------------------------
-- 14. İzinler ve rol şablonları (yönetici panelinden değiştirilebilir).
-- Şantiye şefi projesinde stok görür, giriş/kullanım hareketi hazırlar ve
-- onaylı siparişin malzemesini teslim alır; hareket onayı, sipariş onayı,
-- fiyatlar ve ödeme yetkisi verilmez.
-- -----------------------------------------------------------------------------
insert into public.permissions (key, module, description) values
  ('stok.read',         'stok',      'Depo stoklarını ve stok hareketlerini görüntüleme'),
  ('stok.write',        'stok',      'Stok hareketi hazırlama (giriş, kullanım, transfer, iade, sayım)'),
  ('stok.approve',      'stok',      'Stok hareketini onaylama (stoka işler) veya reddetme'),
  ('stok.cancel',       'stok',      'Onaylı stok hareketini ters kayıtla iptal etme, teslimi geri alma'),
  ('malzeme.manage',    'stok',      'Malzeme kataloğu, kategori, birim, dönüşüm oranı ve depo tanımlama'),
  ('satinalma.read',    'satinalma', 'Satın alma siparişlerini, fiyatları ve gider/belge bağlantılarını görüntüleme'),
  ('satinalma.write',   'satinalma', 'Satın alma siparişi hazırlama; gider ve belge bağlama'),
  ('satinalma.approve', 'satinalma', 'Satın alma siparişini onaylama ve eksik teslimle kapatma'),
  ('satinalma.receive', 'satinalma', 'Onaylı siparişin malzemesini teslim alma (fiyat görmeden)'),
  ('satinalma.cancel',  'satinalma', 'Onaylı satın alma siparişini iptal etme');

insert into public.role_permissions (role_id, permission_key)
select r.id, x.permission_key
  from (values
          ('muhasebe',      'stok.read'),
          ('muhasebe',      'malzeme.manage'),
          ('muhasebe',      'satinalma.read'),
          ('muhasebe',      'satinalma.write'),
          ('idari_isler',   'stok.read'),
          ('idari_isler',   'malzeme.manage'),
          ('proje_muduru',  'stok.read'),
          ('proje_muduru',  'stok.write'),
          ('proje_muduru',  'stok.approve'),
          ('proje_muduru',  'stok.cancel'),
          ('proje_muduru',  'satinalma.read'),
          ('proje_muduru',  'satinalma.write'),
          ('proje_muduru',  'satinalma.receive'),
          ('santiye_sefi',  'stok.read'),
          ('santiye_sefi',  'stok.write'),
          ('santiye_sefi',  'satinalma.receive'),
          ('goruntuleyici', 'stok.read')
       ) as x (role_key, permission_key)
  join public.roles r on r.key = x.role_key;
