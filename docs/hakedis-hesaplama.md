# Hakediş hesaplama kuralları

Hesap veritabanında `private.hakedis_refresh` ile yapılır ve her taslak
değişikliğinde, ayrıca onay anında yeniden çalışır. Swift tarafındaki
`HakedisMath` aynı kuralların kopyasıdır (önizleme ve testler için); sunucu
sonucu esastır. Kararlar: [karar 0005](decisions/0005-asama-4-kararlari.md).

## Ayrı tutulan tutarlar

| Kavram | Alan | Anlamı |
| --- | --- | --- |
| Brüt hakediş | `gross_amount` | Bu dönem yapılan işin bedeli (satır tutarlarının toplamı) |
| KDV | `kdv_amount` | Brüte eklenen vergi |
| Stopaj | `tax_deduction_amount` | Kesilen vergi |
| Diğer kesinti | `other_deduction_amount` | Sözleşmesel diğer kesintiler |
| Teminat kesintisi | `retention_amount` | Brütten kesilir, sözleşmede birikir; ödenmiş sayılmaz |
| Avans mahsubu | `advance_amount` | Daha önce verilen avanstan düşülen |
| Ödemeye uygun | `payable_amount` | Kesintilerden sonra ödenebilecek tutar; **ödendiği anlamına gelmez** |
| Gerçekleşen ödeme | `finance_payments` | Ayrıca kaydedilen ödemeler |
| Kalan | `v_hakedis_payment_status.remaining_amount` | Ödemeye uygun − ödenen |

```
ödemeye uygun = brüt + KDV − stopaj − diğer kesinti − teminat − avans mahsubu
kalan         = ödemeye uygun − gerçekleşen ödeme
```

## Satır tutarları

Her kalem için bir satır (`hakedis_lines`, `line_kind = 'ana'`), fazla mesai
ücreti tanımlı günlük kalemde ayrıca `fazla_mesai` satırı. Her satır önceki
(onaylı hakedişlerin toplamı), bu dönem ve kümülatif miktar/tutarı ayrı
saklar.

| Yöntem | Bu dönem miktarı | Tutar |
| --- | --- | --- |
| Birim fiyat | Dönem sonuna kadar onaylanmış, henüz hiçbir hakedişe bağlanmamış imalat toplamı | `round(miktar × birim fiyat, 2)` |
| Günlük | Onaylı/kilitli puantajdan adam-gün (aşağıda) | `round(adam-gün × günlük ücret, 2)` |
| Götürü | Kümülatif ilerleme % − önceki % | `round(bedel × kümülatif % / 100, 2) − önceki tutar` |
| Fazla mesai | Onaylı saat (yalnızca kalemde saat ücreti varsa) | `round(saat × saat ücreti, 2)` |

### Günlük kalemde puantaj

Her puantaj kaydı için hedef gün:

- Kayıt silinmişse 0.
- `pay_basis = calisilan_gun` ise `work_equivalent` (tam 1, yarım 0,5).
- Durumun `pay_basis` değeri kalemin `paid_bases` listesindeyse 1 (ör. resmî
  tatil, ücretli izin, rapor sözleşmede ücretliyse).
- Diğerleri 0 (çalışmadı, ücretsiz izin; tanımlanmamış izinler).

Kayıt daha önce bir hakedişe bağlandıysa bu dönem yalnızca fark gelir:
`hedef − önceki etkin bağlantıların toplamı`. Aynı kayıt sürümü zaten
bağlıysa atlanır. Kişiye özel fiyatlı kalem varsa o, yoksa kişisiz varsayılan
günlük kalem kullanılır.

## Vergi ve kesintiler

1. Sözleşme revizyonu vergi kodlarını seçer (`contract_version_taxes`).
2. Her kod için dönem sonunda geçerli, etkin ve **doğrulanmış** `tax_rules`
   satırı aranır; yoksa hakediş hesaplanmaz (hata 23514).
3. KDV = `round(brüt × oran / 100, 2)`.
4. Stopaj ve diğer kesinti: matrah kuralda `brut` veya `kdv`;
   `round(matrah × oran / 100, 2)`.
5. Teminat = `round(brüt × teminat oranı / 100, 2)`.
6. Avans mahsubu ve diğer kesinti elle girilir. Avans mahsubu açık avansı
   (verilen − daha önce mahsup edilen) aşamaz; onayda ayrıca onaylı ama henüz
   deftere işlenmemiş hakedişlerde ayrılan mahsup da düşülerek yeniden
   denetlenir.

Her kesinti `hakedis_adjustments` satırında matrah, oran ve tutarla ayrı
durur.

## Yuvarlama

- Miktar en çok 3, birim fiyat 4, tutar 2 ondalık.
- Yuvarlama her satırda ayrı yapılır (toplamda değil); 2 ondalığa yarım yukarı.
- Örnek: 3 × 33,3333 = 99,9999 → **100,00**; 100 × %12,5 = **12,50**.

## Sınırlar

- Kalem: kümülatif miktar > sözleşme miktarı.
- Sözleşme: onaylı hakedişlerin brütü + bu hakediş > sözleşme bedeli.

Aşım `limit_exceeded` ve `limit_messages` olarak kaydedilir. Onay için onaylı
revizyon (sınır artar) ya da `hakedis.limit_override` ile gerekçeli izin
gerekir. Brüt değişirse izin düşer.

## Örnek 1: %20 teminat (birim fiyat)

Sözleşme: C30 beton 150 m³ × 10.000 ₺, teminat %20. Onaylı imalat 100 m³.

| | Tutar |
| --- | --- |
| Brüt hakediş | 1.000.000,00 |
| Teminat kesintisi (%20) | − 200.000,00 |
| **Ödemeye uygun** | **800.000,00** |
| Gerçekleşen ödeme | 0,00 |
| Kalan | 800.000,00 |

Deftere işlenince cari: 1.000.000 alacak (hakediş) ve 200.000 borç (teminat
kesintisi) → taşerona 800.000 borçluyuz. 300.000 ödeme sonrası kalan 500.000.
Teminatın 50.000'i serbest bırakılırsa cariye 50.000 alacak (teminat iadesi)
yazılır; hakediş yeniden borçlandırılmaz. İade ödemesi ayrıca kaydedilir.

## Örnek 2: karma sözleşme

Kalemler: günlük 2.000 ₺/adam-gün (fazla mesai 300 ₺/saat, resmî tatil
ücretli), götürü iskele 100.000 ₺, birim fiyat sıva 150 ₺/m². KDV %20, stopaj
%3, teminat %10 (test kuralları, gerçek oran değildir).

Eylül puantajı (onaylı): 1 + 1 + 0,5 + 1 (resmî tatil) + 2 = 5,5 adam-gün;
ücretli izin ve çalışmadı ücretlendirilmez; onaylı 2 saat fazla mesai.
İskele %40.

| | Tutar |
| --- | --- |
| Günlük: 5,5 × 2.000 | 11.000,00 |
| Fazla mesai: 2 × 300 | 600,00 |
| Götürü: %40 × 100.000 | 40.000,00 |
| **Brüt** | **51.600,00** |
| KDV %20 | + 10.320,00 |
| Stopaj %3 | − 1.548,00 |
| Teminat %10 | − 5.160,00 |
| **Ödemeye uygun** | **55.212,00** |

Eylül yeniden açılıp 3 Eylül yarım günden tam güne düzeltilirse onaylı Eylül
hakedişi değişmez; Ekim hakedişine +0,5 adam-gün (1.000 ₺) fark satırı gelir.

## Deftere işleme

`post_hakedis` (izin `hakedis.post`), tek işlemde:

1. `hakedis` türünde alacak: brüt + KDV (kaynak `hakedis`, hakediş kimliği).
2. Her stopaj, teminat ve diğer kesinti için `kesinti` türünde borç (kaynak
   `hakedis_kesinti`), hakediş hareketine eşleştirilir.
3. Avans mahsubu: açık avans hareketleri tarih sırasıyla hakediş hareketine
   eşleştirilir (yeni hareket açılmaz; avans zaten borç olarak yazılıdır).

Tekrar çağrı aynı sonucu döner. İptalde bu hareketler ters kayıtla kapatılır.

## Sözleşme özeti

`contract_finance_summary(sözleşme)`:

- sözleşme bedeli; onaylı brüt, KDV, stopaj, diğer kesinti, avans mahsubu
- kesilen / serbest bırakılan / biriken teminat
- ödemeye uygun toplam; onaylı ama deftere işlenmemiş kısmı
- gerçekleşen ödeme; verilen avans (ayrı)
- kalan = ödemeye uygun + serbest bırakılan teminat − gerçekleşen ödeme

Bu değerler hiçbir ana ekran bakiyesine, kasaya veya banka bakiyesine
eklenmez.
