-- Sunucuda SHA-256 doğrulaması (migration 20261107000000): yüklenen dosyanın
-- gerçek baytlarının özeti (belge-dogrula Edge Function'ı hesaplar,
-- service_role yazar) beyan edilenle aynı değilse belge "yüklendi" olamaz.
-- Özellikle aynı boyut ve aynı MIME türünde farklı içerik reddedilir.
begin;
select plan(26);

create temp table ctx (k text primary key, v uuid) on commit drop;
create temp table paths (k text primary key, v text) on commit drop;
grant select, insert on ctx, paths to authenticated, service_role;
create function pg_temp.c(p_key text) returns uuid language sql stable
  as $$ select v from ctx where k = p_key $$;
create function pg_temp.p(p_key text) returns text language sql stable
  as $$ select v from paths where k = p_key $$;
create function pg_temp.sha(p_char text) returns text language sql immutable
  as $$ select repeat(p_char, 64) $$;
create function pg_temp.reserve(p_id text, p_sha text, p_size bigint default 100) returns void language plpgsql as $$
begin
  insert into paths values (p_id, (public.reserve_document_upload(pg_temp.c(p_id), 'tutanak', 'Belge ' || p_id, 'proje',
                                     pg_temp.c('pA'), 'application/pdf', p_size, pg_temp.sha(p_sha))).storage_path);
end $$;
-- Storage API'nin yükleme sırasında eklediği satır: boyut ve tür beyanla aynı.
create function pg_temp.put(p_id text, p_size bigint default 100) returns void language sql as $$
  insert into storage.objects (bucket_id, name, owner, owner_id, metadata)
  values ('belgeler', pg_temp.p(p_id), auth.uid(), auth.uid()::text,
          jsonb_build_object('size', p_size, 'mimetype', 'application/pdf')) $$;
create function pg_temp.status(p_id text) returns text language sql stable
  as $$ select status::text from public.documents where id = pg_temp.c(p_id) $$;
grant execute on function pg_temp.c(text), pg_temp.sha(text) to service_role;

insert into ctx values
  ('sef',   tests.create_user('oz-sef@test.invalid')),
  ('sef2',  tests.create_user('oz-sef2@test.invalid')),
  ('pA',    tests.create_project('TEST-OZ-A'));
insert into ctx select k, gen_random_uuid() from unnest(array['farkli', 'boyut', 'dogru', 'bos', 'beklemede']) k;
select tests.add_member(pg_temp.c('pA'), pg_temp.c('sef'),  'santiye_sefi', '2020-01-01');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('sef2'), 'santiye_sefi', '2020-01-01');

-- ------------------------------------------------ 1) ayrıcalıklar
select ok(not has_function_privilege('authenticated', 'public.record_document_server_hash(uuid, text, bigint)', 'execute'),
  'oturum açmış kullanıcı sunucu özetini yazamaz');
select ok(not has_function_privilege('anon', 'public.record_document_server_hash(uuid, text, bigint)', 'execute'),
  'oturumsuz istek sunucu özetini yazamaz');
select ok(has_function_privilege('service_role', 'public.record_document_server_hash(uuid, text, bigint)', 'execute'),
  'yalnızca sunucu (service_role, Edge Function) sunucu özetini yazar');
select ok(not has_function_privilege('anon', 'public.document_upload_target(uuid)', 'execute'),
  'oturumsuz istek doğrulama hedefini soramaz');

-- ------------------------------------------------ 2) doğrulamasız tamamlama yok
select tests.authenticate_as(pg_temp.c('sef'));
select pg_temp.reserve('farkli', 'a');
select pg_temp.reserve('boyut', 'a');
select pg_temp.reserve('dogru', 'c');
select pg_temp.reserve('bos', 'd');
select pg_temp.reserve('beklemede', 'e');
select pg_temp.put('farkli');
select pg_temp.put('boyut');
select pg_temp.put('dogru');
select pg_temp.put('beklemede');
select throws_ok($$ select public.record_document_server_hash(pg_temp.c('dogru'), repeat('c', 64), 100) $$, '42501', null,
  'kullanıcı kendi dosyasının özetini "doğrulandı" diye yazamaz');
select throws_ok($$ select public.complete_document_upload(pg_temp.c('dogru')) $$, '23514',
  'Dosyanın özeti sunucuda henüz doğrulanmadı', 'sunucu özeti olmadan belge tamamlanmaz (yalnızca istemci beyanı yetmez)');
select is(pg_temp.status('dogru'), 'bekliyor', 'doğrulanmamış belge yükleme bekliyor');
select is((select storage_path from public.document_upload_target(pg_temp.c('dogru'))), pg_temp.p('dogru'),
  'yükleyen doğrulama hedefini (yolu) alır');
select tests.authenticate_as(pg_temp.c('sef2'));
select throws_ok($$ select * from public.document_upload_target(pg_temp.c('dogru')) $$, 'P0002', 'Belge bulunamadı',
  'başka kullanıcı (aynı projede bile) başkasının yüklemesini doğrulatamaz');

-- ------------------------------------------------ 3) sunucu adımı (service_role)
select tests.clear_authentication();
set local role service_role;
select throws_ok($$ select public.record_document_server_hash(pg_temp.c('bos'), repeat('d', 64), 100) $$, 'P0002',
  'Dosya henüz yüklenmedi', 'Storage''da nesne yoksa doğrulama yapılmaz');
select is((select matches from public.record_document_server_hash(pg_temp.c('farkli'), repeat('b', 64), 100)), false,
  'aynı boyut ve aynı türde FARKLI içerik: özet uyuşmuyor');
select is((select matches from public.record_document_server_hash(pg_temp.c('boyut'), repeat('a', 64), 99)), false,
  'özet aynı ama gerçek boyut farklı: uyuşmuyor');
select is((select matches from public.record_document_server_hash(pg_temp.c('dogru'), repeat('c', 64), 100)), true,
  'dürüst yükleme: sunucu özeti beyanla aynı');
select is((select matches from public.record_document_server_hash(pg_temp.c('dogru'), repeat('f', 64), 100)), false,
  'ikinci (farklı) sunucu özeti kaydı değiştirmez');
reset role;

select is(pg_temp.status('farkli'), 'iptal', 'özeti uyuşmayan yükleme iptal edilir');
select is(pg_temp.status('boyut'), 'iptal', 'boyutu uyuşmayan yükleme iptal edilir');
select is((select to_status || ':' || (data ->> 'sunucu_sha256') from public.document_events
            where document_id = pg_temp.c('farkli') and action = 'ozet_uyusmadi'),
  'iptal:' || repeat('b', 64), 'uyuşmazlık sunucu özetiyle birlikte geçmişe yazılır');
select is((select server_sha256 from public.documents where id = pg_temp.c('dogru')), repeat('c', 64),
  'ilk sunucu özeti korunur');

-- ------------------------------------------------ 4) tamamlama
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok($$ select public.complete_document_upload(pg_temp.c('farkli')) $$, '23505',
  'Sunucuya ulaşan dosya cihazdakiyle aynı değil; yeniden yükleyin',
  'farklı içerikli dosya "yüklendi" olmaz; açık hata');
select throws_ok($$ select pg_temp.reserve('farkli', 'a') $$, '23505', null,
  'reddedilen kimlik yeniden kullanılmaz (yeni kimlik ve yeni yol gerekir)');
select is((public.complete_document_upload(pg_temp.c('dogru'))).status::text, 'yuklendi',
  'sunucuda doğrulanan dosya tamamlanır');
select is((select data ->> 'sunucuda_dogrulandi' from public.document_events
            where document_id = pg_temp.c('dogru') and action = 'yuklendi'), 'true',
  'yükleme olayı sunucu doğrulamasını kaydeder');

-- ------------------------------------------------ 5) ikinci savunma: tetikleyici ve kısıt
select tests.clear_authentication();
select throws_ok($$ update public.documents set server_sha256 = repeat('0', 64) where id = pg_temp.c('dogru') $$, '23514',
  'Sunucu doğrulaması bir kez yazılır', 'sunucu özeti sonradan değiştirilemez');
select throws_ok($$ update public.documents set status = 'yuklendi', uploaded_at = now(), upload_expires_at = null
                     where id = pg_temp.c('beklemede') $$, '23514', null,
  'sunucu özeti olmadan belge yüklendi durumuna geçemez (kısıt)');

-- ------------------------------------------------ 6) yedek manifesti yalnızca doğrulanmış özetler
select is((select sha256 from private.document_storage_manifest() where storage_path = pg_temp.p('dogru')), repeat('c', 64),
  'manifest sunucuda doğrulanan özeti içerir');
select is((select count(*)::int from private.document_storage_manifest()
            where storage_path in (pg_temp.p('farkli'), pg_temp.p('boyut'), pg_temp.p('beklemede'))), 0,
  'doğrulanmamış veya reddedilmiş dosya manifestte güvenilir referans olmaz');

select * from finish();
rollback;
