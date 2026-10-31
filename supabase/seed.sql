-- =============================================================================
-- YALNIZCA YEREL GELİŞTİRME VERİSİ. Gerçek şirket verisi içermez ve canlı
-- veritabanına hiçbir zaman uygulanmaz (supabase db reset ile yerelde yüklenir).
-- Tüm kayıtlar is_demo = true ile işaretlidir; kodlar DEMO- ile başlar.
-- Yerel giriş (şifre: yerel-test-1234):
--   yonetici@example.test  · tüm yetkiler
--   muhasebe@example.test  · cari ve finans
--   sef@example.test       · Sivas projesinde şantiye şefi (finans görmez, puantaj girer)
-- =============================================================================

do $$
declare
  v_admin    uuid := '00000000-0000-4000-8000-000000000001';
  v_sef      uuid := '00000000-0000-4000-8000-000000000002';
  v_muhasebe uuid := '00000000-0000-4000-8000-000000000003';
  v_proj     uuid;
  v_sivas    uuid;
  v_ofis     uuid;
  v_taseron  uuid;
  v_beton    uuid;
  v_demir    uuid;
  v_musteri  uuid;
  v_hakedis  uuid := '00000000-0000-4000-8000-0000000000d1';
  v_odeme    uuid := '00000000-0000-4000-8000-0000000000d2';
begin
  -- Gerçek veri bulunan bir veritabanına demo yüklenmesini engeller.
  if exists (select 1 from public.projects where not is_demo)
     or exists (select 1 from auth.users where email not like '%@example.test') then
    raise exception 'seed.sql yalnızca boş yerel veritabanında çalışır';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                          created_at, updated_at, confirmation_token, recovery_token,
                          email_change, email_change_token_new)
  select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         u.email, extensions.crypt('yerel-test-1234', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', u.full_name),
         now(), now(), '', '', '', ''
    from (values (v_admin,    'yonetici@example.test', 'Deneme Yönetici'),
                 (v_sef,      'sef@example.test',      'Deneme Şantiye Şefi'),
                 (v_muhasebe, 'muhasebe@example.test', 'Deneme Muhasebe')) as u (id, email, full_name);

  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  select gen_random_uuid(), u.id, u.id::text, 'email',
         jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
         now(), now(), now()
    from auth.users u where u.id in (v_admin, v_sef, v_muhasebe);

  perform private.bootstrap_admin('yonetici@example.test');
  insert into public.user_roles (user_id, role_id)
  select v_muhasebe, r.id from public.roles r where r.key = 'muhasebe';

  -- Projeler ve genel masraf merkezi
  insert into public.projects (code, name, city, status, is_demo)
  values ('DEMO-01', 'Deneme Konut Projesi', 'Deneme', 'devam', true)
  returning id into v_proj;

  insert into public.projects (code, name, address, city, start_date, status, notes, is_demo)
  values ('DEMO-SVS', 'Sivas 30 Daire Projesi', 'Örnek Mahallesi, Deneme Sokak No: 1', 'Sivas',
          '2026-03-01', 'devam', 'Örnek proje: 2 blok, 30 daire. Tüm kayıtlar demodur.', true)
  returning id into v_sivas;

  insert into public.project_members (project_id, user_id, role_id)
  select p, v_sef, r.id from public.roles r, unnest(array[v_proj, v_sivas]) p where r.key = 'santiye_sefi';

  insert into public.cost_centers (code, name, description, is_demo)
  values ('GENEL-OFIS', 'Merkez ofis', 'Deneme genel masraf merkezi', true)
  returning id into v_ofis;

  -- Cari kartlar (hayali firmalar)
  insert into public.cari_accounts (code, title, type, tax_number, phone, is_demo) values
    ('DEMO-C01', 'Örnek Kaba İnşaat Taşeronu', 'taseron',          '1111111111', '0000 000 00 01', true),
    ('DEMO-C02', 'Örnek Hazır Beton Tedarikçisi', 'tedarikci',     '2222222222', '0000 000 00 02', true),
    ('DEMO-C03', 'Örnek Demir Tedarikçisi', 'tedarikci',           '3333333333', null, true),
    ('DEMO-C04', 'Örnek Daire Alıcısı', 'musteri',                 null, null, true),
    ('DEMO-C05', 'Örnek Muhasebe Bürosu', 'hizmet_saglayici',      null, null, true);
  select id into v_taseron from public.cari_accounts where code = 'DEMO-C01';
  select id into v_beton   from public.cari_accounts where code = 'DEMO-C02';
  select id into v_demir   from public.cari_accounts where code = 'DEMO-C03';
  select id into v_musteri from public.cari_accounts where code = 'DEMO-C04';

  -- Hareketler: hakediş Aşama 2'de kendi modülünden gelecek; burada kaynak
  -- belge kimliğiyle temsil ediliyor. Diğerleri muhasebe kullanıcısı adına RPC ile.
  insert into public.cari_entries (id, cari_account_id, project_id, entry_date, direction, kind,
                                   amount, description, document_no, source_type, source_id)
  values (v_hakedis, v_taseron, v_sivas, '2026-09-30', 'alacak', 'hakedis', 450000,
          'Kaba inşaat 1 nolu hakediş (demo)', 'HK-1', 'hakedis', '00000000-0000-4000-8000-0000000000e1');

  perform set_config('request.jwt.claims', json_build_object('sub', v_muhasebe, 'role', 'authenticated')::text, true);

  perform public.post_cari_entry('00000000-0000-4000-8000-0000000000d0', v_taseron, '2026-08-15', 'borc', 'avans',
                                 100000, 'İş başlangıç avansı (demo)', p_project_id => v_sivas);
  perform public.post_cari_entry(v_odeme, v_taseron, '2026-10-10', 'borc', 'odeme',
                                 200000, '1 nolu hakediş kısmi ödemesi (demo)', p_project_id => v_sivas);
  perform public.allocate_cari_entry(v_odeme, v_hakedis, 200000, 'Kısmi ödeme');
  perform public.post_cari_entry('00000000-0000-4000-8000-0000000000d3', v_beton, '2026-09-12', 'alacak', 'manuel',
                                 185000, 'C30 hazır beton, temel (demo)', p_project_id => v_sivas, p_document_no => 'IRS-104');
  perform public.post_cari_entry('00000000-0000-4000-8000-0000000000d4', v_beton, '2026-10-01', 'borc', 'odeme',
                                 185000, 'Beton ödemesi (demo)', p_project_id => v_sivas);
  perform public.post_cari_entry('00000000-0000-4000-8000-0000000000d5', v_demir, '2026-09-20', 'alacak', 'manuel',
                                 320000, 'Nervürlü demir (demo)', p_project_id => v_sivas);
  perform public.post_cari_entry('00000000-0000-4000-8000-0000000000d6', v_demir, '2026-09-21', 'alacak', 'manuel',
                                 32000, 'Hatalı giriş örneği (demo)', p_project_id => v_sivas);
  perform public.reverse_cari_entry('00000000-0000-4000-8000-0000000000d6', 'Mükerrer irsaliye',
                                    '00000000-0000-4000-8000-0000000000d7');
  perform public.post_cari_entry('00000000-0000-4000-8000-0000000000d8', v_musteri, '2026-07-01', 'alacak', 'tahsilat',
                                 500000, 'A Blok 3 nolu daire peşinatı (demo)', p_project_id => v_sivas);
  perform public.post_cari_entry('00000000-0000-4000-8000-0000000000d9',
                                 (select id from public.cari_accounts where code = 'DEMO-C05'), '2026-10-01', 'alacak', 'manuel',
                                 15000, 'Ekim muhasebe hizmeti (demo)', p_cost_center_id => v_ofis);

  perform set_config('request.jwt.claims', '', true);

  -- İş takibi
  insert into public.tasks (project_id, title, description, assignee_id, due_date, status, priority) values
    (v_sivas, 'B Blok 3. kat döşeme betonu', 'Pompa ve beton siparişi teyit edilecek', v_sef, private.today() + 2, 'acik', 'yuksek'),
    (v_sivas, 'A Blok iskele kontrolü', null, v_sef, private.today() + 5, 'devam', 'normal'),
    (v_sivas, 'Yapı denetim tutanağı', 'Temel aşaması tutanağı imzalandı', null, private.today() - 3, 'tamamlandi', 'normal'),
    (null,    'Ofis sigorta yenilemesi', 'Genel iş, projeye bağlı değil', v_admin, private.today() + 14, 'acik', 'dusuk');

  -- Taşeron, personel, ekip ve görevlendirmeler (Aşama 2). Kişi adları hayalidir.
  insert into public.subcontractors (name, trade, cari_account_id, contact_name, phone, notes, is_demo) values
    ('Örnek Kaba İnşaat Taşeronu', 'kalip', v_taseron, 'Deneme Ekip Başı', '0000 000 00 11',
     'Cari kartı DEMO-C01 ile bağlı (demo)', true),
    ('Örnek Elektrik Taşeronu', 'elektrik', null, null, '0000 000 00 12', null, true);

  insert into public.subcontractor_documents (subcontractor_id, title, document_no, valid_until)
  select s.id, 'Vergi levhası (demo)', 'VL-0001', '2026-12-31'
    from public.subcontractors s where s.name = 'Örnek Kaba İnşaat Taşeronu';

  insert into public.personnel (full_name, job_title, trade, employment_type, subcontractor_id, is_demo)
  select x.full_name, x.job_title, x.trade::public.work_trade, x.employment::public.employment_type, s.id, true
    from (values ('Deneme Şantiye Teknikeri', 'Tekniker',     'genel',    'sirket',  null),
                 ('Deneme Kalıp Ustası',      'Kalıp ustası', 'kalip',    'taseron', 'Örnek Kaba İnşaat Taşeronu'),
                 ('Deneme Kalıp Kalfası',     'Kalfa',        'kalip',    'taseron', 'Örnek Kaba İnşaat Taşeronu'),
                 ('Deneme Demir Ustası',      'Demir ustası', 'demir',    'taseron', 'Örnek Kaba İnşaat Taşeronu'),
                 ('Deneme Elektrikçi',        'Elektrikçi',   'elektrik', 'taseron', 'Örnek Elektrik Taşeronu'))
         as x (full_name, job_title, trade, employment, sub_name)
    left join public.subcontractors s on s.name = x.sub_name;

  insert into public.personnel_contacts (personnel_id, phone)
  select p.id, '0000 000 00 2' || row_number() over (order by p.full_name)
    from public.personnel p where p.is_demo;

  insert into public.crews (name, subcontractor_id, trade, leader_id, is_demo)
  select x.name, s.id, x.trade::public.work_trade, p.id, true
    from (values ('Kalıp Ekibi',    'Örnek Kaba İnşaat Taşeronu', 'kalip',    'Deneme Kalıp Ustası'),
                 ('Demir Ekibi',    'Örnek Kaba İnşaat Taşeronu', 'demir',    'Deneme Demir Ustası'),
                 ('Elektrik Ekibi', 'Örnek Elektrik Taşeronu',    'elektrik', 'Deneme Elektrikçi'))
         as x (name, sub_name, trade, leader)
    join public.subcontractors s on s.name = x.sub_name
    join public.personnel p on p.full_name = x.leader;

  insert into public.crew_memberships (crew_id, personnel_id, start_date, role_title)
  select c.id, p.id, '2026-03-01', x.role_title
    from (values ('Kalıp Ekibi', 'Deneme Kalıp Ustası', 'Usta'),
                 ('Kalıp Ekibi', 'Deneme Kalıp Kalfası', 'Kalfa'),
                 ('Demir Ekibi', 'Deneme Demir Ustası', 'Usta'),
                 ('Elektrik Ekibi', 'Deneme Elektrikçi', 'Usta')) as x (crew, person, role_title)
    join public.crews c on c.name = x.crew
    join public.personnel p on p.full_name = x.person;

  insert into public.subcontractor_projects (subcontractor_id, project_id, start_date, scope)
  select s.id, v_sivas, '2026-03-01', 'Kaba inşaat: kalıp ve demir (demo)'
    from public.subcontractors s where s.name = 'Örnek Kaba İnşaat Taşeronu';

  insert into public.project_assignments (project_id, crew_id, personnel_id, start_date, description)
  select x.project, c.id, p.id, x.start_date::date, x.description
    from (values (v_sivas, 'Kalıp Ekibi', null, '2026-03-01', 'Temel ve bodrum kalıbı'),
                 (v_sivas, 'Demir Ekibi', null, '2026-04-01', null),
                 (v_sivas, null, 'Deneme Şantiye Teknikeri', '2026-03-01', 'Saha teknik takibi'),
                 (v_proj,  'Elektrik Ekibi', null, '2026-09-01', null))
         as x (project, crew, person, start_date, description)
    left join public.crews c on c.name = x.crew
    left join public.personnel p on p.full_name = x.person;

  -- Puantaj (Aşama 3): Sivas projesinde Ekim 2026'nın ilk iş günleri taslak.
  -- Pazar günleri boş bırakılır (girilmeyen gün devamsızlık sayılmaz).
  insert into public.puantaj_entries (project_id, personnel_id, work_date, status, overtime_hours, overtime_note)
  select v_sivas, p.id, d::date,
         case when p.full_name = 'Deneme Kalıp Kalfası' and extract(day from d) in (7, 8) then 'raporlu'
              when p.full_name = 'Deneme Demir Ustası' and extract(day from d) = 14 then 'yarim_gun'
              when p.full_name = 'Deneme Şantiye Teknikeri' and extract(day from d) = 29 then 'resmi_tatil'
              else 'tam_gun' end::public.puantaj_status,
         case when p.full_name = 'Deneme Kalıp Ustası' and extract(day from d) = 10 then 2 else 0 end,
         case when p.full_name = 'Deneme Kalıp Ustası' and extract(day from d) = 10 then 'Döşeme betonu (demo)' end
    from generate_series('2026-10-01'::date, least(private.today() - 1, '2026-10-30'::date), interval '1 day') d
   cross join public.personnel p
   where p.is_demo
     and p.full_name in ('Deneme Şantiye Teknikeri', 'Deneme Kalıp Ustası', 'Deneme Kalıp Kalfası', 'Deneme Demir Ustası')
     and extract(isodow from d) <> 7;

  -- Sözleşme ve hakediş (Aşama 4): Sivas projesinde birim fiyatlı demo
  -- sözleşme. Eylül hakedişi onaylı, deftere işlenmiş ve kısmen ödenmiş; Ekim
  -- hakedişi incelemede. Vergi kuralı eklenmez: oranlar kullanıcı tarafından
  -- doğrulanarak girilir. Tutarlar hayalidir.
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  perform public.save_payment_source('00000000-0000-4000-8000-0000000000f1', 'Şirket ödemesi (demo)', 'sirket');
  perform public.save_payment_source('00000000-0000-4000-8000-0000000000f2', 'Örnek kredi kartı (demo)', 'kart');

  perform public.save_contract(
    '00000000-0000-4000-8000-0000000000c1', v_sivas,
    (select id from public.subcontractors where name = 'Örnek Kaba İnşaat Taşeronu'),
    'DEMO-S-001', 'Kaba inşaat kalıp ve beton işçiliği (demo)',
    jsonb_build_array(
      jsonb_build_object('item_key', '00000000-0000-4000-8000-0000000000a1', 'method', 'birim_fiyat',
                         'description', 'Temel ve perde kalıbı', 'unit', 'm2', 'quantity', 2400, 'unit_price', 450),
      jsonb_build_object('item_key', '00000000-0000-4000-8000-0000000000a2', 'method', 'birim_fiyat',
                         'description', 'Beton döküm işçiliği', 'unit', 'm3', 'quantity', 900, 'unit_price', 280)),
    p_signed_date => '2026-08-01', p_scope => 'A ve B blok kaba inşaat işçiliği (demo)',
    p_start_date => '2026-08-01', p_total_amount => 1332000, p_retention_rate => 10,
    p_payment_terms => 'Onaydan sonra 15 gün içinde (demo)');
  perform public.contract_transition('00000000-0000-4000-8000-0000000000c1', 'onayla');

  perform public.save_work_quantity('00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000c1',
    '00000000-0000-4000-8000-0000000000a1', '2026-09-20', 600, 'A blok temel', 'Eylül metrajı (demo)');
  perform public.save_work_quantity('00000000-0000-4000-8000-0000000000b2', '00000000-0000-4000-8000-0000000000c1',
    '00000000-0000-4000-8000-0000000000a2', '2026-09-25', 150, 'A blok temel', null);
  perform public.approve_work_quantities(array['00000000-0000-4000-8000-0000000000b1',
                                               '00000000-0000-4000-8000-0000000000b2']::uuid[]);

  perform public.create_hakedis('00000000-0000-4000-8000-0000000000e2', '00000000-0000-4000-8000-0000000000c1',
                                '2026-09-01', '2026-09-30', 'Eylül hakedişi (demo)');
  perform public.set_hakedis_deduction('00000000-0000-4000-8000-0000000000e2', 'avans_mahsubu', 50000,
                                       'İş başlangıç avansının yarısı');
  perform public.hakedis_transition('00000000-0000-4000-8000-0000000000e2', 'gonder');
  perform public.hakedis_transition('00000000-0000-4000-8000-0000000000e2', 'onayla');
  perform public.post_hakedis('00000000-0000-4000-8000-0000000000e2', '2026-10-05');
  perform public.record_finance_payment('00000000-0000-4000-8000-0000000000f3', '00000000-0000-4000-8000-0000000000c1',
    'odeme', 150000, '00000000-0000-4000-8000-0000000000f1', '2026-10-15',
    p_hakedis_id => '00000000-0000-4000-8000-0000000000e2', p_description => 'Eylül hakedişi kısmi ödeme (demo)');

  perform public.save_work_quantity('00000000-0000-4000-8000-0000000000b3', '00000000-0000-4000-8000-0000000000c1',
    '00000000-0000-4000-8000-0000000000a1', '2026-10-20', 400, 'A blok perde', null);
  perform public.approve_work_quantities(array['00000000-0000-4000-8000-0000000000b3']::uuid[]);
  perform public.create_hakedis('00000000-0000-4000-8000-0000000000e3', '00000000-0000-4000-8000-0000000000c1',
                                '2026-10-01', '2026-10-31', 'Ekim hakedişi (demo)');
  perform public.hakedis_transition('00000000-0000-4000-8000-0000000000e3', 'gonder');

  -- Gider, gelir ve borç (Aşama 5). Tutarlar hayalidir. Kategoriler migration
  -- ile gelen düzenlenebilir başlangıç verisidir.
  --   g1: cari bağlantılı demir faturası, onaylı, kısmen ödenmiş (vade geçmiş)
  --   g2: sahada Kürşat kartıyla peşin ödenmiş akaryakıt (onayda ödeme doğar)
  --   g3: ofis gideri, taslak (onay bekliyor)
  --   g4: nakliye, onaylı, ödenmemiş, vadesi yakın
  --   l1: daire alıcısından gelir, onaylı, kısmen tahsil edilmiş
  perform public.save_payment_source('00000000-0000-4000-8000-0000000000f4', 'Kürşat kartı (demo)', 'kart');
  perform public.save_finance_document('00000000-0000-4000-8000-000000000101', 'gider',
    (select id from public.finance_categories where kind = 'gider' and name = 'Demir'),
    'Ø12 nervürlü demir, B blok (demo)', 240000, '2026-10-02', p_project_id => v_sivas,
    p_due_date => '2026-10-20', p_cari_account_id => v_demir, p_invoice_no => 'DMR-2026-118');
  perform public.approve_finance_document('00000000-0000-4000-8000-000000000101');
  perform public.record_finance_settlement('00000000-0000-4000-8000-000000000111',
    '00000000-0000-4000-8000-000000000101', 100000, '00000000-0000-4000-8000-0000000000f1', '2026-10-15',
    'Deneme Muhasebe', 'Demir faturası kısmi ödeme (demo)');
  perform public.save_finance_document('00000000-0000-4000-8000-000000000102', 'gider',
    (select id from public.finance_categories where kind = 'gider' and name = 'Akaryakıt'),
    'İş makinesi motorin (demo)', 4250.50, '2026-10-21', p_project_id => v_sivas,
    p_reported_settled => true, p_reported_source_id => '00000000-0000-4000-8000-0000000000f4',
    p_reported_by => 'Kürşat (demo)', p_document_ref => 'Fiş no 4471');
  perform public.approve_finance_document('00000000-0000-4000-8000-000000000102',
                                          p_settlement_id => '00000000-0000-4000-8000-000000000112');
  perform public.save_finance_document('00000000-0000-4000-8000-000000000103', 'gider',
    (select id from public.finance_categories where kind = 'gider' and name = 'Ofis gideri'),
    'Ofis kırtasiye ve toner (demo)', 1830, '2026-10-25', p_cost_center_id => v_ofis);
  perform public.save_finance_document('00000000-0000-4000-8000-000000000104', 'gider',
    (select id from public.finance_categories where kind = 'gider' and name = 'Nakliye'),
    'Kalıp malzemesi nakliyesi (demo)', 12500, '2026-10-26', p_project_id => v_sivas,
    p_due_date => private.today() + 5);
  perform public.approve_finance_document('00000000-0000-4000-8000-000000000104');
  perform public.save_finance_document('00000000-0000-4000-8000-000000000105', 'gelir',
    (select id from public.finance_categories where kind = 'gelir' and name = 'Satış geliri'),
    'A Blok 5 nolu daire ara ödemesi (demo)', 750000, '2026-10-01', p_project_id => v_sivas,
    p_due_date => '2026-11-15', p_cari_account_id => v_musteri, p_invoice_no => 'SAT-2026-005');
  perform public.approve_finance_document('00000000-0000-4000-8000-000000000105');
  perform public.record_finance_settlement('00000000-0000-4000-8000-000000000115',
    '00000000-0000-4000-8000-000000000105', 250000, '00000000-0000-4000-8000-0000000000f1', '2026-10-10',
    null, 'Ara ödemenin ilk kısmı (demo)');

  perform set_config('request.jwt.claims', '', true);
end;
$$;
