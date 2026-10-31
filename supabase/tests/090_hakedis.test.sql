-- Sözleşme ve hakediş: birim fiyat, günlük (puantaj), götürü ve karma
-- sözleşme; kümülatif miktar ve limit; imalat ve puantajın iki kez
-- kullanılamaması; %20 teminat örneği, biriken ve kısmen serbest bırakılan
-- teminat; avans mahsubu ve kısmi ödeme; onaylı fakat ödenmemiş hakediş;
-- tekrarlanan onay ve deftere işleme; iptal, revizyon ve ters kayıt; proje
-- bazlı RLS, pasif kullanıcı ve yetkisiz finans erişimi; DEMO ayrımı;
-- yuvarlama ve tutar bütünlüğü.
begin;
select plan(153);

-- ---------------------------------------------------------------- hazırlık
create temp table ctx (k text primary key, v uuid) on commit drop;
grant select, insert on ctx to authenticated;
create function pg_temp.c(p_key text) returns uuid language sql stable
  as $$ select v from ctx where k = p_key $$;

-- Sözleşme kalemi (jsonb).
create function pg_temp.bf(p_key text, p_desc text, p_unit text, p_qty numeric, p_price numeric) returns jsonb
  language sql stable as $$ select jsonb_build_object('item_key', pg_temp.c(p_key), 'method', 'birim_fiyat',
    'description', p_desc, 'unit', p_unit, 'quantity', p_qty, 'unit_price', p_price) $$;
create function pg_temp.gn(p_key text, p_price numeric, p_ot numeric, p_bases text[]) returns jsonb
  language sql stable as $$ select jsonb_build_object('item_key', pg_temp.c(p_key), 'method', 'gunluk',
    'description', 'Günlük işçilik', 'unit_price', p_price, 'overtime_unit_price', p_ot, 'paid_bases', p_bases) $$;
create function pg_temp.gt(p_key text, p_desc text, p_price numeric) returns jsonb
  language sql stable as $$ select jsonb_build_object('item_key', pg_temp.c(p_key), 'method', 'goturu',
    'description', p_desc, 'unit_price', p_price) $$;
create function pg_temp.line(p_h text, p_item text, p_kind text default 'ana') returns public.hakedis_lines
  language sql stable as $$ select * from public.hakedis_lines
    where hakedis_id = pg_temp.c(p_h) and item_key = pg_temp.c(p_item) and line_kind = p_kind $$;
create function pg_temp.h(p_h text) returns public.hakedis
  language sql stable as $$ select * from public.hakedis where id = pg_temp.c(p_h) $$;
-- Carinin TL bakiyesi (borç − alacak; eksi: biz borçluyuz). postgres olarak okunur.
create function pg_temp.balance(p_cari text) returns numeric language sql stable
  as $$ select coalesce(sum(case direction when 'borc' then amount_try else -amount_try end), 0)
          from public.cari_entries where cari_account_id = pg_temp.c(p_cari) $$;

insert into ctx values
  ('admin',    tests.create_user('hk-yonetici@test.invalid')),
  ('muhasebe', tests.create_user('hk-muhasebe@test.invalid')),
  ('mudur',    tests.create_user('hk-mudur@test.invalid')),
  ('mudurB',   tests.create_user('hk-mudur-b@test.invalid')),
  ('sef',      tests.create_user('hk-sef@test.invalid')),
  ('passive',  tests.create_user('hk-pasif@test.invalid')),
  ('outsider', tests.create_user('hk-rolsuz@test.invalid')),
  ('pA',       tests.create_project('TEST-HK-A')),
  ('pB',       tests.create_project('TEST-HK-B'));
insert into public.projects (code, name, is_demo) values ('TEST-HK-DEMO', 'Demo hakediş projesi', true);
insert into ctx select 'pDemo', id from public.projects where code = 'TEST-HK-DEMO';
insert into ctx values ('iBeton', gen_random_uuid()), ('iBeton2', gen_random_uuid()), ('iGun', gen_random_uuid()),
                       ('iIskele', gen_random_uuid()), ('iSiva', gen_random_uuid()), ('iKucuk', gen_random_uuid()),
                       ('cBf', gen_random_uuid()), ('cKarma', gen_random_uuid()), ('cKucuk', gen_random_uuid()),
                       ('h1', gen_random_uuid()), ('h2', gen_random_uuid()), ('hK1', gen_random_uuid()),
                       ('hK2', gen_random_uuid()), ('hK3', gen_random_uuid()), ('hS', gen_random_uuid()),
                       ('wq1', gen_random_uuid()), ('wq2', gen_random_uuid()), ('wq3', gen_random_uuid()),
                       ('pay1', gen_random_uuid()), ('pay2', gen_random_uuid()), ('pay3', gen_random_uuid()),
                       ('adv1', gen_random_uuid()), ('rel1', gen_random_uuid()), ('rel2', gen_random_uuid()),
                       ('rel3', gen_random_uuid());

select tests.grant_global_role(pg_temp.c('admin'),    'yonetici');
select tests.grant_global_role(pg_temp.c('muhasebe'), 'muhasebe');
select tests.grant_global_role(pg_temp.c('passive'),  'muhasebe');
update public.profiles set is_active = false where id = pg_temp.c('passive');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('mudur'),  'proje_muduru', '2020-01-01');
select tests.add_member(pg_temp.c('pB'), pg_temp.c('mudurB'), 'proje_muduru', '2020-01-01');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('sef'),    'santiye_sefi', '2020-01-01');

insert into public.cari_accounts (code, title, type) values ('TEST-HK-C1', 'TEST HK Kaba Yapı Taşeronu', 'taseron');
insert into public.cari_accounts (code, title, type, is_demo) values ('TEST-HK-CD', 'TEST HK Demo Taşeron', 'taseron', true);
insert into ctx select case code when 'TEST-HK-C1' then 'cari' else 'cariDemo' end, id
  from public.cari_accounts where code like 'TEST-HK-%';
insert into public.subcontractors (name, cari_account_id) values ('TEST HK Kaba Yapı', pg_temp.c('cari'));
insert into public.subcontractors (name) values ('TEST HK Carisiz');
insert into public.subcontractors (name, cari_account_id, is_demo) values ('TEST HK Demo', pg_temp.c('cariDemo'), true);
insert into ctx select case name when 'TEST HK Kaba Yapı' then 'sub' when 'TEST HK Carisiz' then 'subNoCari' else 'subDemo' end, id
  from public.subcontractors where name like 'TEST HK %';
insert into public.personnel (full_name, employment_type, subcontractor_id) values
  ('TEST HK İşçi 1', 'taseron', pg_temp.c('sub')), ('TEST HK İşçi 2', 'taseron', pg_temp.c('sub'));
insert into ctx select case full_name when 'TEST HK İşçi 1' then 'w1' else 'w2' end, id
  from public.personnel where full_name like 'TEST HK İşçi %';
insert into public.project_assignments (project_id, personnel_id, start_date) values
  (pg_temp.c('pA'), pg_temp.c('w1'), '2026-01-01'), (pg_temp.c('pA'), pg_temp.c('w2'), '2026-01-01');

insert into public.tax_rules (code, name, kind, rate, valid_from, verified_at) values
  ('TKDV20', 'KDV %20 (test)', 'kdv', 20, '2020-01-01', now()),
  ('TSTP3', 'Stopaj %3 (test)', 'stopaj', 3, '2020-01-01', now());
insert into public.tax_rules (code, name, kind, rate, valid_from) values ('TKDVX', 'Doğrulanmamış KDV', 'kdv', 10, '2020-01-01');
insert into public.payment_sources (name, kind) values ('TEST HK Şirket ödemesi', 'sirket'), ('TEST HK Kürşat kartı', 'kart');
insert into ctx select case name when 'TEST HK Şirket ödemesi' then 'srcSirket' else 'srcKart' end, id
  from public.payment_sources where name like 'TEST HK %';
create temp table start_counts on commit drop as select (select count(*)::int from public.cari_accounts) as cari_accounts;
grant select on start_counts to authenticated;

-- ---------------------------------------------------------------- yapı
select ok(not has_table_privilege('authenticated', 'public.hakedis', 'insert')
          and not has_table_privilege('authenticated', 'public.hakedis', 'update')
          and not has_table_privilege('authenticated', 'public.contract_items', 'update')
          and not has_table_privilege('authenticated', 'public.teminat_releases', 'insert')
          and not has_table_privilege('authenticated', 'public.finance_payments', 'insert'),
  'sözleşme, hakediş, teminat ve ödeme tabloları API''den doğrudan yazılamaz');
select is_empty(
  $$ select table_name, column_name from information_schema.columns
      where table_schema = 'public' and table_name in ('work_quantities')
        and column_name ~ '(amount|price|fiyat|tutar)' $$,
  'imalat (metraj) kaydı fiyat veya tutar içermez');
select is_empty(
  $$ select n.nspname || '.' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'private') and p.proname ~ '(kasa|bank|cash)' $$,
  'kasa veya banka bakiyesi fonksiyonu yok');

-- ---------------------------------------------------------------- 1. birim fiyatlı sözleşme
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(
  format($$ select public.save_contract(null, %L, %L, 'TEST-S-0', 'Carisiz', %L) $$, pg_temp.c('pA'), pg_temp.c('subNoCari'),
         jsonb_build_array(pg_temp.bf('iBeton', 'Beton', 'm3', 10, 100))),
  '23514', null, 'cari kartı olmayan taşerona sözleşme açılamaz (ikinci cari oluşturulmaz)');
select lives_ok(
  format($$ select public.save_contract(%L, %L, %L, 'TEST-S-1', 'Kaba yapı betonu', %L,
            p_total_amount => 1500000, p_retention_rate => 20) $$,
         pg_temp.c('cBf'), pg_temp.c('pA'), pg_temp.c('sub'),
         jsonb_build_array(pg_temp.bf('iBeton', 'C30 beton dökümü', 'm3', 150, 10000))),
  'muhasebe birim fiyatlı sözleşme taslağı hazırlar (%20 teminat)');
select is((select cari_account_id from public.contracts where id = pg_temp.c('cBf')), pg_temp.c('cari'),
  'sözleşmenin finansal kimliği taşeronun mevcut cari kartı');
select is((select count(*)::int from public.cari_accounts), (select cari_accounts from start_counts),
  'yeni cari kart oluşmaz');
select throws_ok(format($$ select public.contract_transition(%L, 'onayla') $$, pg_temp.c('cBf')),
  '42501', null, 'muhasebe sözleşmeyi onaylayamaz');
select throws_ok(format($$ select public.create_hakedis(%L, %L, '2026-09-01', '2026-09-30') $$, pg_temp.c('h1'), pg_temp.c('cBf')),
  '23514', null, 'onaysız sözleşmeye hakediş açılamaz');
select tests.authenticate_as(pg_temp.c('admin'));
select is((public.contract_transition(pg_temp.c('cBf'), 'onayla')).status::text, 'aktif', 'yönetici sözleşmeyi onaylar');
select throws_ok(
  format($$ select public.save_contract(%L, %L, %L, 'TEST-S-1', 'Kaba yapı betonu', %L) $$,
         pg_temp.c('cBf'), pg_temp.c('pA'), pg_temp.c('sub'), jsonb_build_array(pg_temp.bf('iBeton', 'Beton', 'm3', 150, 1))),
  '23514', null, 'onaylı sözleşmenin fiyatı revizyon açmadan değiştirilemez');
select tests.clear_authentication();
select throws_ok(
  format($$ update public.contract_items set unit_price = 1 where contract_id = %L $$, pg_temp.c('cBf')),
  '23514', null, 'onaylı revizyonun kalemi veritabanında da değiştirilemez');

-- imalat: şantiye şefi miktar girer, fiyat görmez
select tests.authenticate_as(pg_temp.c('sef'));
select is((select count(*)::int from public.contract_items), 0, 'şantiye şefi sözleşme fiyatlarını göremez');
select is((select count(*)::int from public.contracts), 0, 'şantiye şefi sözleşmeleri göremez');
select results_eq(
  format($$ select description, unit, contract_quantity from public.imalat_items(%L) $$, pg_temp.c('pA')),
  $$ values ('C30 beton dökümü', 'm3', 150.000::numeric) $$,
  'şantiye şefi imalat kalemini fiyatsız görür');
select lives_ok(
  format($$ select public.save_work_quantity(%L, %L, %L, '2026-09-10', 100, 'B blok temel') $$,
         pg_temp.c('wq1'), pg_temp.c('cBf'), pg_temp.c('iBeton')),
  'şantiye şefi 100 m³ imalat girer');
select throws_ok(format($$ select public.approve_work_quantities(array[%L::uuid]) $$, pg_temp.c('wq1')),
  '42501', null, 'şantiye şefi imalatı onaylayamaz');
select is((select count(*)::int from public.hakedis), 0, 'şantiye şefi hakediş tutarlarını göremez');
select tests.authenticate_as(pg_temp.c('mudur'));
select is(public.approve_work_quantities(array[pg_temp.c('wq1')]), 1, 'proje müdürü imalatı onaylar');

-- hakediş 1: %20 teminat örneği
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(format($$ select public.create_hakedis(%L, %L, '2026-09-01', '2026-09-30') $$, pg_temp.c('h1'), pg_temp.c('cBf')),
  'muhasebe hakediş hazırlar');
select results_eq(
  $$ select gross_amount, retention_amount, kdv_amount, payable_amount from pg_temp.h('h1') $$,
  $$ values (1000000.00::numeric, 200000.00::numeric, 0.00::numeric, 800000.00::numeric) $$,
  '%20 teminat: brüt 1.000.000, teminat 200.000, ödemeye uygun 800.000');
select results_eq(
  $$ select quantity, previous_quantity, cumulative_quantity, amount from pg_temp.line('h1', 'iBeton') $$,
  $$ values (100.0000::numeric, 0.0000::numeric, 100.0000::numeric, 1000000.00::numeric) $$,
  'bu dönem 100 m³ × 10.000; önceki 0; kümülatif 100');
select throws_ok(format($$ select public.create_hakedis(%L, %L, '2026-10-01', '2026-10-31') $$, gen_random_uuid(), pg_temp.c('cBf')),
  '23514', null, 'aynı sözleşmede ikinci açık hakediş açılamaz');
select lives_ok(format($$ select public.hakedis_transition(%L, 'gonder') $$, pg_temp.c('h1')), 'muhasebe incelemeye gönderir');
select throws_ok(format($$ select public.hakedis_transition(%L, 'onayla') $$, pg_temp.c('h1')),
  '42501', null, 'finans (muhasebe) yetkisi hakediş onayı değildir');
select tests.authenticate_as(pg_temp.c('mudur'));
select throws_ok(format($$ select public.hakedis_transition(%L, 'onayla') $$, pg_temp.c('h1')),
  '42501', null, 'proje müdürü finansal onay veremez');
select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(format($$ select public.hakedis_transition(%L, 'onayla', null, 0) $$, pg_temp.c('h1')),
  '40001', null, 'eski sürümle gelen onay reddedilir');
select is((public.hakedis_transition(pg_temp.c('h1'), 'onayla')).status::text, 'onaylandi', 'yönetici hakedişi onaylar');
select throws_ok(format($$ select public.hakedis_transition(%L, 'onayla') $$, pg_temp.c('h1')),
  '23514', null, 'tekrarlanan onay reddedilir');
select is(
  (select (data -> 'totals' ->> 'payable')::numeric from public.finance_events
    where entity_id = pg_temp.c('h1') and action = 'onayla'),
  800000.00, 'onay geçmişi tutarların snapshot''ını saklar');
select is((select count(*)::int from public.cari_entries where source_id = pg_temp.c('h1')), 0,
  'onay cari deftere kendiliğinden yazmaz');
select results_eq(
  format($$ select payable_amount, paid_amount, remaining_amount from public.v_hakedis_payment_status where hakedis_id = %L $$, pg_temp.c('h1')),
  $$ values (800000.00::numeric, 0::numeric, 800000.00::numeric) $$,
  'onaylı fakat ödenmemiş: ödemeye uygun 800.000, ödenen 0, kalan 800.000');
select tests.clear_authentication();
select throws_ok(format($$ update public.hakedis set gross_amount = 1 where id = %L $$, pg_temp.c('h1')),
  '23514', null, 'onaylı hakedişin tutarı veritabanında da değiştirilemez');

-- deftere işleme
select tests.authenticate_as(pg_temp.c('mudur'));
select throws_ok(format($$ select public.post_hakedis(%L) $$, pg_temp.c('h1')),
  '42501', null, 'deftere işleme ayrı yetki ister');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(format($$ select public.post_hakedis(%L, '2026-10-05') $$, pg_temp.c('h1')), 'muhasebe hakedişi deftere işler');
select lives_ok(format($$ select public.post_hakedis(%L, '2026-10-05') $$, pg_temp.c('h1')), 'tekrar gönderim hata vermez');
select tests.clear_authentication();
select results_eq(
  format($$ select kind::text, direction::text, amount from public.cari_entries
             where cari_account_id = %L order by amount desc $$, pg_temp.c('cari')),
  $$ values ('hakedis', 'alacak', 1000000.00::numeric), ('kesinti', 'borc', 200000.00::numeric) $$,
  'defterde brüt hakediş alacağı ve teminat kesintisi ayrı hareketler; tekrar işleme ikinci hareket açmaz');
select is(pg_temp.balance('cari'), -800000.00, 'cari bakiye: taşerona 800.000 borçluyuz (teminat dahil değil)');

-- kısmi ödeme
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 300000, %L, '2026-10-10', %L) $$,
         pg_temp.c('pay1'), pg_temp.c('cBf'), pg_temp.c('srcKart'), pg_temp.c('h1')),
  'Kürşat kartından 300.000 kısmi ödeme');
select lives_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 300000, %L, '2026-10-10', %L) $$,
         pg_temp.c('pay1'), pg_temp.c('cBf'), pg_temp.c('srcKart'), pg_temp.c('h1')),
  'aynı ödemenin tekrar gönderimi');
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 600000, %L, '2026-10-10', %L) $$,
         gen_random_uuid(), pg_temp.c('cBf'), pg_temp.c('srcSirket'), pg_temp.c('h1')),
  '23514', null, 'hakedişin kalanını aşan ödeme reddedilir');
select results_eq(
  format($$ select payable_amount, paid_amount, remaining_amount from public.v_hakedis_payment_status where hakedis_id = %L $$, pg_temp.c('h1')),
  $$ values (800000.00::numeric, 300000.00::numeric, 500000.00::numeric) $$,
  'kısmi ödeme: ödenen 300.000, kalan 500.000');
select tests.clear_authentication();
select is((select count(*)::int from public.cari_entries where source_type = 'finans_odeme' and cari_account_id = pg_temp.c('cari')), 1,
  'tekrar gönderilen ödeme tek hareket');
select is(pg_temp.balance('cari'), -500000.00, 'cari bakiye ödemeden sonra −500.000');

-- teminat serbest bırakma
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(format($$ select public.release_teminat(%L, %L, 50000, 'Kısmi kabul sonrası iade') $$, pg_temp.c('rel1'), pg_temp.c('cBf')),
  '42501', null, 'muhasebe teminatı serbest bırakamaz');
select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(format($$ select public.release_teminat(%L, %L, 200000.01, 'Fazla iade denemesi') $$, gen_random_uuid(), pg_temp.c('cBf')),
  '23514', null, 'biriken teminattan fazlası serbest bırakılamaz');
select lives_ok(format($$ select public.release_teminat(%L, %L, 50000, 'Kısmi kabul sonrası iade', '2026-10-15') $$, pg_temp.c('rel1'), pg_temp.c('cBf')),
  'yönetici 50.000 teminatı kısmen serbest bırakır');
select lives_ok(format($$ select public.release_teminat(%L, %L, 50000, 'Kısmi kabul sonrası iade', '2026-10-15') $$, pg_temp.c('rel1'), pg_temp.c('cBf')),
  'serbest bırakmanın tekrar gönderimi');
select results_eq(
  format($$ select retention_withheld, retention_released, retention_balance, payable_total, paid_total, remaining_total
             from public.contract_finance_summary(%L) $$, pg_temp.c('cBf')),
  $$ values (200000.00::numeric, 50000.00::numeric, 150000.00::numeric, 800000.00::numeric, 300000.00::numeric, 550000.00::numeric) $$,
  'özet: kesilen 200.000, bırakılan 50.000, biriken 150.000; ödemeye uygun 800.000, ödenen 300.000, kalan 550.000');
select tests.clear_authentication();
select is(pg_temp.balance('cari'), -550000.00, 'serbest bırakma yalnızca bırakılan tutar kadar alacak doğurur');
select is((select count(*)::int from public.cari_entries where source_type = 'teminat_iade' and cari_account_id = pg_temp.c('cari')), 1,
  'tekrar gönderilen serbest bırakma tek hareket');
select is((select count(*)::int from public.finance_payments where teminat_release_id = pg_temp.c('rel1')), 0,
  'serbest bırakma nakit ödeme değildir (ödeme kaydı oluşmaz)');
select tests.authenticate_as(pg_temp.c('admin'));
select lives_ok(format($$ select public.release_teminat(%L, %L, 150000, 'Kesin kabul: kalan teminat', '2026-10-20') $$, pg_temp.c('rel2'), pg_temp.c('cBf')),
  'kalan 150.000 teminat da serbest bırakılır');
select throws_ok(format($$ select public.release_teminat(%L, %L, 0.01, 'Fazladan iade denemesi') $$, gen_random_uuid(), pg_temp.c('cBf')),
  '23514', null, 'teminat bitince yeni serbest bırakma reddedilir');
select tests.clear_authentication();
select is(
  (select sum(amount) filter (where direction = 'alacak') - sum(amount) filter (where kind = 'kesinti')
     from public.cari_entries where cari_account_id = pg_temp.c('cari')),
  1000000.00, 'teminatın tamamı bırakılınca toplam yükümlülük brüt hakedişe eşit: çift borç yok');
select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(format($$ select public.hakedis_transition(%L, 'iptal', 'Ödemeli hakediş iptal denemesi') $$, pg_temp.c('h1')),
  '23514', null, 'ödemesi olan hakediş iptal edilemez');
select lives_ok(format($$ select public.cancel_teminat_release(%L, 'Yanlış tutar girildi, geri alındı') $$, pg_temp.c('rel2')),
  'ödenmemiş teminat iadesi ters kayıtla iptal edilir');
select is((select retention_balance from public.contract_finance_summary(pg_temp.c('cBf'))), 150000.00,
  'iptal edilen serbest bırakmanın tutarı teminat bakiyesine döner');
select lives_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 50000, %L, '2026-10-16', null, %L) $$,
         pg_temp.c('pay2'), pg_temp.c('cBf'), pg_temp.c('srcSirket'), pg_temp.c('rel1')),
  'serbest bırakılan teminatın nakit ödemesi ayrı bir olay olarak kaydedilir');

-- ---------------------------------------------------------------- 2. revizyon, kümülatif, limit, avans
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(format($$ select public.contract_transition(%L, 'revizyon', 'kısa') $$, pg_temp.c('cBf')),
  '23514', null, 'revizyon gerekçesiz açılamaz');
select lives_ok(format($$ select public.contract_transition(%L, 'revizyon', 'Beton birim fiyatı Ekim zammı') $$, pg_temp.c('cBf')),
  'muhasebe fiyat revizyonu açar');
select lives_ok(
  format($$ select public.save_contract(%L, %L, %L, 'TEST-S-1', 'Kaba yapı betonu', %L,
            p_total_amount => 1500000, p_retention_rate => 20) $$,
         pg_temp.c('cBf'), pg_temp.c('pA'), pg_temp.c('sub'),
         jsonb_build_array(pg_temp.bf('iBeton', 'C30 beton dökümü', 'm3', 150, 12000))),
  'revizyonda birim fiyat 12.000');
select tests.authenticate_as(pg_temp.c('admin'));
select is((public.contract_transition(pg_temp.c('cBf'), 'onayla')).status::text, 'aktif', 'revizyon onaylanır');
select is((select unit_price from pg_temp.line('h1', 'iBeton')), 10000.0000::numeric,
  'yeni revizyon eski hakedişin fiyatını değiştirmez');
select is((select gross_amount from pg_temp.h('h1')), 1000000.00, 'eski hakedişin tutarı aynı kalır');

select tests.authenticate_as(pg_temp.c('sef'));
select lives_ok(
  format($$ select public.save_work_quantity(%L, %L, %L, '2026-10-12', 60, 'C blok') $$, pg_temp.c('wq2'), pg_temp.c('cBf'), pg_temp.c('iBeton')),
  'ikinci dönem 60 m³ imalat');
select tests.authenticate_as(pg_temp.c('mudur'));
select is(public.approve_work_quantities(array[pg_temp.c('wq2')]), 1, 'imalat onaylanır');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(
  format($$ select public.record_finance_payment(%L, %L, 'avans', 100000, %L, '2026-10-01') $$, pg_temp.c('adv1'), pg_temp.c('cBf'), pg_temp.c('srcSirket')),
  '100.000 avans verilir');
select lives_ok(format($$ select public.create_hakedis(%L, %L, '2026-10-01', '2026-10-31') $$, pg_temp.c('h2'), pg_temp.c('cBf')),
  'ikinci hakediş açılır');
select results_eq(
  $$ select quantity, previous_quantity, cumulative_quantity, unit_price, amount, previous_amount from pg_temp.line('h2', 'iBeton') $$,
  $$ values (60.0000::numeric, 100.0000::numeric, 160.0000::numeric, 12000.0000::numeric, 720000.00::numeric, 1000000.00::numeric) $$,
  'kümülatif: önceki 100, bu dönem 60, toplam 160; yalnızca yeni imalat kullanılır');
select is((select limit_exceeded from pg_temp.h('h2')), true, 'sözleşme miktarı (150) ve bedeli (1.500.000) aşıldı olarak işaretlenir');
select throws_ok(format($$ select public.set_hakedis_deduction(%L, 'avans_mahsubu', 100000.01) $$, pg_temp.c('h2')),
  '23514', null, 'açık avanstan fazla mahsup girilemez');
select lives_ok(format($$ select public.set_hakedis_deduction(%L, 'avans_mahsubu', 100000) $$, pg_temp.c('h2')),
  '100.000 avans mahsubu girilir');
select results_eq(
  $$ select gross_amount, retention_amount, advance_amount, payable_amount from pg_temp.h('h2') $$,
  $$ values (720000.00::numeric, 144000.00::numeric, 100000.00::numeric, 476000.00::numeric) $$,
  'brüt 720.000, teminat 144.000, avans mahsubu 100.000, ödemeye uygun 476.000');
select lives_ok(format($$ select public.hakedis_transition(%L, 'gonder') $$, pg_temp.c('h2')), 'incelemeye gönderilir');
select throws_ok(format($$ select public.override_hakedis_limit(%L, 'Ek metraj onaylandı') $$, pg_temp.c('h2')),
  '42501', null, 'muhasebe limit izni veremez');
select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(format($$ select public.hakedis_transition(%L, 'onayla') $$, pg_temp.c('h2')),
  '23514', null, 'limit aşımı izin veya revizyon olmadan onaylanmaz');
select lives_ok(format($$ select public.override_hakedis_limit(%L, 'Ek metraj saha tutanağıyla onaylandı') $$, pg_temp.c('h2')),
  'yönetici gerekçeli limit izni verir');
select is((public.hakedis_transition(pg_temp.c('h2'), 'onayla')).status::text, 'onaylandi', 'izinli hakediş onaylanır');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(format($$ select public.post_hakedis(%L, '2026-11-01') $$, pg_temp.c('h2')), 'ikinci hakediş deftere işlenir');
select tests.clear_authentication();
select is(
  (select sum(a.amount) from public.cari_allocations a
     join public.cari_entries e on e.id = a.payment_entry_id
    where e.id = pg_temp.c('adv1') and a.deleted_at is null),
  100000.00, 'avans hakediş hareketine mahsup edilir');
select is(pg_temp.balance('cari'), -500000.00 - 50000.00 + 50000.00 - 720000.00 + 144000.00 + 100000.00,
  'cari: önceki bakiye + yeni hakediş − teminat; avans zaten borç olarak işlenmişti');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(format($$ select public.cancel_finance_payment(%L, 'Avans iptal denemesi yapılıyor') $$, pg_temp.c('adv1')),
  '23514', null, 'mahsup edilmiş avans iptal edilemez');

-- iptal ve ters kayıt
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(format($$ select public.hakedis_transition(%L, 'iptal', 'Metraj hatası var, iptal') $$, pg_temp.c('h2')),
  '42501', null, 'onaylı hakedişi muhasebe iptal edemez');
select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(format($$ select public.hakedis_transition(%L, 'iptal', 'kısa') $$, pg_temp.c('h2')),
  '23514', null, 'onaylı hakediş gerekçesiz iptal edilemez');
select is((public.hakedis_transition(pg_temp.c('h2'), 'iptal', 'C blok metrajı hatalı ölçülmüş')).status::text, 'iptal',
  'yönetici onaylı hakedişi gerekçeyle iptal eder');
select tests.clear_authentication();
select is((select count(*)::int from public.cari_entries e
            where e.kind = 'ters_kayit' and e.reversal_of_id in (
              select id from public.cari_entries where source_id = pg_temp.c('h2')
              union select cari_entry_id from public.hakedis_adjustments where hakedis_id = pg_temp.c('h2'))), 2,
  'iptal ters kayıtla yapılır: hakediş ve teminat kesintisi hareketleri silinmez, tersleri eklenir');
select is(pg_temp.balance('cari'), -500000.00 + 100000.00, 'iptal sonrası cari bakiye geri döner (avans açık kalır)');
select is((select count(*)::int from public.hakedis_quantity_links where work_quantity_id = pg_temp.c('wq2') and active), 0,
  'iptal edilen hakedişin imalatı yeniden kullanılabilir');
select is((select sum(a.amount) from public.cari_allocations a where a.payment_entry_id = pg_temp.c('adv1') and a.deleted_at is null),
  null, 'iptalde avans mahsubu çözülür');
select throws_ok(format($$ update public.cari_entries set amount = 1 where source_id = %L $$, pg_temp.c('h2')),
  '42501', null, 'cari defter değiştirilemez');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(format($$ select public.create_hakedis(%L, %L, '2026-10-01', '2026-10-31') $$, pg_temp.c('hS'), pg_temp.c('cBf')),
  'iptalden sonra aynı dönem için yeni hakediş açılır');
select is((select quantity from pg_temp.line('hS', 'iBeton')), 60.0000::numeric, 'serbest kalan imalat yeni hakedişe gelir');
select tests.clear_authentication();
select throws_ok(
  format($$ insert into public.hakedis_quantity_links (hakedis_id, work_quantity_id, item_key, quantity)
            values (%L, %L, %L, 100) $$, pg_temp.c('hS'), pg_temp.c('wq1'), pg_temp.c('iBeton')),
  '23505', null, 'onaylı hakedişte kullanılan imalat ikinci kez bağlanamaz');

-- ---------------------------------------------------------------- 3. karma sözleşme: günlük + götürü + birim fiyat
-- Eylül puantajı: İşçi 1 tam, tam (2 sa onaylı FM), yarım, resmî tatil, ücretli
-- izin, çalışmadı; İşçi 2 tam, tam (3 sa onaysız FM).
select tests.authenticate_as(pg_temp.c('admin'));
select is((select count(*)::int from public.save_puantaj(pg_temp.c('pA'), jsonb_build_array(
    jsonb_build_object('personnel_id', pg_temp.c('w1'), 'work_date', '2026-09-01', 'status', 'tam_gun', 'overtime_hours', 2),
    jsonb_build_object('personnel_id', pg_temp.c('w1'), 'work_date', '2026-09-02', 'status', 'tam_gun'),
    jsonb_build_object('personnel_id', pg_temp.c('w1'), 'work_date', '2026-09-03', 'status', 'yarim_gun'),
    jsonb_build_object('personnel_id', pg_temp.c('w1'), 'work_date', '2026-09-04', 'status', 'resmi_tatil'),
    jsonb_build_object('personnel_id', pg_temp.c('w1'), 'work_date', '2026-09-07', 'status', 'ucretli_izin'),
    jsonb_build_object('personnel_id', pg_temp.c('w1'), 'work_date', '2026-09-08', 'status', 'calismadi'),
    jsonb_build_object('personnel_id', pg_temp.c('w2'), 'work_date', '2026-09-01', 'status', 'tam_gun'),
    jsonb_build_object('personnel_id', pg_temp.c('w2'), 'work_date', '2026-09-02', 'status', 'tam_gun', 'overtime_hours', 3)))
    where result = 'eklendi'), 8, 'Eylül puantajı girilir');
select is(public.approve_puantaj_overtime(array(select id from public.puantaj_entries
            where personnel_id = pg_temp.c('w1') and work_date = '2026-09-01')), 1, 'yalnızca İşçi 1''in fazla mesaisi onaylanır');
select lives_ok(
  format($$ select public.save_contract(%L, %L, %L, 'TEST-S-2', 'Karma işçilik', %L,
            p_retention_rate => 10, p_tax_codes => array['TKDV20', 'TSTP3']) $$,
         pg_temp.c('cKarma'), pg_temp.c('pA'), pg_temp.c('sub'),
         jsonb_build_array(pg_temp.gn('iGun', 2000, 300, array['calisilan_gun', 'resmi_tatil']),
                           pg_temp.gt('iIskele', 'İskele kurulumu', 100000),
                           pg_temp.bf('iSiva', 'İç sıva', 'm2', 200, 150))),
  'karma sözleşme: günlük (FM 300/sa, resmî tatil ücretli), götürü ve birim fiyat; KDV %20, stopaj %3, teminat %10');
select is((public.contract_transition(pg_temp.c('cKarma'), 'onayla')).status::text, 'aktif', 'karma sözleşme onaylanır');
select lives_ok(format($$ select public.create_hakedis(%L, %L, '2026-09-01', '2026-09-30') $$, pg_temp.c('hK1'), pg_temp.c('cKarma')),
  'karma sözleşmede hakediş açılır');
select is((select quantity from pg_temp.line('hK1', 'iGun')), 0.0000::numeric, 'onaylanmamış (taslak) puantaj hakedişe kaynak olmaz');
select lives_ok(format($$ select public.puantaj_transition(%L, '2026-09-01', 'onayla') $$, pg_temp.c('pA')), 'Eylül puantajı onaylanır');
select lives_ok(format($$ select public.set_hakedis_progress(%L, %L, 40) $$, pg_temp.c('hK1'), pg_temp.c('iIskele')),
  'götürü kalemde %40 ilerleme');
select results_eq(
  $$ select quantity, amount from pg_temp.line('hK1', 'iGun') $$,
  $$ values (5.5000::numeric, 11000.00::numeric) $$,
  'günlük: 1 + 1 + 0,5 + 1 (resmî tatil ücretli) + 2 = 5,5 adam-gün; ücretli izin ve çalışmadı ücretlendirilmez');
select results_eq(
  $$ select quantity, amount from pg_temp.line('hK1', 'iGun', 'fazla_mesai') $$,
  $$ values (2.0000::numeric, 600.00::numeric) $$,
  'fazla mesai: yalnızca onaylı 2 saat × 300');
select results_eq(
  $$ select quantity, amount from pg_temp.line('hK1', 'iIskele') $$,
  $$ values (40.0000::numeric, 40000.00::numeric) $$,
  'götürü: %40 × 100.000');
select is((select quantity from pg_temp.line('hK1', 'iSiva')), 0.0000::numeric, 'imalatı olmayan birim fiyat kalemi sıfır');
select results_eq(
  $$ select gross_amount, kdv_amount, tax_deduction_amount, retention_amount, payable_amount from pg_temp.h('hK1') $$,
  $$ values (51600.00::numeric, 10320.00::numeric, 1548.00::numeric, 5160.00::numeric, 55212.00::numeric) $$,
  'brüt 51.600; KDV 10.320 eklenir; stopaj 1.548 ve teminat 5.160 düşülür; ödemeye uygun 55.212');
select is(
  (select count(*)::int from public.hakedis_puantaj_links where hakedis_id = pg_temp.c('hK1') and period_revision = 0), 6,
  'hakediş ücrete etki eden 6 puantaj kaydını ve ay revizyonunu saklar (ücretsiz izin/çalışmadı bağlanmaz)');
select throws_ok(format($$ select public.set_hakedis_progress(%L, %L, 100.5) $$, pg_temp.c('hK1'), pg_temp.c('iIskele')),
  '23514', null, 'götürü ilerleme %100''ü aşamaz');
select lives_ok(format($$ select public.hakedis_transition(%L, 'gonder') $$, pg_temp.c('hK1')), 'gönderilir');
select tests.authenticate_as(pg_temp.c('admin'));
select is((public.hakedis_transition(pg_temp.c('hK1'), 'onayla')).status::text, 'onaylandi', 'karma hakediş onaylanır');

-- puantaj düzeltmesi: eski hakediş sessizce değişmez, fark sonraki hakedişe gelir
select lives_ok(format($$ select public.puantaj_transition(%L, '2026-09-01', 'yeniden_ac', 'İşçi 1 3 Eylül tam gün çalışmış') $$, pg_temp.c('pA')),
  'Eylül puantajı gerekçeyle yeniden açılır');
select is((select result from public.save_puantaj(pg_temp.c('pA'), jsonb_build_array(
    jsonb_build_object('personnel_id', pg_temp.c('w1'), 'work_date', '2026-09-03', 'status', 'tam_gun',
                       'expected_version', (select version from public.puantaj_entries
                                             where personnel_id = pg_temp.c('w1') and work_date = '2026-09-03'))))),
  'guncellendi', '3 Eylül yarım → tam düzeltilir');
select lives_ok(format($$ select public.puantaj_transition(%L, '2026-09-01', 'onayla') $$, pg_temp.c('pA')), 'Eylül yeniden onaylanır');
select is((select gross_amount from pg_temp.h('hK1')), 51600.00, 'onaylı eski hakediş değişmez');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(format($$ select public.create_hakedis(%L, %L, '2026-10-01', '2026-10-31') $$, pg_temp.c('hK2'), pg_temp.c('cKarma')),
  'sonraki dönem hakedişi açılır');
select results_eq(
  format($$ select personnel_id, work_date, day_delta, is_correction, period_revision from public.hakedis_puantaj_links
             where hakedis_id = %L $$, pg_temp.c('hK2')),
  format($$ values (%L::uuid, '2026-09-03'::date, 0.50::numeric, true, 1) $$, pg_temp.c('w1')),
  'yalnızca düzeltilen gün +0,5 fark olarak gelir (yeni ay revizyonuyla)');
select results_eq(
  $$ select quantity, previous_quantity, cumulative_quantity, amount from pg_temp.line('hK2', 'iGun') $$,
  $$ values (0.5000::numeric, 5.5000::numeric, 6.0000::numeric, 1000.00::numeric) $$,
  'fark satırı: 0,5 × 2.000; kümülatif 6 adam-gün');
select is((select quantity from pg_temp.line('hK2', 'iIskele')), 0.0000::numeric, 'götürü önceki ilerlemede kalır');
select throws_ok(format($$ select public.set_hakedis_progress(%L, %L, 30) $$, pg_temp.c('hK2'), pg_temp.c('iIskele')),
  '23514', null, 'götürü ilerleme önceki onaylı düzeyin altına inemez');
select tests.clear_authentication();
select throws_ok(
  format($$ insert into public.hakedis_puantaj_links (hakedis_id, contract_item_id, item_key, puantaj_entry_id, entry_version,
              period_id, period_revision, personnel_id, personnel_name, work_date, status, pay_basis, day_delta)
            select %L, l.contract_item_id, l.item_key, l.puantaj_entry_id, l.entry_version, l.period_id, l.period_revision,
                   l.personnel_id, l.personnel_name, l.work_date, l.status, l.pay_basis, 1
              from public.hakedis_puantaj_links l where l.hakedis_id = %L limit 1 $$, pg_temp.c('hK2'), pg_temp.c('hK1')),
  '23505', null, 'aynı puantaj kaydı (aynı sürüm) ikinci hakedişe bağlanamaz');

-- düzeltme hakedişi (revise)
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(format($$ select public.hakedis_transition(%L, 'gonder') $$, pg_temp.c('hK2')), 'fark hakedişi gönderilir');
select tests.authenticate_as(pg_temp.c('admin'));
select is((public.hakedis_transition(pg_temp.c('hK2'), 'onayla')).status::text, 'onaylandi', 'fark hakedişi onaylanır');
select is((public.revise_hakedis(pg_temp.c('hK2'), pg_temp.c('hK3'), 'Fark hakedişi yanlış döneme alındı')).replaces_id,
  pg_temp.c('hK2'), 'düzeltme: eski hakediş iptal, yerine yeni taslak');
select results_eq(
  format($$ select status::text from public.hakedis where id in (%L, %L) order by hakedis_no $$, pg_temp.c('hK2'), pg_temp.c('hK3')),
  $$ values ('iptal'), ('taslak') $$, 'eski hakediş iptal, yenisi taslak');
select is((select day_delta from public.hakedis_puantaj_links where hakedis_id = pg_temp.c('hK3')), 0.50::numeric,
  'iptal edilen hakedişin puantaj farkı yeni taslağa geçer');

-- ---------------------------------------------------------------- 4. yetki, RLS, DEMO
select tests.authenticate_as(pg_temp.c('mudurB'));
select is((select count(*)::int from public.contracts where project_id = pg_temp.c('pA')), 0,
  'başka projenin yetkilisi sözleşmeyi göremez');
select is((select count(*)::int from public.hakedis), 0, 'başka projenin yetkilisi hakedişi göremez');
select throws_ok(format($$ select * from public.contract_finance_summary(%L) $$, pg_temp.c('cBf')),
  '42501', null, 'başka projenin finans özeti görülemez');
select throws_ok(format($$ select public.create_hakedis(%L, %L, '2026-11-01', '2026-11-30') $$, gen_random_uuid(), pg_temp.c('cKarma')),
  '42501', null, 'doğrudan API çağrısıyla başka projeye hakediş açılamaz');
select tests.authenticate_as(pg_temp.c('passive'));
select is((select count(*)::int from public.hakedis), 0, 'pasif kullanıcı hakediş göremez');
select throws_ok(format($$ select public.post_hakedis(%L) $$, pg_temp.c('h1')), 'P0002', null, 'pasif kullanıcı deftere işleyemez');
select tests.authenticate_as(pg_temp.c('outsider'));
select is((select count(*)::int from public.finance_payments), 0, 'rolsüz kullanıcı ödemeleri göremez');
select throws_ok(
  format($$ select public.record_finance_payment(%L, %L, 'odeme', 1, %L) $$, gen_random_uuid(), pg_temp.c('cBf'), pg_temp.c('srcSirket')),
  '42501', null, 'rolsüz kullanıcı ödeme kaydedemez');
select tests.authenticate_as(pg_temp.c('mudur'));
select is((select count(*)::int from public.hakedis where project_id = pg_temp.c('pA')) > 0, true,
  'proje müdürü kendi projesinin hakedişini görür');
select throws_ok(format($$ select public.release_teminat(%L, %L, 1, 'Proje müdürü denemesi') $$, gen_random_uuid(), pg_temp.c('cBf')),
  '42501', null, 'proje müdürü teminat serbest bırakamaz');

select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(
  format($$ select public.save_contract(null, %L, %L, 'TEST-S-DEMO-1', 'Karışık', %L) $$, pg_temp.c('pDemo'), pg_temp.c('sub'),
         jsonb_build_array(pg_temp.bf('iKucuk', 'Kalem', 'adet', 1, 1))),
  '23514', null, 'gerçek taşeron demo projede sözleşme alamaz');
select is(
  (public.save_contract(null, pg_temp.c('pDemo'), pg_temp.c('subDemo'), 'TEST-S-DEMO-2', 'Demo sözleşme',
     jsonb_build_array(pg_temp.bf('iKucuk', 'Kalem', 'adet', 1, 1)))).is_demo,
  true, 'demo proje + demo taşeron: sözleşme demo işaretli');

-- ---------------------------------------------------------------- 5. yuvarlama, doğrulanmamış vergi, bütünlük
select lives_ok(
  format($$ select public.save_contract(%L, %L, %L, 'TEST-S-3', 'Yuvarlama', %L, p_retention_rate => 12.5) $$,
         pg_temp.c('cKucuk'), pg_temp.c('pB'), pg_temp.c('sub'),
         jsonb_build_array(pg_temp.bf('iKucuk', 'Ankraj', 'adet', 10, 33.3333))),
  'birim fiyat 33,3333 ve %12,5 teminatlı sözleşme');
select lives_ok(format($$ select public.contract_transition(%L, 'onayla') $$, pg_temp.c('cKucuk')), 'onaylanır');
select lives_ok(format($$ select public.save_work_quantity(%L, %L, %L, '2026-10-01', 3) $$, pg_temp.c('wq3'), pg_temp.c('cKucuk'), pg_temp.c('iKucuk')),
  '3 adet imalat');
select is(public.approve_work_quantities(array[pg_temp.c('wq3')]), 1, 'imalat onaylanır');
select lives_ok(format($$ select public.create_hakedis(%L, %L, '2026-10-01', '2026-10-31') $$, gen_random_uuid(), pg_temp.c('cKucuk')),
  'yuvarlama hakedişi');
select results_eq(
  format($$ select gross_amount, retention_amount, payable_amount from public.hakedis where contract_id = %L $$, pg_temp.c('cKucuk')),
  $$ values (100.00::numeric, 12.50::numeric, 87.50::numeric) $$,
  '3 × 33,3333 = 99,9999 → 100,00; teminat 12,50; ödemeye uygun 87,50');
select lives_ok(format($$ select public.contract_transition(%L, 'revizyon', 'Doğrulanmamış vergi denemesi') $$, pg_temp.c('cKucuk')),
  'revizyon açılır');
select lives_ok(
  format($$ select public.save_contract(%L, %L, %L, 'TEST-S-3', 'Yuvarlama', %L, p_retention_rate => 12.5, p_tax_codes => array['TKDVX']) $$,
         pg_temp.c('cKucuk'), pg_temp.c('pB'), pg_temp.c('sub'),
         jsonb_build_array(pg_temp.bf('iKucuk', 'Ankraj', 'adet', 10, 33.3333))),
  'revizyona doğrulanmamış KDV kuralı eklenir');
select lives_ok(format($$ select public.contract_transition(%L, 'onayla') $$, pg_temp.c('cKucuk')), 'revizyon onaylanır');
select throws_ok(
  format($$ select public.refresh_hakedis(id) from public.hakedis where contract_id = %L $$, pg_temp.c('cKucuk')),
  '23514', null, 'doğrulanmamış vergi oranı hakedişte kullanılmaz (varsayım yapılmaz)');
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok(
  $$ select public.save_tax_rule(null, 'TKDV1', 'Deneme', 'kdv', 1, '2026-01-01') $$,
  '42501', null, 'şantiye şefi vergi kuralı tanımlayamaz');
select tests.clear_authentication();
select is_empty(
  $$ select id from public.hakedis
      where payable_amount <> gross_amount + kdv_amount - tax_deduction_amount - other_deduction_amount
                               - retention_amount - advance_amount $$,
  'her hakedişte ödemeye uygun = brüt + KDV − stopaj − diğer − teminat − avans');
select is_empty(
  $$ select h.id from public.hakedis h
      where h.retention_amount <> coalesce((select sum(amount) from public.hakedis_adjustments a
                                             where a.hakedis_id = h.id and a.kind = 'teminat'), 0)
         or h.gross_amount <> coalesce((select sum(amount) from public.hakedis_lines l where l.hakedis_id = h.id), 0) $$,
  'hakediş toplamları satır ve kesintilerin toplamına eşit');
select is_empty(
  $$ select e.id from public.cari_entries e join public.hakedis h on h.id = e.source_id and e.source_type = 'hakedis'
      where e.amount <> h.gross_amount + h.kdv_amount $$,
  'defterdeki hakediş hareketi brüt + KDV''ye eşit');
select is_empty(
  $$ select table_name from information_schema.columns
      where table_schema = 'public' and table_name like 'puantaj%' and column_name ~ '(amount|price|tutar)' $$,
  'puantaj tabloları hâlâ tutar içermez; tutar yalnızca hakedişte hesaplanır');

select * from finish();
rollback;
