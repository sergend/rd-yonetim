# Karar 0003: Aşama 2 kararları (taşeron, personel, ekip, görevlendirme)

| # | Karar | Gerekçe |
| --- | --- | --- |
| 1 | Taşeronun finansal kimliği cari karttır. `subcontractors` vergi numarası, IBAN veya bakiye tutmaz; `cari_account_id` isteğe bağlıdır ve etkin kayıtlarda benzersizdir | Aynı firma ikinci kez bağımsız finansal kimlik olarak açılamaz; hakediş ve ödeme (Aşama 3-4) tek cari karta yazılır. |
| 2 | Taşerona yalnızca etkin, müşteri olmayan, demo durumu aynı ve kullanıcının görebildiği cari kart bağlanır | Müşteri carisi taşeron olamaz; cari kartı göremeyen kullanıcı finans kaydını dolaylı olarak değiştiremez. |
| 3 | Personel kimliği (`personnel`) ile ekip üyeliği (`crew_memberships`) ayrı tablolardır | Kişi ekip değiştirdiğinde kimliği ve geçmişi korunur; puantaj kişiye, ekip bilgisi o günkü üyeliğe bağlanır. |
| 4 | Telefon ayrı tabloda (`personnel_contacts`) ve ayrı izinle (`personel_iletisim.read`) okunur. TCKN, banka, adres tutulmaz | KVKK: bu aşamada gerekmeyen kişisel veri toplanmaz; iletişim bilgisi personel listesini görebilen herkese açılmaz. İleride eklenirse ayrı tablo ve izinle eklenmeli. |
| 5 | Taşeron personelinde taşeron zorunludur; şirket ve diğer personel taşerona bağlanamaz | Puantaj ve hakedişte kişinin kimin adına çalıştığı belirsiz kalmaz. Bunun dışında zorunlu alan yalnızca ad soyaddır. |
| 6 | Bir kişi aynı anda yalnızca bir ekipte olabilir (gist exclusion + Türkçe mesajlı trigger) | Günlük çalışma kaydı tek ekibe yazılabilir; çift sayım olmaz. |
| 7 | Taşeron personeli yalnızca kendi taşeronunun, şirket personeli yalnızca şirket ekibine katılır; ekip sorumlusu için de aynı kural | Ekip, hakedişte tek bir taşerona (veya şirkete) ait olur. |
| 8 | Aynı kişi veya ekip aynı anda farklı projelerde görevli olabilir; aynı projeye çakışan ikinci görevlendirme reddedilir | Gerçek hayatta yasak olmayan durum kısıtlanmaz; yalnızca mükerrer kayıt engellenir. |
| 9 | Üyelik ve görevlendirmeler silinmez; bitiş tarihiyle kapanır. Kaydın sahibi (kişi, ekip, proje, taşeron) sonradan değiştirilemez | Geçmiş korunur; tarih düzeltmeleri işlem geçmişine yazılır. Yanlış kişi seçildiyse kayıt bitirilip doğrusu eklenir. |
| 10 | Kartlar (taşeron, personel, ekip, üyelik) genel izinle yazılır; görevlendirmeler proje izniyle | Genel yönetici şirket geneli kayıtları, proje yetkilisi yalnızca kendi projesinin görevlendirmelerini yönetir. |
| 11 | Proje kapsamlı okuma: personel, projeye doğrudan görevliyse ya da üyelik dönemi projedeki ekip görevlendirmesiyle çakışıyorsa görünür; ekibin başka dönem/proje üyelikleri görünmez | Proje bazında yetkili kullanıcı başka projelerin personel ve görevlendirme bilgisini göremez. |
| 12 | `assignment_candidates(proje)` yalnızca o projede `gorevlendirme.write` olan kullanıcıya, etkin personel ve ekiplerin adını ve görevini döner (iletişim, üyelik ve başka proje bilgisi yok) | Şantiye şefi projesine yeni gelen kişiyi seçebilir; personel kartı açma yetkisi şirket genelinde kalır. |
| 13 | `project_workforce(proje, gün)` o gün projede çalışan kişileri (doğrudan ya da ekip üzerinden, kişi başına bir satır, doğrudan görevlendirme öncelikli) görevlendirme ve üyelik kimlikleriyle döner | Aşama 3 puantajı günlük kaydı bu fonksiyonla doğru görevlendirme ve üyeliğe bağlayacak. |
| 14 | Bu tablolarda cari deftere yazan trigger yoktur (pgTAP ile denetlenir) | Personel ve görevlendirme kayıtları hiçbir şekilde otomatik borç doğurmaz. |
| 15 | Yeni rol şablonu `idari_isler` (genel): taşeron, personel, ekip ve görevlendirme yönetimi; finans yok | Personel işlerini yürüten kişiye muhasebe yetkisi vermeden yönetim imkânı. Şablonlar yönetici tarafından düzenlenebilir. |
| 16 | Taşeron belgeleri şimdilik yalnızca bilgi kaydıdır (ad, numara, geçerlilik tarihi) | Dosya yükleme Storage, RLS ve yedekleme gerektirir; belge modülüyle (Aşama 6) eklenecek. |
