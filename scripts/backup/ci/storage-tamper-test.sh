#!/usr/bin/env bash
# YALNIZCA CI / yerel test: storage-verify.sh'in eksik ve bozuk dosyayı
# sessizce geçmediğini kanıtlar. Yedeğin geçici bir kopyasında bir dosyayı
# siler, birini kısaltır, birinin içeriğini aynı boyutta bozar; doğrulamanın
# üçünü de bildirip hata ile çıkmasını bekler. Asıl yedeğe dokunmaz.
#
# Kullanım : scripts/backup/ci/storage-tamper-test.sh <storage-manifest.tsv> <yedek-kökü>
set -euo pipefail
manifest="${1:?bütünlük listesi gerekli}"
src="${2:?yedek kökü gerekli (ör. vault:current/belgeler)}"
here="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(grep -c . "$manifest")" -ge 3 ] || { echo "En az 3 belge gerekli" >&2; exit 1; }

copy="$(mktemp -d)"
trap 'rm -rf "$copy"' EXIT
rclone copy "$src" "$copy"
missing="$(sed -n 1p "$manifest" | cut -f1)"
short="$(sed -n 2p "$manifest" | cut -f1)"
flipped="$(sed -n 3p "$manifest" | cut -f1)"
rm "$copy/$missing"
truncate -s 10 "$copy/$short"
# Aynı boyutta içerik bozulması: yalnızca SHA-256 yakalar.
printf 'X' | dd of="$copy/$flipped" bs=1 seek=5 conv=notrunc status=none

if out="$("$here/storage-verify.sh" "$manifest" "$copy" 2>&1)"; then
  echo "HATA: bozulmuş yedek doğrulamadan geçti" >&2
  echo "$out" >&2
  exit 1
fi
echo "$out"
grep -q "EKSİK: $missing" <<< "$out"              || { echo "HATA: silinen dosya bildirilmedi" >&2; exit 1; }
grep -q "BOYUT FARKLI: $short" <<< "$out"         || { echo "HATA: kısalan dosya bildirilmedi" >&2; exit 1; }
grep -q "BOZUK (SHA-256 farklı): $flipped" <<< "$out" || { echo "HATA: bozulan dosya bildirilmedi" >&2; exit 1; }
echo "Bozulma testi: eksik, kısalmış ve aynı boyutta bozulmuş dosyalar yakalandı."
