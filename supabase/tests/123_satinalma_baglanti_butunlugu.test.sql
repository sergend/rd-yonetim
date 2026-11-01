-- Aşama 7 düzeltmesi: siparişe bağlı gider ve belgenin kapsamı bağlantıdan
-- sonra da korunur; iptal ve düzeltmede yanlış etkin bağlantı kalmaz. Teslim
-- ve gider bağlantısının tekrar gönderimi tüm öznitelikleri karşılaştırır.
begin;
select plan(44);

create temp table ctx (k text primary key, v uuid) on commit drop;
grant select on ctx to authenticated;
create function pg_temp.id(p text) returns uuid language sql stable as $$ select v from ctx where k = p $$;

insert into ctx values
  ('admin', tests.create_user('bb-admin@example.test')),
  ('p1',    tests.create_project('BB-1')),
  ('p2',    tests.create_project('BB-2'));
insert into public.cari_accounts (code, title, type) values ('BB-T1', 'Bağ Tedarikçi 1', 'tedarikci');
insert into public.cari_accounts (code, title, type) values ('BB-T2', 'Bağ Tedarikçi 2', 'tedarikci');
insert into ctx values
  ('vendor',  (select id from public.cari_accounts where code = 'BB-T1')),
  ('vendor2', (select id from public.cari_accounts where code = 'BB-T2')),
  ('cat',     (select id from public.finance_categories where kind = 'gider' and name = 'Kalıp')),
  ('plywood', (select id from public.materials where name = 'Plywood')),
  ('w1',      (select id from public.warehouses where project_id = pg_temp.id('p1') and is_default)),
  ('po', gen_random_uuid()), ('l1', gen_random_uuid()), ('po2', gen_random_uuid()),
  ('gd', gen_random_uuid()), ('gd_new', gen_random_uuid()), ('gd3', gen_random_uuid()), ('gd4', gen_random_uuid()),
  ('lnk', gen_random_uuid()), ('lnk3', gen_random_uuid()), ('lnk4', gen_random_uuid()),
  ('doc', gen_random_uuid()), ('doc2', gen_random_uuid()), ('doc3', gen_random_uuid()), ('doc_new', gen_random_uuid()),
  ('dl', gen_random_uuid()), ('dl3', gen_random_uuid()), ('r1', gen_random_uuid());

select tests.grant_global_role(pg_temp.id('admin'), 'yonetici');

-- Arşivde yüklenmiş belgeler (Aşama 6 akışının sonucu)
insert into public.documents (id, kind, title, document_date, link_type, project_id, mime_type, byte_size, sha256,
                              storage_path, status, uploaded_at, server_sha256, server_byte_size, server_verified_at)
select pg_temp.id(k), 'irsaliye', 'İrsaliye ' || k, current_date, 'proje', pg_temp.id('p1'), 'application/pdf',
       100, encode(sha256(convert_to(k, 'UTF8')), 'hex'), gen_random_uuid() || '/x.pdf', 'yuklendi', now(),
       encode(sha256(convert_to(k, 'UTF8')), 'hex'), 100, now()
  from unnest(array['doc', 'doc2', 'doc3']) k;

create function pg_temp.save_gd(p_id text, p_project text, p_cari uuid, p_amount numeric default 1000,
                                p_desc text default 'Plywood faturası') returns public.finance_documents
  language sql as $$
  select public.save_finance_document(pg_temp.id(p_id), 'gider', pg_temp.id('cat'), p_desc, p_amount, current_date,
                                      p_project_id => pg_temp.id(p_project), p_cari_account_id => p_cari,
                                      p_expected_version => (select version from public.finance_documents
                                                              where id = pg_temp.id(p_id))) $$;
create function pg_temp.link_status(p_id uuid) returns text language sql stable
  as $$ select status from public.purchase_order_expense_links where id = p_id $$;
create function pg_temp.relink(p_doc text, p_project text) returns public.documents language sql as $$
  select public.relink_document(pg_temp.id(p_doc), 'proje', pg_temp.id(p_project), 'Yanlış projeye yüklenmiş',
                                (select version from public.documents where id = pg_temp.id(p_doc))) $$;

select tests.authenticate_as(pg_temp.id('admin'));
select lives_ok($$
  select public.save_purchase_order(pg_temp.id('po'), pg_temp.id('vendor'), pg_temp.id('w1'),
           jsonb_build_array(jsonb_build_object('id', pg_temp.id('l1'), 'material_id', pg_temp.id('plywood'),
                                                'quantity', 100, 'unit_price', 10)));
  select public.purchase_order_transition(pg_temp.id('po'), 'onayla');
  select public.save_purchase_order(pg_temp.id('po2'), pg_temp.id('vendor'), pg_temp.id('w1'),
           jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'material_id', pg_temp.id('plywood'),
                                                'quantity', 5)));
  select public.purchase_order_transition(pg_temp.id('po2'), 'onayla') $$,
  'iki onaylı sipariş');

-- -----------------------------------------------------------------------------
-- Taslak gider bağlıyken kapsamı bozulamaz
-- -----------------------------------------------------------------------------
select lives_ok($$ select pg_temp.save_gd('gd', 'p1', pg_temp.id('vendor')) $$, 'taslak gider');
select is((public.link_purchase_order_expense(pg_temp.id('lnk'), pg_temp.id('po'), pg_temp.id('gd'), 'Fatura geldi')).status,
          'aktif', 'taslak gider siparişe bağlanır');
select throws_ok($$ select pg_temp.save_gd('gd', 'p2', pg_temp.id('vendor')) $$, '23514', null,
                 'bağlı taslak gider başka projeye taşınamaz');
select throws_ok($$ select pg_temp.save_gd('gd', 'p1', pg_temp.id('vendor2')) $$, '23514', null,
                 'bağlı taslak giderin tedarikçisi başka cariye değiştirilemez');
select is((select project_id from public.finance_documents where id = pg_temp.id('gd')), pg_temp.id('p1'),
          'gider proje A''da kalır');
select is((pg_temp.save_gd('gd', 'p1', null, 1200, 'Plywood faturası (düzeltildi)')).amount, 1200.00::numeric,
          'aynı projede tutar ve açıklama düzeltmesi serbest; cari boşaltılabilir');
select is((pg_temp.save_gd('gd', 'p1', pg_temp.id('vendor'), 1200, 'Plywood faturası')).cari_account_id,
          pg_temp.id('vendor'), 'aynı tedarikçi yeniden seçilebilir');
select is(pg_temp.link_status(pg_temp.id('lnk')), 'aktif', 'uyumlu düzenlemeler bağlantıyı etkilemez');
select lives_ok($$ select public.approve_finance_document(pg_temp.id('gd')) $$, 'bağlı gider onaylanır');
select is(pg_temp.link_status(pg_temp.id('lnk')), 'aktif', 'onay bağlantıyı değiştirmez');

-- Gider bağlı onaylı sipariş iptal edilemez
select throws_ok($$ select public.purchase_order_transition(pg_temp.id('po'), 'iptal', 'Tedarikçi teslim edemedi') $$,
  '23514', null, 'gider bağlı sipariş iptal edilemez');

-- -----------------------------------------------------------------------------
-- Düzeltme: bağlantı yeni taslağa taşınır; iptal: bağlantı sona erer
-- -----------------------------------------------------------------------------
select is((public.revise_finance_document(pg_temp.id('gd'), pg_temp.id('gd_new'), 'Fatura tutarı hatalı girildi')).id,
          pg_temp.id('gd_new'), 'onaylı bağlı gider düzeltilir');
select is(pg_temp.link_status(pg_temp.id('lnk')), 'iptal', 'eski giderin bağlantısı sona erer');
select is((select count(*)::int from public.purchase_order_expense_links
            where finance_document_id = pg_temp.id('gd_new') and order_id = pg_temp.id('po') and status = 'aktif'), 1,
          'düzeltilmiş taslak aynı siparişe bağlanır');
select is((select count(*)::int from public.purchase_order_expense_links
            where order_id = pg_temp.id('po') and status = 'aktif'), 1, 'siparişte tek etkin gider bağlantısı kalır');
select ok((select count(*) >= 2 from public.purchase_order_events
            where order_id = pg_temp.id('po') and action in ('gider_bag_kaldir', 'gider_bagla')
              and (data ->> 'otomatik')::boolean), 'otomatik bağlantı değişiklikleri sipariş geçmişinde');
select throws_ok($$ select pg_temp.save_gd('gd_new', 'p2', pg_temp.id('vendor')) $$, '23514', null,
                 'taşınan bağlantı da yeni taslağı korur');
select lives_ok($$ select public.cancel_finance_document(pg_temp.id('gd_new'), 'Fatura reddedildi') $$,
                'bağlı taslak gider iptal edilir');
select is((select count(*)::int from public.purchase_order_expense_links
            where finance_document_id = pg_temp.id('gd_new') and status = 'aktif'), 0,
          'iptal edilen giderin bağlantısı sona erer');
select lives_ok($$ select public.purchase_order_transition(pg_temp.id('po2'), 'iptal', 'Sipariş artık gerekli değil') $$,
                'gidersiz onaylı sipariş iptal edilebilir');

-- Bağlantı kaldırıldıktan sonra meşru düzenleme
select lives_ok($$ select pg_temp.save_gd('gd3', 'p1', pg_temp.id('vendor')) $$, 'üçüncü taslak gider');
select lives_ok($$ select public.link_purchase_order_expense(pg_temp.id('lnk3'), pg_temp.id('po'), pg_temp.id('gd3')) $$,
                'üçüncü gider bağlanır');
select lives_ok($$ select public.unlink_purchase_order_expense(pg_temp.id('lnk3'), 'Yanlış sipariş') $$,
                'bağlantı kaldırılır');
select is((pg_temp.save_gd('gd3', 'p2', pg_temp.id('vendor2'))).project_id, pg_temp.id('p2'),
          'bağlantısız gider başka projeye ve cariye taşınır');

-- -----------------------------------------------------------------------------
-- Gider bağlantısında tekrar gönderim: not da karşılaştırılır
-- -----------------------------------------------------------------------------
select lives_ok($$ select pg_temp.save_gd('gd4', 'p1', pg_temp.id('vendor')) $$, 'dördüncü taslak gider');
select is((public.link_purchase_order_expense(pg_temp.id('lnk4'), pg_temp.id('po'), pg_temp.id('gd4'), 'İlk not')).status,
          'aktif', 'bağlantı notla açılır');
select is((public.link_purchase_order_expense(pg_temp.id('lnk4'), pg_temp.id('po'), pg_temp.id('gd4'), '  İlk not ')).id,
          pg_temp.id('lnk4'), 'aynı not (boşluklar normalleştirilir) aynı bağlantıyı döner');
select throws_ok($$ select public.link_purchase_order_expense(pg_temp.id('lnk4'), pg_temp.id('po'), pg_temp.id('gd4'), 'Başka not') $$,
  '23505', null, 'aynı kimlik farklı notla reddedilir');

-- -----------------------------------------------------------------------------
-- Teslimde tekrar gönderim: teslim alan kişi karşılaştırılır
-- -----------------------------------------------------------------------------
select is((public.receive_purchase_order(pg_temp.id('r1'), pg_temp.id('po'),
             jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l1'), 'quantity', 10)),
             p_document_id => pg_temp.id('doc2'), p_performed_by => 'Ali Usta')).id,
          pg_temp.id('r1'), 'teslim alınır');
select is((public.receive_purchase_order(pg_temp.id('r1'), pg_temp.id('po'),
             jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l1'), 'quantity', 10)),
             p_document_id => pg_temp.id('doc2'), p_performed_by => ' Ali Usta ')).id,
          pg_temp.id('r1'), 'aynı teslim alan kişiyle tekrar gönderim aynı teslimi döner');
select throws_ok($$ select public.receive_purchase_order(pg_temp.id('r1'), pg_temp.id('po'),
                      jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l1'), 'quantity', 10)),
                      p_document_id => pg_temp.id('doc2'), p_performed_by => 'Veli Usta') $$,
  '23505', null, 'aynı kimlik farklı teslim alan kişiyle reddedilir');
select throws_ok($$ select public.receive_purchase_order(pg_temp.id('r1'), pg_temp.id('po'),
                      jsonb_build_array(jsonb_build_object('order_line_id', pg_temp.id('l1'), 'quantity', 10)),
                      p_document_id => pg_temp.id('doc2')) $$,
  '23505', null, 'aynı kimlik teslim alan kişi boş bırakılarak gönderilirse reddedilir');
select is((select count(*)::int from public.stock_movements where purchase_receipt_id = pg_temp.id('r1')), 1,
          'tekrar gönderim ikinci stok girişi açmaz');

-- -----------------------------------------------------------------------------
-- Belge: bağlıyken başka projeye taşınamaz; iptal ve değiştirme
-- -----------------------------------------------------------------------------
select lives_ok($$ select public.link_purchase_order_document(pg_temp.id('dl'), pg_temp.id('po'), pg_temp.id('doc')) $$,
                'irsaliye siparişe bağlanır');
select throws_ok($$ select pg_temp.relink('doc', 'p2') $$, '23514', null,
                 'siparişe bağlı belge başka projeye taşınamaz');
select throws_ok($$ select pg_temp.relink('doc2', 'p2') $$, '23514', null,
                 'teslime (ve stok girişine) bağlı belge başka projeye taşınamaz');
select is((select project_id from public.documents where id = pg_temp.id('doc')), pg_temp.id('p1'),
          'belge proje A''da kalır');
select lives_ok($$ select public.link_purchase_order_document(pg_temp.id('dl3'), pg_temp.id('po'), pg_temp.id('doc3'));
                   select public.unlink_purchase_order_document(pg_temp.id('dl3'), 'Yanlış belge') $$,
                'bağlanıp kaldırılan belge');
select is((pg_temp.relink('doc3', 'p2')).project_id, pg_temp.id('p2'), 'bağlantısı kaldırılan belge taşınabilir');

-- Yeni dosyayla değiştirme (complete_document_upload akışının veri adımları):
-- bağlantı yeni belgeye geçer
select tests.clear_authentication();
insert into public.documents (id, kind, title, document_date, link_type, project_id, mime_type, byte_size, sha256,
                              storage_path, status, upload_expires_at, replaces_id, server_sha256, server_byte_size, server_verified_at)
values (pg_temp.id('doc_new'), 'irsaliye', 'İrsaliye (net)', current_date, 'proje', pg_temp.id('p1'), 'application/pdf',
        100, repeat('c', 64), gen_random_uuid() || '/y.pdf', 'bekliyor', now() + interval '1 hour', pg_temp.id('doc'), repeat('c', 64), 100, now());
update public.documents set status = 'iptal', cancelled_at = now(), cancel_reason = 'Yeni dosyayla değiştirildi'
 where id = pg_temp.id('doc');
select is((select status from public.purchase_order_documents where id = pg_temp.id('dl')), 'iptal',
          'değiştirilen belgenin bağlantısı sona erer');
select is((select count(*)::int from public.purchase_order_documents
            where order_id = pg_temp.id('po') and document_id = pg_temp.id('doc_new') and status = 'aktif'), 1,
          'bağlantı aynı kayda yüklenen yeni belgeye taşınır');
update public.documents set status = 'yuklendi', uploaded_at = now(), upload_expires_at = null where id = pg_temp.id('doc_new');

-- Belge iptali: etkin sipariş belge bağlantısı kalmaz
select tests.authenticate_as(pg_temp.id('admin'));
select lives_ok($$ select public.cancel_document(pg_temp.id('doc_new'), 'Yanlış irsaliye yüklendi') $$,
                'bağlı belge iptal edilir');
select is((select count(*)::int from public.purchase_order_documents
            where document_id = pg_temp.id('doc_new') and status = 'aktif'), 0,
          'iptal edilen belgenin sipariş bağlantısı sona erer');
select tests.clear_authentication();

select * from finish();
rollback;
