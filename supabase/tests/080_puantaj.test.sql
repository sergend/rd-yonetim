-- Puantaj: günlük kayıt kuralları, tarihli ekip/proje bağlantısı, ay uzunlukları
-- ve artık yıl, özet sayımları, toplu kayıt ve tekrar gönderim, eşzamanlı
-- değişiklik, onay/kilit/yeniden açma ve audit, yetki ve proje izolasyonu,
-- demo ayrımı ve finansal yan etki olmaması.
begin;
select plan(94);

-- ---------------------------------------------------------------- hazırlık
create temp table ctx (k text primary key, v uuid) on commit drop;
grant select, insert on ctx to authenticated;
create function pg_temp.c(p_key text) returns uuid language sql stable
  as $$ select v from ctx where k = p_key $$;

-- Tek hücre öğesi.
create function pg_temp.item(p_person text, p_day date, p_status text,
                             p_ot numeric default 0, p_version integer default null)
returns jsonb language sql stable
  as $$ select jsonb_build_object('personnel_id', pg_temp.c(p_person), 'work_date', p_day, 'status', p_status,
                                  'overtime_hours', p_ot, 'expected_version', p_version) $$;

create function pg_temp.ver(p_project text, p_person text, p_day date) returns integer language sql stable
  as $$ select e.version from public.puantaj_entries e
         where e.project_id = pg_temp.c(p_project) and e.personnel_id = pg_temp.c(p_person) and e.work_date = p_day $$;

create temp table start_counts on commit drop as select count(*)::int as cari from public.cari_entries;
grant select on start_counts to authenticated;

insert into ctx values
  ('admin',    tests.create_user('pt-yonetici@test.invalid')),
  ('mudur',    tests.create_user('pt-mudur@test.invalid')),
  ('sef',      tests.create_user('pt-sef@test.invalid')),
  ('sefB',     tests.create_user('pt-sef-b@test.invalid')),
  ('idari',    tests.create_user('pt-idari@test.invalid')),
  ('muhasebe', tests.create_user('pt-muhasebe@test.invalid')),
  ('viewer',   tests.create_user('pt-viewer@test.invalid')),
  ('passive',  tests.create_user('pt-pasif@test.invalid')),
  ('outsider', tests.create_user('pt-rolsuz@test.invalid')),
  ('pA',       tests.create_project('TEST-PT-A')),
  ('pB',       tests.create_project('TEST-PT-B'));
insert into public.projects (code, name, is_demo) values ('TEST-PT-DEMO', 'Demo puantaj projesi', true);
insert into ctx select 'pDemo', id from public.projects where code = 'TEST-PT-DEMO';

select tests.grant_global_role(pg_temp.c('admin'),    'yonetici');
select tests.grant_global_role(pg_temp.c('idari'),    'idari_isler');
select tests.grant_global_role(pg_temp.c('muhasebe'), 'muhasebe');
select tests.grant_global_role(pg_temp.c('passive'),  'idari_isler');
update public.profiles set is_active = false where id = pg_temp.c('passive');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('mudur'),  'proje_muduru', '2020-01-01');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('sef'),    'santiye_sefi', '2020-01-01');
select tests.add_member(pg_temp.c('pB'), pg_temp.c('sefB'),   'santiye_sefi', '2020-01-01');
select tests.add_member(pg_temp.c('pA'), pg_temp.c('viewer'), 'goruntuleyici', '2020-01-01');

insert into public.personnel (full_name, job_title) values
  ('TEST PT Gezici Usta', 'Usta'), ('TEST PT Kalfa', 'Kalfa'), ('TEST PT Tekniker', 'Tekniker');
insert into public.personnel (full_name, is_demo) values ('TEST PT Demo İşçi', true);
insert into ctx select case full_name when 'TEST PT Gezici Usta' then 'k1' when 'TEST PT Kalfa' then 'k2'
                                      when 'TEST PT Tekniker' then 'k3' else 'kDemo' end, id
  from public.personnel where full_name like 'TEST PT %';
insert into public.crews (name) values ('TEST PT A Ekibi'), ('TEST PT B Ekibi');
insert into ctx select case name when 'TEST PT A Ekibi' then 'crewA' else 'crewB' end, id
  from public.crews where name like 'TEST PT %';

-- k1: 1–10 Mart A ekibinde, 11 Mart'tan itibaren B ekibinde. B ekibi 20 Mart'a
-- kadar A projesinde, 21 Mart'tan itibaren B projesinde. k2 2024'ten beri A ekibinde.
-- k3 iki projeye aynı anda doğrudan görevli.
insert into public.crew_memberships (crew_id, personnel_id, start_date, end_date) values
  (pg_temp.c('crewA'), pg_temp.c('k1'), '2026-03-01', '2026-03-10'),
  (pg_temp.c('crewB'), pg_temp.c('k1'), '2026-03-11', null),
  (pg_temp.c('crewA'), pg_temp.c('k2'), '2024-01-01', null);
insert into public.project_assignments (project_id, crew_id, personnel_id, start_date, end_date) values
  (pg_temp.c('pA'), pg_temp.c('crewA'), null, '2024-01-01', null),
  (pg_temp.c('pA'), pg_temp.c('crewB'), null, '2026-03-01', '2026-03-20'),
  (pg_temp.c('pB'), pg_temp.c('crewB'), null, '2026-03-21', null),
  (pg_temp.c('pA'), null, pg_temp.c('k3'), '2024-01-01', null),
  (pg_temp.c('pB'), null, pg_temp.c('k3'), '2026-03-01', null),
  (pg_temp.c('pDemo'), null, pg_temp.c('kDemo'), '2026-01-01', null);
insert into ctx select 'aK3', id from public.project_assignments
  where project_id = pg_temp.c('pA') and personnel_id = pg_temp.c('k3');

-- ---------------------------------------------------------------- yapı ve tanımlar
select is_empty(
  $$ select table_name, column_name from information_schema.columns
      where table_schema = 'public' and table_name like 'puantaj%'
        and column_name ~ '(amount|tutar|ucret|wage|salary|price|fiyat)' $$,
  'puantaj tablolarında ücret veya tutar sütunu yok');
select results_eq(
  $$ select status::text, work_equivalent, pay_basis from public.puantaj_status_definitions order by sort_order $$,
  $$ values ('tam_gun', 1.00, 'calisilan_gun'), ('yarim_gun', 0.50, 'calisilan_gun'), ('calismadi', 0.00, 'ucretsiz'),
            ('ucretli_izin', 0.00, 'ucretli_izin'), ('ucretsiz_izin', 0.00, 'ucretsiz'), ('raporlu', 0.00, 'rapor'),
            ('resmi_tatil', 0.00, 'resmi_tatil') $$,
  'sayısal karşılık ile ücret sınıfı ayrı: ücretli izin ve resmî tatil çalışılmış sayılmaz');
select ok(not has_table_privilege('authenticated', 'public.puantaj_entries', 'insert')
          and not has_table_privilege('authenticated', 'public.puantaj_entries', 'update')
          and not has_table_privilege('authenticated', 'public.puantaj_periods', 'update')
          and not has_table_privilege('authenticated', 'public.puantaj_period_events', 'insert'),
  'puantaj tabloları API''den doğrudan yazılamaz (yalnızca RPC)');

-- ---------------------------------------------------------------- kayıt ve tarihli bağlantı
select tests.authenticate_as(pg_temp.c('sef'));
select is(
  (select count(*)::int from public.save_puantaj(pg_temp.c('pA'), jsonb_build_array(
     pg_temp.item('k1', '2026-03-02', 'tam_gun'),
     pg_temp.item('k1', '2026-03-12', 'tam_gun'),
     pg_temp.item('k2', '2026-03-02', 'yarim_gun'),
     pg_temp.item('k3', '2026-03-02', 'tam_gun', 2.5))) where result = 'eklendi'),
  4, 'şantiye şefi kendi projesine dört hücreyi tek istekte kaydeder');
select results_eq(
  format($$ select work_date, crew_id, crew_name from public.puantaj_entries
             where personnel_id = %L order by work_date $$, pg_temp.c('k1')),
  format($$ values ('2026-03-02'::date, %L::uuid, 'TEST PT A Ekibi'), ('2026-03-12'::date, %L::uuid, 'TEST PT B Ekibi') $$,
         pg_temp.c('crewA'), pg_temp.c('crewB')),
  'ay ortasında ekip değiştiren kişinin her günü o günkü ekibine bağlanır');
select results_eq(
  format($$ select assignment_id, membership_id, crew_id from public.puantaj_entries where personnel_id = %L $$, pg_temp.c('k3')),
  format($$ values (%L::uuid, null::uuid, null::uuid) $$, pg_temp.c('aK3')),
  'doğrudan görevli kişi görevlendirmesine bağlanır, ekip boş kalır');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k1', '2026-03-25', 'tam_gun'))),
  '23514', null, 'kişi o tarihte projede görevli değilse (başka projeye geçmiş) kayıt reddedilir');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2026-03-03', 'tam_gun'), pg_temp.item('k2', '2026-03-03', 'yarim_gun'))),
  '22023', null, 'aynı kişi ve gün listede iki kez gönderilemez');
select throws_ok(
  format($$ insert into public.puantaj_entries (project_id, personnel_id, work_date, status) values (%L, %L, '2026-03-04', 'tam_gun') $$,
         pg_temp.c('pA'), pg_temp.c('k2')),
  '42501', null, 'tabloya doğrudan ekleme yapılamaz');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2026-03-05', 'calismadi', 2))),
  '23514', null, 'çalışılmayan güne fazla mesai yazılamaz');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', (private.today() + 1)::date, 'tam_gun'))),
  '23514', null, 'ileri tarihe çalışma girilemez');
select lives_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', (private.today() + 1)::date, 'ucretli_izin'))),
  'ileri tarihe planlı izin girilebilir');

select tests.authenticate_as(pg_temp.c('admin'));
select lives_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pB'),
         jsonb_build_array(pg_temp.item('k1', '2026-03-25', 'tam_gun'))),
  'projeler arası geçiş: kişi yeni projesinde puantaj alır');
select lives_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pB'),
         jsonb_build_array(pg_temp.item('k3', '2026-03-02', 'yarim_gun'))),
  'aynı kişi aynı gün başka projede de kayıt alabilir');
select is((select count(*)::int from public.puantaj_entries
            where personnel_id = pg_temp.c('k3') and work_date = '2026-03-02'), 2,
  'aynı gün iki farklı projede iki ayrı kayıt');

select tests.clear_authentication();
select throws_ok(
  format($$ insert into public.puantaj_entries (project_id, personnel_id, work_date, status) values (%L, %L, '2026-03-02', 'tam_gun') $$,
         pg_temp.c('pA'), pg_temp.c('k1')),
  '23505', null, 'aynı proje, kişi ve gün için ikinci kayıt veritabanında da engellenir');

-- ---------------------------------------------------------------- tekrar gönderim, çakışma, üzerine yazma
select tests.authenticate_as(pg_temp.c('sef'));
select is(
  (select array_agg(result order by personnel_id) from public.save_puantaj(pg_temp.c('pA'), jsonb_build_array(
     pg_temp.item('k1', '2026-03-02', 'tam_gun', 0, 1),
     pg_temp.item('k2', '2026-03-02', 'yarim_gun', 0, 1)))),
  array['degismedi', 'degismedi'], 'aynı isteğin tekrar gönderilmesi değişiklik yapmaz');
select is(pg_temp.ver('pA', 'k2', '2026-03-02'), 1, 'tekrar gönderim sürümü artırmaz');
select is(
  (select result from public.save_puantaj(pg_temp.c('pA'), jsonb_build_array(pg_temp.item('k2', '2026-03-02', 'calismadi')))),
  'atlandi', 'sürüm bilmeden gelen toplu işlem var olan kaydı ezmez (atlanır)');
select is((select status::text from public.puantaj_entries where personnel_id = pg_temp.c('k2') and work_date = '2026-03-02'),
  'yarim_gun', 'atlanan kayıt değişmedi');

-- İki kullanıcı aynı hücreyi açar; önce müdür kaydeder, şef eski sürümle gönderir.
select tests.authenticate_as(pg_temp.c('mudur'));
select is(
  (select result from public.save_puantaj(pg_temp.c('pA'),
     jsonb_build_array(pg_temp.item('k2', '2026-03-02', 'tam_gun', 0, 1)))),
  'guncellendi', 'doğru sürümle gelen değişiklik kaydedilir');
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2026-03-02', 'raporlu', 0, 1))),
  '40001', null, 'eski sürümle gelen eşzamanlı değişiklik reddedilir (başkasının kaydı ezilmez)');
select is(
  (select result from public.save_puantaj(pg_temp.c('pA'),
     jsonb_build_array(pg_temp.item('k2', '2026-03-02', 'raporlu')), true)),
  'guncellendi', 'açıkça üzerine yazma seçilirse güncellenir');
select is(
  (select result from public.save_puantaj(pg_temp.c('pA'), jsonb_build_array(
     jsonb_build_object('personnel_id', pg_temp.c('k2'), 'work_date', '2026-03-02', 'status', null,
                        'expected_version', pg_temp.ver('pA', 'k2', '2026-03-02'))))),
  'silindi', 'hücre temizlenir (henüz işlenmedi)');
select is((select count(*)::int from public.puantaj_summary(pg_temp.c('pA'), '2026-03-01') where personnel_id = pg_temp.c('k2')), 0,
  'temizlenen hücre özete girmez');
select is(
  (select result from public.save_puantaj(pg_temp.c('pA'), jsonb_build_array(pg_temp.item('k2', '2026-03-02', 'tam_gun')))),
  'eklendi', 'temizlenen hücreye yeniden giriş yapılır');

-- ---------------------------------------------------------------- toplu kayıt
select is(
  (select count(*)::int from public.save_puantaj(pg_temp.c('pA'),
     (select jsonb_agg(pg_temp.item('k2', d::date, 'tam_gun'))
        from generate_series('2026-05-01'::date, '2026-05-31', interval '1 day') d))
    where result = 'eklendi'),
  31, '31 günlük ay tek istekte kaydedilir');
select is(
  (select count(*)::int from public.save_puantaj(pg_temp.c('pA'),
     (select jsonb_agg(pg_temp.item('k2', d::date, 'tam_gun'))
        from generate_series('2026-05-01'::date, '2026-05-31', interval '1 day') d))
    where result = 'degismedi'),
  31, 'toplu isteğin tekrarı mükerrer kayıt üretmez');
select is((select count(*)::int from public.puantaj_entries where personnel_id = pg_temp.c('k2')
            and work_date between '2026-05-01' and '2026-05-31'), 31, 'Mayıs için kişi başına 31 kayıt');

-- ---------------------------------------------------------------- ay uzunlukları ve artık yıl
select lives_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2024-02-29', 'tam_gun'))),
  'artık yılda 29 Şubat kaydedilir');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, '[{"personnel_id": "%s", "work_date": "2026-02-29", "status": "tam_gun"}]') $$,
         pg_temp.c('pA'), pg_temp.c('k2')),
  '22008', null, 'artık yıl olmayan yılda 29 Şubat geçersiz tarihtir');
select is((select end_date from public.puantaj_roster(pg_temp.c('pA'), '2024-02-01') where personnel_id = pg_temp.c('k2')),
  '2024-02-29'::date, 'Şubat 2024 tablosu 29 gün');
select is((select end_date from public.puantaj_roster(pg_temp.c('pA'), '2026-02-01') where personnel_id = pg_temp.c('k2')),
  '2026-02-28'::date, 'Şubat 2026 tablosu 28 gün');
select is((select end_date from public.puantaj_roster(pg_temp.c('pA'), '2026-04-01') where personnel_id = pg_temp.c('k2')),
  '2026-04-30'::date, 'Nisan tablosu 30 gün');
select is((select end_date from public.puantaj_roster(pg_temp.c('pA'), '2026-05-01') where personnel_id = pg_temp.c('k2')),
  '2026-05-31'::date, 'Mayıs tablosu 31 gün');
select results_eq(
  format($$ select crew_name, start_date, end_date from public.puantaj_roster(%L, '2026-03-01')
             where personnel_id = %L order by start_date $$, pg_temp.c('pA'), pg_temp.c('k1')),
  $$ values ('TEST PT A Ekibi', '2026-03-01'::date, '2026-03-10'::date),
            ('TEST PT B Ekibi', '2026-03-11'::date, '2026-03-20'::date) $$,
  'aylık tablo ay ortasındaki ekip değişikliğini ve projeden ayrılışı tarihleriyle gösterir');

-- ---------------------------------------------------------------- özet
select lives_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'), jsonb_build_array(
    pg_temp.item('k2', '2026-04-01', 'tam_gun'),
    pg_temp.item('k2', '2026-04-02', 'yarim_gun'),
    pg_temp.item('k2', '2026-04-03', 'calismadi'),
    pg_temp.item('k2', '2026-04-04', 'ucretli_izin'),
    pg_temp.item('k2', '2026-04-06', 'ucretsiz_izin'),
    pg_temp.item('k2', '2026-04-07', 'raporlu'),
    pg_temp.item('k2', '2026-04-08', 'resmi_tatil'),
    pg_temp.item('k2', '2026-04-09', 'tam_gun', 3),
    pg_temp.item('k2', '2026-04-10', 'yarim_gun', 1.5))),
  'Nisan için her durumdan kayıt girilir');
select results_eq(
  format($$ select kayitli_gun, tam_gun, yarim_gun, fiili_calisma, calismadi, ucretli_izin, ucretsiz_izin,
                   raporlu, resmi_tatil, fazla_mesai_saat, onayli_fazla_mesai
              from public.puantaj_summary(%L, '2026-04-01') where personnel_id = %L $$, pg_temp.c('pA'), pg_temp.c('k2')),
  $$ values (9, 2, 2, 3.00::numeric, 1, 1, 1, 1, 1, 4.50::numeric, 0::numeric) $$,
  'özet: tam 2, yarım 2, fiilî 3,0; izin, rapor, tatil ve devamsızlık ayrı sayılır; fazla mesai 4,5 saat');
select is((select calismadi from public.puantaj_summary(pg_temp.c('pA'), '2026-04-01') where personnel_id = pg_temp.c('k2')), 1,
  'girilmemiş 21 gün devamsızlık sayılmaz');

select throws_ok(
  format($$ select public.approve_puantaj_overtime(array(select id from public.puantaj_entries where project_id = %L and overtime_hours > 0)) $$,
         pg_temp.c('pA')),
  '42501', null, 'şantiye şefi fazla mesai onaylayamaz');
select tests.authenticate_as(pg_temp.c('mudur'));
select is(public.approve_puantaj_overtime(array(
            select id from public.puantaj_entries where personnel_id = pg_temp.c('k2') and overtime_hours > 0)), 2,
  'proje müdürü fazla mesaiyi onaylar');
select is((select onayli_fazla_mesai from public.puantaj_summary(pg_temp.c('pA'), '2026-04-01') where personnel_id = pg_temp.c('k2')),
  4.50::numeric, 'onaylı fazla mesai toplamı');
select is(
  (select result from public.save_puantaj(pg_temp.c('pA'),
     jsonb_build_array(pg_temp.item('k2', '2026-04-09', 'tam_gun', 4, pg_temp.ver('pA', 'k2', '2026-04-09'))))),
  'guncellendi', 'onaylı fazla mesai saati değiştirilir');
select is((select onayli_fazla_mesai from public.puantaj_summary(pg_temp.c('pA'), '2026-04-01') where personnel_id = pg_temp.c('k2')),
  1.50::numeric, 'saati değişen fazla mesainin onayı düşer');

-- ---------------------------------------------------------------- onay, kilit, yeniden açma
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok(format($$ select public.puantaj_transition(%L, '2026-03-01', 'onayla') $$, pg_temp.c('pA')),
  '42501', null, 'şantiye şefi ayı onaylayamaz');
select is((public.puantaj_transition(pg_temp.c('pA'), '2026-03-01', 'gonder')).status::text, 'incelemede',
  'şantiye şefi ayı incelemeye gönderir');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2026-03-03', 'tam_gun'))),
  '42501', null, 'incelemedeki aya şantiye şefi yazamaz');
select tests.authenticate_as(pg_temp.c('mudur'));
select lives_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2026-03-03', 'tam_gun'))),
  'inceleme yetkisi olan proje müdürü incelemedeki ayı düzeltir');
select lives_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k1', '2026-03-06', 'tam_gun', 2))),
  'onay öncesi Mart ayına onaysız fazla mesai girilir');
select throws_ok(format($$ select public.puantaj_transition(%L, '2026-03-01', 'onayla', null, 1) $$, pg_temp.c('pA')),
  '40001', null, 'eski sürümle gelen ay işlemi reddedilir');
select is((public.puantaj_transition(pg_temp.c('pA'), '2026-03-01', 'onayla')).status::text, 'onaylandi',
  'proje müdürü ayı onaylar');
select is((select first_approved_by from public.puantaj_periods where project_id = pg_temp.c('pA') and month = '2026-03-01'),
  pg_temp.c('mudur'), 'ilk onaylayan kaydedilir');
select is(
  (select jsonb_array_length(snapshot -> 'entries') from public.puantaj_period_events
    where project_id = pg_temp.c('pA') and action = 'onayla'),
  (select count(*)::int from public.puantaj_entries where project_id = pg_temp.c('pA')
     and work_date between '2026-03-01' and '2026-03-31' and deleted_at is null),
  'onay anındaki tüm kayıtlar değiştirilemez geçmişe yazılır');

select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L, true) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2026-03-02', 'calismadi'))),
  '23514', null, 'onaylı aya yönetici dahil kimse yazamaz');
select throws_ok(
  format($$ select public.approve_puantaj_overtime(array(select id from public.puantaj_entries
             where project_id = %L and work_date = '2026-03-06' and personnel_id = %L)) $$, pg_temp.c('pA'), pg_temp.c('k1')),
  '23514', null, 'onaylanmış ayda fazla mesai onaylanamaz');
select throws_ok(
  format($$ select public.approve_puantaj_overtime(array(select id from public.puantaj_entries
             where project_id = %L and overtime_hours > 0 and overtime_approved_at is null)) $$, pg_temp.c('pA')),
  '23514', null, 'Mart (onaylı) ve Nisan (taslak) içeren toplu fazla mesai onayı bütünüyle reddedilir');
select is(
  (select overtime_approved_at from public.puantaj_entries
    where project_id = pg_temp.c('pA') and personnel_id = pg_temp.c('k2') and work_date = '2026-04-09'),
  null, 'reddedilen toplu onayda taslak aydaki kayıt da değişmez');
select tests.authenticate_as(pg_temp.c('sef'));
select throws_ok(format($$ select public.puantaj_transition(%L, '2026-03-01', 'kilitle') $$, pg_temp.c('pA')),
  '42501', null, 'şantiye şefi ayı kilitleyemez');
select tests.authenticate_as(pg_temp.c('mudur'));
select is((public.puantaj_transition(pg_temp.c('pA'), '2026-03-01', 'kilitle')).status::text, 'kilitli',
  'proje müdürü onaylı ayı kilitler');
select throws_ok(
  format($$ select public.approve_puantaj_overtime(array(select id from public.puantaj_entries
             where project_id = %L and work_date = '2026-03-06' and personnel_id = %L)) $$, pg_temp.c('pA'), pg_temp.c('k1')),
  '23514', null, 'kilitli ayda fazla mesai onaylanamaz');
select throws_ok(
  format($$ select public.puantaj_transition(%L, '2026-03-01', 'yeniden_ac', 'Kalfanın raporu eksik girilmiş') $$, pg_temp.c('pA')),
  '42501', null, 'kilitli ayı yalnızca kilit açma yetkisi olan açar');
select tests.authenticate_as(pg_temp.c('admin'));
select throws_ok(format($$ select public.puantaj_transition(%L, '2026-03-01', 'yeniden_ac', 'kısa') $$, pg_temp.c('pA')),
  '23514', null, 'yeniden açma gerekçesiz yapılamaz');
select is((public.puantaj_transition(pg_temp.c('pA'), '2026-03-01', 'yeniden_ac',
            'Kalfanın raporlu günleri eksik girilmiş')).revision, 1,
  'yönetici kilitli ayı gerekçeyle açar; revizyon 1 olur');
select results_eq(
  format($$ select status::text, first_approved_by, approved_by from public.puantaj_periods
             where project_id = %L and month = '2026-03-01' $$, pg_temp.c('pA')),
  format($$ values ('taslak', %L::uuid, null::uuid) $$, pg_temp.c('mudur')),
  'yeniden açılan ay taslak; ilk onay bilgisi korunur');
select results_eq(
  format($$ select action, from_status::text, to_status::text, revision from public.puantaj_period_events
             where project_id = %L order by occurred_at, created_at $$, pg_temp.c('pA')),
  $$ values ('gonder', 'taslak', 'incelemede', 0), ('onayla', 'incelemede', 'onaylandi', 0),
            ('kilitle', 'onaylandi', 'kilitli', 0), ('yeniden_ac', 'kilitli', 'taslak', 1) $$,
  'onay ve revizyon geçmişi tarih sırasıyla tutulur');
select is((select reason from public.puantaj_period_events where project_id = pg_temp.c('pA') and action = 'yeniden_ac'),
  'Kalfanın raporlu günleri eksik girilmiş', 'yeniden açma gerekçesi saklanır');
select tests.authenticate_as(pg_temp.c('sef'));
select lives_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2026-03-04', 'raporlu'))),
  'yeniden açılan aya şantiye şefi düzeltme girer');
select tests.authenticate_as(pg_temp.c('mudur'));
select is(public.approve_puantaj_overtime(array(select id from public.puantaj_entries
            where project_id = pg_temp.c('pA') and work_date = '2026-03-06' and personnel_id = pg_temp.c('k1'))), 1,
  'yeniden açılan ayda fazla mesai onaylanır');

select tests.clear_authentication();
select throws_ok(
  format($$ update public.puantaj_period_events set reason = 'değişti' where project_id = %L $$, pg_temp.c('pA')),
  '42501', null, 'onay geçmişi değiştirilemez');
select throws_ok(
  format($$ delete from public.puantaj_period_events where project_id = %L $$, pg_temp.c('pA')),
  '42501', null, 'onay geçmişi silinemez');
select throws_ok(
  format($$ update public.puantaj_periods set first_approved_by = null where project_id = %L $$, pg_temp.c('pA')),
  '23514', null, 'ilk onay bilgisi silinemez');
select ok(
  (select count(*) from audit.log where table_name = 'puantaj_entries') > 0
  and (select count(*) from audit.log where table_name = 'puantaj_periods' and action = 'UPDATE') >= 4,
  'kayıt ve ay durum değişiklikleri işlem geçmişine yazılır');

-- ---------------------------------------------------------------- yetki ve proje izolasyonu
select tests.authenticate_as(pg_temp.c('sef'));
select is((select count(*)::int from public.puantaj_entries where project_id = pg_temp.c('pB')), 0,
  'şantiye şefi başka projenin puantajını göremez');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pB'),
         jsonb_build_array(pg_temp.item('k3', '2026-03-03', 'tam_gun'))),
  '42501', null, 'şantiye şefi başka projeye API ile puantaj yazamaz');
select throws_ok(format($$ select * from public.puantaj_roster(%L, '2026-03-01') $$, pg_temp.c('pB')),
  '42501', null, 'başka projenin puantaj listesi alınamaz');
select throws_ok(format($$ select public.puantaj_transition(%L, '2026-03-01', 'gonder') $$, pg_temp.c('pB')),
  '42501', null, 'başka projenin ayına işlem yapılamaz');

select tests.authenticate_as(pg_temp.c('sefB'));
select is((select count(*)::int from public.puantaj_entries where project_id = pg_temp.c('pA')), 0,
  'B projesinin şefi A projesini göremez');

select tests.authenticate_as(pg_temp.c('viewer'));
select ok((select count(*) from public.puantaj_entries where project_id = pg_temp.c('pA')) > 0,
  'görüntüleyici projesinin puantajını görür');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2026-03-06', 'tam_gun'))),
  '42501', null, 'görüntüleyici puantaj yazamaz');

select tests.authenticate_as(pg_temp.c('muhasebe'));
select ok((select count(*) from public.puantaj_entries) > 0, 'muhasebe tüm projelerin puantajını okur');
select throws_ok(format($$ select public.puantaj_transition(%L, '2026-04-01', 'onayla') $$, pg_temp.c('pA')),
  '42501', null, 'finans yetkisi puantaj onay yetkisi değildir');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2026-04-13', 'tam_gun'))),
  '42501', null, 'muhasebe puantaj yazamaz');

select tests.authenticate_as(pg_temp.c('idari'));
select lives_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pB'),
         jsonb_build_array(pg_temp.item('k3', '2026-03-03', 'tam_gun'))),
  'idari işler tüm projelerde puantaj girer');
select throws_ok(format($$ select public.puantaj_transition(%L, '2026-04-01', 'onayla') $$, pg_temp.c('pA')),
  '42501', null, 'idari işler ayı onaylayamaz');

select tests.authenticate_as(pg_temp.c('passive'));
select is((select count(*)::int from public.puantaj_entries), 0, 'pasif kullanıcı puantaj göremez');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pA'),
         jsonb_build_array(pg_temp.item('k2', '2026-04-14', 'tam_gun'))),
  '42501', null, 'pasif kullanıcı puantaj yazamaz');

select tests.authenticate_as(pg_temp.c('outsider'));
select is((select count(*)::int from public.puantaj_periods), 0, 'rolü olmayan kullanıcı puantaj dönemlerini göremez');
select throws_ok(format($$ select * from public.puantaj_summary(%L, '2026-04-01') $$, pg_temp.c('pA')),
  '42501', null, 'rolü olmayan kullanıcı özet alamaz');

-- ---------------------------------------------------------------- demo ayrımı
select tests.authenticate_as(pg_temp.c('admin'));
select lives_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pDemo'),
         jsonb_build_array(pg_temp.item('kDemo', '2026-03-02', 'tam_gun'))),
  'demo projeye demo personel yazılır');
select ok((select is_demo from public.puantaj_entries where personnel_id = pg_temp.c('kDemo'))
          and (select is_demo from public.puantaj_periods where project_id = pg_temp.c('pDemo')),
  'demo kayıt ve dönemi demo olarak işaretlenir');
select throws_ok(
  format($$ select * from public.save_puantaj(%L, %L) $$, pg_temp.c('pDemo'),
         jsonb_build_array(pg_temp.item('k2', '2026-03-02', 'tam_gun'))),
  '23514', null, 'gerçek personel demo projeye puantaj alamaz');
select tests.clear_authentication();
update public.puantaj_entries set is_demo = false where personnel_id = pg_temp.c('kDemo');
select ok((select is_demo from public.puantaj_entries where personnel_id = pg_temp.c('kDemo')),
  'kaydın demo işareti sonradan değiştirilemez');

-- ---------------------------------------------------------------- finansal yan etki yok
select is((select count(*)::int from public.cari_entries), (select cari from start_counts),
  'puantaj kayıtları, onay ve kilit hiçbir cari hareket (borç) oluşturmaz');
select is_empty(
  $$ select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where (p.proname like '%puantaj%')
        and pg_get_functiondef(p.oid) ~* '(cari_entries|cari_allocations|post_cari_entry)' $$,
  'hiçbir puantaj fonksiyonu veya trigger''ı cari deftere yazmaz');

select * from finish();
rollback;
