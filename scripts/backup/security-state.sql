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
   and table_name in ('profiles', 'purchase_order_lines')
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
union all
-- Belge dosyaları: storage.objects politikaları (şema dökümüne girmez;
-- post_restore() yeniden kurar) ve bucket'ların herkese açık olmaması.
select 'storage-policy:' || p.polname || ':' || p.polcmd::text || ':' || coalesce(pg_get_expr(p.polqual, p.polrelid)::text, '')
       || ':' || coalesce(pg_get_expr(p.polwithcheck, p.polrelid)::text, '')
  from pg_policy p
 where p.polrelid = 'storage.objects'::regclass
union all
select 'bucket:' || b.id || ':public=' || b.public::text || ':limit=' || coalesce(b.file_size_limit::text, '')
       || ':types=' || coalesce(array_to_string(b.allowed_mime_types, ','), '')
  from storage.buckets b
 order by 1;
