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

### Aşama 4: sözleşme ve hakediş

Seed verisi Sivas projesinde `DEMO-S-001` sözleşmesini içerir: kalıp 2.400 m² ×
450 ₺, beton 900 m³ × 280 ₺, teminat %10. Eylül hakedişi onaylı ve deftere
işlenmiş (brüt 312.000, teminat 31.200, avans mahsubu 50.000, ödemeye uygun
230.800, ödenen 150.000, kalan 80.800); Ekim hakedişi incelemede.

- [ ] `muhasebe@example.test` → Ana ekran → Taşeron sözleşmeleri → DEMO-S-001: finans özetinde brüt, kesilen teminat, ödemeye uygun, gerçekleşen ödeme ve kalan **ayrı satırlarda**; hiçbir satır "ödendi" diye toplanmıyor.
- [ ] 1 nolu hakediş: "Hak edilen", "Kesilen", "Ödeme" bölümleri ayrı; ödeme durumu "Kısmen ödendi", kalan 80.800,00 ₺.
- [ ] "Ödeme kaydet" → "Kalanın tamamı" → kaynak seçin → kaydedin: durum "Ödendi"; kalanı aşan tutar Kaydet'i kapatır.
- [ ] 2 nolu (incelemede) hakedişte muhasebe "Onayla"yı görmez; `yonetici@example.test` görür. Onay onay sorusu ile yapılır, ardından "Cari deftere işle" ayrı adımdır.
- [ ] Cari hesaplar → Örnek Kaba İnşaat Taşeronu: hakediş alacağı ve teminat kesintisi borcu ayrı hareketler; teminat iadesi yeni "Teminat iadesi" türüyle görünür.
- [ ] Sözleşme → "Teminat serbest bırak": biriken tutardan fazlası girilemez; gerekçe en az 10 karakter. İade satırı "Ödenmedi" gösterir; sola kaydırıp "Öde" ile ödeme ayrıca kaydedilir.
- [ ] Sözleşme → "Revizyon aç" → fiyatı değiştirip onaylayın: eski hakedişlerin tutarı değişmez.
- [ ] Yeni sözleşme formu: yalnızca cari kartı bağlı taşeronlar listelenir; birim fiyat / günlük / götürü kalemler aynı sözleşmeye eklenebilir; %5/10/15/20 veya başka teminat oranı.
- [ ] `sef@example.test` → Ana ekran: "Taşeron sözleşmeleri" ve "Hakediş" modülleri **görünmez**; "İmalat (metraj)" görünür. Sivas → kalemler fiyatsız; miktar girilir, "Tümünü onayla" görünmez.
- [ ] Ana ekranda hiçbir para tutarı, kasa veya banka bakiyesi yok.
- [ ] Hakediş detayı koyu temada ve en büyük metin boyutunda okunaklı; VoiceOver tutar satırlarını "eklenir/düşülür" ile okur.
- [ ] USD sözleşme açın (para birimi USD): "Cari deftere işle" kur sorar; kur boşken kaydedilemez. Ödeme ve teminat iadesi sayfalarında "Kur (1 USD = ? ₺)" alanı görünür, boşken Kaydet kapalıdır; TL sözleşmede bu alan görünmez.
- [ ] Aynı ödemeyi çift dokunuşla iki kez gönderin: tek ödeme oluşur.
- [ ] Sözleşme bedeli girilmeden onaylanan sözleşmede "Avans ver" yerine "Sözleşme bedeli tanımlı olmadığı için avans verilemez" yazar; bedelli sözleşmede avans sayfası kalan tavanı gösterir, aşan tutar Kaydet'i kapatır.

### Aşama 5: gider, gelir ve borç

Seed verisi (tutarlar hayalidir): `GD-000001` demir faturası 240.000 ₺ (cari
bağlantılı, 100.000 ödenmiş, vadesi geçmiş), `GD-000002` akaryakıt 4.250,50 ₺
(Kürşat kartıyla peşin), `GD-000003` ofis gideri 1.830 ₺ (onay bekliyor),
`GD-000004` nakliye 12.500 ₺ (vadesi 5 gün sonra), `GL-000005` daire ara ödemesi
750.000 ₺ (250.000 tahsil edilmiş).

- [ ] `muhasebe@example.test` → Ana ekran → Giderler: dört gider; demir satırında "Vadesi geçti · Kısmen ödendi" ve "Kalan 140.000,00 ₺"; akaryakıt "Tamamen ödendi"; ofis gideri "Onay bekliyor".
- [ ] Üstteki hızlı filtreler (Onay bekleyen, Ödenmemiş, Vadesi geçmiş…) ve arama (açıklama, fatura no "DMR", cari adı, kategori) doğru sonuç veriyor.
- [ ] + ile yeni gider: yalnızca tutar, kategori, açıklama ve proje doldurulup kaydedilebiliyor; "Kaydet ve yeni" formu temizleyip kategori ve projeyi koruyor. Kayıt "Onay bekliyor" olarak listede.
- [ ] Yeni gider → "Vade, cari, fatura ve döviz": USD seçince kur alanı çıkıyor, kur boşken Kaydet kapalı; vade belge tarihinden önce seçilemiyor.
- [ ] Demir faturası detayı: Gider tutarı, Ödenen, Kalan borç ayrı satırlarda; ödeme geçmişinde 100.000 ₺ "Şirket ödemesi (demo)".
- [ ] "Ödeme kaydet" → 40.000 → kaynak → Kaydet: durum "Kısmen ödendi", kalan 100.000; kalanı aşan tutar Kaydet'i kapatıyor. Hızlı çift dokunuş tek ödeme oluşturuyor.
- [ ] Ödeme satırını sola kaydırıp "İptal": gerekçe en az 10 karakter; iptal edilen ödeme listede "İptal" etiketiyle kalıyor, kalan geri artıyor.
- [ ] Muhasebe ofis giderinde "Onayla"yı **görmüyor**; `yonetici@example.test` görüyor ve onay sorusunda tutar ve "borç olarak kaydedilir" yazıyor.
- [ ] Yönetici → onaylı ve ödemesiz nakliye gideri → "Düzelt": eski belge İptal, yeni taslak açılıyor ve "Yerine açılan belge" bağlantısı çıkıyor.
- [ ] Ana ekran → Bekleyen borçlar: "Vadesi geçmiş", "7 gün içinde", "Daha sonra" grupları ve her grubun kalan toplamı; tamamen ödenmiş akaryakıt listede yok.
- [ ] Ana ekran → Gelir ve tahsilat → GL-000005: "Kısmen tahsil edildi", kalan alacak 500.000; tahsilat kaydı çalışıyor.
- [ ] Cari hesaplar → Örnek Demir Tedarikçisi: gider alacağı bir kez, her ödeme ayrı hareket; akaryakıt (carisiz) hiçbir caride görünmüyor, Kürşat adına borç yok.
- [ ] Raporlar → Gider → Kategori / Ay / Ödeme kaynağı / Tedarikçi: tahakkuk, ödenen, kalan ve vadesi geçmiş ayrı; "Ödeme kaynağı"nda Kürşat kartı satırı.
- [ ] Raporlar → Proje maliyeti → Sivas: gider, hakediş ve gelir ayrı bölümler; "Verilen avans" ayrı satır ve "ödeme değildir" açıklaması; hakediş tutarları gider satırlarına eklenmemiş.
- [ ] Giderler → filtre menüsü → "Kategorileri yönet": yeni kategori ekleme, pasif yapma; pasif kategori yeni gider formunda çıkmıyor.
- [ ] `sef@example.test` → Ana ekran: yalnızca "Giderler" görünür ("Bekleyen borçlar", "Gelir ve tahsilat", "Raporlar" görünmez). Listede muhasebenin girdiği giderler yok; "Peşin ödendi" + Kürşat kartı ile gider girebiliyor; kendi giderinde "Onayla" ve "Ödeme kaydet" yok.
- [ ] Ana ekranda hiçbir para tutarı, kasa veya banka bakiyesi yok.
- [ ] Gider listesi ve detayı koyu temada ve en büyük metin boyutunda okunaklı; VoiceOver durum rozetini ve kalan tutarı okuyor.

### Aşama 6: evrak ve belge arşivi

Seed verisinde belge yoktur; adımlar boş arşivle başlar. `supabase start`
Storage'ı ve Edge Function çalışma ortamını da başlatmalıdır (varsayılan;
`-x storage-api` veya `-x edge-runtime` kullanmayın): yükleme `belge-dogrula`
fonksiyonu dosyanın SHA-256 özetini sunucuda doğrulamadan tamamlanmaz. Belge
tarayıcı (VisionKit) **Simülatörde çalışmaz**: orada "Tara" düğmesi görünmez,
fotoğraf ve dosya seçimiyle devam edilir. Tarama adımları gerçek iPhone ister.

- [ ] `sef@example.test` → Projeler → Sivas → "Proje belgeleri" → + → "Fotoğraf seç": fotoğraf önizlemede görünüyor (yakınlaştırılabiliyor), tür varsayılan "İrsaliye"; tür listesinde Fatura, Fiş ve Sözleşme **yok**. Ad girip "Yükle": adımlar (Sunucuya bildiriliyor → Dosya gönderiliyor → Doğrulanıyor) ve belge listede.
- [ ] Belgeye dokun: dosya açılıyor, "Dosya doğrulandı (SHA-256 eşleşti)" yazıyor, Geçmiş'te "Yükleme başlatıldı" ve "Dosya yüklendi ve doğrulandı".
- [ ] Not: aynı boyut ve türde farklı içerik (sunucu özeti uyuşmaz) ve indirilen dosyanın bozuk olması elle kolay üretilemez; bu senaryolar otomatik testlerdedir (pgTAP `111_evrak_sunucu_ozet`, Swift `DocumentServerDigestTests` ve gerçek Storage'a karşı entegrasyon testi). Eşleşmeyen dosya ayrıntı ekranında gösterilmez; hata ve "Tekrar dene" çıkar.
- [ ] Gerçek iPhone: + → "Tara" → üç sayfa tara → Kaydet: tek PDF olarak önizlemede üç sayfa; yüklenince ayrıntıda sayfalar kaydırılıyor ve yakınlaştırılıyor.
- [ ] + → "Dosya seç (PDF)": Dosyalar'dan PDF seçiliyor. Uzantısı `.pdf` olan ama içi PDF olmayan dosya "Bu dosya türü desteklenmiyor" hatası veriyor; 25 MB'tan büyük dosya boyut hatası veriyor.
- [ ] Aynı fotoğrafı aynı projeye ikinci kez yüklemek "Bu dosya bu kayda zaten eklenmiş" hatası veriyor.
- [ ] Yükleme sırasında uçak modunu aç: hata ve "Tekrar dene" çıkıyor. "Kapat" → "Sakla, sonra dene": belge listesinde "Gönderilmeyi bekleyenler" altında. Uygulamayı kapatıp aç, uçak modunu kapat, "Tekrar dene": belge **bir kez** yükleniyor.
- [ ] `muhasebe@example.test` → Giderler → GD-000001 (demir) → Belgeler bölümü → "Belge ekle": tür varsayılan "Fiş"; fatura PDF'i yükle. Detaydaki tutar, ödenen, kalan ve durum **değişmedi**; cari hesapta yeni hareket yok.
- [ ] `sef@example.test`: Sivas belgelerinde muhasebenin yüklediği fatura/fiş **görünmüyor**; şefin yüklediği irsaliye görünüyor.
- [ ] Ana ekran → Belgeler: Proje, tür ve tarih süzgeci ile arama (ad, açıklama) çalışıyor; "Arşiv" ve "İptal" sekmeleri.
- [ ] Muhasebe → bir belge → "Arşivle" (gerekçe): Etkin listeden kalkıp Arşiv'de. "İptal et" (gerekçe en az 10 karakter): İptal sekmesinde, geçmişte gerekçe görünüyor; dosya hâlâ açılabiliyor.
- [ ] "Dosyayı değiştir": yeni dosya yüklenince eski belge "Yeni dosyayla değiştirildi" gerekçesiyle İptal'de, yenisi Etkin'de.
- [ ] Proje müdürü veya yönetici → proje belgesi → "Bağlantıyı düzelt" → başka demo proje + gerekçe: belge yeni projede; geçmişte "Bağlantısı değiştirildi".
- [ ] Taşeron sözleşmesi detayında "Belgeler" bölümü; sözleşme dosyası eklenebiliyor.
- [ ] Ana ekranda hiçbir para tutarı, kasa veya banka bakiyesi yok; logo ve ikon değişmedi.
- [ ] Belge ekranları koyu temada ve en büyük metin boyutunda okunaklı; VoiceOver "Tara", "Fotoğraf seç", "Dosya seç" ve durum rozetlerini okuyor.

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
- Belge tarama (VisionKit kamera), fotoğraf seçici, Dosyalar seçici, PDF
  görüntüleme ve yakınlaştırma hiçbir cihazda denenmedi; yalnızca derleme
  (CI) ve RDCore testleri (doğrulama, özet, yükleme/yeniden deneme) çalıştı.
- Uygulama ikonu ve logo boştur; orijinal dosyalar bekleniyor (docs/brand-assets.md).
