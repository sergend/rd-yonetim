-- Yedek doğrulaması için stok durumu (sıralı): depo × malzeme mevcut miktarı
-- (defter toplamı), onay bekleyen hareketler ve sipariş satırı teslim miktarları.
-- Geri yüklenen veritabanında aynı satırlar birebir çıkmalıdır.
select 'stock:' || e.warehouse_id || ':' || e.material_id || '=' || sum(e.quantity)::text
  from public.stock_entries e
 group by e.warehouse_id, e.material_id
union all
select 'pending:' || m.id || ':' || m.kind || '=' || m.base_quantity::text
  from public.stock_movements m
 where m.status = 'bekliyor'
union all
select 'po-line:' || s.order_line_id || ':ordered=' || s.base_quantity::text || ':received=' || s.received_base_quantity::text
  from public.v_purchase_order_line_status s
union all
select 'po:' || o.order_no || '=' || o.status::text
  from public.purchase_orders o
 order by 1;
