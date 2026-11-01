-- Stok çıkışı ve teslim alma: iki ayrı oturumla eşzamanlılık. İkinci oturum
-- dblink ile açılır ve yalnızca işlenmiş veriyi görür; bu yüzden seed'deki
-- demo stok kullanılır (Sivas ana deposunda 110 plywood; SA-000002'de 7 ton
-- demir teslim bekliyor). Hiçbir oturum commit etmez.
--
-- Çıkış, (depo, malzeme) kilidini alıp toplamı kilitten sonra yeniden okur:
-- ikinci işlem birincisi bitmeden stoka işleyemez, toplamı aşan iki çıkış
-- birlikte işlenemez. Teslim alma sipariş satırını kilitler.
begin;
select plan(10);

create extension if not exists dblink with schema extensions;

create temp table seed_ctx on commit drop as
select '00000000-0000-4000-8000-000000000001'::uuid as admin_id,
       (select id from public.warehouses where is_default
           and project_id = (select id from public.projects where code = 'DEMO-SVS')) as w_svs,
       (select id from public.warehouses where is_default
           and project_id = (select id from public.projects where code = 'DEMO-01')) as w_d01,
       (select id from public.materials where name = 'Plywood') as plywood,
       '00000000-0000-4000-8000-000000000302'::uuid as po_demir,
       '00000000-0000-4000-8000-000000000313'::uuid as line_demir;
grant select on seed_ctx to authenticated;

select is((select quantity from public.v_stock_balances b join seed_ctx s on b.warehouse_id = s.w_svs and b.material_id = s.plywood),
          110.000::numeric, 'seed: Sivas deposunda 110 plywood (160 − 40 − 10)');

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

-- 1. Aynı depodan eşzamanlı iki kullanım (toplam 200 > 110).
select pg_temp.remote('begin');
select pg_temp.remote(pg_temp.as_sql((select admin_id from seed_ctx)));
select is(
  pg_temp.remote_value(format($f$ select (public.create_stock_movement(gen_random_uuid(), 'kullanim', %L, %L, 100)).status::text $f$,
                              (select plywood from seed_ctx), (select w_svs from seed_ctx))),
  'onaylandi', 'ikinci oturum 100 plywood kullanır (commit etmeden)');
select tests.authenticate_as((select admin_id from seed_ctx));
set local lock_timeout = '300ms';
select throws_ok(
  format($$ select public.create_stock_movement(gen_random_uuid(), 'kullanim', %L, %L, 100) $$,
         (select plywood from seed_ctx), (select w_svs from seed_ctx)),
  '55P03', null, 'eşzamanlı ikinci çıkış stok kilidini bekler; iki çıkış birlikte işlenmez');
select tests.clear_authentication();
select pg_temp.remote('rollback');

-- 2. Transfer sürerken kullanım.
select pg_temp.remote('begin');
select pg_temp.remote(pg_temp.as_sql((select admin_id from seed_ctx)));
select is(
  pg_temp.remote_value(format($f$ select (public.create_stock_movement(gen_random_uuid(), 'transfer', %L, %L, 110,
                                    p_target_warehouse_id => %L)).status::text $f$,
                              (select plywood from seed_ctx), (select w_svs from seed_ctx), (select w_d01 from seed_ctx))),
  'onaylandi', 'ikinci oturum 110 plywoodu aktarır (commit etmeden)');
select tests.authenticate_as((select admin_id from seed_ctx));
select throws_ok(
  format($$ select public.create_stock_movement(gen_random_uuid(), 'kullanim', %L, %L, 1) $$,
         (select plywood from seed_ctx), (select w_svs from seed_ctx)),
  '55P03', null, 'transfer bitmeden aynı stoktan kullanım işlenmez');
select tests.clear_authentication();
select pg_temp.remote('rollback');

-- 3. Aynı sipariş satırına eşzamanlı iki teslim (kalan 7 ton).
select pg_temp.remote('begin');
select pg_temp.remote(pg_temp.as_sql((select admin_id from seed_ctx)));
select is(
  pg_temp.remote_value(format($f$ select (public.receive_purchase_order(gen_random_uuid(), %L,
                                    jsonb_build_array(jsonb_build_object('order_line_id', %L, 'quantity', 7)))).status $f$,
                              (select po_demir from seed_ctx), (select line_demir from seed_ctx))),
  'aktif', 'ikinci oturum kalan 7 tonu teslim alır (commit etmeden)');
select tests.authenticate_as((select admin_id from seed_ctx));
select throws_ok(
  format($$ select public.receive_purchase_order(gen_random_uuid(), %L,
              jsonb_build_array(jsonb_build_object('order_line_id', %L, 'quantity', 7))) $$,
         (select po_demir from seed_ctx), (select line_demir from seed_ctx)),
  '55P03', null, 'eşzamanlı ikinci teslim sipariş kilidini bekler; fazla teslim oluşmaz');
select tests.clear_authentication();
select pg_temp.remote('rollback');
select extensions.dblink_disconnect('ikinci');
reset lock_timeout;

-- 4. Sıralı iki çıkış: ikincisi birincinin sonucunu görür.
select tests.authenticate_as((select admin_id from seed_ctx));
select lives_ok(
  format($$ select public.create_stock_movement(gen_random_uuid(), 'kullanim', %L, %L, 100) $$,
         (select plywood from seed_ctx), (select w_svs from seed_ctx)),
  'ilk 100 plywood kullanımı');
select throws_ok(
  format($$ select public.create_stock_movement(gen_random_uuid(), 'kullanim', %L, %L, 20) $$,
         (select plywood from seed_ctx), (select w_svs from seed_ctx)),
  '23514', null, 'ikinci 20 adet kalan 10''u aşar ve reddedilir');
select is((select quantity from public.v_stock_balances b join seed_ctx s on b.warehouse_id = s.w_svs and b.material_id = s.plywood),
          10.000::numeric, 'stok tutarlı: 10 plywood, negatif yok');
select tests.clear_authentication();

select * from finish();
rollback;
