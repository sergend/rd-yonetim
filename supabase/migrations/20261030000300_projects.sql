-- =============================================================================
-- RD Yönetim · Aşama 0 · 4/5 · Projeler, proje üyeliği, genel masraf merkezleri
-- =============================================================================

create type public.project_status as enum ('planlama', 'devam', 'durdu', 'tamamlandi');

create table public.projects (
  id         uuid primary key default gen_random_uuid(),
  code       text not null check (length(trim(code)) > 0),
  name       text not null check (length(trim(name)) > 0),
  address    text,
  city       text,
  start_date date,
  end_date   date,
  status     public.project_status not null default 'planlama',
  notes      text,
  deleted_at timestamptz,
  check (end_date is null or start_date is null or end_date >= start_date)
);
create unique index projects_code_active_uq on public.projects (upper(code)) where deleted_at is null;
select private.add_row_meta('public.projects');
select audit.enable('public.projects');

alter table public.user_permission_overrides
  add constraint user_permission_overrides_project_fk
  foreign key (project_id) references public.projects (id) on delete restrict;

-- -----------------------------------------------------------------------------
-- Proje üyeliği ve projeye özel rol. Aynı kullanıcının aynı projede çakışan
-- iki aktif üyeliği olamaz (tarih aralığı dışlama kısıtı).
-- -----------------------------------------------------------------------------
create table public.project_members (
  id         uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete restrict,
  user_id    uuid not null references public.profiles (id) on delete restrict,
  role_id    uuid not null references public.roles (id) on delete restrict,
  valid_from date not null default private.today(),
  valid_to   date,
  note       text,
  deleted_at timestamptz,
  check (valid_to is null or valid_to >= valid_from),
  constraint project_members_no_overlap exclude using gist (
    project_id with =,
    user_id with =,
    daterange(valid_from, valid_to, '[]') with &&
  ) where (deleted_at is null)
);
create index project_members_user_idx on public.project_members (user_id) where deleted_at is null;
select private.add_row_meta('public.project_members');
select audit.enable('public.project_members');

create trigger check_role_scope before insert or update of role_id on public.project_members
  for each row execute function private.tg_check_role_scope('project');

-- -----------------------------------------------------------------------------
-- Genel masraf merkezleri: projeye bağlı olmayan şirket giderleri için
-- (ofis, araçlar, yönetim...). Gider tabloları Aşama 5'te bu tabloya bağlanır.
-- -----------------------------------------------------------------------------
create table public.cost_centers (
  id          uuid primary key default gen_random_uuid(),
  code        text not null check (length(trim(code)) > 0),
  name        text not null check (length(trim(name)) > 0),
  description text,
  is_active   boolean not null default true,
  deleted_at  timestamptz
);
create unique index cost_centers_code_active_uq on public.cost_centers (upper(code)) where deleted_at is null;
select private.add_row_meta('public.cost_centers');
select audit.enable('public.cost_centers');
