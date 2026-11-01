-- Belge dosyalarının bütünlük listesi: yol <TAB> bayt <TAB> SHA-256 (sıralı).
-- Yalnızca yüklemesi tamamlanmış belgeler (etkin, arşivlenmiş veya sonradan
-- iptal edilmiş; dosyaları silinmez). Yedek ve geri yükleme doğrulamasında
-- storage-verify.sh ile kullanılır.
select storage_path || E'\t' || byte_size || E'\t' || sha256
  from private.document_storage_manifest();
