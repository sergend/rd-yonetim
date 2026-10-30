# Mimari özet (Aşama 0 ve 1)

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
