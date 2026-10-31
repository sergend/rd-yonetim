-- =============================================================================
-- RD Yönetim · Aşama 4 · Taşeron sözleşmeleri, imalat, hakediş, teminat, ödeme
-- =============================================================================
-- Temel ilkeler:
--   * Sözleşme taşeron ve projeye bağlıdır; finansal kimlik taşeronun mevcut
--     cari kartıdır (ikinci cari açılmaz).
--   * Sözleşme revizyonludur. Onaylı revizyon değiştirilemez; fiyat değişikliği
--     yeni revizyonla yapılır. Hakediş satırları birim fiyatın kopyasını
--     saklar: yeni revizyon eski hakedişleri etkilemez.
--   * Hakediş tutarları yalnızca sunucuda hesaplanır (private.hakedis_refresh).
--     Para numeric(14,2), birim fiyat numeric(14,4), miktar numeric(14,4);
--     yuvarlama satır düzeyinde round(x, 2) (yarım yukarı, sıfırdan uzağa).
--   * Puantajdan yalnızca onaylı/kilitli ayların kayıtları alınır; her kayıt
--     sürümüyle bağlanır ve aynı kayıt sürümü iki etkin hakedişte olamaz.
--     Puantaj sonradan düzeltilirse eski hakediş değişmez; fark sonraki
--     hakedişte ayrı satır (fark) olarak gelir.
--   * Teminat kesintisi kaybolmaz: sözleşme bazında birikir, serbest bırakma
--     ayrı bir olaydır ve yalnızca bırakılan tutar kadar alacak doğurur; nakit
--     ödeme ayrıca kaydedilir.
--   * Cari deftere işleme ayrı yetkili, tek işlemli ve tekrar güvenli bir
--     işlemdir. Defter değişmez; iptal ters kayıtla yapılır.
--   * Vergi oranları kodda yoktur: kullanıcı tarafından tanımlanıp doğrulanan,
--     tarihli kurallardan (tax_rules) okunur. Belirsiz durumda işlem reddedilir.
--   * Bu modül kasa, banka veya toplam para bakiyesi tutmaz.

alter type public.cari_entry_kind add value if not exists 'teminat_iadesi';

create type public.contract_status as enum ('taslak', 'aktif', 'kapandi', 'iptal');
create type public.contract_version_status as enum ('taslak', 'onaylandi', 'yerine_gecildi');
create type public.contract_item_method as enum ('birim_fiyat', 'gunluk', 'goturu');
create type public.work_quantity_status as enum ('taslak', 'onaylandi', 'iptal');
create type public.hakedis_status as enum ('taslak', 'incelemede', 'onaylandi', 'iptal');
create type public.tax_rule_kind as enum ('kdv', 'stopaj', 'diger_kesinti');
create type public.hakedis_adjustment_kind as enum ('kdv', 'stopaj', 'teminat', 'avans_mahsubu', 'diger_kesinti');

-- -----------------------------------------------------------------------------
-- Vergi ve kesinti kuralları (kullanıcı tanımlı, tarihli, doğrulamalı).
-- Oran değişikliği yeni satırla (aynı kod, yeni geçerlilik tarihi) yapılır;
-- doğrulanmış kuralın oranı ve tarihleri değiştirilemez.
-- -----------------------------------------------------------------------------
create table public.tax_rules (
  id          uuid primary key default gen_random_uuid(),
  code        text not null check (code ~ '^[A-Z0-9_]{2,20}$'),
  name        text not null check (length(trim(name)) > 0),
  kind        public.tax_rule_kind not null,
  rate        numeric(7, 4) not null check (rate >= 0 and rate <= 100),
  -- Matrah: brüt hakediş veya (tevkifat gibi) hesaplanan KDV.
  base        text not null default 'brut' check (base in ('brut', 'kdv')),
  valid_from  date not null,
  valid_to    date,
  verified_at timestamptz,
  verified_by uuid,
  notes       text,
  is_active   boolean not null default true,
  check (valid_to is null or valid_to >= valid_from),
  check (kind <> 'kdv' or base = 'brut')
);
create unique index tax_rules_code_from_uq on public.tax_rules (code, valid_from);
select private.add_row_meta('public.tax_rules');
select audit.enable('public.tax_rules');

-- Ödeme kaynakları: "Şirket ödemesi", "Kürşat kartı" gibi. Yalnızca ödemenin
-- nereden yapıldığını etiketler; bakiye tutulmaz.
create table public.payment_sources (
  id        uuid primary key default gen_random_uuid(),
  name      text not null check (length(trim(name)) > 0),
  kind      text not null default 'sirket' check (kind in ('sirket', 'kart', 'kisi', 'diger')),
  notes     text,
  is_active boolean not null default true
);
create unique index payment_sources_name_uq on public.payment_sources (lower(name));
select private.add_row_meta('public.payment_sources');
select audit.enable('public.payment_sources');

-- -----------------------------------------------------------------------------
-- Sözleşme, revizyon, kalem
-- -----------------------------------------------------------------------------
create table public.contracts (
  id               uuid primary key default gen_random_uuid(),
  contract_no      text not null check (length(trim(contract_no)) > 0),
  project_id       uuid not null references public.projects (id) on delete restrict,
  subcontractor_id uuid not null references public.subcontractors (id) on delete restrict,
  cari_account_id  uuid not null references public.cari_accounts (id) on delete restrict,
  title            text not null check (length(trim(title)) > 0),
  signed_date      date,
  currency         char(3) not null default 'TRY' check (currency ~ '^[A-Z]{3}$'),
  status           public.contract_status not null default 'taslak',
  closed_at        timestamptz,
  closed_by        uuid,
  close_reason     text,
  is_demo          boolean not null default false
);
create unique index contracts_no_uq on public.contracts (upper(contract_no));
create index contracts_project_idx on public.contracts (project_id);
create index contracts_subcontractor_idx on public.contracts (subcontractor_id);
select private.add_row_meta('public.contracts');
select audit.enable('public.contracts');

create table public.contract_versions (
  id                     uuid primary key default gen_random_uuid(),
  contract_id            uuid not null references public.contracts (id) on delete restrict,
  revision               integer not null check (revision >= 0),
  status                 public.contract_version_status not null default 'taslak',
  scope                  text,
  start_date             date,
  end_date               date,
  -- Sözleşme bedeli üst sınırı (isteğe bağlı). Kümülatif brüt hakediş aşamaz.
  total_amount           numeric(14, 2) check (total_amount > 0),
  retention_rate         numeric(7, 4) not null default 0 check (retention_rate >= 0 and retention_rate <= 100),
  advance_deduction_rate numeric(7, 4) check (advance_deduction_rate >= 0 and advance_deduction_rate <= 100),
  payment_terms          text,
  notes                  text,
  reason                 text,
  approved_at            timestamptz,
  approved_by            uuid,
  superseded_at          timestamptz,
  unique (contract_id, revision),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create unique index contract_versions_one_draft_uq on public.contract_versions (contract_id) where status = 'taslak';
create unique index contract_versions_one_approved_uq on public.contract_versions (contract_id) where status = 'onaylandi';
select private.add_row_meta('public.contract_versions');
select audit.enable('public.contract_versions');

create table public.contract_items (
  id                  uuid primary key default gen_random_uuid(),
  version_id          uuid not null references public.contract_versions (id) on delete restrict,
  contract_id         uuid not null references public.contracts (id) on delete restrict,
  -- Revizyonlar arasında aynı kalemi tanıyan kalıcı anahtar.
  item_key            uuid not null,
  line_no             integer not null check (line_no > 0),
  method              public.contract_item_method not null,
  description         text not null check (length(trim(description)) > 0),
  unit                text not null check (unit in ('m2', 'm3', 'm', 'ton', 'kg', 'adet', 'saat', 'adam_gun', 'goturu', 'diger')),
  -- Sözleşme miktarı (üst sınır); götürüde yok (ilerleme yüzdesi en çok 100).
  quantity            numeric(14, 3) check (quantity > 0),
  -- Birim fiyat; götürüde kalemin toplam bedeli.
  unit_price          numeric(14, 4) not null check (unit_price >= 0),
  -- Günlük işte fazla mesai saat ücreti; boşsa fazla mesai ücretlendirilmez.
  overtime_unit_price numeric(14, 4) check (overtime_unit_price >= 0),
  -- Günlük işte ücretlendirilen puantaj sınıfları (pay_basis).
  paid_bases          text[] not null default '{calisilan_gun}',
  -- Günlük işte kişiye özel fiyat (boşsa sözleşmedeki herkes için).
  personnel_id        uuid references public.personnel (id) on delete restrict,
  unique (version_id, item_key),
  constraint contract_items_goturu_ck check (method <> 'goturu' or (unit = 'goturu' and quantity is null)),
  constraint contract_items_gunluk_ck check ((method = 'gunluk') = (unit = 'adam_gun')),
  constraint contract_items_birim_ck check (method <> 'birim_fiyat' or unit not in ('adam_gun', 'goturu')),
  constraint contract_items_daily_only_ck check (
    method = 'gunluk' or (overtime_unit_price is null and personnel_id is null and paid_bases = '{calisilan_gun}')),
  constraint contract_items_paid_bases_ck check (
    'calisilan_gun' = any (paid_bases)
    and paid_bases <@ array['calisilan_gun', 'ucretli_izin', 'rapor', 'resmi_tatil'])
);
create unique index contract_items_daily_person_uq on public.contract_items
  (version_id, coalesce(personnel_id, '00000000-0000-0000-0000-000000000000'::uuid)) where method = 'gunluk';
create index contract_items_contract_idx on public.contract_items (contract_id, item_key);
select private.add_row_meta('public.contract_items');
select audit.enable('public.contract_items');

-- Sözleşme revizyonuna bağlı vergi/kesinti kuralları (kod ile; oran hakediş
-- dönem sonunda geçerli doğrulanmış kuraldan alınır).
create table public.contract_version_taxes (
  id         uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.contract_versions (id) on delete restrict,
  tax_code   text not null,
  unique (version_id, tax_code)
);
select private.add_row_meta('public.contract_version_taxes');
select audit.enable('public.contract_version_taxes');

-- -----------------------------------------------------------------------------
-- Gerçekleşen imalat (metraj). Fiyat içermez; şantiye girer, yetkili onaylar.
-- -----------------------------------------------------------------------------
create table public.work_quantities (
  id             uuid primary key,
  contract_id    uuid not null references public.contracts (id) on delete restrict,
  project_id     uuid not null references public.projects (id) on delete restrict,
  item_key       uuid not null,
  work_date      date not null,
  quantity       numeric(14, 3) not null check (quantity > 0),
  location       text,
  note           text,
  status         public.work_quantity_status not null default 'taslak',
  approved_at    timestamptz,
  approved_by    uuid,
  cancelled_at   timestamptz,
  cancelled_by   uuid,
  cancel_reason  text,
  is_demo        boolean not null default false
);
create index work_quantities_contract_idx on public.work_quantities (contract_id, item_key, work_date);
select private.add_row_meta('public.work_quantities');
select audit.enable('public.work_quantities');

-- -----------------------------------------------------------------------------
-- Hakediş
-- -----------------------------------------------------------------------------
create table public.hakedis (
  id                     uuid primary key,
  contract_id            uuid not null references public.contracts (id) on delete restrict,
  version_id             uuid not null references public.contract_versions (id) on delete restrict,
  project_id             uuid not null references public.projects (id) on delete restrict,
  subcontractor_id       uuid not null references public.subcontractors (id) on delete restrict,
  cari_account_id        uuid not null references public.cari_accounts (id) on delete restrict,
  hakedis_no             integer not null check (hakedis_no > 0),
  period_start           date not null,
  period_end             date not null,
  status                 public.hakedis_status not null default 'taslak',
  currency               char(3) not null,
  replaces_id            uuid references public.hakedis (id) on delete restrict,
  note                   text,
  -- Sunucunun hesapladığı tutarlar (onayda dondurulur).
  gross_amount           numeric(14, 2) not null default 0,  -- bu dönem brüt hakediş
  kdv_amount             numeric(14, 2) not null default 0,  -- eklenen KDV
  tax_deduction_amount   numeric(14, 2) not null default 0,  -- stopaj
  other_deduction_amount numeric(14, 2) not null default 0,  -- diğer sözleşmesel kesintiler
  retention_amount       numeric(14, 2) not null default 0,  -- teminat kesintisi
  advance_amount         numeric(14, 2) not null default 0,  -- avans mahsubu
  payable_amount         numeric(14, 2) not null default 0,  -- ödemeye uygun
  limit_exceeded         boolean not null default false,
  limit_messages         text[] not null default '{}',
  limit_override_reason  text,
  limit_override_by      uuid,
  limit_override_at      timestamptz,
  submitted_at           timestamptz,
  submitted_by           uuid,
  approved_at            timestamptz,
  approved_by            uuid,
  cancelled_at           timestamptz,
  cancelled_by           uuid,
  cancel_reason          text,
  posted_at              timestamptz,
  posted_by              uuid,
  cari_entry_id          uuid references public.cari_entries (id) on delete restrict,
  is_demo                boolean not null default false,
  unique (contract_id, hakedis_no),
  check (period_end >= period_start)
);
-- Bir sözleşmede aynı anda tek açık (taslak/incelemede) hakediş olur.
create unique index hakedis_one_open_uq on public.hakedis (contract_id) where status in ('taslak', 'incelemede');
create index hakedis_project_idx on public.hakedis (project_id, status);
select private.add_row_meta('public.hakedis');
select audit.enable('public.hakedis');

create table public.hakedis_lines (
  id                  uuid primary key default gen_random_uuid(),
  hakedis_id          uuid not null references public.hakedis (id) on delete restrict,
  contract_item_id    uuid not null references public.contract_items (id) on delete restrict,
  item_key            uuid not null,
  line_kind           text not null default 'ana' check (line_kind in ('ana', 'fazla_mesai')),
  method              public.contract_item_method not null,
  description         text not null,
  unit                text not null,
  unit_price          numeric(14, 4) not null,
  contract_quantity   numeric(14, 3),
  -- Bu dönem miktarı (götürüde yüzde puanı); fark satırlarında eksi olabilir.
  quantity            numeric(14, 4) not null default 0,
  previous_quantity   numeric(14, 4) not null default 0,
  cumulative_quantity numeric(14, 4) not null default 0,
  amount              numeric(14, 2) not null default 0,
  previous_amount     numeric(14, 2) not null default 0,
  cumulative_amount   numeric(14, 2) not null default 0,
  -- Götürü kalemde girilen kümülatif ilerleme yüzdesi.
  progress_percent    numeric(7, 4) check (progress_percent >= 0 and progress_percent <= 100),
  unique (hakedis_id, item_key, line_kind)
);
select private.add_row_meta('public.hakedis_lines');
select audit.enable('public.hakedis_lines');

-- Hangi imalat kaydı hangi hakedişte kullanıldı (bir kayıt tek etkin hakedişte).
create table public.hakedis_quantity_links (
  id               uuid primary key default gen_random_uuid(),
  hakedis_id       uuid not null references public.hakedis (id) on delete restrict,
  work_quantity_id uuid not null references public.work_quantities (id) on delete restrict,
  item_key         uuid not null,
  quantity         numeric(14, 3) not null,
  active           boolean not null default true
);
create unique index hakedis_quantity_links_once_uq on public.hakedis_quantity_links (work_quantity_id) where active;
create index hakedis_quantity_links_hakedis_idx on public.hakedis_quantity_links (hakedis_id);
select private.add_row_meta('public.hakedis_quantity_links');
select audit.enable('public.hakedis_quantity_links');

-- Hangi puantaj kaydı (sürümüyle) hangi hakedişte, kaç gün/saat olarak
-- kullanıldı. day_delta / overtime_delta önceki kullanımlara göre farktır.
create table public.hakedis_puantaj_links (
  id               uuid primary key default gen_random_uuid(),
  hakedis_id       uuid not null references public.hakedis (id) on delete restrict,
  contract_item_id uuid not null references public.contract_items (id) on delete restrict,
  item_key         uuid not null,
  puantaj_entry_id uuid not null references public.puantaj_entries (id) on delete restrict,
  entry_version    integer not null,
  period_id        uuid not null references public.puantaj_periods (id) on delete restrict,
  period_revision  integer not null,
  personnel_id     uuid not null,
  personnel_name   text not null,
  work_date        date not null,
  status           public.puantaj_status not null,
  pay_basis        text not null,
  day_delta        numeric(6, 2) not null default 0,
  overtime_delta   numeric(6, 2) not null default 0,
  is_correction    boolean not null default false,
  active           boolean not null default true
);
create unique index hakedis_puantaj_links_once_uq on public.hakedis_puantaj_links (puantaj_entry_id, entry_version) where active;
create index hakedis_puantaj_links_entry_idx on public.hakedis_puantaj_links (puantaj_entry_id) where active;
create index hakedis_puantaj_links_hakedis_idx on public.hakedis_puantaj_links (hakedis_id);
select private.add_row_meta('public.hakedis_puantaj_links');
select audit.enable('public.hakedis_puantaj_links');

-- Brüte eklenen (KDV) ve brütten düşülen (stopaj, teminat, avans mahsubu,
-- diğer) tutarlar. Matrah ve oran satırda saklanır.
create table public.hakedis_adjustments (
  id            uuid primary key default gen_random_uuid(),
  hakedis_id    uuid not null references public.hakedis (id) on delete restrict,
  kind          public.hakedis_adjustment_kind not null,
  tax_code      text not null default '',
  base_amount   numeric(14, 2),
  rate          numeric(7, 4),
  amount        numeric(14, 2) not null check (amount >= 0),
  description   text not null,
  is_manual     boolean not null default false,
  cari_entry_id uuid references public.cari_entries (id) on delete restrict,
  unique (hakedis_id, kind, tax_code),
  check (kind not in ('avans_mahsubu') or is_manual)
);
select private.add_row_meta('public.hakedis_adjustments');
select audit.enable('public.hakedis_adjustments');

-- -----------------------------------------------------------------------------
-- Teminat serbest bırakma ve ödemeler
-- -----------------------------------------------------------------------------
create table public.teminat_releases (
  id              uuid primary key,
  contract_id     uuid not null references public.contracts (id) on delete restrict,
  project_id      uuid not null references public.projects (id) on delete restrict,
  cari_account_id uuid not null references public.cari_accounts (id) on delete restrict,
  amount          numeric(14, 2) not null check (amount > 0),
  release_date    date not null,
  reason          text not null check (length(trim(reason)) > 0),
  status          text not null default 'aktif' check (status in ('aktif', 'iptal')),
  cari_entry_id   uuid unique references public.cari_entries (id) on delete restrict,
  cancelled_at    timestamptz,
  cancelled_by    uuid,
  cancel_reason   text,
  is_demo         boolean not null default false
);
create index teminat_releases_contract_idx on public.teminat_releases (contract_id);
select private.add_row_meta('public.teminat_releases');
select audit.enable('public.teminat_releases');

create table public.finance_payments (
  id                 uuid primary key,  -- cari hareket kimliğiyle aynı (istemcide üretilir)
  contract_id        uuid not null references public.contracts (id) on delete restrict,
  project_id         uuid not null references public.projects (id) on delete restrict,
  cari_account_id    uuid not null references public.cari_accounts (id) on delete restrict,
  kind               text not null check (kind in ('odeme', 'avans')),
  amount             numeric(14, 2) not null check (amount > 0),
  payment_date       date not null,
  payment_source_id  uuid not null references public.payment_sources (id) on delete restrict,
  hakedis_id         uuid references public.hakedis (id) on delete restrict,
  teminat_release_id uuid references public.teminat_releases (id) on delete restrict,
  cari_entry_id      uuid not null unique references public.cari_entries (id) on delete restrict,
  description        text,
  status             text not null default 'aktif' check (status in ('aktif', 'iptal')),
  cancelled_at       timestamptz,
  cancelled_by       uuid,
  cancel_reason      text,
  is_demo            boolean not null default false,
  check (num_nonnulls(hakedis_id, teminat_release_id) <= 1),
  check (kind = 'odeme' or (hakedis_id is null and teminat_release_id is null))
);
create index finance_payments_contract_idx on public.finance_payments (contract_id);
create index finance_payments_hakedis_idx on public.finance_payments (hakedis_id) where hakedis_id is not null;
select private.add_row_meta('public.finance_payments');
select audit.enable('public.finance_payments');

-- Onay ve değişiklik geçmişi (değiştirilemez).
create table public.finance_events (
  id          uuid primary key default gen_random_uuid(),
  entity      text not null check (entity in ('sozlesme', 'imalat', 'hakedis', 'teminat', 'odeme')),
  entity_id   uuid not null,
  contract_id uuid not null references public.contracts (id) on delete restrict,
  project_id  uuid not null references public.projects (id) on delete restrict,
  action      text not null,
  from_status text,
  to_status   text,
  reason      text,
  data        jsonb,
  actor_id    uuid default auth.uid(),
  occurred_at timestamptz not null default clock_timestamp()
);
create index finance_events_entity_idx on public.finance_events (entity_id, occurred_at);
create index finance_events_contract_idx on public.finance_events (contract_id, occurred_at);
select private.add_row_meta('public.finance_events');
select audit.enable('public.finance_events');

create or replace function private.tg_finance_event_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Onay ve değişiklik geçmişi değiştirilemez' using errcode = 'insufficient_privilege';
end;
$$;
create trigger finance_event_immutable before update or delete on public.finance_events
  for each row execute function private.tg_finance_event_immutable();

-- -----------------------------------------------------------------------------
-- Değişmezlik kuralları (tablolar API'ye kapalı; bu kurallar RPC hatalarına
-- karşı ikinci savunma hattıdır).
-- -----------------------------------------------------------------------------
create or replace function private.tg_contract_version_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Sözleşme revizyonu silinemez' using errcode = 'insufficient_privilege';
  end if;
  if old.status <> 'taslak' and (
       new.retention_rate is distinct from old.retention_rate
       or new.total_amount is distinct from old.total_amount
       or new.advance_deduction_rate is distinct from old.advance_deduction_rate
       or new.revision <> old.revision or new.contract_id <> old.contract_id
       or new.approved_at is distinct from old.approved_at
       or (old.status = 'yerine_gecildi')
       or (old.status = 'onaylandi' and new.status not in ('onaylandi', 'yerine_gecildi'))) then
    raise exception 'Onaylı sözleşme revizyonu değiştirilemez; yeni revizyon açın' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger contract_version_guard before update or delete on public.contract_versions
  for each row execute function private.tg_contract_version_guard();

create or replace function private.tg_contract_item_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status public.contract_version_status;
begin
  select status into v_status from public.contract_versions
   where id = case when tg_op = 'DELETE' then old.version_id else new.version_id end;
  if v_status <> 'taslak' then
    raise exception 'Onaylı sözleşme revizyonunun kalemleri değiştirilemez; yeni revizyon açın'
      using errcode = 'check_violation';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
create trigger contract_item_guard before insert or update or delete on public.contract_items
  for each row execute function private.tg_contract_item_guard();
create trigger contract_tax_guard before insert or update or delete on public.contract_version_taxes
  for each row execute function private.tg_contract_item_guard();

-- Onaylı veya iptal edilmiş hakedişin tutarları ve dönemi değişmez; yalnızca
-- iptal, deftere işleme ve limit bilgisi alanları değişebilir.
create or replace function private.tg_hakedis_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Hakediş silinemez; iptal edin' using errcode = 'insufficient_privilege';
  end if;
  if new.contract_id <> old.contract_id or new.project_id <> old.project_id
     or new.cari_account_id <> old.cari_account_id or new.hakedis_no <> old.hakedis_no
     or new.is_demo <> old.is_demo then
    raise exception 'Hakedişin sözleşmesi, numarası veya demo işareti değiştirilemez' using errcode = 'check_violation';
  end if;
  if old.status in ('onaylandi', 'iptal') and (
       new.gross_amount <> old.gross_amount or new.kdv_amount <> old.kdv_amount
       or new.tax_deduction_amount <> old.tax_deduction_amount
       or new.other_deduction_amount <> old.other_deduction_amount
       or new.retention_amount <> old.retention_amount or new.advance_amount <> old.advance_amount
       or new.payable_amount <> old.payable_amount or new.version_id <> old.version_id
       or new.period_start <> old.period_start or new.period_end <> old.period_end
       or new.approved_at is distinct from old.approved_at
       or new.approved_by is distinct from old.approved_by) then
    raise exception 'Onaylı hakediş değiştirilemez; iptal edip düzeltme hakedişi açın' using errcode = 'check_violation';
  end if;
  if old.status = 'iptal' and new.status <> 'iptal' then
    raise exception 'İptal edilen hakediş yeniden açılamaz' using errcode = 'check_violation';
  end if;
  if old.posted_at is not null and (new.posted_at is distinct from old.posted_at
                                    or new.cari_entry_id is distinct from old.cari_entry_id) then
    raise exception 'Deftere işleme bilgisi değiştirilemez' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger hakedis_guard before update or delete on public.hakedis
  for each row execute function private.tg_hakedis_guard();

-- Onaylı/iptal hakedişin satırları ve kesintileri değişmez (bağlantıların
-- yalnızca "active" bayrağı iptalde kapanır).
create or replace function private.tg_hakedis_child_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status public.hakedis_status;
begin
  select status into v_status from public.hakedis
   where id = case when tg_op = 'DELETE' then old.hakedis_id else new.hakedis_id end;
  if v_status in ('onaylandi', 'iptal') then
    if tg_table_name in ('hakedis_quantity_links', 'hakedis_puantaj_links') and tg_op = 'UPDATE'
       and (to_jsonb(new) - array['active', 'updated_at', 'updated_by', 'version'])
         = (to_jsonb(old) - array['active', 'updated_at', 'updated_by', 'version']) then
      return new;
    end if;
    if tg_table_name = 'hakedis_adjustments' and tg_op = 'UPDATE'
       and (to_jsonb(new) - array['cari_entry_id', 'updated_at', 'updated_by', 'version'])
         = (to_jsonb(old) - array['cari_entry_id', 'updated_at', 'updated_by', 'version']) then
      return new;
    end if;
    raise exception 'Onaylı hakedişin satırları değiştirilemez' using errcode = 'check_violation';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
create trigger hakedis_child_guard before insert or update or delete on public.hakedis_lines
  for each row execute function private.tg_hakedis_child_guard();
create trigger hakedis_child_guard before insert or update or delete on public.hakedis_adjustments
  for each row execute function private.tg_hakedis_child_guard();
create trigger hakedis_child_guard before insert or update or delete on public.hakedis_quantity_links
  for each row execute function private.tg_hakedis_child_guard();
create trigger hakedis_child_guard before insert or update or delete on public.hakedis_puantaj_links
  for each row execute function private.tg_hakedis_child_guard();

create or replace function private.tg_tax_rule_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.verified_at is not null and (
       new.rate <> old.rate or new.base <> old.base or new.kind <> old.kind or new.code <> old.code
       or new.valid_from <> old.valid_from or new.verified_at is distinct from old.verified_at
       or (old.valid_to is not null and new.valid_to is distinct from old.valid_to)) then
    raise exception 'Doğrulanmış vergi kuralının oranı ve tarihleri değiştirilemez; yeni geçerlilik tarihiyle yeni kural ekleyin'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger tax_rule_guard before update on public.tax_rules
  for each row execute function private.tg_tax_rule_guard();

-- -----------------------------------------------------------------------------
-- Yardımcılar
-- -----------------------------------------------------------------------------
create or replace function private.fin_event(
  p_entity text, p_entity_id uuid, p_contract_id uuid, p_project_id uuid, p_action text,
  p_from text, p_to text, p_reason text default null, p_data jsonb default null)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.finance_events (entity, entity_id, contract_id, project_id, action, from_status, to_status, reason, data)
  values (p_entity, p_entity_id, p_contract_id, p_project_id, p_action, p_from, p_to, nullif(trim(p_reason), ''), p_data);
$$;

-- Kaynak belgeden gelen hareketin ters kaydı (eşleştirmeleri de kapatır).
create or replace function private.fin_reverse_entry(p_entry_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_orig public.cari_entries;
begin
  select * into v_orig from public.cari_entries where id = p_entry_id for update;
  if not found or exists (select 1 from public.cari_entries e where e.reversal_of_id = p_entry_id) then
    return;
  end if;
  update public.cari_allocations a
     set deleted_at = now(), note = coalesce(a.note || ' · ', '') || 'Kaynak belge iptal edildi'
   where a.deleted_at is null and p_entry_id in (a.payment_entry_id, a.target_entry_id);
  insert into public.cari_entries (id, cari_account_id, project_id, cost_center_id, entry_date, direction, kind,
                                   amount, currency, exchange_rate, description, document_no, reversal_of_id)
  values (gen_random_uuid(), v_orig.cari_account_id, v_orig.project_id, v_orig.cost_center_id, private.today(),
          case v_orig.direction when 'borc' then 'alacak'::public.cari_direction else 'borc'::public.cari_direction end,
          'ters_kayit', v_orig.amount, v_orig.currency, v_orig.exchange_rate,
          'İptal: ' || trim(p_reason), v_orig.document_no, v_orig.id);
end;
$$;

-- Sözleşmenin onaylı hakedişlerinde kullanılmış kalem miktarları.
create or replace function private.contract_item_usage(p_contract_id uuid, p_item_key uuid, p_except uuid default null)
returns table (quantity numeric, amount numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(l.quantity), 0), coalesce(sum(l.amount), 0)
    from public.hakedis_lines l
    join public.hakedis h on h.id = l.hakedis_id
   where h.contract_id = p_contract_id and h.status = 'onaylandi' and l.item_key = p_item_key
     and l.line_kind = 'ana' and h.id is distinct from p_except;
$$;

-- Teminat bakiyesi: deftere işlenmiş, iptal edilmemiş hakedişlerin teminat
-- kesintileri − etkin serbest bırakmalar.
create or replace function private.contract_retention_balance(p_contract_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select sum(h.retention_amount) from public.hakedis h
                    where h.contract_id = p_contract_id and h.status = 'onaylandi' and h.posted_at is not null), 0)
       - coalesce((select sum(r.amount) from public.teminat_releases r
                    where r.contract_id = p_contract_id and r.status = 'aktif'), 0);
$$;

-- Cari + projede mahsup edilebilir açık avans tutarı.
create or replace function private.open_advance(p_cari uuid, p_project uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(e.amount - coalesce((select sum(a.amount) from public.cari_allocations a
                                            where a.deleted_at is null and e.id in (a.payment_entry_id, a.target_entry_id)), 0)), 0)
    from public.cari_entries e
   where e.cari_account_id = p_cari and e.project_id = p_project and e.kind = 'avans'
     and not exists (select 1 from public.cari_entries r where r.reversal_of_id = e.id);
$$;

-- -----------------------------------------------------------------------------
-- Hakediş hesabı. Taslak/incelemedeki hakedişin satırlarını, bağlantılarını
-- ve otomatik kesintilerini kaynak verilerden yeniden üretir. Götürü ilerleme
-- girişleri ve elle girilen kesintiler (avans mahsubu, diğer) korunur.
-- -----------------------------------------------------------------------------
create or replace function private.hakedis_refresh(p_hakedis_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  h          public.hakedis;
  c          public.contracts;
  v          public.contract_versions;
  it         record;
  t          record;
  r          public.tax_rules;
  v_prev     record;
  v_q        numeric;
  v_ot       numeric;
  v_amount   numeric;
  v_gross    numeric;
  v_kdv      numeric;
  v_stopaj   numeric;
  v_other    numeric;
  v_ret      numeric;
  v_adv      numeric;
  v_prev_gross numeric;
  v_msgs     text[] := '{}';
begin
  select * into h from public.hakedis where id = p_hakedis_id for update;
  if h.status not in ('taslak', 'incelemede') then
    raise exception 'Yalnızca taslak veya incelemedeki hakediş yeniden hesaplanır' using errcode = 'check_violation';
  end if;
  select * into c from public.contracts where id = h.contract_id;
  select * into v from public.contract_versions where contract_id = c.id and status = 'onaylandi';
  if not found then
    raise exception 'Sözleşmenin onaylı revizyonu yok' using errcode = 'check_violation';
  end if;
  if h.version_id <> v.id then
    update public.hakedis set version_id = v.id where id = h.id;
  end if;

  delete from public.hakedis_quantity_links where hakedis_id = h.id;
  delete from public.hakedis_puantaj_links  where hakedis_id = h.id;
  delete from public.hakedis_lines where hakedis_id = h.id
     and (method <> 'goturu'
          or item_key not in (select ci.item_key from public.contract_items ci where ci.version_id = v.id and ci.method = 'goturu'));
  delete from public.hakedis_adjustments where hakedis_id = h.id and not is_manual;

  -- Birim fiyat: onaylı ve henüz hiçbir etkin hakedişte kullanılmamış imalat.
  insert into public.hakedis_quantity_links (hakedis_id, work_quantity_id, item_key, quantity)
  select h.id, w.id, w.item_key, w.quantity
    from public.work_quantities w
    join public.contract_items ci on ci.version_id = v.id and ci.item_key = w.item_key and ci.method = 'birim_fiyat'
   where w.contract_id = c.id and w.status = 'onaylandi' and w.work_date <= h.period_end
     and not exists (select 1 from public.hakedis_quantity_links l where l.work_quantity_id = w.id and l.active);

  -- Günlük: onaylı/kilitli aylardaki puantaj kayıtları. Her kaydın hedef
  -- gün/saat değeri ile önceki etkin kullanımların farkı bağlanır.
  insert into public.hakedis_puantaj_links (hakedis_id, contract_item_id, item_key, puantaj_entry_id, entry_version,
                                            period_id, period_revision, personnel_id, personnel_name, work_date,
                                            status, pay_basis, day_delta, overtime_delta, is_correction)
  select h.id, x.item_id, x.item_key, x.entry_id, x.entry_version, x.period_id, x.period_revision, x.personnel_id,
         x.personnel_name, x.work_date, x.status, x.pay_basis,
         x.target_days - x.used_days, x.target_ot - x.used_ot, x.used_count > 0
    from (
      select e.id as entry_id, e.version as entry_version, e.period_id, p.revision as period_revision,
             e.personnel_id, e.personnel_name, e.work_date, e.status, d.pay_basis,
             ci.id as item_id, ci.item_key,
             case when e.deleted_at is not null then 0
                  when d.pay_basis = 'calisilan_gun' then d.work_equivalent
                  when d.pay_basis = any (ci.paid_bases) then 1
                  else 0 end as target_days,
             case when e.deleted_at is not null or ci.overtime_unit_price is null or e.overtime_approved_at is null then 0
                  else e.overtime_hours end as target_ot,
             coalesce(u.days, 0) as used_days, coalesce(u.ot, 0) as used_ot, coalesce(u.n, 0) as used_count,
             u.same_version
        from public.puantaj_entries e
        join public.puantaj_periods p on p.id = e.period_id
        join public.puantaj_status_definitions d on d.status = e.status
        join lateral (
               select ci.* from public.contract_items ci
                where ci.version_id = v.id and ci.method = 'gunluk'
                  and (ci.personnel_id = e.personnel_id or ci.personnel_id is null)
                order by ci.personnel_id nulls last limit 1) ci on true
        left join lateral (
               select sum(l.day_delta) as days, sum(l.overtime_delta) as ot, count(*) as n,
                      bool_or(l.entry_version = e.version) as same_version
                 from public.hakedis_puantaj_links l
                where l.puantaj_entry_id = e.id and l.active) u on true
       where e.project_id = c.project_id and e.subcontractor_id = c.subcontractor_id
         and e.work_date <= h.period_end
         and (v.start_date is null or e.work_date >= v.start_date)
         and p.status in ('onaylandi', 'kilitli')
         and (e.deleted_at is null or u.n > 0)
    ) x
   where coalesce(x.same_version, false) = false
     and (x.target_days <> x.used_days or x.target_ot <> x.used_ot);

  -- Satırlar: sözleşmenin her kalemi için (hareket olmasa da önceki ve
  -- kümülatif değerler görünsün diye).
  for it in select * from public.contract_items ci where ci.version_id = v.id order by ci.line_no loop
    select * into v_prev from private.contract_item_usage(c.id, it.item_key, h.id);
    if it.method = 'birim_fiyat' then
      select coalesce(sum(l.quantity), 0) into v_q from public.hakedis_quantity_links l
       where l.hakedis_id = h.id and l.item_key = it.item_key;
      v_amount := round(v_q * it.unit_price, 2);
      insert into public.hakedis_lines (hakedis_id, contract_item_id, item_key, line_kind, method, description, unit,
                                        unit_price, contract_quantity, quantity, previous_quantity, cumulative_quantity,
                                        amount, previous_amount, cumulative_amount)
      values (h.id, it.id, it.item_key, 'ana', it.method, it.description, it.unit, it.unit_price, it.quantity,
              v_q, v_prev.quantity, v_prev.quantity + v_q, v_amount, v_prev.amount, v_prev.amount + v_amount);
    elsif it.method = 'gunluk' then
      select coalesce(sum(l.day_delta), 0), coalesce(sum(l.overtime_delta), 0) into v_q, v_ot
        from public.hakedis_puantaj_links l where l.hakedis_id = h.id and l.item_key = it.item_key;
      v_amount := round(v_q * it.unit_price, 2);
      insert into public.hakedis_lines (hakedis_id, contract_item_id, item_key, line_kind, method, description, unit,
                                        unit_price, contract_quantity, quantity, previous_quantity, cumulative_quantity,
                                        amount, previous_amount, cumulative_amount)
      values (h.id, it.id, it.item_key, 'ana', it.method, it.description, it.unit, it.unit_price, it.quantity,
              v_q, v_prev.quantity, v_prev.quantity + v_q, v_amount, v_prev.amount, v_prev.amount + v_amount);
      if it.overtime_unit_price is not null then
        select coalesce(sum(l.quantity), 0) as quantity, coalesce(sum(l.amount), 0) as amount into v_prev
          from public.hakedis_lines l join public.hakedis hh on hh.id = l.hakedis_id
         where hh.contract_id = c.id and hh.status = 'onaylandi' and l.item_key = it.item_key
           and l.line_kind = 'fazla_mesai';
        v_amount := round(v_ot * it.overtime_unit_price, 2);
        insert into public.hakedis_lines (hakedis_id, contract_item_id, item_key, line_kind, method, description, unit,
                                          unit_price, quantity, previous_quantity, cumulative_quantity,
                                          amount, previous_amount, cumulative_amount)
        values (h.id, it.id, it.item_key, 'fazla_mesai', it.method, it.description || ' · fazla mesai', 'saat',
                it.overtime_unit_price, v_ot, v_prev.quantity, v_prev.quantity + v_ot,
                v_amount, v_prev.amount, v_prev.amount + v_amount);
      end if;
    else
      -- Götürü: girilen kümülatif ilerleme (yoksa önceki düzeyde kalır).
      insert into public.hakedis_lines (hakedis_id, contract_item_id, item_key, line_kind, method, description, unit,
                                        unit_price, progress_percent)
      values (h.id, it.id, it.item_key, 'ana', it.method, it.description, it.unit, it.unit_price, v_prev.quantity)
      on conflict (hakedis_id, item_key, line_kind) do nothing;
      update public.hakedis_lines l
         set contract_item_id = it.id, description = it.description, unit_price = it.unit_price,
             progress_percent = greatest(coalesce(l.progress_percent, 0), v_prev.quantity),
             previous_quantity = v_prev.quantity,
             quantity = greatest(coalesce(l.progress_percent, 0), v_prev.quantity) - v_prev.quantity,
             cumulative_quantity = greatest(coalesce(l.progress_percent, 0), v_prev.quantity),
             previous_amount = v_prev.amount,
             cumulative_amount = round(it.unit_price * greatest(coalesce(l.progress_percent, 0), v_prev.quantity) / 100, 2),
             amount = round(it.unit_price * greatest(coalesce(l.progress_percent, 0), v_prev.quantity) / 100, 2) - v_prev.amount
       where l.hakedis_id = h.id and l.item_key = it.item_key and l.line_kind = 'ana';
    end if;

    if it.quantity is not null then
      if (select cumulative_quantity from public.hakedis_lines
           where hakedis_id = h.id and item_key = it.item_key and line_kind = 'ana') > it.quantity then
        v_msgs := v_msgs || format('%s: kümülatif miktar sözleşme miktarını (%s %s) aşıyor',
                                   it.description, it.quantity, it.unit);
      end if;
    end if;
  end loop;

  select coalesce(sum(amount), 0) into v_gross from public.hakedis_lines where hakedis_id = h.id;
  select coalesce(sum(hh.gross_amount), 0) into v_prev_gross
    from public.hakedis hh where hh.contract_id = c.id and hh.status = 'onaylandi' and hh.id <> h.id;
  if v.total_amount is not null and v_prev_gross + v_gross > v.total_amount then
    v_msgs := v_msgs || format('Kümülatif brüt hakediş (%s) sözleşme bedelini (%s) aşıyor', v_prev_gross + v_gross, v.total_amount);
  end if;

  -- Vergi ve sözleşmesel kesintiler: dönem sonunda geçerli, doğrulanmış kural.
  v_kdv := 0;
  for t in select vt.tax_code from public.contract_version_taxes vt where vt.version_id = v.id order by vt.tax_code loop
    select * into r from public.tax_rules tr
     where tr.code = t.tax_code and tr.is_active and tr.verified_at is not null
       and tr.valid_from <= h.period_end and (tr.valid_to is null or tr.valid_to >= h.period_end)
     order by tr.valid_from desc limit 1;
    if not found then
      raise exception '% kodlu vergi/kesinti kuralı için % tarihinde geçerli ve doğrulanmış oran yok; kuralı tanımlayıp doğrulayın',
        t.tax_code, to_char(h.period_end, 'DD.MM.YYYY') using errcode = 'check_violation';
    end if;
    if r.kind = 'kdv' then
      insert into public.hakedis_adjustments (hakedis_id, kind, tax_code, base_amount, rate, amount, description)
      values (h.id, 'kdv', r.code, greatest(v_gross, 0), r.rate, round(greatest(v_gross, 0) * r.rate / 100, 2), r.name);
    end if;
  end loop;
  select coalesce(sum(amount), 0) into v_kdv from public.hakedis_adjustments where hakedis_id = h.id and kind = 'kdv';
  for t in select vt.tax_code from public.contract_version_taxes vt where vt.version_id = v.id order by vt.tax_code loop
    select * into r from public.tax_rules tr
     where tr.code = t.tax_code and tr.is_active and tr.verified_at is not null
       and tr.valid_from <= h.period_end and (tr.valid_to is null or tr.valid_to >= h.period_end)
     order by tr.valid_from desc limit 1;
    if r.kind <> 'kdv' then
      insert into public.hakedis_adjustments (hakedis_id, kind, tax_code, base_amount, rate, amount, description)
      values (h.id, case r.kind when 'stopaj' then 'stopaj'::public.hakedis_adjustment_kind
                                else 'diger_kesinti'::public.hakedis_adjustment_kind end,
              r.code, case r.base when 'kdv' then v_kdv else greatest(v_gross, 0) end, r.rate,
              round((case r.base when 'kdv' then v_kdv else greatest(v_gross, 0) end) * r.rate / 100, 2), r.name);
    end if;
  end loop;

  if v.retention_rate > 0 then
    insert into public.hakedis_adjustments (hakedis_id, kind, base_amount, rate, amount, description)
    values (h.id, 'teminat', greatest(v_gross, 0), v.retention_rate,
            round(greatest(v_gross, 0) * v.retention_rate / 100, 2), 'Teminat kesintisi');
  end if;

  select coalesce(sum(amount) filter (where kind = 'stopaj'), 0),
         coalesce(sum(amount) filter (where kind = 'diger_kesinti'), 0),
         coalesce(sum(amount) filter (where kind = 'teminat'), 0),
         coalesce(sum(amount) filter (where kind = 'avans_mahsubu'), 0)
    into v_stopaj, v_other, v_ret, v_adv
    from public.hakedis_adjustments where hakedis_id = h.id;

  update public.hakedis
     set gross_amount = v_gross, kdv_amount = v_kdv, tax_deduction_amount = v_stopaj,
         other_deduction_amount = v_other, retention_amount = v_ret, advance_amount = v_adv,
         payable_amount = v_gross + v_kdv - v_stopaj - v_other - v_ret - v_adv,
         limit_exceeded = cardinality(v_msgs) > 0, limit_messages = v_msgs,
         -- Tutar değişirse önceki limit izni geçersizdir.
         limit_override_reason = case when v_gross = h.gross_amount then h.limit_override_reason end,
         limit_override_by     = case when v_gross = h.gross_amount then h.limit_override_by end,
         limit_override_at     = case when v_gross = h.gross_amount then h.limit_override_at end
   where id = h.id;
end;
$$;

-- -----------------------------------------------------------------------------
-- RLS: tablolar yalnızca okunur; yazma RPC'lerle.
-- -----------------------------------------------------------------------------
alter table public.tax_rules              enable row level security;
alter table public.payment_sources        enable row level security;
alter table public.contracts              enable row level security;
alter table public.contract_versions      enable row level security;
alter table public.contract_items         enable row level security;
alter table public.contract_version_taxes enable row level security;
alter table public.work_quantities        enable row level security;
alter table public.hakedis                enable row level security;
alter table public.hakedis_lines          enable row level security;
alter table public.hakedis_quantity_links enable row level security;
alter table public.hakedis_puantaj_links  enable row level security;
alter table public.hakedis_adjustments    enable row level security;
alter table public.teminat_releases       enable row level security;
alter table public.finance_payments       enable row level security;
alter table public.finance_events         enable row level security;

create policy tax_rules_select on public.tax_rules
  for select to authenticated using (private.is_active_user());
create policy payment_sources_select on public.payment_sources
  for select to authenticated using (private.is_active_user());
create policy contracts_select on public.contracts
  for select to authenticated using (private.has_permission('sozlesme.read', project_id));
create policy contract_versions_select on public.contract_versions
  for select to authenticated
  using (exists (select 1 from public.contracts c where c.id = contract_id));
create policy contract_items_select on public.contract_items
  for select to authenticated
  using (exists (select 1 from public.contracts c where c.id = contract_id));
create policy contract_version_taxes_select on public.contract_version_taxes
  for select to authenticated
  using (exists (select 1 from public.contract_versions cv where cv.id = version_id));
create policy work_quantities_select on public.work_quantities
  for select to authenticated using (private.has_permission('imalat.read', project_id));
create policy hakedis_select on public.hakedis
  for select to authenticated using (private.has_permission('hakedis.read', project_id));
create policy hakedis_lines_select on public.hakedis_lines
  for select to authenticated using (exists (select 1 from public.hakedis h where h.id = hakedis_id));
create policy hakedis_quantity_links_select on public.hakedis_quantity_links
  for select to authenticated using (exists (select 1 from public.hakedis h where h.id = hakedis_id));
create policy hakedis_puantaj_links_select on public.hakedis_puantaj_links
  for select to authenticated using (exists (select 1 from public.hakedis h where h.id = hakedis_id));
create policy hakedis_adjustments_select on public.hakedis_adjustments
  for select to authenticated using (exists (select 1 from public.hakedis h where h.id = hakedis_id));
create policy teminat_releases_select on public.teminat_releases
  for select to authenticated using (private.has_permission('hakedis.read', project_id));
create policy finance_payments_select on public.finance_payments
  for select to authenticated using (private.has_permission('hakedis.read', project_id));
create policy finance_events_select on public.finance_events
  for select to authenticated
  using (private.has_permission('hakedis.read', project_id)
         or (entity = 'sozlesme' and private.has_permission('sozlesme.read', project_id))
         or (entity = 'imalat' and private.has_permission('imalat.read', project_id)));

-- -----------------------------------------------------------------------------
-- Vergi kuralları ve ödeme kaynakları
-- -----------------------------------------------------------------------------
create or replace function public.save_tax_rule(
  p_id uuid, p_code text, p_name text, p_kind public.tax_rule_kind, p_rate numeric, p_valid_from date,
  p_base text default 'brut', p_valid_to date default null, p_notes text default null, p_is_active boolean default true)
returns public.tax_rules
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.tax_rules;
begin
  if not private.has_permission('vergi.manage', null) then
    raise exception 'Vergi kuralı tanımlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  insert into public.tax_rules (id, code, name, kind, rate, base, valid_from, valid_to, notes, is_active)
  values (coalesce(p_id, gen_random_uuid()), upper(trim(p_code)), trim(p_name), p_kind, p_rate, p_base,
          p_valid_from, p_valid_to, p_notes, p_is_active)
  on conflict (id) do update
     set name = excluded.name, kind = excluded.kind, rate = excluded.rate, base = excluded.base,
         code = excluded.code, valid_from = excluded.valid_from, valid_to = excluded.valid_to,
         notes = excluded.notes, is_active = excluded.is_active
  returning * into v_row;
  return v_row;
end;
$$;

-- Oranın mevzuata uygunluğunu kullanıcı doğrular; doğrulanmamış kural hakedişte kullanılmaz.
create or replace function public.verify_tax_rule(p_id uuid)
returns public.tax_rules
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.tax_rules;
begin
  if not private.has_permission('vergi.manage', null) then
    raise exception 'Vergi kuralı doğrulama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  update public.tax_rules set verified_at = now(), verified_by = auth.uid()
   where id = p_id and verified_at is null
  returning * into v_row;
  if not found then
    select * into v_row from public.tax_rules where id = p_id;
    if not found then
      raise exception 'Vergi kuralı bulunamadı' using errcode = 'no_data_found';
    end if;
  end if;
  return v_row;
end;
$$;

create or replace function public.save_payment_source(p_id uuid, p_name text, p_kind text default 'sirket',
                                                      p_notes text default null, p_is_active boolean default true)
returns public.payment_sources
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.payment_sources;
begin
  if not private.has_permission('odeme.write', null) then
    raise exception 'Ödeme kaynağı tanımlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  insert into public.payment_sources (id, name, kind, notes, is_active)
  values (coalesce(p_id, gen_random_uuid()), trim(p_name), p_kind, p_notes, p_is_active)
  on conflict (id) do update set name = excluded.name, kind = excluded.kind, notes = excluded.notes,
                                  is_active = excluded.is_active
  returning * into v_row;
  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- Sözleşme kaydı: yeni sözleşme (revizyon 0, taslak) ya da açık taslak
-- revizyonun güncellenmesi. Kalemler jsonb dizisi olarak bütünüyle gönderilir.
-- -----------------------------------------------------------------------------
create or replace function public.save_contract(
  p_contract_id            uuid,
  p_project_id             uuid,
  p_subcontractor_id       uuid,
  p_contract_no            text,
  p_title                  text,
  p_items                  jsonb,
  p_signed_date            date    default null,
  p_currency               text    default 'TRY',
  p_scope                  text    default null,
  p_start_date             date    default null,
  p_end_date               date    default null,
  p_total_amount           numeric default null,
  p_retention_rate         numeric default 0,
  p_advance_deduction_rate numeric default null,
  p_payment_terms          text    default null,
  p_notes                  text    default null,
  p_tax_codes              text[]  default '{}',
  p_expected_version       integer default null)
returns public.contracts
language plpgsql
security definer
set search_path = ''
as $$
declare
  c     public.contracts;
  v     public.contract_versions;
  s     public.subcontractors;
  pr    public.projects;
  ca    public.cari_accounts;
  x     record;
  v_n   integer := 0;
  v_key uuid;
begin
  if not private.has_permission('sozlesme.write', p_project_id) then
    raise exception 'Sözleşme yazma yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Sözleşmede en az bir kalem olmalı' using errcode = 'check_violation';
  end if;

  select * into c from public.contracts where id = p_contract_id for update;
  if found then
    if c.project_id <> p_project_id or c.subcontractor_id <> p_subcontractor_id then
      raise exception 'Sözleşmenin projesi veya taşeronu değiştirilemez' using errcode = 'check_violation';
    end if;
    if p_expected_version is not null and c.version <> p_expected_version then
      raise exception 'Sözleşme siz düzenlerken değişti; yenileyip tekrar deneyin' using errcode = 'serialization_failure';
    end if;
    if c.status in ('kapandi', 'iptal') then
      raise exception 'Kapanan veya iptal edilen sözleşme değiştirilemez' using errcode = 'check_violation';
    end if;
    select * into v from public.contract_versions where contract_id = c.id and status = 'taslak' for update;
    if not found then
      raise exception 'Onaylı sözleşme değiştirilemez; önce revizyon başlatın' using errcode = 'check_violation';
    end if;
    update public.contracts
       set contract_no = trim(p_contract_no), title = trim(p_title), signed_date = p_signed_date,
           currency = case when c.status = 'taslak' then upper(p_currency) else c.currency end
     where id = c.id returning * into c;
    if c.status <> 'taslak' and upper(p_currency) <> c.currency then
      raise exception 'Onaylanmış sözleşmenin para birimi değiştirilemez' using errcode = 'check_violation';
    end if;
  else
    select * into pr from public.projects where id = p_project_id and deleted_at is null;
    if not found then
      raise exception 'Proje bulunamadı' using errcode = 'foreign_key_violation';
    end if;
    select * into s from public.subcontractors where id = p_subcontractor_id and deleted_at is null and is_active;
    if not found then
      raise exception 'Taşeron bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
    if s.cari_account_id is null then
      raise exception '% taşeronunun cari kartı yok; sözleşmeden önce taşerona mevcut cari kartını bağlayın', s.name
        using errcode = 'check_violation';
    end if;
    select * into ca from public.cari_accounts where id = s.cari_account_id;
    if pr.is_demo <> s.is_demo or pr.is_demo <> ca.is_demo then
      raise exception 'Demo kayıtlar gerçek kayıtlarla aynı sözleşmede kullanılamaz' using errcode = 'check_violation';
    end if;
    insert into public.contracts (id, contract_no, project_id, subcontractor_id, cari_account_id, title, signed_date,
                                  currency, is_demo)
    values (coalesce(p_contract_id, gen_random_uuid()), trim(p_contract_no), p_project_id, p_subcontractor_id,
            s.cari_account_id, trim(p_title), p_signed_date, upper(p_currency), pr.is_demo)
    returning * into c;
    insert into public.contract_versions (contract_id, revision, reason)
    values (c.id, 0, 'İlk sözleşme') returning * into v;
    perform private.fin_event('sozlesme', c.id, c.id, c.project_id, 'olustur', null, 'taslak');
  end if;

  update public.contract_versions
     set scope = p_scope, start_date = p_start_date, end_date = p_end_date, total_amount = p_total_amount,
         retention_rate = coalesce(p_retention_rate, 0), advance_deduction_rate = p_advance_deduction_rate,
         payment_terms = p_payment_terms, notes = p_notes
   where id = v.id;

  delete from public.contract_items where version_id = v.id;
  for x in select * from jsonb_to_recordset(p_items) as t (
             item_key uuid, method public.contract_item_method, description text, unit text, quantity numeric,
             unit_price numeric, overtime_unit_price numeric, paid_bases text[], personnel_id uuid)
  loop
    v_n := v_n + 1;
    v_key := coalesce(x.item_key, gen_random_uuid());
    if x.personnel_id is not null and not exists (
         select 1 from public.personnel p where p.id = x.personnel_id and p.subcontractor_id = c.subcontractor_id) then
      raise exception 'Kişiye özel günlük fiyat yalnızca sözleşmenin taşeron personeline verilir' using errcode = 'check_violation';
    end if;
    insert into public.contract_items (version_id, contract_id, item_key, line_no, method, description, unit, quantity,
                                       unit_price, overtime_unit_price, paid_bases, personnel_id)
    values (v.id, c.id, v_key, v_n, x.method, trim(x.description),
            case x.method when 'gunluk' then 'adam_gun' when 'goturu' then 'goturu' else x.unit end,
            case when x.method = 'goturu' then null else x.quantity end,
            x.unit_price, x.overtime_unit_price, coalesce(x.paid_bases, '{calisilan_gun}'), x.personnel_id);
  end loop;

  delete from public.contract_version_taxes where version_id = v.id;
  insert into public.contract_version_taxes (version_id, tax_code)
  select v.id, upper(trim(code)) from unnest(coalesce(p_tax_codes, '{}')) as code
   where length(trim(code)) > 0 group by upper(trim(code));
  if exists (select 1 from public.contract_version_taxes vt where vt.version_id = v.id
              and not exists (select 1 from public.tax_rules tr where tr.code = vt.tax_code)) then
    raise exception 'Tanımlı olmayan vergi/kesinti kodu seçildi' using errcode = 'foreign_key_violation';
  end if;

  select * into c from public.contracts where id = c.id;
  return c;
end;
$$;

-- -----------------------------------------------------------------------------
-- Sözleşme durum işlemleri
--   onayla   : taslak revizyonu onaylar (önceki onaylı revizyon yerine geçilir)
--   revizyon : onaylı revizyondan yeni taslak revizyon açar (gerekçe zorunlu)
--   kapat    : açık hakedişi olmayan aktif sözleşmeyi kapatır
--   iptal    : hiç onaylanmamış sözleşmeyi iptal eder
-- -----------------------------------------------------------------------------
create or replace function public.contract_transition(
  p_contract_id uuid, p_action text, p_reason text default null, p_expected_version integer default null)
returns public.contracts
language plpgsql
security definer
set search_path = ''
as $$
declare
  c      public.contracts;
  v      public.contract_versions;
  v_old  public.contract_versions;
  v_new  public.contract_versions;
  x      record;
  v_prev text;
begin
  select * into c from public.contracts where id = p_contract_id for update;
  if not found or not private.has_permission('sozlesme.read', c.project_id) then
    raise exception 'Sözleşme bulunamadı' using errcode = 'no_data_found';
  end if;
  if p_expected_version is not null and c.version <> p_expected_version then
    raise exception 'Sözleşme siz bakarken değişti; yenileyip tekrar deneyin' using errcode = 'serialization_failure';
  end if;
  v_prev := c.status::text;

  if p_action = 'onayla' then
    if not private.has_permission('sozlesme.approve', c.project_id) then
      raise exception 'Sözleşme onaylama yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    select * into v from public.contract_versions where contract_id = c.id and status = 'taslak' for update;
    if not found then
      raise exception 'Onaylanacak taslak revizyon yok' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.contract_items where version_id = v.id) then
      raise exception 'Sözleşmede en az bir kalem olmalı' using errcode = 'check_violation';
    end if;
    select * into v_old from public.contract_versions where contract_id = c.id and status = 'onaylandi' for update;
    if found then
      -- Kullanılmış kalem kaldırılamaz; miktarı kullanılanın altına inemez.
      for x in select ci.item_key, ci.description, u.quantity as used
                 from public.contract_items ci
                 cross join lateral private.contract_item_usage(c.id, ci.item_key) u
                where ci.version_id = v_old.id and u.quantity <> 0 loop
        if not exists (select 1 from public.contract_items n where n.version_id = v.id and n.item_key = x.item_key) then
          raise exception '% kalemi önceki hakedişlerde kullanıldı; revizyonda kaldırılamaz', x.description
            using errcode = 'check_violation';
        end if;
        if exists (select 1 from public.contract_items n where n.version_id = v.id and n.item_key = x.item_key
                    and n.quantity is not null and n.quantity < x.used) then
          raise exception '% kaleminin miktarı gerçekleşen miktarın (%) altına indirilemez', x.description, x.used
            using errcode = 'check_violation';
        end if;
      end loop;
      update public.contract_versions set status = 'yerine_gecildi', superseded_at = now() where id = v_old.id;
    end if;
    update public.contract_versions set status = 'onaylandi', approved_at = now(), approved_by = auth.uid()
     where id = v.id returning * into v_new;
    update public.contracts set status = 'aktif' where id = c.id returning * into c;
    perform private.fin_event('sozlesme', c.id, c.id, c.project_id, 'onayla', v_prev, 'aktif', p_reason,
      jsonb_build_object('revision', v_new.revision, 'version_id', v_new.id,
                         'items', (select jsonb_agg(to_jsonb(ci) order by ci.line_no) from public.contract_items ci
                                    where ci.version_id = v_new.id)));

  elsif p_action = 'revizyon' then
    if not private.has_permission('sozlesme.write', c.project_id) then
      raise exception 'Sözleşme revizyonu açma yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if length(coalesce(trim(p_reason), '')) < 10 then
      raise exception 'Revizyon gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
    end if;
    if c.status <> 'aktif' then
      raise exception 'Yalnızca aktif sözleşmede revizyon açılır' using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.contract_versions where contract_id = c.id and status = 'taslak') then
      raise exception 'Açık bir taslak revizyon zaten var' using errcode = 'check_violation';
    end if;
    select * into v_old from public.contract_versions where contract_id = c.id and status = 'onaylandi';
    insert into public.contract_versions (contract_id, revision, scope, start_date, end_date, total_amount,
                                          retention_rate, advance_deduction_rate, payment_terms, notes, reason)
    select c.id, (select max(revision) + 1 from public.contract_versions where contract_id = c.id),
           v_old.scope, v_old.start_date, v_old.end_date, v_old.total_amount, v_old.retention_rate,
           v_old.advance_deduction_rate, v_old.payment_terms, v_old.notes, trim(p_reason)
    returning * into v_new;
    insert into public.contract_items (version_id, contract_id, item_key, line_no, method, description, unit, quantity,
                                       unit_price, overtime_unit_price, paid_bases, personnel_id)
    select v_new.id, c.id, item_key, line_no, method, description, unit, quantity, unit_price, overtime_unit_price,
           paid_bases, personnel_id
      from public.contract_items where version_id = v_old.id;
    insert into public.contract_version_taxes (version_id, tax_code)
    select v_new.id, tax_code from public.contract_version_taxes where version_id = v_old.id;
    update public.contracts set updated_at = now() where id = c.id returning * into c;
    perform private.fin_event('sozlesme', c.id, c.id, c.project_id, 'revizyon', v_prev, v_prev, p_reason,
                              jsonb_build_object('revision', v_new.revision));

  elsif p_action = 'kapat' then
    if not private.has_permission('sozlesme.approve', c.project_id) then
      raise exception 'Sözleşme kapatma yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if c.status <> 'aktif' then
      raise exception 'Yalnızca aktif sözleşme kapatılır' using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.hakedis where contract_id = c.id and status in ('taslak', 'incelemede')) then
      raise exception 'Açık hakedişi olan sözleşme kapatılamaz' using errcode = 'check_violation';
    end if;
    update public.contracts set status = 'kapandi', closed_at = now(), closed_by = auth.uid(),
                                close_reason = nullif(trim(p_reason), '')
     where id = c.id returning * into c;
    perform private.fin_event('sozlesme', c.id, c.id, c.project_id, 'kapat', v_prev, 'kapandi', p_reason);

  elsif p_action = 'iptal' then
    if not private.has_permission('sozlesme.write', c.project_id) then
      raise exception 'Sözleşme iptal yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if c.status <> 'taslak' then
      raise exception 'Onaylanmış sözleşme iptal edilemez; kapatın' using errcode = 'check_violation';
    end if;
    update public.contracts set status = 'iptal', closed_at = now(), closed_by = auth.uid(),
                                close_reason = nullif(trim(p_reason), '')
     where id = c.id returning * into c;
    perform private.fin_event('sozlesme', c.id, c.id, c.project_id, 'iptal', v_prev, 'iptal', p_reason);
  else
    raise exception 'Geçersiz sözleşme işlemi: %', p_action using errcode = 'invalid_parameter_value';
  end if;
  return c;
end;
$$;

-- -----------------------------------------------------------------------------
-- İmalat (metraj) kayıtları. Fiyat görmeyen şantiye kullanıcısı da girer.
-- -----------------------------------------------------------------------------
create or replace function public.save_work_quantity(
  p_id uuid, p_contract_id uuid, p_item_key uuid, p_work_date date, p_quantity numeric,
  p_location text default null, p_note text default null)
returns public.work_quantities
language plpgsql
security definer
set search_path = ''
as $$
declare
  c     public.contracts;
  w     public.work_quantities;
begin
  select * into c from public.contracts where id = p_contract_id;
  if not found or not private.has_permission('imalat.write', c.project_id) then
    raise exception 'İmalat girme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if c.status <> 'aktif' then
    raise exception 'İmalat yalnızca aktif sözleşmeye girilir' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.contract_items ci join public.contract_versions v on v.id = ci.version_id
                  where v.contract_id = c.id and v.status = 'onaylandi' and ci.item_key = p_item_key
                    and ci.method = 'birim_fiyat') then
    raise exception 'İmalat yalnızca sözleşmenin birim fiyatlı kalemine girilir' using errcode = 'check_violation';
  end if;
  if p_work_date > private.today() then
    raise exception 'İleri tarihli imalat girilemez' using errcode = 'check_violation';
  end if;

  select * into w from public.work_quantities where id = p_id for update;
  if found then
    if w.status <> 'taslak' or w.contract_id <> p_contract_id then
      raise exception 'Onaylanmış imalat değiştirilemez; iptal edip yeniden girin' using errcode = 'check_violation';
    end if;
    update public.work_quantities
       set item_key = p_item_key, work_date = p_work_date, quantity = p_quantity,
           location = nullif(trim(p_location), ''), note = nullif(trim(p_note), '')
     where id = p_id returning * into w;
  else
    insert into public.work_quantities (id, contract_id, project_id, item_key, work_date, quantity, location, note, is_demo)
    values (p_id, c.id, c.project_id, p_item_key, p_work_date, p_quantity, nullif(trim(p_location), ''),
            nullif(trim(p_note), ''), c.is_demo)
    returning * into w;
  end if;
  return w;
end;
$$;

create or replace function public.approve_work_quantities(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if exists (select 1 from public.work_quantities w
              where w.id = any (p_ids) and not private.has_permission('imalat.approve', w.project_id)) then
    raise exception 'İmalat onaylama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  with upd as (
    update public.work_quantities set status = 'onaylandi', approved_at = now(), approved_by = auth.uid()
     where id = any (p_ids) and status = 'taslak'
    returning id, contract_id, project_id)
  insert into public.finance_events (entity, entity_id, contract_id, project_id, action, from_status, to_status)
  select 'imalat', upd.id, upd.contract_id, upd.project_id, 'onayla', 'taslak', 'onaylandi' from upd;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.cancel_work_quantity(p_id uuid, p_reason text)
returns public.work_quantities
language plpgsql
security definer
set search_path = ''
as $$
declare
  w public.work_quantities;
begin
  select * into w from public.work_quantities where id = p_id for update;
  if not found or not private.has_permission('imalat.write', w.project_id) then
    raise exception 'İmalat bulunamadı veya yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if w.status <> 'taslak' and not private.has_permission('imalat.approve', w.project_id) then
    raise exception 'Onaylı imalatı yalnızca onay yetkisi olan iptal eder' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from public.hakedis_quantity_links l join public.hakedis h on h.id = l.hakedis_id
              where l.work_quantity_id = p_id and l.active and h.status = 'onaylandi') then
    raise exception 'Onaylı hakedişte kullanılan imalat iptal edilemez; önce hakedişi iptal edin' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_reason), '')) = 0 then
    raise exception 'İptal gerekçesi zorunlu' using errcode = 'check_violation';
  end if;
  update public.work_quantities set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(),
                                    cancel_reason = trim(p_reason)
   where id = p_id returning * into w;
  perform private.fin_event('imalat', w.id, w.contract_id, w.project_id, 'iptal', null, 'iptal', p_reason);
  return w;
end;
$$;

-- Şantiye için imalat kalemleri: fiyat ve tutar içermez.
create or replace function public.imalat_items(p_project_id uuid)
returns table (contract_id uuid, contract_no text, subcontractor_name text, item_key uuid, description text,
               unit text, contract_quantity numeric, approved_quantity numeric, pending_quantity numeric)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.has_permission('imalat.read', p_project_id) then
    raise exception 'İmalat görme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  return query
  select c.id, c.contract_no, s.name, ci.item_key, ci.description, ci.unit, ci.quantity,
         coalesce((select sum(w.quantity) from public.work_quantities w
                    where w.contract_id = c.id and w.item_key = ci.item_key and w.status = 'onaylandi'), 0),
         coalesce((select sum(w.quantity) from public.work_quantities w
                    where w.contract_id = c.id and w.item_key = ci.item_key and w.status = 'taslak'), 0)
    from public.contracts c
    join public.subcontractors s on s.id = c.subcontractor_id
    join public.contract_versions v on v.contract_id = c.id and v.status = 'onaylandi'
    join public.contract_items ci on ci.version_id = v.id and ci.method = 'birim_fiyat'
   where c.project_id = p_project_id and c.status = 'aktif'
   order by c.contract_no, ci.line_no;
end;
$$;

-- -----------------------------------------------------------------------------
-- Hakediş işlemleri
-- -----------------------------------------------------------------------------
create or replace function public.create_hakedis(
  p_id uuid, p_contract_id uuid, p_period_start date, p_period_end date, p_note text default null)
returns public.hakedis
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.contracts;
  v public.contract_versions;
  h public.hakedis;
begin
  select * into c from public.contracts where id = p_contract_id for update;
  if not found or not private.has_permission('hakedis.prepare', c.project_id) then
    raise exception 'Hakediş hazırlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select * into h from public.hakedis where id = p_id;
  if found then
    if h.contract_id = p_contract_id then
      return h;  -- aynı isteğin tekrarı
    end if;
    raise exception 'Bu kimlikle başka bir hakediş var' using errcode = 'unique_violation';
  end if;
  if c.status <> 'aktif' then
    raise exception 'Hakediş yalnızca aktif (onaylı) sözleşmeye açılır' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.hakedis where contract_id = c.id and status in ('taslak', 'incelemede')) then
    raise exception 'Bu sözleşmede açık bir hakediş var; önce onu sonuçlandırın' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.hakedis where contract_id = c.id and status = 'onaylandi' and period_end >= p_period_start) then
    raise exception 'Dönem, önceki onaylı hakedişin dönemiyle çakışıyor' using errcode = 'check_violation';
  end if;
  select * into v from public.contract_versions where contract_id = c.id and status = 'onaylandi';
  insert into public.hakedis (id, contract_id, version_id, project_id, subcontractor_id, cari_account_id, hakedis_no,
                              period_start, period_end, currency, note, is_demo)
  values (p_id, c.id, v.id, c.project_id, c.subcontractor_id, c.cari_account_id,
          coalesce((select max(hakedis_no) from public.hakedis where contract_id = c.id), 0) + 1,
          p_period_start, p_period_end, c.currency, nullif(trim(p_note), ''), c.is_demo)
  returning * into h;
  perform private.hakedis_refresh(h.id);
  perform private.fin_event('hakedis', h.id, c.id, c.project_id, 'olustur', null, 'taslak');
  select * into h from public.hakedis where id = h.id;
  return h;
end;
$$;

create or replace function public.refresh_hakedis(p_hakedis_id uuid)
returns public.hakedis
language plpgsql
security definer
set search_path = ''
as $$
declare
  h public.hakedis;
begin
  select * into h from public.hakedis where id = p_hakedis_id;
  if not found or not private.has_permission('hakedis.prepare', h.project_id) then
    raise exception 'Hakediş hazırlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  perform 1 from public.contracts where id = h.contract_id for update;
  perform private.hakedis_refresh(h.id);
  select * into h from public.hakedis where id = p_hakedis_id;
  return h;
end;
$$;

-- Götürü kalemin kümülatif ilerleme yüzdesi.
create or replace function public.set_hakedis_progress(p_hakedis_id uuid, p_item_key uuid, p_percent numeric)
returns public.hakedis
language plpgsql
security definer
set search_path = ''
as $$
declare
  h      public.hakedis;
  v_prev numeric;
begin
  -- Kilit sırası her yerde aynı: önce sözleşme, sonra hakediş.
  perform 1 from public.contracts c
   where c.id = (select x.contract_id from public.hakedis x where x.id = p_hakedis_id) for update;
  select * into h from public.hakedis where id = p_hakedis_id for update;
  if not found or not private.has_permission('hakedis.prepare', h.project_id) then
    raise exception 'Hakediş hazırlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if h.status <> 'taslak' then
    raise exception 'Yalnızca taslak hakediş düzenlenir' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.hakedis_lines where hakedis_id = h.id and item_key = p_item_key and method = 'goturu') then
    raise exception 'İlerleme yalnızca götürü kaleme girilir' using errcode = 'check_violation';
  end if;
  select quantity into v_prev from private.contract_item_usage(h.contract_id, p_item_key, h.id);
  if p_percent is null or p_percent < v_prev or p_percent > 100 then
    raise exception 'Kümülatif ilerleme % ile 100 arasında olmalı', v_prev using errcode = 'check_violation';
  end if;
  update public.hakedis_lines set progress_percent = p_percent
   where hakedis_id = h.id and item_key = p_item_key and line_kind = 'ana';
  perform private.hakedis_refresh(h.id);
  select * into h from public.hakedis where id = h.id;
  return h;
end;
$$;

-- Elle girilen kesintiler: avans mahsubu ve diğer kesinti (tutar 0 kaldırır).
create or replace function public.set_hakedis_deduction(
  p_hakedis_id uuid, p_kind public.hakedis_adjustment_kind, p_amount numeric, p_description text default null)
returns public.hakedis
language plpgsql
security definer
set search_path = ''
as $$
declare
  h public.hakedis;
begin
  -- Kilit sırası her yerde aynı: önce sözleşme, sonra hakediş.
  perform 1 from public.contracts c
   where c.id = (select x.contract_id from public.hakedis x where x.id = p_hakedis_id) for update;
  select * into h from public.hakedis where id = p_hakedis_id for update;
  if not found or not private.has_permission('hakedis.prepare', h.project_id) then
    raise exception 'Hakediş hazırlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if h.status <> 'taslak' then
    raise exception 'Yalnızca taslak hakediş düzenlenir' using errcode = 'check_violation';
  end if;
  if p_kind not in ('avans_mahsubu', 'diger_kesinti') then
    raise exception 'Bu kesinti elle girilemez; sözleşme kuralından hesaplanır' using errcode = 'invalid_parameter_value';
  end if;
  if p_amount is null or p_amount < 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Kesinti tutarı sıfır veya pozitif, en çok iki ondalıklı olmalı' using errcode = 'check_violation';
  end if;
  if p_kind = 'avans_mahsubu' and p_amount > private.open_advance(h.cari_account_id, h.project_id) then
    raise exception 'Avans mahsubu açık avans tutarını (%) aşıyor',
      private.open_advance(h.cari_account_id, h.project_id) using errcode = 'check_violation';
  end if;
  delete from public.hakedis_adjustments where hakedis_id = h.id and kind = p_kind and is_manual;
  if p_amount > 0 then
    insert into public.hakedis_adjustments (hakedis_id, kind, amount, description, is_manual)
    values (h.id, p_kind, p_amount,
            coalesce(nullif(trim(p_description), ''), case p_kind when 'avans_mahsubu' then 'Avans mahsubu' else 'Diğer kesinti' end),
            true);
  end if;
  perform private.hakedis_refresh(h.id);
  select * into h from public.hakedis where id = h.id;
  return h;
end;
$$;

-- Limit aşımı için açık yetki (gerekçe kaydedilir; tutar değişirse düşer).
create or replace function public.override_hakedis_limit(p_hakedis_id uuid, p_reason text)
returns public.hakedis
language plpgsql
security definer
set search_path = ''
as $$
declare
  h public.hakedis;
begin
  -- Kilit sırası her yerde aynı: önce sözleşme, sonra hakediş.
  perform 1 from public.contracts c
   where c.id = (select x.contract_id from public.hakedis x where x.id = p_hakedis_id) for update;
  select * into h from public.hakedis where id = p_hakedis_id for update;
  if not found or not private.has_permission('hakedis.limit_override', h.project_id) then
    raise exception 'Limit aşımı izni verme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if h.status not in ('taslak', 'incelemede') or not h.limit_exceeded then
    raise exception 'Bu hakedişte izin gerektiren limit aşımı yok' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_reason), '')) < 10 then
    raise exception 'Gerekçe en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;
  update public.hakedis set limit_override_reason = trim(p_reason), limit_override_by = auth.uid(), limit_override_at = now()
   where id = h.id returning * into h;
  perform private.fin_event('hakedis', h.id, h.contract_id, h.project_id, 'limit_izni', h.status::text, h.status::text,
                            p_reason, jsonb_build_object('messages', to_jsonb(h.limit_messages)));
  return h;
end;
$$;

-- Onaylı hakedişin iptali (deftere işlendiyse ters kayıtla).
create or replace function private.hakedis_cancel(h public.hakedis, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_adj record;
begin
  if h.status = 'onaylandi' then
    if exists (select 1 from public.finance_payments p where p.hakedis_id = h.id and p.status = 'aktif') then
      raise exception 'Ödemesi kaydedilmiş hakediş iptal edilemez; önce ödemeyi iptal edin' using errcode = 'check_violation';
    end if;
    if h.posted_at is not null and private.contract_retention_balance(h.contract_id) < h.retention_amount then
      raise exception 'Bu hakedişin teminatı serbest bırakılmış; önce serbest bırakmayı iptal edin' using errcode = 'check_violation';
    end if;
    if h.posted_at is not null then
      for v_adj in select cari_entry_id from public.hakedis_adjustments
                    where hakedis_id = h.id and cari_entry_id is not null loop
        perform private.fin_reverse_entry(v_adj.cari_entry_id, p_reason);
      end loop;
      perform private.fin_reverse_entry(h.cari_entry_id, p_reason);
    end if;
  end if;
  update public.hakedis_quantity_links set active = false where hakedis_id = h.id;
  update public.hakedis_puantaj_links  set active = false where hakedis_id = h.id;
  update public.hakedis set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(),
                            cancel_reason = nullif(trim(p_reason), '')
   where id = h.id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Hakediş durum işlemleri
--   gonder : taslak → incelemede (hakedis.prepare)
--   iade   : incelemede → taslak (hakedis.prepare)
--   onayla : incelemede → onaylandi (hakedis.approve; kaynaklar yeniden
--            denetlenir, limitler ve avans kontrol edilir, snapshot alınır)
--   iptal  : taslak/incelemede (hakedis.prepare) veya onaylı (hakedis.approve,
--            gerekçe ≥ 10; deftere işlendiyse ters kayıt)
-- -----------------------------------------------------------------------------
create or replace function public.hakedis_transition(
  p_hakedis_id uuid, p_action text, p_reason text default null, p_expected_version integer default null)
returns public.hakedis
language plpgsql
security definer
set search_path = ''
as $$
declare
  h        public.hakedis;
  v_before integer;
  v_prev   text;
  v_open   numeric;
begin
  select * into h from public.hakedis where id = p_hakedis_id;
  if not found or not private.has_permission('hakedis.read', h.project_id) then
    raise exception 'Hakediş bulunamadı' using errcode = 'no_data_found';
  end if;
  -- Aynı sözleşmedeki onay, iptal ve deftere işleme sırayla yürür.
  perform 1 from public.contracts where id = h.contract_id for update;
  select * into h from public.hakedis where id = p_hakedis_id for update;
  if p_expected_version is not null and h.version <> p_expected_version then
    raise exception 'Hakediş siz bakarken değişti; yenileyip tekrar deneyin' using errcode = 'serialization_failure';
  end if;
  v_prev := h.status::text;

  if p_action = 'gonder' then
    if not private.has_permission('hakedis.prepare', h.project_id) then
      raise exception 'Hakediş hazırlama yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if h.status <> 'taslak' then
      raise exception 'Yalnızca taslak hakediş incelemeye gönderilir' using errcode = 'check_violation';
    end if;
    update public.hakedis set status = 'incelemede', submitted_at = now(), submitted_by = auth.uid()
     where id = h.id returning * into h;

  elsif p_action = 'iade' then
    if not private.has_permission('hakedis.prepare', h.project_id) then
      raise exception 'Hakediş hazırlama yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if h.status <> 'incelemede' then
      raise exception 'Yalnızca incelemedeki hakediş iade edilir' using errcode = 'check_violation';
    end if;
    update public.hakedis set status = 'taslak' where id = h.id returning * into h;

  elsif p_action = 'onayla' then
    if not private.has_permission('hakedis.approve', h.project_id) then
      raise exception 'Hakediş onaylama yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if h.status <> 'incelemede' then
      raise exception 'Yalnızca incelemedeki hakediş onaylanır' using errcode = 'check_violation';
    end if;
    v_before := h.version;
    perform private.hakedis_refresh(h.id);
    select * into h from public.hakedis where id = h.id;
    if h.version <> v_before then
      raise exception 'Hakedişin kaynak verileri (puantaj, imalat veya sözleşme) değişti; yeniden hesaplayıp inceleyin'
        using errcode = 'serialization_failure';
    end if;
    if h.gross_amount <= 0 then
      raise exception 'Brüt hakediş sıfırdan büyük olmalı' using errcode = 'check_violation';
    end if;
    if h.payable_amount < 0 then
      raise exception 'Kesintiler hakediş tutarını aşıyor' using errcode = 'check_violation';
    end if;
    if h.limit_exceeded and h.limit_override_by is null then
      raise exception 'Sözleşme limiti aşılıyor: %. Sözleşme revizyonu onaylayın veya yetkili limit izni verin',
        array_to_string(h.limit_messages, '; ') using errcode = 'check_violation';
    end if;
    select private.open_advance(h.cari_account_id, h.project_id)
           - coalesce((select sum(x.advance_amount) from public.hakedis x
                        where x.cari_account_id = h.cari_account_id and x.project_id = h.project_id
                          and x.status = 'onaylandi' and x.posted_at is null), 0)
      into v_open;
    if h.advance_amount > v_open then
      raise exception 'Avans mahsubu açık avans tutarını (%) aşıyor', v_open using errcode = 'check_violation';
    end if;
    update public.hakedis set status = 'onaylandi', approved_at = now(), approved_by = auth.uid()
     where id = h.id returning * into h;

  elsif p_action = 'iptal' then
    if h.status = 'iptal' then
      raise exception 'Hakediş zaten iptal edilmiş' using errcode = 'check_violation';
    end if;
    if h.status = 'onaylandi' then
      if not private.has_permission('hakedis.approve', h.project_id) then
        raise exception 'Onaylı hakedişi yalnızca onay yetkisi olan iptal eder' using errcode = 'insufficient_privilege';
      end if;
      if length(coalesce(trim(p_reason), '')) < 10 then
        raise exception 'İptal gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
      end if;
    elsif not private.has_permission('hakedis.prepare', h.project_id) then
      raise exception 'Hakediş hazırlama yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    perform private.hakedis_cancel(h, p_reason);
    select * into h from public.hakedis where id = h.id;
  else
    raise exception 'Geçersiz hakediş işlemi: %', p_action using errcode = 'invalid_parameter_value';
  end if;

  perform private.fin_event('hakedis', h.id, h.contract_id, h.project_id, p_action, v_prev, h.status::text, p_reason,
    case when p_action = 'onayla' then jsonb_build_object(
      'totals', jsonb_build_object('gross', h.gross_amount, 'kdv', h.kdv_amount, 'stopaj', h.tax_deduction_amount,
                                   'other', h.other_deduction_amount, 'retention', h.retention_amount,
                                   'advance', h.advance_amount, 'payable', h.payable_amount),
      'version_id', h.version_id,
      'lines', (select jsonb_agg(to_jsonb(l) order by l.item_key, l.line_kind) from public.hakedis_lines l where l.hakedis_id = h.id),
      'adjustments', (select jsonb_agg(to_jsonb(a) order by a.kind, a.tax_code) from public.hakedis_adjustments a where a.hakedis_id = h.id),
      'puantaj', (select jsonb_agg(distinct jsonb_build_object('period_id', l.period_id, 'revision', l.period_revision))
                    from public.hakedis_puantaj_links l where l.hakedis_id = h.id),
      'limit_override', h.limit_override_reason) end);
  return h;
end;
$$;

-- Düzeltme: onaylı hakedişi gerekçeyle iptal eder ve yerine yeni taslak açar
-- (götürü ilerleme ve elle kesintiler kopyalanır; kaynaklar yeniden hesaplanır).
create or replace function public.revise_hakedis(p_hakedis_id uuid, p_new_id uuid, p_reason text)
returns public.hakedis
language plpgsql
security definer
set search_path = ''
as $$
declare
  h     public.hakedis;
  n     public.hakedis;
  v     public.contract_versions;
begin
  select * into h from public.hakedis where id = p_hakedis_id;
  if not found or not private.has_permission('hakedis.prepare', h.project_id) then
    raise exception 'Hakediş hazırlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select * into n from public.hakedis where id = p_new_id;
  if found and n.replaces_id = p_hakedis_id then
    return n;  -- tekrar
  end if;
  h := public.hakedis_transition(p_hakedis_id, 'iptal', p_reason);
  select * into v from public.contract_versions where contract_id = h.contract_id and status = 'onaylandi';
  insert into public.hakedis (id, contract_id, version_id, project_id, subcontractor_id, cari_account_id, hakedis_no,
                              period_start, period_end, currency, note, replaces_id, is_demo)
  values (p_new_id, h.contract_id, v.id, h.project_id, h.subcontractor_id, h.cari_account_id,
          (select max(hakedis_no) from public.hakedis where contract_id = h.contract_id) + 1,
          h.period_start, h.period_end, h.currency, h.note, h.id, h.is_demo)
  returning * into n;
  insert into public.hakedis_lines (hakedis_id, contract_item_id, item_key, line_kind, method, description, unit,
                                    unit_price, progress_percent)
  select n.id, contract_item_id, item_key, line_kind, method, description, unit, unit_price, progress_percent
    from public.hakedis_lines where hakedis_id = h.id and method = 'goturu';
  insert into public.hakedis_adjustments (hakedis_id, kind, amount, description, is_manual)
  select n.id, kind, amount, description, true from public.hakedis_adjustments where hakedis_id = h.id and is_manual;
  perform private.hakedis_refresh(n.id);
  perform private.fin_event('hakedis', n.id, n.contract_id, n.project_id, 'duzeltme', null, 'taslak', p_reason,
                            jsonb_build_object('replaces', h.id, 'replaces_no', h.hakedis_no));
  select * into n from public.hakedis where id = n.id;
  return n;
end;
$$;

-- -----------------------------------------------------------------------------
-- Deftere işleme. Tek işlem, tekrar güvenli (kaynak belge benzersizliği).
--   alacak  hakedis  : brüt + KDV (hakediş faturası)
--   borç    kesinti  : stopaj, teminat, diğer kesintiler (her biri ayrı)
--   eşleştirme       : kesintiler ve avans mahsubu hakediş hareketini kapatır
-- Hakediş hareketinin açık tutarı = ödemeye uygun tutar − ödemeler.
-- -----------------------------------------------------------------------------
create or replace function public.post_hakedis(p_hakedis_id uuid, p_entry_date date default null,
                                               p_exchange_rate numeric default 1)
returns public.hakedis
language plpgsql
security definer
set search_path = ''
as $$
declare
  h        public.hakedis;
  c        public.contracts;
  v_entry  uuid;
  v_adj    record;
  v_av     record;
  v_need   numeric;
  v_take   numeric;
  v_date   date := coalesce(p_entry_date, private.today());
  v_doc    text;
begin
  select * into h from public.hakedis where id = p_hakedis_id;
  if not found or not private.has_permission('hakedis.read', h.project_id) then
    raise exception 'Hakediş bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('hakedis.post', h.project_id) then
    raise exception 'Hakedişi cari deftere işleme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  perform 1 from public.contracts where id = h.contract_id for update;
  select * into h from public.hakedis where id = p_hakedis_id for update;
  if h.posted_at is not null then
    return h;  -- tekrar gönderim ikinci hareket oluşturmaz
  end if;
  if h.status <> 'onaylandi' then
    raise exception 'Yalnızca onaylı hakediş deftere işlenir' using errcode = 'check_violation';
  end if;
  select * into c from public.contracts where id = h.contract_id;
  if c.currency = 'TRY' and p_exchange_rate <> 1 then
    raise exception 'TL hakedişte kur 1 olmalı' using errcode = 'check_violation';
  end if;
  v_doc := c.contract_no || '/' || h.hakedis_no;

  v_entry := gen_random_uuid();
  insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind, amount, currency,
                                   exchange_rate, description, document_no, source_type, source_id)
  values (v_entry, h.cari_account_id, h.project_id, v_date, 'alacak', 'hakedis', h.gross_amount + h.kdv_amount,
          c.currency, p_exchange_rate,
          format('Hakediş %s · %s', h.hakedis_no, c.title), v_doc, 'hakedis', h.id);

  for v_adj in select * from public.hakedis_adjustments
                where hakedis_id = h.id and kind in ('stopaj', 'teminat', 'diger_kesinti') and amount > 0
                order by kind, tax_code loop
    insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind, amount, currency,
                                     exchange_rate, description, document_no, source_type, source_id)
    values (gen_random_uuid(), h.cari_account_id, h.project_id, v_date, 'borc', 'kesinti', v_adj.amount, c.currency,
            p_exchange_rate, format('Hakediş %s · %s', h.hakedis_no, v_adj.description), v_doc,
            'hakedis_kesinti', v_adj.id)
    returning id into v_adj.cari_entry_id;
    update public.hakedis_adjustments set cari_entry_id = v_adj.cari_entry_id where id = v_adj.id;
    insert into public.cari_allocations (payment_entry_id, target_entry_id, amount, note)
    values (v_adj.cari_entry_id, v_entry, v_adj.amount, 'Hakediş kesintisi');
  end loop;

  -- Avans mahsubu: açık avanslardan eskiden yeniye.
  v_need := h.advance_amount;
  if v_need > 0 then
    for v_av in select e.id, e.amount - coalesce((select sum(a.amount) from public.cari_allocations a
                                                  where a.deleted_at is null and e.id in (a.payment_entry_id, a.target_entry_id)), 0) as open
                  from public.cari_entries e
                 where e.cari_account_id = h.cari_account_id and e.project_id = h.project_id and e.kind = 'avans'
                   and e.currency = c.currency
                   and not exists (select 1 from public.cari_entries r where r.reversal_of_id = e.id)
                 order by e.entry_date, e.created_at
                 for update of e loop
      exit when v_need <= 0;
      continue when v_av.open <= 0;
      v_take := least(v_av.open, v_need);
      insert into public.cari_allocations (payment_entry_id, target_entry_id, amount, note)
      values (v_av.id, v_entry, v_take, format('Hakediş %s avans mahsubu', h.hakedis_no));
      v_need := v_need - v_take;
    end loop;
    if v_need > 0 then
      raise exception 'Mahsup edilecek açık avans yetersiz (eksik %)', v_need using errcode = 'check_violation';
    end if;
  end if;

  update public.hakedis set posted_at = now(), posted_by = auth.uid(), cari_entry_id = v_entry
   where id = h.id returning * into h;
  perform private.fin_event('hakedis', h.id, h.contract_id, h.project_id, 'deftere_isle', 'onaylandi', 'onaylandi', null,
                            jsonb_build_object('cari_entry_id', v_entry, 'entry_date', v_date));
  return h;
end;
$$;

-- -----------------------------------------------------------------------------
-- Teminat serbest bırakma: yalnızca bırakılan tutar kadar alacak doğar
-- (teminat_iadesi). Nakit ödeme ayrıca record_finance_payment ile yapılır.
-- -----------------------------------------------------------------------------
create or replace function public.release_teminat(
  p_id uuid, p_contract_id uuid, p_amount numeric, p_reason text, p_release_date date default null)
returns public.teminat_releases
language plpgsql
security definer
set search_path = ''
as $$
declare
  c       public.contracts;
  r       public.teminat_releases;
  v_avail numeric;
  v_entry uuid;
begin
  select * into c from public.contracts where id = p_contract_id;
  if not found or not private.has_permission('teminat.release', c.project_id) then
    raise exception 'Teminat serbest bırakma yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  perform 1 from public.contracts where id = c.id for update;
  select * into r from public.teminat_releases where id = p_id;
  if found then
    if r.contract_id = p_contract_id and r.amount = p_amount then
      return r;  -- tekrar
    end if;
    raise exception 'Bu kimlikle farklı bir serbest bırakma var' using errcode = 'unique_violation';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Tutar pozitif ve en çok iki ondalıklı olmalı' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_reason), '')) < 10 then
    raise exception 'Serbest bırakma gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;
  v_avail := private.contract_retention_balance(c.id);
  if p_amount > v_avail then
    raise exception 'Serbest bırakılabilir teminat %; istenen % ', v_avail, p_amount using errcode = 'check_violation';
  end if;
  v_entry := gen_random_uuid();
  insert into public.teminat_releases (id, contract_id, project_id, cari_account_id, amount, release_date, reason, is_demo)
  values (p_id, c.id, c.project_id, c.cari_account_id, p_amount, coalesce(p_release_date, private.today()), trim(p_reason), c.is_demo)
  returning * into r;
  insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind, amount, currency,
                                   description, document_no, source_type, source_id)
  values (v_entry, c.cari_account_id, c.project_id, r.release_date, 'alacak', 'teminat_iadesi', p_amount, c.currency,
          'Teminat serbest bırakma · ' || c.title, c.contract_no, 'teminat_iade', r.id);
  update public.teminat_releases set cari_entry_id = v_entry where id = r.id returning * into r;
  perform private.fin_event('teminat', r.id, c.id, c.project_id, 'serbest_birak', null, 'aktif', p_reason,
                            jsonb_build_object('amount', p_amount, 'balance_before', v_avail));
  return r;
end;
$$;

create or replace function public.cancel_teminat_release(p_id uuid, p_reason text)
returns public.teminat_releases
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.teminat_releases;
begin
  select * into r from public.teminat_releases where id = p_id;
  if not found or not private.has_permission('teminat.release', r.project_id) then
    raise exception 'Teminat işlemi bulunamadı veya yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  perform 1 from public.contracts where id = r.contract_id for update;
  select * into r from public.teminat_releases where id = p_id for update;
  if r.status = 'iptal' then
    return r;
  end if;
  if length(coalesce(trim(p_reason), '')) < 10 then
    raise exception 'İptal gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.finance_payments p where p.teminat_release_id = r.id and p.status = 'aktif') then
    raise exception 'Ödemesi yapılmış teminat iadesi iptal edilemez; önce ödemeyi iptal edin' using errcode = 'check_violation';
  end if;
  perform private.fin_reverse_entry(r.cari_entry_id, p_reason);
  update public.teminat_releases set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(),
                                     cancel_reason = trim(p_reason)
   where id = r.id returning * into r;
  perform private.fin_event('teminat', r.id, r.contract_id, r.project_id, 'iptal', 'aktif', 'iptal', p_reason);
  return r;
end;
$$;

-- -----------------------------------------------------------------------------
-- Ödeme ve avans. Ödeme kaynağı yalnızca etikettir; yükümlülükten ayrıdır.
-- Hedef (hakediş veya teminat iadesi) verilirse ödeme ona eşleştirilir;
-- açık tutarı aşan ödeme reddedilir.
-- -----------------------------------------------------------------------------
create or replace function public.record_finance_payment(
  p_id uuid, p_contract_id uuid, p_kind text, p_amount numeric, p_payment_source_id uuid,
  p_payment_date date default null, p_hakedis_id uuid default null, p_teminat_release_id uuid default null,
  p_description text default null)
returns public.finance_payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  c        public.contracts;
  p        public.finance_payments;
  h        public.hakedis;
  r        public.teminat_releases;
  v_target uuid;
  v_date   date := coalesce(p_payment_date, private.today());
begin
  select * into c from public.contracts where id = p_contract_id;
  if not found or not private.has_permission('odeme.write', c.project_id) then
    raise exception 'Ödeme kaydetme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  -- Kilit, tekrar gönderim kontrolünden önce alınır: aynı kimlikle eşzamanlı
  -- iki gönderimden ikincisi birincinin bitmesini bekler ve aynı kaydı döner.
  perform 1 from public.contracts where id = c.id for update;
  select * into p from public.finance_payments where id = p_id;
  if found then
    if p.contract_id = p_contract_id and p.amount = p_amount and p.kind = p_kind
       and p.hakedis_id is not distinct from p_hakedis_id and p.teminat_release_id is not distinct from p_teminat_release_id then
      return p;  -- tekrar gönderim
    end if;
    raise exception 'Bu kimlikle farklı bir ödeme var' using errcode = 'unique_violation';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Tutar pozitif ve en çok iki ondalıklı olmalı' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.payment_sources s where s.id = p_payment_source_id and s.is_active) then
    raise exception 'Ödeme kaynağı bulunamadı veya pasif' using errcode = 'foreign_key_violation';
  end if;

  if p_hakedis_id is not null then
    select * into h from public.hakedis where id = p_hakedis_id and contract_id = c.id for update;
    if not found or h.status <> 'onaylandi' or h.posted_at is null then
      raise exception 'Ödeme yalnızca onaylanıp deftere işlenmiş hakedişe eşleştirilir' using errcode = 'check_violation';
    end if;
    v_target := h.cari_entry_id;
  elsif p_teminat_release_id is not null then
    select * into r from public.teminat_releases where id = p_teminat_release_id and contract_id = c.id;
    if not found or r.status <> 'aktif' then
      raise exception 'Teminat iadesi bulunamadı veya iptal edilmiş' using errcode = 'check_violation';
    end if;
    v_target := r.cari_entry_id;
  end if;

  insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind, amount, currency,
                                   description, document_no, source_type, source_id)
  values (p_id, c.cari_account_id, c.project_id, v_date, 'borc', p_kind::public.cari_entry_kind, p_amount, c.currency,
          coalesce(nullif(trim(p_description), ''),
                   case p_kind when 'avans' then 'Avans · ' else 'Ödeme · ' end || c.title),
          c.contract_no, 'finans_odeme', p_id);
  insert into public.finance_payments (id, contract_id, project_id, cari_account_id, kind, amount, payment_date,
                                       payment_source_id, hakedis_id, teminat_release_id, cari_entry_id, description, is_demo)
  values (p_id, c.id, c.project_id, c.cari_account_id, p_kind, p_amount, v_date, p_payment_source_id, p_hakedis_id,
          p_teminat_release_id, p_id, nullif(trim(p_description), ''), c.is_demo)
  returning * into p;
  if v_target is not null then
    insert into public.cari_allocations (payment_entry_id, target_entry_id, amount, note)
    values (p_id, v_target, p_amount, 'Ödeme');
  end if;
  perform private.fin_event('odeme', p.id, c.id, c.project_id, 'kaydet', null, 'aktif', null,
                            jsonb_build_object('kind', p_kind, 'amount', p_amount, 'hakedis_id', p_hakedis_id,
                                               'teminat_release_id', p_teminat_release_id));
  return p;
end;
$$;

create or replace function public.cancel_finance_payment(p_id uuid, p_reason text)
returns public.finance_payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.finance_payments;
begin
  select * into p from public.finance_payments where id = p_id;
  if not found or not private.has_permission('odeme.write', p.project_id) then
    raise exception 'Ödeme bulunamadı veya yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  perform 1 from public.contracts where id = p.contract_id for update;
  select * into p from public.finance_payments where id = p_id for update;
  if p.status = 'iptal' then
    return p;
  end if;
  if length(coalesce(trim(p_reason), '')) < 10 then
    raise exception 'İptal gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;
  if p.kind = 'avans' and exists (select 1 from public.cari_allocations a
                                    where a.deleted_at is null and a.payment_entry_id = p.cari_entry_id) then
    raise exception 'Hakedişte mahsup edilmiş avans iptal edilemez; önce hakedişi iptal edin' using errcode = 'check_violation';
  end if;
  perform private.fin_reverse_entry(p.cari_entry_id, p_reason);
  update public.finance_payments set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(),
                                     cancel_reason = trim(p_reason)
   where id = p.id returning * into p;
  perform private.fin_event('odeme', p.id, p.contract_id, p.project_id, 'iptal', 'aktif', 'iptal', p_reason);
  return p;
end;
$$;

-- -----------------------------------------------------------------------------
-- Özetler (para kavramları ayrı ayrı; birbirine eklenmez)
-- -----------------------------------------------------------------------------
create or replace function public.contract_finance_summary(p_contract_id uuid)
returns table (
  contract_id             uuid,
  contract_amount         numeric,  -- sözleşme bedeli (onaylı revizyon; yoksa boş)
  gross_total             numeric,  -- onaylı hakedişlerin brüt toplamı
  kdv_total               numeric,
  tax_deduction_total     numeric,  -- stopaj
  other_deduction_total   numeric,
  advance_deducted_total  numeric,  -- avans mahsubu
  retention_withheld      numeric,  -- kesilen teminat (onaylı)
  retention_released      numeric,  -- serbest bırakılan
  retention_balance       numeric,  -- biriken, henüz bırakılmamış teminat
  payable_total           numeric,  -- hakedişlerden ödemeye uygun toplam
  unposted_payable        numeric,  -- onaylı ama deftere işlenmemiş ödemeye uygun tutar
  paid_total              numeric,  -- gerçekleşmiş ödemeler (hakediş ve teminat iadesi)
  advance_paid_total      numeric,  -- verilen avans (ödeme değil, mahsup edilir)
  remaining_total         numeric,  -- kalan borcumuz = ödemeye uygun + bırakılan teminat − ödenen
  hakedis_count           integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.contracts;
begin
  select * into c from public.contracts where id = p_contract_id;
  if not found or not private.has_permission('hakedis.read', c.project_id) then
    raise exception 'Sözleşme finans özetini görme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  return query
  with hk as (select * from public.hakedis h where h.contract_id = c.id and h.status = 'onaylandi'),
       pay as (select * from public.finance_payments p where p.contract_id = c.id and p.status = 'aktif'),
       rel as (select * from public.teminat_releases r where r.contract_id = c.id and r.status = 'aktif')
  select c.id,
         (select v.total_amount from public.contract_versions v where v.contract_id = c.id and v.status = 'onaylandi'),
         coalesce((select sum(gross_amount) from hk), 0),
         coalesce((select sum(kdv_amount) from hk), 0),
         coalesce((select sum(tax_deduction_amount) from hk), 0),
         coalesce((select sum(other_deduction_amount) from hk), 0),
         coalesce((select sum(advance_amount) from hk), 0),
         coalesce((select sum(retention_amount) from hk), 0),
         coalesce((select sum(amount) from rel), 0),
         coalesce((select sum(retention_amount) from hk), 0) - coalesce((select sum(amount) from rel), 0),
         coalesce((select sum(payable_amount) from hk), 0),
         coalesce((select sum(payable_amount) from hk where posted_at is null), 0),
         coalesce((select sum(amount) from pay where kind = 'odeme'), 0),
         coalesce((select sum(amount) from pay where kind = 'avans'), 0),
         coalesce((select sum(payable_amount) from hk), 0) + coalesce((select sum(amount) from rel), 0)
           - coalesce((select sum(amount) from pay where kind = 'odeme'), 0),
         (select count(*)::integer from hk);
end;
$$;

-- Hakediş başına ödeme durumu.
create or replace view public.v_hakedis_payment_status
with (security_invoker = true)
as
select h.id as hakedis_id,
       h.payable_amount,
       coalesce((select sum(p.amount) from public.finance_payments p
                  where p.hakedis_id = h.id and p.status = 'aktif'), 0) as paid_amount,
       h.payable_amount - coalesce((select sum(p.amount) from public.finance_payments p
                                     where p.hakedis_id = h.id and p.status = 'aktif'), 0) as remaining_amount
  from public.hakedis h;

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
end;
$$;

revoke execute on function private.harden_api_privileges() from public, anon, authenticated;

grant execute on function public.save_tax_rule(uuid, text, text, public.tax_rule_kind, numeric, date, text, date, text, boolean) to authenticated;
grant execute on function public.verify_tax_rule(uuid) to authenticated;
grant execute on function public.save_payment_source(uuid, text, text, text, boolean) to authenticated;
grant execute on function public.save_contract(uuid, uuid, uuid, text, text, jsonb, date, text, text, date, date, numeric,
                                               numeric, numeric, text, text, text[], integer) to authenticated;
grant execute on function public.contract_transition(uuid, text, text, integer) to authenticated;
grant execute on function public.save_work_quantity(uuid, uuid, uuid, date, numeric, text, text) to authenticated;
grant execute on function public.approve_work_quantities(uuid[]) to authenticated;
grant execute on function public.cancel_work_quantity(uuid, text) to authenticated;
grant execute on function public.imalat_items(uuid) to authenticated;
grant execute on function public.create_hakedis(uuid, uuid, date, date, text) to authenticated;
grant execute on function public.refresh_hakedis(uuid) to authenticated;
grant execute on function public.set_hakedis_progress(uuid, uuid, numeric) to authenticated;
grant execute on function public.set_hakedis_deduction(uuid, public.hakedis_adjustment_kind, numeric, text) to authenticated;
grant execute on function public.override_hakedis_limit(uuid, text) to authenticated;
grant execute on function public.hakedis_transition(uuid, text, text, integer) to authenticated;
grant execute on function public.revise_hakedis(uuid, uuid, text) to authenticated;
grant execute on function public.post_hakedis(uuid, date, numeric) to authenticated;
grant execute on function public.release_teminat(uuid, uuid, numeric, text, date) to authenticated;
grant execute on function public.cancel_teminat_release(uuid, text) to authenticated;
grant execute on function public.record_finance_payment(uuid, uuid, text, numeric, uuid, date, uuid, uuid, text) to authenticated;
grant execute on function public.cancel_finance_payment(uuid, text) to authenticated;
grant execute on function public.contract_finance_summary(uuid) to authenticated;
grant select on public.v_hakedis_payment_status to authenticated;

-- -----------------------------------------------------------------------------
-- İzinler ve rol şablonları. Şantiye şefi yalnızca imalat (miktar) görür;
-- finansal tutarlara erişmez. Finansal onay, limit izni ve teminat serbest
-- bırakma yalnızca yöneticidedir (şablonlar yönetici tarafından değiştirilebilir).
-- -----------------------------------------------------------------------------
insert into public.permissions (key, module, description) values
  ('sozlesme.read',          'hakedis', 'Taşeron sözleşmelerini, kalemleri ve fiyatları görüntüleme'),
  ('sozlesme.write',         'hakedis', 'Sözleşme taslağı ve revizyon hazırlama'),
  ('sozlesme.approve',       'hakedis', 'Sözleşme ve revizyon onaylama, sözleşme kapatma'),
  ('imalat.read',            'hakedis', 'Gerçekleşen imalat (metraj) kayıtlarını görüntüleme'),
  ('imalat.write',           'hakedis', 'İmalat (metraj) girme'),
  ('imalat.approve',         'hakedis', 'İmalat kayıtlarını onaylama'),
  ('hakedis.read',           'hakedis', 'Hakediş tutarlarını, teminatı ve ödemeleri görüntüleme'),
  ('hakedis.prepare',        'hakedis', 'Hakediş hazırlama ve incelemeye gönderme'),
  ('hakedis.approve',        'hakedis', 'Hakedişi finansal olarak onaylama ve onaylı hakedişi iptal etme'),
  ('hakedis.limit_override', 'hakedis', 'Sözleşme limitini aşan hakediş için gerekçeli izin verme'),
  ('hakedis.post',           'hakedis', 'Onaylı hakedişi cari deftere işleme'),
  ('teminat.release',        'hakedis', 'Teminatı kısmen veya tamamen serbest bırakma'),
  ('odeme.write',            'hakedis', 'Ödeme ve avans kaydetme, ödeme kaynağı tanımlama'),
  ('vergi.manage',           'hakedis', 'Vergi ve kesinti kurallarını tanımlama ve doğrulama');

insert into public.role_permissions (role_id, permission_key)
select r.id, x.permission_key
  from (values
          ('muhasebe',     'sozlesme.read'),
          ('muhasebe',     'sozlesme.write'),
          ('muhasebe',     'imalat.read'),
          ('muhasebe',     'hakedis.read'),
          ('muhasebe',     'hakedis.prepare'),
          ('muhasebe',     'hakedis.post'),
          ('muhasebe',     'odeme.write'),
          ('muhasebe',     'vergi.manage'),
          ('proje_muduru', 'sozlesme.read'),
          ('proje_muduru', 'imalat.read'),
          ('proje_muduru', 'imalat.write'),
          ('proje_muduru', 'imalat.approve'),
          ('proje_muduru', 'hakedis.read'),
          ('proje_muduru', 'hakedis.prepare'),
          ('santiye_sefi', 'imalat.read'),
          ('santiye_sefi', 'imalat.write')
       ) as x (role_key, permission_key)
  join public.roles r on r.key = x.role_key;

select private.harden_api_privileges();
