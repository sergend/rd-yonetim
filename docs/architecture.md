# Mimari özet (Aşama 0–5)

Tam doküman: [Teknik Mimari Önerisi](https://claude.ai/artifact/6gdNhhjhSuDdodf55R3dn9).
Bu dosya yalnızca veritabanında şu an uygulanmış olanı özetler.

## Şemalar

| Şema | İçerik | API erişimi |
| --- | --- | --- |
| `public` | Uygulama tabloları ve RPC'ler | Var, her tabloda RLS zorunlu |
| `private` | Yetki fonksiyonları, koruma trigger'ları, ilk yönetici kurulumu | Yok (yalnızca yetki fonksiyonları politikalarda çalışır) |
| `audit` | İşlem geçmişi (`audit.log`) | Yok |

## Tablolar

| Tablo | Amaç |
| --- | --- |
| `profiles` | `auth.users` ile 1:1 kullanıcı profili; silinmez, pasifleştirilir. Satırlar: kişi kendini, kullanıcı yöneticisi ve genel rollüler herkesi, proje kullanıcıları yalnızca aynı projedekileri görür. E-posta ve telefon sütunları kapalı; `my_profile()` ve `user_directory()` (yalnızca `kullanici.manage`) ile okunur |
| `permissions` | İzin kataloğu (`modül.eylem`); yalnızca migration ile değişir |
| `roles` | Rol şablonları; `scope` = `global` veya `project`; `yonetici` sistem rolü tüm izinlere sahip |
| `role_permissions` | Rol ile izin bağı |
| `user_roles` | Genel rol atamaları (yalnızca `global` roller) |
| `project_members` | Projeye özel rol ve tarih aralıklı üyelik (çakışma kısıtıyla) |
| `user_permission_overrides` | Kullanıcıya özel `grant` / `deny`, isteğe bağlı proje ve geçerlilik tarihleriyle |
| `projects` | Projeler |
| `cost_centers` | Projeye bağlı olmayan şirket genel giderleri için masraf merkezleri |
| `cari_accounts` | Cari kartlar (taşeron, tedarikçi, müşteri, hizmet sağlayıcı, diğer). Bakiye alanı yoktur |
| `cari_entries` | Cari defter: yalnızca eklenir, değiştirilemez/silinemez; iptal ters kayıtla. Her hareket ya bir projeye ya bir masraf merkezine bağlı. `(source_type, source_id)` benzersiz: aynı kaynak belge iki kez borç/alacak oluşturamaz |
| `cari_allocations` | Kısmi ödeme ve avans eşleştirmesi; toplam, hareket tutarını aşamaz |
| `tasks` | İş takibi; proje boşsa şirket geneli |
| `subcontractors` | Taşeron kartı (ad, iş kolu, iletişim, not). Finansal kimlik bağlı cari karttır; bir cari kart en fazla bir taşerona bağlanır |
| `subcontractor_documents` | Taşeron belge bilgisi (ad, numara, geçerlilik); dosya eki yok (dosyalı arşiv: `documents`, Aşama 6) |
| `subcontractor_projects` | Taşeronun çalıştığı proje ve dönem; aynı projede çakışan dönem yok |
| `personnel` | Personel kimliği (ad, görev, iş kolu, çalışma ilişkisi, taşeron). TCKN/banka/adres yok |
| `personnel_contacts` | Personel telefonu; ayrı izinle (`personel_iletisim.read`) okunur |
| `crews` | Ekip; taşerona ya da şirkete bağlı, isteğe bağlı sorumlu |
| `crew_memberships` | Tarihli ekip üyeliği; silinmez, kişi aynı anda tek ekipte |
| `project_assignments` | Kişi veya ekibin projedeki görev dönemi; silinmez, aynı projede çakışma yok |

`projects`, `cost_centers` ve `cari_accounts` üzerindeki `is_demo` işareti demo
kayıtları ayırır: demo cari ile gerçek proje (veya tersi) aynı harekette
kullanılamaz ve işaret sonradan değiştirilemez.

## Cari defter (Aşama 1)

- Yön karşı tarafın hesabı açısındandır: **borç** (ödeme, avans), **alacak**
  (fatura, hakediş, tahsilat). Bakiye = borç − alacak, her sorguda hesaplanır.
- İstemci deftere doğrudan yazamaz. `post_cari_entry` (istemcinin ürettiği
  kimlikle; tekrar gönderim ikinci kayıt açmaz), `reverse_cari_entry` (bir kez,
  ters kayıt yeniden iptal edilemez), `allocate_cari_entry`,
  `cancel_cari_allocation` RPC'leri yetkiyi ve kuralları denetler.
- Okuma: `cari_balances(proje, masraf merkezi, tarih)` ve
  `cari_statement(cari, proje, başlangıç, bitiş, masraf merkezi)` SECURITY
  INVOKER'dır, yani yalnızca kullanıcının RLS ile görebildiği hareketleri toplar.
- İzinler: `cari.read/write` (kartlar), `cari_hareket.read/write/reverse`
  (hareketler). Varsayılan şablonda yalnızca `muhasebe` (ve `yonetici`) finans
  görür; şantiye şefi ve görüntüleyici görmez. Proje bazlı finans erişimi
  kullanıcıya özel proje izniyle verilir; genel gider hareketleri genel izin ister.

## iOS katmanları (Aşama 1)

`RDCore` (bağımlılıksız Swift paketi: modeller, repository arayüzleri,
`@Observable` ViewModel'ler) → `RDSupabase` (repository'lerin supabase-swift
uygulaması) → `RDYonetim` (yalnızca SwiftUI görünümleri). Tek dış bağımlılık
supabase-swift'tir. Ekranlardaki yetki kontrolü `my_permissions()` sonucuna
göre menüyü sadeleştirir; asıl koruma RLS'tir.

## Taşeron, personel ve ekip (Aşama 2)

- Kartlar şirket genelidir ve genel izinle (`taseron.write`, `personel.write`)
  yazılır; görevlendirmeler projeye aittir ve `gorevlendirme.write` proje
  izniyle yazılır.
- Proje kapsamlı okuma yalnızca o projeyle ilişkili kayıtları açar (ayrıntı:
  [karar 0003](decisions/0003-asama-2-kararlari.md), madde 11).
- `assignment_candidates(proje)`: görevlendirme ekranının seçim listesi (ad ve
  görev; iletişim yok). `project_workforce(proje, gün)`: o gün sahada olanlar;
  puantaj buna bağlanacak.
- Hiçbir kayıt cari deftere yazmaz.

| İzin | Yönetici | İdari işler | Muhasebe | Şantiye şefi (proje) | Görüntüleyici (proje) |
| --- | --- | --- | --- | --- | --- |
| `taseron.read` | ✓ | ✓ | ✓ | ✓ | |
| `taseron.write` | ✓ | ✓ | | | |
| `personel.read` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `personel.write` | ✓ | ✓ | | | |
| `personel_iletisim.read` | ✓ | ✓ | | ✓ | |
| `gorevlendirme.read` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `gorevlendirme.write` | ✓ | ✓ | | ✓ | |

## Puantaj (Aşama 3)

- `puantaj_status_definitions`: durumların sayısal (`work_equivalent`) ve ücret
  (`pay_basis`) anlamı ayrı alanlarda.
- `puantaj_periods` (proje + ay): Taslak → İncelemede → Onaylandı → Kilitlendi,
  revizyon ve ilk onay bilgisi.
- `puantaj_entries` (proje + kişi + gün benzersiz): durum, fazla mesai, not ve
  kayıt anındaki görevlendirme/üyelik/ekip/taşeron snapshot'ı.
- `puantaj_period_events`: değiştirilemez geçiş geçmişi; onay olayı snapshot
  saklar.
- Yazma yalnızca `save_puantaj` (toplu, sürüm kontrollü) ve
  `puantaj_transition` RPC'leriyle; okuma RLS ile. `puantaj_roster` ay içindeki
  görevli listesini, `puantaj_summary` kişi başı sayımları döner.
- Hiçbir puantaj kaydı cari deftere yazmaz; hakedişe veri sağlama:
  [puantaj-hakedis.md](puantaj-hakedis.md). Kararlar:
  [karar 0004](decisions/0004-asama-3-kararlari.md).

| İzin | Yönetici | İdari işler | Muhasebe | Proje müdürü (proje) | Şantiye şefi (proje) | Görüntüleyici (proje) |
| --- | --- | --- | --- | --- | --- | --- |
| `puantaj.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `puantaj.write` | ✓ | ✓ | | ✓ | ✓ | |
| `puantaj.review` | ✓ | ✓ | | ✓ | | |
| `puantaj.approve` | ✓ | | | ✓ | | |
| `puantaj.unlock` | ✓ | | | | | |

## Sözleşme ve hakediş (Aşama 4)

- `contracts` (taşeron + proje + taşeronun mevcut carisi), `contract_versions`
  (revizyon; onaylı olan değişmez), `contract_items` (birim fiyat / günlük /
  götürü; revizyonlar arası sabit `item_key`), `contract_version_taxes`.
- `work_quantities`: birim fiyatlı kaleme imalat (metraj); fiyat içermez.
- `hakedis` + `hakedis_lines` (önceki / bu dönem / kümülatif) +
  `hakedis_adjustments` (KDV, stopaj, teminat, avans mahsubu, diğer kesinti;
  matrah ve oranıyla) + kaynak bağlantıları `hakedis_quantity_links` ve
  `hakedis_puantaj_links` (etkin bağlantıda benzersiz).
- `teminat_releases`, `finance_payments` (ödeme/avans; `payment_sources` yalnızca
  bilgi), `tax_rules` (kullanıcı tarafından doğrulanan, tarihli oranlar),
  `finance_events` (değiştirilemez geçmiş).
- Cari: deftere işleme `hakedis` alacak + `kesinti` borç hareketleri;
  teminat iadesi yeni `teminat_iadesi` türünde alacak; ödeme/avans borç.
  Kaynak belge benzersizliği tekrar kaydı engeller; iptal ters kayıtla.
- Yazma yalnızca RPC'lerle (`save_contract`, `contract_transition`,
  `save_work_quantity`, `approve_work_quantities`, `create_hakedis`,
  `set_hakedis_progress`, `set_hakedis_deduction`, `override_hakedis_limit`,
  `hakedis_transition`, `revise_hakedis`, `post_hakedis`, `release_teminat`,
  `record_finance_payment` ve iptalleri). Özet: `contract_finance_summary`,
  `v_hakedis_payment_status`.
- Normal ödeme her zaman tek bir yükümlülüğe (deftere işlenmiş hakediş veya
  teminat iadesi) bağlıdır; hedefsiz ödeme yalnızca sınırlı avanstır. TRY dışı
  sözleşmede deftere işleme, teminat iadesi ve ödeme açık kur ister
  (migration `20261102000000_hakedis_odeme_duzeltmeleri.sql`).
- Hesap kuralları: [hakedis-hesaplama.md](hakedis-hesaplama.md). Kararlar:
  [karar 0005](decisions/0005-asama-4-kararlari.md).

| İzin | Yönetici | Muhasebe | Proje müdürü (proje) | Şantiye şefi (proje) | Diğer roller |
| --- | --- | --- | --- | --- | --- |
| `sozlesme.read` | ✓ | ✓ | ✓ | | |
| `sozlesme.write` | ✓ | ✓ | | | |
| `sozlesme.approve` | ✓ | | | | |
| `imalat.read` | ✓ | ✓ | ✓ | ✓ | |
| `imalat.write` | ✓ | | ✓ | ✓ | |
| `imalat.approve` | ✓ | | ✓ | | |
| `hakedis.read` | ✓ | ✓ | ✓ | | |
| `hakedis.prepare` | ✓ | ✓ | ✓ | | |
| `hakedis.approve` | ✓ | | | | |
| `hakedis.limit_override` | ✓ | | | | |
| `hakedis.post` | ✓ | ✓ | | | |
| `teminat.release` | ✓ | | | | |
| `odeme.write` | ✓ | ✓ | | | |
| `vergi.manage` | ✓ | ✓ | | | |

Şantiye şefi puantaj ve imalat girer, ancak sözleşme fiyatlarını ve hakediş
tutarlarını göremez. Şablonlar yönetici tarafından değiştirilebilir.

## Gider, gelir ve borç (Aşama 5)

- `finance_categories` (veri; kodda kategori yok), `finance_documents` (gider ve
  gelir; proje veya genel masraf merkezi; taslak → onaylı → iptal),
  `finance_settlements` (kısmi ödeme/tahsilat; `payment_sources` yalnızca bilgi),
  `finance_document_events` (değiştirilemez geçmiş).
- Durum: `v_finance_document_status` (ödenmedi / kısmen / tamamen, kalan,
  vadesi geçmiş). Raporlar: `finance_report`, `project_cost_report`.
- Cari: yalnızca cari bağlantılı belgeler deftere yazılır (onayda bir kez;
  her ödeme/tahsilat ayrı hareket + `cari_allocations` eşleştirmesi). İptal ters kayıtla.
- Yazma yalnızca RPC'lerle (`save_finance_category`, `save_finance_document`,
  `approve_finance_document`, `record_finance_settlement`,
  `cancel_finance_settlement`, `cancel_finance_document`, `revise_finance_document`).
- Hakediş bu tablolara yazılmaz; proje maliyetinde ayrı sütundur.
- Hesap kuralları: [gider-gelir-hesaplama.md](gider-gelir-hesaplama.md). Kararlar:
  [karar 0006](decisions/0006-asama-5-kararlari.md).

| İzin | Yönetici | Muhasebe | Proje müdürü (proje) | Şantiye şefi (proje) | Diğer roller |
| --- | --- | --- | --- | --- | --- |
| `gider.read` | ✓ | ✓ | ✓ | | |
| `gider.write` | ✓ | ✓ | ✓ | ✓ | |
| `gider.approve` | ✓ | | | | |
| `gider.pay` | ✓ | ✓ | | | |
| `gelir.read` | ✓ | ✓ | | | |
| `gelir.write` | ✓ | ✓ | | | |
| `gelir.approve` | ✓ | | | | |
| `gelir.collect` | ✓ | ✓ | | | |
| `finans_rapor.read` | ✓ | ✓ | ✓ | | |
| `finans_kategori.manage` | ✓ | ✓ | | | |

Şantiye şefi kendi projesinde hızlı gider girer ve yalnızca kendi girdiği
giderleri görür; başkasının giderini, geliri ve raporları göremez, onaylayamaz,
ödeme kaydedemez.

## Evrak arşivi (Aşama 6)

- `documents`: belge bilgisi ve dosya kaydı (tür, ad, tarih, açıklama; tek ana
  bağlantı `proje` / `masraf_merkezi` / `finans_belgesi` / `sozlesme`; türetilmiş
  proje veya masraf merkezi, cari, taşeron, DEMO; `mime_type`, `byte_size`,
  `sha256`, `storage_path`; durum `bekliyor` → `yuklendi` → `arsivlendi` / `iptal`;
  `replaces_id`). `document_events`: değiştirilemez geçmiş.
- Dosyalar özel `belgeler` bucket'ında (25 MB, PDF/JPEG/PNG), yol
  `<uuid>/<uuid>.<uzantı>`. `storage.objects` politikaları yalnızca insert (kendi
  ayrılmış yoluna) ve select (belgeyi görebilen) içerir; update ve delete yok.
  Politikalar `private.install_storage_policies()` ile kurulur, `post_restore()` de çağırır.
- Yazma yalnızca RPC'lerle: `reserve_document_upload`, `complete_document_upload`,
  `archive_document`, `cancel_document`, `relink_document`. Tamamlama
  `belge-dogrula` Edge Function'ı üzerinden: Storage'daki gerçek baytların
  SHA-256'sı sunucuda hesaplanır (`record_document_server_hash`, yalnızca
  `service_role`); beyanla aynı değilse belge yüklendi olmaz, iptal edilir. Bakım:
  `private.expire_document_uploads()`, `private.document_orphan_objects()`
  (yalnızca listeler), `private.document_storage_manifest()` (yedek doğrulaması).
- iOS: `DocumentUploader` (cihazda sakla → yer ayır → gönder → sunucuda doğrula; aynı
  kimlikle yeniden dene), `FilePendingUploadStore`, `DocumentFileValidator`
  (içerikten tür, boyut), `SHA256Digest`. Ekranlar `ios/RDYonetim/Belgeler/`.
- Kararlar: [karar 0007](decisions/0007-asama-6-kararlari.md).

| İzin | Yönetici | Muhasebe | Proje müdürü (proje) | Şantiye şefi (proje) | İdari işler | Görüntüleyici |
| --- | --- | --- | --- | --- | --- | --- |
| `belge.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `belge.finans_read` | ✓ | ✓ | ✓ | | | |
| `belge.write` | ✓ | ✓ | ✓ | ✓ | ✓ | |
| `belge.manage` | ✓ | ✓ | ✓ | | | |

`belge.finans_read` proje ve genel belgelerinde fatura, fiş ve sözleşme
türlerini açar. Gider/gelire bağlı belge için o gider/geliri görme yetkisi,
sözleşmeye bağlı belge için `sozlesme.read`/`sozlesme.write` de gerekir. Bu
yüzden şantiye şefi irsaliye, tutanak ve ruhsatı görür ve ekler; fatura, fiş
ve sözleşme dosyalarını göremez.

## Malzeme, stok ve satın alma (Aşama 7)

- Katalog veridir, kodda sabit liste yoktur: `material_units` (kod, ad, sembol,
  izin verilen ondalık hane), `material_categories`, `materials` (kod, ad,
  kategori, **temel birim**, açıklama, etkin/pasif), `material_unit_conversions`
  (1 birim = `factor` temel birim; yalnızca açıkça tanımlanan oran kullanılır,
  oran değişmez, pasifleştirilip yenisi açılır). Hareketi, sipariş satırı veya
  etkin oranı olan malzemenin temel birimi değiştirilemez.
- `warehouses`: her projeye otomatik "Ana depo" (`zz_default_warehouse`
  trigger'ı, mevcut projelere de açıldı) ve projesiz **genel depolar**. Depo
  projesi ve DEMO işareti sonradan değişmez.
- `stock_movements` (giriş, kullanım, transfer, depoya iade, tedarikçiye iade,
  sayım, ters kayıt; durum `bekliyor` → `onaylandi` / `reddedildi`) ve
  `stock_entries` (**değiştirilemez defter**, işaretli miktar, temel birim).
  Stok miktarı hiçbir tabloda tutulmaz: `v_stock_balances` defter toplamıdır;
  `v_stock_pending` onay bekleyenlerin etkisini ayrı gösterir.
- Negatif stok veritabanında engellenir: her çıkış satırı (depo, malzeme)
  anahtarında işlem sonuna kadar süren `pg_advisory_xact_lock` alır ve toplamı
  kilitten sonra yeniden okur (`stock_entry_non_negative` trigger'ı). Eşzamanlı
  iki çıkış sırayla değerlendirilir.
- Satın alma: `purchase_orders` (tedarikçi carisi, teslim deposu, proje depodan
  türetilir, tarih, beklenen tarih, para birimi; `taslak` → `onaylandi` →
  `kismi_teslim` → `tamamlandi`, `iptal`), `purchase_order_lines` (miktar, birim,
  oran, temel miktar, bilgi amaçlı birim fiyat), `purchase_receipts` +
  `purchase_receipt_lines` (her satır bir stok girişi; satır kilidiyle kalan
  miktar aşılamaz), `purchase_order_events` (değiştirilemez geçmiş).
  `v_purchase_order_line_status` fiyatsız teslim durumudur; fiyat sütunları
  sütun yetkisiyle kapalıdır ve yalnızca `purchase_order_prices()` ile
  (`satinalma.read`) okunur.
- Finans bağlantısı yalnızca bilgidir: `purchase_order_expense_links` (bir gider
  en fazla bir siparişe; gider, proje, cari ve DEMO uyumlu olmalı) ve
  `purchase_order_documents` (Aşama 6 arşivi). Bu aşama hiçbir finans tablosuna
  yazmaz ve finans tablolarına trigger eklemez.
- Yazma yalnızca RPC'lerle: `save_material_unit`, `save_material_category`,
  `save_material`, `save_material_unit_conversion`,
  `set_material_unit_conversion_active`, `save_warehouse`,
  `create_stock_movement`, `approve_stock_movement`, `reject_stock_movement`,
  `reverse_stock_movement`, `stock_summary`, `save_purchase_order`,
  `purchase_order_transition`, `receive_purchase_order`,
  `cancel_purchase_receipt`, `link_purchase_order_expense`,
  `unlink_purchase_order_expense`, `link_purchase_order_document`,
  `unlink_purchase_order_document`, `purchase_order_prices`.
- iOS: `InventoryRepository` (RDCore), `SupabaseInventoryRepository`,
  `InMemoryInventory`, `InventoryViewModels`. Ekranlar `ios/RDYonetim/Stok/`.
- Ayrıntılı kurallar: [stok-satinalma.md](stok-satinalma.md); kararlar:
  [karar 0008](decisions/0008-asama-7-kararlari.md).

| İzin | Yönetici | Muhasebe | Proje müdürü (proje) | Şantiye şefi (proje) | İdari işler | Görüntüleyici |
| --- | --- | --- | --- | --- | --- | --- |
| `stok.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `stok.write` | ✓ | | ✓ | ✓ | | |
| `stok.approve` | ✓ | | ✓ | | | |
| `stok.cancel` | ✓ | | ✓ | | | |
| `malzeme.manage` | ✓ | ✓ | | | ✓ | |
| `satinalma.read` (fiyat dahil) | ✓ | ✓ | ✓ | | | |
| `satinalma.write` | ✓ | ✓ | ✓ | | | |
| `satinalma.approve` | ✓ | | | | | |
| `satinalma.receive` | ✓ | | ✓ | ✓ | | |
| `satinalma.cancel` | ✓ | | | | | |

Şantiye şefi giriş ve kullanım hazırlar (onaya düşer), teslim alır; fiyat
göremez, sipariş onaylayamaz, stok onaylayamaz ve hiçbir ödeme yetkisi almaz.
Transferde hareket her iki depoda da yetki ister. Proje kullanıcısı yalnızca
kendi projesinin deposunu görür; genel depolar genel izin ister.

## Etkin izin

`private.has_permission(izin, proje)` = (genel roller ∪ o projedeki rol ∪ özel
grant) − özel deny. Yasak her zaman kazanır, pasif kullanıcının izni yoktur.
Uygulama menüleri `public.my_permissions()` ile gösterir; asıl engel RLS'tir.

## Son yönetici koruması

Etkin yönetici = aktif profil + sistem rolü ataması + `kullanici.manage` üzerinde
genel yasak yok (ileri tarihli yasak da sayılır). Rol kaldırma, pasifleştirme,
yasak ekleme veya fiziksel silme son etkin yöneticiyi ortadan kaldıracaksa işlem
sonunda reddedilir (`keep_last_admin` ertelenmiş kısıt trigger'ı). Aynı işlemde
yeni yönetici atanıp eskisi kaldırılabilir.

## Her tabloda ortak kurallar

- `id uuid`, `created_at/by`, `updated_at/by`, `version` (`aa_row_meta` trigger'ı;
  istemcinin gönderdiği değerler yok sayılır, değişiklik yoksa sürüm artmaz).
- `zz_audit_row` trigger'ı ile işlem geçmişi; değişmeyen güncelleme kaydedilmez.
- Fiziksel silme ve `TRUNCATE` API'ye kapalı; silme `deleted_at` ile yapılır.
- `anon` rolünün hiçbir tabloya ve fonksiyona yetkisi yok.

Bu kuralların her biri `supabase/tests/010_schema_guards.test.sql` ile otomatik
denetlenir; yeni bir tablo kurala uymazsa testler kırılır.
