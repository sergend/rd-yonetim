-- Test yardımcıları. Bu dosya bilerek COMMIT eder: sonraki test dosyaları
-- (her biri kendi işleminde çalışıp ROLLBACK eder) bu fonksiyonları kullanır.
-- Yalnızca yerel/CI test veritabanında çalışır; canlıya hiçbir zaman uygulanmaz.
begin;

create extension if not exists pgtap with schema extensions;
create schema if not exists tests;
grant usage on schema tests to authenticated;

-- Sahte bir Auth kullanıcısı oluşturur (profil trigger'la açılır).
create or replace function tests.create_user(p_email text, p_full_name text default null)
returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          p_email, jsonb_build_object('full_name', coalesce(p_full_name, p_email)), now(), now());
  return v_id;
end;
$$;

-- Sonraki sorguları bu kullanıcının JWT'siyle (authenticated rolü) çalıştırır.
create or replace function tests.authenticate_as(p_user uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end;
$$;

-- postgres rolüne geri döner (test verisi hazırlamak için).
create or replace function tests.clear_authentication()
returns void
language plpgsql
as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end;
$$;

create or replace function tests.grant_global_role(p_user uuid, p_role_key text)
returns void
language sql
as $$
  insert into public.user_roles (user_id, role_id)
  select p_user, r.id from public.roles r where r.key = p_role_key and r.deleted_at is null;
$$;

create or replace function tests.add_member(p_project uuid, p_user uuid, p_role_key text,
                                            p_from date default null, p_to date default null)
returns void
language sql
as $$
  insert into public.project_members (project_id, user_id, role_id, valid_from, valid_to)
  select p_project, p_user, r.id, coalesce(p_from, private.today()), p_to
    from public.roles r where r.key = p_role_key and r.deleted_at is null;
$$;

create or replace function tests.create_project(p_code text)
returns uuid
language sql
as $$
  insert into public.projects (code, name) values (p_code, p_code || ' test projesi') returning id;
$$;

grant execute on all functions in schema tests to authenticated;

select plan(1);
select has_schema('tests', 'test yardımcı şeması hazır');
select * from finish();

commit;
