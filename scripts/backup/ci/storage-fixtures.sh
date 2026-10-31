#!/usr/bin/env bash
# YALNIZCA CI / yerel test: yerel Supabase'e (deneme verisiyle) gerçek yükleme
# akışıyla (yer ayır → Storage'a yükle → tamamla) birkaç deneme belgesi ekler.
# Gerçek veri içermez; canlı ortamda çalıştırılmaz.
#
# Kullanım : scripts/backup/ci/storage-fixtures.sh <api-url> <anon-key>
set -euo pipefail
api="${1:?API adresi gerekli}"
anon="${2:?anon anahtarı gerekli}"
case "$api" in http://127.0.0.1:*|http://localhost:*) ;; *) echo "Yalnızca yerel Supabase'e çalışır" >&2; exit 1 ;; esac

login() {
  curl -fsS "$api/auth/v1/token?grant_type=password" -H "apikey: $anon" -H 'content-type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"yerel-test-1234\"}" | python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])'
}
token="$(login yonetici@example.test)"
project="$(curl -fsS "$api/rest/v1/projects?code=eq.DEMO-SVS&select=id" -H "apikey: $anon" -H "Authorization: Bearer $token" \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)[0]["id"])')"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Geçerli imzalı küçük deneme dosyaları (PDF, JPEG, PNG) + rastgele içerik.
{ printf '%%PDF-1.4\n%% RD deneme tutanağı\n'; head -c 2048 /dev/urandom | base64; printf '\n%%%%EOF\n'; } > "$work/tutanak.pdf"
{ printf '\xff\xd8\xff\xe0'; head -c 4096 /dev/urandom; printf '\xff\xd9'; } > "$work/fis.jpg"
{ printf '\x89PNG\r\n\x1a\n'; head -c 1024 /dev/urandom; } > "$work/irsaliye.png"
{ printf '%%PDF-1.7\n%% RD deneme faturası\n'; head -c 1024 /dev/urandom | base64; printf '\n%%%%EOF\n'; } > "$work/fatura.pdf"

upload() { # dosya tür mime başlık
  local file="$1" kind="$2" mime="$3" title="$4" id sha size path
  id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  sha="$(sha256sum "$file" | cut -c1-64)"
  size="$(stat -c %s "$file")"
  path="$(curl -fsS "$api/rest/v1/rpc/reserve_document_upload" -H "apikey: $anon" -H "Authorization: Bearer $token" \
    -H 'content-type: application/json' \
    -d "{\"p_id\":\"$id\",\"p_kind\":\"$kind\",\"p_title\":\"$title\",\"p_link_type\":\"proje\",\"p_link_id\":\"$project\",\"p_mime_type\":\"$mime\",\"p_byte_size\":$size,\"p_sha256\":\"$sha\"}" \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["storage_path"])')"
  curl -fsS -X POST "$api/storage/v1/object/belgeler/$path" -H "apikey: $anon" -H "Authorization: Bearer $token" \
    -H "content-type: $mime" --data-binary "@$file" > /dev/null
  curl -fsS "$api/rest/v1/rpc/complete_document_upload" -H "apikey: $anon" -H "Authorization: Bearer $token" \
    -H 'content-type: application/json' -d "{\"p_id\":\"$id\"}" > /dev/null
  echo "Yüklendi: $title ($kind, $size bayt) → $path"
}
upload "$work/tutanak.pdf"  tutanak  application/pdf "Deneme tutanağı"
upload "$work/fis.jpg"      fis      image/jpeg      "Deneme fişi"
upload "$work/irsaliye.png" irsaliye image/png       "Deneme irsaliyesi"
upload "$work/fatura.pdf"   fatura   application/pdf "Deneme faturası"
