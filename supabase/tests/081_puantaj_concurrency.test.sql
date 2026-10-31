-- Puantaj: iki ayrı oturumla eşzamanlılık. İkinci oturum dblink ile açılır;
-- yalnızca işlenmiş (commit edilmiş) veriyi gördüğü için seed'deki demo Sivas
-- puantajı kullanılır. Hiçbir oturum commit etmez; veri değişmeden kalır.
--
-- Senaryolar:
--   1. Ay onayı (puantaj_transition) sürerken fazla mesai onayı dönem
--      kilidini bekler; araya giremez.
--   2. Fazla mesai onayı sürerken ay onayı dönem kilidini bekler; snapshot,
--      işlenmemiş bir fazla mesai onayıyla alınamaz.
begin;
select plan(6);

create extension if not exists dblink with schema extensions;

create temp table seed_ctx on commit drop as
select e.id as entry_id, e.project_id, date_trunc('month', e.work_date)::date as month,
       '00000000-0000-4000-8000-000000000001'::uuid as admin_id
  from public.puantaj_entries e
 where e.is_demo and e.overtime_hours > 0 and e.overtime_approved_at is null and e.deleted_at is null
 order by e.work_date
 limit 1;
grant select on seed_ctx to authenticated;

select is((select count(*)::int from seed_ctx), 1, 'seed verisinde onaysız fazla mesaili demo kayıt var');

-- İkinci oturum. Supabase'te postgres süper kullanıcı değildir; dblink şifre
-- doğrulamasını gerektirdiği için sunucunun ağ adresine bağlanılır.
select extensions.dblink_connect('ikinci',
  format('host=%s port=%s user=postgres password=postgres dbname=postgres',
         host(inet_server_addr()), inet_server_port()));

create function pg_temp.remote(p_sql text) returns text language sql
  as $$ select extensions.dblink_exec('ikinci', p_sql) $$;

create function pg_temp.as_admin_sql() returns text language sql stable
  as $$ select format($f$ set local request.jwt.claims = %L; set local role authenticated $f$,
                      json_build_object('sub', admin_id, 'role', 'authenticated')::text) from seed_ctx $$;

-- 1. İkinci oturum ayı onaylıyor (henüz commit etmedi).
select pg_temp.remote('begin');
select pg_temp.remote(pg_temp.as_admin_sql());
select is(
  (select s from extensions.dblink('ikinci',
     format($f$ select (public.puantaj_transition(%L, %L, 'onayla')).status::text $f$,
            (select project_id from seed_ctx), (select month from seed_ctx))) as t (s text)),
  'onaylandi', 'ikinci oturum ayı onaylar (commit etmeden)');

select tests.authenticate_as((select admin_id from seed_ctx));
set local lock_timeout = '300ms';
select throws_ok(
  $$ select public.approve_puantaj_overtime(array(select entry_id from seed_ctx)) $$,
  '55P03', null, 'ay onayı sürerken fazla mesai onayı dönem kilidini bekler, araya giremez');
select tests.clear_authentication();
select pg_temp.remote('rollback');

-- 2. Bu oturum fazla mesaiyi onaylıyor (commit etmeden); ikinci oturum ayı onaylayamaz.
select tests.authenticate_as((select admin_id from seed_ctx));
set local lock_timeout = '5s';
select is(public.approve_puantaj_overtime(array(select entry_id from seed_ctx)), 1,
  'ay onayı bittikten (geri alındıktan) sonra fazla mesai onaylanır');
select tests.clear_authentication();

select pg_temp.remote('begin');
select pg_temp.remote('set local lock_timeout = ''300ms''');
select pg_temp.remote(pg_temp.as_admin_sql());
select throws_ok(
  format($f$ select pg_temp.remote(%L) $f$,
         format($g$ select public.puantaj_transition(%L, %L, 'onayla') $g$,
                (select project_id from seed_ctx), (select month from seed_ctx))),
  '55P03', null, 'fazla mesai onayı sürerken ay onayı dönem kilidini bekler; snapshot onunla yarışmaz');
select pg_temp.remote('rollback');
select extensions.dblink_disconnect('ikinci');

select is(
  (select status::text from public.puantaj_periods p join seed_ctx c on c.project_id = p.project_id and c.month = p.month),
  'taslak', 'ikinci oturumun işlemleri geri alındı; dönem taslak');

select * from finish();
rollback;
