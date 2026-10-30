# Yedekleme ve geri yükleme talimatı

Veri kaybına karşı katmanlar: Supabase'in kendi yedekleri (Pro plan + PITR),
her gece Supabase dışına şifreli yedek, aylık otomatik geri yükleme testi.

## 1. Bir kez yapılacak kurulum

### Supabase (canlı proje)

1. Pro plana geçin ve **PITR** eklentisini açın (Project Settings > Add-ons).
2. Authentication > Providers > Email: **Allow new users to sign up = kapalı**.
3. Veritabanı bağlantı adresi: Connect > **Session pooler** URI (şifre dahil).

### Dış yedek deposu (S3 uyumlu, Supabase dışında)

Örnek: Cloudflare R2 veya Backblaze B2.

1. Özel bir bucket açın (ör. `rd-yonetim-yedek`), **sürümleme** ve mümkünse
   **object lock** (silme kilidi) açık olsun.
2. Yaşam döngüsü kuralları: `db/daily/` 30 gün, `db/monthly/` 400 gün sonra silinsin.
3. Yalnızca bu bucket'a yazma/okuma yetkisi olan bir erişim anahtarı oluşturun.

### Şifreleme anahtarı (age)

```bash
age-keygen -o rd-yonetim-yedek-anahtari.txt
```

Çıktıdaki `age1...` ile başlayan **açık anahtar** GitHub'a değişken olarak
girer. Dosyanın kendisi **gizli anahtardır**: bir parola yöneticisinde ve
çevrimdışı ikinci bir yerde saklayın. Kaybolursa yedekler açılamaz.

### GitHub ayarları

Settings > Environments > `production-backup` ortamı oluşturun, içine:

| Tür | Ad | Değer |
| --- | --- | --- |
| Secret | `SUPABASE_DB_URL` | Canlı Session pooler URI |
| Secret | `BACKUP_S3_ENDPOINT` | Dış deponun S3 adresi |
| Secret | `BACKUP_S3_ACCESS_KEY_ID` | Dış depo erişim anahtarı |
| Secret | `BACKUP_S3_SECRET_ACCESS_KEY` | Dış depo gizli anahtarı |
| Secret | `BACKUP_AGE_IDENTITY` | age gizli anahtar dosyasının içeriği (yalnızca aylık geri yükleme testi için) |
| Variable | `BACKUP_AGE_RECIPIENT` | age açık anahtarı (`age1...`) |
| Variable | `BACKUP_S3_BUCKET` | Bucket adı |
| Variable | `BACKUP_ENABLED` | `true` (repository variable olarak) |

Belge yedeği (Storage, Aşama 6'da belgeler gelince açılır):

| Tür | Ad |
| --- | --- |
| Secret | `SUPABASE_STORAGE_S3_ENDPOINT`, `SUPABASE_STORAGE_S3_ACCESS_KEY_ID`, `SUPABASE_STORAGE_S3_SECRET_ACCESS_KEY` |
| Secret | `BACKUP_STORAGE_CRYPT_PASSWORD`, `BACKUP_STORAGE_CRYPT_SALT` (rastgele, parola yöneticisinde de saklayın) |
| Variable | `SUPABASE_STORAGE_S3_REGION`, `STORAGE_BACKUP_ENABLED` = `true` |

## 2. Otomatik çalışanlar

| İş akışı | Ne zaman | Ne yapar |
| --- | --- | --- |
| `db-tests.yml` | Her pull request | Testler + deneme verisiyle yedek al / boş veritabanına geri yükle / doğrula |
| `backup-nightly.yml` | Her gece 03:00 (İstanbul) | Roller, şema, veri dökümü + satır sayıları + güvenlik durumu; age ile şifreli yükleme; ayın 1'inde aylık kopya |
| `restore-test-monthly.yml` | Her ayın 1'i | En son yedeği çözer, boş Supabase veritabanına yükler, satır sayıları ve güvenlik durumunu karşılaştırır, tüm testleri çalıştırır |

Başarısız zamanlanmış iş akışları için GitHub e-posta bildirimi gönderir.

## 3. Gerçek veriye geçmeden önce (zorunlu)

- [ ] `db-tests.yml` yeşil.
- [ ] Canlı projede migration'lar uygulandı, ilk yönetici atandı.
- [ ] `backup-nightly.yml` elle çalıştırıldı (Run workflow), dosya dış depoda görünüyor.
- [ ] `restore-test-monthly.yml` elle çalıştırıldı ve yeşil.
- [ ] age gizli anahtarı iki ayrı yerde saklanıyor.

Aşama 6'da (belgeler) ek olarak:

- [ ] `STORAGE_BACKUP_ENABLED` açıldı, gece belge yedeği dış depoda görünüyor.
- [ ] Belgelerin şifreli kopyadan geri yüklenmesi ayrıca denendi ve dosya
      sağlama toplamları (`documents.sha256`) karşılaştırıldı.

## 4. Acil durumda geri yükleme

Önce Supabase'in kendi geri dönüşünü deneyin: Database > Backups > **PITR** ile
sorundan hemen önceki ana dönün. Supabase'e erişilemiyorsa veya PITR yetmiyorsa:

1. Yeni boş bir Supabase projesi oluşturun.
2. Dış depodan istenen günün dosyasını indirin ve çözün:
   ```bash
   age -d -i rd-yonetim-yedek-anahtari.txt rd-yonetim-db-<tarih>.tar.gz.age | tar -xzf - -C yedek/
   ```
3. Geri yükleyin ve doğrulayın (yeni projenin Session pooler adresiyle):
   ```bash
   scripts/backup/restore-verify.sh yedek/ "<yeni-proje-db-url>"
   ```
   Betik sonunda `private.post_restore()` çalıştırır (Auth trigger'ı ve API
   kısıtları) ve satır sayıları ile güvenlik durumunu yedek anıyla karşılaştırır.
4. Yeni projede Authentication > Email kaydını kapatın; uygulamanın Supabase
   adresini ve anahtarını yeni projeye çevirin.

> Betik yalnızca **boş** bir veritabanına uygulanır. Canlı veritabanına asla çalıştırmayın.
