# Marka görselleri: hazırlık noktası

**Durum: orijinal RD logosu (kırmızı R, siyah D) depoda YOK.** Uygulamada logo
yerine yalnızca "RD Projeler" adı sistem yazı tipiyle yazılır. Logo taklit
edilmez, harfler başka yazı tipiyle çizilmez, geçici logo üretilmez. Uygulama
ikonu da boştur.

## Gerçek dosyalar gelince

| Dosya | Yer | Biçim |
| --- | --- | --- |
| Logo (uygulama içi) | `ios/RDYonetim/Assets.xcassets/RDLogo.imageset/` | Tercihen vektör PDF veya SVG (tek dosya, "Preserve Vector Data" açık). Yoksa 1x/2x/3x PNG, saydam zemin |
| Logo, koyu tema sürümü | Aynı görsel setine "Dark" görünümü olarak | Siyah D koyu zeminde görünmeyeceği için açık renkli D'li resmi sürüm gerekir. Marka sahibinden istenmeli, kendimiz renk değiştirmemeliyiz |
| Uygulama ikonu | `ios/RDYonetim/Assets.xcassets/AppIcon.appiconset/` | 1024 × 1024 PNG, saydamlık yok, köşeler yuvarlatılmamış (iOS kendisi yuvarlar) |

Adımlar:

1. Dosyaları yukarıdaki yerlere koyun (Xcode'da görsel setine sürükleyin).
   `RDBrandMark` logoyu kendiliğinden gösterir, kod değişikliği gerekmez.
2. Marka kırmızısının kesin değerini logodan (veya kurumsal kimlik kılavuzundan)
   alın, `ios/RDCore/Sources/RDDesign/Tokens.swift` içinde `Palette.brand` ve
   `Palette.brandText` değerlerini, `AccentColor.colorset` değerini güncelleyin.
3. `cd ios/RDCore && swift test --filter RDDesignTests` çalıştırın. Kontrast
   testleri geçmezse (ör. kırmızı koyu zeminde okunmuyorsa) `brandText.dark`
   için daha açık bir ton seçilir; `brand` (dolgu) logo rengiyle kalabilir.
4. Açık ve koyu temada giriş ve ana sayfa önizlemelerini kontrol edin.
