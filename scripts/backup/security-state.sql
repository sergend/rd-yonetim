-- Yedek doğrulaması için güvenlik durumu (sıralı):
--   API rollerinin tablo, sütun ve fonksiyon ayrıcalıkları, RLS durumu, trigger'lar.
select 'table:' || table_schema || '.' || table_name || ':' || grantee || ':' || privilege_type
  from information_schema.role_table_grants
 where table_schema in ('public', 'audit', 'private')
   and grantee in ('anon', 'authenticated')
union all
select 'function:' || n.nspname || '.' || p.proname || ':' || r.rolname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 cross join (values ('anon'), ('authenticated')) as r (rolname)
 where n.nspname in ('public', 'private', 'audit')
   and has_function_privilege(r.rolname, p.oid, 'execute')
union all
select 'column:' || table_schema || '.' || table_name || '.' || column_name || ':' || grantee || ':' || privilege_type
  from information_schema.column_privileges
 where table_schema = 'public'
   and table_name = 'profiles'
   and grantee in ('anon', 'authenticated')
union all
select 'rls:' || n.nspname || '.' || c.relname || ':' || c.relrowsecurity
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname in ('public', 'audit') and c.relkind = 'r'
union all
select 'trigger:' || n.nspname || '.' || c.relname || ':' || t.tgname
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
 where not t.tgisinternal
   and (n.nspname in ('public', 'audit') or t.tgname = 'on_auth_user_created')
 order by 1;
