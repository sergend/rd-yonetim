#!/usr/bin/env bash
# Belge dosyalarını bütünlük listesine (storage-manifest.tsv) göre doğrular:
# her dosya gerçekten okunur (indirilir), boyutu ve SHA-256 özeti
# karşılaştırılır. Eksik, boyutu farklı veya bozuk tek bir dosya bile varsa
# hata ile çıkar; sessizce başarılı sayılmaz.
#
# Kullanım : scripts/backup/storage-verify.sh <storage-manifest.tsv> <rclone-kökü>
#   rclone-kökü örnekleri: supa:belgeler (Supabase Storage, S3),
#                          vault:current/belgeler (şifreli dış yedek)
set -uo pipefail

manifest="${1:?bütünlük listesi (storage-manifest.tsv) gerekli}"
root="${2:?rclone kökü gerekli}"
test -f "$manifest" || { echo "HATA: bütünlük listesi bulunamadı: $manifest" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
total=0
bad=0
while IFS=$'\t' read -r path size sha; do
  [ -n "$path" ] || continue
  total=$((total + 1))
  file="$work/f"
  rm -f "$file"
  if ! rclone cat "$root/$path" > "$file" 2> "$work/err"; then
    echo "EKSİK: $path ($(tail -n 1 "$work/err"))"
    bad=$((bad + 1))
    continue
  fi
  got_size="$(stat -c %s "$file")"
  if [ "$got_size" != "$size" ]; then
    if [ "$got_size" = "0" ]; then echo "EKSİK: $path"; else echo "BOYUT FARKLI: $path ($got_size bayt, beklenen $size)"; fi
    bad=$((bad + 1))
    continue
  fi
  got_sha="$(sha256sum "$file" | cut -c1-64)"
  if [ "$got_sha" != "$sha" ]; then
    echo "BOZUK (SHA-256 farklı): $path"
    bad=$((bad + 1))
  fi
done < "$manifest"

if [ "$bad" -gt 0 ]; then
  echo "HATA: $total dosyadan $bad tanesi eksik veya bozuk ($root)." >&2
  exit 1
fi
echo "Belge dosyaları: $total dosyanın boyutu ve SHA-256 özeti birebir aynı ($root)."
