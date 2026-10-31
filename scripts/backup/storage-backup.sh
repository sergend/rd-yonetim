#!/usr/bin/env bash
# Supabase Storage'daki belge dosyalarını Supabase dışındaki şifreli yedeğe
# eşitler. Değişen veya kaynaktan kalkan dosyalar silinmez; tarihli arşiv
# klasörüne taşınır. Ardından yedekteki her dosyayı bütünlük listesine göre
# doğrular (storage-verify.sh).
#
# Kullanım : scripts/backup/storage-backup.sh <kaynak> <yedek-kökü> <storage-manifest.tsv>
#   ör.     scripts/backup/storage-backup.sh supa:belgeler vault: "$RUNNER_TEMP/storage-manifest.tsv"
# rclone uzak bağlantıları ortam değişkenleriyle tanımlanır (RCLONE_CONFIG_*).
set -euo pipefail

src="${1:?kaynak gerekli (ör. supa:belgeler)}"
dst="${2:?yedek kökü gerekli (ör. vault:)}"
manifest="${3:?bütünlük listesi gerekli}"
here="$(cd "$(dirname "$0")" && pwd)"
stamp="$(date -u +%Y-%m-%dT%H%M%SZ)"

# Nesneler değiştirilemez (Storage'da güncelleme/silme politikası yok); bu
# yüzden boyut + zaman karşılaştırması yeterlidir. Asıl doğrulama aşağıda.
rclone sync "$src" "${dst}current/belgeler" --backup-dir "${dst}archive/$stamp/belgeler"
rclone size "${dst}current/belgeler"
"$here/storage-verify.sh" "$manifest" "${dst}current/belgeler"
