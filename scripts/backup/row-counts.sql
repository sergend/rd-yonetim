-- Yedek doğrulaması için tablo başına satır sayıları (tablo=sayı, sıralı).
select t.table_schema || '.' || t.table_name || '=' ||
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from %I.%I', t.table_schema, t.table_name),
                           false, true, '')))[1]::text
  from information_schema.tables t
 where t.table_type = 'BASE TABLE'
   and (t.table_schema in ('public', 'audit')
        or (t.table_schema = 'auth' and t.table_name in ('users', 'identities'))
        or (t.table_schema = 'storage' and t.table_name in ('buckets', 'objects')))
 order by 1;
