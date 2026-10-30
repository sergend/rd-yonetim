-- Profil görünürlüğü, iletişim bilgisinin gizliliği ve son yöneticinin korunması.
begin;
select plan(19);

create temp table ctx (k text primary key, v uuid) on commit drop;
grant select on ctx to authenticated;

-- Yerel deneme verisindeki yöneticileri bu işlem içinde devre dışı bırak
-- (ROLLBACK geri alır); testler yalnızca kendi kullanıcılarıyla çalışır.
-- Son yönetici denetimi işlem sonuna ertelenmiş olduğu için, yeni yönetici
-- atanana kadar hata vermez.
update public.user_roles set deleted_at = now()
 where role_id in (select id from public.roles where is_system);

insert into ctx values
  ('admin1',   tests.create_user('yonetici1@test.invalid')),
  ('admin2',   tests.create_user('yonetici2@test.invalid')),
  ('muhasebe', tests.create_user('muhasebe@test.invalid')),
  ('sef',      tests.create_user('sef@test.invalid')),
  ('viewer',   tests.create_user('goruntuleyici@test.invalid')),
  ('other',    tests.create_user('baska-proje@test.invalid')),
  ('pA',       tests.create_project('TEST-A')),
  ('pB',       tests.create_project('TEST-B'));

select tests.grant_global_role((select v from ctx where k = 'admin1'),   'yonetici');
-- Bundan sonra son yönetici denetimi her ifadede hemen çalışsın.
set constraints all immediate;
select tests.grant_global_role((select v from ctx where k = 'muhasebe'), 'muhasebe');
select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'sef'),    'santiye_sefi');
select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'viewer'), 'goruntuleyici');
select tests.add_member((select v from ctx where k = 'pB'), (select v from ctx where k = 'other'),  'goruntuleyici');
update public.profiles set phone = '+90 500 000 00 00' where id = (select v from ctx where k = 'sef');

-- ---------------------------------------------------------------- profil görünürlüğü
select tests.authenticate_as((select v from ctx where k = 'sef'));
select results_eq(
  $$ select full_name from public.profiles where full_name like '%@test.invalid' order by 1 $$,
  $$ values ('goruntuleyici@test.invalid'), ('sef@test.invalid') $$,
  'proje kullanıcısı yalnızca kendini ve aynı projedeki kişileri görür');
select throws_ok($$ select email from public.profiles $$, '42501', null,
  'e-posta sütunu doğrudan okunamaz');
select throws_ok($$ select phone from public.profiles $$, '42501', null,
  'telefon sütunu doğrudan okunamaz');
select throws_ok($$ select * from public.profiles $$, '42501', null,
  'tüm sütunlar (select *) okunamaz');
select results_eq($$ select email, phone from public.my_profile() $$,
  $$ values ('sef@test.invalid'::text, '+90 500 000 00 00'::text) $$,
  'kişi kendi e-posta ve telefonunu my_profile ile görür');
select throws_ok($$ select * from public.user_directory() $$, '42501',
  'Kullanıcı listesini görüntüleme yetkiniz yok', 'proje kullanıcısı kullanıcı listesini göremez');

select tests.authenticate_as((select v from ctx where k = 'other'));
select results_eq(
  $$ select full_name from public.profiles where full_name like '%@test.invalid' order by 1 $$,
  $$ values ('baska-proje@test.invalid') $$,
  'başka projedeki kullanıcı A projesindekileri görmez');

select tests.authenticate_as((select v from ctx where k = 'muhasebe'));
select is((select count(*)::int from public.profiles where full_name like '%@test.invalid'), 6,
  'genel rolü olan kullanıcı tüm adları görür');
select throws_ok($$ select email from public.profiles $$, '42501', null,
  'genel rol de e-postayı doğrudan okuyamaz');

select tests.authenticate_as((select v from ctx where k = 'admin1'));
select is((select count(*)::int from public.user_directory() where email like '%@test.invalid'), 6,
  'kullanıcı yöneticisi user_directory ile iletişim bilgilerini görür');

-- ---------------------------------------------------------------- son yönetici koruması
select tests.clear_authentication();
select throws_ok(
  $$ update public.user_roles set deleted_at = now()
      where user_id = (select v from ctx where k = 'admin1') $$,
  '23514', 'Son etkin yönetici kaldırılamaz; önce başka bir yönetici atayın',
  'son yöneticinin rolü kaldırılamaz');
select throws_ok(
  $$ update public.profiles set is_active = false where id = (select v from ctx where k = 'admin1') $$,
  '23514', null, 'son yönetici pasifleştirilemez');
select throws_ok(
  $$ insert into public.user_permission_overrides (user_id, permission_key, effect, reason)
     values ((select v from ctx where k = 'admin1'), 'kullanici.manage', 'deny', 'deneme') $$,
  '23514', null, 'son yöneticiye kullanıcı yönetimi yasağı konamaz');
select throws_ok(
  $$ insert into public.user_permission_overrides (user_id, permission_key, effect, valid_from, reason)
     values ((select v from ctx where k = 'admin1'), 'kullanici.manage', 'deny', private.today() + 30, 'ileri tarihli') $$,
  '23514', null, 'ileri tarihli yasak da son yöneticiye konamaz');
select throws_ok(
  $$ delete from public.user_roles where user_id = (select v from ctx where k = 'admin1') $$,
  '23514', null, 'sunucu tarafında fiziksel silme de son yöneticiyi kaldıramaz');
select lives_ok(
  $$ insert into public.user_permission_overrides (user_id, permission_key, project_id, effect, reason)
     values ((select v from ctx where k = 'admin1'), 'proje.read', (select v from ctx where k = 'pB'), 'deny', 'deneme') $$,
  'yöneticiye başka izinlerde projeye özel yasak konabilir');

select tests.grant_global_role((select v from ctx where k = 'admin2'), 'yonetici');
select lives_ok(
  $$ update public.user_roles set deleted_at = now()
      where user_id = (select v from ctx where k = 'admin1') $$,
  'ikinci yönetici varken ilk yöneticinin rolü kaldırılabilir');
select throws_ok(
  $$ update public.profiles set is_active = false where id = (select v from ctx where k = 'admin2') $$,
  '23514', null, 'kalan tek yönetici bu kez korunur');

select is(private.effective_admin_count(), 1, 'sonuçta bir etkin yönetici kalır');

select * from finish();
rollback;
