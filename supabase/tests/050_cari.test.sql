-- Cari hesaplar ve cari defter: çift borç engeli, değişmezlik, ters kayıt,
-- kısmi ödeme eşleştirmesi, bakiye hesabı ve finansal verinin RLS ile korunması.
begin;
select plan(67);

-- ---------------------------------------------------------------- hazırlık
create temp table ctx (k text primary key, v uuid) on commit drop;
grant select, insert on ctx to authenticated;

insert into ctx values
  ('muhasebe', tests.create_user('cari-muhasebe@test.invalid')),
  ('sef',      tests.create_user('cari-sef@test.invalid')),
  ('viewer',   tests.create_user('cari-viewer@test.invalid')),
  ('outsider', tests.create_user('cari-rolsuz@test.invalid')),
  ('passive',  tests.create_user('cari-pasif@test.invalid')),
  ('denied',   tests.create_user('cari-yasakli@test.invalid')),
  ('projfin',  tests.create_user('cari-proje-finans@test.invalid')),
  ('pA',       tests.create_project('TEST-CARI-A')),
  ('pB',       tests.create_project('TEST-CARI-B'));

insert into public.cost_centers (code, name) values ('TEST-GENEL', 'Test genel gider');
insert into ctx select 'cc', id from public.cost_centers where code = 'TEST-GENEL';

select tests.grant_global_role((select v from ctx where k = 'muhasebe'), 'muhasebe');
select tests.grant_global_role((select v from ctx where k = 'passive'),  'muhasebe');
select tests.grant_global_role((select v from ctx where k = 'denied'),   'muhasebe');
update public.profiles set is_active = false where id = (select v from ctx where k = 'passive');
insert into public.user_permission_overrides (user_id, permission_key, effect, reason)
values ((select v from ctx where k = 'denied'), 'cari_hareket.read', 'deny', 'test: finans okuması kapalı');

select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'sef'),     'santiye_sefi');
select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'viewer'),  'goruntuleyici');
select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'projfin'), 'santiye_sefi');
-- Yalnızca A projesinde finans okuması olan kullanıcı (kullanıcıya özel izin).
insert into public.user_permission_overrides (user_id, permission_key, project_id, effect, reason)
select (select v from ctx where k = 'projfin'), p, (select v from ctx where k = 'pA'), 'grant', 'test: proje finansı'
  from unnest(array['cari.read', 'cari_hareket.read']) p;

-- Cari kartlar muhasebe tarafından açılır.
select tests.authenticate_as((select v from ctx where k = 'muhasebe'));
insert into public.cari_accounts (code, title, type) values
  ('TEST-C1', 'Test Kaba İnşaat Taşeronu', 'taseron'),
  ('TEST-C2', 'Test Tedarikçi', 'tedarikci'),
  ('TEST-C3', 'Test Döviz Tedarikçisi', 'tedarikci');
insert into ctx select 'c3', id from public.cari_accounts where code = 'TEST-C3';
insert into ctx select 'c1', id from public.cari_accounts where code = 'TEST-C1';
insert into ctx select 'c2', id from public.cari_accounts where code = 'TEST-C2';
insert into ctx values ('e_pay', gen_random_uuid()), ('e_gen', gen_random_uuid()),
                       ('e_b', gen_random_uuid()), ('e_rev', gen_random_uuid()), ('e_usd', gen_random_uuid());

-- Kaynak belgeden gelen hareket (hakediş modülü Aşama 2'de bunu yapacak).
select tests.clear_authentication();
insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind,
                                 amount, description, source_type, source_id)
values (gen_random_uuid(), (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA'),
        '2026-10-01', 'alacak', 'hakedis', 100000, 'Test hakediş 1', 'hakedis',
        '00000000-0000-4000-8000-0000000000aa');
insert into ctx select 'e_hak', id from public.cari_entries where source_id = '00000000-0000-4000-8000-0000000000aa';

-- ---------------------------------------------------------------- kart kuralları
select hasnt_column('public', 'cari_accounts', 'balance', 'cari kartında düzenlenebilir bakiye alanı yok');
select hasnt_column('public', 'cari_entries', 'balance', 'cari harekette saklanan bakiye alanı yok');
select throws_ok($$ insert into public.cari_accounts (title, type, tax_number) values ('x', 'diger', '12AB') $$,
  '23514', null, 'geçersiz vergi numarası reddedilir');
select ok((select code from public.cari_accounts where title = 'Test Tedarikçi') = 'TEST-C2', 'kod elle verilebilir');
insert into public.cari_accounts (title, type) values ('Test Otomatik Kod', 'diger');
select matches((select code from public.cari_accounts where title = 'Test Otomatik Kod'), '^C-[0-9]{5}$',
  'kod verilmezse otomatik C-00000 biçiminde üretilir');

-- ---------------------------------------------------------------- deftere işleme
select tests.authenticate_as((select v from ctx where k = 'muhasebe'));
select lives_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-05', 'borc', 'odeme', 40000, 'Test kısmi ödeme',
                                          p_project_id => %L) $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  'muhasebe projeye ödeme işler');
select lives_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-05', 'borc', 'odeme', 40000, 'Test kısmi ödeme',
                                          p_project_id => %L) $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  'aynı kimlikle yeniden gönderim hata vermez');
select is((select count(*)::int from public.cari_entries where id = (select v from ctx where k = 'e_pay')), 1,
  'yeniden gönderim ikinci kayıt açmaz');
select throws_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-05', 'borc', 'odeme', 45000, 'Farklı tutar',
                                          p_project_id => %L) $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '23505', null, 'aynı kimlikle farklı içerik reddedilir');
select throws_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-05', 'borc', 'odeme', 40000, 'Başka açıklama',
                                          p_project_id => %L) $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '23505', null, 'aynı kimlikle farklı açıklama reddedilir');
select throws_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-05', 'borc', 'odeme', 40000, 'Test kısmi ödeme',
                                          p_project_id => %L, p_document_no => 'DKN-9') $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '23505', null, 'aynı kimlikle farklı belge no reddedilir');
select lives_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-05', 'borc', 'odeme', 40000, '  Test kısmi ödeme  ',
                                          p_project_id => %L, p_document_no => '  ') $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  'boşluk farkı olan aynı istek tekrar sayılır (saklanan biçimle karşılaştırılır)');
select lives_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-05', 'borc', 'odeme', 1000, 'Test döviz ödemesi',
                                          p_project_id => %L, p_currency => 'usd', p_exchange_rate => 41.5) $$,
         (select v from ctx where k = 'e_usd'), (select v from ctx where k = 'c3'), (select v from ctx where k = 'pB')),
  'döviz hareketi kurla işlenir');
select lives_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-05', 'borc', 'odeme', 1000, 'Test döviz ödemesi',
                                          p_project_id => %L, p_currency => 'USD', p_exchange_rate => 41.500000) $$,
         (select v from ctx where k = 'e_usd'), (select v from ctx where k = 'c3'), (select v from ctx where k = 'pB')),
  'aynı döviz isteğinin tekrarı kabul edilir');
select throws_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-05', 'borc', 'odeme', 1000, 'Test döviz ödemesi',
                                          p_project_id => %L, p_currency => 'USD', p_exchange_rate => 42) $$,
         (select v from ctx where k = 'e_usd'), (select v from ctx where k = 'c3'), (select v from ctx where k = 'pB')),
  '23505', null, 'aynı kimlikle farklı kur reddedilir');
select is((select count(*)::int from public.cari_entries
            where id in ((select v from ctx where k = 'e_pay'), (select v from ctx where k = 'e_usd'))), 2,
  'tekrar denemeler ek kayıt açmadı');
select lives_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-06', 'alacak', 'manuel', 2500, 'Test ofis kırtasiye',
                                          p_cost_center_id => %L) $$,
         (select v from ctx where k = 'e_gen'), (select v from ctx where k = 'c2'), (select v from ctx where k = 'cc')),
  'projeye bağlı olmayan genel gider hareketi işlenir');
select lives_ok(
  format($$ select public.post_cari_entry(%L, %L, '2026-10-07', 'alacak', 'manuel', 7000, 'Test B projesi malzeme',
                                          p_project_id => %L) $$,
         (select v from ctx where k = 'e_b'), (select v from ctx where k = 'c2'), (select v from ctx where k = 'pB')),
  'B projesine hareket işlenir');

select throws_ok(
  format($$ select public.post_cari_entry(gen_random_uuid(), %L, '2026-10-05', 'alacak', 'hakedis', 1, 'x', p_project_id => %L) $$,
         (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '22023', null, 'hakediş türü elle girilemez');
select throws_ok(
  format($$ select public.post_cari_entry(gen_random_uuid(), %L, '2026-10-05', 'alacak', 'avans', 1, 'x', p_project_id => %L) $$,
         (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '23514', null, 'avans alacak yönünde girilemez');
select throws_ok(
  format($$ select public.post_cari_entry(gen_random_uuid(), %L, '2026-10-05', 'borc', 'manuel', 1, 'x',
                                          p_project_id => %L, p_cost_center_id => %L) $$,
         (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA'), (select v from ctx where k = 'cc')),
  '23514', null, 'hareket aynı anda proje ve masraf merkezine bağlanamaz');
select throws_ok(
  format($$ select public.post_cari_entry(gen_random_uuid(), %L, '2026-10-05', 'borc', 'manuel', 1, 'x') $$,
         (select v from ctx where k = 'c1')),
  '23514', null, 'hareket proje ya da masraf merkezi olmadan girilemez');
select throws_ok(
  format($$ select public.post_cari_entry(gen_random_uuid(), %L, '2026-10-05', 'borc', 'manuel', 0, 'x', p_project_id => %L) $$,
         (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '23514', null, 'sıfır tutar reddedilir');
select throws_ok(
  format($$ select public.post_cari_entry(gen_random_uuid(), %L, '2026-10-05', 'borc', 'manuel', 10, 'x',
                                          p_project_id => %L, p_exchange_rate => 2) $$,
         (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '23514', null, 'TL harekette kur 1 dışında olamaz');

-- ---------------------------------------------------------------- doğrudan yazma ve değişmezlik
select throws_ok(
  format($$ insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind, amount, description)
            values (gen_random_uuid(), %L, %L, '2026-10-05', 'borc', 'manuel', 1, 'x') $$,
         (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '42501', null, 'istemci deftere doğrudan yazamaz');
select throws_ok($$ update public.cari_entries set amount = 1 $$, '42501', null, 'istemci hareketi değiştiremez');
select throws_ok($$ delete from public.cari_entries $$, '42501', null, 'istemci hareketi silemez');

select tests.clear_authentication();
select throws_ok(format($$ update public.cari_entries set amount = 1 where id = %L $$, (select v from ctx where k = 'e_pay')),
  '42501', null, 'veritabanı sahibi bile hareketi değiştiremez (defter değişmez)');
select throws_ok(format($$ delete from public.cari_entries where id = %L $$, (select v from ctx where k = 'e_pay')),
  '42501', null, 'veritabanı sahibi bile hareketi silemez');

-- ---------------------------------------------------------------- aynı kaynak iki kez borç oluşturamaz
select throws_ok(
  format($$ insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind,
                                             amount, description, source_type, source_id)
            values (gen_random_uuid(), %L, %L, '2026-10-01', 'alacak', 'hakedis', 100000, 'Çift hakediş',
                    'hakedis', '00000000-0000-4000-8000-0000000000aa') $$,
         (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '23505', null, 'aynı kaynak belge deftere ikinci kez işlenemez');
select throws_ok(
  format($$ insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind,
                                             amount, description, source_type, source_id)
            values (gen_random_uuid(), %L, %L, '2026-10-01', 'alacak', 'hakedis', 100000, 'Başka cariye çift hakediş',
                    'hakedis', '00000000-0000-4000-8000-0000000000aa') $$,
         (select v from ctx where k = 'c2'), (select v from ctx where k = 'pA')),
  '23505', null, 'aynı kaynak başka bir cariye de ikinci kez işlenemez');
select throws_ok(
  format($$ insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind,
                                             amount, description, source_type)
            values (gen_random_uuid(), %L, %L, '2026-10-01', 'alacak', 'hakedis', 1, 'Yarım kaynak', 'hakedis') $$,
         (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '23514', null, 'kaynak türü kimliksiz girilemez');

-- ---------------------------------------------------------------- bakiye ve ekstre
select tests.authenticate_as((select v from ctx where k = 'muhasebe'));
select results_eq(
  format($$ select total_borc_try, total_alacak_try, balance_try from public.cari_balances() where cari_account_id = %L $$,
         (select v from ctx where k = 'c1')),
  $$ values (40000.00::numeric, 100000.00::numeric, -60000.00::numeric) $$,
  'bakiye hareketlerden hesaplanır (borç − alacak)');
select results_eq(
  format($$ select balance_try from public.cari_balances(p_project_id => %L) where cari_account_id = %L $$,
         (select v from ctx where k = 'pB'), (select v from ctx where k = 'c2')),
  $$ values (-7000.00::numeric) $$, 'proje filtresi yalnızca o projenin hareketlerini toplar');
select results_eq(
  format($$ select balance_try from public.cari_balances(p_cost_center_id => %L) where cari_account_id = %L $$,
         (select v from ctx where k = 'cc'), (select v from ctx where k = 'c2')),
  $$ values (-2500.00::numeric) $$, 'genel gider (masraf merkezi) filtresi çalışır');
select is((select count(*)::int from public.cari_balances(p_until => '2026-10-04')
            where cari_account_id = (select v from ctx where k = 'c1')
              and balance_try = -100000), 1, 'tarih filtresi sonraki hareketleri dışarıda bırakır');
select results_eq(
  format($$ select kind::text, running_balance_try from public.cari_statement(%L) $$, (select v from ctx where k = 'c1')),
  $$ values ('hakedis', -100000.00::numeric), ('odeme', -60000.00::numeric) $$,
  'ekstre yürüyen bakiyeyi verir');
select results_eq(
  format($$ select kind::text, running_balance_try from public.cari_statement(%L, p_from => '2026-10-02') $$,
         (select v from ctx where k = 'c1')),
  $$ values ('odeme', -60000.00::numeric) $$,
  'tarih aralıklı ekstre devir bakiyesini korur');

-- ---------------------------------------------------------------- kısmi ödeme eşleştirmesi
select lives_ok(
  format($$ select public.allocate_cari_entry(%L, %L, 30000) $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'e_hak')),
  'ödeme hakedişe kısmi olarak eşleştirilir');
select results_eq(
  format($$ select settlement_status, open_amount from public.v_cari_entry_status where id = %L $$,
         (select v from ctx where k = 'e_hak')),
  $$ values ('kismi', 70000.00::numeric) $$, 'hakediş kısmi kapanmış görünür');
select throws_ok(
  format($$ select public.allocate_cari_entry(%L, %L, 1) $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'e_hak')),
  '23505', null, 'aynı çift ikinci kez eşleştirilemez');
select throws_ok(
  format($$ select public.allocate_cari_entry(%L, %L, 1) $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'e_gen')),
  '23514', null, 'farklı carilerin hareketleri eşleştirilemez');

-- Hakedişe ikinci bir ödeme: toplam eşleştirme hakediş tutarını aşamaz.
select lives_ok(
  format($$ select public.post_cari_entry(gen_random_uuid(), %L, '2026-10-08', 'borc', 'odeme', 80000, 'Test fazla ödeme',
                                          p_project_id => %L) $$,
         (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  'ikinci ödeme işlenir');
select throws_ok(
  format($$ select public.allocate_cari_entry(e.id, %L, 75000) from public.cari_entries e where e.description = 'Test fazla ödeme' $$,
         (select v from ctx where k = 'e_hak')),
  '23514', null, 'eşleştirme toplamı hakediş tutarını aşamaz');
select throws_ok(
  format($$ select public.allocate_cari_entry(e.id, %L, 1) from public.cari_entries e where e.description = 'Test fazla ödeme' $$,
         (select v from ctx where k = 'e_pay')),
  '23514', null, 'aynı yönlü iki hareket eşleştirilemez');

-- ---------------------------------------------------------------- ters kayıt
select lives_ok(
  format($$ select public.reverse_cari_entry(%L, 'Yanlış tutar', %L) $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'e_rev')),
  'ödeme ters kayıtla iptal edilir');
select results_eq(
  format($$ select kind::text, direction::text, amount, reversal_of_id from public.cari_entries where id = %L $$,
         (select v from ctx where k = 'e_rev')),
  format($$ values ('ters_kayit', 'alacak', 40000.00::numeric, %L::uuid) $$, (select v from ctx where k = 'e_pay')),
  'ters kayıt zıt yönde, aynı tutarda ve orijinale bağlı');
select results_eq(
  format($$ select settlement_status, open_amount from public.v_cari_entry_status where id = %L $$,
         (select v from ctx where k = 'e_hak')),
  $$ values ('acik', 100000.00::numeric) $$, 'iptal edilen ödemenin eşleştirmesi kalkar');
select lives_ok(
  format($$ select public.reverse_cari_entry(%L, 'Yanlış tutar', %L) $$,
         (select v from ctx where k = 'e_pay'), (select v from ctx where k = 'e_rev')),
  'aynı iptal isteğinin tekrarı ikinci ters kayıt açmaz');
select throws_ok(
  format($$ select public.reverse_cari_entry(%L, 'Tekrar') $$, (select v from ctx where k = 'e_pay')),
  '23514', null, 'bir hareket iki kez iptal edilemez');
select throws_ok(
  format($$ select public.reverse_cari_entry(%L, 'Ters kaydı iptal') $$, (select v from ctx where k = 'e_rev')),
  '23514', null, 'ters kayıt iptal edilemez');
select throws_ok(
  format($$ select public.reverse_cari_entry(%L, 'Hakedişi iptal') $$, (select v from ctx where k = 'e_hak')),
  '23514', null, 'kaynak belgeden gelen hareket cariden iptal edilemez');

-- ---------------------------------------------------------------- finansal verinin RLS ile korunması
select tests.authenticate_as((select v from ctx where k = 'sef'));
select is((select count(*)::int from public.cari_entries), 0, 'şantiye şefi kendi projesinde bile cari hareket görmez');
select is((select count(*)::int from public.cari_accounts where code like 'TEST-C%'), 0, 'şantiye şefi cari kart görmez');
select is((select count(*)::int from public.cari_balances()), 0, 'şantiye şefi bakiye göremez');
select throws_ok(
  format($$ select public.post_cari_entry(gen_random_uuid(), %L, '2026-10-05', 'borc', 'odeme', 1, 'x', p_project_id => %L) $$,
         (select v from ctx where k = 'c1'), (select v from ctx where k = 'pA')),
  '42501', null, 'şantiye şefi cari hareket giremez');

select tests.authenticate_as((select v from ctx where k = 'viewer'));
select is((select count(*)::int from public.cari_statement((select v from ctx where k = 'c1'))), 0,
  'görüntüleyici ekstre göremez');

select tests.authenticate_as((select v from ctx where k = 'outsider'));
select is((select count(*)::int from public.v_cari_entry_status) + (select count(*)::int from public.cari_allocations), 0,
  'rolü olmayan kullanıcı hareket ve eşleştirme göremez');

select tests.authenticate_as((select v from ctx where k = 'passive'));
select is((select count(*)::int from public.cari_entries), 0, 'pasif muhasebe kullanıcısı hareket göremez');

select tests.authenticate_as((select v from ctx where k = 'denied'));
select is((select count(*)::int from public.cari_entries), 0, 'kullanıcıya özel yasak rol iznini ezer');

select tests.authenticate_as((select v from ctx where k = 'projfin'));
select results_eq(
  $$ select distinct p.code from public.cari_entries e join public.projects p on p.id = e.project_id $$,
  $$ values ('TEST-CARI-A') $$,
  'proje finans izni yalnızca o projenin hareketlerini gösterir');
select is((select count(*)::int from public.cari_entries where cost_center_id is not null), 0,
  'proje kapsamlı kullanıcı genel gider hareketlerini görmez');
select results_eq($$ select code from public.cari_accounts where code like 'TEST-%' order by code $$,
  $$ values ('TEST-C1') $$,
  'proje kapsamlı kullanıcı yalnızca projesinde hareketi olan carinin kartını (IBAN, vergi, iletişim) görür');
select throws_ok($$ insert into public.cari_accounts (title, type) values ('Proje kullanıcısının carisi', 'diger') $$,
  '42501', null, 'proje kapsamlı kullanıcı şirket geneli cari kart açamaz');
select results_eq(
  $$ with u as (update public.cari_accounts set phone = '0' where code = 'TEST-C1' returning 1) select count(*)::int from u $$,
  $$ values (0) $$, 'proje kapsamlı kullanıcı cari kartı düzenleyemez');

-- ---------------------------------------------------------------- demo ayrımı
select tests.clear_authentication();
insert into public.cari_accounts (code, title, type, is_demo) values ('TEST-DEMO-C', 'Test demo cari', 'diger', true);
select tests.authenticate_as((select v from ctx where k = 'muhasebe'));
select throws_ok(
  format($$ select public.post_cari_entry(gen_random_uuid(), c.id, '2026-10-05', 'borc', 'manuel', 1, 'x', p_project_id => %L)
              from public.cari_accounts c where c.code = 'TEST-DEMO-C' $$,
         (select v from ctx where k = 'pA')),
  '23514', null, 'demo cariye gerçek projede hareket işlenemez');
select throws_ok($$ update public.cari_accounts set is_demo = true where code = 'TEST-C1' $$,
  '23514', null, 'demo işareti sonradan değiştirilemez');

select * from finish();
rollback;
