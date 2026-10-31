# Puantajın hakedişe veri sağlaması (teknik not)

Bu belge Aşama 3'te tasarım notu olarak yazıldı; **Aşama 4'te uygulandı**
(migration `20261101000000_sozlesme_hakedis.sql`). Uygulamadaki karşılıkları
her bölümün sonunda "Aşama 4" notuyla belirtilir. Hesap kuralları:
[hakedis-hesaplama.md](hakedis-hesaplama.md). Puantaj kayıtları hâlâ hiçbir
zaman cari borç üretmez; borç yalnızca onaylı hakedişin açıkça deftere
işlenmesiyle oluşur.

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

Aşama 4: `private.hakedis_refresh`, sözleşmenin projesi ve taşeronu için
yalnızca `onaylandi`/`kilitli` dönemlerin kayıtlarını okur. Her kullanılan
kayıt `hakedis_puantaj_links` satırında `entry_version`, `period_id` ve
`period_revision` ile saklanır; onay olayı da kullanılan dönem revizyonlarını
`finance_events.data` içinde tutar.

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

Aşama 4: ücretlendirilen sınıflar günlük sözleşme kaleminde `paid_bases`
listesindedir (`calisilan_gun` her zaman dahil; `ucretli_izin`, `rapor`,
`resmi_tatil` yalnızca sözleşme açıkça tanımlarsa). Fazla mesai yalnızca
kalemde `overtime_unit_price` varsa ve yalnızca onaylı saatler için ödenir.

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

Aşama 4: benzersizlik `(puantaj_entry_id, entry_version)` üzerinde, etkin
bağlantılar için kısmi indekstir. Onaylı hakediş değiştirilemediği için
düzeltme "mevcut hakedişe satır" yerine **sonraki hakedişe fark satırı**
olarak gelir (`is_correction = true`, `day_delta` = yeni hedef − daha önce
ödenen). Hakediş iptal edilirse bağlantıları pasifleşir ve kayıtlar yeniden
kullanılabilir olur. Birim fiyatlı ve götürü kalemlerde puantaj gerekmez.

## Taşeron hakedişi

Taşeron personelinin günleri `subcontractor_id` snapshot'ı ile taşerona
gruplanır. Taşeronun finansal kimliği cari karttır (karar 0003, madde 1);
cari deftere yazma hakediş onayından sonra, ayrı izinli açık bir işlemle
(`post_hakedis`) yapılır.
