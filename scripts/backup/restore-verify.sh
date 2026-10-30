#!/usr/bin/env bash
# Bir yedeği BOŞ bir Supabase veritabanına geri yükler ve satır sayılarını
# yedek anındaki sayılarla karşılaştırır. Fark varsa hata ile çıkar.
#
# Kullanım : scripts/backup/restore-verify.sh <yedek-klasörü> <hedef-db-url>
# UYARI    : Hedef, yeni oluşturulmuş boş bir veritabanı olmalıdır. Canlı
#            veritabanına asla uygulamayın.
set -euo pipefail

dir="${1:?yedek klasörü gerekli}"
target="${2:?hedef veritabanı adresi gerekli}"
here="$(cd "$(dirname "$0")" && pwd)"

# Supabase'in kendi iç rol ayarları (GRANT SET ON PARAMETER) her yeni Supabase
# projesinde zaten vardır ve postgres kullanıcısıyla yeniden verilemez.
roles="$(mktemp)"
trap 'rm -f "$roles"' EXIT
grep -v '^GRANT SET ON PARAMETER' "$dir/roles.sql" > "$roles"

psql "$target" -X -q \
  --single-transaction \
  --variable ON_ERROR_STOP=1 \
  --file "$roles" \
  --file "$dir/schema.sql" \
  --command 'SET session_replication_role = replica' \
  --file "$dir/data.sql" > /dev/null

# Şema dökümü auth şemasındaki trigger'ları ve anon'dan alınan yetkileri
# taşımaz: bunları yeniden kur, sonucu yedek anındaki güvenlik durumuyla karşılaştır.
psql "$target" -X -q -v ON_ERROR_STOP=1 -c 'select private.post_restore()' > /dev/null

psql "$target" -X -A -t -v ON_ERROR_STOP=1 -f "$here/row-counts.sql"  > "$dir/restored-row-counts.txt"
psql "$target" -X -A -t -v ON_ERROR_STOP=1 -f "$here/security-state.sql" > "$dir/restored-security-state.txt"

status=0
if diff -u "$dir/row-counts.txt" "$dir/restored-row-counts.txt"; then
  echo "Satır sayıları: $(wc -l < "$dir/row-counts.txt") tablo birebir aynı."
else
  echo "HATA: geri yüklenen satır sayıları yedekle uyuşmuyor." >&2
  status=1
fi
if diff -u "$dir/security-state.txt" "$dir/restored-security-state.txt"; then
  echo "Güvenlik durumu (API ayrıcalıkları, RLS, trigger'lar): yedek anıyla birebir aynı."
else
  echo "HATA: geri yüklenen güvenlik durumu yedekle uyuşmuyor." >&2
  status=1
fi
exit $status
