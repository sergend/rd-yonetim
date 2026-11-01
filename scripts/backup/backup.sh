#!/usr/bin/env bash
# Veritabanının tam yedeğini Supabase'in önerdiği üç dosya halinde alır
# (roller, şema, veri) ve doğrulama için satır sayılarını kaydeder.
#
# Kullanım : scripts/backup/backup.sh <çıktı-klasörü>
# Ortam    : SUPABASE_DB_URL  (Supabase > Connect > Session pooler bağlantı adresi)
#            SUPABASE_CLI     (isteğe bağlı, varsayılan: supabase)
set -euo pipefail

out="${1:?çıktı klasörü gerekli}"
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL tanımlı değil}"
cli="${SUPABASE_CLI:-supabase}"
here="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$out"
$cli db dump --db-url "$SUPABASE_DB_URL" --role-only -f "$out/roles.sql"
$cli db dump --db-url "$SUPABASE_DB_URL" -f "$out/schema.sql"
# Supabase'in iç vektör tabloları postgres kullanıcısıyla geri yüklenemez
# (Supabase geri yükleme rehberindeki gibi hariç tutulur).
$cli db dump --db-url "$SUPABASE_DB_URL" --data-only --use-copy \
  -x storage.buckets_vectors -x storage.vector_indexes \
  -f "$out/data.sql"

psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -f "$here/row-counts.sql"  > "$out/row-counts.txt"
psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -f "$here/security-state.sql" > "$out/security-state.txt"
# Stok miktarları (defter toplamı) ve sipariş teslim miktarları: geri yüklemeden
# sonra birebir aynı olmalı.
psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -f "$here/stock-state.sql" > "$out/stock-state.txt"
# Belge dosyalarının yol, boyut ve SHA-256 listesi. Veritabanı yedeği dosya
# içeriklerini taşımaz: dosyalar storage-backup.sh ile ayrıca yedeklenir ve
# bu listeyle doğrulanır. Henüz belge yoksa liste boş olabilir.
psql "$SUPABASE_DB_URL" -X -A -t -v ON_ERROR_STOP=1 -f "$here/storage-manifest.sql" > "$out/storage-manifest.tsv"
date -u +%Y-%m-%dT%H:%M:%SZ > "$out/created-at.txt"

for f in roles.sql schema.sql data.sql row-counts.txt security-state.txt; do
  test -s "$out/$f" || { echo "Boş yedek dosyası: $f" >&2; exit 1; }
done
echo "Yedek hazır: $out ($(wc -l < "$out/row-counts.txt") tablo, $(grep -c . "$out/storage-manifest.tsv" || true) belge dosyası listede)"
