-- Avans tavanı (migration 20261103000000): bedeli tanımsız sözleşmede avans
-- reddedilir; bilinen bedelin altı ve tam eşiti kabul, az aşan reddedilir;
-- iptal edilen avans tavandan düşülür; TL tutarlar ve özet tutarlı kalır.
begin;
select plan(12);

create temp table ctx (k text primary key, v uuid) on commit drop;
grant select, insert on ctx to authenticated;
create function pg_temp.c(p_key text) returns uuid language sql stable
  as $$ select v from ctx where k = p_key $$;
create function pg_temp.bf(p_key text) returns jsonb
  language sql stable as $$ select jsonb_build_object('item_key', pg_temp.c(p_key), 'method', 'birim_fiyat',
    'description', 'Test kalemi', 'unit', 'adet', 'quantity', 100, 'unit_price', 1000) $$;
create function pg_temp.avans(p_id text, p_contract text, p_amount numeric) returns text
  language sql as $$ select format($f$ select public.record_finance_payment(%L, %L, 'avans', %s, %L, '2026-09-01') $f$,
    pg_temp.c(p_id), pg_temp.c(p_contract), p_amount, pg_temp.c('src')) $$;

insert into ctx values
  ('admin',    tests.create_user('av-yonetici@test.invalid')),
  ('muhasebe', tests.create_user('av-muhasebe@test.invalid')),
  ('p',        tests.create_project('TEST-AV'));
insert into ctx values ('i1', gen_random_uuid()), ('i2', gen_random_uuid()),
                       ('cNo', gen_random_uuid()), ('cLim', gen_random_uuid()),
                       ('a0', gen_random_uuid()), ('a1', gen_random_uuid()), ('a2', gen_random_uuid()),
                       ('a3', gen_random_uuid()), ('a4', gen_random_uuid()), ('a5', gen_random_uuid());
select tests.grant_global_role(pg_temp.c('admin'),    'yonetici');
select tests.grant_global_role(pg_temp.c('muhasebe'), 'muhasebe');
insert into public.cari_accounts (code, title, type) values ('TEST-AV-C', 'TEST AV Taşeron', 'taseron');
insert into ctx select 'cari', id from public.cari_accounts where code = 'TEST-AV-C';
insert into public.subcontractors (name, cari_account_id) values ('TEST AV Taşeron', pg_temp.c('cari'));
insert into ctx select 'sub', id from public.subcontractors where name = 'TEST AV Taşeron';
insert into public.payment_sources (name, kind) values ('TEST AV Şirket ödemesi', 'sirket');
insert into ctx select 'src', id from public.payment_sources where name = 'TEST AV Şirket ödemesi';

select tests.authenticate_as(pg_temp.c('admin'));
select public.save_contract(pg_temp.c('cNo'), pg_temp.c('p'), pg_temp.c('sub'), 'TEST-AV-1', 'Bedelsiz sözleşme',
                            jsonb_build_array(pg_temp.bf('i1')));
select public.save_contract(pg_temp.c('cLim'), pg_temp.c('p'), pg_temp.c('sub'), 'TEST-AV-2', 'Bedelli sözleşme',
                            jsonb_build_array(pg_temp.bf('i2')), p_total_amount => 100000);
select public.contract_transition(pg_temp.c('cNo'), 'onayla');
select public.contract_transition(pg_temp.c('cLim'), 'onayla');

select tests.authenticate_as(pg_temp.c('muhasebe'));
select is((select total_amount from public.contract_versions where contract_id = pg_temp.c('cNo') and status = 'onaylandi'),
  null, 'onaylı sözleşmenin bedeli tanımsız');
select throws_like(pg_temp.avans('a0', 'cNo', 1), '%bedeli tanımlı olmayan%',
  'bedeli tanımsız sözleşmeye avans verilemez (açık hata)');
select is((select count(*)::int from public.finance_payments where contract_id = pg_temp.c('cNo')), 0,
  'reddedilen avans kayıt veya cari hareket açmaz');

select lives_ok(pg_temp.avans('a1', 'cLim', 60000), 'bedelin altında avans (60.000 / 100.000) kabul');
select lives_ok(pg_temp.avans('a2', 'cLim', 40000), 'toplamı bedele tam eşit avans (100.000) kabul');
select throws_ok(pg_temp.avans('a3', 'cLim', 0.01), '23514', null, 'bedeli 0,01 aşan avans reddedilir');
select is((select advance_paid_total from public.contract_finance_summary(pg_temp.c('cLim'))), 100000.00,
  'özette verilen avans 100.000');

select lives_ok(format($$ select public.cancel_finance_payment(%L, 'Yanlış tutarla girildi') $$, pg_temp.c('a2')),
  'mahsup edilmemiş avans iptal edilir');
select is((select advance_paid_total from public.contract_finance_summary(pg_temp.c('cLim'))), 60000.00,
  'iptal edilen avans özetten düşer');
select lives_ok(pg_temp.avans('a4', 'cLim', 40000), 'iptal edilen avans tavandan düşülür: yeniden 40.000 verilir');
select throws_ok(pg_temp.avans('a5', 'cLim', 0.01), '23514', null, 'tavan yine tam dolu: 0,01 reddedilir');
select tests.clear_authentication();
select is((select coalesce(sum(case direction when 'borc' then amount_try else -amount_try end), 0)
             from public.cari_entries where cari_account_id = pg_temp.c('cari')), 100000.00,
  'cari: iptal ters kayıtla kapandı, etkin avans 100.000 TL');

select * from finish();
rollback;
