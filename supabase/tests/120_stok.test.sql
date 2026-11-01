-- Aşama 7: malzeme kataloğu ve stok hareketleri (giriş, kullanım, transfer,
-- iade, sayım, ters kayıt), negatif stok engeli, yetki, DEMO ayrımı,
-- tekrar gönderim ve değiştirilemez geçmiş.
begin;
select plan(58);

-- -----------------------------------------------------------------------------
-- Hazırlık (postgres)
-- -----------------------------------------------------------------------------
create temp table ctx (k text primary key, v uuid) on commit drop;
grant select on ctx to authenticated;
create function pg_temp.id(p text) returns uuid language sql stable as $$ select v from ctx where k = p $$;

insert into ctx values
  ('admin',    tests.create_user('stok-admin@example.test')),
  ('pm',       tests.create_user('stok-pm@example.test')),
  ('sef',      tests.create_user('stok-sef@example.test')),
  ('outsider', tests.create_user('stok-dis@example.test')),
  ('viewer',   tests.create_user('stok-izle@example.test')),
  ('p1',       tests.create_project('STK-1')),
  ('p2',       tests.create_project('STK-2'));
insert into public.projects (code, name, is_demo) values ('STK-DEMO', 'Stok demo', true);
insert into ctx values
  ('pd',       (select id from public.projects where code = 'STK-DEMO')),
  ('plywood',  (select id from public.materials where name = 'Plywood')),
  ('tahta',    (select id from public.materials where name = 'Tahta')),
  ('direk',    (select id from public.materials where name = 'Demir direk')),
  ('adet',     (select id from public.material_units where code = 'adet')),
  ('kg',       (select id from public.material_units where code = 'kg')),
  ('paket',    (select id from public.material_units where code = 'paket'));
insert into ctx values
  ('w1', (select id from public.warehouses where project_id = pg_temp.id('p1') and is_default)),
  ('w2', (select id from public.warehouses where project_id = pg_temp.id('p2') and is_default)),
  ('wd', (select id from public.warehouses where project_id = pg_temp.id('pd') and is_default)),
  ('m_giris', gen_random_uuid()), ('m_kul', gen_random_uuid()), ('m_tr', gen_random_uuid()),
  ('m_sayim', gen_random_uuid()), ('m_rev', gen_random_uuid()), ('m_sef', gen_random_uuid());

select tests.grant_global_role(pg_temp.id('admin'), 'yonetici');
select tests.add_member(pg_temp.id('p1'), pg_temp.id('pm'), 'proje_muduru');
select tests.add_member(pg_temp.id('p1'), pg_temp.id('sef'), 'santiye_sefi');
select tests.add_member(pg_temp.id('p2'), pg_temp.id('outsider'), 'santiye_sefi');
select tests.add_member(pg_temp.id('p1'), pg_temp.id('viewer'), 'goruntuleyici');

create function pg_temp.balance(p_w text, p_m text) returns numeric language sql stable
  as $$ select coalesce((select quantity from public.v_stock_balances
                          where warehouse_id = pg_temp.id(p_w) and material_id = pg_temp.id(p_m)), 0) $$;

-- -----------------------------------------------------------------------------
-- Katalog ve depolar
-- -----------------------------------------------------------------------------
select is((select count(*)::int from public.warehouses where project_id = pg_temp.id('p1') and is_default), 1,
          'yeni projeye ana depo otomatik açılır');
select ok((select is_demo from public.warehouses where id = pg_temp.id('wd')), 'DEMO projenin deposu DEMO işaretli');
select is((select count(*)::int from public.material_units where code in ('adet', 'kg', 'm3', 'torba')), 4,
          'birimler veri olarak tanımlı');

select tests.authenticate_as(pg_temp.id('sef'));
select throws_ok($$ select public.save_material(gen_random_uuid(), 'Kalıp yağı',
                      (select id from public.material_categories where name = 'Diğer'), pg_temp.id('adet')) $$,
  '42501', null, 'şantiye şefi katalog yönetemez');
select is((select count(*)::int from public.materials where name = 'Plywood'), 1, 'şantiye şefi kataloğu görür');

-- -----------------------------------------------------------------------------
-- Giriş: şantiye şefi hazırlar, proje müdürü onaylar
-- -----------------------------------------------------------------------------
select is((public.create_stock_movement(pg_temp.id('m_giris'), 'giris', pg_temp.id('plywood'), pg_temp.id('w1'), 160,
                                        p_description => 'Sivas plywood teslimi')).status::text,
          'bekliyor', 'şantiye şefinin girişi onay bekler');
select is(pg_temp.balance('w1', 'plywood'), 0::numeric, 'onay bekleyen giriş stoku değiştirmez');
select is((select pending_in from public.v_stock_pending where warehouse_id = pg_temp.id('w1')
            and material_id = pg_temp.id('plywood')), 160.000::numeric, 'bekleyen giriş ayrıca görünür');
select throws_ok($$ select public.approve_stock_movement(pg_temp.id('m_giris')) $$, '42501', null,
                 'şantiye şefi hareketi onaylayamaz');
select tests.clear_authentication();

select tests.authenticate_as(pg_temp.id('pm'));
select is((public.approve_stock_movement(pg_temp.id('m_giris'))).status::text, 'onaylandi', 'proje müdürü onaylar');
select is(pg_temp.balance('w1', 'plywood'), 160::numeric, 'onaylı giriş stoku artırır (160)');
select lives_ok($$ select public.approve_stock_movement(pg_temp.id('m_giris')) $$, 'tekrar onay hata vermez');
select is((select count(*)::int from public.stock_entries where movement_id = pg_temp.id('m_giris')), 1,
          'tekrar onay ikinci defter satırı açmaz');

-- Kullanım (onay yetkisi olan kaydedince doğrudan işlenir)
select is((public.create_stock_movement(pg_temp.id('m_kul'), 'kullanim', pg_temp.id('plywood'), pg_temp.id('w1'), 40,
                                        p_description => 'Döşeme kalıbı')).status::text,
          'onaylandi', 'onay yetkili kullanıcının kullanımı doğrudan işlenir');
select is(pg_temp.balance('w1', 'plywood'), 120::numeric, 'kullanım stoku azaltır (120)');

-- Tekrar gönderim ve kimlik çakışması
select is((public.create_stock_movement(pg_temp.id('m_kul'), 'kullanim', pg_temp.id('plywood'), pg_temp.id('w1'), 40,
                                        p_description => 'Döşeme kalıbı')).id,
          pg_temp.id('m_kul'), 'aynı kimlik + aynı içerik aynı hareketi döner');
select is((select count(*)::int from public.stock_movements where id = pg_temp.id('m_kul')), 1,
          'tekrarlanan talep ikinci hareket oluşturmaz');
select is(pg_temp.balance('w1', 'plywood'), 120::numeric, 'tekrarlanan talep stoku ikinci kez azaltmaz');
select throws_ok($$ select public.create_stock_movement(pg_temp.id('m_kul'), 'kullanim', pg_temp.id('plywood'),
                      pg_temp.id('w1'), 41, p_description => 'Döşeme kalıbı') $$,
  '23505', null, 'aynı kimlik farklı içerikle reddedilir');
select tests.clear_authentication();

select tests.authenticate_as(pg_temp.id('sef'));
select throws_ok($$ select public.create_stock_movement(pg_temp.id('m_kul'), 'kullanim', pg_temp.id('plywood'),
                      pg_temp.id('w1'), 40, p_description => 'Döşeme kalıbı') $$,
  '23505', null, 'başkasının hareket kimliği kullanılamaz (içerik sızmaz)');
select tests.clear_authentication();

-- Transfer: iki yönlü doğru miktar, iki depoda yetki
select tests.authenticate_as(pg_temp.id('pm'));
select throws_ok($$ select public.create_stock_movement(gen_random_uuid(), 'transfer', pg_temp.id('plywood'),
                      pg_temp.id('w1'), 10, p_target_warehouse_id => pg_temp.id('w2')) $$,
  'P0002', null, 'yetkisi olmayan alıcı depoya transfer yapılamaz');
select tests.clear_authentication();

select tests.authenticate_as(pg_temp.id('admin'));
select is((public.create_stock_movement(pg_temp.id('m_tr'), 'transfer', pg_temp.id('plywood'), pg_temp.id('w1'), 10,
                                        p_target_warehouse_id => pg_temp.id('w2'))).status::text,
          'onaylandi', 'yönetici transferi işlenir');
select is(pg_temp.balance('w1', 'plywood'), 110::numeric, 'gönderen depoda 160 − 40 − 10 = 110');
select is(pg_temp.balance('w2', 'plywood'), 10::numeric, 'alıcı depoda 10');
select is((select sum(quantity) from public.stock_entries where movement_id = pg_temp.id('m_tr')), 0::numeric,
          'transfer toplamda stok yaratmaz (−10 / +10)');
select throws_ok($$ select public.create_stock_movement(gen_random_uuid(), 'transfer', pg_temp.id('plywood'),
                      pg_temp.id('w1'), 5, p_target_warehouse_id => pg_temp.id('wd')) $$,
  '23514', null, 'DEMO depo ile gerçek depo arasında transfer engellenir');
select tests.clear_authentication();

-- -----------------------------------------------------------------------------
-- Negatif stok, sayım, iade ve ters kayıt
-- -----------------------------------------------------------------------------
select tests.authenticate_as(pg_temp.id('pm'));
select throws_ok($$ select public.create_stock_movement(gen_random_uuid(), 'kullanim', pg_temp.id('plywood'),
                      pg_temp.id('w1'), 111) $$,
  '23514', null, 'depodakinden fazla kullanım reddedilir (negatif stok yok)');
select is(pg_temp.balance('w1', 'plywood'), 110::numeric, 'reddedilen çıkış stoku değiştirmez');

select throws_ok($$ select public.create_stock_movement(gen_random_uuid(), 'sayim', pg_temp.id('plywood'),
                      pg_temp.id('w1'), 105) $$,
  '23514', null, 'gerekçesiz sayım düzeltmesi reddedilir');
select is((public.create_stock_movement(pg_temp.id('m_sayim'), 'sayim', pg_temp.id('plywood'), pg_temp.id('w1'), 105,
                                        p_reason => 'Ay sonu sayımında 5 adet kırık çıktı')).adjustment,
          -5.000::numeric, 'sayım farkı onayda hesaplanır (105 − 110 = −5)');
select is(pg_temp.balance('w1', 'plywood'), 105::numeric, 'sayımdan sonra 105');

select is((public.create_stock_movement(gen_random_uuid(), 'iade_depo', pg_temp.id('plywood'), pg_temp.id('w1'), 5,
                                        p_description => 'Kullanılmayan plywood depoya döndü')).status::text,
          'onaylandi', 'depoya iade');
select is(pg_temp.balance('w1', 'plywood'), 110::numeric, 'depoya iade stoku artırır (110)');
select lives_ok($$ select public.create_stock_movement(gen_random_uuid(), 'iade_tedarikci', pg_temp.id('plywood'),
                     pg_temp.id('w1'), 5, p_description => 'Hatalı ürün tedarikçiye iade') $$,
  'tedarikçiye iade');
select is(pg_temp.balance('w1', 'plywood'), 105::numeric, 'tedarikçiye iade stoku azaltır (105)');

select is((public.reverse_stock_movement(pg_temp.id('m_kul'), pg_temp.id('m_rev'),
                                         'Kullanım yanlış projeye girildi')).kind::text,
          'ters_kayit', 'kullanım ters kayıtla iptal edilir');
select is(pg_temp.balance('w1', 'plywood'), 145::numeric, 'ters kayıt kullanılan 40 adedi geri ekler');
select ok((select reversed_by_id = pg_temp.id('m_rev') from public.stock_movements where id = pg_temp.id('m_kul')),
          'orijinal hareket silinmez; ters kayda bağlanır');
select is((public.reverse_stock_movement(pg_temp.id('m_kul'), pg_temp.id('m_rev'), 'Kullanım yanlış projeye girildi')).id,
          pg_temp.id('m_rev'), 'aynı ters kayıt kimliğiyle tekrar çağrı aynı kaydı döner');
select throws_ok($$ select public.reverse_stock_movement(pg_temp.id('m_kul'), gen_random_uuid(), 'İkinci iptal denemesi') $$,
  '23505', null, 'iptal edilmiş hareket ikinci kez iptal edilemez');
select throws_ok($$ select public.reverse_stock_movement(pg_temp.id('m_rev'), gen_random_uuid(), 'Ters kaydın iptali') $$,
  '23514', null, 'ters kayıt yeniden iptal edilemez');
select tests.clear_authentication();

-- Sayım ters kaydı: farkı geri alır
select tests.authenticate_as(pg_temp.id('admin'));
select lives_ok($$ select public.reverse_stock_movement(pg_temp.id('m_sayim'), gen_random_uuid(), 'Sayım yanlış depoda yapıldı') $$,
  'sayım düzeltmesi ters kayıtla geri alınır');
select is(pg_temp.balance('w1', 'plywood'), 150::numeric, 'sayım farkı (−5) geri eklendi');
select tests.clear_authentication();

-- -----------------------------------------------------------------------------
-- Birim ve dönüşüm
-- -----------------------------------------------------------------------------
select tests.authenticate_as(pg_temp.id('pm'));
select throws_ok($$ select public.create_stock_movement(gen_random_uuid(), 'giris', pg_temp.id('plywood'),
                      pg_temp.id('w1'), 1.5) $$,
  '23514', null, 'adet biriminde ondalık miktar reddedilir');
select throws_ok($$ select public.create_stock_movement(gen_random_uuid(), 'giris', pg_temp.id('plywood'),
                      pg_temp.id('w1'), 2, p_unit_id => pg_temp.id('paket')) $$,
  '23514', null, 'tanımsız birim dönüşümü tahmin edilmez, reddedilir');
select tests.clear_authentication();

select tests.authenticate_as(pg_temp.id('admin'));
select lives_ok($$ select public.save_material_unit_conversion(gen_random_uuid(), pg_temp.id('plywood'), pg_temp.id('paket'), 10,
                     '1 paket = 10 adet') $$, 'yönetici açık dönüşüm oranı tanımlar');
select is((public.create_stock_movement(gen_random_uuid(), 'giris', pg_temp.id('plywood'), pg_temp.id('w1'), 2,
                                        p_unit_id => pg_temp.id('paket'))).base_quantity,
          20.000::numeric, '2 paket = 20 adet olarak işlenir');
select throws_ok($$ select public.save_material(pg_temp.id('plywood'), 'Plywood',
                      (select category_id from public.materials where id = pg_temp.id('plywood')), pg_temp.id('kg'),
                      p_expected_version => (select version from public.materials where id = pg_temp.id('plywood'))) $$,
  '23514', null, 'hareketi olan malzemenin temel birimi değiştirilemez');
select tests.clear_authentication();

-- -----------------------------------------------------------------------------
-- Görünürlük ve yetki
-- -----------------------------------------------------------------------------
select tests.authenticate_as(pg_temp.id('outsider'));
select is((select count(*)::int from public.v_stock_balances where warehouse_id = pg_temp.id('w1')), 0,
          'başka projenin kullanıcısı o projenin stoklarını görmez');
select is((select count(*)::int from public.stock_movements
            where warehouse_id = pg_temp.id('w1') and target_warehouse_id is distinct from pg_temp.id('w2')), 0,
          'başka projenin hareketleri görünmez');
select is((select count(*)::int from public.stock_movements where target_warehouse_id = pg_temp.id('w2')), 1,
          'kendi deposuna gelen transferi görür');
select throws_ok($$ select public.create_stock_movement(gen_random_uuid(), 'kullanim', pg_temp.id('plywood'),
                      pg_temp.id('w1'), 1) $$,
  'P0002', null, 'yetkisiz proje deposuna hareket girilemez');
select tests.clear_authentication();

select tests.authenticate_as(pg_temp.id('viewer'));
select throws_ok($$ select public.create_stock_movement(gen_random_uuid(), 'kullanim', pg_temp.id('plywood'),
                      pg_temp.id('w1'), 1) $$,
  '42501', null, 'görüntüleyici stoku görür ama hareket giremez');
select tests.clear_authentication();

-- Şantiye şefi kendi bekleyen hareketini geri çekebilir
select tests.authenticate_as(pg_temp.id('sef'));
select is((public.create_stock_movement(pg_temp.id('m_sef'), 'kullanim', pg_temp.id('plywood'), pg_temp.id('w1'), 1)).status::text,
          'bekliyor', 'şantiye şefi kullanım hazırlar');
select is((public.reject_stock_movement(pg_temp.id('m_sef'), 'Yanlış malzeme seçildi')).status::text,
          'reddedildi', 'şantiye şefi kendi bekleyen hareketini geri çeker');
select tests.clear_authentication();

-- -----------------------------------------------------------------------------
-- Değiştirilemez geçmiş
-- -----------------------------------------------------------------------------
select tests.authenticate_as(pg_temp.id('admin'));
select throws_ok($$ insert into public.stock_entries (movement_id, warehouse_id, material_id, entry_date, quantity, is_demo)
                    values (pg_temp.id('m_giris'), pg_temp.id('w1'), pg_temp.id('plywood'), current_date, 1000, false) $$,
  '42501', null, 'stok defterine doğrudan yazılamaz (bakiye elle değiştirilemez)');
select tests.clear_authentication();

select throws_ok($$ update public.stock_entries set quantity = 1 where movement_id = pg_temp.id('m_giris') $$,
  '42501', null, 'stok defteri satırı değiştirilemez (sahip rolü dahil)');
select throws_ok($$ update public.stock_movements set quantity = 1 where id = pg_temp.id('m_giris') $$,
  '23514', null, 'onaylı hareketin miktarı değiştirilemez');

select * from finish();
rollback;
