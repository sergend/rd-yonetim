-- =============================================================================
-- Aşama 4 düzeltmeleri (PR #6 incelemesi). 20261101000000 değiştirilmez.
--
-- 1) Hedefsiz normal ödeme: `odeme` türü her zaman tek bir yükümlülüğe
--    (deftere işlenmiş hakediş veya etkin teminat iadesi) bağlanır ve kalan
--    tutarı aşamaz. Hedefsiz ödeme yalnızca açıkça `avans` olarak, aktif
--    sözleşmeye ve sözleşme bedeliyle sınırlı kaydedilir.
-- 2) Döviz: TRY dışı sözleşmede deftere işleme, teminat iadesi ve ödeme için
--    kur zorunludur (> 0, en çok 6 ondalık); kur tahmin edilmez, varsayılan
--    yoktur. TRY'de kur yalnızca 1 olabilir. amount_try cari tabloda
--    amount × exchange_rate olarak üretilir.
-- 3) Ödeme tekrar gönderimi: aynı kimlik ancak aynı sözleşme, tür, tutar,
--    hedef, ödeme kaynağı, ödeme tarihi ve kurla gelirse aynı kayıt döner;
--    aksi halde açık uyuşmazlık hatası (23505). Teminat iadesinde de tarih ve
--    kur karşılaştırılır.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tablo kuralı: normal ödeme tam olarak bir hedefe bağlıdır.
-- -----------------------------------------------------------------------------
alter table public.finance_payments
  add constraint finance_payments_odeme_target_ck
  check (kind <> 'odeme' or num_nonnulls(hakedis_id, teminat_release_id) = 1);

-- -----------------------------------------------------------------------------
-- Kur kuralı (tek yerde). Kur değeri istemciden açıkça gelir; burada tahmin
-- edilmez ve sabitlenmez.
-- -----------------------------------------------------------------------------
create or replace function private.resolve_exchange_rate(p_currency text, p_rate numeric)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_currency = 'TRY' then
    if p_rate is not null and p_rate <> 1 then
      raise exception 'TL işlemde kur 1 olmalı' using errcode = 'check_violation';
    end if;
    return 1;
  end if;
  if p_rate is null or p_rate <= 0 then
    raise exception '% para birimli işlemde kur zorunludur ve sıfırdan büyük olmalı', p_currency
      using errcode = 'check_violation';
  end if;
  if p_rate <> round(p_rate, 6) then
    raise exception 'Kur en çok 6 ondalıklı olmalı' using errcode = 'check_violation';
  end if;
  return p_rate;
end;
$$;
revoke execute on function private.resolve_exchange_rate(text, numeric) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Deftere işleme: varsayılan kur 1 kaldırıldı (TRY dışında zorunlu).
-- -----------------------------------------------------------------------------
drop function public.post_hakedis(uuid, date, numeric);

create function public.post_hakedis(p_hakedis_id uuid, p_entry_date date default null,
                                    p_exchange_rate numeric default null)
returns public.hakedis
language plpgsql
security definer
set search_path = ''
as $$
declare
  h        public.hakedis;
  c        public.contracts;
  v_entry  uuid;
  v_adj    record;
  v_av     record;
  v_need   numeric;
  v_take   numeric;
  v_rate   numeric;
  v_date   date := coalesce(p_entry_date, private.today());
  v_doc    text;
begin
  select * into h from public.hakedis where id = p_hakedis_id;
  if not found or not private.has_permission('hakedis.read', h.project_id) then
    raise exception 'Hakediş bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('hakedis.post', h.project_id) then
    raise exception 'Hakedişi cari deftere işleme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  perform 1 from public.contracts where id = h.contract_id for update;
  select * into h from public.hakedis where id = p_hakedis_id for update;
  if h.posted_at is not null then
    return h;  -- tekrar gönderim ikinci hareket oluşturmaz
  end if;
  if h.status <> 'onaylandi' then
    raise exception 'Yalnızca onaylı hakediş deftere işlenir' using errcode = 'check_violation';
  end if;
  select * into c from public.contracts where id = h.contract_id;
  v_rate := private.resolve_exchange_rate(c.currency, p_exchange_rate);
  v_doc := c.contract_no || '/' || h.hakedis_no;

  v_entry := gen_random_uuid();
  insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind, amount, currency,
                                   exchange_rate, description, document_no, source_type, source_id)
  values (v_entry, h.cari_account_id, h.project_id, v_date, 'alacak', 'hakedis', h.gross_amount + h.kdv_amount,
          c.currency, v_rate,
          format('Hakediş %s · %s', h.hakedis_no, c.title), v_doc, 'hakedis', h.id);

  for v_adj in select * from public.hakedis_adjustments
                where hakedis_id = h.id and kind in ('stopaj', 'teminat', 'diger_kesinti') and amount > 0
                order by kind, tax_code loop
    insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind, amount, currency,
                                     exchange_rate, description, document_no, source_type, source_id)
    values (gen_random_uuid(), h.cari_account_id, h.project_id, v_date, 'borc', 'kesinti', v_adj.amount, c.currency,
            v_rate, format('Hakediş %s · %s', h.hakedis_no, v_adj.description), v_doc,
            'hakedis_kesinti', v_adj.id)
    returning id into v_adj.cari_entry_id;
    update public.hakedis_adjustments set cari_entry_id = v_adj.cari_entry_id where id = v_adj.id;
    insert into public.cari_allocations (payment_entry_id, target_entry_id, amount, note)
    values (v_adj.cari_entry_id, v_entry, v_adj.amount, 'Hakediş kesintisi');
  end loop;

  -- Avans mahsubu: açık avanslardan eskiden yeniye.
  v_need := h.advance_amount;
  if v_need > 0 then
    for v_av in select e.id, e.amount - coalesce((select sum(a.amount) from public.cari_allocations a
                                                  where a.deleted_at is null and e.id in (a.payment_entry_id, a.target_entry_id)), 0) as open
                  from public.cari_entries e
                 where e.cari_account_id = h.cari_account_id and e.project_id = h.project_id and e.kind = 'avans'
                   and e.currency = c.currency
                   and not exists (select 1 from public.cari_entries r where r.reversal_of_id = e.id)
                 order by e.entry_date, e.created_at
                 for update of e loop
      exit when v_need <= 0;
      continue when v_av.open <= 0;
      v_take := least(v_av.open, v_need);
      insert into public.cari_allocations (payment_entry_id, target_entry_id, amount, note)
      values (v_av.id, v_entry, v_take, format('Hakediş %s avans mahsubu', h.hakedis_no));
      v_need := v_need - v_take;
    end loop;
    if v_need > 0 then
      raise exception 'Mahsup edilecek açık avans yetersiz (eksik %)', v_need using errcode = 'check_violation';
    end if;
  end if;

  update public.hakedis set posted_at = now(), posted_by = auth.uid(), cari_entry_id = v_entry
   where id = h.id returning * into h;
  perform private.fin_event('hakedis', h.id, h.contract_id, h.project_id, 'deftere_isle', 'onaylandi', 'onaylandi', null,
                            jsonb_build_object('cari_entry_id', v_entry, 'entry_date', v_date,
                                               'currency', c.currency, 'exchange_rate', v_rate));
  return h;
end;
$$;

-- -----------------------------------------------------------------------------
-- Teminat serbest bırakma: kur iletilir; tekrar gönderimde tarih ve kur da
-- karşılaştırılır.
-- -----------------------------------------------------------------------------
drop function public.release_teminat(uuid, uuid, numeric, text, date);

create function public.release_teminat(
  p_id uuid, p_contract_id uuid, p_amount numeric, p_reason text, p_release_date date default null,
  p_exchange_rate numeric default null)
returns public.teminat_releases
language plpgsql
security definer
set search_path = ''
as $$
declare
  c       public.contracts;
  r       public.teminat_releases;
  v_avail numeric;
  v_entry uuid;
  v_rate  numeric;
  v_old_rate numeric;
begin
  select * into c from public.contracts where id = p_contract_id;
  if not found or not private.has_permission('teminat.release', c.project_id) then
    raise exception 'Teminat serbest bırakma yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  perform 1 from public.contracts where id = c.id for update;
  v_rate := private.resolve_exchange_rate(c.currency, p_exchange_rate);
  select * into r from public.teminat_releases where id = p_id;
  if found then
    select e.exchange_rate into v_old_rate from public.cari_entries e where e.id = r.cari_entry_id;
    if r.contract_id = p_contract_id and r.amount = p_amount
       and r.release_date = coalesce(p_release_date, r.release_date)
       and v_old_rate = v_rate then
      return r;  -- tekrar
    end if;
    raise exception 'Bu kimlikle farklı bir serbest bırakma var (sözleşme, tutar, tarih veya kur farklı)'
      using errcode = 'unique_violation';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Tutar pozitif ve en çok iki ondalıklı olmalı' using errcode = 'check_violation';
  end if;
  if length(coalesce(trim(p_reason), '')) < 10 then
    raise exception 'Serbest bırakma gerekçesi en az 10 karakter olmalı' using errcode = 'check_violation';
  end if;
  v_avail := private.contract_retention_balance(c.id);
  if p_amount > v_avail then
    raise exception 'Serbest bırakılabilir teminat %; istenen % ', v_avail, p_amount using errcode = 'check_violation';
  end if;
  v_entry := gen_random_uuid();
  insert into public.teminat_releases (id, contract_id, project_id, cari_account_id, amount, release_date, reason, is_demo)
  values (p_id, c.id, c.project_id, c.cari_account_id, p_amount, coalesce(p_release_date, private.today()), trim(p_reason), c.is_demo)
  returning * into r;
  insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind, amount, currency,
                                   exchange_rate, description, document_no, source_type, source_id)
  values (v_entry, c.cari_account_id, c.project_id, r.release_date, 'alacak', 'teminat_iadesi', p_amount, c.currency,
          v_rate, 'Teminat serbest bırakma · ' || c.title, c.contract_no, 'teminat_iade', r.id);
  update public.teminat_releases set cari_entry_id = v_entry where id = r.id returning * into r;
  perform private.fin_event('teminat', r.id, c.id, c.project_id, 'serbest_birak', null, 'aktif', p_reason,
                            jsonb_build_object('amount', p_amount, 'balance_before', v_avail,
                                               'currency', c.currency, 'exchange_rate', v_rate));
  return r;
end;
$$;

-- -----------------------------------------------------------------------------
-- Ödeme ve avans.
--   odeme: tam olarak bir hedef (deftere işlenmiş hakediş veya etkin teminat
--          iadesi); hedefin kalan tutarını aşamaz.
--   avans: hedefsiz; yalnızca aktif sözleşmeye; sözleşme bedeli biliniyorsa
--          etkin avansların toplamı bedeli aşamaz. Hakedişte mahsup edilir.
-- Ödeme kaynağı yalnızca etikettir; yükümlülükten ayrıdır.
-- -----------------------------------------------------------------------------
drop function public.record_finance_payment(uuid, uuid, text, numeric, uuid, date, uuid, uuid, text);

create function public.record_finance_payment(
  p_id uuid, p_contract_id uuid, p_kind text, p_amount numeric, p_payment_source_id uuid,
  p_payment_date date default null, p_hakedis_id uuid default null, p_teminat_release_id uuid default null,
  p_description text default null, p_exchange_rate numeric default null)
returns public.finance_payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  c          public.contracts;
  p          public.finance_payments;
  h          public.hakedis;
  r          public.teminat_releases;
  v_target   uuid;
  v_rate     numeric;
  v_old_rate numeric;
  v_open     numeric;
  v_limit    numeric;
  v_date     date := coalesce(p_payment_date, private.today());
begin
  select * into c from public.contracts where id = p_contract_id;
  if not found or not private.has_permission('odeme.write', c.project_id) then
    raise exception 'Ödeme kaydetme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  -- Kilit, tekrar gönderim kontrolünden önce alınır: aynı kimlikle eşzamanlı
  -- iki gönderimden ikincisi birincinin bitmesini bekler ve aynı kaydı döner.
  perform 1 from public.contracts where id = c.id for update;
  v_rate := private.resolve_exchange_rate(c.currency, p_exchange_rate);

  select * into p from public.finance_payments where id = p_id;
  if found then
    select e.exchange_rate into v_old_rate from public.cari_entries e where e.id = p.cari_entry_id;
    if p.contract_id = p_contract_id and p.amount = p_amount and p.kind = p_kind
       and p.hakedis_id is not distinct from p_hakedis_id
       and p.teminat_release_id is not distinct from p_teminat_release_id
       and p.payment_source_id = p_payment_source_id
       and p.payment_date = coalesce(p_payment_date, p.payment_date)
       and v_old_rate = v_rate then
      return p;  -- tekrar gönderim
    end if;
    raise exception 'Bu kimlikle farklı bir ödeme var (sözleşme, tür, tutar, hedef, ödeme kaynağı, tarih veya kur farklı)'
      using errcode = 'unique_violation';
  end if;

  if p_kind is null or p_kind not in ('odeme', 'avans') then
    raise exception 'Ödeme türü odeme veya avans olmalı' using errcode = 'check_violation';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Tutar pozitif ve en çok iki ondalıklı olmalı' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.payment_sources s where s.id = p_payment_source_id and s.is_active) then
    raise exception 'Ödeme kaynağı bulunamadı veya pasif' using errcode = 'foreign_key_violation';
  end if;

  if p_kind = 'odeme' then
    if num_nonnulls(p_hakedis_id, p_teminat_release_id) <> 1 then
      raise exception 'Ödeme tek bir hakedişe veya teminat iadesine bağlanmalı; hedefsiz ödeme kaydedilemez (avans ayrı kaydedilir)'
        using errcode = 'check_violation';
    end if;
    if p_hakedis_id is not null then
      select * into h from public.hakedis where id = p_hakedis_id and contract_id = c.id for update;
      if not found or h.status <> 'onaylandi' or h.posted_at is null then
        raise exception 'Ödeme yalnızca onaylanıp deftere işlenmiş hakedişe eşleştirilir' using errcode = 'check_violation';
      end if;
      v_target := h.cari_entry_id;
      v_open := h.payable_amount - coalesce((select sum(x.amount) from public.finance_payments x
                                              where x.hakedis_id = h.id and x.status = 'aktif'), 0);
    else
      select * into r from public.teminat_releases where id = p_teminat_release_id and contract_id = c.id for update;
      if not found or r.status <> 'aktif' then
        raise exception 'Teminat iadesi bulunamadı veya iptal edilmiş' using errcode = 'check_violation';
      end if;
      v_target := r.cari_entry_id;
      v_open := r.amount - coalesce((select sum(x.amount) from public.finance_payments x
                                      where x.teminat_release_id = r.id and x.status = 'aktif'), 0);
    end if;
    if p_amount > v_open then
      raise exception 'Ödeme kalan tutarı aşıyor (kalan %)', v_open using errcode = 'check_violation';
    end if;
  else
    if num_nonnulls(p_hakedis_id, p_teminat_release_id) <> 0 then
      raise exception 'Avans bir hakedişe veya teminat iadesine bağlanmaz' using errcode = 'check_violation';
    end if;
    if c.status <> 'aktif' then
      raise exception 'Avans yalnızca aktif sözleşmeye verilir' using errcode = 'check_violation';
    end if;
    select v.total_amount into v_limit from public.contract_versions v
     where v.contract_id = c.id and v.status = 'onaylandi';
    if v_limit is not null and p_amount + coalesce((select sum(x.amount) from public.finance_payments x
                                                     where x.contract_id = c.id and x.kind = 'avans'
                                                       and x.status = 'aktif'), 0) > v_limit then
      raise exception 'Toplam avans sözleşme bedelini (%) aşamaz', v_limit using errcode = 'check_violation';
    end if;
  end if;

  insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind, amount, currency,
                                   exchange_rate, description, document_no, source_type, source_id)
  values (p_id, c.cari_account_id, c.project_id, v_date, 'borc', p_kind::public.cari_entry_kind, p_amount, c.currency,
          v_rate,
          coalesce(nullif(trim(p_description), ''),
                   case p_kind when 'avans' then 'Avans · ' else 'Ödeme · ' end || c.title),
          c.contract_no, 'finans_odeme', p_id);
  insert into public.finance_payments (id, contract_id, project_id, cari_account_id, kind, amount, payment_date,
                                       payment_source_id, hakedis_id, teminat_release_id, cari_entry_id, description, is_demo)
  values (p_id, c.id, c.project_id, c.cari_account_id, p_kind, p_amount, v_date, p_payment_source_id, p_hakedis_id,
          p_teminat_release_id, p_id, nullif(trim(p_description), ''), c.is_demo)
  returning * into p;
  if v_target is not null then
    insert into public.cari_allocations (payment_entry_id, target_entry_id, amount, note)
    values (p_id, v_target, p_amount, 'Ödeme');
  end if;
  perform private.fin_event('odeme', p.id, c.id, c.project_id, 'kaydet', null, 'aktif', null,
                            jsonb_build_object('kind', p_kind, 'amount', p_amount, 'hakedis_id', p_hakedis_id,
                                               'teminat_release_id', p_teminat_release_id,
                                               'payment_source_id', p_payment_source_id, 'payment_date', v_date,
                                               'currency', c.currency, 'exchange_rate', v_rate));
  return p;
end;
$$;

-- -----------------------------------------------------------------------------
-- Özet: gerçekleşen ödeme yalnızca bir yükümlülüğe bağlı ödemelerdir
-- (tablo kuralıyla zaten öyle; burada açıkça yazılır). Tutarlar sözleşme
-- para birimindedir; TL karşılığı cari hareketlerde (amount_try) tutulur.
-- -----------------------------------------------------------------------------
create or replace function public.contract_finance_summary(p_contract_id uuid)
returns table (
  contract_id             uuid,
  contract_amount         numeric,
  gross_total             numeric,
  kdv_total               numeric,
  tax_deduction_total     numeric,
  other_deduction_total   numeric,
  advance_deducted_total  numeric,
  retention_withheld      numeric,
  retention_released      numeric,
  retention_balance       numeric,
  payable_total           numeric,
  unposted_payable        numeric,
  paid_total              numeric,
  advance_paid_total      numeric,
  remaining_total         numeric,
  hakedis_count           integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.contracts;
begin
  select * into c from public.contracts where id = p_contract_id;
  if not found or not private.has_permission('hakedis.read', c.project_id) then
    raise exception 'Sözleşme finans özetini görme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  return query
  with hk as (select * from public.hakedis h where h.contract_id = c.id and h.status = 'onaylandi'),
       pay as (select * from public.finance_payments p where p.contract_id = c.id and p.status = 'aktif'),
       paid as (select * from pay where kind = 'odeme'
                  and (hakedis_id is not null or teminat_release_id is not null)),
       rel as (select * from public.teminat_releases r where r.contract_id = c.id and r.status = 'aktif')
  select c.id,
         (select v.total_amount from public.contract_versions v where v.contract_id = c.id and v.status = 'onaylandi'),
         coalesce((select sum(gross_amount) from hk), 0),
         coalesce((select sum(kdv_amount) from hk), 0),
         coalesce((select sum(tax_deduction_amount) from hk), 0),
         coalesce((select sum(other_deduction_amount) from hk), 0),
         coalesce((select sum(advance_amount) from hk), 0),
         coalesce((select sum(retention_amount) from hk), 0),
         coalesce((select sum(amount) from rel), 0),
         coalesce((select sum(retention_amount) from hk), 0) - coalesce((select sum(amount) from rel), 0),
         coalesce((select sum(payable_amount) from hk), 0),
         coalesce((select sum(payable_amount) from hk where posted_at is null), 0),
         coalesce((select sum(amount) from paid), 0),
         coalesce((select sum(amount) from pay where kind = 'avans'), 0),
         coalesce((select sum(payable_amount) from hk), 0) + coalesce((select sum(amount) from rel), 0)
           - coalesce((select sum(amount) from paid), 0),
         (select count(*)::integer from hk);
end;
$$;

-- -----------------------------------------------------------------------------
-- API ayrıcalıkları (yeniden oluşturulan fonksiyonlar PUBLIC'e açık doğar).
-- -----------------------------------------------------------------------------
select private.harden_api_privileges();
grant execute on function public.post_hakedis(uuid, date, numeric) to authenticated;
grant execute on function public.release_teminat(uuid, uuid, numeric, text, date, numeric) to authenticated;
grant execute on function public.record_finance_payment(uuid, uuid, text, numeric, uuid, date, uuid, uuid, text, numeric)
  to authenticated;
