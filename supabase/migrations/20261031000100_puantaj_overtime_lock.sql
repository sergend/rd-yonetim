-- Aşama 3 düzeltmesi: fazla mesai onayı ay durum işlemleriyle yarışmasın.
--
-- save_puantaj dönem satırlarını FOR SHARE ile kilitler, puantaj_transition
-- FOR UPDATE ile. approve_puantaj_overtime ise kilit almadan kayıtları
-- güncelliyordu: ay onayı snapshot'ı alınırken eşzamanlı bir fazla mesai onayı
-- onaylanan aya sızabilirdi. Artık:
--   * Etkilenen dönemler (proje, ay) sırasıyla FOR SHARE kilitlenir; açık bir
--     ay işlemi varsa onay onun bitmesini bekler ve dönemin son durumunu görür.
--   * Onaylanmış veya kilitli aya ait bir kayıt varsa hiçbir kayıt
--     değişmeden reddedilir (23514).
--   * Birden çok ay veya proje içeren toplu onay tek işlemdir; kilit sırası
--     save_puantaj ile uyumludur (aynı projede ay sırası).

create or replace function public.approve_puantaj_overtime(p_entry_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_period  record;
  v_count   integer;
begin
  if exists (select 1 from public.puantaj_entries e
              where e.id = any (p_entry_ids)
                and not private.has_permission('puantaj.approve', e.project_id)) then
    raise exception 'Fazla mesai onaylama yetkiniz yok' using errcode = 'insufficient_privilege';
  end if;

  for v_period in
    select pp.id, pp.month, pp.status
      from public.puantaj_periods pp
     where pp.id in (select e.period_id from public.puantaj_entries e
                      where e.id = any (p_entry_ids) and e.deleted_at is null)
     order by pp.project_id, pp.month
       for share
  loop
    if v_period.status in ('onaylandi', 'kilitli') then
      raise exception '% ayının puantajı %; fazla mesai onayı için ayın yetkili kişi tarafından gerekçeyle yeniden açılması gerekir',
        to_char(v_period.month, 'MM.YYYY'), private.puantaj_status_label(v_period.status)
        using errcode = 'check_violation';
    end if;
  end loop;

  update public.puantaj_entries e
     set overtime_approved_at = now(), overtime_approved_by = auth.uid()
   where e.id = any (p_entry_ids)
     and e.deleted_at is null
     and e.overtime_hours > 0
     and e.overtime_approved_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
