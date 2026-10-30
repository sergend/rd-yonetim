-- =============================================================================
-- RD Yönetim · Aşama 0 · 3/5 · Kullanıcılar, roller, izinler
-- =============================================================================
-- Etkin izin üç kaynaktan birleşir (bkz. private.has_permission):
--   1. Genel roller (user_roles)              -> tüm projelerde ve proje dışı işlerde
--   2. Projedeki rol (project_members.role_id) -> yalnızca o projede
--   3. Kullanıcıya özel izinler (user_permission_overrides): grant / deny
-- Yasak (deny) her zaman kazanır. Roller yalnızca başlangıç şablonudur.

create type public.role_scope as enum ('global', 'project');
create type public.permission_effect as enum ('grant', 'deny');

-- -----------------------------------------------------------------------------
-- Profiller: auth.users ile 1:1. Kullanıcı silinmez, pasifleştirilir.
-- -----------------------------------------------------------------------------
create table public.profiles (
  id        uuid primary key references auth.users (id) on delete restrict,
  email     text not null,
  full_name text not null default '',
  phone     text,
  is_active boolean not null default true
);
select private.add_row_meta('public.profiles');
select audit.enable('public.profiles');

-- Supabase Auth'ta kullanıcı oluşturulunca (davet) profil otomatik açılır.
create or replace function private.tg_create_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id,
          coalesce(new.email, ''),
          coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  return new;
end;
$$;

-- auth şeması yedeğin şema dökümüne girmez; bu trigger geri yüklemeden sonra
-- private.post_restore() ile yeniden kurulur. Bu yüzden fonksiyon olarak tutulur.
create or replace function private.install_auth_hooks()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop trigger if exists on_auth_user_created on auth.users;
  create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function private.tg_create_profile();
end;
$$;

select private.install_auth_hooks();

-- -----------------------------------------------------------------------------
-- İzin kataloğu: yalnızca migration'larla değişir (uygulamadan yazılamaz).
-- Anahtar biçimi: <modül>.<eylem>, ör. proje.write, puantaj.approve_own
-- -----------------------------------------------------------------------------
create table public.permissions (
  id          uuid primary key default gen_random_uuid(),
  key         text not null unique check (key ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  module      text not null,
  description text not null
);
select private.add_row_meta('public.permissions');
select audit.enable('public.permissions');

-- -----------------------------------------------------------------------------
-- Roller. scope = global: user_roles ile atanır; project: project_members ile.
-- -----------------------------------------------------------------------------
create table public.roles (
  id          uuid primary key default gen_random_uuid(),
  key         text not null check (key ~ '^[a-z][a-z0-9_]*$'),
  name        text not null,
  description text,
  scope       public.role_scope not null,
  is_template boolean not null default false,
  is_system   boolean not null default false, -- sistem rolü silinemez
  deleted_at  timestamptz
);
create unique index roles_key_active_uq on public.roles (key) where deleted_at is null;
select private.add_row_meta('public.roles');
select audit.enable('public.roles');

create or replace function private.tg_protect_system_role()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.is_system and (new.deleted_at is not null
                        or new.key   is distinct from old.key
                        or new.scope is distinct from old.scope
                        or not new.is_system) then
    raise exception 'Sistem rolü silinemez veya anahtarı/kapsamı değiştirilemez'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger protect_system_role before update on public.roles
  for each row execute function private.tg_protect_system_role();

create table public.role_permissions (
  id             uuid primary key default gen_random_uuid(),
  role_id        uuid not null references public.roles (id) on delete restrict,
  permission_key text not null references public.permissions (key) on update cascade on delete restrict,
  deleted_at     timestamptz
);
create unique index role_permissions_active_uq
  on public.role_permissions (role_id, permission_key) where deleted_at is null;
select private.add_row_meta('public.role_permissions');
select audit.enable('public.role_permissions');

-- -----------------------------------------------------------------------------
-- Genel rol atamaları (yalnızca scope = global roller).
-- -----------------------------------------------------------------------------
create table public.user_roles (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete restrict,
  role_id    uuid not null references public.roles (id) on delete restrict,
  deleted_at timestamptz
);
create unique index user_roles_active_uq
  on public.user_roles (user_id, role_id) where deleted_at is null;
create index user_roles_user_idx on public.user_roles (user_id) where deleted_at is null;
select private.add_row_meta('public.user_roles');
select audit.enable('public.user_roles');

-- Rolün kapsamı atama yeriyle uyumlu olmalı (global/proje).
create or replace function private.tg_check_role_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_expected public.role_scope := tg_argv[0]::public.role_scope;
  v_scope    public.role_scope;
begin
  if new.role_id is null then
    return new;
  end if;
  select r.scope into v_scope from public.roles r where r.id = new.role_id;
  if v_scope is distinct from v_expected then
    raise exception 'Bu tabloya yalnızca % kapsamlı rol atanabilir', v_expected
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger check_role_scope before insert or update of role_id on public.user_roles
  for each row execute function private.tg_check_role_scope('global');

-- -----------------------------------------------------------------------------
-- Kullanıcıya özel izinler. project_id boşsa tüm projelerde ve proje dışında
-- geçerlidir. valid_to boşsa süresizdir. Kaldırmak için deleted_at doldurulur.
-- -----------------------------------------------------------------------------
create table public.user_permission_overrides (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles (id) on delete restrict,
  permission_key text not null references public.permissions (key) on update cascade on delete restrict,
  project_id     uuid, -- FK projeler migration'ında eklenir
  effect         public.permission_effect not null,
  valid_from     date not null default private.today(),
  valid_to       date,
  reason         text not null check (length(trim(reason)) > 0),
  deleted_at     timestamptz,
  check (valid_to is null or valid_to >= valid_from)
);
create index user_permission_overrides_user_idx
  on public.user_permission_overrides (user_id, permission_key) where deleted_at is null;
select private.add_row_meta('public.user_permission_overrides');
select audit.enable('public.user_permission_overrides');
