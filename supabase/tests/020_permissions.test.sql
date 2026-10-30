-- Rol, proje kapsamı ve kullanıcıya özel izinlerin RLS üzerinden etkisi.
begin;
select plan(27);

-- ---------------------------------------------------------------- hazırlık
-- Testler yerel deneme verisinden (seed.sql) bağımsızdır: yalnızca TEST-*
-- projeleri ve @test.invalid kullanıcıları sayılır.
create temp table ctx (k text primary key, v uuid) on commit drop;
grant select on ctx to authenticated;

insert into ctx values
  ('admin',    tests.create_user('yonetici@test.invalid')),
  ('muhasebe', tests.create_user('muhasebe@test.invalid')),
  ('sef',      tests.create_user('sef@test.invalid')),
  ('viewer',   tests.create_user('goruntuleyici@test.invalid')),
  ('outsider', tests.create_user('rolsuz@test.invalid')),
  ('passive',  tests.create_user('pasif@test.invalid')),
  ('expired',  tests.create_user('suresi-dolmus@test.invalid')),
  ('pA',       tests.create_project('TEST-A')),
  ('pB',       tests.create_project('TEST-B'));

select tests.grant_global_role((select v from ctx where k = 'admin'),    'yonetici');
select tests.grant_global_role((select v from ctx where k = 'muhasebe'), 'muhasebe');
select tests.grant_global_role((select v from ctx where k = 'passive'),  'muhasebe');
update public.profiles set is_active = false where id = (select v from ctx where k = 'passive');

select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'sef'),    'santiye_sefi');
select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'viewer'), 'goruntuleyici');
select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'expired'), 'goruntuleyici',
                        private.today() - 30, private.today() - 1);

-- ---------------------------------------------------------------- proje görünürlüğü
select tests.authenticate_as((select v from ctx where k = 'admin'));
select is((select count(*)::int from public.projects where code like 'TEST-%'), 2, 'yönetici tüm projeleri görür');

select tests.authenticate_as((select v from ctx where k = 'muhasebe'));
select is((select count(*)::int from public.projects where code like 'TEST-%'), 2, 'muhasebe (genel rol) tüm projeleri görür');

select tests.authenticate_as((select v from ctx where k = 'sef'));
select results_eq($$ select code from public.projects where code like 'TEST-%' order by code $$, $$ values ('TEST-A') $$,
  'şantiye şefi yalnızca üye olduğu projeyi görür');

select tests.authenticate_as((select v from ctx where k = 'outsider'));
select is((select count(*)::int from public.projects where code like 'TEST-%'), 0, 'rolü olmayan kullanıcı hiçbir proje görmez');

select tests.authenticate_as((select v from ctx where k = 'passive'));
select is((select count(*)::int from public.projects where code like 'TEST-%'), 0, 'pasif kullanıcının rolü olsa da erişimi yok');

select tests.authenticate_as((select v from ctx where k = 'expired'));
select is((select count(*)::int from public.projects where code like 'TEST-%'), 0, 'süresi bitmiş proje üyeliği erişim vermez');

-- ---------------------------------------------------------------- yazma yetkileri
select tests.authenticate_as((select v from ctx where k = 'sef'));
select results_eq(
  $$ with u as (update public.projects set name = 'Şef düzenledi' where code = 'TEST-A' returning 1)
     select count(*)::int from u $$,
  $$ values (1) $$, 'şantiye şefi kendi projesini düzenler');
select results_eq(
  $$ with u as (update public.projects set name = 'izinsiz' where code = 'TEST-B' returning 1)
     select count(*)::int from u $$,
  $$ values (0) $$, 'şantiye şefi başka projeyi düzenleyemez');
select throws_ok(
  $$ insert into public.projects (code, name) values ('TEST-C', 'izinsiz') $$,
  '42501', null, 'şantiye şefi proje oluşturamaz');
select throws_ok(
  $$ update public.projects set deleted_at = now() where code = 'TEST-A' $$,
  '42501', 'Proje silme yetkiniz yok', 'şantiye şefi proje silemez');
select throws_ok(
  $$ delete from public.projects where code = 'TEST-A' $$,
  '42501', null, 'fiziksel silme hiçbir kullanıcıya açık değil');

select tests.authenticate_as((select v from ctx where k = 'viewer'));
select results_eq(
  $$ with u as (update public.projects set name = 'izinsiz' where code = 'TEST-A' returning 1)
     select count(*)::int from u $$,
  $$ values (0) $$, 'görüntüleyici projeyi düzenleyemez');

select tests.authenticate_as((select v from ctx where k = 'admin'));
select lives_ok(
  $$ update public.projects set deleted_at = now() where code = 'TEST-B' $$,
  'yönetici projeyi yumuşak silebilir');
update public.projects set deleted_at = null where code = 'TEST-B';

-- ---------------------------------------------------------------- yetki yükseltme engelleri
select tests.authenticate_as((select v from ctx where k = 'sef'));
select throws_ok(
  $$ insert into public.user_roles (user_id, role_id)
     select (select v from ctx where k = 'sef'), id from public.roles where key = 'yonetici' $$,
  '42501', null, 'şantiye şefi kendine rol atayamaz');
select throws_ok(
  $$ insert into public.user_permission_overrides (user_id, permission_key, effect, reason)
     values ((select v from ctx where k = 'sef'), 'proje.create', 'grant', 'deneme') $$,
  '42501', null, 'şantiye şefi kendine özel izin veremez');
select results_eq(
  $$ with u as (update public.profiles set is_active = false where id = (select v from ctx where k = 'viewer') returning 1)
     select count(*)::int from u $$,
  $$ values (0) $$, 'şantiye şefi başkasının profilini değiştiremez');
select throws_ok(
  $$ update public.profiles set is_active = false where id = (select v from ctx where k = 'sef') $$,
  '42501', 'Bu alanı değiştirme yetkiniz yok', 'kullanıcı kendini pasifleştiremez veya aktifleştiremez');
select results_eq(
  $$ with u as (update public.profiles set full_name = 'Yeni Ad' where id = (select v from ctx where k = 'sef') returning 1)
     select count(*)::int from u $$,
  $$ values (1) $$, 'kullanıcı kendi adını güncelleyebilir');
select is((select count(*)::int from public.user_roles), 0,
  'şantiye şefi başkalarının rol atamalarını göremez');

-- ---------------------------------------------------------------- kullanıcıya özel izinler
select tests.clear_authentication();
insert into public.user_permission_overrides (user_id, permission_key, project_id, effect, reason)
values ((select v from ctx where k = 'muhasebe'), 'proje.read', (select v from ctx where k = 'pB'), 'deny',
        'Test: B projesi muhasebeye kapalı');
insert into public.user_permission_overrides (user_id, permission_key, project_id, effect, reason)
values ((select v from ctx where k = 'outsider'), 'proje.read', (select v from ctx where k = 'pB'), 'grant',
        'Test: B projesine geçici okuma');
insert into public.user_permission_overrides (user_id, permission_key, project_id, effect, valid_from, valid_to, reason)
values ((select v from ctx where k = 'outsider'), 'proje.read', (select v from ctx where k = 'pA'), 'grant',
        private.today() - 10, private.today() - 1, 'Test: süresi dolmuş izin');

select tests.authenticate_as((select v from ctx where k = 'muhasebe'));
select results_eq($$ select code from public.projects where code like 'TEST-%' order by code $$, $$ values ('TEST-A') $$,
  'projeye özel yasak genel rol iznini geçersiz kılar');

select tests.authenticate_as((select v from ctx where k = 'outsider'));
select results_eq($$ select code from public.projects where code like 'TEST-%' order by code $$, $$ values ('TEST-B') $$,
  'projeye özel izin yalnızca o projede geçerli; süresi dolan izin sayılmaz');

select tests.authenticate_as((select v from ctx where k = 'sef'));
select ok(
  exists (select 1 from public.my_permissions()
           where project_id = (select v from ctx where k = 'pA') and permission_key = 'proje.write'),
  'my_permissions şefin A projesindeki yazma iznini döner');
select ok(
  not exists (select 1 from public.my_permissions()
               where project_id = (select v from ctx where k = 'pB')),
  'my_permissions şefe B projesinde izin göstermez');

-- ---------------------------------------------------------------- bütünlük kuralları
select tests.clear_authentication();
select throws_ok(
  $$ select tests.grant_global_role((select v from ctx where k = 'outsider'), 'santiye_sefi') $$,
  '23514', null, 'proje rolü genel rol olarak atanamaz');
select throws_ok(
  $$ select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'outsider'), 'muhasebe') $$,
  '23514', null, 'genel rol projeye rol olarak atanamaz');
select throws_ok(
  $$ select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'sef'), 'goruntuleyici') $$,
  '23P01', null, 'aynı projede çakışan iki üyelik olamaz');
select throws_ok(
  $$ update public.roles set deleted_at = now() where key = 'yonetici' $$,
  '23514', null, 'sistem rolü silinemez');

select * from finish();
rollback;
