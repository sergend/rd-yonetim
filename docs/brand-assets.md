# Marka görselleri

**Durum: orijinal RD Projeler logosu (kırmızı R, siyah D, "Geleceğe Değer"
sloganı) uygulamada.** Kaynak dosya kullanıcının paylaştığı PNG'dir; renkleri
değiştirilmedi, yalnızca kırpıldı ve boyutlandırıldı.

| Görsel seti | İçerik | Kullanıldığı yer |
| --- | --- | --- |
| `ios/RDYonetim/Assets.xcassets/RDLogo.imageset` | Sloganlı tam logo (1x/2x/3x PNG, saydam) | Giriş ve açılış ekranı (`RDBrandMark`), ay sonu hakediş raporu ve PDF başlığı |
| `RDLogoWordmark.imageset` | Sloganı olmayan yatay logo | Ana sayfa üst bandı |
| `RDLogoMark.imageset` | Yalnızca RD harfleri | Küçük alanlar için hazır |
| `AppIcon.appiconset/AppIcon.png` | 1024 × 1024, beyaz zemin üzerinde RD harfleri | Uygulama ikonu |

Kod tarafı `ios/RDYonetim/Design/BrandMark.swift`: `RDBrandMark` (giriş) ve
`RDLogoImage(kind:height:)` (diğer yerler).

## Koyu tema

Logonun D harfi siyahtır ve koyu zeminde kaybolur. Resmi koyu tema sürümü
olmadığı için logo koyu temada **beyaz yuvarlatılmış zemin üzerinde**
gösterilir; renkler değiştirilmez. Marka sahibinden açık renkli D'li resmi
sürüm gelirse görsel setlerine "Dark" görünümü olarak eklenir ve
`RDLogoImage` içindeki beyaz zemin kaldırılır.

## Marka kırmızısı

Logodan ölçülen değer **#CB010E**; `Palette.brand`, `Palette.brandText` (açık) ve
`AccentColor` bu değerdedir. Değiştirilirse `cd ios/RDCore && swift test --filter
RDDesignTests` kontrast ve eşleşme testlerini çalıştırır.

## Vektör dosya gelirse

PDF veya SVG logo gelirse aynı görsel setlerine tek dosya olarak konur
("Preserve Vector Data" açık) ve PNG'ler kaldırılır; kod değişmez.
