-- =============================================================================
-- RD Yönetim · Aşama 5 · Şirket gider, gelir ve borç yönetimi
-- =============================================================================
-- Gider ve gelir "finans belgesi"dir (finance_documents, kind = gider | gelir).
-- Oluşma (taslak), onay (yükümlülük/alacak doğar) ve ödeme/tahsilat
-- (finance_settlements) ayrı olaylardır.
--
--   gider  : onayla → borcumuz oluşur; ödeme(ler) ile kapanır
--   gelir  : onayla → alacağımız oluşur; tahsilat(lar) ile kapanır
--
-- Cari bağlantısı olan belgede onay, mevcut cari deftere tek bir kaynak
-- hareketi yazar (source_type = 'finans_belge'; kaynak benzersizliği ile bir
-- kez). Ödeme/tahsilat ayrı bir cari hareketi açar ve belge hareketine
-- eşleştirilir. Cari bağlantısı olmayan küçük giderler cari deftere hiç
-- yazılmaz; borç ve ödeme yalnızca bu modülde izlenir.
--
-- Ödeme kaynağı (payment_sources: şirket, kart, kişi, diğer) yalnızca bilgidir.
-- Kişisel kartla yapılan ödeme gösterilir; kart sahibine kendiliğinden ikinci
-- borç (geri ödeme yükümlülüğü) açılmaz. Kasa, banka bakiyesi veya toplam
-- mevcut para tutulmaz.
--
-- Hakediş bu modüle hiç yazılmaz; proje maliyeti raporu hakedişi kendi
-- tablolarından ayrı satırlarda gösterir (çift sayım yok).
-- Önceki migration'lar değiştirilmez.
-- =============================================================================

create type public.finance_doc_kind   as enum ('gider', 'gelir');
create type public.finance_doc_status as enum ('taslak', 'onaylandi', 'iptal');

-- -----------------------------------------------------------------------------
-- Kategoriler: veri olarak tutulur ve uygulamadan genişletilir. Aşağıdaki
-- başlangıç listesi yalnızca ilk kurulum verisidir; kodda kategori yoktur.
-- -----------------------------------------------------------------------------
create table public.finance_categories (
  id         uuid primary key default gen_random_uuid(),
  kind       public.finance_doc_kind not null,
  name       text not null check (length(trim(name)) > 0),
  sort_order integer not null default 100,
  is_active  boolean not null default true
);
create unique index finance_categories_name_uq on public.finance_categories (kind, lower(name));
select private.add_row_meta('public.finance_categories');
select audit.enable('public.finance_categories');

insert into public.finance_categories (kind, name, sort_order) values
  ('gider', 'Demir', 10), ('gider', 'Beton', 20), ('gider', 'Kalıp', 30), ('gider', 'İşçilik', 40),
  ('gider', 'Hafriyat', 50), ('gider', 'Nakliye', 60), ('gider', 'Akaryakıt', 70), ('gider', 'Ekipman', 80),
  ('gider', 'Şantiye gideri', 90), ('gider', 'Ofis gideri', 100), ('gider', 'Resmi gider', 110),
  ('gider', 'Diğer', 900),
  ('gelir', 'Satış geliri', 10), ('gelir', 'Hizmet geliri', 20), ('gelir', 'Kira geliri', 30),
  ('gelir', 'Diğer', 900);

-- -----------------------------------------------------------------------------
-- Finans belgeleri (gider ve gelir)
-- -----------------------------------------------------------------------------
create sequence public.finance_document_no_seq;

create table public.finance_documents (
  id                 uuid primary key,  -- istemcide üretilir: tekrar gönderim çift kayıt açmaz
  kind               public.finance_doc_kind not null,
  document_no        text not null unique,
  status             public.finance_doc_status not null default 'taslak',
  project_id         uuid references public.projects (id) on delete restrict,
  cost_center_id     uuid references public.cost_centers (id) on delete restrict,
  category_id        uuid not null references public.finance_categories (id) on delete restrict,
  cari_account_id    uuid references public.cari_accounts (id) on delete restrict,
  description        text not null check (length(trim(description)) > 0),
  document_date      date not null,
  due_date           date not null,
  amount             numeric(14, 2) not null check (amount > 0),
  currency           char(3) not null default 'TRY' check (currency ~ '^[A-Z]{3}$'),
  exchange_rate      numeric(18, 6) not null default 1 check (exchange_rate > 0),
  amount_try         numeric(14, 2) generated always as (round(amount * exchange_rate, 2)) stored,
  invoice_no         text,
  document_ref       text,  -- belge referansı (dosya yükleme Aşama 6)
  notes              text,
  -- Sahada "peşin ödendi / tahsil edildi" bildirimi: onayda ödeme/tahsilat
  -- kaydına dönüşür. Bildirim tek başına ödeme değildir.
  reported_settled   boolean not null default false,
  reported_source_id uuid references public.payment_sources (id) on delete restrict,
  reported_by        text,
  approved_at        timestamptz,
  approved_by        uuid,
  cari_entry_id      uuid unique references public.cari_entries (id) on delete restrict,
  cancelled_at       timestamptz,
  cancelled_by       uuid,
  cancel_reason      text,
  replaces_id        uuid unique references public.finance_documents (id) on delete restrict,
  is_demo            boolean not null default false,
  constraint finance_documents_scope_ck check (num_nonnulls(project_id, cost_center_id) = 1),
  constraint finance_documents_try_rate_ck check (currency <> 'TRY' or exchange_rate = 1),
  constraint finance_documents_due_ck check (due_date >= document_date),
  constraint finance_documents_reported_ck check (
    (reported_settled and reported_source_id is not null)
    or (not reported_settled and reported_source_id is null and reported_by is null)),
  constraint finance_documents_approved_ck check ((status = 'taslak') = (approved_at is null) or status = 'iptal')
);
create index finance_documents_project_idx on public.finance_documents (project_id, document_date) where project_id is not null;
create index finance_documents_cost_center_idx on public.finance_documents (cost_center_id, document_date) where cost_center_id is not null;
create index finance_documents_cari_idx on public.finance_documents (cari_account_id) where cari_account_id is not null;
create index finance_documents_due_idx on public.finance_documents (kind, due_date) where status = 'onaylandi';
select private.add_row_meta('public.finance_documents');
select audit.enable('public.finance_documents');

-- Ödeme (gider) ve tahsilat (gelir). Para birimi belgeninkidir; kur her
-- işlemin kendi tarihindeki kurdur (TRY dışında zorunlu).
create table public.finance_settlements (
  id                uuid primary key,  -- istemcide üretilir
  document_id       uuid not null references public.finance_documents (id) on delete restrict,
  kind              text not null check (kind in ('odeme', 'tahsilat')),
  amount            numeric(14, 2) not null check (amount > 0),
  settlement_date   date not null,
  payment_source_id uuid not null references public.payment_sources (id) on delete restrict,
  settled_by        text,  -- ödemeyi yapan / tahsil eden kişi (bilgi)
  description       text,
  exchange_rate     numeric(18, 6) not null default 1 check (exchange_rate > 0),
  amount_try        numeric(14, 2) generated always as (round(amount * exchange_rate, 2)) stored,
  cari_entry_id     uuid unique references public.cari_entries (id) on delete restrict,
  status            text not null default 'aktif' check (status in ('aktif', 'iptal')),
  cancelled_at      timestamptz,
  cancelled_by      uuid,
  cancel_reason     text,
  is_demo           boolean not null default false
);
create index finance_settlements_document_idx on public.finance_settlements (document_id);
create index finance_settlements_source_idx on public.finance_settlements (payment_source_id, settlement_date);
select private.add_row_meta('public.finance_settlements');
select audit.enable('public.finance_settlements');

-- Değiştirilemez işlem geçmişi.
create table public.finance_document_events (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.finance_documents (id) on delete restrict,
  action      text not null,
  from_status text,
  to_status   text,
  reason      text,
  data        jsonb,
  actor_id    uuid default auth.uid(),
  occurred_at timestamptz not null default clock_timestamp()
);
create index finance_document_events_doc_idx on public.finance_document_events (document_id, occurred_at);
select private.add_row_meta('public.finance_document_events');
select audit.enable('public.finance_document_events');

create trigger finance_document_event_immutable before update or delete on public.finance_document_events
  for each row execute function private.tg_finance_event_immutable();

-- -----------------------------------------------------------------------------
-- Değişmezlik: onaylı/iptal belgenin tutar ve kapsamı, ödeme/tahsilatın
-- tutar ve hedefi değişmez (tablolar API'ye kapalı; ikinci savunma hattı).
-- -----------------------------------------------------------------------------
create or replace function private.tg_finance_document_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Finans belgesi silinemez; iptal edin' using errcode = 'insufficient_privilege';
  end if;
  if old.status <> 'taslak' and (
       new.kind is distinct from old.kind or new.amount is distinct from old.amount
       or new.currency is distinct from old.currency or new.exchange_rate is distinct from old.exchange_rate
       or new.project_id is distinct from old.project_id or new.cost_center_id is distinct from old.cost_center_id
       or new.cari_account_id is distinct from old.cari_account_id or new.document_date is distinct from old.document_date
       or new.due_date is distinct from old.due_date or new.category_id is distinct from old.category_id
       or new.description is distinct from old.description) then
    raise exception 'Onaylı veya iptal edilmiş belge değiştirilemez; iptal edip yeniden oluşturun'
      using errcode = 'check_violation';
  end if;
  if old.status = 'iptal' and new.status <> 'iptal' then
    raise exception 'İptal edilmiş belge yeniden açılamaz' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger finance_document_guard before update or delete on public.finance_documents
  for each row execute function private.tg_finance_document_guard();

create or replace function private.tg_finance_settlement_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Ödeme/tahsilat silinemez; iptal edin' using errcode = 'insufficient_privilege';
  end if;
  if new.amount is distinct from old.amount or new.document_id is distinct from old.document_id
     or new.exchange_rate is distinct from old.exchange_rate or new.settlement_date is distinct from old.settlement_date
     or new.payment_source_id is distinct from old.payment_source_id or new.kind is distinct from old.kind
     or (old.status = 'iptal' and new.status <> 'iptal') then
    raise exception 'Ödeme/tahsilat değiştirilemez; iptal edip yeniden kaydedin' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger finance_settlement_guard before update or delete on public.finance_settlements
  for each row execute function private.tg_finance_settlement_guard();

-- -----------------------------------------------------------------------------
-- Yetki yardımcıları
-- -----------------------------------------------------------------------------
-- Belge türü + işlem → izin anahtarı (read, write, approve, settle).
create or replace function private.fin_doc_permission(p_kind public.finance_doc_kind, p_action text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_action = 'settle' then case p_kind when 'gider' then 'gider.pay' else 'gelir.collect' end
           else p_kind::text || '.' || p_action
         end;
$$;

create or replace function private.can_fin_doc(p_kind public.finance_doc_kind, p_action text, p_project uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_permission(private.fin_doc_permission(p_kind, p_action), p_project);
$$;

-- Belgeyi görebilir mi: tür okuma izni ya da kendi girdiği belge (yazma izni
-- sürdükçe). Şantiye şefi yalnızca kendi girdiği giderleri görür.
create or replace function private.can_read_fin_doc(p_kind public.finance_doc_kind, p_project uuid, p_created_by uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.can_fin_doc(p_kind, 'read', p_project)
      or (p_created_by = (select auth.uid()) and private.can_fin_doc(p_kind, 'write', p_project));
$$;

grant execute on function private.fin_doc_permission(public.finance_doc_kind, text) to authenticated;
grant execute on function private.can_fin_doc(public.finance_doc_kind, text, uuid) to authenticated;
grant execute on function private.can_read_fin_doc(public.finance_doc_kind, uuid, uuid) to authenticated;

create or replace function private.fin_doc_event(p_doc uuid, p_action text, p_from text, p_to text,
                                                 p_reason text default null, p_data jsonb default null)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.finance_document_events (document_id, action, from_status, to_status, reason, data)
  values (p_doc, p_action, p_from, p_to, nullif(trim(p_reason), ''), p_data);
$$;
revoke execute on function private.fin_doc_event(uuid, text, text, text, text, jsonb) from public, anon, authenticated;

-- Belgenin etkin ödeme/tahsilat toplamı.
create or replace function private.fin_doc_settled(p_doc uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(s.amount), 0) from public.finance_settlements s
   where s.document_id = p_doc and s.status = 'aktif';
$$;
revoke execute on function private.fin_doc_settled(uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.finance_categories      enable row level security;
alter table public.finance_documents       enable row level security;
alter table public.finance_settlements     enable row level security;
alter table public.finance_document_events enable row level security;

create policy finance_categories_select on public.finance_categories
  for select to authenticated using (private.is_active_user());
create policy finance_documents_select on public.finance_documents
  for select to authenticated using (private.can_read_fin_doc(kind, project_id, created_by));
create policy finance_settlements_select on public.finance_settlements
  for select to authenticated
  using (exists (select 1 from public.finance_documents d where d.id = document_id));
create policy finance_document_events_select on public.finance_document_events
  for select to authenticated
  using (exists (select 1 from public.finance_documents d where d.id = document_id));

-- Belgenin ödeme durumu (security_invoker: yalnızca görülebilen belgeler).
create or replace view public.v_finance_document_status
with (security_invoker = true)
as
select d.id as document_id,
       d.kind,
       d.status,
       d.amount,
       d.currency,
       coalesce(s.settled, 0)            as settled_amount,
       coalesce(s.settled_try, 0)        as settled_try,
       case when d.status = 'onaylandi' then d.amount - coalesce(s.settled, 0) else 0 end as remaining_amount,
       case when d.status = 'onaylandi' then round((d.amount - coalesce(s.settled, 0)) * d.exchange_rate, 2) else 0 end
                                         as remaining_try,
       case
         when d.status = 'iptal'                 then 'iptal'
         when d.status = 'taslak'                then 'taslak'
         when coalesce(s.settled, 0) = 0         then 'acik'
         when coalesce(s.settled, 0) < d.amount  then 'kismi'
         else 'kapandi'
       end                               as settlement_status,
       d.due_date,
       (d.status = 'onaylandi' and coalesce(s.settled, 0) < d.amount and d.due_date < private.today()) as is_overdue,
       greatest(private.today() - d.due_date, 0) as days_overdue
  from public.finance_documents d
  left join lateral (
         select sum(x.amount) as settled, sum(x.amount_try) as settled_try
           from public.finance_settlements x
          where x.document_id = d.id and x.status = 'aktif') s on true;

-- -----------------------------------------------------------------------------
-- Kategori yönetimi
-- -----------------------------------------------------------------------------
create or replace function public.save_finance_category(
  p_id uuid, p_kind public.finance_doc_kind, p_name text, p_sort_order integer default 100,
  p_is_active boolean default true)
returns public.finance_categories
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.finance_categories;
begin
  if not private.has_permission('finans_kategori.manage', null) then
    raise exception 'Kategori tanımlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if length(coalesce(trim(p_name), '')) = 0 then
    raise exception 'Kategori adı zorunlu' using errcode = 'check_violation';
  end if;
  select * into v_row from public.finance_categories where id = p_id;
  if found and v_row.kind <> p_kind then
    raise exception 'Kategorinin türü değiştirilemez' using errcode = 'check_violation';
  end if;
  insert into public.finance_categories (id, kind, name, sort_order, is_active)
  values (coalesce(p_id, gen_random_uuid()), p_kind, trim(p_name), coalesce(p_sort_order, 100), coalesce(p_is_active, true))
  on conflict (id) do update set name = excluded.name, sort_order = excluded.sort_order, is_active = excluded.is_active
  returning * into v_row;
  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- Belge kaydı: yeni belge (taslak) veya taslağın güncellenmesi.
--   p_expected_version boş + kimlik var → tekrar gönderim: içerik aynıysa
--   mevcut belge döner, farklıysa 23505.
--   p_expected_version dolu → taslak güncellenir (sürüm eşleşmeli, 40001).
-- -----------------------------------------------------------------------------
create or replace function public.save_finance_document(
  p_id                 uuid,
  p_kind               public.finance_doc_kind,
  p_category_id        uuid,
  p_description        text,
  p_amount             numeric,
  p_document_date      date,
  p_project_id         uuid    default null,
  p_cost_center_id     uuid    default null,
  p_due_date           date    default null,
  p_currency           text    default 'TRY',
  p_exchange_rate      numeric default null,
  p_cari_account_id    uuid    default null,
  p_invoice_no         text    default null,
  p_document_ref       text    default null,
  p_notes              text    default null,
  p_reported_settled   boolean default false,
  p_reported_source_id uuid    default null,
  p_reported_by        text    default null,
  p_expected_version   integer default null)
returns public.finance_documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  d        public.finance_documents;
  v_cur    text := upper(coalesce(nullif(trim(p_currency), ''), 'TRY'));
  v_rate   numeric;
  v_demo   boolean;
  v_due    date := coalesce(p_due_date, p_document_date);
  v_src    uuid := case when coalesce(p_reported_settled, false) then p_reported_source_id end;
  v_by     text := case when coalesce(p_reported_settled, false) then nullif(trim(p_reported_by), '') end;
begin
  if p_kind is null or num_nonnulls(p_project_id, p_cost_center_id) <> 1 then
    raise exception 'Belge bir projeye veya bir genel masraf merkezine bağlanmalı' using errcode = 'check_violation';
  end if;
  if not private.can_fin_doc(p_kind, 'write', p_project_id) then
    raise exception 'Bu kapsamda % kaydetme yetkiniz yok', p_kind using errcode = 'insufficient_privilege';
  end if;

  -- Kapsam ve DEMO işareti
  if p_project_id is not null then
    select pr.is_demo into v_demo from public.projects pr where pr.id = p_project_id and pr.deleted_at is null;
    if not found then
      raise exception 'Proje bulunamadı' using errcode = 'foreign_key_violation';
    end if;
  else
    select cc.is_demo into v_demo from public.cost_centers cc
     where cc.id = p_cost_center_id and cc.deleted_at is null and cc.is_active;
    if not found then
      raise exception 'Masraf merkezi bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
  end if;

  -- Doğrulama
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Tutar pozitif ve en çok iki ondalıklı olmalı' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_description), '')) = 0 then
    raise exception 'Açıklama zorunlu' using errcode = 'check_violation';
  end if;
  if p_document_date is null then
    raise exception 'Tarih zorunlu' using errcode = 'check_violation';
  end if;
  if v_due < p_document_date then
    raise exception 'Vade tarihi belge tarihinden önce olamaz' using errcode = 'check_violation';
  end if;
  if v_cur !~ '^[A-Z]{3}$' then
    raise exception 'Para birimi üç harfli kod olmalı' using errcode = 'check_violation';
  end if;
  v_rate := private.resolve_exchange_rate(v_cur, p_exchange_rate);
  if not exists (select 1 from public.finance_categories k where k.id = p_category_id and k.kind = p_kind and k.is_active) then
    raise exception 'Kategori bulunamadı, pasif veya bu türe ait değil' using errcode = 'foreign_key_violation';
  end if;
  if p_cari_account_id is not null then
    if not exists (select 1 from public.cari_accounts c
                    where c.id = p_cari_account_id and c.deleted_at is null and c.is_active) then
      raise exception 'Cari hesap bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
    if (select c.is_demo from public.cari_accounts c where c.id = p_cari_account_id) is distinct from v_demo then
      raise exception 'Demo kayıtlar gerçek kayıtlarla aynı belgede kullanılamaz' using errcode = 'check_violation';
    end if;
  end if;
  if coalesce(p_reported_settled, false)
     and not exists (select 1 from public.payment_sources s where s.id = v_src and s.is_active) then
    raise exception 'Peşin ödeme/tahsilat için ödeme kaynağı seçilmeli' using errcode = 'check_violation';
  end if;

  select * into d from public.finance_documents where id = p_id for update;
  if found then
    if p_expected_version is null then
      -- Tekrar gönderim: saklanan biçimde karşılaştır.
      if d.kind = p_kind and d.category_id = p_category_id and d.description = trim(p_description)
         and d.amount = p_amount and d.document_date = p_document_date and d.due_date = v_due
         and d.project_id is not distinct from p_project_id and d.cost_center_id is not distinct from p_cost_center_id
         and d.currency = v_cur and d.exchange_rate = v_rate
         and d.cari_account_id is not distinct from p_cari_account_id
         and d.invoice_no is not distinct from nullif(trim(p_invoice_no), '')
         and d.reported_settled = coalesce(p_reported_settled, false)
         and d.reported_source_id is not distinct from v_src then
        return d;
      end if;
      raise exception 'Bu kimlikle farklı bir belge var' using errcode = 'unique_violation';
    end if;
    if d.kind <> p_kind then
      raise exception 'Belge türü değiştirilemez' using errcode = 'check_violation';
    end if;
    if d.status <> 'taslak' then
      raise exception 'Yalnızca taslak belge düzenlenir; onaylı belge iptal edilip yeniden oluşturulur'
        using errcode = 'check_violation';
    end if;
    if d.version <> p_expected_version then
      raise exception 'Belge başka biri tarafından değiştirildi; yenileyip tekrar deneyin' using errcode = 'serialization_failure';
    end if;
    -- Eski kapsamda da yazma izni gerekir (başka projeye taşıma).
    if not private.can_fin_doc(d.kind, 'write', d.project_id) then
      raise exception 'Bu belgeyi düzenleme yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if d.is_demo is distinct from v_demo then
      raise exception 'Demo belge gerçek kapsama taşınamaz (veya tersi)' using errcode = 'check_violation';
    end if;
    update public.finance_documents
       set category_id = p_category_id, description = trim(p_description), amount = p_amount,
           document_date = p_document_date, due_date = v_due, project_id = p_project_id,
           cost_center_id = p_cost_center_id, currency = v_cur, exchange_rate = v_rate,
           cari_account_id = p_cari_account_id, invoice_no = nullif(trim(p_invoice_no), ''),
           document_ref = nullif(trim(p_document_ref), ''), notes = nullif(trim(p_notes), ''),
           reported_settled = coalesce(p_reported_settled, false), reported_source_id = v_src, reported_by = v_by
     where id = d.id
    returning * into d;
    perform private.fin_doc_event(d.id, 'guncelle', 'taslak', 'taslak', null,
                                  jsonb_build_object('amount', d.amount, 'currency', d.currency));
    return d;
  end if;

  insert into public.finance_documents (id, kind, document_no, project_id, cost_center_id, category_id, cari_account_id,
                                        description, document_date, due_date, amount, currency, exchange_rate,
                                        invoice_no, document_ref, notes, reported_settled, reported_source_id,
                                        reported_by, is_demo)
  values (p_id, p_kind,
          case p_kind when 'gider' then 'GD-' else 'GL-' end || lpad(nextval('public.finance_document_no_seq')::text, 6, '0'),
          p_project_id, p_cost_center_id, p_category_id, p_cari_account_id, trim(p_description), p_document_date, v_due,
          p_amount, v_cur, v_rate, nullif(trim(p_invoice_no), ''), nullif(trim(p_document_ref), ''),
          nullif(trim(p_notes), ''), coalesce(p_reported_settled, false), v_src, v_by, v_demo)
  returning * into d;
  perform private.fin_doc_event(d.id, 'olustur', null, 'taslak', null,
                                jsonb_build_object('amount', d.amount, 'currency', d.currency,
                                                   'reported_settled', d.reported_settled));
  return d;
end;
$$;

-- -----------------------------------------------------------------------------
-- Ödeme / tahsilat (iç işlem; yetki ve kilit çağıranda).
-- -----------------------------------------------------------------------------
create or replace function private.fin_settle(
  d public.finance_documents, p_id uuid, p_amount numeric, p_source uuid, p_date date, p_by text,
  p_description text, p_rate numeric)
returns public.finance_settlements
language plpgsql
security definer
set search_path = ''
as $$
declare
  s        public.finance_settlements;
  v_rate   numeric;
  v_open   numeric;
  v_entry  uuid;
  v_kind   text := case d.kind when 'gider' then 'odeme' else 'tahsilat' end;
begin
  if d.status <> 'onaylandi' then
    raise exception 'Ödeme/tahsilat yalnızca onaylı belgeye kaydedilir' using errcode = 'check_violation';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Tutar pozitif ve en çok iki ondalıklı olmalı' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.payment_sources x where x.id = p_source and x.is_active) then
    raise exception 'Ödeme kaynağı bulunamadı veya pasif' using errcode = 'foreign_key_violation';
  end if;
  v_rate := private.resolve_exchange_rate(d.currency, p_rate);
  v_open := d.amount - private.fin_doc_settled(d.id);
  if p_amount > v_open then
    raise exception 'Tutar kalan tutarı aşıyor (kalan %)', v_open using errcode = 'check_violation';
  end if;

  if d.cari_entry_id is not null then
    v_entry := gen_random_uuid();
    insert into public.cari_entries (id, cari_account_id, project_id, cost_center_id, entry_date, direction, kind,
                                     amount, currency, exchange_rate, description, document_no, source_type, source_id)
    values (v_entry, d.cari_account_id, d.project_id, d.cost_center_id, p_date,
            case d.kind when 'gider' then 'borc'::public.cari_direction else 'alacak'::public.cari_direction end,
            v_kind::public.cari_entry_kind, p_amount, d.currency, v_rate,
            coalesce(nullif(trim(p_description), ''), case d.kind when 'gider' then 'Ödeme · ' else 'Tahsilat · ' end || d.description),
            coalesce(d.invoice_no, d.document_no), 'finans_belge_islem', p_id);
  end if;

  insert into public.finance_settlements (id, document_id, kind, amount, settlement_date, payment_source_id, settled_by,
                                          description, exchange_rate, cari_entry_id, is_demo)
  values (p_id, d.id, v_kind, p_amount, p_date, p_source, nullif(trim(p_by), ''), nullif(trim(p_description), ''),
          v_rate, v_entry, d.is_demo)
  returning * into s;

  if v_entry is not null then
    insert into public.cari_allocations (payment_entry_id, target_entry_id, amount, note)
    values (v_entry, d.cari_entry_id, p_amount, case d.kind when 'gider' then 'Gider ödemesi' else 'Gelir tahsilatı' end);
  end if;
  perform private.fin_doc_event(d.id, v_kind, d.status::text, d.status::text, null,
                                jsonb_build_object('settlement_id', p_id, 'amount', p_amount, 'payment_source_id', p_source,
                                                   'date', p_date, 'exchange_rate', v_rate, 'settled_by', nullif(trim(p_by), '')));
  return s;
end;
$$;
revoke execute on function private.fin_settle(public.finance_documents, uuid, numeric, uuid, date, text, text, numeric)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Onay: yükümlülük/alacak doğar. Cari bağlantılıysa deftere bir kez yazılır.
-- Peşin ödendi/tahsil edildi bildirilmişse aynı işlemde tam tutar için
-- ödeme/tahsilat kaydı açılır (onaylayanın ödeme yetkisi de olmalı).
-- Tekrar çağrı aynı sonucu döner.
-- -----------------------------------------------------------------------------
create or replace function public.approve_finance_document(
  p_id uuid, p_expected_version integer default null, p_settlement_id uuid default null)
returns public.finance_documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  d       public.finance_documents;
  v_entry uuid;
begin
  select * into d from public.finance_documents where id = p_id;
  if not found or not private.can_read_fin_doc(d.kind, d.project_id, d.created_by) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.can_fin_doc(d.kind, 'approve', d.project_id) then
    raise exception 'Belge onaylama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select * into d from public.finance_documents where id = p_id for update;
  if d.status = 'onaylandi' then
    return d;  -- tekrar onay ikinci yükümlülük açmaz
  end if;
  if d.status <> 'taslak' then
    raise exception 'İptal edilmiş belge onaylanamaz' using errcode = 'check_violation';
  end if;
  if p_expected_version is not null and d.version <> p_expected_version then
    raise exception 'Belge onaydan önce değişti; yenileyip tekrar inceleyin' using errcode = 'serialization_failure';
  end if;
  if d.reported_settled and not private.can_fin_doc(d.kind, 'settle', d.project_id) then
    raise exception 'Peşin ödenmiş/tahsil edilmiş belgeyi onaylamak için ödeme/tahsilat yetkisi de gerekir'
      using errcode = 'insufficient_privilege';
  end if;

  if d.cari_account_id is not null then
    v_entry := gen_random_uuid();
    insert into public.cari_entries (id, cari_account_id, project_id, cost_center_id, entry_date, direction, kind,
                                     amount, currency, exchange_rate, description, document_no, source_type, source_id)
    values (v_entry, d.cari_account_id, d.project_id, d.cost_center_id, d.document_date,
            case d.kind when 'gider' then 'alacak'::public.cari_direction else 'borc'::public.cari_direction end,
            case d.kind when 'gider' then 'gider'::public.cari_entry_kind else 'fatura'::public.cari_entry_kind end,
            d.amount, d.currency, d.exchange_rate, d.description, coalesce(d.invoice_no, d.document_no),
            'finans_belge', d.id);
  end if;

  update public.finance_documents
     set status = 'onaylandi', approved_at = now(), approved_by = auth.uid(), cari_entry_id = v_entry
   where id = d.id
  returning * into d;
  perform private.fin_doc_event(d.id, 'onayla', 'taslak', 'onaylandi', null,
                                jsonb_build_object('amount', d.amount, 'currency', d.currency,
                                                   'exchange_rate', d.exchange_rate, 'cari_entry_id', v_entry));

  if d.reported_settled then
    perform private.fin_settle(d, coalesce(p_settlement_id, gen_random_uuid()), d.amount, d.reported_source_id,
                               d.document_date, d.reported_by, 'Peşin ' ||
                               case d.kind when 'gider' then 'ödendi (sahadan bildirildi)' else 'tahsil edildi' end,
                               d.exchange_rate);
  end if;
  return d;
end;
$$;

-- -----------------------------------------------------------------------------
-- Ödeme / tahsilat kaydı. Aynı kimlik ancak aynı belge, tutar, kaynak, tarih
-- ve kurla gelirse aynı kaydı döner; aksi halde 23505.
-- -----------------------------------------------------------------------------
create or replace function public.record_finance_settlement(
  p_id uuid, p_document_id uuid, p_amount numeric, p_payment_source_id uuid,
  p_settlement_date date default null, p_settled_by text default null, p_description text default null,
  p_exchange_rate numeric default null)
returns public.finance_settlements
language plpgsql
security definer
set search_path = ''
as $$
declare
  d      public.finance_documents;
  s      public.finance_settlements;
  v_date date := coalesce(p_settlement_date, private.today());
begin
  select * into d from public.finance_documents where id = p_document_id;
  if not found or not private.can_read_fin_doc(d.kind, d.project_id, d.created_by) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.can_fin_doc(d.kind, 'settle', d.project_id) then
    raise exception 'Ödeme/tahsilat kaydetme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  -- Kilit tekrar kontrolünden önce: eşzamanlı iki ödeme sıraya girer.
  select * into d from public.finance_documents where id = p_document_id for update;

  select * into s from public.finance_settlements where id = p_id;
  if found then
    if s.document_id = p_document_id and s.amount = p_amount and s.payment_source_id = p_payment_source_id
       and s.settlement_date = coalesce(p_settlement_date, s.settlement_date)
       and s.exchange_rate = private.resolve_exchange_rate(d.currency, p_exchange_rate) then
      return s;
    end if;
    raise exception 'Bu kimlikle farklı bir ödeme/tahsilat var (belge, tutar, kaynak, tarih veya kur farklı)'
      using errcode = 'unique_violation';
  end if;
  return private.fin_settle(d, p_id, p_amount, p_payment_source_id, v_date, p_settled_by, p_description, p_exchange_rate);
end;
$$;

create or replace function public.cancel_finance_settlement(p_id uuid, p_reason text)
returns public.finance_settlements
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.finance_settlements;
  d public.finance_documents;
begin
  select * into s from public.finance_settlements where id = p_id;
  if found then
    select * into d from public.finance_documents where id = s.document_id;
  end if;
  if not found or not private.can_fin_doc(d.kind, 'settle', d.project_id) then
    raise exception 'Ödeme/tahsilat bulunamadı veya yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  perform 1 from public.finance_documents where id = d.id for update;
  select * into s from public.finance_settlements where id = p_id for update;
  if s.status = 'iptal' then
    return s;
  end if;
  if length(coalesce(trim(p_reason), '')) < 10 then
    raise exception 'İptal gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;
  if s.cari_entry_id is not null then
    perform private.fin_reverse_entry(s.cari_entry_id, p_reason);
  end if;
  update public.finance_settlements
     set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = trim(p_reason)
   where id = s.id
  returning * into s;
  perform private.fin_doc_event(d.id, s.kind || '_iptal', d.status::text, d.status::text, p_reason,
                                jsonb_build_object('settlement_id', s.id, 'amount', s.amount));
  return s;
end;
$$;

-- -----------------------------------------------------------------------------
-- İptal. Taslak: yazma yetkisi; onaylı: onay yetkisi ve etkin ödeme/tahsilat
-- olmamalı (önce onlar iptal edilir). Cari hareket ters kayıtla kapatılır.
-- -----------------------------------------------------------------------------
create or replace function private.fin_doc_cancel(d public.finance_documents, p_reason text)
returns public.finance_documents
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.finance_settlements s where s.document_id = d.id and s.status = 'aktif') then
    raise exception 'Ödemesi/tahsilatı olan belge iptal edilemez; önce ödeme/tahsilatı iptal edin'
      using errcode = 'check_violation';
  end if;
  if d.cari_entry_id is not null then
    perform private.fin_reverse_entry(d.cari_entry_id, p_reason);
  end if;
  update public.finance_documents
     set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = trim(p_reason)
   where id = d.id
  returning * into d;
  return d;
end;
$$;
revoke execute on function private.fin_doc_cancel(public.finance_documents, text) from public, anon, authenticated;

create or replace function public.cancel_finance_document(p_id uuid, p_reason text)
returns public.finance_documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  d      public.finance_documents;
  v_from text;
begin
  select * into d from public.finance_documents where id = p_id;
  if not found or not private.can_read_fin_doc(d.kind, d.project_id, d.created_by) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  select * into d from public.finance_documents where id = p_id for update;
  if d.status = 'iptal' then
    return d;
  end if;
  if d.status = 'taslak' then
    if not private.can_fin_doc(d.kind, 'write', d.project_id) then
      raise exception 'Belgeyi iptal etme yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if length(coalesce(trim(p_reason), '')) < 3 then
      raise exception 'İptal gerekçesi en az 3 karakter olmalı' using errcode = 'check_violation';
    end if;
  else
    if not private.can_fin_doc(d.kind, 'approve', d.project_id) then
      raise exception 'Onaylı belgeyi iptal etmek için onay yetkisi gerekir' using errcode = 'insufficient_privilege';
    end if;
    if length(coalesce(trim(p_reason), '')) < 10 then
      raise exception 'İptal gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
    end if;
  end if;
  v_from := d.status::text;
  d := private.fin_doc_cancel(d, p_reason);
  perform private.fin_doc_event(d.id, 'iptal', v_from, 'iptal', p_reason);
  return d;
end;
$$;

-- Düzeltme: onaylı belge iptal edilir (ters kayıtla), alanları kopyalanarak
-- replaces_id ile yeni taslak açılır. Ödemesi olan belgede önce ödemeler
-- iptal edilmelidir. Tekrar çağrı aynı yeni taslağı döner.
create or replace function public.revise_finance_document(p_id uuid, p_new_id uuid, p_reason text)
returns public.finance_documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.finance_documents;
  n public.finance_documents;
begin
  select * into d from public.finance_documents where id = p_id;
  if not found or not private.can_read_fin_doc(d.kind, d.project_id, d.created_by) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.can_fin_doc(d.kind, 'approve', d.project_id) or not private.can_fin_doc(d.kind, 'write', d.project_id) then
    raise exception 'Belge düzeltme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select * into d from public.finance_documents where id = p_id for update;
  select * into n from public.finance_documents where replaces_id = d.id;
  if found then
    if n.id = p_new_id then
      return n;
    end if;
    raise exception 'Bu belge zaten düzeltilmiş' using errcode = 'unique_violation';
  end if;
  if d.status <> 'onaylandi' then
    raise exception 'Yalnızca onaylı belge düzeltilir; taslak doğrudan düzenlenir' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_reason), '')) < 10 then
    raise exception 'Düzeltme gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;
  d := private.fin_doc_cancel(d, p_reason);
  perform private.fin_doc_event(d.id, 'duzelt', 'onaylandi', 'iptal', p_reason, jsonb_build_object('new_id', p_new_id));
  insert into public.finance_documents (id, kind, document_no, project_id, cost_center_id, category_id, cari_account_id,
                                        description, document_date, due_date, amount, currency, exchange_rate,
                                        invoice_no, document_ref, notes, replaces_id, is_demo)
  values (p_new_id, d.kind,
          case d.kind when 'gider' then 'GD-' else 'GL-' end || lpad(nextval('public.finance_document_no_seq')::text, 6, '0'),
          d.project_id, d.cost_center_id, d.category_id, d.cari_account_id, d.description, d.document_date, d.due_date,
          d.amount, d.currency, d.exchange_rate, d.invoice_no, d.document_ref, d.notes, d.id, d.is_demo)
  returning * into n;
  perform private.fin_doc_event(n.id, 'olustur', null, 'taslak', p_reason, jsonb_build_object('replaces_id', d.id));
  return n;
end;
$$;

-- -----------------------------------------------------------------------------
-- Raporlar. Tutarlar TL karşılığıdır (amount_try). Dövizli belgede kalan =
-- kalan tutar × belge kuru; ödemeler kendi kurlarıyla. Kur farkı hesaplanmaz.
-- Satırlar yalnızca kullanıcının tür okuma ve finans_rapor.read izni olduğu
-- kapsamlardan gelir.
--
-- p_group: proje | kategori | cari | ay | kaynak
--   accrued_try : onaylı belgeler (belge tarihi dönem içinde)
--   settled_try : bu belgelerin etkin ödeme/tahsilatları
--   open_try    : kalan (onaylı belge kuruyla)
--   overdue_try : vadesi geçmiş kalan
--   kaynak grubunda yalnızca dönem içindeki ödeme/tahsilatlar (settled_try).
-- -----------------------------------------------------------------------------
create or replace function public.finance_report(
  p_kind public.finance_doc_kind, p_group text, p_from date default null, p_to date default null,
  p_project_id uuid default null, p_cost_center_id uuid default null)
returns table (
  group_key      text,
  label          text,
  document_count integer,
  accrued_try    numeric,
  settled_try    numeric,
  open_try       numeric,
  overdue_try    numeric)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_group not in ('proje', 'kategori', 'cari', 'ay', 'kaynak') then
    raise exception 'Geçersiz rapor grubu: %', p_group using errcode = 'invalid_parameter_value';
  end if;
  if not private.is_active_user() then
    raise exception 'Oturum gerekli' using errcode = 'insufficient_privilege';
  end if;

  if p_group = 'kaynak' then
    return query
    select ps.id::text, ps.name, count(distinct d.id)::integer, 0::numeric,
           coalesce(sum(s.amount_try), 0), 0::numeric, 0::numeric
      from public.finance_settlements s
      join public.finance_documents d on d.id = s.document_id
      join public.payment_sources ps on ps.id = s.payment_source_id
     where d.kind = p_kind and s.status = 'aktif'
       and (p_from is null or s.settlement_date >= p_from) and (p_to is null or s.settlement_date <= p_to)
       and (p_project_id is null or d.project_id = p_project_id)
       and (p_cost_center_id is null or d.cost_center_id = p_cost_center_id)
       and private.can_fin_doc(d.kind, 'read', d.project_id)
       and private.has_permission('finans_rapor.read', d.project_id)
     group by ps.id, ps.name
     order by 5 desc;
    return;
  end if;

  return query
  with docs as (
    select d.*, st.settled_try, st.remaining_try, st.is_overdue
      from public.finance_documents d
      join lateral (
        select coalesce(sum(x.amount_try), 0) as settled_try,
               round((d.amount - coalesce(sum(x.amount), 0)) * d.exchange_rate, 2) as remaining_try,
               (coalesce(sum(x.amount), 0) < d.amount and d.due_date < private.today()) as is_overdue
          from public.finance_settlements x where x.document_id = d.id and x.status = 'aktif') st on true
     where d.kind = p_kind and d.status = 'onaylandi'
       and (p_from is null or d.document_date >= p_from) and (p_to is null or d.document_date <= p_to)
       and (p_project_id is null or d.project_id = p_project_id)
       and (p_cost_center_id is null or d.cost_center_id = p_cost_center_id)
       and private.can_fin_doc(d.kind, 'read', d.project_id)
       and private.has_permission('finans_rapor.read', d.project_id)
  ),
  keyed as (
    select case p_group
             when 'proje'    then coalesce(dc.project_id, dc.cost_center_id)::text
             when 'kategori' then dc.category_id::text
             when 'cari'     then coalesce(dc.cari_account_id::text, '-')
             else to_char(dc.document_date, 'YYYY-MM')
           end as k,
           case p_group
             when 'proje'    then coalesce((select pr.code || ' · ' || pr.name from public.projects pr where pr.id = dc.project_id),
                                           (select 'Genel · ' || cc.name from public.cost_centers cc where cc.id = dc.cost_center_id))
             when 'kategori' then (select fc.name from public.finance_categories fc where fc.id = dc.category_id)
             when 'cari'     then coalesce((select ca.title from public.cari_accounts ca where ca.id = dc.cari_account_id),
                                           'Cari bağlantısız')
             else to_char(dc.document_date, 'YYYY-MM')
           end as l,
           dc.*
      from docs dc
  )
  select kd.k, min(kd.l), count(*)::integer, sum(kd.amount_try), sum(kd.settled_try), sum(kd.remaining_try),
         coalesce(sum(kd.remaining_try) filter (where kd.is_overdue), 0)
    from keyed kd
   group by kd.k
   order by case when p_group = 'ay' then kd.k end, 4 desc;
end;
$$;

-- Proje maliyeti: gider, hakediş ve gelir ayrı sütunlarda. Hakediş bu
-- modüle yazılmadığından ikinci kez sayılmaz. Hakediş sütunları yalnızca
-- hakedis.read izni olan kullanıcıya dolu gelir (diğerlerine boş).
--   hakedis_accrued_try : deftere işlenmiş hakediş alacakları (brüt + KDV), iptaller hariç
--   hakedis_unposted    : onaylı, deftere işlenmemiş TL hakedişlerin brüt + KDV'si
--   hakedis_paid_try    : hakedişlere yapılan etkin ödemeler
--   advance_paid_try    : verilen etkin avanslar (ödeme sayılmaz)
--   advance_deducted_try: deftere işlenmiş hakedişlerde mahsup edilen avans
create or replace function public.project_cost_report(p_project_id uuid default null)
returns table (
  project_id           uuid,
  project_label        text,
  expense_accrued_try  numeric,
  expense_paid_try     numeric,
  expense_open_try     numeric,
  hakedis_accrued_try  numeric,
  hakedis_unposted_try numeric,
  hakedis_paid_try     numeric,
  advance_paid_try     numeric,
  advance_deducted_try numeric,
  income_accrued_try   numeric,
  income_collected_try numeric)
language sql
stable
security definer
set search_path = ''
as $$
  with pr as (
    select p.id, p.code || ' · ' || p.name as label,
           private.has_permission('hakedis.read', p.id) as can_hk,
           private.has_permission('gider.read', p.id) as can_gd,
           private.has_permission('gelir.read', p.id) as can_gl
      from public.projects p
     where p.deleted_at is null and (p_project_id is null or p.id = p_project_id)
       and private.has_permission('finans_rapor.read', p.id)
  ),
  doc as (
    select d.project_id, d.kind, d.amount_try,
           coalesce((select sum(x.amount_try) from public.finance_settlements x
                      where x.document_id = d.id and x.status = 'aktif'), 0) as settled_try,
           round((d.amount - coalesce((select sum(x.amount) from public.finance_settlements x
                                        where x.document_id = d.id and x.status = 'aktif'), 0)) * d.exchange_rate, 2) as open_try
      from public.finance_documents d
     where d.status = 'onaylandi' and d.project_id is not null
  ),
  hk as (
    select h.project_id,
           coalesce(sum(e.amount_try) filter (where h.posted_at is not null and not exists
                    (select 1 from public.cari_entries r where r.reversal_of_id = e.id)), 0) as accrued_try,
           coalesce(sum(h.gross_amount + h.kdv_amount) filter (where h.posted_at is null and h.currency = 'TRY'), 0) as unposted,
           coalesce(sum(round(h.advance_amount * e.exchange_rate, 2)) filter (where h.posted_at is not null), 0) as adv_deducted
      from public.hakedis h
      left join public.cari_entries e on e.id = h.cari_entry_id
     where h.status = 'onaylandi'
     group by h.project_id
  ),
  fp as (
    select f.project_id,
           coalesce(sum(e.amount_try) filter (where f.kind = 'odeme' and f.hakedis_id is not null), 0) as hk_paid,
           coalesce(sum(e.amount_try) filter (where f.kind = 'avans'), 0) as adv_paid
      from public.finance_payments f
      join public.cari_entries e on e.id = f.cari_entry_id
     where f.status = 'aktif'
     group by f.project_id
  )
  select pr.id, pr.label,
         case when pr.can_gd then coalesce((select sum(amount_try) from doc where doc.project_id = pr.id and kind = 'gider'), 0) end,
         case when pr.can_gd then coalesce((select sum(settled_try) from doc where doc.project_id = pr.id and kind = 'gider'), 0) end,
         case when pr.can_gd then coalesce((select sum(open_try) from doc where doc.project_id = pr.id and kind = 'gider'), 0) end,
         case when pr.can_hk then coalesce(hk.accrued_try, 0) end,
         case when pr.can_hk then coalesce(hk.unposted, 0) end,
         case when pr.can_hk then coalesce(fp.hk_paid, 0) end,
         case when pr.can_hk then coalesce(fp.adv_paid, 0) end,
         case when pr.can_hk then coalesce(hk.adv_deducted, 0) end,
         case when pr.can_gl then coalesce((select sum(amount_try) from doc where doc.project_id = pr.id and kind = 'gelir'), 0) end,
         case when pr.can_gl then coalesce((select sum(settled_try) from doc where doc.project_id = pr.id and kind = 'gelir'), 0) end
    from pr
    left join hk on hk.project_id = pr.id
    left join fp on fp.project_id = pr.id
   order by pr.label;
$$;

-- -----------------------------------------------------------------------------
-- API ayrıcalıkları
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
end;
$$;
revoke execute on function private.harden_api_privileges() from public, anon, authenticated;

select private.harden_api_privileges();

grant execute on function public.save_finance_category(uuid, public.finance_doc_kind, text, integer, boolean) to authenticated;
grant execute on function public.save_finance_document(uuid, public.finance_doc_kind, uuid, text, numeric, date, uuid, uuid,
                                                       date, text, numeric, uuid, text, text, text, boolean, uuid, text,
                                                       integer) to authenticated;
grant execute on function public.approve_finance_document(uuid, integer, uuid) to authenticated;
grant execute on function public.record_finance_settlement(uuid, uuid, numeric, uuid, date, text, text, numeric) to authenticated;
grant execute on function public.cancel_finance_settlement(uuid, text) to authenticated;
grant execute on function public.cancel_finance_document(uuid, text) to authenticated;
grant execute on function public.revise_finance_document(uuid, uuid, text) to authenticated;
grant execute on function public.finance_report(public.finance_doc_kind, text, date, date, uuid, uuid) to authenticated;
grant execute on function public.project_cost_report(uuid) to authenticated;
grant select on public.v_finance_document_status to authenticated;

-- -----------------------------------------------------------------------------
-- İzinler ve rol şablonları. Onay varsayılan olarak yalnızca yöneticidedir
-- (şablonlar yönetici tarafından değiştirilebilir). Şantiye şefi sahada gider
-- girer ve yalnızca kendi girdiği giderleri görür; gelir ve raporları görmez.
-- -----------------------------------------------------------------------------
insert into public.permissions (key, module, description) values
  ('gider.read',             'finans', 'Giderleri, ödemeleri ve bekleyen borçları görüntüleme'),
  ('gider.write',            'finans', 'Gider taslağı girme ve düzenleme'),
  ('gider.approve',          'finans', 'Gideri onaylama (borç doğar), onaylı gideri iptal etme ve düzeltme'),
  ('gider.pay',              'finans', 'Gider ödemesi kaydetme ve iptal etme'),
  ('gelir.read',             'finans', 'Gelirleri, tahsilatları ve bekleyen alacakları görüntüleme'),
  ('gelir.write',            'finans', 'Gelir taslağı girme ve düzenleme'),
  ('gelir.approve',          'finans', 'Geliri onaylama (alacak doğar), onaylı geliri iptal etme ve düzeltme'),
  ('gelir.collect',          'finans', 'Tahsilat kaydetme ve iptal etme'),
  ('finans_rapor.read',      'finans', 'Gider, gelir ve proje maliyeti raporlarını görüntüleme'),
  ('finans_kategori.manage', 'finans', 'Gider ve gelir kategorilerini tanımlama');

insert into public.role_permissions (role_id, permission_key)
select r.id, x.permission_key
  from (values
          ('muhasebe',     'gider.read'),
          ('muhasebe',     'gider.write'),
          ('muhasebe',     'gider.pay'),
          ('muhasebe',     'gelir.read'),
          ('muhasebe',     'gelir.write'),
          ('muhasebe',     'gelir.collect'),
          ('muhasebe',     'finans_rapor.read'),
          ('muhasebe',     'finans_kategori.manage'),
          ('proje_muduru', 'gider.read'),
          ('proje_muduru', 'gider.write'),
          ('proje_muduru', 'finans_rapor.read'),
          ('santiye_sefi', 'gider.write')
       ) as x (role_key, permission_key)
  join public.roles r on r.key = x.role_key;
