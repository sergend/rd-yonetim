# Yedekleme ve geri yükleme talimatı

Veri kaybına karşı katmanlar: Supabase'in kendi yedekleri (Pro plan + PITR),
her gece Supabase dışına şifreli yedek, aylık otomatik geri yükleme testi.

## 1. Bir kez yapılacak kurulum

### Supabase (canlı proje)

1. Pro plana geçin ve **PITR** eklentisini açın (Project Settings > Add-ons).
2. Authentication > Providers > Email: **Allow new users to sign up = kapalı**.
3. Veritabanı bağlantı adresi: Connect > **Session pooler** URI (şifre dahil).

4. Belge doğrulama fonksiyonunu yayınlayın (belgeler bu olmadan **yüklenemez**;
   yükleme "Doğrulama servisine ulaşılamadı" hatasıyla bekler):
   ```bash
   supabase functions deploy belge-dogrula --project-ref <proje-kimliği>
   ```
   Fonksiyon `SUPABASE_URL`, `SUPABASE_ANON_KEY` ve `SUPABASE_SERVICE_ROLE_KEY`
   değerlerini Supabase'in kendi ortamından alır; ayrıca gizli anahtar girilmez
   ve sunucu anahtarı uygulamaya hiç gitmez.

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

Belge dosyası yedeği (Storage, `belgeler` bucket'ı; şu an **kapalı**):

| Tür | Ad | Değer |
| --- | --- | --- |
| Secret | `SUPABASE_STORAGE_S3_ENDPOINT`, `SUPABASE_STORAGE_S3_ACCESS_KEY_ID`, `SUPABASE_STORAGE_S3_SECRET_ACCESS_KEY` | Supabase > Storage > S3 Connection'da oluşturulan **salt okuma amaçlı** erişim anahtarı |
| Secret | `BACKUP_STORAGE_CRYPT_PASSWORD`, `BACKUP_STORAGE_CRYPT_SALT` | Rastgele iki uzun parola (düz metin; iş akışı rclone için kendisi gizler). Parola yöneticisinde ve çevrimdışı ikinci bir yerde de saklayın. Kaybolursa belge yedeği açılamaz |
| Variable | `SUPABASE_STORAGE_S3_REGION` | Supabase bölgesi (ör. `eu-central-1`) |
| Variable | `STORAGE_BACKUP_ENABLED` | `true` (yalnızca yukarıdakiler girildikten sonra) |

Belgeler dış depoda `storage/` altında rclone crypt ile şifreli durur; içerik
ve klasör/dosya adları şifrelidir. Şifre çözülmüş görünümde (`vault:`)
`current/belgeler/` güncel kopyadır; değişen veya silinen dosyaların eski hali
`archive/<tarih>/belgeler/` altına taşınır. `storage/` için yaşam döngüsü kuralı
koymayın (eski kopyaları elle temizleyin); sürümleme açık kalsın.

## 2. Otomatik çalışanlar

| İş akışı | Ne zaman | Ne yapar |
| --- | --- | --- |
| `db-tests.yml` | Her pull request | Testler + deneme verisiyle yedek al / boş veritabanına geri yükle / doğrula |
| `backup-nightly.yml` | Her gece 03:00 (İstanbul) | Roller, şema, veri dökümü + satır sayıları + güvenlik durumu; age ile şifreli yükleme; ayın 1'inde aylık kopya |
| `backup-nightly.yml` (belge işi) | Her gece, `STORAGE_BACKUP_ENABLED` açıksa | Veritabanından yol/boyut/SHA-256 manifesti alır, yetim dosya sayısını raporlar (silmez), `belgeler` bucket'ını şifreli dış depoya eşitler, sonra her dosyayı dış depodan indirip manifestle karşılaştırır |
| `restore-test-monthly.yml` | Her ayın 1'i | En son yedeği çözer, boş Supabase ortamına yükler, satır sayıları ve güvenlik durumunu karşılaştırır, tüm testleri çalıştırır; belge yedeği açıksa dosyaları da geri yükleyip SHA-256 ile doğrular |

`db-tests.yml` içindeki yedek işi her PR'da belge dosyalarını da dener:
örnek PDF/JPEG/PNG yükler, veritabanını ve dosyaları (şifreli yerel depoya)
yedekler, şifreli depoda okunabilir içerik ve dosya adı olmadığını denetler,
bir dosyayı silip birini kesip birinin baytını değiştirerek doğrulamanın üçünü
de yakaladığını görür, boş ikinci Supabase'e veritabanı ve dosyaları geri
yükler, dosyaları API'den indirip SHA-256 karşılaştırır ve yetkisiz erişimin
reddedildiğini denetler. Bu yalnızca deneme verisini kanıtlar.

Başarısız zamanlanmış iş akışları için GitHub e-posta bildirimi gönderir.

## 3. Gerçek veriye geçmeden önce (zorunlu)

- [ ] `db-tests.yml` yeşil.
- [ ] Canlı projede migration'lar uygulandı, ilk yönetici atandı.
- [ ] `backup-nightly.yml` elle çalıştırıldı (Run workflow), dosya dış depoda görünüyor.
- [ ] `restore-test-monthly.yml` elle çalıştırıldı ve yeşil.
- [ ] age gizli anahtarı iki ayrı yerde saklanıyor.

Aşama 6'da (belgeler) ek olarak:

- [ ] `STORAGE_BACKUP_ENABLED` açıldı; gece belge işi yeşil ve dış depoda
      `storage/` altında şifreli dosyalar görünüyor.
- [ ] `restore-test-monthly.yml` elle çalıştırıldı; "Belge dosyalarını geri
      yükle ve SHA-256 doğrula" adımı yeşil.
- [ ] Crypt parolaları iki ayrı yerde saklanıyor.
- [ ] `belge-dogrula` fonksiyonu canlı projede yayınlandı; bir deneme belgesi
      yüklenince Geçmiş'te "Dosya yüklendi ve doğrulandı" görünüyor.

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

5. Belge dosyalarını geri yükleyin (yeni projede Storage > S3 Connection'dan
   anahtar oluşturup rclone'a `target:` olarak, şifreli dış depoyu crypt
   parolalarıyla `vault:` olarak tanımlayın):
   ```bash
   scripts/backup/storage-restore.sh vault: target:belgeler yedek/storage-manifest.tsv
   ```
   Betik dosyaları kopyalar, sonra her dosyayı hedeften indirip yol, boyut ve
   SHA-256 ile karşılaştırır. Eksik (EKSİK), boyutu farklı (BOYUT FARKLI) veya
   bozuk (BOZUK) dosya varsa listeler ve hata koduyla biter; bu durumda
   `vault:archive/` altındaki eski kopyalara bakın.

> Betikler yalnızca **boş** bir ortama uygulanır. Canlı veritabanına asla çalıştırmayın.

## 5. Yarım ve yetim belge dosyaları

- Yükleme sırasında bağlantı koparsa belge `bekliyor` kalır; uygulama aynı
  kimlikle yeniden dener. 24 saati geçen bekleyen kayıtları iptal etmek için
  (SQL editöründe, yönetici olarak):
  ```sql
  select private.expire_document_uploads();
  ```
  Bu fonksiyon şu an zamanlanmış değildir; ayda bir elle çalıştırılabilir.
- Hiçbir etkin veya arşivlenmiş belgeye ait olmayan dosyaları **listelemek** için:
  ```sql
  select * from private.document_orphan_objects();
  ```
  Özeti sunucuda uyuşmadığı için iptal edilen yüklemelerin dosyaları da bu
  listeye girer. Otomatik silme yoktur. Silmeden önce dosyanın dış yedekte olduğunu ve hiçbir
  `documents` satırının `storage_path` değerine eşit olmadığını kontrol edin;
  silme Supabase panelinden (Storage) yapılır. Etkin veya arşivlenmiş belgenin
  dosyası asla silinmez.
