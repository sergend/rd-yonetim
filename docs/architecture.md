# Mimari özet (Aşama 0)

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
