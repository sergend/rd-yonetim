#!/usr/bin/env bash
# YALNIZCA CI / yerel test: geri yüklenen projede belgeleri uygulamanın
# kullandığı yoldan (oturum açmış kullanıcı, Storage API) indirir ve SHA-256
# özetlerini bütünlük listesiyle karşılaştırır. Ayrıca yetki kurallarının
# geri yüklemeden sonra da geçerli olduğunu denetler: oturumsuz istek hiçbir
# dosyayı alamaz, finansal yetkisi olmayan şantiye şefi fatura/fiş dosyasını
# alamaz.
#
# Kullanım : scripts/backup/ci/storage-download-check.sh <api-url> <anon-key> <storage-manifest.tsv> <db-url>
set -euo pipefail
api="${1:?API adresi gerekli}"
anon="${2:?anon anahtarı gerekli}"
manifest="${3:?bütünlük listesi gerekli}"
db="${4:?veritabanı adresi gerekli}"
case "$api" in http://127.0.0.1:*|http://localhost:*) ;; *) echo "Yalnızca yerel Supabase'e çalışır" >&2; exit 1 ;; esac

login() {
  curl -fsS "$api/auth/v1/token?grant_type=password" -H "apikey: $anon" -H 'content-type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"yerel-test-1234\"}" | python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])'
}
admin="$(login yonetici@example.test)"
sef="$(login sef@example.test)"
test -s "$manifest" || { echo "HATA: bütünlük listesi boş; doğrulanacak belge yok" >&2; exit 1; }

fail=0
n=0
while IFS=$'\t' read -r path size sha; do
  [ -n "$path" ] || continue
  n=$((n + 1))
  got="$(curl -fsS "$api/storage/v1/object/authenticated/belgeler/$path" -H "apikey: $anon" -H "Authorization: Bearer $admin" | sha256sum | cut -c1-64)"
  if [ "$got" != "$sha" ]; then echo "HATA: indirilen dosyanın SHA-256'sı farklı: $path"; fail=1; fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "$api/storage/v1/object/authenticated/belgeler/$path" -H "apikey: $anon")"
  if [ "$code" = "200" ]; then echo "HATA: oturumsuz istek dosyayı aldı: $path"; fail=1; fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "$api/storage/v1/object/public/belgeler/$path")"
  if [ "$code" = "200" ]; then echo "HATA: dosya herkese açık adresten alındı: $path"; fail=1; fi
done < "$manifest"

# Şantiye şefi (finansal yetkisi yok): tutanak/irsaliye alır, fatura/fiş alamaz.
while IFS='|' read -r path kind; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$api/storage/v1/object/authenticated/belgeler/$path" -H "apikey: $anon" -H "Authorization: Bearer $sef")"
  case "$kind" in
    fatura|fis|sozlesme) [ "$code" != "200" ] || { echo "HATA: şantiye şefi $kind dosyasını aldı: $path"; fail=1; } ;;
    *)                   [ "$code" = "200" ]  || { echo "HATA: şantiye şefi $kind dosyasını alamadı ($code): $path"; fail=1; } ;;
  esac
done < <(psql "$db" -X -A -t -v ON_ERROR_STOP=1 -c "select storage_path || '|' || kind from public.documents where status = 'yuklendi' order by 1")

[ "$fail" = 0 ] || exit 1
echo "Uygulama yolundan indirme: $n belgenin SHA-256 özeti aynı; oturumsuz ve yetkisiz erişim reddedildi."
