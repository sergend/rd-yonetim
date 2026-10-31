# Gider, gelir ve borç: hesap ve durum kuralları

Kararlar: [karar 0006](decisions/0006-asama-5-kararlari.md). Sunucu kuralları
`supabase/migrations/20261104000000_gider_gelir.sql` içindedir; Swift'teki
`FinanceMath` aynı kuralların istemci kopyasıdır (önizleme ve testler için).

## Yaşam döngüsü

```text
Kaydet (taslak) ──onay──▶ Onaylı ──ödeme/tahsilat (1..n)──▶ Kapandı
     │                      │
     └─iptal (≥3 karakter)  ├─iptal (≥10, ödemesi yoksa; cari ters kayıt)
                            └─düzelt (≥10): iptal + yeni taslak (replaces_id)
```

- **Taslak** borç/alacak doğurmaz; raporlara ve bekleyen borçlara girmez.
- **Onay** yükümlülüğü (gider) veya alacağı (gelir) doğurur.
- **Ödeme/tahsilat** ayrı kayıttır; birden çok olabilir, toplamı tutarı aşamaz.

## Durum

| Koşul | Durum (gider) | Durum (gelir) |
| --- | --- | --- |
| `taslak` | Onay bekliyor | Onay bekliyor |
| onaylı, ödenen = 0 | Ödenmedi | Tahsil edilmedi |
| onaylı, 0 < ödenen < tutar | Kısmen ödendi | Kısmen tahsil edildi |
| onaylı, ödenen = tutar | Tamamen ödendi | Tamamen tahsil edildi |
| `iptal` | İptal | İptal |

- Kalan = tutar − etkin ödemeler (iptal edilen ödeme sayılmaz).
- Vadesi geçmiş = onaylı ve kalan > 0 ve vade < bugün (Europe/Istanbul).
  Gecikme günü = bugün − vade.
- Vade boşsa belge tarihidir.

## Örnek 1: kısmen ödenmiş demir faturası (cari bağlantılı)

Seed `GD-000001`: 240.000 ₺, vade 20.10.2026, Örnek Demir Tedarikçisi.

| Olay | Belge | Cari defter | Kalan |
| --- | --- | --- | --- |
| Kaydet | taslak | — | — |
| Onay | onaylı | `gider` alacak 240.000 | 240.000 (Ödenmedi) |
| Ödeme 100.000 (şirket) | — | `odeme` borç 100.000 + eşleştirme | 140.000 (Kısmen ödendi, vadesi geçti) |
| Aynı ödemenin tekrar gönderimi | — | — (aynı kayıt döner) | 140.000 |
| 150.000 ödeme denemesi | — | reddedilir (kalanı aşıyor) | 140.000 |

## Örnek 2: Kürşat kartıyla peşin akaryakıt (carisiz)

Seed `GD-000002`: 4.250,50 ₺, "Peşin ödendi", kaynak "Kürşat kartı (demo)".

- Sahada kaydedilir: taslak; ödeme kaydı yok.
- Onayda aynı işlemde 4.250,50 ₺ ödeme açılır (kaynak kart, ödeyen "Kürşat").
  Durum: Tamamen ödendi.
- Cari deftere hiçbir şey yazılmaz. Kart sahibine otomatik borç **yazılmaz**.
- Rapor "Ödeme kaynağına göre": Kürşat kartı satırında 4.250,50 ₺ görünür.

## Örnek 3: dövizli gider

1.000 USD, belge kuru 34,5 → `amount_try` 34.500,00 ₺. 400 USD ödeme, kur 35 →
ödeme `amount_try` 14.000,00 ₺. Kalan 600 USD; raporda kalan 600 × 34,5 =
20.700,00 ₺ (belge kuru). Kur farkı (14.000 − 13.800) hesaplanmaz ve kaydedilmez.

## Raporlar

`finance_report(kind, group, from, to, project, cost_center)`:

| Sütun | Anlamı |
| --- | --- |
| `accrued_try` | Dönemde belge tarihli onaylı belgelerin TL karşılığı (tahakkuk) |
| `settled_try` | Bu belgelerin etkin ödeme/tahsilatları (her biri kendi kuruyla) |
| `open_try` | Kalan × belge kuru |
| `overdue_try` | Vadesi geçmiş kalan (`open_try` içindedir) |

Gruplar: `proje` (proje veya genel masraf merkezi), `kategori`, `cari` (carisiz
belgeler "Cari bağlantısız"), `ay` (YYYY-AA, sıralı), `kaynak` (yalnızca dönem
içindeki ödeme/tahsilatlar, ödeme tarihine göre).

## Proje maliyeti ve hakediş

`project_cost_report(project)` her proje için ayrı sütunlar döner:

| Sütun | Kaynak | Not |
| --- | --- | --- |
| Gider tahakkuku / ödemesi / kalanı | `finance_documents` (gider) | Hakediş içermez |
| Hakediş tahakkuku | Deftere işlenmiş hakedişlerin cari hareketi (brüt + KDV), ters kaydı olanlar hariç | Aşama 4 |
| Deftere işlenmemiş hakediş | Onaylı, deftere işlenmemiş TL hakedişlerin brüt + KDV'si | Tahakkuka dahil değil |
| Hakediş ödemesi | Hakedişe bağlı etkin `finance_payments` | |
| Verilen avans | `finance_payments` (`avans`) | Ödeme sayılmaz |
| Avanstan mahsup | Deftere işlenmiş hakedişlerde mahsup edilen avans | |
| Gelir tahakkuku / tahsilatı | `finance_documents` (gelir) | |

Hakediş bu modüle yazılmadığı için iki kez sayılmaz. Sütunlar birbirine
eklenmez; ekranda ayrı satırlardır. İzin yoksa ilgili sütunlar boş (null) gelir.
