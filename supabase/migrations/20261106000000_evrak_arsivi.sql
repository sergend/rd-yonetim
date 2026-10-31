-- =============================================================================
-- RD Yönetim · Aşama 6 · Evrak, belge tarama ve güvenli arşiv
-- =============================================================================
-- Fatura, fiş, irsaliye, sözleşme, tutanak, ruhsat ve diğer belgelerin
-- dosyaları ÖZEL Supabase Storage bucket'ında ('belgeler') durur; bilgileri
-- public.documents tablosundadır.
--
-- Her belge tek bir ana kayda bağlıdır: proje, genel masraf merkezi, finans
-- belgesi (gider/gelir) veya taşeron sözleşmesi. Belgenin projesi / masraf
-- merkezi, cari ve taşeron referansı ve DEMO işareti istemciden alınmaz;
-- bağlanan kayıttan sunucuda türetilir.
--
-- Yükleme üç ayrı adımdır:
--   1) reserve_document_upload : yetki ve dosya bilgisi (tür, boyut, SHA-256)
--      denetlenir; sunucu tahmin edilemez bir depolama yolu ayırır (bekliyor).
--   2) İstemci dosyayı yalnızca bu yola yükler (storage.objects INSERT
--      politikası: yolu ayıran kişi, süre dolmadan, yetkisi sürerken).
--   3) complete_document_upload: nesnenin varlığı, boyutu ve türü
--      doğrulanır; belge 'yuklendi' olur.
-- Depolama yetkisi dosya adına veya yol biçimine değil, documents satırına
-- dayanır: yol yalnızca bir anahtardır.
--
-- Dosya eklemek hiçbir finansal kaydı değiştirmez (gider tutarı, hakediş,
-- cari borç, ödeme durumu): bu migration finans tablolarına yazmaz ve
-- trigger eklemez. Dosyalar silinmez; yanlış dosya iptal edilir veya yenisiyle
-- değiştirilir, geçmiş document_events'te kalır. Storage nesnesi yalnızca
-- hiç tamamlanmamış (yetim) yüklemelerde temizlik listesine girer.
--
-- Önceki migration'lar değiştirilmez.
-- =============================================================================

create type public.document_kind      as enum ('fatura', 'fis', 'irsaliye', 'sozlesme', 'tutanak', 'ruhsat', 'diger');
create type public.document_link_type as enum ('proje', 'masraf_merkezi', 'finans_belgesi', 'sozlesme');
create type public.document_status    as enum ('bekliyor', 'yuklendi', 'arsivlendi', 'iptal');

-- -----------------------------------------------------------------------------
-- Belgeler
-- -----------------------------------------------------------------------------
create table public.documents (
  id                  uuid primary key,  -- istemcide üretilir: tekrar gönderim ikinci belge açmaz
  kind                public.document_kind not null,
  title               text not null check (length(trim(title)) between 1 and 200),
  description         text,
  document_date       date not null,
  link_type           public.document_link_type not null,
  -- Kapsam (tam olarak biri) ve referanslar: bağlanan kayıttan türetilir.
  project_id          uuid references public.projects (id) on delete restrict,
  cost_center_id      uuid references public.cost_centers (id) on delete restrict,
  finance_document_id uuid references public.finance_documents (id) on delete restrict,
  contract_id         uuid references public.contracts (id) on delete restrict,
  cari_account_id     uuid references public.cari_accounts (id) on delete restrict,
  subcontractor_id    uuid references public.subcontractors (id) on delete restrict,
  -- Dosya
  mime_type           text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png')),
  byte_size           bigint not null check (byte_size > 0 and byte_size <= 26214400),
  sha256              text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  storage_bucket      text not null default 'belgeler' check (storage_bucket = 'belgeler'),
  storage_path        text not null unique,
  -- Durum
  status              public.document_status not null default 'bekliyor',
  upload_expires_at   timestamptz,
  uploaded_at         timestamptz,
  uploaded_by         uuid,
  archived_at         timestamptz,
  archived_by         uuid,
  archive_reason      text,
  cancelled_at        timestamptz,
  cancelled_by        uuid,
  cancel_reason       text,
  replaces_id         uuid unique references public.documents (id) on delete restrict,
  is_demo             boolean not null default false,
  constraint documents_scope_ck check (num_nonnulls(project_id, cost_center_id) = 1),
  constraint documents_link_ck check (
    case link_type
      when 'proje'          then project_id is not null and finance_document_id is null and contract_id is null
      when 'masraf_merkezi' then cost_center_id is not null and finance_document_id is null and contract_id is null
      when 'finans_belgesi' then finance_document_id is not null and contract_id is null
      when 'sozlesme'       then contract_id is not null and project_id is not null and finance_document_id is null
    end),
  constraint documents_upload_ck check (
    (status = 'bekliyor' and uploaded_at is null and upload_expires_at is not null)
    or (status in ('yuklendi', 'arsivlendi') and uploaded_at is not null)
    or status = 'iptal'),
  constraint documents_archive_ck check ((status = 'arsivlendi') = (archived_at is not null) or status = 'iptal')
);
create index documents_project_idx on public.documents (project_id, document_date) where project_id is not null;
create index documents_cost_center_idx on public.documents (cost_center_id, document_date) where cost_center_id is not null;
create index documents_finance_idx on public.documents (finance_document_id) where finance_document_id is not null;
create index documents_contract_idx on public.documents (contract_id) where contract_id is not null;
create index documents_pending_idx on public.documents (upload_expires_at) where status = 'bekliyor';
-- Aynı dosya aynı kayda iki kez eklenmez (yanlışlıkla çift yükleme).
create unique index documents_same_file_uq on public.documents
  (link_type, coalesce(finance_document_id, contract_id, project_id, cost_center_id), sha256)
  where status = 'yuklendi';
select private.add_row_meta('public.documents');
select audit.enable('public.documents');

-- Değiştirilemez işlem geçmişi (rezerve, yükleme, arşiv, bağlantı değişikliği, iptal).
create table public.document_events (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.documents (id) on delete restrict,
  action      text not null,
  from_status text,
  to_status   text,
  reason      text,
  data        jsonb,
  actor_id    uuid default auth.uid(),
  occurred_at timestamptz not null default clock_timestamp()
);
create index document_events_doc_idx on public.document_events (document_id, occurred_at);
select private.add_row_meta('public.document_events');
select audit.enable('public.document_events');

create trigger document_event_immutable before update or delete on public.document_events
  for each row execute function private.tg_finance_event_immutable();

-- -----------------------------------------------------------------------------
-- Değişmezlik (tablolar API'ye kapalı; RPC hatalarına karşı ikinci savunma)
-- -----------------------------------------------------------------------------
create or replace function private.tg_document_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Belge silinemez; arşivleyin veya iptal edin' using errcode = 'insufficient_privilege';
  end if;
  if new.sha256 is distinct from old.sha256 or new.byte_size is distinct from old.byte_size
     or new.mime_type is distinct from old.mime_type or new.storage_path is distinct from old.storage_path
     or new.storage_bucket is distinct from old.storage_bucket or new.is_demo is distinct from old.is_demo
     or new.created_by is distinct from old.created_by or new.replaces_id is distinct from old.replaces_id then
    raise exception 'Belgenin dosya bilgisi değiştirilemez; yeni dosya yükleyin' using errcode = 'check_violation';
  end if;
  if old.status = 'iptal' and new is distinct from old then
    raise exception 'İptal edilmiş belge değiştirilemez' using errcode = 'check_violation';
  end if;
  if old.status <> 'bekliyor' and new.status = 'bekliyor' then
    raise exception 'Belge yükleme bekleyen duruma geri dönemez' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger document_guard before update or delete on public.documents
  for each row execute function private.tg_document_guard();

-- -----------------------------------------------------------------------------
-- Yetki
--   belge.read        : proje / genel belgelerini görme
--   belge.finans_read : fatura, fiş ve sözleşme türündeki proje / genel
--                       belgelerini görme (finansal yetki)
--   belge.write       : belge ekleme
--   belge.manage      : başkasının belgesini arşivleme, iptal, bağlantı değiştirme
-- Finans belgesine bağlı dosya ayrıca o finans belgesini görmeyi
-- (can_read_fin_doc), sözleşmeye bağlı dosya sozlesme.read ister. Şantiye
-- şefi finansal yetkisi yoksa fatura ve sözleşme dosyalarını göremez.
-- -----------------------------------------------------------------------------
create or replace function private.is_financial_document_kind(p_kind public.document_kind)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_kind in ('fatura', 'fis', 'sozlesme');
$$;

-- Bağlı kayda erişim (okuma veya ekleme). p_action: 'read' | 'attach'.
create or replace function private.document_link_access(
  p_action text, p_link_type public.document_link_type, p_kind public.document_kind,
  p_project uuid, p_finance_document uuid, p_contract uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_perm text := case p_action when 'read' then 'belge.read' else 'belge.write' end;
  v_fd   public.finance_documents;
  v_c    public.contracts;
begin
  -- p_project boşsa kapsam genel masraf merkezidir: genel izin gerekir.
  if not private.has_permission(v_perm, p_project) then
    return false;
  end if;
  if p_action <> 'read' and not private.has_permission('belge.read', p_project) then
    return false;  -- göremeyeceği belgeyi ekleyemez
  end if;
  case p_link_type
    when 'proje', 'masraf_merkezi' then
      return not private.is_financial_document_kind(p_kind)
          or private.has_permission('belge.finans_read', p_project);
    when 'finans_belgesi' then
      select * into v_fd from public.finance_documents where id = p_finance_document;
      if not found or not private.can_read_fin_doc(v_fd.kind, v_fd.project_id, v_fd.created_by) then
        return false;
      end if;
      return p_action = 'read'
          or (v_fd.status <> 'iptal' and private.can_fin_doc(v_fd.kind, 'write', v_fd.project_id));
    when 'sozlesme' then
      select * into v_c from public.contracts where id = p_contract;
      if not found then
        return false;
      end if;
      return private.has_permission(case p_action when 'read' then 'sozlesme.read' else 'sozlesme.write' end,
                                    v_c.project_id);
  end case;
  return false;
end;
$$;

-- Belgeyi görebilir mi. Yükleme bekleyen belgeyi yalnızca yükleyen görür.
create or replace function private.can_read_document(
  p_status public.document_status, p_created_by uuid, p_link_type public.document_link_type,
  p_kind public.document_kind, p_project uuid, p_finance_document uuid, p_contract uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when p_status = 'bekliyor' then p_created_by = (select auth.uid())
                                           and private.document_link_access('read', p_link_type, p_kind, p_project,
                                                                            p_finance_document, p_contract)
           else private.document_link_access('read', p_link_type, p_kind, p_project, p_finance_document, p_contract)
         end;
$$;

-- Belgeyi yönetebilir mi (arşiv, iptal, bağlantı değişikliği). Kendi yüklediği
-- belgeyi, ekleme yetkisi sürdükçe yönetebilir; ancak onaylı/iptal finans
-- belgesine bağlı dosyanın geçmişini yalnızca belge.manage değiştirir.
create or replace function private.can_manage_document(d public.documents)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.can_read_document(d.status, d.created_by, d.link_type, d.kind, d.project_id,
                                   d.finance_document_id, d.contract_id)
     and (private.has_permission('belge.manage', d.project_id)
          or (d.created_by = (select auth.uid())
              and private.document_link_access('attach', d.link_type, d.kind, d.project_id,
                                               d.finance_document_id, d.contract_id)
              and (d.link_type <> 'finans_belgesi'
                   or exists (select 1 from public.finance_documents f
                               where f.id = d.finance_document_id and f.status = 'taslak'))));
$$;

grant execute on function private.is_financial_document_kind(public.document_kind) to authenticated;
grant execute on function private.document_link_access(text, public.document_link_type, public.document_kind, uuid, uuid, uuid)
  to authenticated;
grant execute on function private.can_read_document(public.document_status, uuid, public.document_link_type,
                                                    public.document_kind, uuid, uuid, uuid) to authenticated;
revoke execute on function private.can_manage_document(public.documents) from public, anon, authenticated;

-- Bağlanacak kaydın kapsamı ve referansları (istemciden gelen proje kimliğine
-- güvenilmez). Kayıt yoksa veya kullanıcı göremiyorsa P0002.
create or replace function private.document_target(p_link_type public.document_link_type, p_link_id uuid)
returns table (project_id uuid, cost_center_id uuid, finance_document_id uuid, contract_id uuid,
               cari_account_id uuid, subcontractor_id uuid, is_demo boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  case p_link_type
    when 'proje' then
      return query select p.id, null::uuid, null::uuid, null::uuid, null::uuid, null::uuid, p.is_demo
                     from public.projects p where p.id = p_link_id and p.deleted_at is null;
    when 'masraf_merkezi' then
      return query select null::uuid, c.id, null::uuid, null::uuid, null::uuid, null::uuid, c.is_demo
                     from public.cost_centers c where c.id = p_link_id;
    when 'finans_belgesi' then
      return query select f.project_id, f.cost_center_id, f.id, null::uuid, f.cari_account_id, null::uuid, f.is_demo
                     from public.finance_documents f where f.id = p_link_id;
    when 'sozlesme' then
      return query select c.project_id, null::uuid, null::uuid, c.id, c.cari_account_id, c.subcontractor_id, c.is_demo
                     from public.contracts c where c.id = p_link_id;
  end case;
end;
$$;
revoke execute on function private.document_target(public.document_link_type, uuid) from public, anon, authenticated;

create or replace function private.document_event(p_doc uuid, p_action text, p_from text, p_to text,
                                                  p_reason text default null, p_data jsonb default null)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.document_events (document_id, action, from_status, to_status, reason, data)
  values (p_doc, p_action, p_from, p_to, nullif(trim(p_reason), ''), p_data);
$$;
revoke execute on function private.document_event(uuid, text, text, text, text, jsonb) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.documents       enable row level security;
alter table public.document_events enable row level security;

create policy documents_select on public.documents
  for select to authenticated
  using (private.can_read_document(status, created_by, link_type, kind, project_id, finance_document_id, contract_id));
create policy document_events_select on public.document_events
  for select to authenticated
  using (exists (select 1 from public.documents d where d.id = document_id));

-- -----------------------------------------------------------------------------
-- Storage: özel bucket ve storage.objects politikaları
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('belgeler', 'belgeler', false, 26214400, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Nesneye yazma: yolu ayıran kişi, yükleme beklerken, süre dolmadan ve
-- ekleme yetkisi sürerken. Yol başka bir belgeye aitse veya hiç ayrılmamışsa
-- reddedilir (kullanıcı kendi yolunu uyduramaz).
create or replace function private.can_upload_document_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.documents d
     where d.storage_path = p_name
       and d.status = 'bekliyor'
       and d.created_by = (select auth.uid())
       and d.upload_expires_at > now()
       and private.document_link_access('attach', d.link_type, d.kind, d.project_id,
                                        d.finance_document_id, d.contract_id));
$$;

-- Nesneyi okuma: belge satırını görebilen kullanıcı.
create or replace function private.can_read_document_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.documents d
     where d.storage_path = p_name
       and private.can_read_document(d.status, d.created_by, d.link_type, d.kind, d.project_id,
                                     d.finance_document_id, d.contract_id));
$$;

grant execute on function private.can_upload_document_object(text) to authenticated;
grant execute on function private.can_read_document_object(text) to authenticated;

-- Politikalar fonksiyonla kurulur: veritabanı şema dökümü storage şemasındaki
-- politikaları taşımaz; geri yüklemede post_restore() bunları yeniden kurar.
-- UPDATE ve DELETE politikası yoktur: dosyanın üzerine yazılamaz ve silinemez.
create or replace function private.install_storage_policies()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop policy if exists belgeler_insert on storage.objects;
  drop policy if exists belgeler_select on storage.objects;
  create policy belgeler_insert on storage.objects
    for insert to authenticated
    with check (bucket_id = 'belgeler' and private.can_upload_document_object(name));
  create policy belgeler_select on storage.objects
    for select to authenticated
    using (bucket_id = 'belgeler' and private.can_read_document_object(name));
end;
$$;
revoke execute on function private.install_storage_policies() from public, anon, authenticated;

select private.install_storage_policies();

create or replace function private.post_restore()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform private.install_auth_hooks();
  perform private.install_storage_policies();
  perform private.harden_api_privileges();
end;
$$;
revoke execute on function private.post_restore() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 1) Yükleme yeri ayırma
--   Aynı kimlik aynı istekle gelirse aynı belge (ve aynı yol) döner; farklı
--   dosya/bilgiyle 23505. İptal edilmiş (süresi dolmuş) kimlik yeniden
--   kullanılamaz (23505): istemci yeni kimlikle başlar.
-- -----------------------------------------------------------------------------
create or replace function public.reserve_document_upload(
  p_id            uuid,
  p_kind          public.document_kind,
  p_title         text,
  p_link_type     public.document_link_type,
  p_link_id       uuid,
  p_mime_type     text,
  p_byte_size     bigint,
  p_sha256        text,
  p_document_date date default null,
  p_description   text default null,
  p_replaces_id   uuid default null)
returns public.documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  t      record;
  d      public.documents;
  r      public.documents;
  v_sha  text := lower(trim(coalesce(p_sha256, '')));
  v_date date := coalesce(p_document_date, private.today());
  v_path text;
begin
  if p_id is null then
    raise exception 'Belge kimliği zorunlu' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_title), '')) = 0 or length(trim(p_title)) > 200 then
    raise exception 'Belge adı zorunlu (en çok 200 karakter)' using errcode = 'check_violation';
  end if;
  if p_mime_type is null or p_mime_type not in ('application/pdf', 'image/jpeg', 'image/png') then
    raise exception 'Desteklenmeyen dosya türü: yalnızca PDF, JPEG ve PNG' using errcode = 'check_violation';
  end if;
  if p_byte_size is null or p_byte_size <= 0 or p_byte_size > 26214400 then
    raise exception 'Dosya boyutu 1 bayt ile 25 MB arasında olmalı' using errcode = 'check_violation';
  end if;
  if v_sha !~ '^[0-9a-f]{64}$' then
    raise exception 'SHA-256 özeti geçersiz' using errcode = 'check_violation';
  end if;
  if v_date > private.today() + 1 then
    raise exception 'Belge tarihi ileri bir tarih olamaz' using errcode = 'check_violation';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_id::text, 0));

  -- Kaydın kendisini görebiliyor mu (tür kısıtı olmadan); türe göre ekleme
  -- yetkisi aşağıda ayrıca denetlenir.
  select * into t from private.document_target(p_link_type, p_link_id);
  if not found or not private.document_link_access('read', p_link_type, 'diger', t.project_id,
                                                   t.finance_document_id, t.contract_id) then
    raise exception 'Bağlanacak kayıt bulunamadı' using errcode = 'no_data_found';
  end if;

  -- Tekrar gönderim
  select * into d from public.documents where id = p_id;
  if found then
    if d.created_by is distinct from (select auth.uid())
       or not private.can_read_document(d.status, d.created_by, d.link_type, d.kind, d.project_id,
                                        d.finance_document_id, d.contract_id) then
      raise exception 'Bu kimlikle başka bir belge var' using errcode = 'unique_violation';
    end if;
    if d.status = 'iptal' then
      raise exception 'Bu kimlikli yükleme iptal edilmiş; yeni yükleme başlatın' using errcode = 'unique_violation';
    end if;
    if d.kind = p_kind and d.title = trim(p_title) and d.link_type = p_link_type
       and coalesce(d.finance_document_id, d.contract_id, d.project_id, d.cost_center_id) = p_link_id
       and d.mime_type = p_mime_type and d.byte_size = p_byte_size and d.sha256 = v_sha
       and d.document_date = v_date
       and d.description is not distinct from nullif(trim(p_description), '')
       and d.replaces_id is not distinct from p_replaces_id then
      return d;
    end if;
    raise exception 'Bu kimlikle farklı bir dosya veya bilgi gönderildi' using errcode = 'unique_violation';
  end if;

  if not private.document_link_access('attach', p_link_type, p_kind, t.project_id,
                                      t.finance_document_id, t.contract_id) then
    raise exception 'Bu kayda belge ekleme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  if p_replaces_id is not null then
    select * into r from public.documents where id = p_replaces_id for update;
    if not found or not private.can_read_document(r.status, r.created_by, r.link_type, r.kind, r.project_id,
                                                  r.finance_document_id, r.contract_id) then
      raise exception 'Değiştirilecek belge bulunamadı' using errcode = 'no_data_found';
    end if;
    if r.status <> 'yuklendi' then
      raise exception 'Yalnızca yüklenmiş etkin belge değiştirilebilir' using errcode = 'check_violation';
    end if;
    if r.link_type <> p_link_type
       or coalesce(r.finance_document_id, r.contract_id, r.project_id, r.cost_center_id) <> p_link_id then
      raise exception 'Yeni dosya aynı kayda bağlanmalı' using errcode = 'check_violation';
    end if;
    if not private.can_manage_document(r) then
      raise exception 'Bu belgeyi değiştirme yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if exists (select 1 from public.documents x where x.replaces_id = r.id) then
      raise exception 'Bu belge için zaten bir değiştirme yüklemesi var' using errcode = 'unique_violation';
    end if;
  end if;

  if exists (select 1 from public.documents x
              where x.status = 'yuklendi' and x.sha256 = v_sha and x.link_type = p_link_type
                and coalesce(x.finance_document_id, x.contract_id, x.project_id, x.cost_center_id) = p_link_id) then
    raise exception 'Bu dosya bu kayda zaten eklenmiş' using errcode = 'unique_violation';
  end if;

  -- Sunucunun ayırdığı, tahmin edilemez yol (dosya adı veya proje içermez).
  v_path := gen_random_uuid()::text || '/' || gen_random_uuid()::text
            || case p_mime_type when 'application/pdf' then '.pdf' when 'image/png' then '.png' else '.jpg' end;

  insert into public.documents (id, kind, title, description, document_date, link_type, project_id, cost_center_id,
                                finance_document_id, contract_id, cari_account_id, subcontractor_id, mime_type,
                                byte_size, sha256, storage_path, status, upload_expires_at, replaces_id, is_demo)
  values (p_id, p_kind, trim(p_title), nullif(trim(p_description), ''), v_date, p_link_type, t.project_id,
          t.cost_center_id, t.finance_document_id, t.contract_id, t.cari_account_id, t.subcontractor_id, p_mime_type,
          p_byte_size, v_sha, v_path, 'bekliyor', now() + interval '24 hours', p_replaces_id, t.is_demo)
  returning * into d;

  perform private.document_event(d.id, 'rezerve', null, 'bekliyor', null,
                                 jsonb_build_object('byte_size', p_byte_size, 'sha256', v_sha, 'mime_type', p_mime_type,
                                                    'replaces_id', p_replaces_id));
  return d;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2) Yüklemeyi tamamlama: nesne var mı, boyutu ve türü ayrılan bilgiyle aynı mı.
--   Tekrar çağrı aynı belgeyi döner. Nesne yoksa P0002 (istemci yüklemeyi
--   yeniden dener). Değiştirme yüklemesinde eski belge iptal edilir (dosyası
--   ve geçmişi korunur).
-- -----------------------------------------------------------------------------
create or replace function public.complete_document_upload(p_id uuid)
returns public.documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  d     public.documents;
  o     record;
begin
  select * into d from public.documents where id = p_id for update;
  if not found or d.created_by is distinct from (select auth.uid())
     or not private.can_read_document(d.status, d.created_by, d.link_type, d.kind, d.project_id,
                                      d.finance_document_id, d.contract_id) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if d.status in ('yuklendi', 'arsivlendi') then
    return d;
  end if;
  if d.status = 'iptal' then
    raise exception 'Bu yükleme iptal edilmiş veya süresi dolmuş; yeniden başlatın' using errcode = 'unique_violation';
  end if;
  if not private.document_link_access('attach', d.link_type, d.kind, d.project_id, d.finance_document_id, d.contract_id) then
    raise exception 'Bu kayda belge ekleme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  select (x.metadata ->> 'size')::bigint as size, x.metadata ->> 'mimetype' as mimetype into o
    from storage.objects x
   where x.bucket_id = d.storage_bucket and x.name = d.storage_path
   order by x.created_at desc
   limit 1;
  if not found then
    raise exception 'Dosya henüz yüklenmedi' using errcode = 'no_data_found';
  end if;
  if o.size is distinct from d.byte_size then
    raise exception 'Yüklenen dosyanın boyutu beklenenden farklı (% / %)', o.size, d.byte_size
      using errcode = 'check_violation';
  end if;
  if o.mimetype is distinct from d.mime_type then
    raise exception 'Yüklenen dosyanın türü beklenenden farklı' using errcode = 'check_violation';
  end if;

  if d.replaces_id is not null then
    update public.documents
       set status = 'iptal', cancelled_at = now(), cancelled_by = (select auth.uid()),
           cancel_reason = 'Yeni dosyayla değiştirildi'
     where id = d.replaces_id and status = 'yuklendi';
    if not found then
      raise exception 'Değiştirilecek belge artık etkin değil' using errcode = 'check_violation';
    end if;
    perform private.document_event(d.replaces_id, 'degistirildi', 'yuklendi', 'iptal', 'Yeni dosyayla değiştirildi',
                                   jsonb_build_object('yeni_belge', d.id));
  end if;

  update public.documents
     set status = 'yuklendi', uploaded_at = now(), uploaded_by = (select auth.uid()), upload_expires_at = null
   where id = d.id
   returning * into d;
  perform private.document_event(d.id, 'yuklendi', 'bekliyor', 'yuklendi', null,
                                 jsonb_build_object('byte_size', d.byte_size, 'sha256', d.sha256));
  return d;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3) Arşivleme, iptal, bağlantı değişikliği
-- -----------------------------------------------------------------------------
create or replace function public.archive_document(p_id uuid, p_reason text)
returns public.documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documents;
begin
  select * into d from public.documents where id = p_id for update;
  if not found or not private.can_read_document(d.status, d.created_by, d.link_type, d.kind, d.project_id,
                                                d.finance_document_id, d.contract_id) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if d.status = 'arsivlendi' then
    return d;
  end if;
  if d.status <> 'yuklendi' then
    raise exception 'Yalnızca yüklenmiş belge arşivlenebilir' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_reason), '')) < 3 then
    raise exception 'Arşivleme gerekçesi zorunlu' using errcode = 'check_violation';
  end if;
  if not private.can_manage_document(d) then
    raise exception 'Bu belgeyi arşivleme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  update public.documents
     set status = 'arsivlendi', archived_at = now(), archived_by = (select auth.uid()), archive_reason = trim(p_reason)
   where id = d.id returning * into d;
  perform private.document_event(d.id, 'arsivlendi', 'yuklendi', 'arsivlendi', p_reason);
  return d;
end;
$$;

-- Bekleyen yükleme: yükleyen gerekçesiz vazgeçebilir. Yüklenmiş belge: yanlış
-- dosya; gerekçe ≥ 10 karakter. Dosya ve geçmiş korunur.
create or replace function public.cancel_document(p_id uuid, p_reason text)
returns public.documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  d      public.documents;
  v_from text;
begin
  select * into d from public.documents where id = p_id for update;
  if not found or not private.can_read_document(d.status, d.created_by, d.link_type, d.kind, d.project_id,
                                                d.finance_document_id, d.contract_id) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if d.status = 'iptal' then
    return d;
  end if;
  v_from := d.status::text;
  if d.status = 'bekliyor' then
    if d.created_by is distinct from (select auth.uid()) then
      raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
    end if;
  else
    if length(coalesce(trim(p_reason), '')) < 10 then
      raise exception 'İptal gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
    end if;
    if not private.can_manage_document(d) then
      raise exception 'Bu belgeyi iptal etme yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
  end if;
  update public.documents
     set status = 'iptal', cancelled_at = now(), cancelled_by = (select auth.uid()),
         cancel_reason = coalesce(nullif(trim(p_reason), ''), 'Yükleme vazgeçildi'), upload_expires_at = null
   where id = d.id returning * into d;
  perform private.document_event(d.id, 'iptal', v_from, 'iptal', d.cancel_reason);
  return d;
end;
$$;

-- Yanlış kayda bağlanmış belgeyi başka kayda taşır (belge.manage). Yeni kapsam
-- ve referanslar yeni kayıttan türetilir; DEMO ile gerçek arasında taşınamaz.
create or replace function public.relink_document(
  p_id uuid, p_link_type public.document_link_type, p_link_id uuid, p_reason text, p_expected_version integer)
returns public.documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documents;
  t record;
begin
  select * into d from public.documents where id = p_id for update;
  if not found or not private.can_read_document(d.status, d.created_by, d.link_type, d.kind, d.project_id,
                                                d.finance_document_id, d.contract_id) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('belge.manage', d.project_id) then
    raise exception 'Belge bağlantısını değiştirme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if d.version <> p_expected_version then
    raise exception 'Belge başka biri tarafından değiştirildi; yeniden yükleyin' using errcode = 'serialization_failure';
  end if;
  if d.status not in ('yuklendi', 'arsivlendi') then
    raise exception 'Yalnızca yüklenmiş belgenin bağlantısı değiştirilebilir' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_reason), '')) < 10 then
    raise exception 'Bağlantı değişikliği gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;
  select * into t from private.document_target(p_link_type, p_link_id);
  if not found or not private.document_link_access('read', p_link_type, 'diger', t.project_id,
                                                   t.finance_document_id, t.contract_id) then
    raise exception 'Bağlanacak kayıt bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.document_link_access('attach', p_link_type, d.kind, t.project_id, t.finance_document_id, t.contract_id)
     or not private.has_permission('belge.manage', t.project_id) then
    raise exception 'Hedef kayda belge ekleme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if t.is_demo is distinct from d.is_demo then
    raise exception 'Deneme (DEMO) belgesi gerçek kayda, gerçek belge deneme kaydına taşınamaz'
      using errcode = 'check_violation';
  end if;
  if d.link_type = p_link_type and coalesce(d.finance_document_id, d.contract_id, d.project_id, d.cost_center_id) = p_link_id then
    return d;
  end if;

  perform private.document_event(d.id, 'baglanti_degisti', d.status::text, d.status::text, p_reason,
                                 jsonb_build_object('eski', jsonb_build_object('link_type', d.link_type,
                                                      'project_id', d.project_id, 'cost_center_id', d.cost_center_id,
                                                      'finance_document_id', d.finance_document_id,
                                                      'contract_id', d.contract_id),
                                                    'yeni', jsonb_build_object('link_type', p_link_type, 'link_id', p_link_id)));
  update public.documents
     set link_type = p_link_type, project_id = t.project_id, cost_center_id = t.cost_center_id,
         finance_document_id = t.finance_document_id, contract_id = t.contract_id,
         cari_account_id = t.cari_account_id, subcontractor_id = t.subcontractor_id
   where id = d.id returning * into d;
  return d;
end;
$$;

-- -----------------------------------------------------------------------------
-- Yarım kalan yüklemeler ve yetim nesneler (yalnızca bakım işi çağırır)
-- -----------------------------------------------------------------------------
-- Süresi dolmuş bekleyen yüklemeleri iptal eder; dönen sayı iptal edilen belge sayısıdır.
create or replace function private.expire_document_uploads()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  with x as (
    update public.documents
       set status = 'iptal', cancelled_at = now(), cancel_reason = 'Yükleme süresi doldu', upload_expires_at = null
     where status = 'bekliyor' and upload_expires_at <= now()
     returning id)
  select coalesce(array_agg(id), '{}') into v_ids from x;
  insert into public.document_events (document_id, action, from_status, to_status, reason)
  select unnest(v_ids), 'suresi_doldu', 'bekliyor', 'iptal', 'Yükleme süresi doldu';
  return cardinality(v_ids);
end;
$$;
revoke execute on function private.expire_document_uploads() from public, anon, authenticated;

-- Silinmesi güvenli (yetim) nesneler: hiçbir belgenin tamamlanmış dosyası
-- olmayan ve süresi dolmamış bir yüklemeye ait olmayan, yeterince eski
-- nesneler. Yüklenmiş, arşivlenmiş veya sonradan iptal edilmiş belgenin
-- dosyası bu listeye hiçbir zaman girmez.
create or replace function private.document_orphan_objects(p_min_age interval default interval '24 hours')
returns table (name text, byte_size bigint, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select o.name, (o.metadata ->> 'size')::bigint, o.created_at
    from storage.objects o
   where o.bucket_id = 'belgeler'
     and o.created_at <= now() - p_min_age
     and not exists (select 1 from public.documents d
                      where d.storage_path = o.name
                        and (d.uploaded_at is not null
                             or d.status in ('yuklendi', 'arsivlendi')
                             or (d.status = 'bekliyor' and d.upload_expires_at > now())))
   order by o.created_at;
$$;
revoke execute on function private.document_orphan_objects(interval) from public, anon, authenticated;

-- Yedek bütünlük denetimi: tamamlanmış her dosyanın yolu, boyutu ve SHA-256'sı.
create or replace function private.document_storage_manifest()
returns table (storage_path text, byte_size bigint, sha256 text)
language sql
stable
security definer
set search_path = ''
as $$
  select d.storage_path, d.byte_size, d.sha256
    from public.documents d
   where d.uploaded_at is not null
   order by d.storage_path;
$$;
revoke execute on function private.document_storage_manifest() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- API ayrıcalıkları
-- -----------------------------------------------------------------------------
create or replace function private.harden_api_privileges()
returns void
language plpgsql
set search_path = ''
as $$
begin
  revoke all on all tables    in schema public from anon;
  revoke all on all sequences in schema public from anon;
  revoke execute on all functions in schema public  from public, anon;
  revoke execute on all functions in schema private from public, anon;
  revoke execute on all functions in schema audit   from public, anon, authenticated;
  revoke truncate, references, trigger, delete on all tables in schema public from authenticated;

  -- İzin kataloğu yalnızca migration ile değişir.
  revoke insert, update on public.permissions from authenticated;
  -- Profil yalnızca Auth trigger'ı ile oluşur; e-posta ve telefon kapalı.
  revoke select, insert, update on public.profiles from authenticated;
  grant select (id, full_name, is_active, created_at, created_by, updated_at, updated_by, version)
    on public.profiles to authenticated;
  grant update (full_name, phone, is_active) on public.profiles to authenticated;

  -- Cari defter ve eşleştirmeler yalnızca RPC'lerle yazılır.
  revoke insert, update on public.cari_entries     from authenticated;
  revoke insert, update on public.cari_allocations from authenticated;

  -- Puantaj yalnızca RPC'lerle yazılır; durum tanımları migration ile değişir.
  revoke insert, update on public.puantaj_status_definitions from authenticated;
  revoke insert, update on public.puantaj_periods            from authenticated;
  revoke insert, update on public.puantaj_entries            from authenticated;
  revoke insert, update on public.puantaj_period_events      from authenticated;

  -- Sözleşme, imalat, hakediş, teminat ve ödeme yalnızca RPC'lerle yazılır.
  revoke insert, update on public.tax_rules              from authenticated;
  revoke insert, update on public.payment_sources        from authenticated;
  revoke insert, update on public.contracts              from authenticated;
  revoke insert, update on public.contract_versions      from authenticated;
  revoke insert, update on public.contract_items         from authenticated;
  revoke insert, update on public.contract_version_taxes from authenticated;
  revoke insert, update on public.work_quantities        from authenticated;
  revoke insert, update on public.hakedis                from authenticated;
  revoke insert, update on public.hakedis_lines          from authenticated;
  revoke insert, update on public.hakedis_quantity_links from authenticated;
  revoke insert, update on public.hakedis_puantaj_links  from authenticated;
  revoke insert, update on public.hakedis_adjustments    from authenticated;
  revoke insert, update on public.teminat_releases       from authenticated;
  revoke insert, update on public.finance_payments       from authenticated;
  revoke insert, update on public.finance_events         from authenticated;

  -- Gider, gelir, ödeme ve tahsilat yalnızca RPC'lerle yazılır.
  revoke insert, update on public.finance_categories      from authenticated;
  revoke insert, update on public.finance_documents       from authenticated;
  revoke insert, update on public.finance_settlements     from authenticated;
  revoke insert, update on public.finance_document_events from authenticated;

  -- Belge arşivi yalnızca RPC'lerle yazılır.
  revoke insert, update on public.documents       from authenticated;
  revoke insert, update on public.document_events from authenticated;
end;
$$;
revoke execute on function private.harden_api_privileges() from public, anon, authenticated;

select private.harden_api_privileges();

grant execute on function public.reserve_document_upload(uuid, public.document_kind, text, public.document_link_type, uuid,
                                                         text, bigint, text, date, text, uuid) to authenticated;
grant execute on function public.complete_document_upload(uuid) to authenticated;
grant execute on function public.archive_document(uuid, text) to authenticated;
grant execute on function public.cancel_document(uuid, text) to authenticated;
grant execute on function public.relink_document(uuid, public.document_link_type, uuid, text, integer) to authenticated;

-- -----------------------------------------------------------------------------
-- İzinler ve rol şablonları. Şantiye şefi projesinde belge görür ve ekler
-- (irsaliye, tutanak, kendi gider fişi); fatura, fiş ve sözleşme türündeki
-- proje belgelerini ve sözleşme dosyalarını finansal yetkisi olmadan görmez.
-- -----------------------------------------------------------------------------
insert into public.permissions (key, module, description) values
  ('belge.read',        'belge', 'Proje ve genel belgeleri görüntüleme (irsaliye, tutanak, ruhsat, diğer)'),
  ('belge.finans_read', 'belge', 'Fatura, fiş ve sözleşme türündeki proje ve genel belgeleri görüntüleme'),
  ('belge.write',       'belge', 'Belge ekleme (tarama, fotoğraf, dosya)'),
  ('belge.manage',      'belge', 'Başkasının belgesini arşivleme, iptal etme ve bağlantısını değiştirme');

insert into public.role_permissions (role_id, permission_key)
select r.id, x.permission_key
  from (values
          ('muhasebe',      'belge.read'),
          ('muhasebe',      'belge.finans_read'),
          ('muhasebe',      'belge.write'),
          ('muhasebe',      'belge.manage'),
          ('idari_isler',   'belge.read'),
          ('idari_isler',   'belge.write'),
          ('proje_muduru',  'belge.read'),
          ('proje_muduru',  'belge.finans_read'),
          ('proje_muduru',  'belge.write'),
          ('proje_muduru',  'belge.manage'),
          ('santiye_sefi',  'belge.read'),
          ('santiye_sefi',  'belge.write'),
          ('goruntuleyici', 'belge.read')
       ) as x (role_key, permission_key)
  join public.roles r on r.key = x.role_key;
