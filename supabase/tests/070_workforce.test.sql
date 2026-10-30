-- Taşeron, personel, ekip ve proje görevlendirmeleri: rol izinleri, proje
-- bazında veri izolasyonu, pasif kullanıcı, iletişim bilgisi gizliliği, ekip
-- üyelik geçmişi, tarih ve çakışma kuralları, taşeron–cari bütünlüğü ve
-- finansal yan etki olmaması.
begin;
select plan(69);

-- ---------------------------------------------------------------- hazırlık
create temp table ctx (k text primary key, v uuid) on commit drop;
grant select, insert on ctx to authenticated;
create function pg_temp.c(p_key text) returns uuid language sql stable
  as $$ select v from ctx where k = p_key $$;

insert into ctx values
  ('admin',    tests.create_user('ek-yonetici@test.invalid')),
  ('idari',    tests.create_user('ek-idari@test.invalid')),
  ('muhasebe', tests.create_user('ek-muhasebe@test.invalid')),
  ('sef',      tests.create_user('ek-sef@test.invalid')),
  ('viewer',   tests.create_user('ek-viewer@test.invalid')),
  ('passive',  tests.create_user('ek-pasif@test.invalid')),
  ('outsider', tests.create_user('ek-rolsuz@test.invalid')),
  ('pA',       tests.create_project('TEST-EK-A')),
  ('pB',       tests.create_project('TEST-EK-B'));
insert into public.projects (code, name, is_demo) values ('TEST-EK-DEMO', 'Demo test projesi', true);
insert into ctx select 'pDemo', id from public.projects where code = 'TEST-EK-DEMO';

select tests.grant_global_role(pg_temp.c('admin'),    'yonetici');
select tests.grant_global_role(pg_temp.c('idari'),    'idari_isler');
select tests.grant_global_role(pg_temp.c('muhasebe'), 'muhasebe');
select tests.grant_global_role(pg_temp.c('passive'),  'idari_isler');
update public.profiles set is_active = false where id = pg_temp.c('passive');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('sef'),    'santiye_sefi');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('viewer'), 'goruntuleyici');

insert into public.cari_accounts (code, title, type) values
  ('TEST-EK-C1', 'Test Kalıp Taşeronu Ltd.', 'taseron'),
  ('TEST-EK-C2', 'Test Elektrik Taşeronu', 'taseron'),
  ('TEST-EK-C3', 'Test Daire Alıcısı', 'musteri');
insert into public.cari_accounts (code, title, type, is_active) values ('TEST-EK-C4', 'Test Pasif Taşeron', 'taseron', false);
insert into ctx select 'c' || right(code, 1), id from public.cari_accounts where code like 'TEST-EK-C%';

-- ---------------------------------------------------------------- taşeron ve cari bütünlüğü
select hasnt_column('public', 'subcontractors', 'tax_number', 'taşeron kartı vergi numarası tutmaz (finansal kimlik cari karttır)');
select hasnt_column('public', 'subcontractors', 'iban', 'taşeron kartı IBAN tutmaz');

select tests.authenticate_as(pg_temp.c('admin'));
select lives_ok(
  format($$ insert into public.subcontractors (name, trade, cari_account_id, phone)
            values ('TEST Kalıp Taşeronu', 'kalip', %L, '0000 000 00 11') $$, pg_temp.c('c1')),
  'yönetici taşeronu mevcut cari karta bağlar');
insert into ctx select 's1', id from public.subcontractors where name = 'TEST Kalıp Taşeronu';
select throws_ok(
  format($$ insert into public.subcontractors (name, cari_account_id) values ('TEST Aynı Firma', %L) $$, pg_temp.c('c1')),
  '23505', null, 'aynı cari kart ikinci taşerona bağlanamaz (ikinci finansal kimlik yok)');
select throws_ok(
  format($$ insert into public.subcontractors (name, cari_account_id) values ('TEST Müşteri', %L) $$, pg_temp.c('c3')),
  '23514', null, 'müşteri carisi taşerona bağlanamaz');
select throws_ok(
  format($$ insert into public.subcontractors (name, cari_account_id) values ('TEST Pasif', %L) $$, pg_temp.c('c4')),
  '23514', null, 'pasif cari karta bağlanamaz');
select throws_ok(
  format($$ insert into public.subcontractors (name, cari_account_id, is_demo) values ('TEST Demo', %L, true) $$, pg_temp.c('c2')),
  '23514', null, 'demo taşeron gerçek cari karta bağlanamaz');

select tests.authenticate_as(pg_temp.c('idari'));
select lives_ok(
  $$ insert into public.subcontractors (name, trade) values ('TEST Elektrik Taşeronu', 'elektrik') $$,
  'idari işler cari bağlantısı olmadan taşeron açar');
insert into ctx select 's2', id from public.subcontractors where name = 'TEST Elektrik Taşeronu';
select throws_ok(
  format($$ update public.subcontractors set cari_account_id = %L where id = %L $$, pg_temp.c('c2'), pg_temp.c('s2')),
  '42501', null, 'cari kartları göremeyen kullanıcı taşeronu cariye bağlayamaz');
select lives_ok(
  format($$ insert into public.subcontractor_documents (subcontractor_id, title, valid_until)
            values (%L, 'TEST vergi levhası', '2027-12-31') $$, pg_temp.c('s1')),
  'taşerona belge kaydı eklenir');

-- ---------------------------------------------------------------- personel
select lives_ok(
  format($$ insert into public.personnel (full_name, job_title, trade, employment_type, subcontractor_id) values
              ('TEST Şirket Kalıp Ustası', 'Kalıp ustası', 'kalip', 'sirket', null),
              ('TEST Taşeron Kalfası', 'Kalfa', 'kalip', 'taseron', %1$L),
              ('TEST Taşeron İşçisi', null, null, 'taseron', %1$L),
              ('TEST B Elektrikçisi', 'Elektrikçi', 'elektrik', 'sirket', null) $$, pg_temp.c('s1')),
  'idari işler personel ekler (yalnızca ad zorunlu)');
insert into ctx select case full_name when 'TEST Şirket Kalıp Ustası' then 'p1' when 'TEST Taşeron Kalfası' then 'p2'
                                      when 'TEST Taşeron İşçisi' then 'p3' else 'p4' end, id
  from public.personnel where full_name like 'TEST %';
select throws_ok(
  $$ insert into public.personnel (full_name, employment_type) values ('TEST Taşeronsuz', 'taseron') $$,
  '23514', null, 'taşeron personelinin taşeronu belirtilmeli');
select throws_ok(
  format($$ insert into public.personnel (full_name, employment_type, subcontractor_id) values ('TEST Karışık', 'sirket', %L) $$,
         pg_temp.c('s1')),
  '23514', null, 'şirket personeli bir taşerona bağlanamaz');
select lives_ok(
  format($$ insert into public.personnel_contacts (personnel_id, phone) values (%L, '0000 000 00 21'), (%L, '0000 000 00 24') $$,
         pg_temp.c('p1'), pg_temp.c('p4')),
  'iletişim bilgisi ayrı kayıtta tutulur');
select throws_ok(
  format($$ delete from public.personnel where id = %L $$, pg_temp.c('p1')),
  '42501', null, 'personel fiziksel olarak silinemez');

-- ---------------------------------------------------------------- ekipler ve üyelik geçmişi
select lives_ok(
  format($$ insert into public.crews (name, subcontractor_id, trade, leader_id) values
              ('TEST Şirket Kalıp Ekibi', null, 'kalip', %L),
              ('TEST Taşeron Kalıp Ekibi', %L, 'kalip', %L),
              ('TEST Taşeron Demir Ekibi', %L, 'demir', null) $$,
         pg_temp.c('p1'), pg_temp.c('s1'), pg_temp.c('p2'), pg_temp.c('s1')),
  'şirkete ve taşerona bağlı ekipler sorumlusuyla açılır');
insert into ctx select case name when 'TEST Şirket Kalıp Ekibi' then 'crA' when 'TEST Taşeron Kalıp Ekibi' then 'crT'
                                 else 'crT2' end, id
  from public.crews where name like 'TEST %';
select throws_ok(
  format($$ insert into public.crews (name, leader_id) values ('TEST Yanlış Sorumlu', %L) $$, pg_temp.c('p2')),
  '23514', null, 'şirket ekibinin sorumlusu taşeron personeli olamaz');
select throws_ok(
  $$ insert into public.crews (name) values ('TEST Şirket Kalıp Ekibi') $$,
  '23505', null, 'aynı sahipte aynı adlı ikinci etkin ekip açılamaz');

select lives_ok(
  format($$ insert into public.crew_memberships (crew_id, personnel_id, start_date, end_date, role_title) values
              (%L, %L, '2026-01-01', null, 'Usta'),
              (%L, %L, '2026-01-01', '2026-03-31', 'Kalfa'),
              (%L, %L, '2026-01-01', null, 'İşçi') $$,
         pg_temp.c('crA'), pg_temp.c('p1'), pg_temp.c('crT'), pg_temp.c('p2'), pg_temp.c('crT'), pg_temp.c('p3')),
  'ekip üyelikleri başlangıç ve bitiş tarihiyle eklenir');
select throws_ok(
  format($$ insert into public.crew_memberships (crew_id, personnel_id, start_date) values (%L, %L, '2026-06-01') $$,
         pg_temp.c('crA'), pg_temp.c('p2')),
  '23514', null, 'taşeron personeli şirket ekibine katılamaz');
select throws_ok(
  format($$ insert into public.crew_memberships (crew_id, personnel_id, start_date) values (%L, %L, '2026-03-01') $$,
         pg_temp.c('crT2'), pg_temp.c('p2')),
  '23P01', null, 'kişi aynı tarihlerde ikinci bir ekibe giremez');
select throws_ok(
  format($$ insert into public.crew_memberships (crew_id, personnel_id, start_date, end_date) values (%L, %L, '2026-05-01', '2026-04-01') $$,
         pg_temp.c('crT2'), pg_temp.c('p2')),
  '23514', null, 'bitiş tarihi başlangıçtan önce olamaz');

-- p3 Mayıs sonunda kalıp ekibinden ayrılıp demir ekibine geçer.
select lives_ok(
  format($$ update public.crew_memberships set end_date = '2026-05-31' where personnel_id = %L and crew_id = %L $$,
         pg_temp.c('p3'), pg_temp.c('crT')),
  'ekipten ayrılış bitiş tarihiyle kaydedilir');
select throws_ok(
  format($$ insert into public.crew_memberships (crew_id, personnel_id, start_date) values (%L, %L, '2026-05-15') $$,
         pg_temp.c('crT2'), pg_temp.c('p3')),
  '23P01', null, 'yeni ekip üyeliği eskisinin bitişinden önce başlayamaz');
select lives_ok(
  format($$ insert into public.crew_memberships (crew_id, personnel_id, start_date) values (%L, %L, '2026-06-01') $$,
         pg_temp.c('crT2'), pg_temp.c('p3')),
  'kişi eski üyeliği bittikten sonra yeni ekibe katılır');
select is((select count(*)::int from public.crew_memberships where personnel_id = pg_temp.c('p3')), 2,
  'eski üyelik silinmez; kişinin üyelik geçmişi korunur');
select throws_ok(
  format($$ update public.crew_memberships set crew_id = %L where personnel_id = %L and crew_id = %L $$,
         pg_temp.c('crT2'), pg_temp.c('p2'), pg_temp.c('crT')),
  '23514', null, 'üyeliğin ekibi sonradan değiştirilemez');
select throws_ok($$ delete from public.crew_memberships $$, '42501', null, 'ekip üyeliği fiziksel olarak silinemez');
select throws_ok(
  format($$ update public.personnel set employment_type = 'sirket', subcontractor_id = null where id = %L $$, pg_temp.c('p3')),
  '23514', null, 'devam eden ekip üyeliği varken çalışma ilişkisi değiştirilemez');
select throws_ok(
  format($$ update public.crews set subcontractor_id = %L where id = %L $$, pg_temp.c('s2'), pg_temp.c('crT')),
  '23514', null, 'üyelik geçmişi olan ekibin taşeronu değiştirilemez');
select tests.clear_authentication();
select ok(exists (select 1 from audit.log l
                   where l.table_name = 'crew_memberships' and l.action = 'UPDATE'
                     and 'end_date' = any (l.changed_fields)),
  'üyelik bitişi işlem geçmişine yazılır');

-- ---------------------------------------------------------------- proje görevlendirmeleri
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok($$ insert into public.personnel (full_name) values ('TEST Şefin eklediği') $$,
  '42501', null, 'şantiye şefi personel kartı açamaz (şirket geneli kayıt)');
select ok((select count(*) from public.assignment_candidates(pg_temp.c('pA'))
            where name in ('TEST Şirket Kalıp Ustası', 'TEST Taşeron Kalıp Ekibi')) = 2,
  'şantiye şefi kendi projesi için seçilebilir personel ve ekipleri görür');
select hasnt_column('public', 'personnel', 'phone', 'personel tablosunda telefon yok (iletişim ayrı ve ayrı izinli)');
select throws_ok(format($$ select * from public.assignment_candidates(%L) $$, pg_temp.c('pB')),
  '42501', null, 'başka projenin seçim listesi açılmaz');
select lives_ok(
  format($$ insert into public.project_assignments (project_id, crew_id, start_date, description)
            values (%L, %L, '2026-01-01', 'TEST kaba inşaat kalıp işleri') $$, pg_temp.c('pA'), pg_temp.c('crT')),
  'şantiye şefi projesine ekip görevlendirir');
select lives_ok(
  format($$ insert into public.project_assignments (project_id, personnel_id, start_date) values (%L, %L, '2026-02-01') $$,
         pg_temp.c('pA'), pg_temp.c('p1')),
  'şantiye şefi projesine personel görevlendirir');
select throws_ok(
  format($$ insert into public.project_assignments (project_id, personnel_id, start_date) values (%L, %L, '2026-03-01') $$,
         pg_temp.c('pA'), pg_temp.c('p1')),
  '23P01', null, 'aynı kişi aynı projeye çakışan tarihlerle ikinci kez görevlendirilemez');
select throws_ok(
  format($$ insert into public.project_assignments (project_id, personnel_id, start_date, end_date)
            values (%L, %L, '2026-02-01', '2026-01-01') $$, pg_temp.c('pA'), pg_temp.c('p2')),
  '23514', null, 'görevlendirme bitişi başlangıçtan önce olamaz');
select throws_ok(
  format($$ insert into public.project_assignments (project_id, personnel_id, start_date) values (%L, %L, '2026-01-01') $$,
         pg_temp.c('pB'), pg_temp.c('p4')),
  '42501', null, 'şantiye şefi başka projeye görevlendirme yapamaz');
select lives_ok(
  format($$ insert into public.subcontractor_projects (subcontractor_id, project_id, start_date, scope)
            values (%L, %L, '2026-01-01', 'TEST kaba inşaat') $$, pg_temp.c('s1'), pg_temp.c('pA')),
  'şantiye şefi taşeronu projesine kaydeder');
select throws_ok(
  format($$ insert into public.subcontractor_projects (subcontractor_id, project_id, start_date) values (%L, %L, '2026-06-01') $$,
         pg_temp.c('s1'), pg_temp.c('pA')),
  '23P01', null, 'taşeron aynı projeye çakışan dönemle ikinci kez kaydedilemez');

select tests.authenticate_as(pg_temp.c('admin'));
select lives_ok(
  format($$ insert into public.project_assignments (project_id, personnel_id, start_date) values (%L, %L, '2026-02-01'),
                                                                                                (%L, %L, '2026-01-01') $$,
         pg_temp.c('pB'), pg_temp.c('p1'), pg_temp.c('pB'), pg_temp.c('p4')),
  'aynı kişi aynı dönemde farklı projelerde görevli olabilir');
select lives_ok(
  format($$ insert into public.project_assignments (project_id, crew_id, start_date) values (%L, %L, '2026-01-01') $$,
         pg_temp.c('pB'), pg_temp.c('crA')),
  'şirket ekibi B projesine görevlendirilir');
select throws_ok(
  format($$ update public.project_assignments set project_id = %L where project_id = %L and personnel_id = %L $$,
         pg_temp.c('pB'), pg_temp.c('pA'), pg_temp.c('p1')),
  '23514', null, 'görevlendirmenin projesi sonradan değiştirilemez');
select throws_ok(
  format($$ insert into public.project_assignments (project_id, personnel_id, start_date) values (%L, %L, '2026-01-01') $$,
         pg_temp.c('pDemo'), pg_temp.c('p1')),
  '23514', null, 'gerçek personel demo projeye görevlendirilemez');
select throws_ok($$ delete from public.project_assignments $$, '42501', null, 'görevlendirme fiziksel olarak silinemez');

-- ---------------------------------------------------------------- proje bazında izolasyon
select tests.authenticate_as(pg_temp.c('sef'));
select results_eq(
  $$ select full_name from public.personnel where full_name like 'TEST %' order by full_name $$,
  $$ values ('TEST Şirket Kalıp Ustası'), ('TEST Taşeron İşçisi'), ('TEST Taşeron Kalfası') $$,
  'şantiye şefi yalnızca projesinde (doğrudan veya ekiple) çalışan personeli görür');
select results_eq(
  $$ select name from public.crews where name like 'TEST %' $$, $$ values ('TEST Taşeron Kalıp Ekibi') $$,
  'şantiye şefi yalnızca projesine görevli ekibi görür');
select is((select count(*)::int from public.crew_memberships), 2,
  'ekibin başka dönemdeki/başka ekipteki üyelikleri görünmez (yalnızca projedeki dönemle çakışanlar)');
select is((select count(*)::int from public.project_assignments where project_id = pg_temp.c('pB')), 0,
  'şantiye şefi başka projenin görevlendirmelerini görmez');
select results_eq(
  $$ select phone from public.personnel_contacts $$, $$ values ('0000 000 00 21') $$,
  'şantiye şefi yalnızca projesindeki personelin telefonunu görür');
select results_eq(
  $$ select name from public.subcontractors where name like 'TEST %' $$, $$ values ('TEST Kalıp Taşeronu') $$,
  'şantiye şefi yalnızca projesinde çalışan taşeronu görür');
select is((select count(*)::int from public.subcontractor_documents), 1, 'projedeki taşeronun belgeleri görünür');
select results_eq(
  format($$ select full_name, via from public.project_workforce(%L, '2026-02-15') $$, pg_temp.c('pA')),
  $$ values ('TEST Şirket Kalıp Ustası', 'dogrudan'), ('TEST Taşeron İşçisi', 'ekip'), ('TEST Taşeron Kalfası', 'ekip') $$,
  'belirli bir günde projede çalışanlar: doğrudan ve ekip üzerinden');
select results_eq(
  format($$ select full_name from public.project_workforce(%L, '2026-07-01') $$, pg_temp.c('pA')),
  $$ values ('TEST Şirket Kalıp Ustası') $$,
  'ekipten ayrılan ve başka ekibe geçen kişi o günün listesinde yer almaz');

select tests.authenticate_as(pg_temp.c('viewer'));
select is((select count(*)::int from public.personnel where full_name like 'TEST %'), 3, 'görüntüleyici projesinin personelini görür');
select is((select count(*)::int from public.personnel_contacts), 0, 'görüntüleyici iletişim bilgisini göremez');
select throws_ok(
  format($$ insert into public.project_assignments (project_id, personnel_id, start_date) values (%L, %L, '2027-01-01') $$,
         pg_temp.c('pA'), pg_temp.c('p2')),
  '42501', null, 'görüntüleyici görevlendirme yapamaz');

select tests.authenticate_as(pg_temp.c('muhasebe'));
select is((select count(*)::int from public.personnel where full_name like 'TEST %'), 4, 'muhasebe tüm personeli görür');
select is((select count(*)::int from public.personnel_contacts), 0, 'muhasebe personel iletişim bilgisini göremez');
select throws_ok($$ insert into public.crews (name) values ('TEST Muhasebe ekibi') $$, '42501', null,
  'muhasebe ekip açamaz');

select tests.authenticate_as(pg_temp.c('passive'));
select is((select count(*)::int from public.personnel), 0, 'pasif kullanıcı personeli göremez');
select is((select count(*)::int from public.subcontractors), 0, 'pasif kullanıcı taşeronları göremez');
select is((select count(*)::int from public.project_assignments), 0, 'pasif kullanıcı görevlendirmeleri göremez');
select throws_ok($$ insert into public.personnel (full_name) values ('TEST pasif ekledi') $$, '42501', null,
  'pasif kullanıcı kayıt ekleyemez');

select tests.authenticate_as(pg_temp.c('outsider'));
select is((select count(*)::int from public.crews), 0, 'rolü olmayan kullanıcı ekip göremez');

-- ---------------------------------------------------------------- finansal yan etki yok
select tests.clear_authentication();
select is((select count(*)::int from public.cari_entries e
            where e.cari_account_id in (pg_temp.c('c1'), pg_temp.c('c2'))), 0,
  'taşeron, personel ve görevlendirme kayıtları cari hareket (borç) oluşturmaz');
select is_empty(
  $$ select distinct p.proname from pg_trigger t join pg_proc p on p.oid = t.tgfoid
      join pg_class c on c.oid = t.tgrelid
     where c.relname in ('subcontractors', 'subcontractor_projects', 'personnel', 'crews',
                         'crew_memberships', 'project_assignments')
       and pg_get_functiondef(p.oid) ilike '%cari_entries%' $$,
  'yeni tablolardaki hiçbir trigger cari deftere yazmaz');

select * from finish();
rollback;
