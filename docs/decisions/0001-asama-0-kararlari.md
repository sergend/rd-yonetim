# Karar 0001: Aşama 0 veritabanı kararları

Tarih: 2026-10-30 · Durum: Önerildi (pull request incelemesinde)

| # | Karar | Gerekçe |
| --- | --- | --- |
| 1 | Yönetici (`yonetici`) sistem rolü izin satırı tutmaz, tüm izinlere sahiptir | Yeni modül izinleri eklendiğinde yöneticinin kilitlenmesini ve unutulan atamaları önler. Kişiye özel `deny` yine geçerlidir. |
| 2 | Rol kapsamı `global` / `project` olarak ayrılır ve atama yeriyle trigger'la eşleştirilir | Revizyon 1-R1: genel roller `user_roles`, proje rolleri `project_members` üzerinden atanır; karışık atama hata verir. |
| 3 | Proje üyesi ve rol atamalarını yalnızca `kullanici.manage` izni olan yapar | Proje içinden kendine daha yüksek rol verme (yetki yükseltme) yolu kapanır. |
| 4 | API'de fiziksel silme yok; her tabloda `deleted_at` | Yanlışlıkla silmeye karşı ilk savunma; RLS `TRUNCATE`'i denetlemediği için ayrıca kapatıldı. |
| 5 | Yumuşak silinen satırlar RLS'te gizlenmez, istemci filtreler | Gizlemek, silme güncellemesinin dönen satırını RLS'e takar ve hatalı hata mesajlarına yol açar. |
| 6 | Değişiklik olmayan güncellemede `version` artmaz, audit kaydı oluşmaz | İyimser kilit yanlış "kayıt değişti" uyarısı vermez, geçmiş gürültüsüz kalır. |
| 7 | API ayrıcalıkları ve `auth.users` trigger'ı fonksiyon olarak tutulur, geri yüklemeden sonra `private.post_restore()` ile yeniden kurulur | Yerel denemede bulundu: Supabase şema dökümü `auth` şemasındaki trigger'ı ve `anon`'dan alınan yetkileri taşımıyor; geri yüklenen veritabanında `anon` tüm tablolarda yetki kazanıyordu. |
| 8 | Aylık geri yükleme testi ayrı bir ücretli Supabase projesi yerine GitHub Actions içindeki geçici Supabase veritabanına yapılır | Aynı Supabase Postgres imajı, sıfır ek maliyet; ayrıca her pull request'te aynı betik yerel verilerle çalışır. |
| 9 | İlk yönetici yalnızca SQL Editor'da `private.bootstrap_admin(e-posta)` ile atanır; aktif yönetici varken çalışmaz | Kayıt kapalıyken güvenli başlangıç; API'den çağrılamaz. |
| 10 | Kullanıcı davet Edge Function'ı Aşama 1'e bırakıldı | Uygulamada kullanıcı yönetimi ekranı Aşama 1'de; o zamana kadar davet Supabase panelinden yapılır. |
| 11 | Son etkin yönetici ertelenmiş kısıt trigger'ıyla korunur; yasak tarihleri bu denetimde dikkate alınmaz | İnceleme 1: rol silme, pasifleştirme veya `kullanici.manage` yasağıyla sistemin yöneticisiz kalması engellenir. İleri tarihli yasak sayılmazsa koruma o tarihte sessizce delinirdi. |
| 12 | Profil satırları proje kapsamıyla sınırlı; e-posta ve telefon sütun yetkisiyle kapalı, yalnızca `my_profile()` ve `user_directory()` ile okunur | İnceleme 2: RLS sütun gizleyemez; sütun yetkisi hem PostgREST'te hem doğrudan SQL'de geçerlidir. Sütun yetkileri geri yüklemede `private.post_restore()` ile yeniden kurulur ve güvenlik durumu karşılaştırmasına dahildir. |
