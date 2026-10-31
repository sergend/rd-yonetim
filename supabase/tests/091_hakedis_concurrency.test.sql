-- Hakediş, ödeme ve teminat: iki ayrı oturumla eşzamanlılık. İkinci oturum
-- dblink ile açılır; yalnızca işlenmiş veriyi gördüğü için seed'deki demo
-- DEMO-S-001 sözleşmesi kullanılır (Eylül hakedişi onaylı ve deftere işlenmiş,
-- Ekim hakedişi incelemede). Hiçbir oturum commit etmez; veri değişmeden kalır.
--
-- Bütün finansal işlemler önce sözleşme satırını kilitler. İkinci işlem,
-- birincisi bitmeden kontrollerini yapamaz; bu yüzden aynı hakediş iki kez
-- onaylanamaz, aynı hakedişe toplamı aşan iki ödeme veya teminat bakiyesini
-- aşan iki serbest bırakma birlikte işlenemez.
begin;
select plan(10);

create extension if not exists dblink with schema extensions;

create temp table seed_ctx on commit drop as
select '00000000-0000-4000-8000-000000000001'::uuid as admin_id,
       '00000000-0000-4000-8000-0000000000c1'::uuid as contract_id,
       '00000000-0000-4000-8000-0000000000e2'::uuid as posted_id,
       '00000000-0000-4000-8000-0000000000e3'::uuid as review_id,
       '00000000-0000-4000-8000-0000000000f1'::uuid as source_id;
grant select on seed_ctx to authenticated;

select results_eq(
  $$ select h.status::text, h.posted_at is not null from public.hakedis h join seed_ctx s on h.id in (s.posted_id, s.review_id)
      order by h.hakedis_no $$,
  $$ values ('onaylandi', true), ('incelemede', false) $$,
  'seed: Eylül hakedişi onaylı ve deftere işlenmiş, Ekim hakedişi incelemede');

select extensions.dblink_connect('ikinci',
  format('host=%s port=%s user=postgres password=postgres dbname=postgres',
         host(inet_server_addr()), inet_server_port()));

create function pg_temp.remote(p_sql text) returns text language sql
  as $$ select extensions.dblink_exec('ikinci', p_sql) $$;
create function pg_temp.remote_value(p_sql text) returns text language sql
  as $$ select v from extensions.dblink('ikinci', p_sql) as t (v text) $$;
create function pg_temp.as_admin_sql() returns text language sql stable
  as $$ select format($f$ set local request.jwt.claims = %L; set local role authenticated $f$,
                      json_build_object('sub', admin_id, 'role', 'authenticated')::text) from seed_ctx $$;

-- 1. Aynı hakedişin eşzamanlı onayı.
select pg_temp.remote('begin');
select pg_temp.remote(pg_temp.as_admin_sql());
select is(
  pg_temp.remote_value(format($f$ select (public.hakedis_transition(%L, 'onayla')).status::text $f$,
                              (select review_id from seed_ctx))),
  'onaylandi', 'ikinci oturum Ekim hakedişini onaylar (commit etmeden)');
select tests.authenticate_as((select admin_id from seed_ctx));
set local lock_timeout = '300ms';
select throws_ok(
  format($$ select public.hakedis_transition(%L, 'onayla') $$, (select review_id from seed_ctx)),
  '55P03', null, 'aynı anda ikinci onay sözleşme kilidini bekler; iki onay birlikte işlenemez');
select tests.clear_authentication();
select pg_temp.remote('rollback');

-- 2. Aynı hakedişe eşzamanlı ödeme: kalan 80.800 TL.
select pg_temp.remote('begin');
select pg_temp.remote(pg_temp.as_admin_sql());
select is(
  pg_temp.remote_value(format(
    $f$ select (public.record_finance_payment(gen_random_uuid(), %L, 'odeme', 80800, %L,
                 '2026-10-30', p_hakedis_id => %L)).amount::text $f$,
    (select contract_id from seed_ctx), (select source_id from seed_ctx), (select posted_id from seed_ctx))),
  '80800.00', 'ikinci oturum kalan 80.800 TL''yi öder (commit etmeden)');
select tests.authenticate_as((select admin_id from seed_ctx));
set local lock_timeout = '300ms';
select throws_ok(
  format($$ select public.record_finance_payment(gen_random_uuid(), %L, 'odeme', 80800, %L, '2026-10-30',
                                                  p_hakedis_id => %L) $$,
         (select contract_id from seed_ctx), (select source_id from seed_ctx), (select posted_id from seed_ctx)),
  '55P03', null, 'aynı anda ikinci ödeme kilidi bekler; mükerrer ödeme oluşmaz');
select tests.clear_authentication();
select pg_temp.remote('rollback');

-- 3. Eşzamanlı teminat serbest bırakma: birikmiş 31.200 TL.
select pg_temp.remote('begin');
select pg_temp.remote(pg_temp.as_admin_sql());
select is(
  pg_temp.remote_value(format(
    $f$ select (public.release_teminat(gen_random_uuid(), %L, 31200, 'Kesin kabul yapıldı (demo)', '2026-10-30')).amount::text $f$,
    (select contract_id from seed_ctx))),
  '31200.00', 'ikinci oturum teminatın tamamını serbest bırakır (commit etmeden)');
select tests.authenticate_as((select admin_id from seed_ctx));
set local lock_timeout = '300ms';
select throws_ok(
  format($$ select public.release_teminat(gen_random_uuid(), %L, 31200, 'Kesin kabul yapıldı (demo)', '2026-10-30') $$,
         (select contract_id from seed_ctx)),
  '55P03', null, 'aynı anda ikinci serbest bırakma kilidi bekler; teminat iki kez iade edilmez');
select tests.clear_authentication();
select pg_temp.remote('rollback');
select extensions.dblink_disconnect('ikinci');

select is(
  (select count(*)::int from public.teminat_releases r join seed_ctx s on s.contract_id = r.contract_id), 0,
  'ikinci oturumun işlemleri geri alındı');

-- Sıralı durumda (ikinci oturum kapandıktan sonra; bu oturum kilidi işlem sonuna dek tutar): birinci ödeme kalanı kapatır, ikinci ödeme reddedilir.
select tests.authenticate_as((select admin_id from seed_ctx));
set local lock_timeout = '5s';
select lives_ok(
  format($$ select public.record_finance_payment(gen_random_uuid(), %L, 'odeme', 80800, %L, '2026-10-30',
                                                  p_hakedis_id => %L) $$,
         (select contract_id from seed_ctx), (select source_id from seed_ctx), (select posted_id from seed_ctx)),
  'kilit bırakılınca ödeme işlenir');
select throws_ok(
  format($$ select public.record_finance_payment(gen_random_uuid(), %L, 'odeme', 1, %L, '2026-10-30',
                                                  p_hakedis_id => %L) $$,
         (select contract_id from seed_ctx), (select source_id from seed_ctx), (select posted_id from seed_ctx)),
  '23514', null, 'ödemeye uygun tutarı aşan ödeme hakedişe eşleştirilemez');
select tests.clear_authentication();

select * from finish();
rollback;
