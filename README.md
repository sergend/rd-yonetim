# RD Yönetim

RD İnşaat'ın proje maliyetleri, cari hesaplar, taşeronlar, puantaj, hakediş ve
operasyonel raporlaması için iPhone uygulaması (SwiftUI) ve Supabase
(PostgreSQL) altyapısı.

Mimari: [Teknik Mimari Önerisi](https://claude.ai/artifact/6gdNhhjhSuDdodf55R3dn9)
(Revizyon 1 dahil). Depodaki özet: [docs/architecture.md](docs/architecture.md).

## Durum

| Aşama | Kapsam | Durum |
| --- | --- | --- |
| 0 | Veritabanı temeli: kullanıcı/rol/izin, proje, audit log, RLS, testler, yedekleme | Geliştiriliyor |
| 1 | Xcode projesi, giriş, ana ekran, proje ve cari | Bekliyor |

## Depo yapısı

```text
supabase/
  config.toml          yerel Supabase ayarları (kayıt kapalı)
  migrations/          veritabanı şeması; canlıya yalnızca bunlar uygulanır
  tests/               pgTAP testleri (RLS, yetki, audit, yapısal kurallar)
  seed.sql             YALNIZCA yerel deneme verisi (gerçek veri yok)
scripts/backup/        yedek alma ve geri yükleyip doğrulama betikleri
.github/workflows/     testler, gece yedeği, aylık geri yükleme testi
docs/                  mimari özet, kararlar, kurulum ve geri yükleme talimatları
```

## Yerelde çalıştırma

Ayrıntı: [docs/local-development.md](docs/local-development.md).

```bash
npx supabase db start      # migration'lar + deneme verisi
npx supabase test db       # pgTAP testleri
npx supabase db reset      # sıfırdan kur
```

## Güvenlik kuralları

- Gizli anahtarlar (service role, veritabanı şifresi, yedek anahtarları) depoya
  girmez; yalnızca GitHub Secrets ve Supabase panelinde durur.
- Gerçek şirket verisi, RLS testleri ve geri yükleme testi başarıyla geçmeden
  girilmez ([docs/runbook-backup-restore.md](docs/runbook-backup-restore.md)).
- `main` dalına yalnızca incelenmiş pull request ile birleştirilir.
