-- =============================================================================
-- YALNIZCA YEREL GELİŞTİRME VERİSİ. Gerçek şirket verisi içermez ve canlı
-- veritabanına hiçbir zaman uygulanmaz (supabase db reset ile yerelde yüklenir).
-- Yerel giriş: yonetici@example.test / sef@example.test, şifre: yerel-test-1234
-- =============================================================================

do $$
declare
  v_admin uuid := '00000000-0000-4000-8000-000000000001';
  v_sef   uuid := '00000000-0000-4000-8000-000000000002';
  v_proj  uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                          created_at, updated_at, confirmation_token, recovery_token,
                          email_change, email_change_token_new)
  values
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'yonetici@example.test', extensions.crypt('yerel-test-1234', extensions.gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}', '{"full_name":"Deneme Yönetici"}',
     now(), now(), '', '', '', ''),
    (v_sef, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'sef@example.test', extensions.crypt('yerel-test-1234', extensions.gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}', '{"full_name":"Deneme Şantiye Şefi"}',
     now(), now(), '', '', '', '');

  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  select gen_random_uuid(), u.id, u.id::text, 'email',
         jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
         now(), now(), now()
    from auth.users u where u.id in (v_admin, v_sef);

  perform private.bootstrap_admin('yonetici@example.test');

  insert into public.projects (code, name, city, status)
  values ('DEMO-01', 'Deneme Konut Projesi', 'Deneme', 'devam')
  returning id into v_proj;

  insert into public.project_members (project_id, user_id, role_id)
  select v_proj, v_sef, r.id from public.roles r where r.key = 'santiye_sefi';

  insert into public.cost_centers (code, name, description)
  values ('GENEL-OFIS', 'Merkez ofis', 'Deneme genel masraf merkezi');
end;
$$;
