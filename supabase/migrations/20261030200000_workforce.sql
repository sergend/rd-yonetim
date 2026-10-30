-- =============================================================================
-- RD Projeler · Aşama 2 · Taşeron, personel, ekip ve proje görevlendirmeleri
-- =============================================================================
-- Kim (personel), kimin adına (şirket ya da taşeron), hangi ekipte ve hangi
-- projede, hangi tarihler arasında çalıştı? Puantaj ve hakediş (Aşama 3-4)
-- bu kayıtlara bağlanacak.
--
-- Bu tablolar hiçbir finansal kayıt üretmez: cari hareket yalnızca Aşama 1'in
-- cari defter RPC'leriyle oluşur; burada cari tablolarına yazan trigger yoktur.
--
-- Kurallar (tamamı veritabanında; pgTAP 070_workforce ile test edilir):
--   * Taşeronun finansal kimliği cari karttır. Taşeron tablosu vergi numarası
--     veya IBAN tutmaz; bir cari kart en fazla bir taşerona bağlanır.
--   * Personel kimliği (personnel) ile ekip üyeliği (crew_memberships) ayrıdır.
--   * Üyelikler ve görevlendirmeler silinmez, bitiş tarihiyle kapanır. Kaydın
--     sahibi (kişi, ekip, proje, taşeron) sonradan değiştirilemez; tarih ve
--     açıklama düzeltmeleri işlem geçmişine yazılır.
--   * Bir kişi aynı anda yalnızca bir ekipte olabilir (günlük çalışma kaydı
--     tek ekibe yazılabilsin diye).
--   * Taşeron personeli yalnızca kendi taşeronunun ekibine, şirket personeli
--     yalnızca şirket ekibine katılır; ekip sorumlusu için de aynı kural geçerli.
--   * Aynı kişi veya ekip aynı anda farklı projelerde görevli olabilir; aynı
--     projeye tarihleri çakışan ikinci görevlendirme reddedilir.
--   * Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez.

create type public.work_trade as enum (
  'kalip', 'demir', 'beton', 'duvar', 'siva', 'alci', 'boya', 'seramik',
  'elektrik', 'tesisat', 'mekanik', 'izolasyon', 'cati', 'dograma',
  'hafriyat', 'peyzaj', 'genel', 'diger');

-- Çalışma ilişkisi. taseron ise kişinin taşeronu zorunludur (puantaj ve
-- hakedişte kimin adına çalıştığı belirsiz kalmasın).
create type public.employment_type as enum ('sirket', 'taseron', 'diger');

-- -----------------------------------------------------------------------------
-- Tablolar
-- -----------------------------------------------------------------------------
create table public.subcontractors (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (length(trim(name)) > 0),
  trade           public.work_trade,
  cari_account_id uuid references public.cari_accounts (id) on delete restrict,
  contact_name    text,
  phone           text,
  email           text check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  notes           text,
  is_active       boolean not null default true,
  is_demo         boolean not null default false,
  deleted_at      timestamptz
);
-- Aynı firma ikinci bir taşeron kaydıyla ayrı finansal kimlik kazanamaz.
create unique index subcontractors_cari_uq on public.subcontractors (cari_account_id)
  where cari_account_id is not null and deleted_at is null;
create index subcontractors_name_idx on public.subcontractors (lower(name)) where deleted_at is null;
select private.add_row_meta('public.subcontractors');
select audit.enable('public.subcontractors');

-- Belge kayıtları (vergi levhası, SGK, sözleşme...). Dosya yükleme sonraki
-- aşamada Storage ile eklenecek; şimdilik belge bilgisi ve geçerlilik tarihi.
create table public.subcontractor_documents (
  id               uuid primary key default gen_random_uuid(),
  subcontractor_id uuid not null references public.subcontractors (id) on delete restrict,
  title            text not null check (length(trim(title)) > 0),
  document_no      text,
  valid_until      date,
  notes            text,
  deleted_at       timestamptz
);
create index subcontractor_documents_sub_idx on public.subcontractor_documents (subcontractor_id) where deleted_at is null;
select private.add_row_meta('public.subcontractor_documents');
select audit.enable('public.subcontractor_documents');

-- Taşeronun çalıştığı projeler (hakediş bu ilişkiye bağlanacak).
create table public.subcontractor_projects (
  id               uuid primary key default gen_random_uuid(),
  subcontractor_id uuid not null references public.subcontractors (id) on delete restrict,
  project_id       uuid not null references public.projects (id) on delete restrict,
  start_date       date not null,
  end_date         date,
  scope            text,  -- iş kapsamı (ör. "A ve B blok kaba inşaat")
  constraint subcontractor_projects_dates_ck check (end_date is null or end_date >= start_date),
  constraint subcontractor_projects_no_overlap exclude using gist (
    subcontractor_id with =, project_id with =, daterange(start_date, end_date, '[]') with &&)
);
create index subcontractor_projects_project_idx on public.subcontractor_projects (project_id);
select private.add_row_meta('public.subcontractor_projects');
select audit.enable('public.subcontractor_projects');

create table public.personnel (
  id               uuid primary key default gen_random_uuid(),
  full_name        text not null check (length(trim(full_name)) > 0),
  job_title        text,  -- görevi (ör. kalıp ustası, şantiye şefi)
  trade            public.work_trade,
  employment_type  public.employment_type not null default 'sirket',
  subcontractor_id uuid references public.subcontractors (id) on delete restrict,
  notes            text,
  is_active        boolean not null default true,
  is_demo          boolean not null default false,
  deleted_at       timestamptz,
  constraint personnel_subcontractor_ck check ((employment_type = 'taseron') = (subcontractor_id is not null))
);
create index personnel_name_idx on public.personnel (lower(full_name)) where deleted_at is null;
create index personnel_subcontractor_idx on public.personnel (subcontractor_id) where subcontractor_id is not null;
select private.add_row_meta('public.personnel');
select audit.enable('public.personnel');

-- İletişim bilgisi ayrı tabloda ve ayrı izinle (personel_iletisim.read) okunur.
-- TCKN, banka ve adres bilgisi bilerek tutulmaz (KVKK: bu aşamada gerekmiyor).
create table public.personnel_contacts (
  id           uuid primary key default gen_random_uuid(),
  personnel_id uuid not null unique references public.personnel (id) on delete restrict,
  phone        text check (phone ~ '^[0-9 +()-]{7,20}$')
);
select private.add_row_meta('public.personnel_contacts');
select audit.enable('public.personnel_contacts');

create table public.crews (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (length(trim(name)) > 0),
  subcontractor_id uuid references public.subcontractors (id) on delete restrict,  -- boşsa şirket ekibi
  trade            public.work_trade,
  leader_id        uuid references public.personnel (id) on delete restrict,
  notes            text,
  is_active        boolean not null default true,
  is_demo          boolean not null default false,
  deleted_at       timestamptz
);
-- Aynı taşeronda (veya şirkette) aynı adlı iki etkin ekip olmaz.
create unique index crews_name_uq on public.crews (subcontractor_id, lower(name)) nulls not distinct
  where deleted_at is null;
select private.add_row_meta('public.crews');
select audit.enable('public.crews');

create table public.crew_memberships (
  id           uuid primary key default gen_random_uuid(),
  crew_id      uuid not null references public.crews (id) on delete restrict,
  personnel_id uuid not null references public.personnel (id) on delete restrict,
  start_date   date not null,
  end_date     date,
  role_title   text,  -- ekipteki görevi (usta, kalfa, işçi...)
  notes        text,
  constraint crew_memberships_dates_ck check (end_date is null or end_date >= start_date),
  constraint crew_memberships_one_crew_at_a_time exclude using gist (
    personnel_id with =, daterange(start_date, end_date, '[]') with &&)
);
create index crew_memberships_crew_idx on public.crew_memberships (crew_id, start_date);
select private.add_row_meta('public.crew_memberships');
select audit.enable('public.crew_memberships');

-- Kişi ya da ekip bir projede görevli. Günlük çalışma kaydı (Aşama 3) kişi +
-- proje + gün ile bu kayda (ve ekipse üyeliğe) project_workforce ile bağlanır.
create table public.project_assignments (
  id           uuid primary key default gen_random_uuid(),
  project_id   uuid not null references public.projects (id) on delete restrict,
  personnel_id uuid references public.personnel (id) on delete restrict,
  crew_id      uuid references public.crews (id) on delete restrict,
  start_date   date not null,
  end_date     date,
  description  text,
  constraint project_assignments_target_ck check (num_nonnulls(personnel_id, crew_id) = 1),
  constraint project_assignments_dates_ck check (end_date is null or end_date >= start_date),
  constraint project_assignments_person_no_overlap exclude using gist (
    project_id with =, personnel_id with =, daterange(start_date, end_date, '[]') with &&)
    where (personnel_id is not null),
  constraint project_assignments_crew_no_overlap exclude using gist (
    project_id with =, crew_id with =, daterange(start_date, end_date, '[]') with &&)
    where (crew_id is not null)
);
create index project_assignments_personnel_idx on public.project_assignments (personnel_id) where personnel_id is not null;
create index project_assignments_crew_idx on public.project_assignments (crew_id) where crew_id is not null;
select private.add_row_meta('public.project_assignments');
select audit.enable('public.project_assignments');

-- -----------------------------------------------------------------------------
-- Kural trigger'ları. SECURITY DEFINER: kullanıcının RLS ile göremediği
-- çakışan kayıtlar da denetlenir. Hata kodları istemcide eşlenir:
-- 23503 bağlı kayıt yok/pasif, 23514 kural, 23P01 tarih çakışması.
-- -----------------------------------------------------------------------------
create or replace function private.tg_subcontractor_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cari  public.cari_accounts;
  v_owner text;
begin
  if new.cari_account_id is null
     or (tg_op = 'UPDATE' and new.cari_account_id is not distinct from old.cari_account_id
         and new.deleted_at is not distinct from old.deleted_at) then
    return new;
  end if;
  if new.deleted_at is not null then
    return new;  -- silinen kaydın bağlantısı serbest kalır
  end if;

  select * into v_cari from public.cari_accounts c where c.id = new.cari_account_id;
  if not found or v_cari.deleted_at is not null then
    raise exception 'Cari hesap bulunamadı' using errcode = 'foreign_key_violation';
  end if;
  if auth.uid() is not null and not private.can_read_cari_account(new.cari_account_id) then
    raise exception 'Bu cari hesabı görme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select s.name into v_owner
    from public.subcontractors s
   where s.cari_account_id = new.cari_account_id and s.deleted_at is null and s.id <> new.id;
  if found then
    raise exception 'Bu cari hesap zaten "%" taşeronuna bağlı', v_owner using errcode = 'unique_violation';
  end if;
  if not v_cari.is_active then
    raise exception 'Pasif cari hesaba bağlanamaz' using errcode = 'check_violation';
  end if;
  if v_cari.type = 'musteri' then
    raise exception 'Müşteri carisi taşerona bağlanamaz' using errcode = 'check_violation';
  end if;
  if v_cari.is_demo is distinct from new.is_demo then
    raise exception 'Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez' using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger subcontractor_rules before insert or update on public.subcontractors
  for each row execute function private.tg_subcontractor_rules();

create or replace function private.tg_personnel_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub public.subcontractors;
begin
  if new.subcontractor_id is not null
     and (tg_op = 'INSERT' or new.subcontractor_id is distinct from old.subcontractor_id) then
    select * into v_sub from public.subcontractors s where s.id = new.subcontractor_id;
    if not found or v_sub.deleted_at is not null or not v_sub.is_active then
      raise exception 'Taşeron bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
    if v_sub.is_demo is distinct from new.is_demo then
      raise exception 'Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez' using errcode = 'check_violation';
    end if;
  end if;

  if tg_op = 'UPDATE' and new.subcontractor_id is distinct from old.subcontractor_id
     and exists (select 1 from public.crew_memberships m
                  where m.personnel_id = new.id
                    and coalesce(m.end_date, 'infinity'::date) >= private.today()) then
    raise exception 'Kişinin devam eden ekip üyeliği var; çalışma ilişkisini değiştirmeden önce üyeliği bitirin'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger personnel_rules before insert or update on public.personnel
  for each row execute function private.tg_personnel_rules();

create or replace function private.tg_crew_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub    public.subcontractors;
  v_leader public.personnel;
begin
  if tg_op = 'UPDATE' and new.subcontractor_id is distinct from old.subcontractor_id
     and exists (select 1 from public.crew_memberships m where m.crew_id = new.id) then
    raise exception 'Üyelik geçmişi olan ekibin bağlı olduğu taşeron değiştirilemez; yeni ekip açın'
      using errcode = 'check_violation';
  end if;

  if new.subcontractor_id is not null
     and (tg_op = 'INSERT' or new.subcontractor_id is distinct from old.subcontractor_id) then
    select * into v_sub from public.subcontractors s where s.id = new.subcontractor_id;
    if not found or v_sub.deleted_at is not null or not v_sub.is_active then
      raise exception 'Taşeron bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
    if v_sub.is_demo is distinct from new.is_demo then
      raise exception 'Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez' using errcode = 'check_violation';
    end if;
  end if;

  if new.leader_id is not null
     and (tg_op = 'INSERT' or new.leader_id is distinct from old.leader_id
          or new.subcontractor_id is distinct from old.subcontractor_id) then
    select * into v_leader from public.personnel p where p.id = new.leader_id;
    if not found or v_leader.deleted_at is not null or not v_leader.is_active then
      raise exception 'Ekip sorumlusu bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
    if v_leader.subcontractor_id is distinct from new.subcontractor_id then
      raise exception 'Ekip sorumlusu ekibin bağlı olduğu taşeronun (şirket ekibinde şirketin) personeli olmalı'
        using errcode = 'check_violation';
    end if;
    if v_leader.is_demo is distinct from new.is_demo then
      raise exception 'Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

create trigger crew_rules before insert or update on public.crews
  for each row execute function private.tg_crew_rules();

create or replace function private.tg_crew_membership_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_crew   public.crews;
  v_person public.personnel;
  v_other  record;
begin
  if new.end_date < new.start_date then
    raise exception 'Bitiş tarihi başlangıç tarihinden önce olamaz' using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE'
     and (new.crew_id <> old.crew_id or new.personnel_id <> old.personnel_id) then
    raise exception 'Üyeliğin ekibi veya kişisi değiştirilemez; üyeliği bitirip yenisini ekleyin'
      using errcode = 'check_violation';
  end if;

  if tg_op = 'INSERT' then
    select * into v_crew   from public.crews c     where c.id = new.crew_id;
    select * into v_person from public.personnel p where p.id = new.personnel_id;
    if v_crew.id is null or v_crew.deleted_at is not null or not v_crew.is_active then
      raise exception 'Ekip bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
    if v_person.id is null or v_person.deleted_at is not null or not v_person.is_active then
      raise exception 'Personel bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
    if v_person.subcontractor_id is distinct from v_crew.subcontractor_id then
      raise exception 'Taşeron personeli yalnızca kendi taşeronunun, şirket personeli yalnızca şirketin ekibine katılabilir'
        using errcode = 'check_violation';
    end if;
    if v_person.is_demo is distinct from v_crew.is_demo then
      raise exception 'Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez' using errcode = 'check_violation';
    end if;
  end if;

  select m.start_date, m.end_date, c.name into v_other
    from public.crew_memberships m
    join public.crews c on c.id = m.crew_id
   where m.personnel_id = new.personnel_id
     and m.id <> new.id
     and daterange(m.start_date, m.end_date, '[]') && daterange(new.start_date, new.end_date, '[]')
   limit 1;
  if found then
    raise exception 'Kişi bu tarihlerde "%" ekibinde (% – %); aynı anda yalnızca bir ekipte olabilir',
      v_other.name, v_other.start_date, coalesce(v_other.end_date::text, 'devam ediyor')
      using errcode = 'exclusion_violation';
  end if;
  return new;
end;
$$;

create trigger crew_membership_rules before insert or update on public.crew_memberships
  for each row execute function private.tg_crew_membership_rules();

create or replace function private.tg_project_assignment_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project public.projects;
  v_active  boolean;
  v_demo    boolean;
begin
  if new.end_date < new.start_date then
    raise exception 'Bitiş tarihi başlangıç tarihinden önce olamaz' using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE'
     and (new.project_id <> old.project_id
          or new.personnel_id is distinct from old.personnel_id
          or new.crew_id is distinct from old.crew_id) then
    raise exception 'Görevlendirmenin projesi, kişisi veya ekibi değiştirilemez; görevlendirmeyi bitirip yenisini ekleyin'
      using errcode = 'check_violation';
  end if;

  if tg_op = 'INSERT' then
    select * into v_project from public.projects pr where pr.id = new.project_id;
    if v_project.id is null or v_project.deleted_at is not null then
      raise exception 'Proje bulunamadı' using errcode = 'foreign_key_violation';
    end if;
    if new.personnel_id is not null then
      select p.deleted_at is null and p.is_active, p.is_demo into v_active, v_demo
        from public.personnel p where p.id = new.personnel_id;
    else
      select c.deleted_at is null and c.is_active, c.is_demo into v_active, v_demo
        from public.crews c where c.id = new.crew_id;
    end if;
    if v_active is not true then
      raise exception 'Personel veya ekip bulunamadı ya da pasif' using errcode = 'foreign_key_violation';
    end if;
    if v_demo is distinct from v_project.is_demo then
      raise exception 'Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez' using errcode = 'check_violation';
    end if;
  end if;

  if exists (select 1 from public.project_assignments a
              where a.project_id = new.project_id
                and a.id <> new.id
                and (a.personnel_id = new.personnel_id or a.crew_id = new.crew_id)
                and daterange(a.start_date, a.end_date, '[]') && daterange(new.start_date, new.end_date, '[]')) then
    raise exception 'Bu projede aynı tarihlerde zaten görevlendirme var' using errcode = 'exclusion_violation';
  end if;
  return new;
end;
$$;

create trigger project_assignment_rules before insert or update on public.project_assignments
  for each row execute function private.tg_project_assignment_rules();

create or replace function private.tg_subcontractor_project_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub     public.subcontractors;
  v_project public.projects;
begin
  if new.end_date < new.start_date then
    raise exception 'Bitiş tarihi başlangıç tarihinden önce olamaz' using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE'
     and (new.project_id <> old.project_id or new.subcontractor_id <> old.subcontractor_id) then
    raise exception 'Kaydın taşeronu veya projesi değiştirilemez; kaydı bitirip yenisini ekleyin'
      using errcode = 'check_violation';
  end if;

  if tg_op = 'INSERT' then
    select * into v_sub     from public.subcontractors s where s.id = new.subcontractor_id;
    select * into v_project from public.projects pr      where pr.id = new.project_id;
    if v_sub.id is null or v_sub.deleted_at is not null or not v_sub.is_active then
      raise exception 'Taşeron bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
    if v_project.id is null or v_project.deleted_at is not null then
      raise exception 'Proje bulunamadı' using errcode = 'foreign_key_violation';
    end if;
    if v_sub.is_demo is distinct from v_project.is_demo then
      raise exception 'Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez' using errcode = 'check_violation';
    end if;
  end if;

  if exists (select 1 from public.subcontractor_projects x
              where x.project_id = new.project_id
                and x.subcontractor_id = new.subcontractor_id
                and x.id <> new.id
                and daterange(x.start_date, x.end_date, '[]') && daterange(new.start_date, new.end_date, '[]')) then
    raise exception 'Taşeron bu projede aynı tarihlerde zaten kayıtlı' using errcode = 'exclusion_violation';
  end if;
  return new;
end;
$$;

create trigger subcontractor_project_rules before insert or update on public.subcontractor_projects
  for each row execute function private.tg_subcontractor_project_rules();

-- Demo işareti sonradan değiştirilemez (Aşama 1 kuralı yeni kartlara da uygulanır).
create trigger demo_flag_locked before update of is_demo on public.subcontractors
  for each row execute function private.tg_demo_flag_locked();
create trigger demo_flag_locked before update of is_demo on public.personnel
  for each row execute function private.tg_demo_flag_locked();
create trigger demo_flag_locked before update of is_demo on public.crews
  for each row execute function private.tg_demo_flag_locked();

-- -----------------------------------------------------------------------------
-- Görünürlük yardımcıları. Genel izin tüm kayıtları açar; proje kapsamlı izin
-- yalnızca o projeyle ilişkili kayıtları açar:
--   personel : projeye doğrudan görevli ya da üyeliği projedeki ekip
--              görevlendirmesiyle aynı döneme denk gelen kişi
--   ekip     : projeye görevlendirilmiş ekip
--   üyelik   : ekibin o projedeki görev dönemiyle çakışan üyelik (ekibin
--              başka projedeki dönemine ait üyelikler görünmez)
--   taşeron  : projede kayıtlı ya da ekibi/personeli projede görevli taşeron
-- -----------------------------------------------------------------------------
create or replace function private.can_read_personnel(p_personnel uuid, p_permission text default 'personel.read')
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_permission(p_permission, null)
      or exists (select 1 from public.project_assignments a
                  where a.personnel_id = p_personnel
                    and private.has_permission(p_permission, a.project_id))
      or exists (select 1
                   from public.crew_memberships m
                   join public.project_assignments a on a.crew_id = m.crew_id
                  where m.personnel_id = p_personnel
                    and daterange(m.start_date, m.end_date, '[]') && daterange(a.start_date, a.end_date, '[]')
                    and private.has_permission(p_permission, a.project_id));
$$;

create or replace function private.can_read_crew(p_crew uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_permission('personel.read', null)
      or exists (select 1 from public.project_assignments a
                  where a.crew_id = p_crew
                    and private.has_permission('personel.read', a.project_id));
$$;

create or replace function private.can_read_crew_membership(p_crew uuid, p_start date, p_end date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_permission('personel.read', null)
      or exists (select 1 from public.project_assignments a
                  where a.crew_id = p_crew
                    and daterange(a.start_date, a.end_date, '[]') && daterange(p_start, p_end, '[]')
                    and private.has_permission('personel.read', a.project_id));
$$;

create or replace function private.can_read_subcontractor(p_subcontractor uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_permission('taseron.read', null)
      or exists (select 1 from public.subcontractor_projects x
                  where x.subcontractor_id = p_subcontractor
                    and private.has_permission('taseron.read', x.project_id))
      or exists (select 1
                   from public.project_assignments a
                   left join public.personnel p on p.id = a.personnel_id
                   left join public.crews c on c.id = a.crew_id
                  where p_subcontractor in (p.subcontractor_id, c.subcontractor_id)
                    and private.has_permission('taseron.read', a.project_id));
$$;

grant execute on function private.can_read_personnel(uuid, text) to authenticated;
grant execute on function private.can_read_crew(uuid) to authenticated;
grant execute on function private.can_read_crew_membership(uuid, date, date) to authenticated;
grant execute on function private.can_read_subcontractor(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- RLS. Kartlar (taşeron, personel, ekip, üyelik) şirket geneli kayıtlardır ve
-- genel izinle yazılır; görevlendirmeler projeye aittir ve proje izniyle yazılır.
-- -----------------------------------------------------------------------------
alter table public.subcontractors          enable row level security;
alter table public.subcontractor_documents enable row level security;
alter table public.subcontractor_projects  enable row level security;
alter table public.personnel               enable row level security;
alter table public.personnel_contacts      enable row level security;
alter table public.crews                   enable row level security;
alter table public.crew_memberships        enable row level security;
alter table public.project_assignments     enable row level security;

create policy subcontractors_select on public.subcontractors
  for select to authenticated using (private.can_read_subcontractor(id));
create policy subcontractors_insert on public.subcontractors
  for insert to authenticated with check (private.has_permission('taseron.write', null));
create policy subcontractors_update on public.subcontractors
  for update to authenticated
  using (private.has_permission('taseron.write', null))
  with check (private.has_permission('taseron.write', null));

create policy subcontractor_documents_select on public.subcontractor_documents
  for select to authenticated using (private.can_read_subcontractor(subcontractor_id));
create policy subcontractor_documents_insert on public.subcontractor_documents
  for insert to authenticated with check (private.has_permission('taseron.write', null));
create policy subcontractor_documents_update on public.subcontractor_documents
  for update to authenticated
  using (private.has_permission('taseron.write', null))
  with check (private.has_permission('taseron.write', null));

create policy subcontractor_projects_select on public.subcontractor_projects
  for select to authenticated
  using (private.has_permission('gorevlendirme.read', project_id)
         or private.has_permission('taseron.read', project_id));
create policy subcontractor_projects_insert on public.subcontractor_projects
  for insert to authenticated with check (private.has_permission('gorevlendirme.write', project_id));
create policy subcontractor_projects_update on public.subcontractor_projects
  for update to authenticated
  using (private.has_permission('gorevlendirme.write', project_id))
  with check (private.has_permission('gorevlendirme.write', project_id));

create policy personnel_select on public.personnel
  for select to authenticated using (private.can_read_personnel(id));
create policy personnel_insert on public.personnel
  for insert to authenticated with check (private.has_permission('personel.write', null));
create policy personnel_update on public.personnel
  for update to authenticated
  using (private.has_permission('personel.write', null))
  with check (private.has_permission('personel.write', null));

create policy personnel_contacts_select on public.personnel_contacts
  for select to authenticated using (private.can_read_personnel(personnel_id, 'personel_iletisim.read'));
create policy personnel_contacts_insert on public.personnel_contacts
  for insert to authenticated with check (private.has_permission('personel.write', null));
create policy personnel_contacts_update on public.personnel_contacts
  for update to authenticated
  using (private.has_permission('personel.write', null))
  with check (private.has_permission('personel.write', null));

create policy crews_select on public.crews
  for select to authenticated using (private.can_read_crew(id));
create policy crews_insert on public.crews
  for insert to authenticated with check (private.has_permission('personel.write', null));
create policy crews_update on public.crews
  for update to authenticated
  using (private.has_permission('personel.write', null))
  with check (private.has_permission('personel.write', null));

create policy crew_memberships_select on public.crew_memberships
  for select to authenticated using (private.can_read_crew_membership(crew_id, start_date, end_date));
create policy crew_memberships_insert on public.crew_memberships
  for insert to authenticated with check (private.has_permission('personel.write', null));
create policy crew_memberships_update on public.crew_memberships
  for update to authenticated
  using (private.has_permission('personel.write', null))
  with check (private.has_permission('personel.write', null));

create policy project_assignments_select on public.project_assignments
  for select to authenticated using (private.has_permission('gorevlendirme.read', project_id));
create policy project_assignments_insert on public.project_assignments
  for insert to authenticated with check (private.has_permission('gorevlendirme.write', project_id));
create policy project_assignments_update on public.project_assignments
  for update to authenticated
  using (private.has_permission('gorevlendirme.write', project_id))
  with check (private.has_permission('gorevlendirme.write', project_id));

-- -----------------------------------------------------------------------------
-- RPC'ler
-- -----------------------------------------------------------------------------

-- Görevlendirme ekranındaki seçim listesi. Proje yetkilisi, projesinde henüz
-- görevli olmayan kişiyi seçebilmek için şirketin etkin personel ve ekiplerinin
-- yalnızca adını ve görevini görür: iletişim, üyelik ve başka projelerdeki
-- görevlendirme bilgisi bu listede yoktur.
create or replace function public.assignment_candidates(p_project_id uuid)
returns table (kind text, id uuid, name text, detail text, subcontractor_name text, is_demo boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_demo boolean;
begin
  if not private.has_permission('gorevlendirme.write', p_project_id) then
    raise exception 'Bu projede görevlendirme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select pr.is_demo into v_demo from public.projects pr where pr.id = p_project_id and pr.deleted_at is null;

  return query
    select x.kind, x.id, x.name, x.detail, x.subcontractor_name, x.is_demo
      from (
        select 'personel'::text as kind, p.id, p.full_name as name, p.job_title as detail,
               s.name as subcontractor_name, p.is_demo
          from public.personnel p
          left join public.subcontractors s on s.id = p.subcontractor_id
         where p.deleted_at is null and p.is_active and p.is_demo = v_demo
        union all
        select 'ekip'::text, c.id, c.name, null::text, s.name, c.is_demo
          from public.crews c
          left join public.subcontractors s on s.id = c.subcontractor_id
         where c.deleted_at is null and c.is_active and c.is_demo = v_demo
      ) x
     order by x.kind, lower(x.name);
end;
$$;

-- Belirli bir günde projede çalışan kişiler: doğrudan görevlendirme ya da
-- projeye görevli ekipteki üyelik. Aynı kişi iki yoldan geliyorsa doğrudan
-- görevlendirme esas alınır; her kişi bir kez döner. Puantaj (Aşama 3) günlük
-- kaydı bu fonksiyonla doğru görevlendirmeye ve üyeliğe bağlayacak.
-- SECURITY INVOKER: yalnızca kullanıcının RLS ile görebildiği kayıtlar.
create or replace function public.project_workforce(p_project_id uuid, p_on date default null)
returns table (
  personnel_id  uuid,
  full_name     text,
  job_title     text,
  via           text,
  crew_id       uuid,
  crew_name     text,
  assignment_id uuid,
  membership_id uuid)
language sql
stable
security invoker
set search_path = ''
as $$
  with d as (select coalesce(p_on, private.today()) as day),
  w as (
    select a.personnel_id, 'dogrudan'::text as via, null::uuid as crew_id, a.id as assignment_id,
           null::uuid as membership_id
      from public.project_assignments a, d
     where a.project_id = p_project_id
       and a.personnel_id is not null
       and d.day between a.start_date and coalesce(a.end_date, 'infinity'::date)
    union all
    select m.personnel_id, 'ekip', a.crew_id, a.id, m.id
      from public.project_assignments a
      join public.crew_memberships m on m.crew_id = a.crew_id, d
     where a.project_id = p_project_id
       and d.day between a.start_date and coalesce(a.end_date, 'infinity'::date)
       and d.day between m.start_date and coalesce(m.end_date, 'infinity'::date)
  ),
  one_per_person as (
    select distinct on (w.personnel_id) w.*
      from w
     order by w.personnel_id, (w.via = 'dogrudan') desc
  )
  select o.personnel_id, p.full_name, p.job_title, o.via, o.crew_id, c.name, o.assignment_id, o.membership_id
    from one_per_person o
    join public.personnel p on p.id = o.personnel_id
    left join public.crews c on c.id = o.crew_id
   where p.deleted_at is null
   order by c.name nulls first, p.full_name;
$$;

grant execute on function public.assignment_candidates(uuid) to authenticated;
grant execute on function public.project_workforce(uuid, date) to authenticated;

-- -----------------------------------------------------------------------------
-- İzinler ve rol şablonları
-- -----------------------------------------------------------------------------
insert into public.permissions (key, module, description) values
  ('taseron.read',           'taseron',      'Taşeron kartlarını ve belgelerini görüntüleme'),
  ('taseron.write',          'taseron',      'Taşeron kartı ve belge kaydı oluşturma, düzenleme'),
  ('personel.read',          'personel',     'Personel, ekip ve ekip üyeliklerini görüntüleme'),
  ('personel.write',         'personel',     'Personel, ekip ve ekip üyeliği oluşturma, düzenleme'),
  ('personel_iletisim.read', 'personel',     'Personel iletişim bilgilerini görüntüleme'),
  ('gorevlendirme.read',     'gorevlendirme', 'Proje görevlendirmelerini görüntüleme'),
  ('gorevlendirme.write',    'gorevlendirme', 'Projeye personel, ekip ve taşeron görevlendirme');

insert into public.roles (key, name, description, scope, is_template, is_system) values
  ('idari_isler', 'İdari işler sorumlusu',
   'Tüm projelerde taşeron, personel, ekip ve görevlendirme yönetimi; finans görmez', 'global', true, false);

insert into public.role_permissions (role_id, permission_key)
select r.id, x.permission_key
  from (values
          ('idari_isler',   'proje.read'),
          ('idari_isler',   'taseron.read'),
          ('idari_isler',   'taseron.write'),
          ('idari_isler',   'personel.read'),
          ('idari_isler',   'personel.write'),
          ('idari_isler',   'personel_iletisim.read'),
          ('idari_isler',   'gorevlendirme.read'),
          ('idari_isler',   'gorevlendirme.write'),
          ('muhasebe',      'taseron.read'),
          ('muhasebe',      'personel.read'),
          ('muhasebe',      'gorevlendirme.read'),
          ('santiye_sefi',  'taseron.read'),
          ('santiye_sefi',  'personel.read'),
          ('santiye_sefi',  'personel_iletisim.read'),
          ('santiye_sefi',  'gorevlendirme.read'),
          ('santiye_sefi',  'gorevlendirme.write'),
          ('goruntuleyici', 'personel.read'),
          ('goruntuleyici', 'gorevlendirme.read')
       ) as x (role_key, permission_key)
  join public.roles r on r.key = x.role_key;

select private.harden_api_privileges();
