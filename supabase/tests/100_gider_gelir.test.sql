-- Gider, gelir ve borç yönetimi (migration 20261104000000): kategori, taslak,
-- tekrar gönderim ve sürüm; onay (borç/alacak doğar) ve cari deftere tek
-- kayıt; kısmi ödeme/tahsilat, fazla ödeme, tekrar gönderim; sahada peşin
-- ödenmiş gider (kişisel kart, ikinci borç yok); iptal ve ters kayıt;
-- düzeltme; vade ve gecikme; döviz; proje bazlı yetki ve RLS (şantiye şefi
-- yalnızca kendi gideri); DEMO ayrımı; raporlar ve hakedişin ayrı sayılması.
begin;
select plan(89);

-- ---------------------------------------------------------------- hazırlık
create temp table ctx (k text primary key, v uuid) on commit drop;
grant select, insert on ctx to authenticated;
create function pg_temp.c(p_key text) returns uuid language sql stable
  as $$ select v from ctx where k = p_key $$;
create function pg_temp.cat(p_kind text, p_name text) returns uuid language sql stable
  as $$ select id from public.finance_categories where kind = p_kind::public.finance_doc_kind and name = p_name $$;
create function pg_temp.st(p_doc text) returns public.v_finance_document_status language sql stable
  as $$ select * from public.v_finance_document_status where document_id = pg_temp.c(p_doc) $$;
create function pg_temp.doc(p_doc text) returns public.finance_documents language sql stable
  as $$ select * from public.finance_documents where id = pg_temp.c(p_doc) $$;
-- Carinin TL bakiyesi (borç − alacak). postgres olarak okunur.
create function pg_temp.balance(p_cari text) returns numeric language sql stable
  as $$ select coalesce(sum(case direction when 'borc' then amount_try else -amount_try end), 0)
          from public.cari_entries where cari_account_id = pg_temp.c(p_cari) $$;
-- Hızlı gider: taslak kaydı (muhasebe/yönetici adına çağrılır).
create function pg_temp.gider(p_id text, p_amount numeric, p_project text, p_cari text default null,
                              p_due date default '2026-10-20') returns public.finance_documents language sql
  as $$ select public.save_finance_document(pg_temp.c(p_id), 'gider', pg_temp.cat('gider', 'Demir'),
          'Test gideri ' || p_id, p_amount, '2026-10-01', p_project_id => pg_temp.c(p_project),
          p_due_date => p_due, p_cari_account_id => pg_temp.c(p_cari)) $$;

insert into ctx values
  ('admin',    tests.create_user('fg-yonetici@test.invalid')),
  ('muhasebe', tests.create_user('fg-muhasebe@test.invalid')),
  ('mudur',    tests.create_user('fg-mudur@test.invalid')),
  ('sef',      tests.create_user('fg-sef@test.invalid')),
  ('outsider', tests.create_user('fg-rolsuz@test.invalid')),
  ('pA',       tests.create_project('TEST-FG-A')),
  ('pB',       tests.create_project('TEST-FG-B'));
insert into public.projects (code, name, is_demo) values ('TEST-FG-DEMO', 'Demo finans projesi', true);
insert into ctx select 'pDemo', id from public.projects where code = 'TEST-FG-DEMO';
insert into public.cost_centers (code, name) values ('TEST-FG-OFIS', 'Test ofis');
insert into ctx select 'cc', id from public.cost_centers where code = 'TEST-FG-OFIS';
insert into ctx select k, gen_random_uuid() from unnest(array[
  'g1', 'g2', 'g3', 'g4', 'g5', 'g6', 'gUsd', 'gDemo', 'gNew', 'gSef', 'gOfis', 'l1',
  's1', 's2', 's3', 'sK', 'sL', 'sU1', 'sU2', 'sR', 'catNew']) k;

select tests.grant_global_role(pg_temp.c('admin'),    'yonetici');
select tests.grant_global_role(pg_temp.c('muhasebe'), 'muhasebe');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('mudur'), 'proje_muduru', '2020-01-01');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('sef'),   'santiye_sefi', '2020-01-01');

insert into public.cari_accounts (code, title, type) values
  ('TEST-FG-T', 'TEST FG Demir Tedarikçisi', 'tedarikci'), ('TEST-FG-M', 'TEST FG Daire Alıcısı', 'musteri');
insert into public.cari_accounts (code, title, type, is_demo) values ('TEST-FG-D', 'TEST FG Demo Tedarikçi', 'tedarikci', true);
insert into ctx select case code when 'TEST-FG-T' then 'cariT' when 'TEST-FG-M' then 'cariM' else 'cariDemo' end, id
  from public.cari_accounts where code like 'TEST-FG-%';
insert into public.payment_sources (name, kind) values ('TEST FG Şirket ödemesi', 'sirket'), ('TEST FG Kürşat kartı', 'kart');
insert into ctx select case name when 'TEST FG Şirket ödemesi' then 'srcSirket' else 'srcKart' end, id
  from public.payment_sources where name like 'TEST FG %';

-- ---------------------------------------------------------------- yapı
select ok(not has_table_privilege('authenticated', 'public.finance_documents', 'insert')
          and not has_table_privilege('authenticated', 'public.finance_documents', 'update')
          and not has_table_privilege('authenticated', 'public.finance_settlements', 'insert')
          and not has_table_privilege('authenticated', 'public.finance_categories', 'insert'),
  'gider, gelir, ödeme ve kategori tabloları API''den doğrudan yazılamaz');
select is_empty(
  $$ select n.nspname || '.' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'private') and p.proname ~ '(kasa|bank|cash|opening_balance|available)' $$,
  'kasa, banka veya mevcut para fonksiyonu yok');
select ok((select count(*) from public.finance_categories where kind = 'gider' and is_active) >= 12,
  'başlangıç gider kategorileri veri olarak var');

-- ---------------------------------------------------------------- kategori
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(format($$ select public.save_finance_category(%L, 'gider', 'Vinç kirası', 85) $$, pg_temp.c('catNew')),
  'muhasebe yeni gider kategorisi ekler (genişletilebilir)');
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok($$ select public.save_finance_category(null, 'gider', 'Şef kategorisi') $$,
  '42501', null, 'şantiye şefi kategori tanımlayamaz');

-- ---------------------------------------------------------------- şantiye şefi: hızlı gider
select lives_ok(
  format($$ select public.save_finance_document(%L, 'gider', %L, 'Jeneratör motorini', 1250.75, '2026-10-05',
            p_project_id => %L, p_reported_settled => true, p_reported_source_id => %L, p_reported_by => 'Kürşat') $$,
         pg_temp.c('gSef'), pg_temp.cat('gider', 'Akaryakıt'), pg_temp.c('pA'), pg_temp.c('srcKart')),
  'şantiye şefi sahada Kürşat kartıyla peşin ödenmiş gideri az alanla girer');
select results_eq($$ select status::text, due_date, document_no like 'GD-%' from pg_temp.doc('gSef') $$,
  $$ values ('taslak', '2026-10-05'::date, true) $$, 'taslak olarak oluşur; vade boşsa belge tarihi; numara verilir');
select throws_ok(
  format($$ select public.save_finance_document(gen_random_uuid(), 'gider', %L, 'B projesi', 10, '2026-10-05', p_project_id => %L) $$,
         pg_temp.cat('gider', 'Akaryakıt'), pg_temp.c('pB')),
  '42501', null, 'şantiye şefi üyesi olmadığı projeye gider giremez');
select throws_ok(
  format($$ select public.save_finance_document(gen_random_uuid(), 'gider', %L, 'Ofis', 10, '2026-10-05', p_cost_center_id => %L) $$,
         pg_temp.cat('gider', 'Ofis gideri'), pg_temp.c('cc')),
  '42501', null, 'şantiye şefi genel gider (masraf merkezi) giremez');
select throws_ok(
  format($$ select public.save_finance_document(gen_random_uuid(), 'gelir', %L, 'Gelir', 10, '2026-10-05', p_project_id => %L) $$,
         pg_temp.cat('gelir', 'Diğer'), pg_temp.c('pA')),
  '42501', null, 'şantiye şefi gelir giremez');
select throws_ok(format($$ select public.approve_finance_document(%L) $$, pg_temp.c('gSef')),
  '42501', null, 'şantiye şefi kendi giderini onaylayamaz');

-- ---------------------------------------------------------------- muhasebe: taslak, doğrulama
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok($$ select pg_temp.gider('g1', 240000, 'pA', 'cariT') $$, 'muhasebe cari bağlantılı demir faturası girer');
select lives_ok($$ select pg_temp.gider('g1', 240000, 'pA', 'cariT') $$, 'aynı içerikle tekrar gönderim hata vermez');
select is((select count(*)::int from public.finance_documents where id = pg_temp.c('g1')), 1, 'tekrar gönderim tek belge');
select throws_ok($$ select pg_temp.gider('g1', 250000, 'pA', 'cariT') $$,
  '23505', null, 'aynı kimlik farklı tutarla gelirse uyuşmazlık');
select throws_ok(
  format($$ select public.save_finance_document(%L, 'gider', %L, 'Güncelleme', 245000, '2026-10-01',
            p_project_id => %L, p_cari_account_id => %L, p_expected_version => 99) $$,
         pg_temp.c('g1'), pg_temp.cat('gider', 'Demir'), pg_temp.c('pA'), pg_temp.c('cariT')),
  '40001', null, 'eski sürümle güncelleme reddedilir');
select lives_ok(
  format($$ select public.save_finance_document(%L, 'gider', %L, 'Test gideri g1', 240000, '2026-10-01',
            p_project_id => %L, p_due_date => '2026-10-20', p_cari_account_id => %L, p_invoice_no => 'DMR-1',
            p_expected_version => %s) $$,
         pg_temp.c('g1'), pg_temp.cat('gider', 'Demir'), pg_temp.c('pA'), pg_temp.c('cariT'), (pg_temp.doc('g1')).version),
  'taslak güncel sürümle düzenlenir');
select throws_ok($$ select pg_temp.gider('g2', 10.005, 'pA') $$, '23514', null, 'üç ondalıklı tutar reddedilir');
select throws_ok($$ select pg_temp.gider('g2', 0, 'pA') $$, '23514', null, 'sıfır tutar reddedilir');
select throws_ok($$ select pg_temp.gider('g2', 10, 'pA', null, '2026-09-01') $$, '23514', null, 'vade belge tarihinden önce olamaz');
select throws_ok(
  format($$ select public.save_finance_document(gen_random_uuid(), 'gider', %L, 'Yanlış tür', 10, '2026-10-01', p_project_id => %L) $$,
         pg_temp.cat('gelir', 'Diğer'), pg_temp.c('pA')),
  '23503', null, 'gelir kategorisi gidere verilemez');
select throws_ok(
  format($$ select public.save_finance_document(gen_random_uuid(), 'gider', %L, 'Kapsamsız', 10, '2026-10-01') $$,
         pg_temp.cat('gider', 'Demir')),
  '23514', null, 'proje veya masraf merkezi zorunlu');
select throws_ok(
  format($$ select public.save_finance_document(gen_random_uuid(), 'gider', %L, 'USD kursuz', 100, '2026-10-01',
            p_project_id => %L, p_currency => 'USD') $$, pg_temp.cat('gider', 'Ekipman'), pg_temp.c('pA')),
  '23514', null, 'dövizli giderde kur zorunlu (tahmin edilmez)');
select throws_ok(
  format($$ select public.save_finance_document(gen_random_uuid(), 'gider', %L, 'TL kur 2', 100, '2026-10-01',
            p_project_id => %L, p_exchange_rate => 2) $$, pg_temp.cat('gider', 'Ekipman'), pg_temp.c('pA')),
  '23514', null, 'TL giderde kur 1 dışında olamaz');
select throws_ok($$ select pg_temp.gider('gDemo', 10, 'pA', 'cariDemo') $$,
  '23514', null, 'demo cari gerçek projede kullanılamaz');
select lives_ok($$ select pg_temp.gider('gDemo', 10, 'pDemo', 'cariDemo') $$, 'demo proje + demo cari');
select is((pg_temp.doc('gDemo')).is_demo, true, 'belge projenin demo işaretini alır');
select lives_ok(
  format($$ select public.save_finance_document(%L, 'gider', %L, 'Ofis kırtasiye', 1830, '2026-10-25', p_cost_center_id => %L) $$,
         pg_temp.c('gOfis'), pg_temp.cat('gider', 'Ofis gideri'), pg_temp.c('cc')),
  'muhasebe şirket genel gideri (masraf merkezi) girer');

-- RLS: şantiye şefi yalnızca kendi gideri
select tests.authenticate_as(pg_temp.c('sef'));
select results_eq($$ select id from public.finance_documents $$, format($$ values (%L::uuid) $$, pg_temp.c('gSef')),
  'şantiye şefi yalnızca kendi girdiği gideri görür');
select tests.authenticate_as(pg_temp.c('mudur'));
select is((select count(*)::int from public.finance_documents), 2, 'proje müdürü projesinin giderlerini görür (genel gider ve diğer projeler hariç)');
select tests.authenticate_as(pg_temp.c('outsider'));
select is((select count(*)::int from public.finance_documents), 0, 'rolsüz kullanıcı hiçbir belge görmez');

-- ---------------------------------------------------------------- onay
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(format($$ select public.approve_finance_document(%L) $$, pg_temp.c('g1')),
  '42501', null, 'muhasebe (onay yetkisi yok) gideri onaylayamaz');
select tests.authenticate_as(pg_temp.c('mudur'));
select throws_ok(format($$ select public.approve_finance_document(%L) $$, pg_temp.c('g1')),
  '42501', null, 'proje müdürü gideri onaylayamaz');
select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(format($$ select public.approve_finance_document(%L, 1) $$, pg_temp.c('g1')),
  '40001', null, 'incelenenden farklı sürüm onaylanmaz');
select is((public.approve_finance_document(pg_temp.c('g1'))).status::text, 'onaylandi', 'yönetici onaylar: borç doğar');
select lives_ok(format($$ select public.approve_finance_document(%L) $$, pg_temp.c('g1')), 'tekrarlanan onay hata vermez');
select tests.clear_authentication();
select results_eq(
  format($$ select kind::text, direction::text, amount, source_type from public.cari_entries where cari_account_id = %L $$, pg_temp.c('cariT')),
  $$ values ('gider', 'alacak', 240000.00::numeric, 'finans_belge') $$,
  'cari deftere bir kez yazılır: tedarikçinin alacağı (tekrar onay ikinci kayıt açmaz)');
select is(pg_temp.balance('cariT'), -240000.00, 'tedarikçiye 240.000 borçluyuz');
select throws_ok(format($$ update public.finance_documents set amount = 1 where id = %L $$, pg_temp.c('g1')),
  '23514', null, 'onaylı belgenin tutarı veritabanında da değiştirilemez');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(
  format($$ select public.save_finance_document(%L, 'gider', %L, 'Test gideri g1', 1, '2026-10-01', p_project_id => %L,
            p_cari_account_id => %L, p_expected_version => %s) $$,
         pg_temp.c('g1'), pg_temp.cat('gider', 'Demir'), pg_temp.c('pA'), pg_temp.c('cariT'), (pg_temp.doc('g1')).version),
  '23514', null, 'onaylı belge düzenlenemez');
select results_eq($$ select settlement_status, remaining_amount, is_overdue from pg_temp.st('g1') $$,
  $$ values ('acik', 240000.00::numeric, true) $$, 'onaylı, ödenmemiş ve vadesi geçmiş borç');

-- ---------------------------------------------------------------- ödeme
select throws_ok(
  format($$ select public.record_finance_settlement(%L, %L, 100, %L, '2026-10-10') $$, gen_random_uuid(), pg_temp.c('gOfis'), pg_temp.c('srcSirket')),
  '23514', null, 'taslak belgeye ödeme yapılamaz');
select lives_ok(
  format($$ select public.record_finance_settlement(%L, %L, 100000, %L, '2026-10-10', 'Deneme Muhasebe') $$,
         pg_temp.c('s1'), pg_temp.c('g1'), pg_temp.c('srcSirket')),
  'şirket ödemesiyle 100.000 kısmi ödeme');
select lives_ok(
  format($$ select public.record_finance_settlement(%L, %L, 100000, %L, '2026-10-10', 'Deneme Muhasebe') $$,
         pg_temp.c('s1'), pg_temp.c('g1'), pg_temp.c('srcSirket')),
  'aynı ödemenin tekrar gönderimi');
select throws_ok(
  format($$ select public.record_finance_settlement(%L, %L, 100000, %L, '2026-10-10') $$, pg_temp.c('s1'), pg_temp.c('g1'), pg_temp.c('srcKart')),
  '23505', null, 'aynı ödeme kimliği farklı kaynakla (Kürşat kartı) gelirse uyuşmazlık');
select throws_ok(
  format($$ select public.record_finance_settlement(%L, %L, 100000, %L, '2026-10-11') $$, pg_temp.c('s1'), pg_temp.c('g1'), pg_temp.c('srcSirket')),
  '23505', null, 'aynı ödeme kimliği farklı tarihle gelirse uyuşmazlık');
select is((select count(*)::int from public.finance_settlements where document_id = pg_temp.c('g1')), 1, 'tek ödeme kaydı');
select throws_ok(
  format($$ select public.record_finance_settlement(%L, %L, 140000.01, %L, '2026-10-12') $$, gen_random_uuid(), pg_temp.c('g1'), pg_temp.c('srcSirket')),
  '23514', null, 'kalanı aşan ödeme reddedilir');
select results_eq($$ select settlement_status, settled_amount, remaining_amount from pg_temp.st('g1') $$,
  $$ values ('kismi', 100000.00::numeric, 140000.00::numeric) $$, 'kısmen ödendi: ödenen 100.000, kalan 140.000');
select tests.clear_authentication();
select is(pg_temp.balance('cariT'), -140000.00, 'cari: ödeme borç hareketi ve eşleştirme; kalan borç 140.000');
select is((select count(*)::int from public.cari_allocations a join public.cari_entries e on e.id = a.target_entry_id
            where e.source_id = pg_temp.c('g1') and a.deleted_at is null), 1, 'ödeme gider hareketine eşleştirildi');
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok(
  format($$ select public.record_finance_settlement(%L, %L, 1, %L) $$, gen_random_uuid(), pg_temp.c('g1'), pg_temp.c('srcSirket')),
  'P0002', null, 'şantiye şefi başkasının giderini göremez ve ödeyemez');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(
  format($$ select public.record_finance_settlement(%L, %L, 140000, %L, '2026-10-20') $$, pg_temp.c('s2'), pg_temp.c('g1'), pg_temp.c('srcKart')),
  'kalan 140.000 ikinci kısmi ödemeyle kapanır');
select results_eq($$ select settlement_status, remaining_amount, is_overdue from pg_temp.st('g1') $$,
  $$ values ('kapandi', 0.00::numeric, false) $$, 'tamamen ödendi; artık gecikmiş değil');

-- iptal ve ters kayıt
select throws_ok(format($$ select public.cancel_finance_settlement(%L, 'kısa') $$, pg_temp.c('s2')),
  '23514', null, 'ödeme iptal gerekçesi en az 10 karakter');
select is((public.cancel_finance_settlement(pg_temp.c('s2'), 'Yanlış kaynakla girildi')).status, 'iptal', 'ödeme ters kayıtla iptal edilir');
select is((pg_temp.st('g1')).remaining_amount, 140000.00, 'iptal sonrası kalan yeniden açılır');
select tests.clear_authentication();
select is(pg_temp.balance('cariT'), -140000.00, 'iptal edilen ödeme cari bakiyeden ters kayıtla düşer');
select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(format($$ select public.cancel_finance_document(%L, 'Fatura yanlış girildi') $$, pg_temp.c('g1')),
  '23514', null, 'ödemesi olan gider iptal edilemez');
select lives_ok(format($$ select public.cancel_finance_settlement(%L, 'Fatura iptal edilecek') $$, pg_temp.c('s1')), 'ilk ödeme de iptal edilir');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(format($$ select public.cancel_finance_document(%L, 'Fatura yanlış girildi') $$, pg_temp.c('g1')),
  '42501', null, 'onaylı gideri iptal etmek için onay yetkisi gerekir');
select tests.authenticate_as(pg_temp.c('admin'));
select is((public.cancel_finance_document(pg_temp.c('g1'), 'Fatura yanlış girildi')).status::text, 'iptal', 'yönetici onaylı gideri iptal eder');
select tests.clear_authentication();
select is(pg_temp.balance('cariT'), 0.00, 'cari: gider ve ödemeler ters kayıtla kapandı');
select is((select count(*)::int from public.cari_entries where cari_account_id = pg_temp.c('cariT') and kind = 'ters_kayit'), 3,
  'geçmiş korunur: 3 ters kayıt, orijinaller duruyor');

-- ---------------------------------------------------------------- peşin ödenmiş saha gideri (kişisel kart)
select tests.authenticate_as(pg_temp.c('admin'));
select is((public.approve_finance_document(pg_temp.c('gSef'), p_settlement_id => pg_temp.c('sK'))).status::text, 'onaylandi',
  'yönetici sahadan gelen peşin ödenmiş gideri onaylar');
select results_eq(
  $$ select s.kind, s.amount, s.payment_source_id, s.settled_by from public.finance_settlements s where s.document_id = pg_temp.c('gSef') $$,
  format($$ values ('odeme', 1250.75::numeric, %L::uuid, 'Kürşat') $$, pg_temp.c('srcKart')),
  'onayda tam tutar Kürşat kartı ödemesi olarak kaydedilir');
select is((pg_temp.st('gSef')).settlement_status, 'kapandi', 'peşin ödenmiş gider kapanmış görünür');
select lives_ok(format($$ select public.approve_finance_document(%L, p_settlement_id => %L) $$, pg_temp.c('gSef'), pg_temp.c('sK')),
  'tekrar onay ikinci ödeme açmaz');
select is((select count(*)::int from public.finance_settlements where document_id = pg_temp.c('gSef')), 1, 'tek ödeme');
select tests.clear_authentication();
select is((select count(*)::int from public.cari_entries e
            where e.description ilike '%Kürşat%' or e.source_id in (pg_temp.c('gSef'), pg_temp.c('sK'))), 0,
  'cari bağlantısız gider deftere yazılmaz; kart sahibine ikinci borç açılmaz');

-- ---------------------------------------------------------------- düzeltme
select tests.authenticate_as(pg_temp.c('muhasebe'));
select pg_temp.gider('g3', 5000, 'pA', 'cariT');
select tests.authenticate_as(pg_temp.c('admin'));
select public.approve_finance_document(pg_temp.c('g3'));
select is((public.revise_finance_document(pg_temp.c('g3'), pg_temp.c('gNew'), 'Tutar 5.500 olmalıydı')).replaces_id, pg_temp.c('g3'),
  'onaylı gider düzeltilir: yeni taslak eskisine bağlanır');
select lives_ok(format($$ select public.revise_finance_document(%L, %L, 'Tutar 5.500 olmalıydı') $$, pg_temp.c('g3'), pg_temp.c('gNew')),
  'tekrar düzeltme aynı taslağı döner');
select results_eq($$ select (pg_temp.doc('g3')).status::text, (pg_temp.doc('gNew')).status::text $$,
  $$ values ('iptal', 'taslak') $$, 'eski belge iptal, yeni belge taslak');

-- ---------------------------------------------------------------- döviz
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(
  format($$ select public.save_finance_document(%L, 'gider', %L, 'İthal kalıp aksesuarı', 1000, '2026-10-01',
            p_project_id => %L, p_currency => 'USD', p_exchange_rate => 40, p_cari_account_id => %L) $$,
         pg_temp.c('gUsd'), pg_temp.cat('gider', 'Kalıp'), pg_temp.c('pA'), pg_temp.c('cariT')),
  'USD gider kur 40 ile girilir');
select tests.authenticate_as(pg_temp.c('admin'));
select public.approve_finance_document(pg_temp.c('gUsd'));
select tests.authenticate_as(pg_temp.c('muhasebe'));
select throws_ok(
  format($$ select public.record_finance_settlement(%L, %L, 400, %L, '2026-10-15') $$, gen_random_uuid(), pg_temp.c('gUsd'), pg_temp.c('srcSirket')),
  '23514', null, 'USD ödeme kursuz kaydedilemez');
select lives_ok(
  format($$ select public.record_finance_settlement(%L, %L, 400, %L, '2026-10-15', p_exchange_rate => 41) $$,
         pg_temp.c('sU1'), pg_temp.c('gUsd'), pg_temp.c('srcSirket')),
  '400 USD ödeme kur 41');
select results_eq($$ select (pg_temp.doc('gUsd')).amount_try, (select amount_try from public.finance_settlements where id = pg_temp.c('sU1')),
                            (pg_temp.st('gUsd')).remaining_try $$,
  $$ values (40000.00::numeric, 16400.00::numeric, 24000.00::numeric) $$,
  'TL karşılıkları: belge 40.000; ödeme 16.400 (kendi kuru); kalan 600 × 40 = 24.000 (kur farkı hesaplanmaz)');

-- ---------------------------------------------------------------- gelir ve tahsilat
select lives_ok(
  format($$ select public.save_finance_document(%L, 'gelir', %L, 'Daire ara ödemesi', 750000, '2026-10-01',
            p_project_id => %L, p_due_date => '2026-11-15', p_cari_account_id => %L) $$,
         pg_temp.c('l1'), pg_temp.cat('gelir', 'Satış geliri'), pg_temp.c('pA'), pg_temp.c('cariM')),
  'muhasebe proje gelirini (alacak) girer');
select throws_ok(format($$ select public.approve_finance_document(%L) $$, pg_temp.c('l1')),
  '42501', null, 'gelir onayı ayrı yetki ister');
select tests.authenticate_as(pg_temp.c('admin'));
select public.approve_finance_document(pg_temp.c('l1'));
select tests.authenticate_as(pg_temp.c('muhasebe'));
select is((public.record_finance_settlement(pg_temp.c('sL'), pg_temp.c('l1'), 250000, pg_temp.c('srcSirket'), '2026-10-10')).kind,
  'tahsilat', 'kısmi tahsilat');
select tests.clear_authentication();
select results_eq(
  format($$ select kind::text, direction::text, amount from public.cari_entries where cari_account_id = %L order by amount desc $$, pg_temp.c('cariM')),
  $$ values ('fatura', 'borc', 750000.00::numeric), ('tahsilat', 'alacak', 250000.00::numeric) $$,
  'alacak deftere bir kez işlenir; tahsilat ayrı hareket');
select is(pg_temp.balance('cariM'), 500000.00, 'müşteri bize 500.000 borçlu (bekleyen alacak)');
select tests.authenticate_as(pg_temp.c('mudur'));
select is((select count(*)::int from public.finance_documents where kind = 'gelir'), 0, 'proje müdürü gelirleri görmez (gelir.read yok)');

-- ---------------------------------------------------------------- raporlar
select tests.authenticate_as(pg_temp.c('muhasebe'));
select results_eq(
  format($$ select label, accrued_try, settled_try, open_try from public.finance_report('gider', 'kategori', p_project_id => %L)
             order by label $$, pg_temp.c('pA')),
  $$ values ('Akaryakıt', 1250.75::numeric, 1250.75::numeric, 0.00::numeric),
            ('Kalıp', 40000.00::numeric, 16400.00::numeric, 24000.00::numeric) $$,
  'kategori raporu: yalnızca onaylı giderler; iptal edilenler yok');
select results_eq(
  format($$ select label, settled_try from public.finance_report('gider', 'kaynak', p_project_id => %L) order by label $$, pg_temp.c('pA')),
  $$ values ('TEST FG Kürşat kartı', 1250.75::numeric), ('TEST FG Şirket ödemesi', 16400.00::numeric) $$,
  'ödeme kaynağı raporu: yalnızca etkin ödemeler (iptaller hariç)');
select results_eq(
  format($$ select expense_accrued_try, expense_paid_try, expense_open_try, income_accrued_try, income_collected_try
             from public.project_cost_report(%L) $$, pg_temp.c('pA')),
  $$ values (41250.75::numeric, 17650.75::numeric, 24000.00::numeric, 750000.00::numeric, 250000.00::numeric) $$,
  'proje maliyeti: gider tahakkuku, ödenen ve kalan ayrı; gelir ve tahsilat ayrı');
select is((select hakedis_accrued_try from public.project_cost_report(pg_temp.c('pA'))), 0::numeric,
  'hakediş ayrı sütunda; gider belgeleri hakediş olarak sayılmaz');
select tests.authenticate_as(pg_temp.c('sef'));
select is((select count(*)::int from public.finance_report('gider', 'kategori')), 0, 'şantiye şefi rapor göremez');
select is((select count(*)::int from public.project_cost_report()), 0, 'şantiye şefi proje maliyeti göremez');

select * from finish();
rollback;
