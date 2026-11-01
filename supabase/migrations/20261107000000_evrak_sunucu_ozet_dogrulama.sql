-- =============================================================================
-- Aşama 6 inceleme düzeltmesi: yüklenen dosyanın SHA-256 özeti sunucuda
-- doğrulanır (önceki migration'lar değişmedi).
--
-- Önceki durum: complete_document_upload yalnızca Storage'daki boyut ve MIME
-- türünü karşılaştırıyordu; documents.sha256 istemcinin beyanıydı. Aynı boyut
-- ve türde farklı içerik "yüklendi" sayılabilirdi.
--
-- Yeni akış:
--   1. İstemci dosyayı ayrılmış yola yükler (değişmedi).
--   2. İstemci `belge-dogrula` Edge Function'ını kendi oturumuyla çağırır.
--      Fonksiyon önce kullanıcının oturumuyla document_upload_target(id)
--      çağırarak belgenin bu kullanıcıya ait bekleyen bir yükleme olduğunu
--      doğrular; sonra Storage'daki gerçek baytları sunucu anahtarıyla indirir,
--      SHA-256 ve boyutu hesaplar ve record_document_server_hash ile kaydeder
--      (yalnızca service_role çalıştırabilir). Son olarak kullanıcının
--      oturumuyla complete_document_upload çağırır.
--   3. complete_document_upload artık sunucunun hesapladığı özet ve boyut
--      beyan edilenle aynı değilse belgeyi "yüklendi" yapmaz.
--   4. Özet uyuşmazsa belge iptal edilir (yeniden denemede yeni kimlik ve
--      yeni yol kullanılır; Storage'da üzerine yazma yoktur) ve geçmişe
--      `ozet_uyusmadi` yazılır.
-- =============================================================================

alter table public.documents
  add column server_sha256      text check (server_sha256 ~ '^[0-9a-f]{64}$'),
  add column server_byte_size   bigint,
  add column server_verified_at timestamptz;

-- Yüklenmiş ve arşivlenmiş belgede sunucu özeti beyan edilenle aynı olmalı.
-- NOT VALID: bu migration'dan önce (yalnızca yerel geliştirme ortamlarında)
-- doğrulanmadan yüklenmiş satırlar engel olmasın; yeni ve değişen satırlar denetlenir.
alter table public.documents
  add constraint documents_server_hash_ck check (
    status not in ('yuklendi', 'arsivlendi')
    or (server_sha256 = sha256 and server_byte_size = byte_size and server_verified_at is not null)
  ) not valid;

-- Sunucu özeti bir kez yazılır, yalnızca yükleme beklerken.
create or replace function private.tg_document_server_hash_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.server_sha256, new.server_byte_size, new.server_verified_at)
     is distinct from (old.server_sha256, old.server_byte_size, old.server_verified_at) then
    if old.server_verified_at is not null then
      raise exception 'Sunucu doğrulaması bir kez yazılır' using errcode = 'check_violation';
    end if;
    if old.status <> 'bekliyor' then
      raise exception 'Yalnızca yükleme bekleyen belge doğrulanır' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;
create trigger document_server_hash_guard before update on public.documents
  for each row execute function private.tg_document_server_hash_guard();

-- -----------------------------------------------------------------------------
-- 1) Doğrulama hedefi (kullanıcının oturumuyla): yalnızca kendi bekleyen veya
--    tamamlanmış yüklemesinin yolunu verir.
-- -----------------------------------------------------------------------------
create or replace function public.document_upload_target(p_id uuid)
returns table (id uuid, status public.document_status, storage_path text, byte_size bigint, mime_type text,
               server_verified boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d public.documents;
begin
  select * into d from public.documents x where x.id = p_id;
  if not found or d.created_by is distinct from (select auth.uid())
     or not private.can_read_document(d.status, d.created_by, d.link_type, d.kind, d.project_id,
                                      d.finance_document_id, d.contract_id) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if d.status = 'bekliyor'
     and not private.document_link_access('attach', d.link_type, d.kind, d.project_id, d.finance_document_id,
                                          d.contract_id) then
    raise exception 'Bu kayda belge ekleme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  return query select d.id, d.status, d.storage_path, d.byte_size, d.mime_type, d.server_verified_at is not null;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2) Sunucu özeti (yalnızca service_role: Edge Function). Özet veya boyut
--    uyuşmazsa belge iptal edilir.
-- -----------------------------------------------------------------------------
create or replace function public.record_document_server_hash(p_id uuid, p_sha256 text, p_byte_size bigint)
returns table (matches boolean, status public.document_status)
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documents;
  v_sha text := lower(trim(coalesce(p_sha256, '')));
begin
  if v_sha !~ '^[0-9a-f]{64}$' or p_byte_size is null or p_byte_size < 0 then
    raise exception 'Geçersiz özet veya boyut' using errcode = 'check_violation';
  end if;
  select * into d from public.documents x where x.id = p_id for update;
  if not found then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if d.status <> 'bekliyor' then
    -- Tamamlanmış belgede tekrar çağrı: kayıtlı sonuç döner (değiştirilmez).
    return query select d.server_sha256 is not distinct from v_sha and d.server_byte_size is not distinct from p_byte_size,
                        d.status;
    return;
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = d.storage_bucket and o.name = d.storage_path) then
    raise exception 'Dosya henüz yüklenmedi' using errcode = 'no_data_found';
  end if;
  if d.server_verified_at is not null then
    return query select d.server_sha256 = v_sha and d.server_byte_size = p_byte_size, d.status;
    return;
  end if;

  update public.documents x
     set server_sha256 = v_sha, server_byte_size = p_byte_size, server_verified_at = now()
   where x.id = d.id
   returning * into d;

  if d.server_sha256 <> d.sha256 or d.server_byte_size <> d.byte_size then
    update public.documents x
       set status = 'iptal', cancelled_at = now(), upload_expires_at = null,
           cancel_reason = 'Sunucuda hesaplanan özet beyan edilen dosyayla uyuşmuyor'
     where x.id = d.id
     returning * into d;
    perform private.document_event(d.id, 'ozet_uyusmadi', 'bekliyor', 'iptal', d.cancel_reason,
                                   jsonb_build_object('beyan_sha256', d.sha256, 'sunucu_sha256', d.server_sha256,
                                                      'beyan_boyut', d.byte_size, 'sunucu_boyut', d.server_byte_size));
    return query select false, d.status;
    return;
  end if;
  -- Başarılı doğrulama ayrı olay yazmaz; tamamlamadaki 'yuklendi' olayı bunu taşır.
  return query select true, d.status;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3) Tamamlama: sunucu özeti zorunlu.
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
    raise exception '%', case when d.server_verified_at is not null and d.server_sha256 <> d.sha256
                              then 'Sunucuya ulaşan dosya cihazdakiyle aynı değil; yeniden yükleyin'
                              else 'Bu yükleme iptal edilmiş veya süresi dolmuş; yeniden başlatın' end
      using errcode = 'unique_violation';
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
  if d.server_verified_at is null then
    raise exception 'Dosyanın özeti sunucuda henüz doğrulanmadı' using errcode = 'check_violation';
  end if;
  if d.server_sha256 <> d.sha256 or d.server_byte_size <> d.byte_size then
    -- record_document_server_hash bu durumda belgeyi zaten iptal eder; ikinci savunma.
    raise exception 'Sunucuya ulaşan dosya cihazdakiyle aynı değil; yeniden yükleyin' using errcode = 'unique_violation';
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
                                 jsonb_build_object('byte_size', d.byte_size, 'sha256', d.sha256,
                                                    'sunucuda_dogrulandi', true));
  return d;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4) Yedek doğrulaması yalnızca sunucuda doğrulanmış özetlere güvenir.
-- -----------------------------------------------------------------------------
create or replace function private.document_storage_manifest()
returns table (storage_path text, byte_size bigint, sha256 text)
language sql
stable
security definer
set search_path = ''
as $$
  select d.storage_path, d.server_byte_size, d.server_sha256
    from public.documents d
   where d.uploaded_at is not null and d.server_verified_at is not null
   order by d.storage_path;
$$;
revoke execute on function private.document_storage_manifest() from public, anon, authenticated;

-- Doğrulanmadan yüklenmiş eski satırlar (yalnızca bu migration'dan önceki
-- yerel ortamlar): yedek raporunda ayrıca sayılır.
create or replace function private.unverified_document_count()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) from public.documents d where d.uploaded_at is not null and d.server_verified_at is null;
$$;
revoke execute on function private.unverified_document_count() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Ayrıcalıklar
-- -----------------------------------------------------------------------------
revoke execute on function public.document_upload_target(uuid) from public, anon;
grant execute on function public.document_upload_target(uuid) to authenticated;
revoke execute on function public.record_document_server_hash(uuid, text, bigint) from public, anon, authenticated;
grant execute on function public.record_document_server_hash(uuid, text, bigint) to service_role;
revoke execute on function private.tg_document_server_hash_guard() from public, anon, authenticated;

-- post_restore() bu fonksiyonu çağırır: geri yüklenen ortamda da sunucu özeti
-- fonksiyonu oturum açmış kullanıcıya kapalı kalır (önceki tanım + bir satır).
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
  -- Sunucu özeti yalnızca belge-dogrula Edge Function'ı (service_role) yazar.
  -- Geri yüklenen ortamda varsayılan ayrıcalıklar bunu yeniden açmasın.
  revoke execute on function public.record_document_server_hash(uuid, text, bigint) from authenticated;
end;
$$;
revoke execute on function private.harden_api_privileges() from public, anon, authenticated;

select private.harden_api_privileges();
