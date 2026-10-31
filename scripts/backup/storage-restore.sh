#!/usr/bin/env bash
# Şifreli yedekteki belge dosyalarını YENİ (boş) bir Supabase projesinin
# Storage'ına geri yükler ve her dosyayı indirip boyut ve SHA-256 ile
# doğrular. Veritabanı önce restore-verify.sh ile geri yüklenmiş olmalıdır
# (bucket ve belge bilgileri veritabanı yedeğindedir).
#
# Kullanım : scripts/backup/storage-restore.sh <yedek-kökü> <hedef> <storage-manifest.tsv>
#   ör.     scripts/backup/storage-restore.sh vault: target:belgeler yedek/storage-manifest.tsv
# UYARI    : Hedef, yeni oluşturulmuş boş bir proje olmalıdır.
set -euo pipefail

src="${1:?yedek kökü gerekli (ör. vault:)}"
dst="${2:?hedef gerekli (ör. target:belgeler)}"
manifest="${3:?bütünlük listesi gerekli}"
here="$(cd "$(dirname "$0")" && pwd)"

# Veritabanı geri yüklemesi storage.objects satırlarını (yalnızca bilgi) getirir;
# dosyalar hedefte yoktur. Satırlar var diye atlanmaması için her dosya yazılır.
rclone copy "${src}current/belgeler" "$dst" --ignore-times
"$here/storage-verify.sh" "$manifest" "$dst"
