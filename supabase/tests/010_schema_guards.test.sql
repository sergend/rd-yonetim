-- Yapısal güvenlik kuralları: her yeni tabloda otomatik denetlenir.
begin;
select plan(9);

select is_empty(
  $$ select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity $$,
  'public şemasındaki her tabloda RLS açık');

select is_empty(
  $$ select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r'
        and not exists (select 1 from pg_trigger t
                         where t.tgrelid = c.oid and t.tgname = 'zz_audit_row') $$,
  'public şemasındaki her tablo işlem geçmişine bağlı');

select is_empty(
  $$ select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r'
        and not exists (select 1 from pg_trigger t
                         where t.tgrelid = c.oid and t.tgname = 'aa_row_meta') $$,
  'public şemasındaki her tabloda ortak satır alanları trigger''ı var');

select is_empty(
  $$ select table_name, privilege_type from information_schema.role_table_grants
      where table_schema = 'public' and grantee = 'anon' $$,
  'anon rolünün hiçbir tabloda yetkisi yok');

select is_empty(
  $$ select table_name, privilege_type from information_schema.role_table_grants
      where table_schema = 'public' and grantee = 'authenticated'
        and privilege_type in ('DELETE', 'TRUNCATE', 'TRIGGER', 'REFERENCES') $$,
  'authenticated fiziksel silme ve truncate yapamaz');

select is_empty(
  $$ select n.nspname || '.' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'private', 'audit')
        and has_function_privilege('anon', p.oid, 'execute') $$,
  'anon hiçbir fonksiyonu çalıştıramaz');

select ok(
  not has_function_privilege('authenticated', 'private.bootstrap_admin(text)', 'execute'),
  'ilk yönetici fonksiyonu API''den çağrılamaz');

select ok(
  not has_table_privilege('authenticated', 'audit.log', 'select'),
  'authenticated audit.log tablosunu doğrudan okuyamaz');

select ok(
  not has_table_privilege('authenticated', 'public.permissions', 'insert'),
  'izin kataloğu uygulamadan değiştirilemez');

select * from finish();
rollback;
