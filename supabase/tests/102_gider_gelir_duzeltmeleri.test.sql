-- PR #7 inceleme düzeltmeleri (migration 20261105000000):
--   1) Taslağı yalnızca onu görebilen kullanıcı düzenler / tekrar gönderir:
--      iki şantiye şefi ve proje müdürü; iptal, onay ve düzeltme yetkisi.
--   2) Tekrar gönderim tüm niyet alanlarını karşılaştırır (belge referansı,
--      not, bildiren; ödeyen, açıklama); iptal edilmiş ödeme kimliği etkin
--      ödeme gibi dönmez.
begin;
select plan(32);

create temp table ctx (k text primary key, v uuid) on commit drop;
grant select, insert on ctx to authenticated;
create function pg_temp.c(p_key text) returns uuid language sql stable
  as $$ select v from ctx where k = p_key $$;
create function pg_temp.cat() returns uuid language sql stable
  as $$ select id from public.finance_categories where kind = 'gider' and name = 'Demir' $$;
-- Taslak kaydı / güncellemesi (çağıran kullanıcı adına).
create function pg_temp.save(p_id text, p_amount numeric, p_version integer default null,
                             p_ref text default null, p_notes text default null)
  returns public.finance_documents language sql
  as $$ select public.save_finance_document(pg_temp.c(p_id), 'gider', pg_temp.cat(), 'Düzeltme testi ' || p_id,
          p_amount, '2026-10-01', p_project_id => pg_temp.c('pA'), p_document_ref => p_ref, p_notes => p_notes,
          p_expected_version => p_version) $$;
create function pg_temp.amount(p_id text) returns numeric language sql stable
  as $$ select amount from public.finance_documents where id = pg_temp.c(p_id) $$;
create function pg_temp.ver(p_id text) returns integer language sql stable
  as $$ select version from public.finance_documents where id = pg_temp.c(p_id) $$;

insert into ctx values
  ('admin',    tests.create_user('fd-yonetici@test.invalid')),
  ('muhasebe', tests.create_user('fd-muhasebe@test.invalid')),
  ('mudur',    tests.create_user('fd-mudur@test.invalid')),
  ('sef1',     tests.create_user('fd-sef1@test.invalid')),
  ('sef2',     tests.create_user('fd-sef2@test.invalid')),
  ('pA',       tests.create_project('TEST-FD-A'));
insert into ctx select k, gen_random_uuid() from unnest(array[
  'd1', 'd2', 'd3', 'dRef', 'dPesin', 'dPay', 's1', 's2']) k;
select tests.grant_global_role(pg_temp.c('admin'),    'yonetici');
select tests.grant_global_role(pg_temp.c('muhasebe'), 'muhasebe');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('mudur'), 'proje_muduru', '2020-01-01');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('sef1'),  'santiye_sefi', '2020-01-01');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('sef2'),  'santiye_sefi', '2020-01-01');
insert into public.payment_sources (name, kind) values ('TEST FD Şirket', 'sirket'), ('TEST FD Kart', 'kart');
insert into ctx select case name when 'TEST FD Şirket' then 'src' else 'card' end, id
  from public.payment_sources where name like 'TEST FD %';

-- ------------------------------------------- 1) taslak düzenleme yetkisi
select tests.authenticate_as(pg_temp.c('sef1'));
select lives_ok($$ select pg_temp.save('d1', 1000) $$, 'şef 1 kendi taslağını girer');
select tests.authenticate_as(pg_temp.c('mudur'));
select lives_ok($$ select pg_temp.save('d2', 2000) $$, 'proje müdürü taslak girer');

select tests.authenticate_as(pg_temp.c('sef2'));
select is((select count(*)::int from public.finance_documents where id in (pg_temp.c('d1'), pg_temp.c('d2'))), 0,
  'şef 2 diğerlerinin taslaklarını görmez');
select throws_ok($$ select pg_temp.save('d1', 1, 1) $$, '23505', null,
  'şef 2, şef 1''in taslağını kimliğini ve sürümünü bilse de değiştiremez');
select throws_ok($$ select pg_temp.save('d2', 1, 1) $$, '23505', null,
  'şef 2, müdürün taslağını değiştiremez');
select throws_ok($$ select pg_temp.save('d1', 1000) $$, '23505', null,
  'görmediği belgenin kimliğiyle tekrar gönderim içerik döndürmez');
select throws_ok(format($$ select public.cancel_finance_document(%L, 'başkasının taslağı') $$, pg_temp.c('d1')),
  'P0002', null, 'şef 2 başkasının taslağını iptal edemez');
select throws_ok(format($$ select public.approve_finance_document(%L) $$, pg_temp.c('d1')),
  'P0002', null, 'şef 2 başkasının taslağını onaylayamaz');
select throws_ok(format($$ select public.revise_finance_document(%L, gen_random_uuid(), 'başkasının belgesi düzeltme') $$,
                        pg_temp.c('d2')),
  'P0002', null, 'şef 2 başkasının belgesini düzeltemez');

select tests.authenticate_as(pg_temp.c('sef1'));
select throws_ok($$ select pg_temp.save('d2', 1, 1) $$, '23505', null, 'şef 1 müdürün taslağını değiştiremez');
select lives_ok($$ select pg_temp.save('d1', 1500, 1) $$, 'şef 1 kendi taslağını günceller');
select is(pg_temp.amount('d1'), 1500.00::numeric, 'sahibin güncellemesi yazıldı');
select lives_ok(format($$ select public.cancel_finance_document(%L, 'yanlış giriş') $$, pg_temp.c('d1')),
  'şef 1 kendi taslağını iptal eder');

select tests.authenticate_as(pg_temp.c('mudur'));
select lives_ok($$ select pg_temp.save('d3', 300) $$, 'müdür ikinci taslağı girer');
select tests.authenticate_as(pg_temp.c('sef1'));
select lives_ok($$ select public.save_finance_document(pg_temp.c('dPesin'), 'gider', pg_temp.cat(), 'Şef taslağı',
                    500, '2026-10-01', p_project_id => pg_temp.c('pA')) $$, 'şef 1 yeni taslak girer');
select tests.authenticate_as(pg_temp.c('mudur'));
select lives_ok(format($$ select public.save_finance_document(%L, 'gider', pg_temp.cat(), 'Müdür düzeltti', 550,
                          '2026-10-01', p_project_id => pg_temp.c('pA'), p_expected_version => %s) $$,
                       pg_temp.c('dPesin'), pg_temp.ver('dPesin')),
  'okuma izni olan proje müdürü şefin taslağını düzeltebilir (yetkili davranış korunur)');
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok(format($$ select pg_temp.save('d3', 350, %s) $$, pg_temp.ver('d3')),
  'muhasebe kapsamındaki taslağı düzenler');

-- ------------------------------------------- 2) tekrar gönderim alanları
select tests.authenticate_as(pg_temp.c('muhasebe'));
select lives_ok($$ select pg_temp.save('dRef', 900, null, 'Fiş 1', 'not A') $$, 'referans ve notlu taslak');
select is((pg_temp.save('dRef', 900, null, '  Fiş 1 ', 'not A')).id, pg_temp.c('dRef'),
  'aynı istek (boşluk farkı) aynı belgeyi döner');
select throws_ok($$ select pg_temp.save('dRef', 900, null, 'Fiş 2', 'not A') $$, '23505', null,
  'farklı belge referansı aynı kimlikle reddedilir');
select throws_ok($$ select pg_temp.save('dRef', 900, null, 'Fiş 1', 'not B') $$, '23505', null,
  'farklı not aynı kimlikle reddedilir');
select lives_ok(format($$ select public.save_finance_document(%L, 'gider', pg_temp.cat(), 'Peşin akaryakıt', 100,
                          '2026-10-01', p_project_id => %L, p_reported_settled => true,
                          p_reported_source_id => %L, p_reported_by => 'Kürşat') $$,
                       gen_random_uuid(), pg_temp.c('pA'), pg_temp.c('card')),
  'peşin bildirilmiş taslak');
insert into ctx select 'dRep', id from public.finance_documents where description = 'Peşin akaryakıt';
select throws_ok(format($$ select public.save_finance_document(%L, 'gider', pg_temp.cat(), 'Peşin akaryakıt', 100,
                           '2026-10-01', p_project_id => %L, p_reported_settled => true,
                           p_reported_source_id => %L, p_reported_by => 'Başkası') $$,
                        pg_temp.c('dRep'), pg_temp.c('pA'), pg_temp.c('card')),
  '23505', null, 'farklı bildiren kişi aynı kimlikle reddedilir');

select tests.authenticate_as(pg_temp.c('admin'));
select lives_ok($$ select pg_temp.save('dPay', 1000) $$, 'ödenecek belge');
select lives_ok(format($$ select public.approve_finance_document(%L) $$, pg_temp.c('dPay')), 'onay');
select lives_ok(format($$ select public.record_finance_settlement(%L, %L, 400, %L, '2026-10-05', 'Ali', 'kısmi') $$,
                       pg_temp.c('s1'), pg_temp.c('dPay'), pg_temp.c('src')), 'ödeme');
select is((public.record_finance_settlement(pg_temp.c('s1'), pg_temp.c('dPay'), 400, pg_temp.c('src'), '2026-10-05',
                                            ' Ali ', 'kısmi')).id, pg_temp.c('s1'),
  'aynı ödeme isteği aynı kaydı döner');
select throws_ok(format($$ select public.record_finance_settlement(%L, %L, 400, %L, '2026-10-05', 'Veli', 'kısmi') $$,
                        pg_temp.c('s1'), pg_temp.c('dPay'), pg_temp.c('src')),
  '23505', null, 'farklı ödeyen kişi aynı kimlikle reddedilir');
select throws_ok(format($$ select public.record_finance_settlement(%L, %L, 400, %L, '2026-10-05', 'Ali', 'tamamı') $$,
                        pg_temp.c('s1'), pg_temp.c('dPay'), pg_temp.c('src')),
  '23505', null, 'farklı açıklama aynı kimlikle reddedilir');
select lives_ok(format($$ select public.cancel_finance_settlement(%L, 'yanlış kaynaktan girildi') $$, pg_temp.c('s1')),
  'ödeme iptal edildi');
select throws_ok(format($$ select public.record_finance_settlement(%L, %L, 400, %L, '2026-10-05', 'Ali', 'kısmi') $$,
                        pg_temp.c('s1'), pg_temp.c('dPay'), pg_temp.c('src')),
  '23505', null, 'iptal edilmiş ödemenin kimliğiyle tekrar deneme etkin ödeme gibi dönmez');
select results_eq(format($$ select s.status, v.remaining_amount from public.finance_settlements s
                             join public.v_finance_document_status v on v.document_id = s.document_id
                            where s.id = %L $$, pg_temp.c('s1')),
  $$ values ('iptal'::text, 1000.00::numeric) $$, 'ödeme iptal kaldı; kalan geri açıldı');

select * from finish();
rollback;
