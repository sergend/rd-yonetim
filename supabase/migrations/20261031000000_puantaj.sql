-- =============================================================================
-- RD Projeler · Aşama 3 · Puantaj (günlük çalışma kayıtları)
-- =============================================================================
-- Puantaj çalışma bilgisidir, finansal borç değildir. Bu migration'daki hiçbir
-- tablo, trigger veya fonksiyon cari defter, ödeme, maaş ya da hakediş kaydı
-- üretmez (pgTAP 080_puantaj bunu denetler). Onaylanan ay, ileride hakediş
-- modülünün okuyacağı güvenilir kaynaktır (bkz. docs/puantaj-hakedis.md).
--
-- Kurallar (tamamı veritabanında):
--   * Bir proje + kişi + gün için tek kayıt vardır. Aynı kişi aynı gün farklı
--     projelerde kayıt alabilir.
--   * Girilmeyen gün "henüz işlenmedi"dir; satır yoktur ve devamsızlık sayılmaz.
--     Hücreyi temizlemek kaydı yumuşak siler (deleted_at); geçmiş audit'te kalır.
--   * Kişi o gün projede görevli olmalıdır (doğrudan ya da projeye görevli
--     ekipteki üyelikle). Kayıt anında görevlendirme, üyelik, ekip, taşeron,
--     çalışma ilişkisi ve adlar kayda yazılır; sonraki ekip/personel
--     değişiklikleri geçmiş puantajı değiştirmez.
--   * Durumun sayısal karşılığı (fiilî çalışma eşdeğeri) ile ücretlendirme
--     sınıfı ayrı tutulur (puantaj_status_definitions). Ücret hesabı yoktur.
--   * Fazla mesai saat olarak ayrı tutulur ve ayrıca onaylanır; para hesabı yok.
--   * Ay durumu: taslak → incelemede → onaylandı → kilitli. Onaylı veya kilitli
--     aydaki kayıtlar hiç kimse tarafından değiştirilemez; düzeltme için ay
--     yetkili kişi tarafından gerekçeyle yeniden açılır (revizyon +1). Her
--     onayda ayın tam görüntüsü değiştirilemez olay kaydına yazılır.
--   * Yazma yalnızca RPC'lerle yapılır (save_puantaj, puantaj_transition,
--     approve_puantaj_overtime); tablolar API'ye salt okunurdur.
--   * Demo projelere yalnızca demo personel yazılır.

create type public.puantaj_status as enum (
  'tam_gun', 'yarim_gun', 'calismadi', 'ucretli_izin', 'ucretsiz_izin', 'raporlu', 'resmi_tatil');

create type public.puantaj_period_status as enum ('taslak', 'incelemede', 'onaylandi', 'kilitli');

-- -----------------------------------------------------------------------------
-- Durum tanımları: sayım ve ücretlendirme anlamı ayrı sütunlardır.
--   work_equivalent : fiilî çalışma günü eşdeğeri (imalat/verim için). Ücretli
--                     izin ve resmî tatil 0'dır: çalışılmış sayılmaz.
--   category        : özet sütunu (calisma, izin, rapor, devamsizlik, tatil).
--   pay_basis       : ileride sözleşmeye göre ücret kuralının bağlanacağı sınıf.
--                     Bu aşamada hiçbir hesapta kullanılmaz.
-- -----------------------------------------------------------------------------
create table public.puantaj_status_definitions (
  status          public.puantaj_status primary key,
  label           text not null,
  short_label     text not null,
  work_equivalent numeric(3, 2) not null check (work_equivalent between 0 and 1),
  category        text not null check (category in ('calisma', 'izin', 'rapor', 'devamsizlik', 'tatil')),
  pay_basis       text not null check (pay_basis in ('calisilan_gun', 'ucretli_izin', 'ucretsiz', 'rapor', 'resmi_tatil')),
  allows_overtime boolean not null,
  sort_order      integer not null
);
select private.add_row_meta('public.puantaj_status_definitions');
select audit.enable('public.puantaj_status_definitions');

insert into public.puantaj_status_definitions
  (status, label, short_label, work_equivalent, category, pay_basis, allows_overtime, sort_order) values
  ('tam_gun',       'Tam gün çalıştı',   'T',  1.00, 'calisma',     'calisilan_gun', true,  1),
  ('yarim_gun',     'Yarım gün çalıştı', 'Y',  0.50, 'calisma',     'calisilan_gun', true,  2),
  ('calismadi',     'Çalışmadı',         'Ç',  0.00, 'devamsizlik', 'ucretsiz',      false, 3),
  ('ucretli_izin',  'Ücretli izin',      'Üİ', 0.00, 'izin',        'ucretli_izin',  false, 4),
  ('ucretsiz_izin', 'Ücretsiz izin',     'İ',  0.00, 'izin',        'ucretsiz',      false, 5),
  ('raporlu',       'Raporlu',           'R',  0.00, 'rapor',       'rapor',         false, 6),
  ('resmi_tatil',   'Resmî tatil',       'RT', 0.00, 'tatil',       'resmi_tatil',   false, 7);

-- -----------------------------------------------------------------------------
-- Aylık dönem (proje + ay). İlk kayıt veya ilk durum işlemiyle oluşur.
-- -----------------------------------------------------------------------------
create table public.puantaj_periods (
  id                uuid primary key default gen_random_uuid(),
  project_id        uuid not null references public.projects (id) on delete restrict,
  month             date not null check (month = date_trunc('month', month)::date),
  status            public.puantaj_period_status not null default 'taslak',
  revision          integer not null default 0 check (revision >= 0),
  submitted_at      timestamptz,
  submitted_by      uuid,
  approved_at       timestamptz,
  approved_by       uuid,
  -- İlk onay bilgisi yeniden açmada silinmez.
  first_approved_at timestamptz,
  first_approved_by uuid,
  locked_at         timestamptz,
  locked_by         uuid,
  is_demo           boolean not null default false,
  constraint puantaj_periods_month_uq unique (project_id, month)
);
select private.add_row_meta('public.puantaj_periods');
select audit.enable('public.puantaj_periods');

-- -----------------------------------------------------------------------------
-- Günlük kayıt
-- -----------------------------------------------------------------------------
create table public.puantaj_entries (
  id                   uuid primary key default gen_random_uuid(),
  period_id            uuid not null references public.puantaj_periods (id) on delete restrict,
  project_id           uuid not null references public.projects (id) on delete restrict,
  personnel_id         uuid not null references public.personnel (id) on delete restrict,
  work_date            date not null,
  status               public.puantaj_status not null,
  overtime_hours       numeric(4, 2) not null default 0 check (overtime_hours >= 0 and overtime_hours <= 16),
  overtime_note        text,
  overtime_approved_at timestamptz,
  overtime_approved_by uuid,
  note                 text,
  -- Kayıt anındaki tarihli bağlantı ve adlar (sonradan değişmez).
  assignment_id        uuid not null references public.project_assignments (id) on delete restrict,
  membership_id        uuid references public.crew_memberships (id) on delete restrict,
  crew_id              uuid references public.crews (id) on delete restrict,
  subcontractor_id     uuid references public.subcontractors (id) on delete restrict,
  employment_type      public.employment_type not null,
  personnel_name       text not null,
  crew_name            text,
  is_demo              boolean not null default false,
  deleted_at           timestamptz,
  constraint puantaj_entries_day_uq unique (project_id, personnel_id, work_date)
);
create index puantaj_entries_project_day_idx on public.puantaj_entries (project_id, work_date);
create index puantaj_entries_personnel_day_idx on public.puantaj_entries (personnel_id, work_date);
create index puantaj_entries_period_idx on public.puantaj_entries (period_id);
select private.add_row_meta('public.puantaj_entries');
select audit.enable('public.puantaj_entries');

-- -----------------------------------------------------------------------------
-- Ay durum geçmişi: gönderme, iade, onay, kilit, yeniden açma. Onay satırı
-- ayın o anki tam görüntüsünü (kayıtlar + özet) taşır. Değiştirilemez.
-- -----------------------------------------------------------------------------
create table public.puantaj_period_events (
  id          uuid primary key default gen_random_uuid(),
  period_id   uuid not null references public.puantaj_periods (id) on delete restrict,
  project_id  uuid not null references public.projects (id) on delete restrict,
  action      text not null check (action in ('gonder', 'iade', 'onayla', 'kilitle', 'yeniden_ac')),
  from_status public.puantaj_period_status not null,
  to_status   public.puantaj_period_status not null,
  revision    integer not null,
  reason      text,
  snapshot    jsonb,
  actor_id    uuid,
  occurred_at timestamptz not null default clock_timestamp()
);
create index puantaj_period_events_period_idx on public.puantaj_period_events (period_id, occurred_at);
select private.add_row_meta('public.puantaj_period_events');
select audit.enable('public.puantaj_period_events');

-- -----------------------------------------------------------------------------
-- Yardımcılar
-- -----------------------------------------------------------------------------

-- Kişinin o gün projedeki bağlantısı: önce doğrudan görevlendirme, yoksa
-- projeye görevli ekipteki üyelik (project_workforce ile aynı öncelik).
create or replace function private.puantaj_link(p_project uuid, p_personnel uuid, p_day date)
returns table (assignment_id uuid, membership_id uuid, crew_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select x.assignment_id, x.membership_id, x.crew_id
    from (
      select a.id as assignment_id, null::uuid as membership_id, null::uuid as crew_id, 0 as priority
        from public.project_assignments a
       where a.project_id = p_project
         and a.personnel_id = p_personnel
         and p_day between a.start_date and coalesce(a.end_date, 'infinity'::date)
      union all
      select a.id, m.id, a.crew_id, 1
        from public.project_assignments a
        join public.crew_memberships m on m.crew_id = a.crew_id
       where a.project_id = p_project
         and m.personnel_id = p_personnel
         and p_day between a.start_date and coalesce(a.end_date, 'infinity'::date)
         and p_day between m.start_date and coalesce(m.end_date, 'infinity'::date)
    ) x
   order by x.priority
   limit 1;
$$;

-- Ayın dönem satırını getirir, yoksa taslak olarak açar.
create or replace function private.puantaj_period_id(p_project uuid, p_month date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id   uuid;
  v_demo boolean;
begin
  select pp.id into v_id from public.puantaj_periods pp where pp.project_id = p_project and pp.month = p_month;
  if found then
    return v_id;
  end if;
  select pr.is_demo into v_demo from public.projects pr where pr.id = p_project and pr.deleted_at is null;
  if not found then
    raise exception 'Proje bulunamadı' using errcode = 'foreign_key_violation';
  end if;
  insert into public.puantaj_periods (project_id, month, is_demo)
  values (p_project, p_month, v_demo)
  on conflict (project_id, month) do nothing;
  select pp.id into v_id from public.puantaj_periods pp where pp.project_id = p_project and pp.month = p_month;
  return v_id;
end;
$$;

create or replace function private.puantaj_status_label(p_status public.puantaj_period_status)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_status
           when 'taslak' then 'taslak'
           when 'incelemede' then 'incelemede'
           when 'onaylandi' then 'onaylandı'
           when 'kilitli' then 'kilitli'
         end;
$$;

-- -----------------------------------------------------------------------------
-- Kural trigger'ları
-- -----------------------------------------------------------------------------
create or replace function private.tg_puantaj_entry_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project       public.projects;
  v_person        public.personnel;
  v_period        public.puantaj_periods;
  v_def           public.puantaj_status_definitions;
  v_link          record;
  v_only_approval boolean := false;
  v_meta          text[] := array['updated_at', 'updated_by', 'version', 'overtime_approved_at', 'overtime_approved_by'];
begin
  if tg_op = 'UPDATE'
     and (new.project_id <> old.project_id or new.personnel_id <> old.personnel_id
          or new.work_date <> old.work_date or new.period_id <> old.period_id) then
    raise exception 'Puantaj kaydının projesi, kişisi veya günü değiştirilemez' using errcode = 'check_violation';
  end if;

  if tg_op = 'INSERT' then
    select * into v_project from public.projects pr where pr.id = new.project_id;
    if not found or v_project.deleted_at is not null then
      raise exception 'Proje bulunamadı' using errcode = 'foreign_key_violation';
    end if;
    new.period_id := private.puantaj_period_id(new.project_id, date_trunc('month', new.work_date)::date);
    new.is_demo := v_project.is_demo;
  else
    v_only_approval := (to_jsonb(new) - v_meta) = (to_jsonb(old) - v_meta);
  end if;

  -- Ay sınırı ve kilit: onaylı/kilitli ayda kimse değiştiremez.
  select * into v_period from public.puantaj_periods pp where pp.id = new.period_id;
  if v_period.project_id <> new.project_id
     or v_period.month <> date_trunc('month', new.work_date)::date then
    raise exception 'Kaydın tarihi veya projesi dönemiyle uyuşmuyor' using errcode = 'check_violation';
  end if;
  if v_period.status in ('onaylandi', 'kilitli') then
    raise exception '% ayının puantajı %; değişiklik için ayın yetkili kişi tarafından gerekçeyle yeniden açılması gerekir',
      to_char(v_period.month, 'MM.YYYY'), private.puantaj_status_label(v_period.status)
      using errcode = 'check_violation';
  end if;

  if auth.uid() is not null then
    if v_only_approval then
      if not private.has_permission('puantaj.approve', new.project_id) then
        raise exception 'Fazla mesai onaylama yetkiniz yok' using errcode = 'insufficient_privilege';
      end if;
    elsif v_period.status = 'taslak' and not private.has_permission('puantaj.write', new.project_id) then
      raise exception 'Bu projede puantaj girme yetkiniz yok' using errcode = 'insufficient_privilege';
    elsif v_period.status = 'incelemede' and not private.has_permission('puantaj.review', new.project_id) then
      raise exception 'Ay incelemede; yalnızca inceleme yetkisi olan kişi değiştirebilir' using errcode = 'insufficient_privilege';
    end if;
  end if;

  if new.deleted_at is null then
    select * into v_def from public.puantaj_status_definitions d where d.status = new.status;
    if new.overtime_hours > 0 and not v_def.allows_overtime then
      raise exception 'Fazla mesai yalnızca tam veya yarım gün çalışılan güne yazılabilir' using errcode = 'check_violation';
    end if;
    if v_def.category = 'calisma' and new.work_date > private.today() then
      raise exception 'İleri bir tarihe çalışma girilemez (%)', to_char(new.work_date, 'DD.MM.YYYY')
        using errcode = 'check_violation';
    end if;
  end if;

  if tg_op = 'INSERT' or (old.deleted_at is not null and new.deleted_at is null) then
    -- Tarihli bağlantıyı ve adları çöz (yeni kayıt ya da temizlenmiş hücreye yeniden giriş).
    select * into v_person from public.personnel p where p.id = new.personnel_id;
    if not found or v_person.deleted_at is not null then
      raise exception 'Personel bulunamadı' using errcode = 'foreign_key_violation';
    end if;
    if v_person.is_demo is distinct from new.is_demo then
      raise exception 'Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez' using errcode = 'check_violation';
    end if;
    select * into v_link from private.puantaj_link(new.project_id, new.personnel_id, new.work_date);
    if not found then
      raise exception '% bu tarihte (%) projede görevli değil; önce görevlendirme veya ekip üyeliği ekleyin',
        v_person.full_name, to_char(new.work_date, 'DD.MM.YYYY') using errcode = 'check_violation';
    end if;
    new.assignment_id    := v_link.assignment_id;
    new.membership_id    := v_link.membership_id;
    new.crew_id          := v_link.crew_id;
    new.subcontractor_id := v_person.subcontractor_id;
    new.employment_type  := v_person.employment_type;
    new.personnel_name   := v_person.full_name;
    new.crew_name        := (select c.name from public.crews c where c.id = v_link.crew_id);
  else
    -- Geçmiş bağlantı ve adlar sabit kalır.
    new.assignment_id    := old.assignment_id;
    new.membership_id    := old.membership_id;
    new.crew_id          := old.crew_id;
    new.subcontractor_id := old.subcontractor_id;
    new.employment_type  := old.employment_type;
    new.personnel_name   := old.personnel_name;
    new.crew_name        := old.crew_name;
    new.is_demo          := old.is_demo;
  end if;

  -- Saat veya durum değişirse fazla mesai onayı düşer.
  if new.overtime_hours = 0
     or (tg_op = 'UPDATE' and (new.overtime_hours <> old.overtime_hours or new.status <> old.status
                               or new.deleted_at is distinct from old.deleted_at)) then
    new.overtime_approved_at := null;
    new.overtime_approved_by := null;
  end if;
  return new;
end;
$$;

create trigger puantaj_entry_rules before insert or update on public.puantaj_entries
  for each row execute function private.tg_puantaj_entry_rules();

create or replace function private.tg_puantaj_period_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.project_id <> old.project_id or new.month <> old.month or new.is_demo <> old.is_demo then
    raise exception 'Puantaj döneminin projesi veya ayı değiştirilemez' using errcode = 'check_violation';
  end if;
  if old.first_approved_at is not null
     and (new.first_approved_at is distinct from old.first_approved_at
          or new.first_approved_by is distinct from old.first_approved_by) then
    raise exception 'İlk onay bilgisi değiştirilemez' using errcode = 'check_violation';
  end if;
  if new.revision < old.revision then
    raise exception 'Revizyon numarası geri alınamaz' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger puantaj_period_guard before update on public.puantaj_periods
  for each row execute function private.tg_puantaj_period_guard();

create or replace function private.tg_puantaj_event_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Puantaj onay geçmişi değiştirilemez veya silinemez' using errcode = 'insufficient_privilege';
end;
$$;

create trigger puantaj_event_immutable before update or delete on public.puantaj_period_events
  for each row execute function private.tg_puantaj_event_immutable();
create trigger puantaj_definitions_immutable before delete on public.puantaj_status_definitions
  for each row execute function private.tg_puantaj_event_immutable();

-- -----------------------------------------------------------------------------
-- RLS: okuma proje izniyle; yazma yalnızca RPC'lerle (tablo yetkisi kapalı).
-- -----------------------------------------------------------------------------
alter table public.puantaj_status_definitions enable row level security;
alter table public.puantaj_periods            enable row level security;
alter table public.puantaj_entries            enable row level security;
alter table public.puantaj_period_events      enable row level security;

create policy puantaj_status_definitions_select on public.puantaj_status_definitions
  for select to authenticated using (private.is_active_user());
create policy puantaj_periods_select on public.puantaj_periods
  for select to authenticated using (private.has_permission('puantaj.read', project_id));
create policy puantaj_entries_select on public.puantaj_entries
  for select to authenticated using (private.has_permission('puantaj.read', project_id));
create policy puantaj_period_events_select on public.puantaj_period_events
  for select to authenticated using (private.has_permission('puantaj.read', project_id));

-- -----------------------------------------------------------------------------
-- RPC'ler
-- -----------------------------------------------------------------------------

-- Toplu kayıt (tek hücre de bu yolla). p_items öğeleri:
--   personnel_id, work_date, status (null = hücreyi temizle), overtime_hours,
--   overtime_note, note, expected_version (okunan sürüm; yeni hücrede null)
-- Sonuç (öğe başına): eklendi, guncellendi, silindi, degismedi, atlandi
-- (var olan kayıt, üzerine yazma istenmedi), bos (zaten boş hücre temizlendi).
-- Tek işlemdir: herhangi bir öğe reddedilirse hiçbiri kaydedilmez. Aynı isteğin
-- tekrar gönderilmesi "degismedi" döner. Okunan sürüm sunucudakinden eskiyse
-- ve değer farklıysa istek reddedilir (başkasının değişikliği ezilmez).
create or replace function public.save_puantaj(p_project_id uuid, p_items jsonb, p_overwrite boolean default false)
returns table (personnel_id uuid, work_date date, result text, entry_id uuid, version integer)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_item  record;
  v_row   public.puantaj_entries;
  v_month date;
  v_ot    numeric;
begin
  if not (private.has_permission('puantaj.write', p_project_id)
          or private.has_permission('puantaj.review', p_project_id)) then
    raise exception 'Bu projede puantaj girme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Kaydedilecek hücre yok' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_items) > 3000 then
    raise exception 'Tek seferde en fazla 3000 hücre kaydedilebilir' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_items) as x (personnel_id uuid, work_date date)
              where x.personnel_id is null or x.work_date is null) then
    raise exception 'Her hücre için kişi ve gün gerekli' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_items) as x (personnel_id uuid, work_date date)
              group by x.personnel_id, x.work_date having count(*) > 1) then
    raise exception 'Aynı kişi ve gün listede iki kez var' using errcode = 'invalid_parameter_value';
  end if;

  -- Ay durum işlemleriyle yarışmamak için dönemleri ay sırasıyla kilitle.
  for v_month in
    select distinct date_trunc('month', x.work_date)::date
      from jsonb_to_recordset(p_items) as x (work_date date) order by 1
  loop
    perform private.puantaj_period_id(p_project_id, v_month);
    perform 1 from public.puantaj_periods pp
      where pp.project_id = p_project_id and pp.month = v_month for share;
  end loop;

  for v_item in
    select * from jsonb_to_recordset(p_items) as x (
      personnel_id uuid, work_date date, status public.puantaj_status, overtime_hours numeric,
      overtime_note text, note text, expected_version integer)
     order by x.personnel_id, x.work_date
  loop
    v_ot := coalesce(v_item.overtime_hours, 0);
    select * into v_row from public.puantaj_entries e
     where e.project_id = p_project_id and e.personnel_id = v_item.personnel_id and e.work_date = v_item.work_date
       for update;

    if not found or v_row.deleted_at is not null then
      if v_item.status is null then
        personnel_id := v_item.personnel_id; work_date := v_item.work_date;
        result := 'bos'; entry_id := v_row.id; version := v_row.version;
        return next;
        continue;
      end if;
      if not found then
        insert into public.puantaj_entries (project_id, personnel_id, work_date, status, overtime_hours, overtime_note, note)
        values (p_project_id, v_item.personnel_id, v_item.work_date, v_item.status, v_ot,
                nullif(trim(v_item.overtime_note), ''), nullif(trim(v_item.note), ''))
        returning * into v_row;
      else
        update public.puantaj_entries e
           set status = v_item.status, overtime_hours = v_ot,
               overtime_note = nullif(trim(v_item.overtime_note), ''), note = nullif(trim(v_item.note), ''),
               deleted_at = null
         where e.id = v_row.id
        returning * into v_row;
      end if;
      result := 'eklendi';
    elsif v_row.status = v_item.status and v_row.overtime_hours = v_ot
          and coalesce(v_row.overtime_note, '') = coalesce(nullif(trim(v_item.overtime_note), ''), '')
          and coalesce(v_row.note, '') = coalesce(nullif(trim(v_item.note), ''), '') then
      result := 'degismedi';
    elsif v_item.expected_version is not null and v_item.expected_version <> v_row.version then
      raise exception '% için % tarihli kayıt siz düzenlerken başka biri tarafından değiştirildi. Tabloyu yenileyip tekrar deneyin.',
        v_row.personnel_name, to_char(v_row.work_date, 'DD.MM.YYYY') using errcode = 'serialization_failure';
    elsif v_item.expected_version is null and not p_overwrite then
      result := 'atlandi';
    elsif v_item.status is null then
      update public.puantaj_entries e set deleted_at = now() where e.id = v_row.id returning * into v_row;
      result := 'silindi';
    else
      update public.puantaj_entries e
         set status = v_item.status, overtime_hours = v_ot,
             overtime_note = nullif(trim(v_item.overtime_note), ''), note = nullif(trim(v_item.note), '')
       where e.id = v_row.id
      returning * into v_row;
      result := 'guncellendi';
    end if;

    personnel_id := v_row.personnel_id; work_date := v_row.work_date;
    entry_id := v_row.id; version := v_row.version;
    return next;
  end loop;
end;
$$;

-- Ay durum işlemleri:
--   gonder     : taslak → incelemede               (puantaj.write)
--   iade       : incelemede → taslak               (puantaj.review)
--   onayla     : taslak/incelemede → onaylandi     (puantaj.approve)
--   kilitle    : onaylandi → kilitli               (puantaj.approve)
--   yeniden_ac : onaylandi → taslak (puantaj.approve), kilitli → taslak
--                (puantaj.unlock); gerekçe zorunlu, revizyon +1.
create or replace function public.puantaj_transition(
  p_project_id       uuid,
  p_month            date,
  p_action           text,
  p_reason           text default null,
  p_expected_version integer default null)
returns public.puantaj_periods
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_period   public.puantaj_periods;
  v_from     public.puantaj_period_status[];
  v_to       public.puantaj_period_status;
  v_perm     text;
  v_reason   text := nullif(trim(p_reason), '');
  v_snapshot jsonb;
  v_revision integer;
  v_prev     public.puantaj_period_status;
begin
  if not private.has_permission('puantaj.read', p_project_id) then
    raise exception 'Bu projenin puantajını görme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if p_month is null or p_month <> date_trunc('month', p_month)::date then
    raise exception 'Ay, ayın ilk günüyle belirtilmeli' using errcode = 'invalid_parameter_value';
  end if;

  case p_action
    when 'gonder'     then v_from := '{taslak}';               v_to := 'incelemede'; v_perm := 'puantaj.write';
    when 'iade'       then v_from := '{incelemede}';           v_to := 'taslak';     v_perm := 'puantaj.review';
    when 'onayla'     then v_from := '{taslak,incelemede}';    v_to := 'onaylandi';  v_perm := 'puantaj.approve';
    when 'kilitle'    then v_from := '{onaylandi}';            v_to := 'kilitli';    v_perm := 'puantaj.approve';
    when 'yeniden_ac' then v_from := '{onaylandi,kilitli}';    v_to := 'taslak';     v_perm := 'puantaj.approve';
    else raise exception 'Geçersiz puantaj işlemi: %', p_action using errcode = 'invalid_parameter_value';
  end case;

  perform private.puantaj_period_id(p_project_id, p_month);
  select * into v_period from public.puantaj_periods pp
   where pp.project_id = p_project_id and pp.month = p_month
     for update;

  if p_expected_version is not null and p_expected_version <> v_period.version then
    raise exception 'Ayın durumu siz bakarken değişti. Ekranı yenileyip tekrar deneyin.' using errcode = 'serialization_failure';
  end if;
  if not (v_period.status = any (v_from)) then
    raise exception 'Bu işlem % durumundaki ay için yapılamaz', private.puantaj_status_label(v_period.status)
      using errcode = 'check_violation';
  end if;
  if p_action = 'yeniden_ac' and v_period.status = 'kilitli' then
    v_perm := 'puantaj.unlock';
  end if;
  if not private.has_permission(v_perm, p_project_id) then
    raise exception '%', case v_perm
        when 'puantaj.write'   then 'Ayı incelemeye gönderme yetkiniz yok'
        when 'puantaj.review'  then 'Ayı taslağa iade etme yetkiniz yok'
        when 'puantaj.approve' then 'Puantaj onaylama yetkiniz yok'
        else 'Kilitli ayı yeniden açma yetkiniz yok' end
      using errcode = 'insufficient_privilege';
  end if;
  if p_action = 'yeniden_ac' and length(coalesce(v_reason, '')) < 10 then
    raise exception 'Yeniden açma gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;

  v_revision := v_period.revision;
  v_prev := v_period.status;
  if p_action = 'onayla' then
    if not exists (select 1 from public.puantaj_entries e where e.period_id = v_period.id and e.deleted_at is null) then
      raise exception 'Hiç kayıt olmayan ay onaylanamaz' using errcode = 'check_violation';
    end if;
    select jsonb_build_object(
             'entries', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', e.id, 'personnel_id', e.personnel_id, 'personnel_name', e.personnel_name,
                        'work_date', e.work_date, 'status', e.status, 'overtime_hours', e.overtime_hours,
                        'overtime_approved', e.overtime_approved_at is not null, 'note', e.note,
                        'assignment_id', e.assignment_id, 'membership_id', e.membership_id,
                        'crew_id', e.crew_id, 'crew_name', e.crew_name, 'subcontractor_id', e.subcontractor_id,
                        'employment_type', e.employment_type, 'version', e.version)
                      order by e.personnel_name, e.work_date)
                 from public.puantaj_entries e
                where e.period_id = v_period.id and e.deleted_at is null), '[]'::jsonb),
             'summary', coalesce((
               select jsonb_agg(to_jsonb(s) order by s.personnel_name)
                 from public.puantaj_summary(p_project_id, p_month) s), '[]'::jsonb))
      into v_snapshot;
    update public.puantaj_periods pp
       set status = v_to, approved_at = now(), approved_by = auth.uid(),
           first_approved_at = coalesce(pp.first_approved_at, now()),
           first_approved_by = coalesce(pp.first_approved_by, auth.uid())
     where pp.id = v_period.id
    returning * into v_period;
  elsif p_action = 'gonder' then
    update public.puantaj_periods pp
       set status = v_to, submitted_at = now(), submitted_by = auth.uid()
     where pp.id = v_period.id
    returning * into v_period;
  elsif p_action = 'kilitle' then
    update public.puantaj_periods pp
       set status = v_to, locked_at = now(), locked_by = auth.uid()
     where pp.id = v_period.id
    returning * into v_period;
  elsif p_action = 'iade' then
    update public.puantaj_periods pp
       set status = v_to, submitted_at = null, submitted_by = null
     where pp.id = v_period.id
    returning * into v_period;
  else  -- yeniden_ac: önceki onaylı görüntü olay kaydında kalır
    v_revision := v_period.revision + 1;
    update public.puantaj_periods pp
       set status = v_to, revision = v_revision,
           submitted_at = null, submitted_by = null, approved_at = null, approved_by = null,
           locked_at = null, locked_by = null
     where pp.id = v_period.id
    returning * into v_period;
  end if;

  insert into public.puantaj_period_events (period_id, project_id, action, from_status, to_status, revision, reason, snapshot, actor_id)
  values (v_period.id, p_project_id, p_action, v_prev, v_to, v_revision, v_reason, v_snapshot, auth.uid());
  return v_period;
end;
$$;

-- Fazla mesai onayı (puantaj.approve). Onaylanan saat değişirse onay düşer.
create or replace function public.approve_puantaj_overtime(p_entry_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if exists (select 1 from public.puantaj_entries e
              where e.id = any (p_entry_ids)
                and not private.has_permission('puantaj.approve', e.project_id)) then
    raise exception 'Fazla mesai onaylama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  update public.puantaj_entries e
     set overtime_approved_at = now(), overtime_approved_by = auth.uid()
   where e.id = any (p_entry_ids)
     and e.deleted_at is null
     and e.overtime_hours > 0
     and e.overtime_approved_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Ay tablosunun satırları: ay içinde projede görevli olan kişiler ve görev
-- aralıkları (aya kırpılmış). Bir kişi ay içinde ekip değiştirdiyse birden
-- fazla satır döner. Yalnızca ad, görev, ekip ve taşeron adı verilir.
create or replace function public.puantaj_roster(p_project_id uuid, p_month date)
returns table (
  personnel_id       uuid,
  full_name          text,
  job_title          text,
  employment_type    public.employment_type,
  subcontractor_id   uuid,
  subcontractor_name text,
  via                text,
  crew_id            uuid,
  crew_name          text,
  assignment_id      uuid,
  membership_id      uuid,
  start_date         date,
  end_date           date,
  is_demo            boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_m0 date := date_trunc('month', p_month)::date;
  v_m1 date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
begin
  if not private.has_permission('puantaj.read', p_project_id) then
    raise exception 'Bu projenin puantajını görme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  return query
    with links as (
      select a.personnel_id, 'dogrudan'::text as via, null::uuid as crew_id, a.id as assignment_id,
             null::uuid as membership_id,
             greatest(a.start_date, v_m0) as s, least(coalesce(a.end_date, 'infinity'::date), v_m1) as e
        from public.project_assignments a
       where a.project_id = p_project_id and a.personnel_id is not null
      union all
      select m.personnel_id, 'ekip', a.crew_id, a.id, m.id,
             greatest(a.start_date, m.start_date, v_m0),
             least(coalesce(a.end_date, 'infinity'::date), coalesce(m.end_date, 'infinity'::date), v_m1)
        from public.project_assignments a
        join public.crew_memberships m on m.crew_id = a.crew_id
       where a.project_id = p_project_id
    )
    select l.personnel_id, p.full_name, p.job_title, p.employment_type, p.subcontractor_id, s.name,
           l.via, l.crew_id, c.name, l.assignment_id, l.membership_id, l.s, l.e, p.is_demo
      from links l
      join public.personnel p on p.id = l.personnel_id and p.deleted_at is null
      left join public.subcontractors s on s.id = p.subcontractor_id
      left join public.crews c on c.id = l.crew_id
     where l.s <= l.e
     order by c.name nulls first, p.full_name, l.s;
end;
$$;

-- Kişi bazında aylık özet. Her sütun tek bir kategoriyi sayar; kategoriler
-- birbirine eklenmez. fiili_calisma = tam_gun × 1 + yarim_gun × 0,5.
-- Girilmemiş gün hiçbir sütuna girmez (devamsızlık sayılmaz).
-- SECURITY INVOKER: kullanıcı yalnızca görebildiği kayıtların özetini alır.
create or replace function public.puantaj_summary(p_project_id uuid, p_month date)
returns table (
  personnel_id        uuid,
  personnel_name      text,
  kayitli_gun         integer,
  tam_gun             integer,
  yarim_gun           integer,
  fiili_calisma       numeric,
  calismadi           integer,
  ucretli_izin        integer,
  ucretsiz_izin       integer,
  raporlu             integer,
  resmi_tatil         integer,
  fazla_mesai_saat    numeric,
  onayli_fazla_mesai  numeric)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not private.has_permission('puantaj.read', p_project_id) then
    raise exception 'Bu projenin puantajını görme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  return query
    select e.personnel_id,
           max(e.personnel_name),
           count(*)::integer,
           count(*) filter (where e.status = 'tam_gun')::integer,
           count(*) filter (where e.status = 'yarim_gun')::integer,
           sum(d.work_equivalent),
           count(*) filter (where e.status = 'calismadi')::integer,
           count(*) filter (where e.status = 'ucretli_izin')::integer,
           count(*) filter (where e.status = 'ucretsiz_izin')::integer,
           count(*) filter (where e.status = 'raporlu')::integer,
           count(*) filter (where e.status = 'resmi_tatil')::integer,
           sum(e.overtime_hours),
           coalesce(sum(e.overtime_hours) filter (where e.overtime_approved_at is not null), 0)
      from public.puantaj_entries e
      join public.puantaj_status_definitions d on d.status = e.status
     where e.project_id = p_project_id
       and e.work_date >= date_trunc('month', p_month)::date
       and e.work_date <  (date_trunc('month', p_month) + interval '1 month')::date
       and e.deleted_at is null
     group by e.personnel_id
     order by max(e.personnel_name);
end;
$$;

grant execute on function public.save_puantaj(uuid, jsonb, boolean) to authenticated;
grant execute on function public.puantaj_transition(uuid, date, text, text, integer) to authenticated;
grant execute on function public.approve_puantaj_overtime(uuid[]) to authenticated;
grant execute on function public.puantaj_roster(uuid, date) to authenticated;
grant execute on function public.puantaj_summary(uuid, date) to authenticated;

-- -----------------------------------------------------------------------------
-- API ayrıcalıkları: puantaj tabloları yalnızca RPC'lerle yazılır.
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
end;
$$;

revoke execute on function private.harden_api_privileges() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- İzinler ve rol şablonları. Finans rolü (muhasebe) yalnızca okur; onay
-- yetkisi proje müdürü ve yöneticidedir; kilitli ayı yalnızca yönetici açar.
-- -----------------------------------------------------------------------------
insert into public.permissions (key, module, description) values
  ('puantaj.read',    'puantaj', 'Puantajı ve aylık özetleri görüntüleme'),
  ('puantaj.write',   'puantaj', 'Taslak aya puantaj girme ve ayı incelemeye gönderme'),
  ('puantaj.review',  'puantaj', 'İncelemedeki ayda düzeltme yapma ve ayı taslağa iade etme'),
  ('puantaj.approve', 'puantaj', 'Ayı onaylama, kilitleme, onaylı ayı yeniden açma ve fazla mesai onayı'),
  ('puantaj.unlock',  'puantaj', 'Kilitli ayı gerekçeyle yeniden açma');

insert into public.roles (key, name, description, scope, is_template, is_system) values
  ('proje_muduru', 'Proje müdürü',
   'Üye olduğu projede saha, görevlendirme ve puantaj onayı; finans görmez', 'project', true, false);

insert into public.role_permissions (role_id, permission_key)
select r.id, x.permission_key
  from (values
          ('proje_muduru',  'proje.read'),
          ('proje_muduru',  'taseron.read'),
          ('proje_muduru',  'personel.read'),
          ('proje_muduru',  'personel_iletisim.read'),
          ('proje_muduru',  'gorevlendirme.read'),
          ('proje_muduru',  'gorevlendirme.write'),
          ('proje_muduru',  'puantaj.read'),
          ('proje_muduru',  'puantaj.write'),
          ('proje_muduru',  'puantaj.review'),
          ('proje_muduru',  'puantaj.approve'),
          ('santiye_sefi',  'puantaj.read'),
          ('santiye_sefi',  'puantaj.write'),
          ('idari_isler',   'puantaj.read'),
          ('idari_isler',   'puantaj.write'),
          ('idari_isler',   'puantaj.review'),
          ('muhasebe',      'puantaj.read'),
          ('goruntuleyici', 'puantaj.read')
       ) as x (role_key, permission_key)
  join public.roles r on r.key = x.role_key;

select private.harden_api_privileges();
