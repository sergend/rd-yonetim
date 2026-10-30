# Supabase projelerinin kurulumu

İki proje kullanılır: **rd-yonetim-dev** (geliştirme, deneme verisi) ve
**rd-yonetim-prod** (canlı). Her ikisinde de bölge olarak Frankfurt
(`eu-central-1`) önerilir.

1. Supabase panelinde iki projeyi oluşturun; veritabanı şifrelerini parola
   yöneticisinde saklayın.
2. Her projede Authentication > Providers > Email: yeni kayıtları kapatın; Authentication > Policies altında en az 10 karakterli şifre zorunlu olsun.
3. Migration'ları uygulayın (önce dev, sonra prod):
   ```bash
   npx supabase link --project-ref <proje-ref>
   npx supabase db push
   ```
4. İlk yönetici: Authentication > Users > **Invite user** ile davet edin, ardından
   SQL Editor'da:
   ```sql
   select private.bootstrap_admin('ad.soyad@sirket.com');
   ```
5. Canlı proje için yedekleme kurulumu: [runbook-backup-restore.md](runbook-backup-restore.md).

`seed.sql` yalnızca yerel `db reset` sırasında yüklenir; `db push` onu uygulamaz.
