-- =============================================================================
-- RD Yönetim · Aşama 0 · 5/5 · Yetki fonksiyonları, RLS politikaları,
-- API ayrıcalıkları, izin kataloğu ve başlangıç rol şablonları
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Yetki yardımcıları
-- -----------------------------------------------------------------------------
create or replace function private.is_active_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where p.id = (select auth.uid()) and p.is_active
  );
$$;

-- Etkin izin = (genel roller ∪ o projedeki rol ∪ özel grant) − özel deny.
-- * p_project boşsa yalnızca genel roller ve projesiz (genel) özel izinler sayılır.
-- * is_system rolü (yonetici) tüm izinlere sahiptir; yeni izinler otomatik dahil olur.
-- * Pasif kullanıcının hiçbir izni yoktur.
create or replace function private.has_permission(p_permission text, p_project uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with me as (select (select auth.uid()) as uid, private.today() as today)
  select
    exists (select 1 from public.profiles p, me
             where p.id = me.uid and p.is_active)
    and not exists (
      select 1 from public.user_permission_overrides o, me
       where o.user_id = me.uid
         and o.permission_key = p_permission
         and o.effect = 'deny'
         and o.deleted_at is null
         and (o.project_id is null or o.project_id = p_project)
         and me.today between o.valid_from and coalesce(o.valid_to, 'infinity'::date))
    and (
      -- 1. Genel roller
      exists (
        select 1
          from public.user_roles ur
          join public.roles r on r.id = ur.role_id and r.deleted_at is null
          join me on ur.user_id = me.uid
         where ur.deleted_at is null
           and (r.is_system
                or exists (select 1 from public.role_permissions rp
                            where rp.role_id = r.id
                              and rp.deleted_at is null
                              and rp.permission_key = p_permission)))
      -- 2. Projedeki rol
      or (p_project is not null and exists (
        select 1
          from public.project_members pm
          join public.projects pr on pr.id = pm.project_id and pr.deleted_at is null
          join public.roles r on r.id = pm.role_id and r.deleted_at is null
          join public.role_permissions rp on rp.role_id = r.id and rp.deleted_at is null
          join me on pm.user_id = me.uid
         where pm.project_id = p_project
           and pm.deleted_at is null
           and me.today between pm.valid_from and coalesce(pm.valid_to, 'infinity'::date)
           and rp.permission_key = p_permission))
      -- 3. Kullanıcıya özel izin
      or exists (
        select 1 from public.user_permission_overrides o, me
         where o.user_id = me.uid
           and o.permission_key = p_permission
           and o.effect = 'grant'
           and o.deleted_at is null
           and (o.project_id is null or o.project_id = p_project)
           and me.today between o.valid_from and coalesce(o.valid_to, 'infinity'::date))
    );
$$;

grant execute on function private.is_active_user() to authenticated;
grant execute on function private.has_permission(text, uuid) to authenticated;

-- Profil satırı görünürlüğü: kişi kendini; kullanıcı yöneticisi herkesi; genel
-- rolü olan (tüm projelerde çalışan) herkesin adını; proje kullanıcıları ise
-- yalnızca aynı projede aktif üyesi olduğu kişileri görür. E-posta ve telefon
-- sütunları ayrıca kapalıdır (bkz. private.harden_api_privileges).
create or replace function private.can_see_profile(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with me as (select (select auth.uid()) as uid, private.today() as today)
  select private.is_active_user() and (
    p_user = (select uid from me)
    or private.has_permission('kullanici.manage')
    or exists (
      select 1
        from public.user_roles ur
        join public.roles r on r.id = ur.role_id and r.deleted_at is null
        join me on ur.user_id = me.uid
       where ur.deleted_at is null)
    or exists (
      select 1
        from public.project_members mine
        join public.project_members theirs on theirs.project_id = mine.project_id
        join public.projects pr on pr.id = mine.project_id and pr.deleted_at is null
        join me on mine.user_id = me.uid
       where theirs.user_id = p_user
         and mine.deleted_at is null
         and theirs.deleted_at is null
         and me.today between mine.valid_from   and coalesce(mine.valid_to,   'infinity'::date)
         and me.today between theirs.valid_from and coalesce(theirs.valid_to, 'infinity'::date))
  );
$$;

grant execute on function private.can_see_profile(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Son etkin sistem yöneticisi korunur. Etkin yönetici: aktif profil +
-- silinmemiş sistem rolü ataması + kullanici.manage üzerinde genel (projesiz)
-- yasak yok. Yasağın tarihleri bilerek dikkate alınmaz: ileri tarihli bir yasak
-- da sayılır, yoksa koruma o tarih geldiğinde sessizce delinirdi.
-- -----------------------------------------------------------------------------
create or replace function private.effective_admin_count()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(distinct ur.user_id)::integer
    from public.user_roles ur
    join public.roles r on r.id = ur.role_id and r.is_system and r.deleted_at is null
    join public.profiles p on p.id = ur.user_id and p.is_active
   where ur.deleted_at is null
     and not exists (
       select 1 from public.user_permission_overrides o
        where o.user_id = ur.user_id
          and o.permission_key = 'kullanici.manage'
          and o.effect = 'deny'
          and o.project_id is null
          and o.deleted_at is null);
$$;

-- İşlem sonunda (deferred) çalışır; böylece aynı işlemde yeni yönetici atanıp
-- eskisi kaldırılabilir. Yalnızca yönetici olmuş bir kullanıcıya dokunan ve
-- sonunda hiç etkin yönetici bırakmayan değişiklik reddedilir; ilk kurulumda
-- (henüz yönetici yokken) devreye girmez.
create or replace function private.tg_keep_last_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row  jsonb;
  v_user uuid;
begin
  if tg_op = 'DELETE' then
    v_row := to_jsonb(old);
  else
    v_row := to_jsonb(new);
  end if;
  v_user := coalesce(v_row ->> 'user_id', v_row ->> 'id')::uuid;

  -- İlgili değişiklik: kullanıcının (silinmiş olsa da) bir sistem rolü ataması
  -- var ya da silinen satırın kendisi sistem rolü ataması.
  if (exists (select 1
                from public.user_roles ur
                join public.roles r on r.id = ur.role_id and r.is_system
               where ur.user_id = v_user)
      or exists (select 1 from public.roles r
                  where r.id = (v_row ->> 'role_id')::uuid and r.is_system))
     and private.effective_admin_count() = 0 then
    raise exception 'Son etkin yönetici kaldırılamaz; önce başka bir yönetici atayın'
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

create constraint trigger keep_last_admin
  after update or delete on public.user_roles
  deferrable initially deferred
  for each row execute function private.tg_keep_last_admin();

create constraint trigger keep_last_admin
  after update or delete on public.profiles
  deferrable initially deferred
  for each row execute function private.tg_keep_last_admin();

create constraint trigger keep_last_admin
  after insert or update on public.user_permission_overrides
  deferrable initially deferred
  for each row execute function private.tg_keep_last_admin();

-- -----------------------------------------------------------------------------
-- Koruma trigger'ları
-- -----------------------------------------------------------------------------

-- Profilde aktiflik ve e-posta yalnızca kullanıcı yöneticisi tarafından
-- değiştirilebilir. auth.uid() boşsa (sunucu/migration) serbesttir.
create or replace function private.tg_guard_profile()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and (new.is_active is distinct from old.is_active or new.email is distinct from old.email)
     and not private.has_permission('kullanici.manage') then
    raise exception 'Bu alanı değiştirme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger guard_profile before update on public.profiles
  for each row execute function private.tg_guard_profile();

-- Projeyi silmek (deleted_at) ayrı bir izindir.
create or replace function private.tg_guard_project_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is not null
     and new.deleted_at is distinct from old.deleted_at
     and not private.has_permission('proje.delete', old.id) then
    raise exception 'Proje silme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger guard_project_delete before update on public.projects
  for each row execute function private.tg_guard_project_delete();

-- -----------------------------------------------------------------------------
-- API ayrıcalıkları. Fonksiyon olarak tutulur, çünkü yedekten geri yüklemede
-- hedef veritabanının varsayılan ayrıcalıkları anon'a yeniden yetki verir;
-- geri yükleme betiği bu fonksiyonu tekrar çalıştırır ve sonucu yedek anındaki
-- ayrıcalık listesiyle karşılaştırır. Yeni bir tabloya özel kısıtlama eklenirse
-- bu fonksiyona da eklenmelidir (karşılaştırma eksikliği yakalar).
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
  -- Profil yalnızca Auth trigger'ı ile oluşur. E-posta ve telefon doğrudan
  -- okunamaz: kişi kendi bilgisini my_profile(), kullanıcı yöneticisi herkesinkini
  -- user_directory() ile görür. Tablo düzeyindeki yetki kaldırılıp yalnızca
  -- hassas olmayan sütunlar açılır.
  revoke select, insert, update on public.profiles from authenticated;
  grant select (id, full_name, is_active, created_at, created_by, updated_at, updated_by, version)
    on public.profiles to authenticated;
  grant update (full_name, phone, is_active) on public.profiles to authenticated;
end;
$$;

revoke execute on function private.harden_api_privileges() from public, anon, authenticated;

-- Yedekten geri yüklemeden sonra bir kez çalıştırılır (scripts/backup/restore-verify.sh).
create or replace function private.post_restore()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform private.install_auth_hooks();
  perform private.harden_api_privileges();
end;
$$;

revoke execute on function private.post_restore() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- RLS: public şemasındaki her tabloda zorunlu (testler denetler).
-- Yumuşak silinmiş satırlar politikada gizlenmez; istemci deleted_at is null
-- filtresi uygular. (Gizlemek, silme güncellemesinin dönüşünü bozardı.)
-- -----------------------------------------------------------------------------
alter table public.profiles                  enable row level security;
alter table public.permissions               enable row level security;
alter table public.roles                     enable row level security;
alter table public.role_permissions          enable row level security;
alter table public.user_roles                enable row level security;
alter table public.user_permission_overrides enable row level security;
alter table public.projects                  enable row level security;
alter table public.project_members           enable row level security;
alter table public.cost_centers              enable row level security;

-- profiles
create policy profiles_select on public.profiles
  for select to authenticated
  using (private.can_see_profile(id));
create policy profiles_update on public.profiles
  for update to authenticated
  using (id = (select auth.uid()) or private.has_permission('kullanici.manage'))
  with check (id = (select auth.uid()) or private.has_permission('kullanici.manage'));

-- permissions (salt okunur katalog)
create policy permissions_select on public.permissions
  for select to authenticated
  using (private.is_active_user());

-- roles, role_permissions
create policy roles_select on public.roles
  for select to authenticated
  using (private.is_active_user());
create policy roles_insert on public.roles
  for insert to authenticated
  with check (private.has_permission('kullanici.manage'));
create policy roles_update on public.roles
  for update to authenticated
  using (private.has_permission('kullanici.manage'))
  with check (private.has_permission('kullanici.manage'));

create policy role_permissions_select on public.role_permissions
  for select to authenticated
  using (private.is_active_user());
create policy role_permissions_insert on public.role_permissions
  for insert to authenticated
  with check (private.has_permission('kullanici.manage'));
create policy role_permissions_update on public.role_permissions
  for update to authenticated
  using (private.has_permission('kullanici.manage'))
  with check (private.has_permission('kullanici.manage'));

-- user_roles, user_permission_overrides: kişi kendi atamalarını görür
create policy user_roles_select on public.user_roles
  for select to authenticated
  using (user_id = (select auth.uid()) or private.has_permission('kullanici.manage'));
create policy user_roles_insert on public.user_roles
  for insert to authenticated
  with check (private.has_permission('kullanici.manage'));
create policy user_roles_update on public.user_roles
  for update to authenticated
  using (private.has_permission('kullanici.manage'))
  with check (private.has_permission('kullanici.manage'));

create policy overrides_select on public.user_permission_overrides
  for select to authenticated
  using (user_id = (select auth.uid()) or private.has_permission('kullanici.manage'));
create policy overrides_insert on public.user_permission_overrides
  for insert to authenticated
  with check (private.has_permission('kullanici.manage'));
create policy overrides_update on public.user_permission_overrides
  for update to authenticated
  using (private.has_permission('kullanici.manage'))
  with check (private.has_permission('kullanici.manage'));

-- projects
create policy projects_select on public.projects
  for select to authenticated
  using (private.has_permission('proje.read', id));
create policy projects_insert on public.projects
  for insert to authenticated
  with check (private.has_permission('proje.create'));
create policy projects_update on public.projects
  for update to authenticated
  using (private.has_permission('proje.write', id))
  with check (private.has_permission('proje.write', id));

-- project_members: projeyi görebilen ekibini de görür; yalnızca kullanıcı
-- yöneticisi atar (proje içinden yetki yükseltmeyi önler).
create policy project_members_select on public.project_members
  for select to authenticated
  using (user_id = (select auth.uid())
         or private.has_permission('kullanici.manage')
         or private.has_permission('proje.read', project_id));
create policy project_members_insert on public.project_members
  for insert to authenticated
  with check (private.has_permission('kullanici.manage'));
create policy project_members_update on public.project_members
  for update to authenticated
  using (private.has_permission('kullanici.manage'))
  with check (private.has_permission('kullanici.manage'));

-- cost_centers
create policy cost_centers_select on public.cost_centers
  for select to authenticated
  using (private.is_active_user());
create policy cost_centers_insert on public.cost_centers
  for insert to authenticated
  with check (private.has_permission('masraf_merkezi.manage'));
create policy cost_centers_update on public.cost_centers
  for update to authenticated
  using (private.has_permission('masraf_merkezi.manage'))
  with check (private.has_permission('masraf_merkezi.manage'));

-- -----------------------------------------------------------------------------
-- RPC'ler (iOS uygulaması ve Edge Function'lar için)
-- -----------------------------------------------------------------------------

-- Oturumdaki kullanıcının etkin izinleri. project_id boş satırlar genel
-- izinlerdir; dolu satırlar o projede geçerli izinlerdir. Menüler buna göre
-- gösterilir; asıl engel her zaman RLS'tir.
create or replace function public.my_permissions()
returns table (project_id uuid, permission_key text)
language sql
stable
security definer
set search_path = ''
as $$
  select null::uuid, p.key
    from public.permissions p
   where private.has_permission(p.key, null)
  union all
  select pr.id, p.key
    from public.projects pr
   cross join public.permissions p
   where pr.deleted_at is null
     and private.has_permission(p.key, pr.id);
$$;

-- Bir kaydın işlem geçmişi (audit.read izni gerekir).
create or replace function public.record_history(p_table text, p_record_id text)
returns table (
  occurred_at    timestamptz,
  actor_id       uuid,
  actor_name     text,
  action         text,
  changed_fields text[],
  old_data       jsonb,
  new_data       jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.has_permission('audit.read') then
    raise exception 'İşlem geçmişini görüntüleme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  return query
    select l.occurred_at, l.actor_id, pf.full_name, l.action, l.changed_fields, l.old_data, l.new_data
      from audit.log l
      left join public.profiles pf on pf.id = l.actor_id
     where l.table_schema = 'public'
       and l.table_name = p_table
       and l.record_id = p_record_id
     order by l.occurred_at desc, l.id desc;
end;
$$;

-- Oturumdaki kullanıcının kendi profili (e-posta ve telefon dahil).
create or replace function public.my_profile()
returns table (id uuid, email text, full_name text, phone text, is_active boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.email, p.full_name, p.phone, p.is_active
    from public.profiles p
   where p.id = (select auth.uid());
$$;

-- Kullanıcı yönetimi ekranı için tüm kullanıcılar ve iletişim bilgileri.
create or replace function public.user_directory()
returns table (id uuid, email text, full_name text, phone text, is_active boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.has_permission('kullanici.manage') then
    raise exception 'Kullanıcı listesini görüntüleme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  return query
    select p.id, p.email, p.full_name, p.phone, p.is_active
      from public.profiles p
     order by p.full_name, p.email;
end;
$$;

grant execute on function public.my_permissions() to authenticated;
grant execute on function public.record_history(text, text) to authenticated;
grant execute on function public.my_profile() to authenticated;
grant execute on function public.user_directory() to authenticated;

-- -----------------------------------------------------------------------------
-- İlk yönetici: kayıt kapalı olduğu için ilk kullanıcı Supabase panelinden
-- davet edilir, ardından SQL Editor'da bir kez çalıştırılır:
--   select private.bootstrap_admin('ad.soyad@rdinsaat.com');
-- Aktif bir yönetici varsa reddedilir. API'den çağrılamaz.
-- -----------------------------------------------------------------------------
create or replace function private.bootstrap_admin(p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_role uuid;
begin
  select r.id into v_role from public.roles r
   where r.key = 'yonetici' and r.is_system and r.deleted_at is null;

  if exists (select 1
               from public.user_roles ur
               join public.profiles p on p.id = ur.user_id and p.is_active
              where ur.role_id = v_role and ur.deleted_at is null) then
    raise exception 'Aktif bir yönetici zaten var; atamayı uygulama üzerinden yapın';
  end if;

  select p.id into v_user from public.profiles p where lower(p.email) = lower(p_email);
  if v_user is null then
    raise exception 'Bu e-postayla kullanıcı bulunamadı: %', p_email;
  end if;

  update public.profiles set is_active = true where id = v_user;
  insert into public.user_roles (user_id, role_id) values (v_user, v_role);
  return v_user;
end;
$$;

revoke execute on function private.bootstrap_admin(text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- İzin kataloğu (Aşama 0). Sonraki aşamalar kendi izinlerini kendi
-- migration'larında ekler.
-- -----------------------------------------------------------------------------
insert into public.permissions (key, module, description) values
  ('kullanici.manage',      'kullanici',      'Kullanıcı, rol, özel izin ve proje üyeliği yönetimi'),
  ('audit.read',            'audit',          'İşlem geçmişini görüntüleme'),
  ('proje.read',            'proje',          'Projeyi görüntüleme'),
  ('proje.write',           'proje',          'Proje bilgilerini düzenleme'),
  ('proje.create',          'proje',          'Yeni proje oluşturma'),
  ('proje.delete',          'proje',          'Projeyi silme (yumuşak silme)'),
  ('masraf_merkezi.manage', 'masraf_merkezi', 'Genel masraf merkezlerini yönetme');

-- -----------------------------------------------------------------------------
-- Başlangıç rol şablonları (yönetici panelinden kopyalanıp düzenlenebilir).
-- yonetici: sistem rolü, tüm izinler; silinemez.
-- -----------------------------------------------------------------------------
insert into public.roles (key, name, description, scope, is_template, is_system) values
  ('yonetici',      'Yönetici',           'Tüm izinler; silinemez',                          'global',  true, true),
  ('muhasebe',      'Muhasebe sorumlusu', 'Tüm projelerde finans; proje bilgisini okur',     'global',  true, false),
  ('santiye_sefi',  'Şantiye şefi',       'Üye olduğu projede saha işleri',                  'project', true, false),
  ('goruntuleyici', 'Görüntüleyici',      'Üye olduğu projeyi yalnızca görüntüler',          'project', true, false);

insert into public.role_permissions (role_id, permission_key)
select r.id, x.permission_key
  from (values
          ('muhasebe',      'proje.read'),
          ('santiye_sefi',  'proje.read'),
          ('santiye_sefi',  'proje.write'),
          ('goruntuleyici', 'proje.read')
       ) as x (role_key, permission_key)
  join public.roles r on r.key = x.role_key;

-- Ayrıcalıkları uygula (en sonda: yukarıdaki tüm tablo ve fonksiyonlar dahil).
select private.harden_api_privileges();
