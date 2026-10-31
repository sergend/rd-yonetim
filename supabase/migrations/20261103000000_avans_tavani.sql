-- =============================================================================
-- PR #6 ikinci inceleme: avans tavanı. 20261101000000 ve 20261102000000
-- değiştirilmez.
--
-- Avansın tavanı onaylı revizyondaki sözleşme bedelidir (total_amount).
-- Bedel isteğe bağlı olduğundan, bedeli tanımlı olmayan sözleşmede tavan
-- türetilmez (miktar × fiyat gibi bir varsayım yapılmaz): avans açık bir
-- hatayla reddedilir. Etkin (iptal edilmemiş) avansların toplamı + yeni avans
-- bedeli aşamaz; bedele tam eşit avans kabul edilir. Fonksiyon imzası aynıdır.
-- =============================================================================

create or replace function public.record_finance_payment(
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
    -- Tavan yalnızca onaylı revizyonda açıkça girilmiş sözleşme bedelidir;
    -- bedel tanımlı değilse tavan türetilmez, avans verilmez.
    if v_limit is null then
      raise exception 'Sözleşme bedeli tanımlı olmayan sözleşmeye avans verilemez; önce bedeli içeren bir revizyon onaylayın'
        using errcode = 'check_violation';
    end if;
    if p_amount + coalesce((select sum(x.amount) from public.finance_payments x
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
