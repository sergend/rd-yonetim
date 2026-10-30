-- =============================================================================
-- RD Yönetim · Aşama 0 · 2/5 · İşlem geçmişi (audit log)
-- =============================================================================
-- Her tablodaki her ekleme/güncelleme/silme, uygulamadan bağımsız olarak
-- trigger ile audit.log'a yazılır. Kayıtlar değiştirilemez ve silinemez.

create table audit.log (
  id             bigint generated always as identity primary key,
  occurred_at    timestamptz not null default now(),
  txid           bigint      not null default txid_current(),
  actor_id       uuid,                 -- auth.uid(); doğrudan DB bağlantısında boş
  actor_role     text        not null, -- JWT rolü (authenticated, service_role) veya db:<kullanıcı>
  table_schema   text        not null,
  table_name     text        not null,
  record_id      text,
  action         text        not null check (action in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')),
  old_data       jsonb,
  new_data       jsonb,
  changed_fields text[]
);

create index log_record_idx on audit.log (table_name, record_id, occurred_at desc);
create index log_actor_idx  on audit.log (actor_id, occurred_at desc);
create index log_time_idx   on audit.log (occurred_at desc);

create or replace function audit.current_actor_role()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    'db:' || session_user
  );
$$;

create or replace function audit.tg_log_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old     jsonb;
  v_new     jsonb;
  v_changed text[];
begin
  if tg_op in ('UPDATE', 'DELETE') then
    v_old := to_jsonb(old);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    v_new := to_jsonb(new);
  end if;

  if tg_op = 'UPDATE' then
    select array_agg(n.key order by n.key)
      into v_changed
      from jsonb_each(v_new) n
     where n.key not in ('updated_at', 'updated_by', 'version')
       and n.value is distinct from (v_old -> n.key);

    -- Hiçbir gerçek alan değişmediyse kayıt üretme.
    if v_changed is null then
      return null;
    end if;
  end if;

  insert into audit.log (actor_id, actor_role, table_schema, table_name, record_id,
                         action, old_data, new_data, changed_fields)
  values (auth.uid(), audit.current_actor_role(), tg_table_schema, tg_table_name,
          coalesce(v_new ->> 'id', v_old ->> 'id'),
          tg_op, v_old, v_new, v_changed);

  return null;
end;
$$;

create or replace function audit.tg_log_truncate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into audit.log (actor_id, actor_role, table_schema, table_name, action)
  values (auth.uid(), audit.current_actor_role(), tg_table_schema, tg_table_name, 'TRUNCATE');
  return null;
end;
$$;

-- Bir tabloyu işlem geçmişine bağlar. Her yeni tablo migration'ında çağrılır;
-- testler public şemasında audit trigger'ı olmayan tablo bırakılmadığını denetler.
create or replace function audit.enable(p_table regclass)
returns void
language plpgsql
set search_path = ''
as $$
begin
  execute format(
    'create trigger zz_audit_row after insert or update or delete on %s
       for each row execute function audit.tg_log_row()', p_table);
  execute format(
    'create trigger zz_audit_truncate after truncate on %s
       for each statement execute function audit.tg_log_truncate()', p_table);
end;
$$;

-- -----------------------------------------------------------------------------
-- audit.log yalnızca eklenebilir: güncelleme, silme ve truncate trigger ile
-- tablo sahibine dahi reddedilir.
-- -----------------------------------------------------------------------------
create or replace function audit.tg_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'audit.log değiştirilemez veya silinemez'
    using errcode = 'insufficient_privilege';
end;
$$;

create trigger log_no_update_delete before update or delete on audit.log
  for each row execute function audit.tg_immutable();
create trigger log_no_truncate before truncate on audit.log
  for each statement execute function audit.tg_immutable();

revoke all on audit.log from public, anon, authenticated, service_role;
