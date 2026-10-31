-- =============================================================================
-- PR #7 incelemesi: gider/gelir yetki ve tekrar gönderim düzeltmeleri.
-- 20261104000000_gider_gelir.sql değiştirilmez; iki fonksiyon aynı imzayla
-- yeniden tanımlanır (yetkiler korunur).
--
-- 1) save_finance_document: var olan belgeye yazmadan (güncelleme veya tekrar
--    gönderim) önce RLS görünürlük kuralı aranır (private.can_read_fin_doc):
--    okuma izni ya da kendi girdiği belge. Şantiye şefi başka kullanıcının
--    taslağını kimliğini bilse bile değiştiremez; görmediği belgenin
--    kimliğiyle gelen istek 23505 alır (içerik sızdırılmaz).
-- 2) Tekrar gönderim karşılaştırması kullanıcı niyetinin tüm alanlarını
--    kapsar: belge referansı, not ve bildiren kişi de (boşluk temizlenerek)
--    aynı olmalı; farklıysa 23505.
-- 3) record_finance_settlement: ödeyen kişi ve açıklama da karşılaştırılır;
--    iptal edilmiş ödeme/tahsilatın kimliğiyle tekrar deneme 23505 alır ve
--    iptal edilmiş kaydı etkin ödeme gibi döndürmez.
-- =============================================================================

create or replace function public.save_finance_document(
  p_id                 uuid,
  p_kind               public.finance_doc_kind,
  p_category_id        uuid,
  p_description        text,
  p_amount             numeric,
  p_document_date      date,
  p_project_id         uuid    default null,
  p_cost_center_id     uuid    default null,
  p_due_date           date    default null,
  p_currency           text    default 'TRY',
  p_exchange_rate      numeric default null,
  p_cari_account_id    uuid    default null,
  p_invoice_no         text    default null,
  p_document_ref       text    default null,
  p_notes              text    default null,
  p_reported_settled   boolean default false,
  p_reported_source_id uuid    default null,
  p_reported_by        text    default null,
  p_expected_version   integer default null)
returns public.finance_documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  d        public.finance_documents;
  v_cur    text := upper(coalesce(nullif(trim(p_currency), ''), 'TRY'));
  v_rate   numeric;
  v_demo   boolean;
  v_due    date := coalesce(p_due_date, p_document_date);
  v_src    uuid := case when coalesce(p_reported_settled, false) then p_reported_source_id end;
  v_by     text := case when coalesce(p_reported_settled, false) then nullif(trim(p_reported_by), '') end;
begin
  if p_kind is null or num_nonnulls(p_project_id, p_cost_center_id) <> 1 then
    raise exception 'Belge bir projeye veya bir genel masraf merkezine bağlanmalı' using errcode = 'check_violation';
  end if;
  if not private.can_fin_doc(p_kind, 'write', p_project_id) then
    raise exception 'Bu kapsamda % kaydetme yetkiniz yok', p_kind using errcode = 'insufficient_privilege';
  end if;

  -- Kapsam ve DEMO işareti
  if p_project_id is not null then
    select pr.is_demo into v_demo from public.projects pr where pr.id = p_project_id and pr.deleted_at is null;
    if not found then
      raise exception 'Proje bulunamadı' using errcode = 'foreign_key_violation';
    end if;
  else
    select cc.is_demo into v_demo from public.cost_centers cc
     where cc.id = p_cost_center_id and cc.deleted_at is null and cc.is_active;
    if not found then
      raise exception 'Masraf merkezi bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
  end if;

  -- Doğrulama
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Tutar pozitif ve en çok iki ondalıklı olmalı' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_description), '')) = 0 then
    raise exception 'Açıklama zorunlu' using errcode = 'check_violation';
  end if;
  if p_document_date is null then
    raise exception 'Tarih zorunlu' using errcode = 'check_violation';
  end if;
  if v_due < p_document_date then
    raise exception 'Vade tarihi belge tarihinden önce olamaz' using errcode = 'check_violation';
  end if;
  if v_cur !~ '^[A-Z]{3}$' then
    raise exception 'Para birimi üç harfli kod olmalı' using errcode = 'check_violation';
  end if;
  v_rate := private.resolve_exchange_rate(v_cur, p_exchange_rate);
  if not exists (select 1 from public.finance_categories k where k.id = p_category_id and k.kind = p_kind and k.is_active) then
    raise exception 'Kategori bulunamadı, pasif veya bu türe ait değil' using errcode = 'foreign_key_violation';
  end if;
  if p_cari_account_id is not null then
    if not exists (select 1 from public.cari_accounts c
                    where c.id = p_cari_account_id and c.deleted_at is null and c.is_active) then
      raise exception 'Cari hesap bulunamadı veya pasif' using errcode = 'foreign_key_violation';
    end if;
    if (select c.is_demo from public.cari_accounts c where c.id = p_cari_account_id) is distinct from v_demo then
      raise exception 'Demo kayıtlar gerçek kayıtlarla aynı belgede kullanılamaz' using errcode = 'check_violation';
    end if;
  end if;
  if coalesce(p_reported_settled, false)
     and not exists (select 1 from public.payment_sources s where s.id = v_src and s.is_active) then
    raise exception 'Peşin ödeme/tahsilat için ödeme kaynağı seçilmeli' using errcode = 'check_violation';
  end if;

  select * into d from public.finance_documents where id = p_id for update;
  if found then
    -- Görünürlük kuralı (RLS ile aynı): belgeyi göremeyen kullanıcı onu ne
    -- güncelleyebilir ne de tekrar gönderimle içeriğini öğrenebilir. Şantiye
    -- şefi yalnızca kendi taslağını; okuma izni olan muhasebe/müdür/yönetici
    -- kapsamındaki taslakları düzenler.
    if not private.can_read_fin_doc(d.kind, d.project_id, d.created_by) then
      raise exception 'Bu kimlikle başka bir belge var' using errcode = 'unique_violation';
    end if;
    if p_expected_version is null then
      -- Tekrar gönderim: saklanan biçimde karşılaştır.
      if d.kind = p_kind and d.category_id = p_category_id and d.description = trim(p_description)
         and d.amount = p_amount and d.document_date = p_document_date and d.due_date = v_due
         and d.project_id is not distinct from p_project_id and d.cost_center_id is not distinct from p_cost_center_id
         and d.currency = v_cur and d.exchange_rate = v_rate
         and d.cari_account_id is not distinct from p_cari_account_id
         and d.invoice_no is not distinct from nullif(trim(p_invoice_no), '')
         and d.reported_settled = coalesce(p_reported_settled, false)
         and d.reported_source_id is not distinct from v_src
         and d.reported_by is not distinct from v_by
         and d.document_ref is not distinct from nullif(trim(p_document_ref), '')
         and d.notes is not distinct from nullif(trim(p_notes), '') then
        return d;
      end if;
      raise exception 'Bu kimlikle farklı bir belge var' using errcode = 'unique_violation';
    end if;
    if d.kind <> p_kind then
      raise exception 'Belge türü değiştirilemez' using errcode = 'check_violation';
    end if;
    if d.status <> 'taslak' then
      raise exception 'Yalnızca taslak belge düzenlenir; onaylı belge iptal edilip yeniden oluşturulur'
        using errcode = 'check_violation';
    end if;
    if d.version <> p_expected_version then
      raise exception 'Belge başka biri tarafından değiştirildi; yenileyip tekrar deneyin' using errcode = 'serialization_failure';
    end if;
    -- Eski kapsamda da yazma izni gerekir (başka projeye taşıma).
    if not private.can_fin_doc(d.kind, 'write', d.project_id) then
      raise exception 'Bu belgeyi düzenleme yetkiniz yok' using errcode = 'insufficient_privilege';
    end if;
    if d.is_demo is distinct from v_demo then
      raise exception 'Demo belge gerçek kapsama taşınamaz (veya tersi)' using errcode = 'check_violation';
    end if;
    update public.finance_documents
       set category_id = p_category_id, description = trim(p_description), amount = p_amount,
           document_date = p_document_date, due_date = v_due, project_id = p_project_id,
           cost_center_id = p_cost_center_id, currency = v_cur, exchange_rate = v_rate,
           cari_account_id = p_cari_account_id, invoice_no = nullif(trim(p_invoice_no), ''),
           document_ref = nullif(trim(p_document_ref), ''), notes = nullif(trim(p_notes), ''),
           reported_settled = coalesce(p_reported_settled, false), reported_source_id = v_src, reported_by = v_by
     where id = d.id
    returning * into d;
    perform private.fin_doc_event(d.id, 'guncelle', 'taslak', 'taslak', null,
                                  jsonb_build_object('amount', d.amount, 'currency', d.currency));
    return d;
  end if;

  insert into public.finance_documents (id, kind, document_no, project_id, cost_center_id, category_id, cari_account_id,
                                        description, document_date, due_date, amount, currency, exchange_rate,
                                        invoice_no, document_ref, notes, reported_settled, reported_source_id,
                                        reported_by, is_demo)
  values (p_id, p_kind,
          case p_kind when 'gider' then 'GD-' else 'GL-' end || lpad(nextval('public.finance_document_no_seq')::text, 6, '0'),
          p_project_id, p_cost_center_id, p_category_id, p_cari_account_id, trim(p_description), p_document_date, v_due,
          p_amount, v_cur, v_rate, nullif(trim(p_invoice_no), ''), nullif(trim(p_document_ref), ''),
          nullif(trim(p_notes), ''), coalesce(p_reported_settled, false), v_src, v_by, v_demo)
  returning * into d;
  perform private.fin_doc_event(d.id, 'olustur', null, 'taslak', null,
                                jsonb_build_object('amount', d.amount, 'currency', d.currency,
                                                   'reported_settled', d.reported_settled));
  return d;
end;
$$;

-- -----------------------------------------------------------------------------
-- Ödeme / tahsilat kaydı. Aynı kimlik ancak aynı belge, tutar, kaynak, tarih
-- ve kurla gelirse aynı kaydı döner; aksi halde 23505.
-- -----------------------------------------------------------------------------
create or replace function public.record_finance_settlement(
  p_id uuid, p_document_id uuid, p_amount numeric, p_payment_source_id uuid,
  p_settlement_date date default null, p_settled_by text default null, p_description text default null,
  p_exchange_rate numeric default null)
returns public.finance_settlements
language plpgsql
security definer
set search_path = ''
as $$
declare
  d      public.finance_documents;
  s      public.finance_settlements;
  v_date date := coalesce(p_settlement_date, private.today());
begin
  select * into d from public.finance_documents where id = p_document_id;
  if not found or not private.can_read_fin_doc(d.kind, d.project_id, d.created_by) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.can_fin_doc(d.kind, 'settle', d.project_id) then
    raise exception 'Ödeme/tahsilat kaydetme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  -- Kilit tekrar kontrolünden önce: eşzamanlı iki ödeme sıraya girer.
  select * into d from public.finance_documents where id = p_document_id for update;

  select * into s from public.finance_settlements where id = p_id;
  if found then
    -- İptal edilmiş kaydın kimliğiyle tekrar deneme etkin ödeme gibi dönmez.
    if s.status = 'iptal' then
      raise exception 'Bu kimlikli ödeme/tahsilat iptal edilmiş; yeni kayıt için yeniden deneyin'
        using errcode = 'unique_violation';
    end if;
    if s.document_id = p_document_id and s.amount = p_amount and s.payment_source_id = p_payment_source_id
       and s.settlement_date = coalesce(p_settlement_date, s.settlement_date)
       and s.exchange_rate = private.resolve_exchange_rate(d.currency, p_exchange_rate)
       and s.settled_by is not distinct from nullif(trim(p_settled_by), '')
       and s.description is not distinct from nullif(trim(p_description), '') then
      return s;
    end if;
    raise exception 'Bu kimlikle farklı bir ödeme/tahsilat var (belge, tutar, kaynak, tarih, kur, ödeyen veya açıklama farklı)'
      using errcode = 'unique_violation';
  end if;
  return private.fin_settle(d, p_id, p_amount, p_payment_source_id, v_date, p_settled_by, p_description, p_exchange_rate);
end;
$$;

select private.harden_api_privileges();
