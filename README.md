# RD Yönetim (uygulama adı: RD Projeler)

RD İnşaat'ın proje maliyetleri, cari hesaplar, taşeronlar, puantaj, hakediş ve
operasyonel raporlaması için iPhone uygulaması (SwiftUI) ve Supabase
(PostgreSQL) altyapısı.

Mimari: [Teknik Mimari Önerisi](https://claude.ai/artifact/6gdNhhjhSuDdodf55R3dn9)
(Revizyon 1 dahil). Depodaki özet: [docs/architecture.md](docs/architecture.md).

## Durum

| Aşama | Kapsam | Durum |
| --- | --- | --- |
| 0 | Veritabanı temeli: kullanıcı/rol/izin, proje, audit log, RLS, testler, yedekleme | Tamamlandı |
| 1 | iOS iskeleti, giriş, ana ekran, proje, iş takibi ve cari | Tamamlandı |
| 1.5 | RD Projeler kurumsal kimlik ve iOS tasarım sistemi | İncelemede |

## Yedekleme durumu (önemli)

**Canlı ortam için otomatik dış yedekleme henüz ETKİN DEĞİL.**

- Pull request'lerdeki yeşil "Yedek al ve boş veritabanına geri yükle" işi,
  yalnızca deneme verisiyle kurulan geçici bir test veritabanını yedekleyip geri
  yükler. Betiklerin çalıştığını kanıtlar; canlı verinin yedeklendiğini göstermez.
- `backup-nightly.yml` (gece yedeği) ve `restore-test-monthly.yml` (aylık geri
  yükleme testi) şu üçü tamamlanmadan çalışmaz: canlı Supabase projesi ve
  `production-backup` ortamındaki gizli anahtarlar, Supabase dışındaki S3 uyumlu
  dış yedek deposu, `BACKUP_ENABLED = true` değişkeni.
- Belge (Storage) yedeği de kapalıdır. Belgeler Aşama 6'da geldiğinde
  `STORAGE_BACKUP_ENABLED` açılacak ve belgelerin geri yüklenmesi ayrıca test
  edilecektir; bugünkü geri yükleme testi yalnızca veritabanını kapsar.

Kurulum ve gerçek veriden önceki zorunlu kontrol listesi:
[docs/runbook-backup-restore.md](docs/runbook-backup-restore.md).

## Depo yapısı

```text
supabase/
  config.toml          yerel Supabase ayarları (kayıt kapalı)
  migrations/          veritabanı şeması; canlıya yalnızca bunlar uygulanır
  tests/               pgTAP testleri (RLS, yetki, audit, yapısal kurallar)
  seed.sql             YALNIZCA yerel deneme verisi (gerçek veri yok)
ios/
  RDCore/              Swift paketi: modeller, repository'ler, ViewModel'ler, testler
  RDYonetim/           SwiftUI ekranları
  RDYonetim.xcodeproj  Xcode projesi (iOS 17+, yalnızca iPhone)
  Config/              xcconfig ve Info.plist; Secrets.xcconfig git'e girmez
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

iOS uygulamasını Mac'te açma ve test etme: [docs/ios-mac-setup.md](docs/ios-mac-setup.md).
Tasarım sistemi: [docs/design-system.md](docs/design-system.md). Logo ve ikon: [docs/brand-assets.md](docs/brand-assets.md).

## Güvenlik kuralları

- Gizli anahtarlar (service role, veritabanı şifresi, yedek anahtarları) depoya
  girmez; yalnızca GitHub Secrets ve Supabase panelinde durur.
- Gerçek şirket verisi, RLS testleri ve geri yükleme testi başarıyla geçmeden
  girilmez ([docs/runbook-backup-restore.md](docs/runbook-backup-restore.md)).
- `main` dalına yalnızca incelenmiş pull request ile birleştirilir.
