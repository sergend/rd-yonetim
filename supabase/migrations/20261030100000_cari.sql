-- =============================================================================
-- RD Yönetim · Aşama 1 · Cari hesaplar ve cari defter
-- =============================================================================
-- Cari defter yalnızca eklenir: hareketler değiştirilemez ve silinemez,
-- düzeltme ters kayıtla yapılır. Bakiye bir alan değildir; her sorguda
-- hareketlerden hesaplanır. İstemci deftere doğrudan yazamaz; kayıt yalnızca
-- post_cari_entry / reverse_cari_entry fonksiyonlarıyla oluşur.
--
-- Yön (karşı tarafın hesabı açısından, muhasebe düzeni):
--   borç   : karşı taraf bize borçlanır / ona olan borcumuz azalır (ödeme, avans)
--   alacak : karşı tarafın bizden alacağı artar (fatura, hakediş) / tahsilat
--   bakiye = borç − alacak  (> 0: bize borçlu, < 0: biz borçluyuz)

create type public.cari_type as enum ('taseron', 'tedarikci', 'musteri', 'hizmet_saglayici', 'diger');
create type public.cari_direction as enum ('borc', 'alacak');
-- acilis/manuel/avans/odeme/tahsilat elle girilir; ters_kayit iptalde oluşur;
-- hakedis/gider/fatura/kesinti sonraki aşamalarda kaynak belgeden oluşur.
create type public.cari_entry_kind as enum (
  'acilis', 'manuel', 'avans', 'odeme', 'tahsilat',
  'ters_kayit', 'hakedis', 'gider', 'fatura', 'kesinti');

-- -----------------------------------------------------------------------------
-- Cari hesaplar
-- -----------------------------------------------------------------------------
create sequence public.cari_code_seq;

create table public.cari_accounts (
  id               uuid primary key default gen_random_uuid(),
  code             text not null default ('C-' || lpad(nextval('public.cari_code_seq')::text, 5, '0'))
                     check (length(trim(code)) > 0),
  title            text not null check (length(trim(title)) > 0),
  type             public.cari_type not null,
  tax_number       text check (tax_number ~ '^[0-9]{10,11}$'),  -- VKN (10) veya TCKN (11)
  tax_office       text,
  phone            text,
  email            text,
  address          text,
  iban             text check (iban ~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$'),  -- boşluksuz, büyük harf
  default_currency char(3) not null default 'TRY' check (default_currency ~ '^[A-Z]{3}$'),
  notes            text,
  is_active        boolean not null default true,
  deleted_at       timestamptz
);
create unique index cari_accounts_code_active_uq on public.cari_accounts (upper(code)) where deleted_at is null;
create index cari_accounts_title_idx on public.cari_accounts (lower(title)) where deleted_at is null;
select private.add_row_meta('public.cari_accounts');
select audit.enable('public.cari_accounts');

-- -----------------------------------------------------------------------------
-- Cari hareketler (defter)
-- -----------------------------------------------------------------------------
create table public.cari_entries (
  id              uuid primary key,  -- istemcide üretilir: tekrar gönderim çift kayıt açmaz
  cari_account_id uuid not null references public.cari_accounts (id) on delete restrict,
  project_id      uuid references public.projects (id) on delete restrict,
  cost_center_id  uuid references public.cost_centers (id) on delete restrict,
  entry_date      date not null,
  direction       public.cari_direction not null,
  kind            public.cari_entry_kind not null,
  amount          numeric(14, 2) not null check (amount > 0),
  currency        char(3) not null default 'TRY' check (currency ~ '^[A-Z]{3}$'),
  exchange_rate   numeric(18, 6) not null default 1 check (exchange_rate > 0),
  amount_try      numeric(14, 2) generated always as (round(amount * exchange_rate, 2)) stored,
  description     text not null check (length(trim(description)) > 0),
  document_no     text,
  source_type     text,  -- kaynak belge türü (hakedis, gider...); elle girişte boş
  source_id       uuid,
  reversal_of_id  uuid unique references public.cari_entries (id) on delete restrict,
  -- Revizyon 1-R6: hareket ya bir projeye ya bir genel masraf merkezine bağlıdır.
  constraint cari_entries_scope_ck check (num_nonnulls(project_id, cost_center_id) = 1),
  constraint cari_entries_try_rate_ck check (currency <> 'TRY' or exchange_rate = 1),
  constraint cari_entries_source_ck check ((source_type is null) = (source_id is null)),
  constraint cari_entries_reversal_ck check ((kind = 'ters_kayit') = (reversal_of_id is not null)),
  constraint cari_entries_kind_direction_ck check (
    (kind in ('avans', 'odeme') and direction = 'borc')
    or (kind = 'tahsilat' and direction = 'alacak')
    or kind not in ('avans', 'odeme', 'tahsilat'))
);

-- Aynı kaynak belge deftere yalnızca bir kez işlenir (Revizyon 1-R5).
create unique index cari_entries_source_uq
  on public.cari_entries (source_type, source_id)
  where source_id is not null;

select private.add_row_meta('public.cari_entries');
select audit.enable('public.cari_entries');
create index cari_entries_account_idx on public.cari_entries (cari_account_id, entry_date, created_at);
create index cari_entries_project_idx on public.cari_entries (project_id, entry_date) where project_id is not null;
create index cari_entries_cost_center_idx on public.cari_entries (cost_center_id, entry_date) where cost_center_id is not null;


create or replace function private.tg_ledger_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Cari hareketler değiştirilemez veya silinemez; düzeltme için ters kayıt kullanın'
    using errcode = 'insufficient_privilege';
end;
$$;

create trigger ledger_immutable before update or delete on public.cari_entries
  for each row execute function private.tg_ledger_immutable();

-- -----------------------------------------------------------------------------
-- Eşleştirme (kısmi ödeme ve avans mahsubu): bir ödeme/avans/tahsilat
-- hareketinin hangi borç/alacak hareketini ne kadar kapattığı. Toplamlar
-- hareket tutarlarını aşamaz; yönler zıt, cari ve para birimi aynı olmalı.
-- -----------------------------------------------------------------------------
create table public.cari_allocations (
  id               uuid primary key default gen_random_uuid(),
  payment_entry_id uuid not null references public.cari_entries (id) on delete restrict,
  target_entry_id  uuid not null references public.cari_entries (id) on delete restrict,
  amount           numeric(14, 2) not null check (amount > 0),
  note             text,
  deleted_at       timestamptz,
  check (payment_entry_id <> target_entry_id)
);
create unique index cari_allocations_pair_uq
  on public.cari_allocations (payment_entry_id, target_entry_id) where deleted_at is null;
create index cari_allocations_target_idx on public.cari_allocations (target_entry_id) where deleted_at is null;
select private.add_row_meta('public.cari_allocations');
select audit.enable('public.cari_allocations');

create or replace function private.tg_check_allocation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_pay    public.cari_entries;
  v_target public.cari_entries;
  v_used   numeric;
begin
  if new.deleted_at is not null then
    return new;  -- iptal edilen eşleştirme her zaman serbest
  end if;

  -- Aynı hareketlere eşzamanlı eşleştirmeyi sıraya sokmak için satır kilidi.
  select * into v_pay    from public.cari_entries where id = new.payment_entry_id for update;
  select * into v_target from public.cari_entries where id = new.target_entry_id  for update;

  if v_pay.cari_account_id <> v_target.cari_account_id then
    raise exception 'Eşleştirilen hareketler aynı cariye ait olmalı' using errcode = 'check_violation';
  end if;
  if v_pay.currency <> v_target.currency then
    raise exception 'Eşleştirilen hareketlerin para birimi aynı olmalı' using errcode = 'check_violation';
  end if;
  if v_pay.direction = v_target.direction then
    raise exception 'Eşleştirilen hareketlerin yönleri zıt olmalı' using errcode = 'check_violation';
  end if;
  if v_pay.kind = 'ters_kayit' or v_target.kind = 'ters_kayit'
     or exists (select 1 from public.cari_entries r
                 where r.reversal_of_id in (v_pay.id, v_target.id)) then
    raise exception 'İptal edilmiş hareket eşleştirilemez' using errcode = 'check_violation';
  end if;

  select coalesce(sum(a.amount), 0) into v_used
    from public.cari_allocations a
   where a.deleted_at is null and a.id <> new.id
     and new.payment_entry_id in (a.payment_entry_id, a.target_entry_id);
  if v_used + new.amount > v_pay.amount then
    raise exception 'Eşleştirme toplamı ödeme tutarını aşıyor (kalan %)', v_pay.amount - v_used
      using errcode = 'check_violation';
  end if;

  select coalesce(sum(a.amount), 0) into v_used
    from public.cari_allocations a
   where a.deleted_at is null and a.id <> new.id
     and new.target_entry_id in (a.payment_entry_id, a.target_entry_id);
  if v_used + new.amount > v_target.amount then
    raise exception 'Eşleştirme toplamı hareket tutarını aşıyor (kalan %)', v_target.amount - v_used
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger check_allocation before insert or update on public.cari_allocations
  for each row execute function private.tg_check_allocation();

-- -----------------------------------------------------------------------------
-- Yetki yardımcıları
-- -----------------------------------------------------------------------------

-- Cari kartı görebilir mi: genel cari.read izni ya da kartın hareketi olan
-- projelerden birinde proje kapsamlı cari.read izni. Proje kapsamlı kullanıcı
-- kendi projeleriyle ilgisi olmayan carilerin IBAN/vergi/iletişim bilgisini görmez.
create or replace function private.can_read_cari_account(p_cari_account_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_permission('cari.read', null)
      or exists (select 1
                   from public.projects pr
                  where pr.deleted_at is null
                    and exists (select 1 from public.cari_entries e
                                 where e.cari_account_id = p_cari_account_id and e.project_id = pr.id)
                    and private.has_permission('cari.read', pr.id));
$$;

-- Proje hareketi o projedeki izne, genel gider (masraf merkezi) hareketi genel izne bakar.
create or replace function private.has_entry_permission(p_permission text, p_project uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_permission(p_permission, p_project);
$$;

grant execute on function private.can_read_cari_account(uuid) to authenticated;
grant execute on function private.has_entry_permission(text, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.cari_accounts    enable row level security;
alter table public.cari_entries     enable row level security;
alter table public.cari_allocations enable row level security;

create policy cari_accounts_select on public.cari_accounts
  for select to authenticated
  using (private.can_read_cari_account(id));
-- Cari kartlar şirket geneli kayıtlardır: oluşturma ve düzenleme genel izin ister.
create policy cari_accounts_insert on public.cari_accounts
  for insert to authenticated
  with check (private.has_permission('cari.write', null));
create policy cari_accounts_update on public.cari_accounts
  for update to authenticated
  using (private.has_permission('cari.write', null))
  with check (private.has_permission('cari.write', null));

-- Hareketler ve eşleştirmeler yalnızca okunur; yazma RPC'lerle yapılır.
create policy cari_entries_select on public.cari_entries
  for select to authenticated
  using (private.has_entry_permission('cari_hareket.read', project_id));

create policy cari_allocations_select on public.cari_allocations
  for select to authenticated
  using (exists (select 1 from public.cari_entries e where e.id = payment_entry_id)
         and exists (select 1 from public.cari_entries e where e.id = target_entry_id));

-- -----------------------------------------------------------------------------
-- Deftere işleme (elle girilen hareketler)
-- -----------------------------------------------------------------------------
create or replace function public.post_cari_entry(
  p_id              uuid,
  p_cari_account_id uuid,
  p_entry_date      date,
  p_direction       public.cari_direction,
  p_kind            public.cari_entry_kind,
  p_amount          numeric,
  p_description     text,
  p_project_id      uuid    default null,
  p_cost_center_id  uuid    default null,
  p_currency        text    default 'TRY',
  p_exchange_rate   numeric default 1,
  p_document_no     text    default null)
returns public.cari_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.cari_entries;
begin
  if p_kind not in ('acilis', 'manuel', 'avans', 'odeme', 'tahsilat') then
    raise exception 'Bu hareket türü elle girilemez: %', p_kind using errcode = 'invalid_parameter_value';
  end if;

  if not private.has_entry_permission('cari_hareket.write', p_project_id) then
    raise exception 'Cari hareket girme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  if not exists (select 1 from public.cari_accounts c
                  where c.id = p_cari_account_id and c.deleted_at is null and c.is_active) then
    raise exception 'Cari hesap bulunamadı veya pasif' using errcode = 'foreign_key_violation';
  end if;
  if p_project_id is not null
     and not exists (select 1 from public.projects pr where pr.id = p_project_id and pr.deleted_at is null) then
    raise exception 'Proje bulunamadı' using errcode = 'foreign_key_violation';
  end if;
  if p_cost_center_id is not null
     and not exists (select 1 from public.cost_centers cc
                      where cc.id = p_cost_center_id and cc.deleted_at is null and cc.is_active) then
    raise exception 'Masraf merkezi bulunamadı veya pasif' using errcode = 'foreign_key_violation';
  end if;

  -- Aynı kimlikle tekrar gönderim (ağ hatası sonrası yeniden deneme): aynı
  -- içerikse mevcut kaydı döner, farklıysa reddedilir.
  select * into v_row from public.cari_entries e where e.id = p_id;
  if found then
    -- Kayıtta saklanan tüm alanlar, saklandığı biçimde (kırpılmış, büyük harf) karşılaştırılır.
    if v_row.cari_account_id = p_cari_account_id
       and v_row.entry_date = p_entry_date
       and v_row.direction = p_direction
       and v_row.kind = p_kind
       and v_row.amount = p_amount
       and v_row.currency = upper(p_currency)
       and v_row.exchange_rate = p_exchange_rate
       and v_row.description = trim(p_description)
       and v_row.document_no is not distinct from nullif(trim(p_document_no), '')
       and v_row.project_id is not distinct from p_project_id
       and v_row.cost_center_id is not distinct from p_cost_center_id then
      return v_row;
    end if;
    raise exception 'Bu kimlikle farklı bir cari hareket zaten var' using errcode = 'unique_violation';
  end if;

  insert into public.cari_entries (id, cari_account_id, project_id, cost_center_id, entry_date,
                                   direction, kind, amount, currency, exchange_rate,
                                   description, document_no)
  values (p_id, p_cari_account_id, p_project_id, p_cost_center_id, p_entry_date,
          p_direction, p_kind, p_amount, upper(p_currency), p_exchange_rate,
          trim(p_description), nullif(trim(p_document_no), ''))
  returning * into v_row;

  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- İptal (ters kayıt). Orijinal hareket değişmez; aynı tutarda zıt yönlü bir
-- hareket eklenir ve orijinale bağlanır. Bir hareket yalnızca bir kez iptal
-- edilir; ters kayıt yeniden iptal edilemez; hareketin eşleştirmeleri kaldırılır.
-- Kaynak belgeden gelen hareketler (hakediş vb.) kendi modülünden iptal edilir.
-- -----------------------------------------------------------------------------
create or replace function public.reverse_cari_entry(
  p_entry_id    uuid,
  p_reason      text,
  p_reversal_id uuid default gen_random_uuid())
returns public.cari_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_orig public.cari_entries;
  v_row  public.cari_entries;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'İptal gerekçesi zorunlu' using errcode = 'invalid_parameter_value';
  end if;

  select * into v_orig from public.cari_entries e where e.id = p_entry_id for update;
  if not found or not private.has_entry_permission('cari_hareket.read', v_orig.project_id) then
    raise exception 'Cari hareket bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_entry_permission('cari_hareket.reverse', v_orig.project_id) then
    raise exception 'Cari hareket iptal etme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  -- Aynı iptal isteğinin tekrarı: mevcut ters kaydı dön.
  select * into v_row from public.cari_entries e where e.id = p_reversal_id;
  if found then
    if v_row.reversal_of_id = p_entry_id then
      return v_row;
    end if;
    raise exception 'Bu kimlikle farklı bir cari hareket zaten var' using errcode = 'unique_violation';
  end if;

  if v_orig.kind = 'ters_kayit' then
    raise exception 'Ters kayıt yeniden iptal edilemez' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.cari_entries e where e.reversal_of_id = p_entry_id) then
    raise exception 'Bu hareket zaten iptal edilmiş' using errcode = 'check_violation';
  end if;
  if v_orig.source_id is not null then
    raise exception 'Kaynak belgeden gelen hareket, kaynağının modülünden iptal edilir'
      using errcode = 'check_violation';
  end if;

  update public.cari_allocations a
     set deleted_at = now(), note = coalesce(a.note || ' · ', '') || 'Hareket iptal edildi'
   where a.deleted_at is null
     and p_entry_id in (a.payment_entry_id, a.target_entry_id);

  insert into public.cari_entries (id, cari_account_id, project_id, cost_center_id, entry_date,
                                   direction, kind, amount, currency, exchange_rate,
                                   description, document_no, reversal_of_id)
  values (p_reversal_id, v_orig.cari_account_id, v_orig.project_id, v_orig.cost_center_id,
          private.today(),
          case v_orig.direction when 'borc' then 'alacak'::public.cari_direction
                                else 'borc'::public.cari_direction end,
          'ters_kayit', v_orig.amount, v_orig.currency, v_orig.exchange_rate,
          'İptal: ' || trim(p_reason), v_orig.document_no, v_orig.id)
  returning * into v_row;

  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- Eşleştirme RPC'leri
-- -----------------------------------------------------------------------------
create or replace function public.allocate_cari_entry(
  p_payment_entry_id uuid,
  p_target_entry_id  uuid,
  p_amount           numeric,
  p_note             text default null)
returns public.cari_allocations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pay_project    uuid;
  v_target_project uuid;
  v_row            public.cari_allocations;
begin
  select e.project_id into v_pay_project    from public.cari_entries e where e.id = p_payment_entry_id;
  select e.project_id into v_target_project from public.cari_entries e where e.id = p_target_entry_id;
  if not found
     or not private.has_entry_permission('cari_hareket.write', v_pay_project)
     or not private.has_entry_permission('cari_hareket.write', v_target_project) then
    raise exception 'Eşleştirme yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  insert into public.cari_allocations (payment_entry_id, target_entry_id, amount, note)
  values (p_payment_entry_id, p_target_entry_id, p_amount, p_note)
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.cancel_cari_allocation(p_allocation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pay_project    uuid;
  v_target_project uuid;
begin
  select p.project_id, t.project_id into v_pay_project, v_target_project
    from public.cari_allocations a
    join public.cari_entries p on p.id = a.payment_entry_id
    join public.cari_entries t on t.id = a.target_entry_id
   where a.id = p_allocation_id and a.deleted_at is null;
  if not found
     or not private.has_entry_permission('cari_hareket.write', v_pay_project)
     or not private.has_entry_permission('cari_hareket.write', v_target_project) then
    raise exception 'Eşleştirme bulunamadı veya yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  update public.cari_allocations set deleted_at = now() where id = p_allocation_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Okuma fonksiyonları: SECURITY INVOKER, yani yalnızca kullanıcının RLS ile
-- görebildiği hareketler hesaplanır. Proje kapsamlı kullanıcı yalnızca kendi
-- projesindeki bakiyeyi görür.
-- -----------------------------------------------------------------------------

-- Hareketin eşleştirme durumu: açık, kısmi, kapandı veya iptal.
create or replace view public.v_cari_entry_status
with (security_invoker = true)
as
select e.id,
       e.cari_account_id,
       e.amount,
       coalesce(al.allocated, 0)                         as allocated_amount,
       e.amount - coalesce(al.allocated, 0)              as open_amount,
       (r.id is not null)                                as is_reversed,
       case
         when e.kind = 'ters_kayit' or r.id is not null then 'iptal'
         when coalesce(al.allocated, 0) = 0             then 'acik'
         when coalesce(al.allocated, 0) < e.amount      then 'kismi'
         else 'kapandi'
       end                                               as settlement_status
  from public.cari_entries e
  left join public.cari_entries r on r.reversal_of_id = e.id
  left join lateral (
         select sum(a.amount) as allocated
           from public.cari_allocations a
          where a.deleted_at is null
            and e.id in (a.payment_entry_id, a.target_entry_id)) al on true;

-- Cari bazında TL bakiyeler; proje, masraf merkezi ve tarih filtresiyle.
create or replace function public.cari_balances(
  p_project_id     uuid default null,
  p_cost_center_id uuid default null,
  p_until          date default null)
returns table (
  cari_account_id uuid,
  total_borc_try  numeric,
  total_alacak_try numeric,
  balance_try     numeric,
  entry_count     bigint,
  last_entry_date date)
language sql
stable
security invoker
set search_path = ''
as $$
  select e.cari_account_id,
         coalesce(sum(e.amount_try) filter (where e.direction = 'borc'), 0),
         coalesce(sum(e.amount_try) filter (where e.direction = 'alacak'), 0),
         coalesce(sum(e.amount_try) filter (where e.direction = 'borc'), 0)
           - coalesce(sum(e.amount_try) filter (where e.direction = 'alacak'), 0),
         count(*),
         max(e.entry_date)
    from public.cari_entries e
   where (p_project_id is null or e.project_id = p_project_id)
     and (p_cost_center_id is null or e.cost_center_id = p_cost_center_id)
     and (p_until is null or e.entry_date <= p_until)
   group by e.cari_account_id;
$$;

-- Cari ekstresi: devir (p_from öncesi) bakiyesiyle birlikte yürüyen bakiye;
-- proje veya genel gider merkezine göre süzülebilir.
create or replace function public.cari_statement(
  p_cari_account_id uuid,
  p_project_id      uuid default null,
  p_from            date default null,
  p_to              date default null,
  p_cost_center_id  uuid default null)
returns table (
  id                  uuid,
  entry_date          date,
  kind                public.cari_entry_kind,
  direction           public.cari_direction,
  description         text,
  document_no         text,
  project_id          uuid,
  cost_center_id      uuid,
  amount              numeric,
  currency            char(3),
  amount_try          numeric,
  borc_try            numeric,
  alacak_try          numeric,
  running_balance_try numeric,
  reversal_of_id      uuid,
  is_reversed         boolean,
  created_at          timestamptz)
language sql
stable
security invoker
set search_path = ''
as $$
  with scoped as (
    select e.*,
           case when e.direction = 'borc' then e.amount_try else -e.amount_try end as signed_try
      from public.cari_entries e
     where e.cari_account_id = p_cari_account_id
       and (p_project_id is null or e.project_id = p_project_id)
       and (p_cost_center_id is null or e.cost_center_id = p_cost_center_id)
       and (p_to is null or e.entry_date <= p_to)
  ),
  running as (
    select s.*,
           sum(s.signed_try) over (order by s.entry_date, s.created_at, s.id
                                   rows between unbounded preceding and current row) as running_try
      from scoped s
  )
  select r.id, r.entry_date, r.kind, r.direction, r.description, r.document_no,
         r.project_id, r.cost_center_id, r.amount, r.currency, r.amount_try,
         case when r.direction = 'borc'   then r.amount_try else 0 end,
         case when r.direction = 'alacak' then r.amount_try else 0 end,
         r.running_try,
         r.reversal_of_id,
         exists (select 1 from public.cari_entries x where x.reversal_of_id = r.id),
         r.created_at
    from running r
   where p_from is null or r.entry_date >= p_from
   order by r.entry_date, r.created_at, r.id;
$$;

-- -----------------------------------------------------------------------------
-- API ayrıcalıkları: Aşama 0 kısıtlarına cari defter eklenir.
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
end;
$$;

grant execute on function public.post_cari_entry(uuid, uuid, date, public.cari_direction, public.cari_entry_kind,
                                                 numeric, text, uuid, uuid, text, numeric, text) to authenticated;
grant execute on function public.reverse_cari_entry(uuid, text, uuid) to authenticated;
grant execute on function public.allocate_cari_entry(uuid, uuid, numeric, text) to authenticated;
grant execute on function public.cancel_cari_allocation(uuid) to authenticated;
grant execute on function public.cari_balances(uuid, uuid, date) to authenticated;
grant execute on function public.cari_statement(uuid, uuid, date, date, uuid) to authenticated;
grant select on public.v_cari_entry_status to authenticated;

-- -----------------------------------------------------------------------------
-- İzinler ve rol şablonları
-- -----------------------------------------------------------------------------
insert into public.permissions (key, module, description) values
  ('cari.read',             'cari', 'Cari hesap kartlarını görüntüleme'),
  ('cari.write',            'cari', 'Cari hesap oluşturma ve düzenleme'),
  ('cari_hareket.read',     'cari', 'Cari hareketleri ve bakiyeleri görüntüleme'),
  ('cari_hareket.write',    'cari', 'Cari hareket girme ve eşleştirme'),
  ('cari_hareket.reverse',  'cari', 'Cari hareketi ters kayıtla iptal etme');

insert into public.role_permissions (role_id, permission_key)
select r.id, x.permission_key
  from (values
          ('muhasebe', 'cari.read'),
          ('muhasebe', 'cari.write'),
          ('muhasebe', 'cari_hareket.read'),
          ('muhasebe', 'cari_hareket.write'),
          ('muhasebe', 'cari_hareket.reverse')
       ) as x (role_key, permission_key)
  join public.roles r on r.key = x.role_key;

select private.harden_api_privileges();
