-- Aşama 7: satın alma siparişi, parça parça teslim alma, fazla teslim
-- engeli, teslim iptali, fiyat gizliliği, gider ve belge bağlantıları.
-- Sipariş, teslim ve bağlantılar hiçbir finansal kayıt açmaz veya değiştirmez.
begin;
select plan(54);

create temp table ctx (k text primary key, v uuid) on commit drop;
grant select on ctx to authenticated;
create function pg_temp.id(p text) returns uuid language sql stable as $$ select v from ctx where k = p $$;

insert into ctx values
  ('admin',    tests.create_user('sa-admin@example.test')),
  ('pm',       tests.create_user('sa-pm@example.test')),
  ('sef',      tests.create_user('sa-sef@example.test')),
  ('muhasebe', tests.create_user('sa-muh@example.test')),
  ('outsider', tests.create_user('sa-dis@example.test')),
  ('p1',       tests.create_project('SAT-1')),
  ('p2',       tests.create_project('SAT-2'));
insert into public.cari_accounts (code, title, type) values ('SAT-T1', 'Test Kalıp Tedarikçisi', 'tedarikci');
insert into public.cari_accounts (code, title, type, is_demo) values ('SAT-TD', 'Demo Tedarikçi', 'tedarikci', true);
insert into ctx values
  ('vendor',   (select id from public.cari_accounts where code = 'SAT-T1')),
  ('demo_v',   (select id from public.cari_accounts where code = 'SAT-TD')),
  ('plywood',  (select id from public.materials where name = 'Plywood')),
  ('direk',    (select id from public.materials where name = 'Demir direk')),
  ('w1',       (select id from public.warehouses where project_id = pg_temp.id('p1') and is_default)),
  ('w2',       (select id from public.warehouses where project_id = pg_temp.id('p2') and is_default)),
  ('po', gen_random_uuid()), ('l1', gen_random_uuid()), ('l2', gen_random_uuid()),
  ('r1', gen_random_uuid()), ('r2', gen_random_uuid()), ('use', gen_random_uuid()),
  ('gd', gen_random_uuid()), ('gd2', gen_random_uuid()), ('lnk', gen_random_uuid()), ('doclnk', gen_random_uuid()),
  ('doc', gen_random_uuid()), ('src', gen_random_uuid());

select tests.grant_global_role(pg_temp.id('admin'), 'yonetici');
select tests.grant_global_role(pg_temp.id('muhasebe'), 'muhasebe');
select tests.add_member(pg_temp.id('p1'), pg_temp.id('pm'), 'proje_muduru');
select tests.add_member(pg_temp.id('p1'), pg_temp.id('sef'), 'santiye_sefi');
select tests.add_member(pg_temp.id('p2'), pg_temp.id('outsider'), 'santiye_sefi');

-- Arşivde yüklenmiş bir irsaliye (Aşama 6 akışının sonucu)
insert into public.documents (id, kind, title, document_date, link_type, project_id, mime_type, byte_size, sha256,
                              storage_path, status, uploaded_at, server_sha256, server_byte_size, server_verified_at)
values (pg_temp.id('doc'), 'irsaliye', 'İrsaliye IRS-1', current_date, 'proje', pg_temp.id('p1'), 'application/pdf',
        100, repeat('a', 64), gen_random_uuid() || '/x.pdf', 'yuklendi', now(), repeat('a', 64), 100, now());

-- Finans tablolarının başlangıç durumu
create temp table fin_before on commit drop as
select (select count(*) from public.finance_documents)   as docs,
       (select count(*) from public.finance_settlements) as settlements,
       (select count(*) from public.cari_entries)        as cari,
       (select count(*) from public.cari_allocations)    as allocations,
       (select count(*) from public.finance_payments)    as payments;
grant select on fin_before to authenticated;

create function pg_temp.lines() returns jsonb language sql stable as $$
  select jsonb_build_array(
    jsonb_build_object('id', pg_temp.id('l1'), 'material_id', pg_temp.id('plywood'), 'quantity', 160, 'unit_price', 850),
    jsonb_build_object('id', pg_temp.id('l2'), 'material_id', pg_temp.id('direk'), 'quantity', 200, 'unit_price', 320)) $$;
create function pg_temp.balance(p_m text) returns numeric language sql stable
  as $$ select coalesce((select quantity from public.v_stock_balances
                          where warehouse_id = pg_temp.id('w1') and material_id = pg_temp.id(p_m)), 0) $$;
create function pg_temp.po_status() returns text language sql stable
  as $$ select status::text from public.purchase_orders where id = pg_temp.id('po') $$;

-- -----------------------------------------------------------------------------
-- Sipariş taslağı
-- -----------------------------------------------------------------------------
select tests.authenticate_as(pg_temp.id('sef'));
select throws_ok($$ select public.save_purchase_order(gen_random_uuid(), pg_temp.id('vendor'), pg_temp.id('w1'), pg_temp.lines()) $$,
  '42501', null, 'şantiye şefi sipariş hazırlayamaz');
select tests.clear_authentication();

select tests.authenticate_as(pg_temp.id('pm'));
select is((public.save_purchase_order(pg_temp.id('po'), pg_temp.id('vendor'), pg_temp.id('w1'), pg_temp.lines(),
                                      p_order_date => current_date, p_description => 'Kalıp malzemesi')).status::text,
          'taslak', 'proje müdürü sipariş taslağı hazırlar');
select is((public.save_purchase_order(pg_temp.id('po'), pg_temp.id('vendor'), pg_temp.id('w1'), pg_temp.lines(),
                                      p_order_date => current_date, p_description => 'Kalıp malzemesi')).id,
          pg_temp.id('po'), 'aynı kimlik + aynı içerik aynı siparişi döner');
select is((select count(*)::int from public.purchase_orders where id = pg_temp.id('po')), 1, 'ikinci sipariş açılmaz');
select throws_ok($$ select public.save_purchase_order(pg_temp.id('po'), pg_temp.id('vendor'), pg_temp.id('w1'),
                      jsonb_build_array(jsonb_build_object('id', pg_temp.id('l1'), 'material_id', pg_temp.id('plywood'),
                                                           'quantity', 161)),
                      p_order_date => current_date, p_description => 'Kalıp malzemesi') $$,
  '23505', null, 'aynı kimlik farklı satırlarla reddedilir');
select throws_ok($$ select public.save_purchase_order(pg_temp.id('po'), pg_temp.id('vendor'), pg_temp.id('w1'), pg_temp.lines(),
                      p_order_date => current_date, p_expected_version => 99) $$,
  '40001', null, 'eski sürümle güncelleme reddedilir');
select throws_ok($$ select public.save_purchase_order(gen_random_uuid(), pg_temp.id('demo_v'), pg_temp.id('w1'),
                      jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'material_id', pg_temp.id('plywood'),
                                                           'quantity', 1))) $$,
  '23514', null, 'DEMO cari ile gerçek depoya sipariş verilemez');
select throws_ok($$ select public.purchase_order_transition(pg_temp.id('po'), 'onayla') $$, '42501', null,
                 'proje müdürü siparişi onaylayamaz (satinalma.approve yok)');
select throws_ok($$ select public.receive_purchase_order(gen_random_uuid(), pg_temp.id('po'),
                      jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l1'), 'quantity', 1))) $$,
  '23514', null, 'taslak siparişe teslim alınamaz');
select is((select line_total from public.purchase_order_prices(pg_temp.id('po')) where order_line_id = pg_temp.id('l1')),
          136000.00::numeric, 'satinalma.read ile satır tutarı görünür (160 × 850)');
select tests.clear_authentication();

select tests.authenticate_as(pg_temp.id('admin'));
select is((public.purchase_order_transition(pg_temp.id('po'), 'onayla')).status::text, 'onaylandi', 'yönetici onaylar');
select throws_ok($$ select public.save_purchase_order(pg_temp.id('po'), pg_temp.id('vendor'), pg_temp.id('w1'), pg_temp.lines(),
                      p_order_date => current_date,
                      p_expected_version => (select version from public.purchase_orders where id = pg_temp.id('po'))) $$,
  '23514', null, 'onaylı sipariş düzenlenemez');
select tests.clear_authentication();

select results_eq($$ select docs, settlements, cari, allocations, payments from fin_before $$,
  $$ select (select count(*) from public.finance_documents), (select count(*) from public.finance_settlements),
            (select count(*) from public.cari_entries), (select count(*) from public.cari_allocations),
            (select count(*) from public.finance_payments) $$,
  'sipariş ve onayı cari borç, gider veya ödeme oluşturmaz');

-- -----------------------------------------------------------------------------
-- Fiyat gizliliği: teslim alan şantiye şefi miktarı görür, fiyatı görmez
-- -----------------------------------------------------------------------------
select tests.authenticate_as(pg_temp.id('sef'));
select is((select count(*)::int from public.purchase_order_lines where order_id = pg_temp.id('po')), 2,
          'şantiye şefi sipariş satırlarını (miktar) görür');
select throws_ok($$ select unit_price from public.purchase_order_lines where order_id = pg_temp.id('po') $$,
  '42501', null, 'şantiye şefi birim fiyat sütununu okuyamaz');
select throws_ok($$ select * from public.purchase_order_prices(pg_temp.id('po')) $$, '42501', null,
                 'şantiye şefi fiyat fonksiyonunu çağıramaz');

-- -----------------------------------------------------------------------------
-- Parça parça teslim alma
-- -----------------------------------------------------------------------------
select is((public.receive_purchase_order(pg_temp.id('r1'), pg_temp.id('po'),
             jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l1'), 'quantity', 100)),
             p_waybill_no => 'IRS-1', p_document_id => pg_temp.id('doc'))).status,
          'aktif', 'şantiye şefi 100 plywood teslim alır');
select is(pg_temp.po_status(), 'kismi_teslim', 'sipariş kısmen teslim alındı');
select is(pg_temp.balance('plywood'), 100::numeric, 'teslim stok girişi oluşturur (100)');
select is((select kind::text || ':' || status::text from public.stock_movements m
            join public.purchase_receipt_lines rl on rl.stock_movement_id = m.id where rl.receipt_id = pg_temp.id('r1')),
          'giris:onaylandi', 'teslim, onaylı stok girişinin kaynağıdır');
select is((public.receive_purchase_order(pg_temp.id('r1'), pg_temp.id('po'),
             jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l1'), 'quantity', 100)),
             p_waybill_no => 'IRS-1', p_document_id => pg_temp.id('doc'))).id,
          pg_temp.id('r1'), 'aynı teslimin tekrar gönderimi aynı kaydı döner');
select is(pg_temp.balance('plywood'), 100::numeric, 'tekrar gönderim ikinci stok girişi yaratmaz');
select is((select count(*)::int from public.stock_movements where purchase_receipt_id = pg_temp.id('r1')), 1,
          'teslim başına tek stok hareketi');
select throws_ok($$ select public.receive_purchase_order(pg_temp.id('r1'), pg_temp.id('po'),
                      jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l1'), 'quantity', 90)),
                      p_waybill_no => 'IRS-1', p_document_id => pg_temp.id('doc')) $$,
  '23505', null, 'aynı teslim kimliği farklı miktarla reddedilir');
select throws_ok($$ select public.receive_purchase_order(gen_random_uuid(), pg_temp.id('po'),
                      jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l1'), 'quantity', 61))) $$,
  '23514', null, 'siparişten fazla teslim reddedilir (kalan 60)');
select is((public.receive_purchase_order(pg_temp.id('r2'), pg_temp.id('po'),
             jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l1'), 'quantity', 60),
                               jsonb_build_object('order_line_id', pg_temp.id('l2'), 'quantity', 200)))).status,
          'aktif', 'kalan 60 plywood ve 200 direk teslim alınır');
select is(pg_temp.po_status(), 'tamamlandi', 'tüm satırlar alınınca sipariş tamamlanır');
select is(pg_temp.balance('plywood'), 160::numeric, 'plywood stoku 160');
select throws_ok($$ select public.receive_purchase_order(gen_random_uuid(), pg_temp.id('po'),
                      jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l2'), 'quantity', 1))) $$,
  '23514', null, 'tamamlanmış siparişe teslim alınamaz');
select tests.clear_authentication();

select results_eq($$ select docs, settlements, cari, allocations, payments from fin_before $$,
  $$ select (select count(*) from public.finance_documents), (select count(*) from public.finance_settlements),
            (select count(*) from public.cari_entries), (select count(*) from public.cari_allocations),
            (select count(*) from public.finance_payments) $$,
  'teslim alma finansal kayıt oluşturmaz');

-- -----------------------------------------------------------------------------
-- Teslim iptali (ters kayıt) ve kullanılmış malzeme
-- -----------------------------------------------------------------------------
select tests.authenticate_as(pg_temp.id('pm'));
select lives_ok($$ select public.create_stock_movement(pg_temp.id('use'), 'kullanim', pg_temp.id('plywood'),
                     pg_temp.id('w1'), 120) $$, '120 plywood kullanılır');
select throws_ok($$ select public.cancel_purchase_receipt(pg_temp.id('r2'), 'Yanlış irsaliye girildi') $$,
  '23514', null, 'kullanılmış malzemenin teslimi geri alınamaz (stok negatife düşmez)');
select throws_ok($$ select public.reverse_stock_movement((select stock_movement_id from public.purchase_receipt_lines
                                                          where receipt_id = pg_temp.id('r1')), gen_random_uuid(),
                                                         'Teslimi hareketten iptal deneme') $$,
  '23514', null, 'teslim hareketi tek başına iptal edilemez (teslim iptal edilir)');
select lives_ok($$ select public.reverse_stock_movement(pg_temp.id('use'), gen_random_uuid(), 'Kullanım yanlış girildi') $$,
  'kullanım ters kayıtla geri alınır');
select is((public.cancel_purchase_receipt(pg_temp.id('r2'), 'Yanlış irsaliye girildi')).status, 'iptal',
          'teslim iptal edilir');
select is(pg_temp.balance('plywood'), 100::numeric, 'teslim iptali 60 plywoodu geri alır');
select is(pg_temp.balance('direk'), 0::numeric, 'teslim iptali 200 direği geri alır');
select is(pg_temp.po_status(), 'kismi_teslim', 'sipariş yeniden kısmen teslim durumuna döner');
select is((select count(*)::int from public.stock_movements m
            where m.purchase_receipt_id = pg_temp.id('r2') and m.kind = 'ters_kayit'), 2,
          'teslim iptali her satır için izlenebilir ters hareket açar');
select throws_ok($$ select public.purchase_order_transition(pg_temp.id('po'), 'iptal', 'Tedarikçi teslim edemedi') $$,
  '42501', null, 'proje müdürü onaylı siparişi iptal edemez');
select tests.clear_authentication();

select tests.authenticate_as(pg_temp.id('admin'));
select throws_ok($$ select public.purchase_order_transition(pg_temp.id('po'), 'iptal', 'Tedarikçi teslim edemedi') $$,
  '23514', null, 'teslim alınmış sipariş iptal edilemez');
select is((public.purchase_order_transition(pg_temp.id('po'), 'kapat', 'Kalan miktar başka tedarikçiden alınacak')).status::text,
          'tamamlandi', 'eksik teslimle sipariş kapatılır');
select tests.clear_authentication();

-- -----------------------------------------------------------------------------
-- Gider (fatura) bağlantısı: finans kaydı değişmez, ikinci kez bağlanmaz
-- -----------------------------------------------------------------------------
select tests.authenticate_as(pg_temp.id('admin'));
select lives_ok($$ select public.save_finance_document(pg_temp.id('gd'), 'gider',
                     (select id from public.finance_categories where kind = 'gider' and name = 'Kalıp'),
                     'Plywood faturası', 85000, current_date, p_project_id => pg_temp.id('p1'),
                     p_cari_account_id => pg_temp.id('vendor'), p_invoice_no => 'KLP-1');
                   select public.approve_finance_document(pg_temp.id('gd')) $$,
  'Aşama 5 akışıyla gider (fatura) onaylanır: borç burada doğar');
select tests.clear_authentication();

create temp table fin_mid on commit drop as
select (select count(*) from public.cari_entries) as cari,
       (select row(d.*)::text from public.finance_documents d where d.id = pg_temp.id('gd')) as doc;
grant select on fin_mid to authenticated;

select tests.authenticate_as(pg_temp.id('pm'));
select is((public.link_purchase_order_expense(pg_temp.id('lnk'), pg_temp.id('po'), pg_temp.id('gd'), 'Fatura geldi')).status,
          'aktif', 'gider kaydı siparişe bağlanır');
select is((public.link_purchase_order_expense(pg_temp.id('lnk'), pg_temp.id('po'), pg_temp.id('gd'), 'Fatura geldi')).id,
          pg_temp.id('lnk'), 'aynı bağlantının tekrarı aynı kaydı döner');
select tests.clear_authentication();
select results_eq($$ select cari, doc from fin_mid $$,
  $$ select (select count(*) from public.cari_entries),
            (select row(d.*)::text from public.finance_documents d where d.id = pg_temp.id('gd')) $$,
  'bağlantı gider kaydını ve cari defteri değiştirmez');

select tests.authenticate_as(pg_temp.id('admin'));
select lives_ok($$ select public.save_purchase_order(pg_temp.id('src'), pg_temp.id('vendor'), pg_temp.id('w1'),
                     jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'material_id', pg_temp.id('plywood'),
                                                          'quantity', 5)));
                   select public.purchase_order_transition(pg_temp.id('src'), 'onayla') $$,
  'ikinci sipariş');
select throws_ok($$ select public.link_purchase_order_expense(gen_random_uuid(), pg_temp.id('src'), pg_temp.id('gd')) $$,
  '23505', null, 'aynı gider ikinci siparişe bağlanamaz (iki kez sayılmaz)');
select is((select expense_accrued_try from public.project_cost_report(pg_temp.id('p1'))), 85000.00::numeric,
          'proje maliyetinde gider bir kez sayılır; sipariş, teslim ve kullanım maliyet eklemez');
select tests.clear_authentication();

-- Belge bağlantısı
select tests.authenticate_as(pg_temp.id('sef'));
select is((public.link_purchase_order_document(pg_temp.id('doclnk'), pg_temp.id('po'), pg_temp.id('doc'))).status,
          'aktif', 'teslim alan irsaliyeyi siparişe bağlar');
select tests.clear_authentication();
select results_eq($$ select cari, doc from fin_mid $$,
  $$ select (select count(*) from public.cari_entries),
            (select row(d.*)::text from public.finance_documents d where d.id = pg_temp.id('gd')) $$,
  'belge bağlantısı finans kayıtlarını değiştirmez');

-- -----------------------------------------------------------------------------
-- Proje dışı erişim
-- -----------------------------------------------------------------------------
select tests.authenticate_as(pg_temp.id('outsider'));
select is((select count(*)::int from public.purchase_orders where project_id = pg_temp.id('p1')), 0,
          'başka projenin kullanıcısı siparişleri görmez');
select throws_ok($$ select public.receive_purchase_order(gen_random_uuid(), pg_temp.id('src'),
                      jsonb_build_array(jsonb_build_object('order_line_id', gen_random_uuid(), 'quantity', 1))) $$,
  'P0002', null, 'yetkisiz projede teslim alınamaz');
select tests.clear_authentication();

select ok((select count(*) > 0 from audit.log where table_name = 'purchase_orders'
            and record_id = pg_temp.id('po')::text), 'sipariş değişiklikleri işlem geçmişinde');

select * from finish();
rollback;
