-- =============================================================================
-- RD Yönetim · Aşama 7 düzeltmesi · Satın alma bağlantılarının bütünlüğü
-- =============================================================================
-- PR #9 incelemesi. Eski migration'lar değişmez; bu dosya yalnızca ekler ve
-- iki fonksiyonu yeniden tanımlar.
--
-- 1) Bağlantı kapsamı yalnızca bağlama anında değil, sonrasında da korunur.
--    a) Siparişe bağlı gider kaydı (taslakken bile) başka projeye, masraf
--       merkezine, DEMO kapsamına veya başka bir tedarikçiye taşınamaz; önce
--       sipariş bağlantısı kaldırılır. Carisi boşaltmak veya aynı tedarikçiyi
--       seçmek ve kapsamı bozmayan diğer düzenlemeler serbesttir.
--    b) Bağlı gider iptal edilirse bağlantı aynı işlemde, gerekçesi ve sipariş
--       geçmişi kaydıyla sona erer. Düzeltmede (revise_finance_document) eski
--       giderin bağlantısı sona erer ve aynı siparişe yeni taslak için bağlantı
--       açılır (yeni taslak eskisinin kapsamını kopyalar).
--    c) Siparişe, teslime veya stok hareketine bağlı arşiv belgesi başka bir
--       projeye / masraf merkezine taşınamaz (relink_document); önce bağlantı
--       kaldırılır. Aynı proje içinde bağlantı türü değişikliği serbesttir.
--    d) Bağlı belge iptal edilirse sipariş belge bağlantısı sona erer; yeni
--       dosyayla değiştirilirse bağlantı yeni belgeye taşınır (aynı kayıt).
--    e) Gider bağlı onaylı sipariş iptal edilemez; önce bağlantı kaldırılır.
--    Bu tetikleyiciler finans kaydına yazmaz; yalnızca reddeder veya sipariş
--    bağlantı tablolarını günceller (audit ve sipariş geçmişi ile).
--
-- 2) Tekrar gönderim karşılaştırması
--    * receive_purchase_order: teslim alan kişi (stock_movements.performed_by)
--      ve teslimin tüm stok hareketleri karşılaştırılır.
--    * link_purchase_order_expense: not karşılaştırılır.
--    Aynı niyet → aynı kayıt; farklı niyet → 23505.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1a/1b) Finans belgesi: bağlı giderin kapsam koruması ve iptalde bağlantı sonu
-- -----------------------------------------------------------------------------
create or replace function private.tg_finance_document_purchase_link_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  k record;
begin
  for k in select x.id, o.order_no, o.project_id, o.cari_account_id, o.is_demo
             from public.purchase_order_expense_links x
             join public.purchase_orders o on o.id = x.order_id
            where x.finance_document_id = old.id and x.status = 'aktif'
              for update of x loop
    if new.kind is distinct from old.kind
       or new.project_id is distinct from k.project_id
       or new.cost_center_id is not null
       or new.is_demo is distinct from k.is_demo
       or (new.cari_account_id is not null and new.cari_account_id is distinct from k.cari_account_id) then
      raise exception 'Bu gider % numaralı satın alma siparişine bağlı; projesi, DEMO işareti veya tedarikçisi değiştirilemez. Önce sipariş bağlantısını kaldırın', k.order_no
        using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$$;
revoke execute on function private.tg_finance_document_purchase_link_guard() from public, anon, authenticated;
create trigger finance_document_purchase_link_guard
  before update of kind, project_id, cost_center_id, cari_account_id, is_demo on public.finance_documents
  for each row execute function private.tg_finance_document_purchase_link_guard();

-- Gider iptal edildi (doğrudan veya düzeltme ile): etkin bağlantı sona erer.
create or replace function private.tg_finance_document_purchase_link_end()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  k public.purchase_order_expense_links;
begin
  for k in select * from public.purchase_order_expense_links
            where finance_document_id = new.id and status = 'aktif' for update loop
    update public.purchase_order_expense_links
       set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(),
           cancel_reason = 'Gider kaydı iptal edildi: ' || coalesce(new.cancel_reason, '')
     where id = k.id;
    perform private.purchase_event(k.order_id, 'gider_bag_kaldir', null, null,
                                   'Gider kaydı iptal edildi: ' || coalesce(new.cancel_reason, ''),
                                   jsonb_build_object('finance_document_id', new.id, 'document_no', new.document_no,
                                                      'otomatik', true));
  end loop;
  return null;
end;
$$;
revoke execute on function private.tg_finance_document_purchase_link_end() from public, anon, authenticated;
create trigger finance_document_purchase_link_end
  after update of status on public.finance_documents
  for each row when (old.status is distinct from 'iptal' and new.status = 'iptal')
  execute function private.tg_finance_document_purchase_link_end();

-- Düzeltme: revise_finance_document eski gideri iptal eder ve aynı işlemde
-- replaces_id ile yeni taslak açar. Aynı işlemde sona eren bağlantı yeni
-- taslağa taşınır. Yeni taslak eskisinin proje, cari ve DEMO bilgisini taşır.
create or replace function private.tg_finance_document_purchase_link_follow()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  k public.purchase_order_expense_links;
  o public.purchase_orders;
begin
  select * into k from public.purchase_order_expense_links
   where finance_document_id = new.replaces_id and status = 'iptal'
     and cancelled_at = now() and cancel_reason like 'Gider kaydı iptal edildi: %'
   order by updated_at desc
   limit 1;
  if not found then
    return null;
  end if;
  select * into o from public.purchase_orders where id = k.order_id for update;
  if o.status = 'iptal' or new.kind <> 'gider' or new.project_id is distinct from o.project_id
     or new.is_demo is distinct from o.is_demo
     or (new.cari_account_id is not null and new.cari_account_id <> o.cari_account_id)
     or exists (select 1 from public.purchase_order_expense_links x
                 where x.finance_document_id = new.id and x.status = 'aktif') then
    return null;
  end if;
  insert into public.purchase_order_expense_links (id, order_id, finance_document_id, note)
  values (gen_random_uuid(), o.id, new.id, k.note);
  perform private.purchase_event(o.id, 'gider_bagla', null, null, 'Gider kaydı düzeltildi',
                                 jsonb_build_object('finance_document_id', new.id, 'document_no', new.document_no,
                                                    'replaces_id', new.replaces_id, 'otomatik', true));
  return null;
end;
$$;
revoke execute on function private.tg_finance_document_purchase_link_follow() from public, anon, authenticated;
create trigger finance_document_purchase_link_follow
  after insert on public.finance_documents
  for each row when (new.replaces_id is not null)
  execute function private.tg_finance_document_purchase_link_follow();

-- -----------------------------------------------------------------------------
-- 1c/1d) Arşiv belgesi: bağlı belgenin kapsam koruması, iptal ve değiştirme
-- -----------------------------------------------------------------------------
create or replace function private.tg_document_stock_link_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ref text;
begin
  if new.project_id is not distinct from old.project_id
     and new.cost_center_id is not distinct from old.cost_center_id
     and new.is_demo is not distinct from old.is_demo then
    return new;
  end if;
  -- Bağlı kayıtların kapsamı: sipariş ve teslim için siparişin projesi,
  -- hareket için deponun projesi (genel depoda boş).
  select coalesce(
           (select 'sipariş ' || o.order_no
              from public.purchase_order_documents x
              join public.purchase_orders o on o.id = x.order_id
             where x.document_id = old.id and x.status = 'aktif'
               and (new.project_id is distinct from o.project_id or new.is_demo is distinct from o.is_demo)
             limit 1),
           (select 'teslim ' || r.receipt_no
              from public.purchase_receipts r
              join public.purchase_orders o on o.id = r.order_id
             where r.document_id = old.id and r.status = 'aktif'
               and (new.project_id is distinct from o.project_id or new.is_demo is distinct from o.is_demo)
             limit 1),
           (select 'stok hareketi ' || m.movement_no
              from public.stock_movements m
              join public.warehouses w on w.id = m.warehouse_id
             where m.document_id = old.id and m.status in ('bekliyor', 'onaylandi')
               and (new.project_id is distinct from w.project_id or new.is_demo is distinct from w.is_demo)
             limit 1))
    into v_ref;
  if v_ref is not null then
    raise exception 'Bu belge % kaydına bağlı; başka projeye veya kapsama taşınamaz. Önce bağlantıyı kaldırın', v_ref
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
revoke execute on function private.tg_document_stock_link_guard() from public, anon, authenticated;
create trigger document_stock_link_guard
  before update of project_id, cost_center_id, is_demo on public.documents
  for each row execute function private.tg_document_stock_link_guard();

-- Belge iptal edildi: sipariş belge bağlantısı sona erer. Yeni dosyayla
-- değiştirmede (complete_document_upload eski belgeyi iptal eder) bağlantı
-- aynı kayda yüklenen yeni belgeye taşınır. Teslim ve hareketlerdeki belge
-- referansı geçmiş olarak kalır (iptal edilmiş belge arşivde görünür).
create or replace function private.tg_document_stock_link_end()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  k   public.purchase_order_documents;
  o   public.purchase_orders;
  rep public.documents;
begin
  select * into rep from public.documents x
   where x.replaces_id = new.id and x.status = 'bekliyor'
     and new.cancel_reason = 'Yeni dosyayla değiştirildi';
  for k in select * from public.purchase_order_documents
            where document_id = new.id and status = 'aktif' for update loop
    update public.purchase_order_documents
       set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(),
           cancel_reason = 'Belge iptal edildi: ' || coalesce(new.cancel_reason, '')
     where id = k.id;
    perform private.purchase_event(k.order_id, 'belge_bag_kaldir', null, null,
                                   'Belge iptal edildi: ' || coalesce(new.cancel_reason, ''),
                                   jsonb_build_object('document_id', new.id, 'otomatik', true));
    if rep.id is not null then
      select * into o from public.purchase_orders where id = k.order_id;
      if o.status <> 'iptal' and rep.project_id is not distinct from o.project_id
         and rep.is_demo is not distinct from o.is_demo
         and not exists (select 1 from public.purchase_order_documents x
                          where x.order_id = o.id and x.document_id = rep.id and x.status = 'aktif') then
        insert into public.purchase_order_documents (id, order_id, document_id)
        values (gen_random_uuid(), o.id, rep.id);
        perform private.purchase_event(o.id, 'belge_bagla', null, null, 'Belge yeni dosyayla değiştirildi',
                                       jsonb_build_object('document_id', rep.id, 'replaces_id', new.id,
                                                          'otomatik', true));
      end if;
    end if;
  end loop;
  return null;
end;
$$;
revoke execute on function private.tg_document_stock_link_end() from public, anon, authenticated;
create trigger document_stock_link_end
  after update of status on public.documents
  for each row when (old.status is distinct from 'iptal' and new.status = 'iptal')
  execute function private.tg_document_stock_link_end();

-- Bağlanacak belge bağlama işlemi bitene kadar kilitlenir (yeniden tanım:
-- yalnızca kilit eklendi, fonksiyon artık STABLE değil).
create or replace function private.check_stock_document(p_document uuid, p_project uuid, p_is_demo boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documents;
begin
  if p_document is null then
    return;
  end if;
  -- Belge satırı paylaşımlı kilitlenir: bağlama ile eşzamanlı bir taşıma
  -- (relink_document) sıralanır ve sonra gelen kapsam korumasına takılır.
  select * into d from public.documents where id = p_document for share;
  if not found or not private.can_read_document(d.status, d.created_by, d.link_type, d.kind, d.project_id,
                                                d.finance_document_id, d.contract_id) then
    raise exception 'Belge bulunamadı' using errcode = 'no_data_found';
  end if;
  if d.status not in ('yuklendi', 'arsivlendi') then
    raise exception 'Yalnızca yüklenmiş belge bağlanabilir' using errcode = 'check_violation';
  end if;
  if d.is_demo is distinct from p_is_demo then
    raise exception 'Deneme (DEMO) belgesi gerçek kayda, gerçek belge deneme kaydına bağlanamaz'
      using errcode = 'check_violation';
  end if;
  if d.project_id is distinct from p_project then
    raise exception 'Belge aynı projeye ait olmalı' using errcode = 'check_violation';
  end if;
end;
$$;
revoke execute on function private.check_stock_document(uuid, uuid, boolean) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 1e) Gider bağlı sipariş iptal edilemez
-- -----------------------------------------------------------------------------
create or replace function private.tg_purchase_order_expense_cancel_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.purchase_order_expense_links x
              where x.order_id = new.id and x.status = 'aktif') then
    raise exception 'Gider (fatura) bağlı sipariş iptal edilemez; önce gider bağlantısını kaldırın'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
revoke execute on function private.tg_purchase_order_expense_cancel_guard() from public, anon, authenticated;
create trigger purchase_order_expense_cancel_guard
  before update of status on public.purchase_orders
  for each row when (old.status is distinct from 'iptal' and new.status = 'iptal')
  execute function private.tg_purchase_order_expense_cancel_guard();

-- -----------------------------------------------------------------------------
-- 2) Tekrar gönderim karşılaştırması
-- -----------------------------------------------------------------------------
create or replace function public.receive_purchase_order(
  p_id           uuid,
  p_order_id     uuid,
  p_lines        jsonb,
  p_receipt_date date default null,
  p_waybill_no   text default null,
  p_note         text default null,
  p_document_id  uuid default null,
  p_performed_by text default null)
returns public.purchase_receipts
language plpgsql
security definer
set search_path = ''
as $$
declare
  o         public.purchase_orders;
  r         public.purchase_receipts;
  l         public.purchase_order_lines;
  v_item    jsonb;
  v_qty     numeric;
  v_base    numeric;
  v_left    numeric;
  v_mov     uuid;
  v_date    date := coalesce(p_receipt_date, private.today());
  v_req     jsonb;
  v_ids     uuid[] := '{}';
  v_by      text := nullif(trim(p_performed_by), '');
begin
  if p_id is null then
    raise exception 'Teslim kimliği zorunlu' using errcode = 'check_violation';
  end if;
  select * into o from public.purchase_orders where id = p_order_id;
  if not found or not private.can_see_purchase(o.project_id) then
    raise exception 'Sipariş bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('satinalma.receive', o.project_id) then
    raise exception 'Malzeme teslim alma yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Teslim alınacak en az bir satır girilmeli' using errcode = 'check_violation';
  end if;
  -- İstek, karşılaştırma için normalleştirilir (satır sırası önemsiz).
  select coalesce(jsonb_agg(jsonb_build_object('order_line_id', (x ->> 'order_line_id')::uuid,
                                               'quantity', (x ->> 'quantity')::numeric)
                            order by (x ->> 'order_line_id')), '[]'::jsonb)
    into v_req from jsonb_array_elements(p_lines) x;

  select * into o from public.purchase_orders where id = p_order_id for update;

  select * into r from public.purchase_receipts where id = p_id;
  if found then
    if r.created_by is distinct from (select auth.uid()) or not private.can_see_purchase(o.project_id) then
      raise exception 'Bu kimlikle başka bir teslim var' using errcode = 'unique_violation';
    end if;
    if r.status = 'iptal' then
      raise exception 'Bu kimlikli teslim iptal edilmiş; yeni teslim için yeniden deneyin' using errcode = 'unique_violation';
    end if;
    if r.order_id = p_order_id and r.receipt_date = v_date
       and r.waybill_no is not distinct from nullif(trim(p_waybill_no), '')
       and r.note is not distinct from nullif(trim(p_note), '')
       and r.document_id is not distinct from p_document_id
       -- Satırlar teslimin açtığı stok hareketleriyle karşılaştırılır: miktar,
       -- birim ve teslim alan kişi aynı olmalı.
       and (select coalesce(jsonb_agg(jsonb_build_object('order_line_id', rl.order_line_id, 'quantity', rl.quantity)
                                      order by rl.order_line_id::text), '[]'::jsonb)
              from public.purchase_receipt_lines rl
              join public.stock_movements m on m.id = rl.stock_movement_id
             where rl.receipt_id = r.id
               and m.quantity = rl.quantity and m.purchase_receipt_id = r.id) = v_req
       and (select count(*) from public.purchase_receipt_lines rl where rl.receipt_id = r.id) = jsonb_array_length(v_req)
       and not exists (select 1 from public.stock_movements m
                        where m.purchase_receipt_id = r.id and m.kind = 'giris'
                          and m.performed_by is distinct from v_by) then
      return r;
    end if;
    raise exception 'Bu kimlikle farklı bir teslim var' using errcode = 'unique_violation';
  end if;

  if o.status not in ('onaylandi', 'kismi_teslim') then
    raise exception 'Yalnızca onaylı ve tamamlanmamış siparişe teslim alınır' using errcode = 'check_violation';
  end if;
  if v_date > private.today() + 1 then
    raise exception 'Teslim tarihi ileri bir tarih olamaz' using errcode = 'check_violation';
  end if;
  if v_date < o.order_date then
    raise exception 'Teslim tarihi sipariş tarihinden önce olamaz' using errcode = 'check_violation';
  end if;
  perform private.check_stock_document(p_document_id, o.project_id, o.is_demo);

  insert into public.purchase_receipts (id, receipt_no, order_id, warehouse_id, receipt_date, waybill_no, note,
                                        document_id, is_demo)
  values (p_id, private.next_doc_no('TS-', 'public.purchase_receipt_no_seq'), o.id, o.warehouse_id, v_date,
          nullif(trim(p_waybill_no), ''), nullif(trim(p_note), ''), p_document_id, o.is_demo)
  returning * into r;

  for v_item in select value from jsonb_array_elements(p_lines) loop
    select * into l from public.purchase_order_lines
     where id = nullif(v_item ->> 'order_line_id', '')::uuid and order_id = o.id and deleted_at is null
       for update;
    if not found then
      raise exception 'Sipariş satırı bulunamadı' using errcode = 'foreign_key_violation';
    end if;
    if l.id = any (v_ids) then
      raise exception 'Aynı sipariş satırı bir teslimde bir kez girilir' using errcode = 'check_violation';
    end if;
    v_ids := v_ids || l.id;
    v_qty := (v_item ->> 'quantity')::numeric;
    perform private.check_unit_quantity(v_qty, l.unit_id, false);
    v_base := private.to_base_quantity(l.material_id, v_qty, l.unit_factor);
    select s.remaining_base_quantity into v_left from public.v_purchase_order_line_status s where s.order_line_id = l.id;
    if v_base > v_left then
      raise exception 'Teslim miktarı sipariş kalanını aşıyor (satır %: kalan %, girilen %)', l.line_no, v_left, v_base
        using errcode = 'check_violation';
    end if;

    v_mov := gen_random_uuid();
    insert into public.stock_movements (id, movement_no, kind, status, movement_date, material_id, warehouse_id,
                                        quantity, unit_id, unit_factor, base_quantity, description, performed_by,
                                        document_id, purchase_order_id, purchase_receipt_id, approved_at, approved_by,
                                        is_demo)
    values (v_mov, private.next_doc_no('SH-', 'public.stock_movement_no_seq'), 'giris', 'onaylandi', v_date,
            l.material_id, o.warehouse_id, v_qty, l.unit_id, l.unit_factor, v_base,
            'Satın alma teslimi · ' || o.order_no || ' · ' || r.receipt_no, v_by,
            p_document_id, o.id, r.id, now(), auth.uid(), o.is_demo);
    insert into public.stock_entries (movement_id, warehouse_id, material_id, entry_date, quantity, is_demo)
    values (v_mov, o.warehouse_id, l.material_id, v_date, v_base, o.is_demo);
    insert into public.purchase_receipt_lines (receipt_id, order_line_id, quantity, base_quantity, stock_movement_id)
    values (r.id, l.id, v_qty, v_base, v_mov);
  end loop;

  o := private.refresh_purchase_order_status(o.id);
  perform private.purchase_event(o.id, 'teslim', null, o.status::text, null,
                                 jsonb_build_object('receipt_id', r.id, 'receipt_no', r.receipt_no, 'lines', v_req));
  return r;
end;
$$;

create or replace function public.link_purchase_order_expense(
  p_id uuid, p_order_id uuid, p_finance_document_id uuid, p_note text default null)
returns public.purchase_order_expense_links
language plpgsql
security definer
set search_path = ''
as $$
declare
  o  public.purchase_orders;
  d  public.finance_documents;
  k  public.purchase_order_expense_links;
begin
  select * into o from public.purchase_orders where id = p_order_id;
  if not found or not private.has_permission('satinalma.read', o.project_id) then
    raise exception 'Sipariş bulunamadı' using errcode = 'no_data_found';
  end if;
  if not private.has_permission('satinalma.write', o.project_id) then
    raise exception 'Siparişe gider bağlama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;
  select * into d from public.finance_documents where id = p_finance_document_id;
  if not found or not private.can_read_fin_doc(d.kind, d.project_id, d.created_by) then
    raise exception 'Gider kaydı bulunamadı' using errcode = 'no_data_found';
  end if;

  perform 1 from public.purchase_orders where id = o.id for update;
  -- Gider satırı kilitlenir: eşzamanlı bir düzenleme bağlantıdan önce veya
  -- sonra sıralanır; sonra gelen kapsam koruması tetikleyicisine takılır.
  select * into d from public.finance_documents where id = p_finance_document_id for update;
  select * into k from public.purchase_order_expense_links where id = p_id;
  if found then
    if k.order_id = p_order_id and k.finance_document_id = p_finance_document_id and k.status = 'aktif'
       and k.note is not distinct from nullif(trim(p_note), '') then
      return k;
    end if;
    raise exception 'Bu kimlikle farklı bir bağlantı var' using errcode = 'unique_violation';
  end if;
  if d.kind <> 'gider' then
    raise exception 'Siparişe yalnızca gider kaydı bağlanır' using errcode = 'check_violation';
  end if;
  if d.status = 'iptal' then
    raise exception 'İptal edilmiş gider bağlanamaz' using errcode = 'check_violation';
  end if;
  if o.status in ('taslak', 'iptal') then
    raise exception 'Gider yalnızca onaylı siparişe bağlanır' using errcode = 'check_violation';
  end if;
  if d.project_id is distinct from o.project_id then
    raise exception 'Gider kaydı siparişle aynı projeye ait olmalı' using errcode = 'check_violation';
  end if;
  if d.cari_account_id is not null and d.cari_account_id <> o.cari_account_id then
    raise exception 'Gider kaydının carisi siparişin tedarikçisiyle aynı olmalı' using errcode = 'check_violation';
  end if;
  if d.is_demo is distinct from o.is_demo then
    raise exception 'Deneme (DEMO) kaydı gerçek kayda bağlanamaz' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.purchase_order_expense_links x
              where x.finance_document_id = d.id and x.status = 'aktif') then
    raise exception 'Bu gider kaydı zaten bir siparişe bağlı' using errcode = 'unique_violation';
  end if;
  insert into public.purchase_order_expense_links (id, order_id, finance_document_id, note)
  values (p_id, o.id, d.id, nullif(trim(p_note), '')) returning * into k;
  perform private.purchase_event(o.id, 'gider_bagla', null, null, null,
                                 jsonb_build_object('finance_document_id', d.id, 'document_no', d.document_no));
  return k;
end;
$$;
