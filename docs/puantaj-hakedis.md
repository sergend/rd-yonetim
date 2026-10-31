# Puantajın hakedişe veri sağlaması (teknik not)

Bu belge **Aşama 3'te geliştirilmeyen** hakediş modülünün puantajı nasıl
kullanacağını tanımlar. Bu aşamada ücret, sözleşme, hakediş veya borç
hesaplayan hiçbir kod yoktur.

## Kaynak

Hakediş yalnızca durumu `onaylandi` veya `kilitli` olan `puantaj_periods`
dönemlerinin kayıtlarını kullanır. Taslak ve incelemedeki aylar hakedişe
kaynak olamaz.

Her dönem için iki kaynak vardır:

1. `puantaj_entries` (silinmemiş satırlar): proje, kişi, gün, durum, fazla
   mesai (saat ve onay) ve kayıt anındaki snapshot alanları
   (`assignment_id`, `membership_id`, `crew_id`, `subcontractor_id`,
   `employment_type`, `personnel_name`, `crew_name`).
2. `puantaj_period_events` içindeki son `onayla` olayının `snapshot` alanı:
   onay anındaki tüm kayıtlar ve kişi özetleri, `revision` ile birlikte.
   Hakediş, hesapladığı revizyonu kaydetmelidir.

## Ücret sınıfı

Hakediş durumun adına değil `puantaj_status_definitions.pay_basis` ve
`work_equivalent` alanlarına bakar:

| pay_basis | Durumlar | work_equivalent |
| --- | --- | --- |
| `calisilan_gun` | tam gün, yarım gün | 1 / 0,5 |
| `ucretli_izin` | ücretli izin | 0 |
| `rapor` | raporlu | 0 |
| `resmi_tatil` | resmî tatil | 0 |
| `ucretsiz` | çalışmadı, ücretsiz izin | 0 |

Her sınıfın nasıl ücretleneceği (günlük, aylık, götürü, taşeron sözleşmesi)
hakediş modülünde, kişinin `employment_type` ve `subcontractor_id`
snapshot'ına göre seçilen sözleşme kuralıyla belirlenecektir. Fazla mesaide
yalnızca `overtime_approved_at` dolu saatler kullanılmalıdır.

## Çift yükümlülüğün önlenmesi

- Puantajda proje + kişi + gün zaten benzersizdir.
- Hakediş satırı tablosu (ileride) `puantaj_entry_id` üzerinde benzersiz
  kısıt taşımalıdır (iptal edilmiş satırlar hariç kısmi indeks). Böylece aynı
  çalışma günü iki hakedişe girmez.
- Hakediş, dönem kilitlendikten sonra oluşturulmalı; hakedişe girmiş bir
  dönem yeniden açılırsa, değişen kayıtlar için yeni hakediş değil, mevcut
  hakedişe düzeltme satırı üretilmelidir (fark = yeni revizyon − hesaplanan
  revizyon).
- Puantaj tablolarına hakediş tarafından yazılmaz; ilişki yalnızca hakediş
  tarafındaki yabancı anahtarla kurulur.

## Taşeron hakedişi

Taşeron personelinin günleri `subcontractor_id` snapshot'ı ile taşerona
gruplanır. Taşeronun finansal kimliği cari karttır (karar 0003, madde 1);
cari deftere yazma hakediş onayında, açık bir işlemle yapılacaktır.
