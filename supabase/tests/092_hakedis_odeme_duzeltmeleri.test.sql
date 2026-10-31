-- PR #6 inceleme düzeltmeleri (migration 20261102000000):
-- 1) hedefsiz normal ödeme reddedilir; avans ayrı ve sınırlı; fazla ödeme
--    reddedilir; özet negatif kalan üretmez.
-- 2) TRY dışı sözleşmede kur zorunlu; deftere işleme, teminat iadesi ve
--    ödemede amount_try doğru; farklı tarihlerde farklı kur; TRY'de kur 1.
-- 3) aynı ödeme kimliği farklı kaynak, tarih veya kurla gelirse uyuşmazlık.
begin;
select plan(49);

-- ---------------------------------------------------------------- hazırlık
create temp table ctx (k text primary key, v uuid) on commit drop;
grant select, insert on ctx to authenticated;
create function pg_temp.c(p_key text) returns uuid language sql stable
  as $$ select v from ctx where k = p_key $$;
create function pg_temp.bf(p_key text, p_qty numeric, p_price numeric) returns jsonb
  language sql stable as $$ select jsonb_build_object('item_key', pg_temp.c(p_key), 'method', 'birim_fiyat',
    'description', 'Test kalemi', 'unit', 'adet', 'quantity', p_qty, 'unit_price', p_price) $$;
-- Carinin TL bakiyesi (borç − alacak). postgres olarak okunur.
create function pg_temp.balance(p_cari text) returns numeric language sql stable
  as $$ select coalesce(sum(case direction when 'borc' then amount_try else -amount_try end), 0)
          from public.cari_entries where cari_account_id = pg_temp.c(p_cari) $$;
create function pg_temp.entry(p_id text) returns public.cari_entries language sql stable
  as $$ select * from public.cari_entries where id = pg_temp.c(p_id) $$;

insert into ctx values
  ('admin',    tests.create_user('od-yonetici@test.invalid')),
  ('muhasebe', tests.create_user('od-muhasebe@test.invalid')),
  ('p',        tests.create_project('TEST-OD'));
insert into ctx values ('iT', gen_random_uuid()), ('iU', gen_random_uuid()),
                       ('cT', gen_random_uuid()), ('cU', gen_random_uuid()),
                       ('hT', gen_random_uuid()), ('hU', gen_random_uuid()),
                       ('wqT', gen_random_uuid()), ('wqU', gen_random_uuid()),
                       ('advT', gen_random_uuid()), ('payT1', gen_random_uuid()), ('payT2', gen_random_uuid()),
                       ('payT3', gen_random_uuid()), ('relT', gen_random_uuid()),
                       ('payU1', gen_random_uuid()), ('payU2', gen_random_uuid()), ('relU', gen_random_uuid());
select tests.grant_global_role(pg_temp.c('admin'),    'yonetici');
select tests.grant_global_role(pg_temp.c('muhasebe'), 'muhasebe');

insert into public.cari_accounts (code, title, type) values
  ('TEST-OD-T', 'TEST OD TL Taşeron', 'taseron'), ('TEST-OD-U', 'TEST OD USD Taşeron', 'taseron');
insert into ctx select case code when 'TEST-OD-T' then 'cariT' else 'cariU' end, id
  from public.cari_accounts where code like 'TEST-OD-%';
insert into public.subcontractors (name, cari_account_id) values
  ('TEST OD TL', pg_temp.c('cariT')), ('TEST OD USD', pg_temp.c('cariU'));
insert into ctx select case name when 'TEST OD TL' then 'subT' else 'subU' end, id
  from public.subcontractors where name like 'TEST OD %';
insert into public.payment_sources (name, kind) values ('TEST OD Şirket ödemesi', 'sirket'), ('TEST OD Kürşat kartı', 'kart');
insert into ctx select case name when 'TEST OD Şirket ödemesi' then 'srcSirket' else 'srcKart' end, id
  from public.payment_sources where name like 'TEST OD %';

-- TL sözleşme: 100 adet × 1.000, bedel 100.000, teminat %20.
-- USD sözleşme: 10 adet × 1.000 USD, bedel 10.000, teminat %10.
select tests.authenticate_as(pg_temp.c('admin'));
select public.save_contract(pg_temp.c('cT'), pg_temp.c('p'), pg_temp.c('subT'), 'TEST-OD-1', 'TL sözleşme',
                            jsonb_build_array(pg_temp.bf('iT', 100, 1000)), p_total_amount => 100000, p_retention_rate => 20);
select public.save_contract(pg_temp.c('cU'), pg_temp.c('p'), pg_temp.c('subU'), 'TEST-OD-2', 'USD sözleşme',
                            jsonb_build_array(pg_temp.bf('iU', 10, 1000)), p_currency => 'USD',
                            p_total_amount => 10000, p_retention_rate => 10);
select public.contract_transition(pg_temp.c('cT'), 'onayla');
select public.contract_transition(pg_temp.c('cU'), 'onayla');
select public.save_work_quantity(pg_temp.c('wqT'), pg_temp.c('cT'), pg_temp.c('iT'), '2026-09-10', 50, null, null);
select public.save_work_quantity(pg_temp.c('wqU'), pg_temp.c('cU'), pg_temp.c('iU'), '2026-09-10', 4, null, null);
select public.approve_work_quantities(array[pg_temp.c('wqT'), pg_temp.c('wqU')]);

-- ---------------------------------------------------------------- 1. hedefsiz ödeme ve avans
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 1000, %L, '2026-09-01') $$,
         gen_random_uuid(), pg_temp.c('cT'), pg_temp.c('srcSirket')),
  '23514', null, 'hakediş yokken hedefsiz normal ödeme reddedilir');
select results_eq($$ select paid_total, remaining_total from public.contract_finance_summary(pg_temp.c('cT')) $$,
  $$ values (0::numeric, 0::numeric) $$, 'reddedilen ödeme özeti değiştirmez; kalan eksiye düşmez');
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'baska', 1000, %L, '2026-09-01') $$,
         gen_random_uuid(), pg_temp.c('cT'), pg_temp.c('srcSirket')),
  '23514', null, 'tanımsız ödeme türü reddedilir');
select lives_ok(
  format($$ select public.record_finance_payment(%L, %L, 'avans', 10000, %L, '2026-09-01') $$,
         pg_temp.c('advT'), pg_temp.c('cT'), pg_temp.c('srcSirket')),
  'hedefsiz ödeme yalnızca açıkça avans olarak kaydedilir');
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'avans', 90000.01, %L, '2026-09-02') $$,
         gen_random_uuid(), pg_temp.c('cT'), pg_temp.c('srcSirket')),
  '23514', null, 'toplam avans sözleşme bedelini aşamaz');
select is((select advance_paid_total from public.contract_finance_summary(pg_temp.c('cT'))), 10000.00, 'avans ödemeden ayrı görünür');
select is((select paid_total from public.contract_finance_summary(pg_temp.c('cT'))), 0::numeric, 'avans gerçekleşen ödeme sayılmaz');

-- TL hakediş: brüt 50.000, teminat 10.000, ödemeye uygun 40.000.
select tests.authenticate_as(pg_temp.c('admin'));
select public.create_hakedis(pg_temp.c('hT'), pg_temp.c('cT'), '2026-09-01', '2026-09-30');
select public.hakedis_transition(pg_temp.c('hT'), 'gonder');
select public.hakedis_transition(pg_temp.c('hT'), 'onayla');
select is((select payable_amount from public.hakedis where id = pg_temp.c('hT')), 40000.00, 'TL hakediş ödemeye uygun 40.000');
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'avans', 1000, %L, '2026-09-02', %L) $$,
         gen_random_uuid(), pg_temp.c('cT'), pg_temp.c('srcSirket'), pg_temp.c('hT')),
  '23514', null, 'avans bir hakedişe bağlanamaz');

-- ---------------------------------------------------------------- 2a. TRY kuru
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(format($$ select public.post_hakedis(%L, '2026-10-01', 2) $$, pg_temp.c('hT')),
  '23514', null, 'TL hakedişte kur 1 dışında olamaz');
select lives_ok(format($$ select public.post_hakedis(%L, '2026-10-01') $$, pg_temp.c('hT')), 'TL hakediş kursuz deftere işlenir');
select is((select exchange_rate from public.cari_entries where source_type = 'hakedis' and source_id = pg_temp.c('hT')),
  1.000000, 'TL harekette kur 1');

-- ---------------------------------------------------------------- 1b. hedefli ödeme ve fazla ödeme
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 40000.01, %L, '2026-10-10', %L) $$,
         gen_random_uuid(), pg_temp.c('cT'), pg_temp.c('srcSirket'), pg_temp.c('hT')),
  '23514', null, 'ödemeye uygun tutarı aşan ödeme reddedilir');
select lives_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 30000, %L, '2026-10-10', %L) $$,
         pg_temp.c('payT1'), pg_temp.c('cT'), pg_temp.c('srcSirket'), pg_temp.c('hT')),
  'şirket ödemesiyle 30.000 hedefli ödeme');

-- ---------------------------------------------------------------- 3. tekrar gönderim
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 30000, %L, '2026-10-10', %L) $$,
         pg_temp.c('payT1'), pg_temp.c('cT'), pg_temp.c('srcKart'), pg_temp.c('hT')),
  '23505', null, 'aynı kimlik farklı ödeme kaynağıyla (Kürşat kartı) gelirse uyuşmazlık');
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 30000, %L, '2026-10-11', %L) $$,
         pg_temp.c('payT1'), pg_temp.c('cT'), pg_temp.c('srcSirket'), pg_temp.c('hT')),
  '23505', null, 'aynı kimlik farklı ödeme tarihiyle gelirse uyuşmazlık');
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 29999, %L, '2026-10-10', %L) $$,
         pg_temp.c('payT1'), pg_temp.c('cT'), pg_temp.c('srcSirket'), pg_temp.c('hT')),
  '23505', null, 'aynı kimlik farklı tutarla gelirse uyuşmazlık');
select is(
  (public.record_finance_payment(pg_temp.c('payT1'), pg_temp.c('cT'), 'odeme', 30000, pg_temp.c('srcSirket'),
                                 '2026-10-10', pg_temp.c('hT'))).id,
  pg_temp.c('payT1'), 'aynı niyetle tekrar gönderim aynı kaydı döner');
select is(
  (public.record_finance_payment(pg_temp.c('payT1'), pg_temp.c('cT'), 'odeme', 30000, pg_temp.c('srcSirket'),
                                 null, pg_temp.c('hT'))).payment_date,
  '2026-10-10'::date, 'tarihsiz tekrar gönderim kayıtlı tarihi korur');
select is((select count(*)::int from public.finance_payments where id = pg_temp.c('payT1')), 1, 'tekrar gönderim tek ödeme');
select is((select payment_source_id from public.finance_payments where id = pg_temp.c('payT1')), pg_temp.c('srcSirket'),
  'ödeme kaynağı ilk kayıttaki gibi kalır');

select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 10000.01, %L, '2026-10-12', %L) $$,
         gen_random_uuid(), pg_temp.c('cT'), pg_temp.c('srcKart'), pg_temp.c('hT')),
  '23514', null, 'kalanı (10.000) aşan ikinci ödeme reddedilir');
select lives_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 10000, %L, '2026-10-12', %L) $$,
         pg_temp.c('payT2'), pg_temp.c('cT'), pg_temp.c('srcKart'), pg_temp.c('hT')),
  'kalan 10.000 Kürşat kartıyla ödenir');

-- teminat iadesi (TL) ve ödemesi
select tests.authenticate_as(pg_temp.c('admin'));
select lives_ok(format($$ select public.release_teminat(%L, %L, 5000, 'Kısmi kabul sonrası iade', '2026-10-15') $$,
                       pg_temp.c('relT'), pg_temp.c('cT')), 'TL teminatın 5.000''i serbest bırakılır');
select throws_ok(format($$ select public.release_teminat(%L, %L, 5000, 'Kısmi kabul sonrası iade', '2026-10-16') $$,
                        pg_temp.c('relT'), pg_temp.c('cT')),
  '23505', null, 'aynı iade kimliği farklı tarihle gelirse uyuşmazlık');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 1, %L, '2026-10-16', %L, %L) $$,
         gen_random_uuid(), pg_temp.c('cT'), pg_temp.c('srcSirket'), pg_temp.c('hT'), pg_temp.c('relT')),
  '23514', null, 'ödeme aynı anda iki hedefe bağlanamaz');
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 5000.01, %L, '2026-10-16', null, %L) $$,
         gen_random_uuid(), pg_temp.c('cT'), pg_temp.c('srcSirket'), pg_temp.c('relT')),
  '23514', null, 'teminat iadesini aşan ödeme reddedilir');
select lives_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 5000, %L, '2026-10-16', null, %L) $$,
         pg_temp.c('payT3'), pg_temp.c('cT'), pg_temp.c('srcSirket'), pg_temp.c('relT')),
  'teminat iadesi ayrıca ödenir');
select results_eq($$ select payable_total, retention_released, paid_total, advance_paid_total, remaining_total
                       from public.contract_finance_summary(pg_temp.c('cT')) $$,
  $$ values (40000.00::numeric, 5000.00::numeric, 45000.00::numeric, 10000.00::numeric, 0.00::numeric) $$,
  'TL özet: ödemeye uygun 40.000 + iade 5.000 − ödenen 45.000 = 0; avans ayrı');
select tests.clear_authentication();
select is(pg_temp.balance('cariT'), 10000.00, 'TL cari: tüm yükümlülük ödendi, yalnızca mahsup edilmemiş 10.000 avans kaldı');
select throws_ok(
  format($$ insert into public.finance_payments (id, contract_id, project_id, cari_account_id, kind, amount, payment_date,
                                                 payment_source_id, cari_entry_id)
            values (gen_random_uuid(), %L, %L, %L, 'odeme', 1, '2026-10-20', %L, gen_random_uuid()) $$,
         pg_temp.c('cT'), pg_temp.c('p'), pg_temp.c('cariT'), pg_temp.c('srcSirket')),
  '23514', null, 'tablo kuralı da hedefsiz normal ödemeyi reddeder');

-- ---------------------------------------------------------------- 2b. USD
select tests.authenticate_as(pg_temp.c('admin'));
select public.create_hakedis(pg_temp.c('hU'), pg_temp.c('cU'), '2026-09-01', '2026-09-30');
select public.hakedis_transition(pg_temp.c('hU'), 'gonder');
select public.hakedis_transition(pg_temp.c('hU'), 'onayla');
select results_eq($$ select currency::text, gross_amount, retention_amount, payable_amount
                       from public.hakedis where id = pg_temp.c('hU') $$,
  $$ values ('USD', 4000.00::numeric, 400.00::numeric, 3600.00::numeric) $$, 'USD hakediş: brüt 4.000, teminat 400, ödemeye uygun 3.600');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(format($$ select public.post_hakedis(%L, '2026-10-01') $$, pg_temp.c('hU')),
  '23514', null, 'USD hakediş kursuz deftere işlenemez (kur tahmin edilmez)');
select throws_ok(format($$ select public.post_hakedis(%L, '2026-10-01', 0) $$, pg_temp.c('hU')),
  '23514', null, 'kur sıfır olamaz');
select throws_ok(format($$ select public.post_hakedis(%L, '2026-10-01', 41.1234567) $$, pg_temp.c('hU')),
  '23514', null, 'kur en çok 6 ondalıklı');
select lives_ok(format($$ select public.post_hakedis(%L, '2026-10-01', 41.5) $$, pg_temp.c('hU')),
  'USD hakediş 41,5 kurla deftere işlenir');
select tests.clear_authentication();
select results_eq(
  format($$ select kind::text, amount, exchange_rate, amount_try from public.cari_entries
             where cari_account_id = %L order by amount desc $$, pg_temp.c('cariU')),
  $$ values ('hakedis', 4000.00::numeric, 41.500000::numeric, 166000.00::numeric),
            ('kesinti', 400.00::numeric, 41.500000::numeric, 16600.00::numeric) $$,
  'USD hakediş ve teminat kesintisi TL karşılığı 41,5 kurla');

select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 1000, %L, '2026-10-20', %L) $$,
         gen_random_uuid(), pg_temp.c('cU'), pg_temp.c('srcSirket'), pg_temp.c('hU')),
  '23514', null, 'USD ödeme kursuz kaydedilemez');
select lives_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 1000, %L, '2026-10-20', %L, p_exchange_rate => 42) $$,
         pg_temp.c('payU1'), pg_temp.c('cU'), pg_temp.c('srcSirket'), pg_temp.c('hU')),
  '20 Ekim: 1.000 USD, kur 42');
select lives_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 1000, %L, '2026-10-25', %L, p_exchange_rate => 43) $$,
         pg_temp.c('payU2'), pg_temp.c('cU'), pg_temp.c('srcSirket'), pg_temp.c('hU')),
  '25 Ekim: 1.000 USD, kur 43');
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 1000, %L, '2026-10-20', %L, p_exchange_rate => 43) $$,
         pg_temp.c('payU1'), pg_temp.c('cU'), pg_temp.c('srcSirket'), pg_temp.c('hU')),
  '23505', null, 'aynı ödeme kimliği farklı kurla gelirse uyuşmazlık');
select tests.clear_authentication();
select results_eq($$ select (pg_temp.entry('payU1')).amount_try, (pg_temp.entry('payU2')).amount_try $$,
  $$ values (42000.00::numeric, 43000.00::numeric) $$, 'farklı tarihlerde farklı kur: 42.000 ve 43.000 TL');
select is((select (data ->> 'exchange_rate')::numeric from public.finance_events
            where entity_id = pg_temp.c('payU1') and action = 'kaydet'), 42::numeric, 'ödeme geçmişi kuru saklar');

select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(format($$ select public.release_teminat(%L, %L, 200, 'Kısmi kabul sonrası iade', '2026-10-28') $$,
                        gen_random_uuid(), pg_temp.c('cU')),
  '23514', null, 'USD teminat iadesi kursuz yapılamaz');
select lives_ok(format($$ select public.release_teminat(%L, %L, 200, 'Kısmi kabul sonrası iade', '2026-10-28', 44) $$,
                       pg_temp.c('relU'), pg_temp.c('cU')), 'USD teminatın 200''ü 44 kurla serbest bırakılır');
select throws_ok(format($$ select public.release_teminat(%L, %L, 200, 'Kısmi kabul sonrası iade', '2026-10-28', 45) $$,
                        pg_temp.c('relU'), pg_temp.c('cU')),
  '23505', null, 'aynı iade kimliği farklı kurla gelirse uyuşmazlık');
select results_eq($$ select payable_total, retention_released, paid_total, remaining_total from public.contract_finance_summary(pg_temp.c('cU')) $$,
  $$ values (3600.00::numeric, 200.00::numeric, 2000.00::numeric, 1800.00::numeric) $$,
  'USD özet sözleşme para biriminde: 3.600 + 200 − 2.000 = 1.800 USD');
select tests.clear_authentication();
select is((select amount_try from public.cari_entries where source_type = 'teminat_iade' and source_id = pg_temp.c('relU')),
  8800.00, 'USD teminat iadesi TL karşılığı 200 × 44 = 8.800');
select is(pg_temp.balance('cariU'), -73200.00,
  'USD cari TL bakiyesi: (16.600 + 42.000 + 43.000) − (166.000 + 8.800) = −73.200');

select * from finish();
rollback;
