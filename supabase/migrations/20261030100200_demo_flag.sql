-- =============================================================================
-- RD Yönetim · Aşama 1 · Demo kayıt ayrımı
-- =============================================================================
-- Deneme ve eğitim kayıtları is_demo ile işaretlenir; uygulama bunları
-- "DEMO" etiketiyle gösterir. Demo bir cari ile gerçek bir proje (veya tersi)
-- arasında hareket oluşamaz, böylece demo tutarlar gerçek bakiyelere karışmaz.

alter table public.projects      add column is_demo boolean not null default false;
alter table public.cost_centers  add column is_demo boolean not null default false;
alter table public.cari_accounts add column is_demo boolean not null default false;

create or replace function private.tg_cari_entry_demo_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_cari  boolean;
  v_scope boolean;
begin
  select c.is_demo into v_cari from public.cari_accounts c where c.id = new.cari_account_id;
  if new.project_id is not null then
    select p.is_demo into v_scope from public.projects p where p.id = new.project_id;
  else
    select cc.is_demo into v_scope from public.cost_centers cc where cc.id = new.cost_center_id;
  end if;
  if v_cari is distinct from v_scope then
    raise exception 'Demo kayıtlar gerçek kayıtlarla aynı harekette kullanılamaz'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger demo_scope before insert on public.cari_entries
  for each row execute function private.tg_cari_entry_demo_scope();

-- İşaret sonradan değiştirilemez: hareketi olan kayıt demo/gerçek arasında taşınamaz.
create or replace function private.tg_demo_flag_locked()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.is_demo is distinct from old.is_demo then
    raise exception 'Demo işareti kayıt oluşturulduktan sonra değiştirilemez'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger demo_flag_locked before update of is_demo on public.projects
  for each row execute function private.tg_demo_flag_locked();
create trigger demo_flag_locked before update of is_demo on public.cost_centers
  for each row execute function private.tg_demo_flag_locked();
create trigger demo_flag_locked before update of is_demo on public.cari_accounts
  for each row execute function private.tg_demo_flag_locked();

select private.harden_api_privileges();
