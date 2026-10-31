# YALNIZCA CI / yerel test: rclone bağlantılarını ortam değişkenleriyle tanımlar.
#   supa:   kaynak yerel Supabase Storage (S3 protokolü)
#   target: geri yükleme hedefi yerel Supabase Storage (S3 protokolü)
#   vault:  dış yedeğin yerel benzeri: <geçici>/vault-raw üzerinde rclone crypt
# Canlı ortamda kullanılmaz (canlı ayarlar backup-nightly.yml'dedir).
# Kullanım : source scripts/backup/ci/rclone-local-env.sh <depo-kökü> <geçici-klasör>
_repo="${1:?depo kökü gerekli}"
_tmp="${2:?geçici klasör gerekli}"
# Yerel http uçlarına giderken vekil sunucu ve özel CA paketi kullanılmaz.
unset AWS_CA_BUNDLE
export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}" no_proxy="127.0.0.1,localhost${no_proxy:+,$no_proxy}"
_s3env() { # önek klasör
  local prefix="$1" dir="$2" env
  env="$(cd "$dir" && supabase status -o env | grep -E '^(STORAGE_S3_URL|S3_PROTOCOL_ACCESS_KEY_ID|S3_PROTOCOL_ACCESS_KEY_SECRET|S3_PROTOCOL_REGION)=')"
  eval "$env"
  export "RCLONE_CONFIG_${prefix}_TYPE=s3" "RCLONE_CONFIG_${prefix}_PROVIDER=Other" \
         "RCLONE_CONFIG_${prefix}_ENDPOINT=$STORAGE_S3_URL" "RCLONE_CONFIG_${prefix}_REGION=$S3_PROTOCOL_REGION" \
         "RCLONE_CONFIG_${prefix}_ACCESS_KEY_ID=$S3_PROTOCOL_ACCESS_KEY_ID" \
         "RCLONE_CONFIG_${prefix}_SECRET_ACCESS_KEY=$S3_PROTOCOL_ACCESS_KEY_SECRET" \
         "RCLONE_CONFIG_${prefix}_FORCE_PATH_STYLE=true"
}
_s3env SUPA "$_repo"
if [ -d "$_tmp/restore-target/supabase" ]; then _s3env TARGET "$_tmp/restore-target"; fi
mkdir -p "$_tmp/vault-raw"
export RCLONE_CONFIG_VAULT_TYPE=crypt RCLONE_CONFIG_VAULT_REMOTE="$_tmp/vault-raw"
# Deneme parolası: yalnızca bu geçici, deneme verili test yedeği için.
export RCLONE_CONFIG_VAULT_PASSWORD="$(rclone obscure ci-deneme-parolasi)"
export RCLONE_CONFIG_VAULT_PASSWORD2="$(rclone obscure ci-deneme-tuzu)"
