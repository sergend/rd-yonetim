# Karar 0009: Aşama 8 kararları (onaylanan iPhone arayüzü ve logo)

Tasarım önce tıklanabilir taslak olarak hazırlandı ve onaylandı; bu aşama yalnızca
iPhone arayüzünü değiştirir. Veritabanı, migration ve RPC değişmedi.
Testler: `ios/RDCore/Tests/RDCoreTests/DashboardReportTests.swift`,
`ios/RDCore/Tests/RDDesignTests/TokenTests.swift` (`HomeScreenRuleTests`).

| # | Karar | Gerekçe |
| --- | --- | --- |
| 1 | Orijinal RD logosu eklendi: `RDLogo` (sloganlı), `RDLogoWordmark` (yatay), `RDLogoMark` (RD) ve uygulama ikonu. Renkleri değiştirilmedi; koyu temada logo beyaz zemin üzerinde gösterilir | Siyah D koyu zeminde kaybolur; resmi koyu sürüm gelene kadar logo bozulmadan okunur. |
| 2 | Marka kırmızısı logodan alındı: #CB010E (önceki geçici değer #C8102E). Kontrast testleri geçer | Brand-assets'te öngörülen adım. |
| 3 | Alt sekme çubuğu: Ana Sayfa, Projeler, +, Cari, Raporlar. Her sekmenin kendi gezinme yığını vardır; sekmeler ve + seçenekleri izne göre görünür | Sık kullanılan bölümler tek dokunuşta; yetkisiz giriş noktası gösterilmez. |
| 4 | **Ürün kuralı değişti:** ana sayfa artık seçili ayın onaylı gider maliyetini (kategori dağılımıyla), bekleyen ödemeleri, açık hakedişleri, yaklaşan ödemeleri ve proje maliyetlerini gösterir. Kasa, banka veya cari bakiyesi yine gösterilmez (`HomeScreenRuleTests`) | Kullanıcı onayı. Odak genel kasa değil proje maliyeti ve borç takibidir. |
| 5 | Ana sayfa tutarları mevcut RPC'lerden gelir: `finance.report(kategori)`, `openStatuses(gider)`, `hakedisList`, `projectCosts`. Her bölüm kendi iznine bağlıdır; okunamayan bölüm gizlenir, ekranın geri kalanı çalışır | Yeni sunucu hesabı yok; izin kuralları sunucuda kalır. |
| 6 | Proje detayı sekmelidir (Özet, Giderler, Taşeronlar, Puantaj, Hakediş, Cari). Sekmeler mevcut proje süzgeçli ekranları kullanır; Özet'te gider ve hakediş maliyeti ayrı satırlardadır | Modül ekranları tekrar yazılmadı. |
| 7 | Ay sonu hakediş raporu salt okunurdur: taşeron özeti (sunucunun hesapladığı brüt, kesinti, ödemeye uygun), hakedişe bağlanan puantaj günlerinden kişi takvimleri ve toplamlar. Kişi tutarı = gün × sözleşmedeki günlük birim fiyat; hakediş toplamının yerine geçmez | Puantaj, hakediş ve ödeme ilişkisi tek sayfada görülür; hesap kaynağı değişmez. |
| 8 | Rapor PDF'i cihazda `ImageRenderer` ile tek sayfa, açık temada üretilir ve paylaşılır | Ek kütüphane yok. |
