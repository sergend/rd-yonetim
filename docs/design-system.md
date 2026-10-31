# RD Projeler tasarım sistemi

Kullanıcıya görünen ad **RD Projeler**. Depo, klasör ve Xcode hedefi adı
(`RDYonetim`) değişmedi.

## Katmanlar

| Yer | İçerik |
| --- | --- |
| `ios/RDCore/Sources/RDDesign/Tokens.swift` | Platformdan bağımsız token'lar: renk (açık/koyu), boşluk, köşe, dokunma alanı, durum tonları. Linux'ta test edilir. |
| `ios/RDCore/Sources/RDDesign/Tones.swift` | Alan durumlarının (proje durumu, iş önceliği, bakiye yönü) tonu, tek yerde |
| `ios/RDYonetim/Design/Theme.swift` | Token'ların SwiftUI karşılığı: `RDColor`, `RDFont`, `.rdS/.rdL…` boşlukları, `rdScreen()` |
| `ios/RDYonetim/Design/*.swift` | Bileşenler (aşağıda) |
| `ios/RDYonetim/Preview Content/PreviewSupport.swift` | Ekran ve bileşen önizlemeleri ("Tasarım sistemi" galerisi dahil) |

Kural: ekranlar sabit renk, punto veya boşluk yazmaz; `RDColor`, `RDFont`,
`Spacing`/`Radius`/`Metrics` ve aşağıdaki bileşenleri kullanır.

## Renk

| Token | Açık | Koyu | Kullanım |
| --- | --- | --- | --- |
| `brand` | #C8102E | #C8102E | Birincil buton dolgusu (beyaz metinle) |
| `brandText` | #C8102E | #F0565C | Kırmızı metin/ikon: bağlantı, seçili durum, modül ikonları; uygulama `tint`'i ve `AccentColor` |
| `background` | #F2F2F7 | #000000 | Sayfa zemini |
| `surface` | #FFFFFF | #1C1C1E | Liste bölümü yüzeyi |
| `textPrimary` | #111114 | #F5F5F7 | Ana metin (AAA kontrast) |
| `textSecondary` | #5C5C66 | #A1A1AA | İkincil metin |
| `success / warning / danger / info / neutral` | | | Durum etiketleri ve bakiye yönü |

- **Marka kırmızısı geçicidir.** Kesin değer orijinal logodan alınınca yalnızca
  `Palette.brand` ve `Palette.brandText` değiştirilir; `AccentColor` görsel seti
  de aynı değere getirilir (test eşleşmeyi denetler).
- Kırmızı yalnızca marka vurgusu ve birincil etkileşimdedir: ekran başına bir
  birincil buton, bağlantılar, modül ikonları. Gövde metni ve yüzeyler nötrdür.
  Koyu temada kırmızı metin daha açık tondadır (#F0565C), çünkü #C8102E koyu
  zeminde okunmaz.
- Hata rengi (`danger`, #B42318) marka kırmızısından ayrıdır; hata ile marka karışmaz.
- `swift test` (RDDesignTests) her renk çifti için WCAG 2.1 AA kontrastını
  denetler: metin ≥ 4.5, buton dolgusu ile zemin ≥ 3, ana metin ≥ 7.
  Geçmeyen bir token değeri CI'da kırmızıya düşer.

## Tipografi

Yalnızca Dynamic Type metin stilleri kullanılır (`RDFont`): ekran başlığı
`largeTitle` kalın, bölüm `title3` yarı kalın, satır başlığı `body` yarı kalın,
ikincil `subheadline`, açıklama `footnote`, sayı `title2` kalın ve eşit genişlikli
rakam. Sabit punto yoktur; yazı boyutu büyüdüğünde satırlar (`RDRow`,
`RDInfoRow`, ana sayfa özeti) `ViewThatFits` ile alt alta dizilir.

## Boşluk, köşe, dokunma alanı

- Boşluk 4 pt tabanlı: 4, 8, 12, 16, 24, 32; ekran kenarı 16.
- Köşe: 8 (etiket), 12 (alan, buton), 16 (yüzey).
- Dokunulabilir her öğe en az 44 × 44 pt; birincil buton ve giriş alanı 50 pt.
- Gölge kullanılmaz. Yüzeyler iOS'un gruplu liste düzeniyle tek katmandır
  (kart yığını yok). Animasyon yalnızca sistemin varsayılanlarıdır.

## Bileşenler

| Bileşen | Ne zaman |
| --- | --- |
| `RDPrimaryButton`, `.buttonStyle(.rdPrimary)` | Ekranın tek ana eylemi (Giriş yap, Hareket ekle) |
| `.buttonStyle(.rdSecondary)` | İkincil eylem (Tekrar dene) |
| `RDTextField` | Form dışı alan: etiket üstte, hata altta (giriş ekranı). Form içinde sistem `TextField` kullanılır |
| `RDFormMessage` | Form içinde doğrulama veya sunucu hatası |
| `RDStatusBadge(tone:)`, `RDDemoBadge` | Durum etiketi; renk tek başına anlam taşımaz, metin her zaman yazılır. Demo kayıtlar her yerde DEMO etiketiyle görünür |
| `RDStateView` ve `.rdContentState(...)` | Liste ekranlarında yükleniyor, boş ve "Tekrar dene"li hata durumu |
| `RDErrorBanner` | İçerik varken oluşan hata (ör. yenileme başarısız) |
| `RDSectionHeader` | Bölüm başlığı ve isteğe bağlı "Tümü" bağlantısı |
| `RDRow`, `RDInfoRow` | Liste satırı (ikon, başlık, etiketler, alt bilgi, sağ içerik); etiket–değer satırı |
| `RDAmount` | TL tutar; `showsSide` bakiye yönünü renk ve VoiceOver metniyle verir. **Yalnızca finans ekranlarında** |
| `RDBrandMark` | Logo ve uygulama adı (bkz. [brand-assets.md](brand-assets.md)) |

Yeni bileşen yalnızca en az iki ekranda kullanılacaksa eklenir.

## Ekranlarda yapılan değişiklikler (Aşama 1.5)

İşlevler ve veri akışı değişmedi; yalnızca görünüm ve dokunuş sayısı.

- **Giriş:** marka alanı, üstte etiketli alanlar, tek kırmızı birincil buton,
  yükleniyor göstergesi butonun içinde, klavyede "İleri" ile şifreye geçiş.
- **Ana sayfa:** başlık "RD Projeler"; selamlama ve tarih; özet sayılar (aktif
  proje, açık iş, bana atanan, geciken). Kartlar yerine gruplu liste: aktif
  projeler (en fazla 5), bana atanan işler, modüller, "Sonraki aşamalarda".
  **Tutar, kasa veya banka bakiyesi yok**. `HomeScreenRuleTests` yalnızca
  kaynak kodu tarar; gerçek ekrandaki doğrulama `docs/ios-mac-setup.md`
  elle test listesindedir.
- **Projeler / proje detayı:** ortak `ProjectRow`; detayda durum ve demo etiketi,
  bilgi satırları, açık işler, yetkiliyse finans bağlantısı.
- **Cari listesi:** tür ve bakiye kapsamı filtreleri araç çubuğundaki "Filtre"
  menüsünde (liste daha sade); bakiye yön rengiyle.
- **Cari detay:** güncel bakiye ve "Hareket ekle" en üstte (önceden araç
  çubuğunda simgeydi); filtre katlanabilir ve özetini gösteriyor; hareket
  satırında Borç/Alacak yazıyla; kart bilgileri en altta, kopyalanabilir.
- **İş takibi:** daire simgesine tek dokunuşla tamamlama (önceden kaydırma
  gerekiyordu); "Başladı" kaydırmayla; filtreler menüde; gecikmiş tarih kırmızı.
- **Genel giderler:** ortak satır bileşeni ve durum ekranları.

## Aşama 2 ekranları

Yeni ekranlar yeni bileşen kütüphanesi kurmaz; Aşama 1.5 bileşenlerini kullanır.
Yalnızca bu ekranlarda tekrar eden küçük parçalar `RDYonetim/Workforce/WorkforceShared.swift`
dosyasındadır: `PeriodBadge` (Başlayacak / Devam ediyor / Bitti), `RecordBadges`
(DEMO, Pasif), `RecordHeader` (kart başlığı), `PhoneRow` (dokununca arama),
`TradePicker`, `InactiveFilterMenu`, `SheetToolbar` (Vazgeç / onay).

- **Taşeronlar / Personel / Ekipler:** arama, araç çubuğunda filtre menüsü,
  pasif kayıtlar varsayılan olarak gizli. "+" yalnızca kart yazma izni olanda.
- **Taşeron detayı:** cari kart bağlantısı (göremeyen kullanıcıya kilitli not),
  çalıştığı projeler, ekipler, personel, belgeler; tutar yok.
- **Personel detayı:** iletişim bölümü yalnızca iletişim izni olana; ekip geçmişi
  ve görevlendirmeler dönem etiketiyle.
- **Ekip detayı:** "Ekipte şu an" ve "Üyelik geçmişi" ayrı; ayrılış sola kaydırma
  ile (silmez, bitiş tarihi yazar).
- **Proje → Ekip ve personel:** bugün sahada olanlar, projedeki taşeronlar,
  devam eden ve geçmiş görevlendirmeler. Görevlendirme sayfası: tür (ekip/kişi)
  → seç → Görevlendir; başlangıç bugün, bitiş isteğe bağlı.
- Formlarda zorunlu alan yalnızca ad; diğer her şey isteğe bağlı. Sayfalar
  `.medium` boyutta açılır, tek elle kullanılabilir.

## Aşama 3 ekranları (puantaj)

Ortak parçalar `RDYonetim/Puantaj/PuantajShared.swift` dosyasındadır:
`PuantajCellLabel` (durum harfi, fazla mesai noktası, görevsiz gün soluk),
`PuantajLegend`, `PuantajMonthBar` (‹ ay ›, ay durumu, revizyon) ve `PuantajNotice`.

- **Renk tek başına anlam taşımaz:** her durumun kısa harfi vardır (T, Y, Ç, Üİ,
  İ, R, RT) ve tonu `StatusTone` üzerinden gelir: tam gün başarı, yarım gün
  bilgi, çalışmadı tehlike, ücretli izin ve rapor uyarı, ücretsiz izin ve resmî
  tatil nötr. Henüz işlenmemiş gün "·" ile gösterilir.
- **Ay tablosu:** ad sütunu sabit; gün başlığı ve gövde aynı gün sütununa
  bağlı iki yatay kaydırma alanıdır. Hücre boyutları `@ScaledMetric` ile metin
  boyutuna göre büyür; ad sütunu ekranın yarısını geçmez.
- **Gün görünümü:** küçük ekranda daha okunaklı alternatif; kişiler ekiplerine
  göre gruplanır, satır `RDRow` + `RDStatusBadge`.
- **Hızlı giriş:** hücre sayfasında duruma tek dokunuş kaydeder ve kapatır
  (dokunsal geri bildirimle). Fazla mesai ve not ayrı açılır bölümdedir.
- **Toplu işlem:** her zaman önizleme ve onay; korunan kayıtlar ayrı listelenir.
- **Özet:** yalnızca gün ve saat sayıları; para yok, kategoriler birleştirilmez.
