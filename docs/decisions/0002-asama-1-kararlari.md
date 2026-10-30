# Karar 0002: Aşama 1 kararları (iOS iskeleti, proje, cari)

| # | Karar | Gerekçe |
| --- | --- | --- |
| 1 | Cari defter yalnızca eklenir; değiştirme ve silme trigger ile veritabanı sahibine bile kapalı, düzeltme ters kayıtla | Finansal geçmiş geri alınamaz şekilde korunur; audit log'a ek olarak defterin kendisi kanıttır. |
| 2 | Bakiye saklanmaz, her sorguda hareketlerden hesaplanır | Elle düzenlenebilir bakiye alanı ve senkron dışı kalma riski olmaz. |
| 3 | Hareket kimliği istemcide üretilir; aynı kimlikle aynı içerik tekrar gelirse mevcut kayıt döner | Şantiyede zayıf bağlantıda "Kaydet"e iki kez basmak ikinci borç oluşturmaz. |
| 4 | Kaynak belgeden gelen hareketler için `(source_type, source_id)` benzersiz; bu hareketler cariden iptal edilemez | Revizyon 1-R5: hakediş/gider gibi bir belge deftere bir kez işlenir; iptali kendi modülünden yapılır (Aşama 2+). |
| 5 | Kısmi ödeme ve avans mahsubu `cari_allocations` ile; eşleştirme toplamı hareket tutarını aşamaz | Bakiye hesabını değiştirmeden "hangi ödeme hangi hakedişi kapattı" sorusu cevaplanır. Arayüzü sonraki aşamada (hakediş ile) gelecek. |
| 6 | Finans okuması ayrı izinlerdir (`cari_hareket.read`); şantiye şefi ve görüntüleyici şablonlarında yoktur | Proje erişimi finans erişimi anlamına gelmez; gerekirse kullanıcıya özel proje izniyle açılır. |
| 7 | Demo kayıtlar `is_demo` ile işaretlenir; demo ve gerçek kayıt aynı harekette kullanılamaz, işaret sonradan değişmez | Deneme/eğitim verisi gerçek bakiyelere karışmaz. |
| 8 | iOS kodu `RDCore` paketinde, SwiftUI'dan bağımsız | Model, doğrulama, yetki ve ViewModel mantığı Mac olmadan GitHub Actions'ta (Linux) test edilir. |
| 9 | Tek dış bağımlılık supabase-swift | Bakım yükü ve tedarik zinciri riski düşük tutulur. |
| 10 | `[auth.email] enable_signup = true`, `[auth] enable_signup = false` | Aşama 0 ayarı e-posta sağlayıcısını tümden kapatıp girişi de engelliyordu; kayıt hâlâ kapalıdır (yalnızca davet). |
