-- Gider ödemesi ve onayı: iki ayrı oturumla eşzamanlılık. İkinci oturum dblink
-- ile açılır ve yalnızca işlenmiş veriyi görür; bu yüzden seed'deki demo
-- belgeler kullanılır (GD-000004 onaylı ve ödenmemiş 12.500; GD-000003
-- taslak). Hiçbir oturum commit etmez.
--
-- Ödeme, onay ve iptal önce belge satırını kilitler: ikinci işlem birincisi
-- bitmeden kalan tutarı veya durumu okuyamaz; böylece toplamı aşan iki ödeme,
-- iki onay (iki cari kayıt) veya ödeme ile iptal birlikte işlenemez.
begin;
select plan(9);

create extension if not exists dblink with schema extensions;

create temp table seed_ctx on commit drop as
select '00000000-0000-4000-8000-000000000001'::uuid as admin_id,
       '00000000-0000-4000-8000-000000000003'::uuid as muhasebe_id,
       '00000000-0000-4000-8000-000000000104'::uuid as open_doc,
       '00000000-0000-4000-8000-000000000103'::uuid as draft_doc,
       '00000000-0000-4000-8000-0000000000f1'::uuid as source_id;
grant select on seed_ctx to authenticated;

select results_eq(
  $$ select v.status::text, v.remaining_amount from public.v_finance_document_status v join seed_ctx s
       on v.document_id in (s.open_doc, s.draft_doc) order by v.status $$,
  $$ values ('taslak', 0::numeric), ('onaylandi', 12500.00::numeric) $$,
  'seed: nakliye gideri onaylı ve ödenmemiş (12.500), ofis gideri taslak');

select extensions.dblink_connect('ikinci',
  format('host=%s port=%s user=postgres password=postgres dbname=postgres',
         host(inet_server_addr()), inet_server_port()));
create function pg_temp.remote(p_sql text) returns text language sql
  as $$ select extensions.dblink_exec('ikinci', p_sql) $$;
create function pg_temp.remote_value(p_sql text) returns text language sql
  as $$ select v from extensions.dblink('ikinci', p_sql) as t (v text) $$;
create function pg_temp.as_sql(p_user uuid) returns text language sql stable
  as $$ select format($f$ set local request.jwt.claims = %L; set local role authenticated $f$,
                      json_build_object('sub', p_user, 'role', 'authenticated')::text) $$;

-- 1. Aynı borca eşzamanlı iki ödeme (toplam kalanı aşar).
select pg_temp.remote('begin');
select pg_temp.remote(pg_temp.as_sql((select muhasebe_id from seed_ctx)));
select is(
  pg_temp.remote_value(format($f$ select (public.record_finance_settlement(gen_random_uuid(), %L, 12500, %L, '2026-10-30')).amount::text $f$,
                              (select open_doc from seed_ctx), (select source_id from seed_ctx))),
  '12500.00', 'ikinci oturum kalanın tamamını öder (commit etmeden)');
select tests.authenticate_as((select muhasebe_id from seed_ctx));
set local lock_timeout = '300ms';
select throws_ok(
  format($$ select public.record_finance_settlement(gen_random_uuid(), %L, 12500, %L, '2026-10-30') $$,
         (select open_doc from seed_ctx), (select source_id from seed_ctx)),
  '55P03', null, 'eşzamanlı ikinci ödeme belge kilidini bekler; çift ödeme oluşmaz');
select tests.clear_authentication();
select pg_temp.remote('rollback');

-- 2. Aynı taslağın eşzamanlı onayı (iki yükümlülük oluşamaz).
select pg_temp.remote('begin');
select pg_temp.remote(pg_temp.as_sql((select admin_id from seed_ctx)));
select is(
  pg_temp.remote_value(format($f$ select (public.approve_finance_document(%L)).status::text $f$, (select draft_doc from seed_ctx))),
  'onaylandi', 'ikinci oturum taslağı onaylar (commit etmeden)');
select tests.authenticate_as((select admin_id from seed_ctx));
select throws_ok(format($$ select public.approve_finance_document(%L) $$, (select draft_doc from seed_ctx)),
  '55P03', null, 'eşzamanlı ikinci onay kilidi bekler');
select tests.clear_authentication();
select pg_temp.remote('rollback');

-- 3. Ödeme sürerken iptal.
select pg_temp.remote('begin');
select pg_temp.remote(pg_temp.as_sql((select muhasebe_id from seed_ctx)));
select is(
  pg_temp.remote_value(format($f$ select (public.record_finance_settlement(gen_random_uuid(), %L, 1000, %L, '2026-10-30')).status $f$,
                              (select open_doc from seed_ctx), (select source_id from seed_ctx))),
  'aktif', 'ikinci oturum kısmi ödeme kaydeder (commit etmeden)');
select tests.authenticate_as((select admin_id from seed_ctx));
select throws_ok(format($$ select public.cancel_finance_document(%L, 'Eşzamanlı iptal denemesi') $$, (select open_doc from seed_ctx)),
  '55P03', null, 'ödeme sürerken belge iptal edilemez (kilidi bekler)');
select tests.clear_authentication();
select pg_temp.remote('rollback');
select extensions.dblink_disconnect('ikinci');
reset lock_timeout;

-- 4. Sıralı iki ödeme: ikincisi birincinin sonucunu görür.
select tests.authenticate_as((select muhasebe_id from seed_ctx));
select lives_ok(
  format($$ select public.record_finance_settlement(gen_random_uuid(), %L, 7000, %L, '2026-10-30') $$,
         (select open_doc from seed_ctx), (select source_id from seed_ctx)),
  'ilk 7.000 ödeme');
select throws_ok(
  format($$ select public.record_finance_settlement(gen_random_uuid(), %L, 7000, %L, '2026-10-30') $$,
         (select open_doc from seed_ctx), (select source_id from seed_ctx)),
  '23514', null, 'ikinci 7.000 kalan 5.500''ü aşar ve reddedilir');

select * from finish();
rollback;
