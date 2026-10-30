# iOS uygulaması: Mac'te kurulum ve test

Bu belge Aşama 1 iOS kodunu ilk kez Mac'te açacak kişi içindir. Kod Windows/Linux
ortamında yazıldı; SwiftUI ekranları orada derlenemez (ayrıntı aşağıda).

## Gerekenler

- macOS 14.5+ ve **Xcode 16** veya üstü (proje dosyası Xcode 16 biçimindedir)
- Docker Desktop ve Node.js (yerel Supabase için)
- İsteğe bağlı: Supabase CLI (`brew install supabase/tap/supabase`; yoksa `npx supabase`)

## 1. Yerel Supabase'i başlat

```bash
git clone https://github.com/sergend/rd-yonetim.git && cd rd-yonetim
git checkout asama-1/ios-proje-cari
npx supabase start          # ilk seferde imajları indirir
npx supabase status         # "API URL" ve "anon key" değerlerini not alın
npx supabase test db        # pgTAP testleri (hepsi "ok" olmalı)
```

`supabase start` deneme verisini (`seed.sql`) yükler: **Sivas 30 Daire Projesi**
(DEMO), örnek cariler ve işler. Yerel kullanıcılar (şifre `yerel-test-1234`):

| E-posta | Rol | Görmesi gereken |
| --- | --- | --- |
| `yonetici@example.test` | Yönetici | Her şey |
| `muhasebe@example.test` | Muhasebe | Projeler, cariler, bakiyeler, genel giderler |
| `sef@example.test` | Sivas projesinde şantiye şefi | Projeler ve işler; **cari ve tutar yok** |

## 2. Gizli ayar dosyası

```bash
cp ios/Config/Secrets.example.xcconfig ios/Config/Secrets.xcconfig
```

`SUPABASE_ANON_KEY` satırına `supabase status` çıktısındaki anon key'i yazın.
Bu dosya `.gitignore`'dadır, depoya girmez. URL yazımındaki `https:/$()/`
biçimi bilerek böyledir (xcconfig'te `//` yorum başlatır).

## 3. Xcode'da aç ve çalıştır

1. `ios/RDYonetim.xcodeproj` dosyasını açın. Xcode supabase-swift paketini indirir.
2. Signing & Capabilities → Team: kendi Apple hesabınızı seçin (simülatör için gerekmez).
3. Şema `RDYonetim`, hedef bir iPhone simülatörü (iOS 17+) → Run (⌘R).
4. Gerçek iPhone'da denemek için `SUPABASE_URL`'de 127.0.0.1 yerine Mac'in
   yerel ağ IP'sini yazın (ör. `http:/$()/192.168.1.20:54321`).

## 4. Elle test adımları

- [ ] `muhasebe@example.test` ile giriş; ana ekranda **hiçbir tutar yok**, yalnızca proje, iş sayıları ve modüller.
- [ ] Projeler → yeni proje ekle, düzenle; aynı kodla ikinci proje reddedilmeli.
- [ ] Cari hesaplar → yeni cari (VKN 10 hane, IBAN kontrolü); listede bakiye görünmeli.
- [ ] Cari detay → hareket ekle (Ödeme: yön otomatik "Borç"); proje ve tarih filtresiyle ekstre ve bakiye değişmeli.
- [ ] Bir ödemeyi sola kaydırıp "İptal et": hareket silinmez, "İptal edildi" etiketi ve ters kayıt eklenir; ikinci kez iptal edilemez.
- [ ] Şirket genel giderleri → Merkez ofis altında hareket ve bakiye.
- [ ] Çıkış yapıp `sef@example.test` ile giriş: Cari hesaplar ve genel giderler modülleri **görünmemeli**; proje detayında "Finans" bölümü olmamalı.
- [ ] Puantaj, Hakediş vb. "Sonraki aşamalarda" bölümünde; açınca veri girişi sunmayan bilgi ekranı.
- [ ] Ayarlar → Görünüm → Koyu: tüm ekranlar okunaklı olmalı.
- [ ] Uygulamayı kapatıp açın: oturum hatırlanmalı (Keychain).

## 5. Otomatik testler

```bash
cd ios/RDCore
swift test --filter RDCoreTests                 # model, doğrulama, yetki, ViewModel
RD_SUPABASE_URL=http://127.0.0.1:54321 RD_SUPABASE_ANON_KEY=<anon key> \
  swift test --filter RDSupabaseIntegrationTests # gerçek yerel API'ye karşı
```

Entegrasyon testleri yalnızca `127.0.0.1`/`localhost` adresine bağlanır; canlı
adrese yöneltilirse başarısız olur. Testler yerel veritabanına kayıt ekler; temiz
başlangıç için `npx supabase db reset`.

## Windows/Linux'ta doğrulanamayanlar

- SwiftUI görünümleri (`ios/RDYonetim/`) yalnızca sözdizimi açısından denetlendi;
  tür denetimi ve derleme Xcode ister. GitHub Actions'taki "iOS uygulaması
  derleme" işi (macOS) bunu her PR'da yapar.
- `RDYonetim.xcodeproj` elle yazıldı; ilk açılışta Xcode bir düzeltme önerirse kabul edilebilir.
- Keychain'de oturum saklama, klavye/odak davranışı, koyu mod görünümü ve
  gerçek cihaz davranışı yalnızca Mac/iPhone'da görülebilir.
- Uygulama ikonu boştur (yer tutucu).
