-- =============================================================================
-- RD Yönetim · Aşama 1 · İş takibi (ana ekrandaki yapılacak işler)
-- =============================================================================
-- project_id boşsa iş şirket geneli işidir ve genel izin gerektirir.

create type public.task_status as enum ('acik', 'devam', 'tamamlandi', 'iptal');
create type public.task_priority as enum ('dusuk', 'normal', 'yuksek');

create table public.tasks (
  id           uuid primary key default gen_random_uuid(),
  project_id   uuid references public.projects (id) on delete restrict,
  title        text not null check (length(trim(title)) > 0),
  description  text,
  assignee_id  uuid references public.profiles (id) on delete restrict,
  due_date     date,
  status       public.task_status not null default 'acik',
  priority     public.task_priority not null default 'normal',
  completed_at timestamptz,
  deleted_at   timestamptz
);
create index tasks_project_idx on public.tasks (project_id, status) where deleted_at is null;
create index tasks_assignee_idx on public.tasks (assignee_id, status) where deleted_at is null;
select private.add_row_meta('public.tasks');
select audit.enable('public.tasks');

create or replace function private.tg_task_completed_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'tamamlandi' then
    new.completed_at := coalesce(case when tg_op = 'UPDATE' then old.completed_at end, now());
  else
    new.completed_at := null;
  end if;
  return new;
end;
$$;

create trigger task_completed_at before insert or update of status on public.tasks
  for each row execute function private.tg_task_completed_at();

alter table public.tasks enable row level security;

-- Atanan kişi işi, iş yetkisi olmasa da görür; ancak yalnızca hesabı aktifken
-- ve işin kapsamına (proje işi ise o projeye) hâlâ erişimi varken.
create policy tasks_select on public.tasks
  for select to authenticated
  using (private.has_permission('is.read', project_id)
         or (assignee_id = (select auth.uid())
             and private.is_active_user()
             and (project_id is null or private.has_permission('proje.read', project_id))));
create policy tasks_insert on public.tasks
  for insert to authenticated
  with check (private.has_permission('is.write', project_id));
create policy tasks_update on public.tasks
  for update to authenticated
  using (private.has_permission('is.write', project_id))
  with check (private.has_permission('is.write', project_id));

insert into public.permissions (key, module, description) values
  ('is.read',  'is', 'İşleri görüntüleme'),
  ('is.write', 'is', 'İş oluşturma, düzenleme ve kapatma');

insert into public.role_permissions (role_id, permission_key)
select r.id, x.permission_key
  from (values
          ('muhasebe',      'is.read'),
          ('santiye_sefi',  'is.read'),
          ('santiye_sefi',  'is.write'),
          ('goruntuleyici', 'is.read')
       ) as x (role_key, permission_key)
  join public.roles r on r.key = x.role_key;

select private.harden_api_privileges();
