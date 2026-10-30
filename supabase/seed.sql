-- =============================================================================
-- YALNIZCA YEREL GELİŞTİRME VERİSİ. Gerçek şirket verisi içermez ve canlı
-- veritabanına hiçbir zaman uygulanmaz (supabase db reset ile yerelde yüklenir).
-- Tüm kayıtlar is_demo = true ile işaretlidir; kodlar DEMO- ile başlar.
-- Yerel giriş (şifre: yerel-test-1234):
--   yonetici@example.test  · tüm yetkiler
--   muhasebe@example.test  · cari ve finans
--   sef@example.test       · Sivas projesinde şantiye şefi (finans görmez)
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
end;
$$;
