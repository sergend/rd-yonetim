-- Evrak arşivi (migration 20261106000000): özel bucket, storage.objects
-- politikaları ile belge yetkisinin uyumu, yükleme adımları (ayır → yükle →
-- tamamla), tekrar gönderim ve çakışma, finansal belge erişimi, DEMO ayrımı,
-- arşiv / iptal / değiştirme / bağlantı değişikliği geçmişi, yarım kalan ve
-- yetim yüklemeler, dosya eklemenin finans tutarlarına dokunmaması.
begin;
select plan(95);

create temp table ctx (k text primary key, v uuid) on commit drop;
create temp table paths (k text primary key, v text) on commit drop;
grant select, insert on ctx, paths to authenticated;
create function pg_temp.c(p_key text) returns uuid language sql stable
  as $$ select v from ctx where k = p_key $$;
create function pg_temp.p(p_key text) returns text language sql stable
  as $$ select v from paths where k = p_key $$;
create function pg_temp.sha(p_char text) returns text language sql immutable
  as $$ select repeat(p_char, 64) $$;
-- Yer ayırır ve yolu kaydeder (çağıran kullanıcı adına).
create function pg_temp.reserve(p_id text, p_kind text, p_link_type text, p_link text, p_sha text,
                                p_size bigint default 100, p_mime text default 'application/pdf',
                                p_title text default null, p_replaces text default null)
  returns text language plpgsql as $$
declare v text;
begin
  v := (public.reserve_document_upload(pg_temp.c(p_id), p_kind::public.document_kind, coalesce(p_title, 'Belge ' || p_id),
          p_link_type::public.document_link_type, pg_temp.c(p_link), p_mime, p_size, pg_temp.sha(p_sha),
          p_replaces_id => pg_temp.c(p_replaces))).storage_path;
  insert into paths values (p_id, v) on conflict (k) do nothing;
  return v;
end $$;
-- Storage API'nin yükleme sırasında yaptığı satır ekleme (RLS uygulanır).
create function pg_temp.put(p_path text, p_size bigint default 100, p_mime text default 'application/pdf')
  returns void language sql as $$
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values ('belgeler', p_path, auth.uid(), auth.uid()::text, jsonb_build_object('size', p_size, 'mimetype', p_mime)) $$;
create function pg_temp.complete(p_id text) returns public.documents language sql
  as $$ select public.complete_document_upload(pg_temp.c(p_id)) $$;
-- Tam yükleme: ayır + yükle + tamamla.
create function pg_temp.upload(p_id text, p_kind text, p_link_type text, p_link text, p_sha text,
                               p_replaces text default null) returns void language plpgsql as $$
begin
  perform pg_temp.reserve(p_id, p_kind, p_link_type, p_link, p_sha, p_replaces => p_replaces);
  perform pg_temp.put(pg_temp.p(p_id));
  perform pg_temp.complete(p_id);
end $$;
create function pg_temp.visible(p_id text) returns integer language sql stable
  as $$ select count(*)::int from public.documents where id = pg_temp.c(p_id) $$;
create function pg_temp.object_visible(p_id text) returns integer language sql stable
  as $$ select count(*)::int from storage.objects where bucket_id = 'belgeler' and name = pg_temp.p(p_id) $$;
create function pg_temp.status(p_id text) returns text language sql stable
  as $$ select status::text from public.documents where id = pg_temp.c(p_id) $$;

insert into ctx values
  ('admin',    tests.create_user('ev-yonetici@test.invalid')),
  ('muhasebe', tests.create_user('ev-muhasebe@test.invalid')),
  ('mudur',    tests.create_user('ev-mudur@test.invalid')),
  ('sef',      tests.create_user('ev-sef@test.invalid')),
  ('sefB',     tests.create_user('ev-sef-b@test.invalid')),
  ('viewer',   tests.create_user('ev-izleyici@test.invalid')),
  ('outsider', tests.create_user('ev-rolsuz@test.invalid')),
  ('pA',       tests.create_project('TEST-EV-A')),
  ('pB',       tests.create_project('TEST-EV-B'));
insert into public.projects (code, name, is_demo) values ('TEST-EV-DEMO', 'Demo evrak projesi', true);
insert into ctx select 'pDemo', id from public.projects where code = 'TEST-EV-DEMO';
insert into public.cost_centers (code, name) values ('TEST-EV-OFIS', 'Test ofis');
insert into ctx select 'ofis', id from public.cost_centers where code = 'TEST-EV-OFIS';
insert into public.cari_accounts (code, title, type) values ('TEST-EV-C1', 'TEST EV Taşeron', 'taseron');
insert into ctx select 'cari', id from public.cari_accounts where code = 'TEST-EV-C1';
insert into public.subcontractors (name, cari_account_id) values ('TEST EV Taşeron', pg_temp.c('cari'));
insert into ctx select 'sub', id from public.subcontractors where name = 'TEST EV Taşeron';
insert into ctx values ('cA', gen_random_uuid());
insert into public.contracts (id, contract_no, project_id, subcontractor_id, cari_account_id, title)
values (pg_temp.c('cA'), 'TEST-EV-S1', pg_temp.c('pA'), pg_temp.c('sub'), pg_temp.c('cari'), 'Kaba yapı');
insert into ctx select k, gen_random_uuid() from unnest(array[
  'fA', 'fSef', 'd1', 'd2', 'dDup', 'dB', 'fat', 'fat2', 'fis', 'soz', 'demo', 'pend', 'exp', 'size', 'mime', 'ofisDoc',
  'stray', 'x']) k;
select tests.grant_global_role(pg_temp.c('admin'),    'yonetici');
select tests.grant_global_role(pg_temp.c('muhasebe'), 'muhasebe');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('mudur'),  'proje_muduru',  '2020-01-01');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('sef'),    'santiye_sefi',  '2020-01-01');
select tests.add_member(pg_temp.c('pB'), pg_temp.c('sefB'),   'santiye_sefi',  '2020-01-01');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('viewer'), 'goruntuleyici', '2020-01-01');

-- Finans kayıtları: muhasebe gideri (onaylı) ve şefin kendi taslak gideri.
select tests.authenticate_as(pg_temp.c('muhasebe'));
select public.save_finance_document(pg_temp.c('fA'), 'gider',
         (select id from public.finance_categories where kind = 'gider' and name = 'Demir'),
         'Evrak testi demir', 1000, '2026-10-01', p_project_id => pg_temp.c('pA'), p_cari_account_id => pg_temp.c('cari'));
select tests.authenticate_as(pg_temp.c('admin'));
select public.approve_finance_document(pg_temp.c('fA'));
select tests.authenticate_as(pg_temp.c('sef'));
select public.save_finance_document(pg_temp.c('fSef'), 'gider',
         (select id from public.finance_categories where kind = 'gider' and name = 'Akaryakıt'),
         'Evrak testi akaryakıt', 250, '2026-10-02', p_project_id => pg_temp.c('pA'));
select tests.clear_authentication();
-- Belge eklemeden önceki finans durumu.
create temp table fin_before on commit drop as
  select d.id, d.amount, d.status::text, d.version, d.updated_at, d.cari_entry_id,
         (select count(*) from public.cari_entries e where e.cari_account_id = pg_temp.c('cari')) as cari_entries,
         (select count(*) from public.finance_settlements s where s.document_id = d.id) as settlements,
         v.remaining_amount
    from public.finance_documents d join public.v_finance_document_status v on v.document_id = d.id
   where d.id in (pg_temp.c('fA'), pg_temp.c('fSef'));

-- ------------------------------------------------ 1) bucket ve politikalar
select is((select public from storage.buckets where id = 'belgeler'), false, 'belgeler bucket''ı özel');
select is_empty($$ select id from storage.buckets where public $$, 'herkese açık bucket yok');
select is_empty($$ select polname from pg_policy where polrelid = 'storage.objects'::regclass and polcmd in ('w', 'd', '*') $$,
  'storage.objects üzerinde güncelleme veya silme politikası yok (üzerine yazma ve silme kapalı)');
select ok(not has_function_privilege('anon', 'public.reserve_document_upload(uuid, public.document_kind, text, public.document_link_type, uuid, text, bigint, text, date, text, uuid)', 'execute'),
  'anon yükleme yeri ayıramaz');
select ok(not has_table_privilege('authenticated', 'public.documents', 'insert')
          and not has_table_privilege('authenticated', 'public.documents', 'update'),
  'belge tablosuna doğrudan yazılamaz (yalnızca RPC)');

-- ------------------------------------------------ 2) yükleme adımları
select tests.authenticate_as(pg_temp.c('sef'));
select lives_ok($$ select pg_temp.reserve('d1', 'tutanak', 'proje', 'pA', 'a') $$, 'şef projesinde tutanak için yer ayırır');
select is(pg_temp.status('d1'), 'bekliyor', 'ayrılan belge yükleme bekliyor');
select ok(pg_temp.p('d1') ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.pdf$'
          and position(pg_temp.c('pA')::text in pg_temp.p('d1')) = 0
          and position(pg_temp.c('d1')::text in pg_temp.p('d1')) = 0,
  'depolama yolu sunucuda üretilir; proje, belge kimliği veya dosya adı içermez');
select is((select project_id from public.documents where id = pg_temp.c('d1')), pg_temp.c('pA'), 'kapsam bağlı kayıttan gelir');
select throws_ok($$ select pg_temp.complete('d1') $$, 'P0002', 'Dosya henüz yüklenmedi', 'dosya yüklenmeden tamamlanamaz');
select throws_ok($$ select pg_temp.put('rastgele/yol.pdf') $$, '42501', null, 'ayrılmamış bir yola dosya yüklenemez');

select tests.authenticate_as(pg_temp.c('sefB'));
select throws_ok(format($$ select pg_temp.put(%L) $$, pg_temp.p('d1')), '42501', null,
  'başka projedeki şef, yolu bilse de o belgeye dosya yükleyemez');

select tests.authenticate_as(pg_temp.c('sef'));
select lives_ok(format($$ select pg_temp.put(%L) $$, pg_temp.p('d1')), 'yükleyen kendi yoluna dosyayı yükler');
select is((pg_temp.complete('d1')).status::text, 'yuklendi', 'tamamlama dosyayı doğrular, belge yüklendi');
select is((pg_temp.complete('d1')).status::text, 'yuklendi', 'tamamlamanın tekrarı aynı belgeyi döner');
select throws_ok(format($$ select pg_temp.put(%L) $$, pg_temp.p('d1')), '42501', null,
  'yüklenmiş belgenin dosyası yeniden yazılamaz');
select is(pg_temp.object_visible('d1'), 1, 'yükleyen dosyayı görür');

-- ------------------------------------------------ 3) okuma yetkisi
select tests.authenticate_as(pg_temp.c('viewer'));
select is(pg_temp.visible('d1') + pg_temp.object_visible('d1'), 2, 'görüntüleyici projedeki tutanağı ve dosyasını görür');
select tests.authenticate_as(pg_temp.c('sefB'));
select is(pg_temp.visible('d1') + pg_temp.object_visible('d1'), 0, 'başka projedeki şef belgeyi ve dosyayı göremez');
select tests.authenticate_as(pg_temp.c('outsider'));
select is(pg_temp.visible('d1') + pg_temp.object_visible('d1'), 0, 'rolü olmayan kullanıcı göremez');
set local role anon;
select is((select count(*)::int from storage.objects where bucket_id = 'belgeler'), 0, 'oturumsuz istek hiçbir dosyayı görmez');
reset role;

-- ------------------------------------------------ 4) tekrar gönderim ve çakışma
select tests.authenticate_as(pg_temp.c('sef'));
select is(pg_temp.reserve('d1', 'tutanak', 'proje', 'pA', 'a'), pg_temp.p('d1'), 'aynı istek aynı belgeyi ve yolu döner');
select throws_ok($$ select pg_temp.reserve('d1', 'tutanak', 'proje', 'pA', 'b') $$, '23505', null,
  'aynı kimlikle farklı dosya (SHA-256) reddedilir');
select throws_ok($$ select pg_temp.reserve('d1', 'tutanak', 'proje', 'pA', 'a', p_title => 'Başka ad') $$, '23505', null,
  'aynı kimlikle farklı bilgi reddedilir');
select throws_ok($$ select pg_temp.reserve('d1', 'tutanak', 'proje', 'pA', 'a', 101) $$, '23505', null,
  'aynı kimlikle farklı boyut reddedilir');
select throws_ok($$ select pg_temp.reserve('dDup', 'tutanak', 'proje', 'pA', 'a') $$, '23505', 'Bu dosya bu kayda zaten eklenmiş',
  'aynı dosya aynı kayda ikinci kez eklenemez');
select tests.authenticate_as(pg_temp.c('sefB'));
select throws_ok($$ select pg_temp.reserve('d1', 'tutanak', 'proje', 'pB', 'a') $$, '23505', null,
  'başkasının belge kimliği içerik sızdırmaz');
select lives_ok($$ select pg_temp.upload('dB', 'tutanak', 'proje', 'pB', 'a') $$, 'aynı dosya başka projenin kaydına ayrı belge olarak eklenir');
select isnt(pg_temp.p('dB'), pg_temp.p('d1'), 'iki belge aynı depolama nesnesini paylaşmaz');

-- ------------------------------------------------ 5) dosya doğrulama
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok($$ select pg_temp.reserve('mime', 'tutanak', 'proje', 'pA', 'c', 100, 'image/gif') $$, '23514', null,
  'desteklenmeyen tür reddedilir');
select throws_ok($$ select pg_temp.reserve('mime', 'tutanak', 'proje', 'pA', 'c', 0) $$, '23514', null, 'boş dosya reddedilir');
select throws_ok($$ select pg_temp.reserve('mime', 'tutanak', 'proje', 'pA', 'c', 26214401) $$, '23514', null, '25 MB üstü reddedilir');
select throws_ok(format($$ select public.reserve_document_upload(%L, 'tutanak', 'X', 'proje', %L, 'application/pdf', 10, 'abc') $$,
                        pg_temp.c('mime'), pg_temp.c('pA')), '23514', null, 'geçersiz SHA-256 reddedilir');
select throws_ok(format($$ select public.reserve_document_upload(%L, 'tutanak', '  ', 'proje', %L, 'application/pdf', 10, %L) $$,
                        pg_temp.c('mime'), pg_temp.c('pA'), pg_temp.sha('c')), '23514', null, 'belge adı zorunlu');
select lives_ok($$ select pg_temp.reserve('size', 'irsaliye', 'proje', 'pA', 'd') $$, 'irsaliye için yer');
select lives_ok(format($$ select pg_temp.put(%L, 99) $$, pg_temp.p('size')), 'eksik boyutlu nesne yüklendi');
select throws_ok($$ select pg_temp.complete('size') $$, '23514', null, 'boyutu farklı dosya tamamlanmaz');
select lives_ok($$ select pg_temp.reserve('mime', 'irsaliye', 'proje', 'pA', 'e') $$, 'ikinci irsaliye için yer');
select lives_ok(format($$ select pg_temp.put(%L, 100, 'image/png') $$, pg_temp.p('mime')), 'türü farklı nesne yüklendi');
select throws_ok($$ select pg_temp.complete('mime') $$, '23514', null, 'türü farklı dosya tamamlanmaz');

-- ------------------------------------------------ 6) finansal belgeler
select throws_ok($$ select pg_temp.reserve('fat', 'fatura', 'proje', 'pA', 'f') $$, '42501', null,
  'finansal yetkisi olmayan şef projeye fatura ekleyemez');
select throws_ok($$ select pg_temp.reserve('fat', 'fatura', 'finans_belgesi', 'fA', 'f') $$, 'P0002', null,
  'şef göremediği gidere dosya ekleyemez');
select lives_ok($$ select pg_temp.upload('fis', 'fis', 'finans_belgesi', 'fSef', '1') $$, 'şef kendi giderine fiş ekler');
select is(pg_temp.visible('fis') + pg_temp.object_visible('fis'), 2, 'şef kendi gider fişini ve dosyasını görür');
select throws_ok($$ select pg_temp.reserve('soz', 'sozlesme', 'sozlesme', 'cA', '2') $$, 'P0002', null,
  'şef sözleşmeye dosya ekleyemez (sözleşmeyi göremez)');

select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok($$ select pg_temp.upload('fat', 'fatura', 'finans_belgesi', 'fA', 'f') $$, 'muhasebe onaylı gidere fatura ekler');
select results_eq(format($$ select project_id, cari_account_id, is_demo from public.documents where id = %L $$, pg_temp.c('fat')),
  format($$ values (%L::uuid, %L::uuid, false) $$, pg_temp.c('pA'), pg_temp.c('cari')),
  'gider belgesinin projesi ve carisi giderden türetilir');
select lives_ok($$ select pg_temp.upload('soz', 'sozlesme', 'sozlesme', 'cA', '2') $$, 'muhasebe sözleşme dosyası ekler');
select results_eq(format($$ select project_id, cari_account_id, subcontractor_id from public.documents where id = %L $$, pg_temp.c('soz')),
  format($$ values (%L::uuid, %L::uuid, %L::uuid) $$, pg_temp.c('pA'), pg_temp.c('cari'), pg_temp.c('sub')),
  'sözleşme dosyasının projesi, carisi ve taşeronu sözleşmeden türetilir');
select lives_ok($$ select pg_temp.upload('fat2', 'fatura', 'proje', 'pA', '3') $$, 'muhasebe proje düzeyinde fatura ekler');
select lives_ok($$ select pg_temp.upload('ofisDoc', 'fatura', 'masraf_merkezi', 'ofis', '4') $$, 'muhasebe genel masraf merkezine belge ekler');

select tests.authenticate_as(pg_temp.c('sef'));
select is(pg_temp.visible('fat') + pg_temp.object_visible('fat'), 0, 'şef gider faturasını ve dosyasını göremez');
select is(pg_temp.visible('fat2') + pg_temp.object_visible('fat2'), 0, 'şef proje faturasını göremez');
select is(pg_temp.visible('soz') + pg_temp.object_visible('soz'), 0, 'şef sözleşme dosyasını göremez');
select is(pg_temp.visible('ofisDoc'), 0, 'şef genel masraf belgesini göremez');
select tests.authenticate_as(pg_temp.c('viewer'));
select is(pg_temp.visible('fat2') + pg_temp.visible('fis') + pg_temp.visible('soz'), 0,
  'görüntüleyici finansal belgeleri göremez');
select tests.authenticate_as(pg_temp.c('mudur'));
select is(pg_temp.visible('fat') + pg_temp.visible('fat2') + pg_temp.visible('soz') + pg_temp.visible('fis'), 4,
  'proje müdürü projesindeki fatura, fiş ve sözleşme dosyalarını görür');
select throws_ok($$ select pg_temp.reserve('x', 'sozlesme', 'sozlesme', 'cA', '5') $$, '42501', null,
  'sözleşme yazma izni olmayan müdür sözleşmeye dosya ekleyemez');

-- ------------------------------------------------ 7) DEMO ayrımı
select tests.authenticate_as(pg_temp.c('admin'));
select lives_ok($$ select pg_temp.upload('demo', 'tutanak', 'proje', 'pDemo', '6') $$, 'demo projesine belge');
select is((select is_demo from public.documents where id = pg_temp.c('demo')), true, 'demo işareti projeden gelir');
select is((select is_demo from public.documents where id = pg_temp.c('d1')), false, 'gerçek proje belgesi demo değil');
select throws_ok(format($$ select public.relink_document(%L, 'proje', %L, 'Yanlış projeye eklenmişti', %s) $$,
                        pg_temp.c('demo'), pg_temp.c('pA'), (select version from public.documents where id = pg_temp.c('demo'))),
  '23514', null, 'demo belge gerçek projeye taşınamaz');

-- ------------------------------------------------ 8) arşiv, iptal, değiştirme, bağlantı
select tests.authenticate_as(pg_temp.c('sef'));
select lives_ok(format($$ select public.archive_document(%L, 'Eski tutanak') $$, pg_temp.c('d1')), 'şef kendi belgesini arşivler');
select is(pg_temp.status('d1'), 'arsivlendi', 'belge arşivde');
select throws_ok(format($$ select public.archive_document(%L, 'deneme') $$, pg_temp.c('fat')), 'P0002', null,
  'şef göremediği belgeyi arşivleyemez');
select throws_ok(format($$ select public.cancel_document(%L, 'kısa') $$, pg_temp.c('fis')), '23514', null,
  'yüklenmiş belgenin iptali gerekçe ister');
select throws_ok(format($$ select public.relink_document(%L, 'proje', %L, 'Yanlış kayda bağlanmış', 1) $$, pg_temp.c('fis'), pg_temp.c('pA')),
  '42501', null, 'şef belge bağlantısını değiştiremez');
select tests.authenticate_as(pg_temp.c('admin'));
select public.approve_finance_document(pg_temp.c('fSef'));
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok(format($$ select public.cancel_document(%L, 'Yanlış fiş yüklendi') $$, pg_temp.c('fis')), '42501', null,
  'gider onaylandıktan sonra şef fişin geçmişini değiştiremez');
select tests.authenticate_as(pg_temp.c('viewer'));
select is(pg_temp.visible('d1'), 1, 'arşivlenen belge görünür kalır');

select tests.authenticate_as(pg_temp.c('muhasebe'));
insert into ctx values ('fatNew', gen_random_uuid());
select lives_ok($$ select pg_temp.upload('fatNew', 'fatura', 'finans_belgesi', 'fA', '7', p_replaces => 'fat') $$,
  'yanlış fatura yeni dosyayla değiştirilir');
select results_eq(format($$ select status::text, cancel_reason from public.documents where id = %L $$, pg_temp.c('fat')),
  $$ values ('iptal', 'Yeni dosyayla değiştirildi') $$, 'eski dosya iptal edildi');
select is(pg_temp.object_visible('fat'), 1, 'eski dosya silinmedi, okunabilir');
select is((select replaces_id from public.documents where id = pg_temp.c('fatNew')), pg_temp.c('fat'), 'yeni belge eskisini gösterir');
select lives_ok(format($$ select public.relink_document(%L, 'proje', %L, 'Yanlış projeye eklenmişti', %s) $$,
                       pg_temp.c('fat2'), pg_temp.c('pB'),
                       (select version from public.documents where id = pg_temp.c('fat2'))),
  'muhasebe belgeyi doğru projeye bağlar');
select is((select project_id from public.documents where id = pg_temp.c('fat2')), pg_temp.c('pB'), 'proje yeni kayıttan alındı');
select tests.authenticate_as(pg_temp.c('mudur'));
select is(pg_temp.visible('fat2'), 0, 'taşınan belge eski projede görünmez');

select tests.authenticate_as(pg_temp.c('sef'));
select results_eq(format($$ select array_agg(action order by occurred_at) from public.document_events where document_id = %L $$, pg_temp.c('d1')),
  $$ values (array['rezerve', 'yuklendi', 'arsivlendi']) $$, 'geçmiş: ayrıldı, yüklendi, arşivlendi');
select tests.clear_authentication();
select ok(exists (select 1 from public.document_events where document_id = pg_temp.c('fat2') and action = 'baglanti_degisti'
                  and data -> 'eski' ->> 'project_id' = pg_temp.c('pA')::text),
  'bağlantı değişikliği eski kaydıyla geçmişte');
select throws_ok(format($$ update public.document_events set reason = 'x' where document_id = %L $$, pg_temp.c('d1')),
  '42501', null, 'geçmiş değiştirilemez');
select throws_ok(format($$ delete from public.documents where id = %L $$, pg_temp.c('d1')), '42501', null, 'belge silinemez');
select throws_ok(format($$ update public.documents set sha256 = %L where id = %L $$, pg_temp.sha('9'), pg_temp.c('d1')),
  '23514', null, 'dosya özeti değiştirilemez');

-- ------------------------------------------------ 9) yarım kalan ve yetim yüklemeler
select tests.authenticate_as(pg_temp.c('sef'));
select lives_ok($$ select pg_temp.reserve('pend', 'tutanak', 'proje', 'pA', '8') $$, 'yükleme başlatıldı');
select lives_ok(format($$ select public.cancel_document(%L, null) $$, pg_temp.c('pend')), 'yükleyen bekleyen yüklemeden vazgeçer');
select throws_ok($$ select pg_temp.reserve('pend', 'tutanak', 'proje', 'pA', '8') $$, '23505', null,
  'iptal edilmiş yükleme kimliği yeniden kullanılamaz');
select lives_ok($$ select pg_temp.reserve('exp', 'tutanak', 'proje', 'pA', 'b') $$, 'ikinci yükleme başlatıldı');
select lives_ok(format($$ select pg_temp.put(%L) $$, pg_temp.p('exp')), 'dosya yüklendi ama tamamlanmadı (ağ kesildi)');
select tests.clear_authentication();
update public.documents set upload_expires_at = now() - interval '1 minute' where id = pg_temp.c('exp');
insert into storage.objects (bucket_id, name, metadata) values ('belgeler', 'sahipsiz/' || pg_temp.c('stray') || '.pdf', '{"size": 5}');
select is(private.expire_document_uploads(), 1, 'süresi dolan yükleme iptal edilir');
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok($$ select pg_temp.complete('exp') $$, '23505', null, 'süresi dolmuş yükleme tamamlanamaz');
select tests.clear_authentication();
select set_eq($$ select name from private.document_orphan_objects(interval '0 seconds') $$,
  format($$ values (%L), (%L) $$, pg_temp.p('exp'), 'sahipsiz/' || pg_temp.c('stray') || '.pdf'),
  'yetim listesi yalnızca süresi dolan yüklemenin ve sahipsiz nesneyi içerir (süresi dolmamış bekleyenler korunur)');
select is_empty($$ select o.name from private.document_orphan_objects(interval '0 seconds') o
                    join public.documents d on d.storage_path = o.name where d.uploaded_at is not null $$,
  'yüklenmiş, arşivlenmiş veya iptal edilmiş belgenin dosyası hiçbir zaman yetim sayılmaz');
select is((select count(*)::int from private.document_orphan_objects()), 0, 'varsayılan 24 saat beklemeden yeni nesne listelenmez');
select ok(exists (select 1 from private.document_storage_manifest() where storage_path = pg_temp.p('fat'))
          and not exists (select 1 from private.document_storage_manifest() where storage_path = pg_temp.p('exp')),
  'yedek bütünlük listesi tamamlanan (iptal edilenler dahil) dosyaları içerir, tamamlanmayanları içermez');

-- ------------------------------------------------ 10) finans tutarları değişmedi
select results_eq(
  $$ select d.id, d.amount, d.cari_entry_id,
            (select count(*) from public.cari_entries e where e.cari_account_id = pg_temp.c('cari')),
            (select count(*) from public.finance_settlements s where s.document_id = d.id)
       from public.finance_documents d where d.id = pg_temp.c('fA') $$,
  $$ select id, amount, cari_entry_id, cari_entries, settlements from fin_before where id = pg_temp.c('fA') $$,
  'belge eklemek gider tutarını, cari hareketleri ve ödemeleri değiştirmez');
select results_eq(
  $$ select status::text, version, updated_at from public.finance_documents where id = pg_temp.c('fA') $$,
  $$ select status, version, updated_at from fin_before where id = pg_temp.c('fA') $$,
  'onaylı gider kaydı belge eklemeyle güncellenmedi (sürüm aynı)');
select is((select remaining_amount from public.v_finance_document_status where document_id = pg_temp.c('fA')),
  (select remaining_amount from fin_before where id = pg_temp.c('fA')), 'ödeme durumu (kalan) değişmedi');

select * from finish();
rollback;
