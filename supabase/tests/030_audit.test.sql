-- İşlem geçmişi, satır sürümü ve ilk yönetici kurulumu.
begin;
select plan(12);

create temp table ctx (k text primary key, v uuid) on commit drop;
grant select on ctx to authenticated;
insert into ctx values
  ('admin', tests.create_user('yonetici@test.invalid')),
  ('sef',   tests.create_user('sef@test.invalid')),
  ('pA',    tests.create_project('TEST-A'));

-- ---------------------------------------------------------------- ilk yönetici
-- Yerel deneme verisindeki yöneticiyi bu işlem içinde pasifleştir (ROLLBACK geri alır).
update public.profiles set is_active = false
 where id in (select ur.user_id from public.user_roles ur
                join public.roles r on r.id = ur.role_id
               where r.key = 'yonetici' and ur.deleted_at is null);
select is(private.bootstrap_admin('YONETICI@TEST.invalid'), (select v from ctx where k = 'admin'),
  'ilk yönetici e-postayla atanır (büyük/küçük harf duyarsız)');
select throws_ok($$ select private.bootstrap_admin('sef@test.invalid') $$,
  'P0001', 'Aktif bir yönetici zaten var; atamayı uygulama üzerinden yapın',
  'aktif yönetici varken ikinci kez çalışmaz');

select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'sef'), 'santiye_sefi');

-- ---------------------------------------------------------------- değişiklik kaydı
select tests.authenticate_as((select v from ctx where k = 'sef'));
update public.projects set name = 'Yeni ad', city = 'İstanbul', created_by = gen_random_uuid(), version = 99
 where id = (select v from ctx where k = 'pA');
update public.projects set name = 'Yeni ad' where id = (select v from ctx where k = 'pA'); -- değişiklik yok
select tests.clear_authentication();

select is((select version from public.projects where id = (select v from ctx where k = 'pA')), 2,
  'version istemciden bağımsız olarak her güncellemede bir artar');
select ok((select created_by is null from public.projects where id = (select v from ctx where k = 'pA')),
  'created_by istemci tarafından değiştirilemez');
select is((select updated_by from public.projects where id = (select v from ctx where k = 'pA')),
  (select v from ctx where k = 'sef'), 'updated_by oturumdaki kullanıcıdır');

select is(
  (select count(*)::int from audit.log
    where table_name = 'projects' and record_id = (select v from ctx where k = 'pA')::text
      and action = 'UPDATE'),
  1, 'gerçek değişiklik bir kez kaydedilir, değişmeyen güncelleme kaydedilmez');
select is(
  (select changed_fields from audit.log
    where table_name = 'projects' and record_id = (select v from ctx where k = 'pA')::text
      and action = 'UPDATE'),
  array['city', 'name'], 'değişen alanlar kaydedilir');
select is(
  (select actor_id from audit.log
    where table_name = 'projects' and record_id = (select v from ctx where k = 'pA')::text
      and action = 'UPDATE'),
  (select v from ctx where k = 'sef'), 'değişikliği yapan kullanıcı kaydedilir');

-- ---------------------------------------------------------------- değiştirilemezlik
select throws_ok($$ update audit.log set actor_id = null $$,
  '42501', 'audit.log değiştirilemez veya silinemez', 'audit.log güncellenemez (sahibi dahi)');
select throws_ok($$ delete from audit.log $$,
  '42501', 'audit.log değiştirilemez veya silinemez', 'audit.log silinemez (sahibi dahi)');

-- ---------------------------------------------------------------- okuma yetkisi
select tests.authenticate_as((select v from ctx where k = 'admin'));
select ok(
  (select count(*) from public.record_history('projects', (select v from ctx where k = 'pA')::text)) >= 2,
  'yönetici kaydın geçmişini okuyabilir');

select tests.authenticate_as((select v from ctx where k = 'sef'));
select throws_ok(
  $$ select * from public.record_history('projects', (select v from ctx where k = 'pA')::text) $$,
  '42501', 'İşlem geçmişini görüntüleme yetkiniz yok', 'audit.read izni olmayan geçmişi okuyamaz');

select * from finish();
rollback;
