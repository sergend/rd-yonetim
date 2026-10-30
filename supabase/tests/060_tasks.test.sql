-- İş takibi: proje kapsamlı görünürlük, atanan kişinin erişimi, tamamlanma zamanı.
begin;
select plan(8);

create temp table ctx (k text primary key, v uuid) on commit drop;
grant select on ctx to authenticated;

insert into ctx values
  ('sef',      tests.create_user('is-sef@test.invalid')),
  ('viewer',   tests.create_user('is-viewer@test.invalid')),
  ('assignee', tests.create_user('is-atanan@test.invalid')),
  ('pA',       tests.create_project('TEST-IS-A')),
  ('pB',       tests.create_project('TEST-IS-B'));

select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'sef'),    'santiye_sefi');
select tests.add_member((select v from ctx where k = 'pA'), (select v from ctx where k = 'viewer'), 'goruntuleyici');

insert into public.tasks (project_id, title) values ((select v from ctx where k = 'pB'), 'TEST B projesi işi');
insert into public.tasks (project_id, title, assignee_id)
values ((select v from ctx where k = 'pB'), 'TEST atanmış iş', (select v from ctx where k = 'assignee'));

select tests.authenticate_as((select v from ctx where k = 'sef'));
select lives_ok(
  format($$ insert into public.tasks (project_id, title, priority) values (%L, 'TEST kalıp kontrolü', 'yuksek') $$,
         (select v from ctx where k = 'pA')),
  'şantiye şefi kendi projesine iş açar');
select throws_ok(
  format($$ insert into public.tasks (project_id, title) values (%L, 'izinsiz') $$, (select v from ctx where k = 'pB')),
  '42501', null, 'şantiye şefi başka projeye iş açamaz');
select results_eq($$ select title from public.tasks where title like 'TEST%' $$, $$ values ('TEST kalıp kontrolü') $$,
  'şantiye şefi yalnızca kendi projesinin işlerini görür');
select results_eq(
  $$ with u as (update public.tasks set status = 'tamamlandi' where title = 'TEST kalıp kontrolü' returning completed_at)
     select count(*)::int from u where completed_at is not null $$,
  $$ values (1) $$, 'tamamlanan işe tamamlanma zamanı yazılır');
select throws_ok($$ delete from public.tasks $$, '42501', null, 'iş fiziksel olarak silinemez');

select tests.authenticate_as((select v from ctx where k = 'viewer'));
select is((select count(*)::int from public.tasks where title like 'TEST%'), 1, 'görüntüleyici projesinin işlerini görür');
select results_eq(
  $$ with u as (update public.tasks set title = 'değişti' where title like 'TEST%' returning 1) select count(*)::int from u $$,
  $$ values (0) $$, 'görüntüleyici iş düzenleyemez');

select tests.authenticate_as((select v from ctx where k = 'assignee'));
select results_eq($$ select title from public.tasks where title like 'TEST%' $$, $$ values ('TEST atanmış iş') $$,
  'proje rolü olmayan kişi kendisine atanan işi görür');

select * from finish();
rollback;
