-- =============================================================================
-- RD Yönetim · Aşama 0 · 1/5 · Temel: eklentiler, şemalar, ortak trigger'lar
-- =============================================================================
-- Şemalar:
--   public  : API'ye (PostgREST) açık tablolar; her tabloda RLS zorunlu.
--   private : yetki yardımcı fonksiyonları; API'den doğrudan çağrılamaz.
--   audit   : işlem geçmişi; API'ye tamamen kapalı.

create extension if not exists btree_gist with schema extensions;

create schema if not exists private;
create schema if not exists audit;

revoke all on schema private from public, anon, authenticated;
revoke all on schema audit   from public, anon, authenticated;

-- RLS politikaları private fonksiyonlarını çağırdığı için oturum açmış
-- kullanıcıya yalnızca şema kullanım izni verilir; fonksiyonlar tek tek açılır.
grant usage on schema private to authenticated;

-- Yeni fonksiyonlar varsayılan olarak herkese EXECUTE vermesin.
alter default privileges in schema private revoke execute on functions from public;
alter default privileges in schema audit   revoke execute on functions from public;

-- -----------------------------------------------------------------------------
-- Türkiye saatine göre bugünün tarihi (yetki geçerlilik tarihleri için).
-- -----------------------------------------------------------------------------
create or replace function private.today()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'Europe/Istanbul')::date;
$$;

grant execute on function private.today() to authenticated;

-- -----------------------------------------------------------------------------
-- Ortak satır alanları: created_at/by, updated_at/by, version.
-- İstemcinin gönderdiği değerler yok sayılır; version her güncellemede artar.
-- İyimser kilit: istemci güncellemede "where version = <okuduğu>" filtresi
-- kullanır; satır başka biri tarafından değiştirildiyse 0 satır güncellenir.
-- -----------------------------------------------------------------------------
create or replace function private.tg_row_meta()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.created_by := auth.uid();
    new.updated_at := new.created_at;
    new.updated_by := new.created_by;
    new.version    := 1;
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    -- Gerçek bir değişiklik yoksa sürüm ve güncelleme bilgisi aynı kalır.
    if (to_jsonb(new) - array['created_at', 'created_by', 'updated_at', 'updated_by', 'version'])
       = (to_jsonb(old) - array['created_at', 'created_by', 'updated_at', 'updated_by', 'version']) then
      new.updated_at := old.updated_at;
      new.updated_by := old.updated_by;
      new.version    := old.version;
    else
      new.updated_at := now();
      new.updated_by := auth.uid();
      new.version    := old.version + 1;
    end if;
  end if;
  return new;
end;
$$;

-- Ortak alanları ve trigger'ı bir tabloya ekler (migration'larda kullanılır).
create or replace function private.add_row_meta(p_table regclass)
returns void
language plpgsql
set search_path = ''
as $$
begin
  execute format(
    'alter table %s
       add column if not exists created_at timestamptz not null default now(),
       add column if not exists created_by uuid,
       add column if not exists updated_at timestamptz not null default now(),
       add column if not exists updated_by uuid,
       add column if not exists version integer not null default 1',
    p_table);
  execute format(
    'create trigger aa_row_meta before insert or update on %s
       for each row execute function private.tg_row_meta()',
    p_table);
end;
$$;

-- -----------------------------------------------------------------------------
-- API ayrıcalıkları: anon hiçbir tabloya erişemez; authenticated için
-- TRUNCATE/REFERENCES/TRIGGER ve fiziksel DELETE kapalı (RLS bunları
-- denetlemez). Silme her yerde yumuşak silmedir (deleted_at).
-- -----------------------------------------------------------------------------
alter default privileges for role postgres in schema public
  revoke all on tables from anon;
alter default privileges for role postgres in schema public
  revoke truncate, references, trigger, delete on tables from authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon;
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon;
