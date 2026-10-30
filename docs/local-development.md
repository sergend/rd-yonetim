# Yerel geliştirme

Yerel ortam yalnızca deneme verisi kullanır ve canlı Supabase'e bağlanmaz.

## Gerekenler (Windows veya Mac)

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (çalışır durumda)
- Node.js 20 veya üzeri (`npx` ile Supabase CLI kurulum gerektirmeden çalışır)
- Git

## Komutlar

```bash
npx supabase db start   # yerel Postgres'i başlatır, migration'ları ve seed.sql'i uygular
npx supabase test db    # supabase/tests altındaki pgTAP testlerini çalıştırır
npx supabase db reset   # veritabanını sıfırlayıp yeniden kurar
npx supabase stop       # durdurur
```

Yerel veritabanı: `postgresql://postgres:postgres@127.0.0.1:54322/postgres`

Deneme kullanıcıları (`supabase start` ile Auth da açıldığında giriş için):

| E-posta | Rol | Şifre |
| --- | --- | --- |
| `yonetici@example.test` | Yönetici (genel) | `yerel-test-1234` |
| `sef@example.test` | Şantiye şefi (DEMO-01 projesi) | `yerel-test-1234` |

## Yeni migration eklerken

1. `npx supabase migration new <kisa_ad>` ile dosya oluşturun.
2. Her yeni tabloda: `select private.add_row_meta('public.<tablo>');`,
   `select audit.enable('public.<tablo>');`, `alter table ... enable row level security;`
   ve politikalar. Tabloya özel API kısıtı varsa `private.harden_api_privileges()`'a ekleyin.
3. `npx supabase db reset && npx supabase test db`. Yapısal kurallar
   (`010_schema_guards`) eksik RLS, audit veya ayrıcalık sızıntısında testi kırar.
