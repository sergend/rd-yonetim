# Malzeme, stok ve satın alma kuralları (Aşama 7)

Bu belge stok miktarının nasıl hesaplandığını, satın almanın finansla nasıl
ilişkilendiği ve hangi işlemin neyi değiştirmediğini anlatır. Kurallar
veritabanındadır (`supabase/migrations/20261108000000_malzeme_stok_satinalma.sql`);
uygulama yalnızca gösterir ve ön kontrol yapar.

## Stok miktarı

- Stok hiçbir tabloda elle tutulmaz. Her onaylı hareket değiştirilemez stok
  defterine (`stock_entries`) işaretli satır yazar; miktar bu satırların
  toplamıdır (`v_stock_balances`). Düzenlenebilir bir "bakiye" alanı yoktur.
- Miktarlar malzemenin **temel biriminde** saklanır (ör. demir kg). Başka birimle
  giriş yalnızca açıkça tanımlı oranla yapılır: "1 ton = 1000 kg". Oran tahmin
  edilmez; oranı olmayan birimle hareket reddedilir. Kullanılan oran harekete ve
  sipariş satırına kopyalanır, oran sonradan pasifleşse bile geçmiş değişmez.
- Birimin izin verdiği ondalık hane zorunludur (adet ve torba tam sayı, kg ve m³
  üç hane).

| Hareket | Kaynak depo | Hedef depo | Not |
| --- | --- | --- | --- |
| Giriş | + miktar | | Elle giriş veya satın alma teslimi |
| Kullanım | − miktar | | Maliyet oluşturmaz |
| Transfer | − miktar | + miktar | Her iki depoda yazma izni; DEMO ↔ gerçek yasak; ödeme oluşturmaz |
| Depoya iade | + miktar | | Sahadan depoya geri dönen malzeme |
| Tedarikçiye iade | − miktar | | Cari alacak veya gider düzeltmesi oluşturmaz |
| Sayım düzeltmesi | sayılan − mevcut | | Temel birimle, gerekçe ≥ 10 karakter; fark onay anında hesaplanır |
| Ters kayıt | asıl hareketin tersi | asıl hareketin tersi | Yalnızca iptal işlemiyle oluşur; yeniden iptal edilemez |

## Negatif stok ve eşzamanlılık

Çıkış yapan her defter satırı (depo, malzeme) anahtarında işlem sonuna kadar
süren bir kilit alır ve toplamı kilitten sonra yeniden okur. Aynı stoktan iki
kişi aynı anda çıkış yaparsa ikinci işlem birincinin bitmesini bekler ve
güncel miktarı görür; toplamı aşan iki çıkış birlikte işlenemez (pgTAP
`121_stok_concurrency`). Formdaki "depoda X var" bilgisi yalnızca kolaylıktır.

## Onay

Hareketi kaydeden kişinin hareketin tüm depolarında `stok.approve` izni varsa
hareket hemen stoka işlenir. Yoksa (şantiye şefi) hareket **onay bekler** ve
stoka yansımaz; onay bekleyenlerin etkisi stok ekranında ayrıca gösterilir.
Onaylayan reddedebilir, kaydeden kendi bekleyen hareketini geri çekebilir.

## İptal: silme yok

Onaylı hareket silinmez ve değişmez. İptal, aynı miktarda ters kayıt açar
(gerekçe ≥ 10). Ters kayıt da negatif stok kuralına tabidir: kullanılmış
girişin iptali, önce o kullanım geri alınmadan yapılamaz. Satın alma teslimiyle
oluşan giriş tek başına iptal edilmez; siparişteki teslim kaydı iptal edilir
(`satinalma.receive` + `stok.cancel`).

## Tekrar gönderim (idempotency)

Hareket, sipariş, teslim, bağlantı ve ters kayıt kimlikleri uygulamada üretilir.
Aynı kimlik ve aynı içerik aynı kaydı döner; ikinci hareket, ikinci stok girişi
veya ikinci sipariş açılmaz. Aynı kimlik farklı içerikle veya başka kullanıcının
kimliğiyle gelirse 23505 ("Bu kimlikle farklı bir hareket var") döner. Formlar
kimliği başarılı olana kadar korur: bağlantı kopup "Kaydet"e tekrar basılırsa
aynı istek gönderilir. Teslimde teslim alan kişi, gider bağlantısında not da karşılaştırılır.

## Satın alma ve finans (çift kayıt yok)

- Sipariş **borç, gider veya ödeme oluşturmaz**. Gerçek borç, gelen faturanın
  Aşama 5'te gider olarak girilip onaylanmasıyla doğar.
- Satır fiyatı bilgi amaçlıdır; finans raporlarına, proje maliyet raporuna,
  cari bakiyeye veya ödeme kaynaklarına girmez. Fiyatı yalnızca `satinalma.read`
  sahibi görür (sütun yetkisi kapalı, `purchase_order_prices()`).
- Teslim alma stok girişinin kaynağıdır: her teslim satırı bir giriş hareketi
  açar. Teslim kalan miktarı aşamaz (sipariş satırı kilitlenir). Kısmi teslim
  "Kısmen teslim", tamamı "Tamamlandı" yapar; eksik teslimle kapatma gerekçe ister.
- Fatura bağlantısı: var olan gider kaydı siparişe **bağlanır**; yeni gider,
  cari hareket veya ödeme açılmaz. Bir gider en fazla bir etkin siparişe
  bağlanır; gider siparişle aynı projede, aynı DEMO işaretinde ve carisi boş ya
  da tedarikçiyle aynı olmalıdır. Proje maliyet raporu gideri yalnızca bir kez
  sayar (pgTAP `122_satinalma`).
- Belge bağlantısı (irsaliye, fatura fotoğrafı) Aşama 6 arşivindeki belgeyi
  gösterir; finans kayıtlarına dokunmaz.
- **Bağlantı sonrası koruma:** Siparişe bağlı gider (taslak olsa bile) başka
  projeye, DEMO kapsamına veya başka tedarikçiye taşınamaz; belge de bağlı
  olduğu sipariş, teslim veya hareketin projesinden çıkarılamaz. Önce bağlantı
  kaldırılır. Gider iptal edilirse bağlantı kendiliğinden sona erer, düzeltilirse
  yeni taslağa taşınır; belge iptal edilirse bağlantı sona erer, yeni dosyayla
  değiştirilirse yeni belgeye taşınır. Gider bağlı sipariş iptal edilemez.
  Bu değişiklikler sipariş geçmişinde "otomatik" olarak görünür.
- Stok değerlemesi yoktur: FIFO, ortalama maliyet ve kur farkı hesaplanmaz. Stok
  raporları (miktar) finans raporlarından (tutar) ayrıdır.

## Yetki özeti

- Proje kullanıcısı yalnızca kendi projesinin deposunu görür; genel depolar
  genel izin ister. Transfer iki depoda yetki ister.
- Şantiye şefi: stok okuma, giriş/kullanım hazırlama (onaya düşer), teslim alma.
  Fiyat görmez, sipariş onaylamaz, stok onaylamaz, ödeme yetkisi almaz.
- Sipariş onayı ve onaylı siparişin iptali yalnızca yöneticidedir
  (`satinalma.approve`, `satinalma.cancel`); rol şablonuyla başka role verilebilir.

## Yedek ve geri yükleme

`scripts/backup/stock-state.sql` her depo/malzeme miktarını, bekleyen hareketleri
ve sipariş satırı teslim miktarlarını yazar; `restore-verify.sh` geri yüklemeden
sonra aynı listeyi üretip birebir karşılaştırır. Fark varsa iş kırmızı olur.
