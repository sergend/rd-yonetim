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
(DEMO), örnek cariler, işler, taşeronlar, personel, ekipler ve görevlendirmeler. Yerel kullanıcılar (şifre `yerel-test-1234`):

| E-posta | Rol | Görmesi gereken |
| --- | --- | --- |
| `yonetici@example.test` | Yönetici | Her şey |
| `muhasebe@example.test` | Muhasebe | Projeler, cariler, bakiyeler, genel giderler |
| `sef@example.test` | Sivas projesinde şantiye şefi | Projeler, işler, projesindeki taşeron/personel/ekip; **cari ve tutar yok** |

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
- [ ] Ana ekran finans kuralı ayrıca elle doğrulanır (kaynak taraması olan `HomeScreenRuleTests` tek başına kanıt değildir): `muhasebe@example.test` ve `sef@example.test` ile açık ve koyu temada, en büyük metin boyutunda ana ekranı en alta kadar kaydırın; hiçbir yerde ₺/TL tutarı, kasa veya banka bakiyesi görünmemeli.
- [ ] Projeler → yeni proje ekle, düzenle; aynı kodla ikinci proje reddedilmeli.
- [ ] Cari hesaplar → yeni cari (VKN 10 hane, IBAN kontrolü); listede bakiye görünmeli.
- [ ] Cari detay → hareket ekle (Ödeme: yön otomatik "Borç"); proje ve tarih filtresiyle ekstre ve bakiye değişmeli.
- [ ] Bir ödemeyi sola kaydırıp "İptal et": hareket silinmez, "İptal edildi" etiketi ve ters kayıt eklenir; ikinci kez iptal edilemez.
- [ ] Şirket genel giderleri → Merkez ofis altında hareket ve bakiye.
- [ ] Çıkış yapıp `sef@example.test` ile giriş: Cari hesaplar ve genel giderler modülleri **görünmemeli**; proje detayında "Finans" bölümü olmamalı.
- [ ] Puantaj, Hakediş vb. "Sonraki aşamalarda" bölümünde; açınca veri girişi sunmayan bilgi ekranı.
- [ ] Ayarlar → Görünüm → Koyu: tüm ekranlar okunaklı olmalı; kırmızı metinler koyu zeminde açık tonda.
- [ ] Ayarlar → Erişilebilirlik → Ekran ve Metin Boyutu → Daha Büyük Metin (en büyük): satırlar alt alta diziliyor, metin kesilmiyor.
- [ ] Ana ekran adı ve başlık "RD Projeler"; logo henüz yok (bilinçli, bkz. docs/brand-assets.md).
- [ ] İş takibinde daire simgesine tek dokunuş işi tamamlıyor.
- [ ] Xcode Canvas'ta "Tasarım sistemi" önizlemesi açık ve koyu temada açılıyor.
- [ ] Uygulamayı kapatıp açın: oturum hatırlanmalı (Keychain).

### Aşama 2: taşeron, personel, ekip ve görevlendirme

- [ ] `yonetici@example.test`: ana ekranda Taşeronlar, Personel ve Ekipler modülleri görünür; ana ekranda yine hiçbir tutar yok.
- [ ] Taşeronlar → "Örnek Kaba İnşaat Taşeronu": cari kart (DEMO-C01) bağlantısı, Sivas projesi, Kalıp/Demir ekipleri, personel ve "Vergi levhası (demo)" görünür.
- [ ] Yeni taşeron: yalnızca ad girerek kaydedilebilir; cari kart seçicide müşteri carileri ve başka taşerona bağlı cariler çıkmaz.
- [ ] Yeni personel: yalnızca ad soyad ile kaydedilir; "Taşeron personeli" seçilince taşeron zorunlu olur; telefon alanının altındaki KVKK notu görünür.
- [ ] Ekipler → Kalıp Ekibi → "Üye ekle": seçicide yalnızca o taşeronun personeli var. Bir üyeyi sola kaydırıp "Bugün ayrıldı": kişi "Üyelik geçmişi"ne geçer, silinmez.
- [ ] Ayrılan kişiyi başka bir ekibe bugünden önceki bir tarihle eklemeyi deneyin: "aynı anda yalnızca bir ekipte" mesajı.
- [ ] Projeler → Sivas → "Ekip ve personel": "Bugün sahada" listesi, projedeki taşeron, devam eden görevlendirmeler. "+" ile Elektrik Ekibi'ni görevlendirin (tür → ekip → seç → Görevlendir: 3 dokunuş).
- [ ] Aynı ekibi aynı projeye tekrar görevlendirmeyi deneyin: "aynı tarihlerde zaten görevlendirme var".
- [ ] `sef@example.test`: Taşeronlar/Personel/Ekipler yalnızca kendi projelerindeki kayıtları gösterir; "+" (yeni kart) düğmesi yok; personel telefonu görünür.
- [ ] `muhasebe@example.test`: personel listesi görünür, personel detayında **İletişim bölümü yok**.
- [ ] Açık/koyu tema ve en büyük metin boyutunda yeni ekranlar okunaklı; satırlar kesilmiyor.

### Aşama 3: puantaj

Seed verisi Sivas projesinde Ekim 2026 için Pazar hariç dünkü güne kadar
puantaj içerir (Kalfa 7-8'inde raporlu, Demir Ustası 14'ünde yarım gün, Usta
10'unda 2 saat fazla mesai, Tekniker 29'unda resmî tatil).

- [ ] `sef@example.test` → Ana ekran → Puantaj → Sivas: ay tablosu açılır; ad sütunu sabit, günler yatay kayar ve **gün başlığı gövdeyle birlikte kayar** (en kritik kontrol).
- [ ] Tablo açılışta bugünün sütununa yakın konumlanır; bugün çerçeveli, Pazar sütunları gri.
- [ ] Boş bir hücreye dokunun → durum sayfası; "Tam gün"e dokununca kaydedip kapanır, hücrede "T" görünür.
- [ ] Gelecek bir güne "Tam gün" yazmayı deneyin: Türkçe hata mesajı. Görevli olmayan (gri) hücre açılmaz.
- [ ] "Gün" görünümüne geçin: kişiler ekiplerine göre gruplu; alt bilgide "henüz işlenmedi" sayısı.
- [ ] İşlemler → Toplu işle: bir gün seçip Kalıp Ekibi'ne "Tam gün"; önizlemede eklenecek / korunacak hücreler ayrı listelenir; mevcut kayıtlar "üzerine yaz" açılmadan değişmez.
- [ ] Toplu işle → "Önceki günü kopyala": önizlemede kaynak gün ve hedef gün, fazla mesai kopyalanmaz.
- [ ] İşlemler → Aylık özet: Kişi / Ekip / Proje sekmeleri; hiçbir yerde para tutarı yok; ücretli ve ücretsiz izin ayrı satırlarda.
- [ ] İşlemler → Ay durumu: şef "İncelemeye gönder"i görür, "Onayla"yı görmez. Gönderdikten sonra hücreye dokunmak düzenleme açmaz.
- [ ] `yonetici@example.test`: Ay durumu → Onayla → Kilitle; tablo kilitli uyarısı gösterir. "Yeniden aç" gerekçe (en az 10 karakter) ister; revizyon 1 olur, geçmişte tüm olaylar görünür.
- [ ] `muhasebe@example.test`: puantajı görür ama düzenleyemez ve onaylayamaz.
- [ ] Önceki/sonraki ay okları çalışır; Eylül'de kayıt yoktur ve boş hücreler devamsızlık sayılmaz.
- [ ] Koyu tema ve en büyük metin boyutunda tablo ve gün görünümü okunaklı; VoiceOver hücreyi "ad, tarih: durum" olarak okur.
- [ ] Cari ekranlarında puantaj nedeniyle yeni hareket oluşmadığını kontrol edin.

## 5. Otomatik testler

```bash
cd ios/RDCore
swift test --filter "RDCoreTests|RDDesignTests" # model, doğrulama, yetki, ViewModel, tasarım token'ları
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
- Uygulama ikonu ve logo boştur; orijinal dosyalar bekleniyor (docs/brand-assets.md).
