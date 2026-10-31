import Foundation

// Gider/gelir belgeleri için bellek içi uygulama (önizleme ve birim testleri).
// Asıl kurallar veritabanındadır (20261104000000_gider_gelir.sql, pgTAP);
// burada onay, kısmi ödeme, tekrar gönderim ve iptal davranışı taklit edilir.

extension InMemoryBackend {
  /// Önizleme/test verisi: kategoriler ve ödeme kaynakları (sunucuda veri olarak tutulur).
  public func seedFinance(categories: [FinanceCategory] = [], paymentSources: [PaymentSource] = []) {
    financeCategoryList += categories
    paymentSourceList += paymentSources.filter { source in !paymentSourceList.contains { $0.id == source.id } }
  }

  private func can(_ kind: FinanceDocKind, _ key: KeyPath<FinanceDocKind, PermissionKey>, _ scope: FinanceScope) -> Bool {
    switch scope {
    case .project(let id): access.can(kind[keyPath: key], in: id)
    case .costCenter: access.can(kind[keyPath: key])
    }
  }

  private func canRead(_ document: FinanceDocument) -> Bool {
    can(document.kind, \.readPermission, document.scope)
      || (document.createdBy == profile.id && can(document.kind, \.writePermission, document.scope))
  }

  private func financeEvent(_ documentId: UUID, _ action: String, from: String?, to: String?, reason: String? = nil) {
    financeDocumentEvents.append(FinanceDocumentEvent(documentId: documentId, action: action, fromStatus: from,
                                                      toStatus: to, reason: reason?.nilIfBlank, actorId: profile.id))
  }

  private func documentIndex(_ id: UUID) throws -> Int {
    guard let index = financeDocumentList.firstIndex(where: { $0.id == id }), canRead(financeDocumentList[index]) else {
      throw RepositoryError.notFound
    }
    return index
  }

  private func settled(_ documentId: UUID) -> Decimal {
    financeSettlementList.filter { $0.documentId == documentId && $0.status == .aktif }.reduce(0) { $0 + $1.amount }
  }

  private func cariScope(_ scope: FinanceScope) -> CariEntryDraft.Scope {
    switch scope {
    case .project(let id): .project(id)
    case .costCenter(let id): .costCenter(id)
    }
  }

  private func reverseFinanceEntry(_ entryId: UUID, reason: String) {
    guard let original = entries.first(where: { $0.draft.id == entryId }),
          !entries.contains(where: { $0.reversalOf == entryId }) else { return }
    var draft = original.draft
    draft.id = UUID()
    draft.kind = .tersKayit
    draft.direction = draft.direction == .borc ? .alacak : .borc
    draft.entryDate = today
    draft.description = "İptal: \(reason)"
    entries.append(StoredEntry(draft: draft, reversalOf: entryId, sequence: entries.count))
  }

  // MARK: Kategoriler

  func financeCategories(kind: FinanceDocKind?, includeInactive: Bool) throws -> [FinanceCategory] {
    try failIfNeeded()
    return financeCategoryList.filter { (kind == nil || $0.kind == kind) && (includeInactive || $0.isActive) }
      .sorted { ($0.kind.rawValue, $0.sortOrder, $0.name) < ($1.kind.rawValue, $1.sortOrder, $1.name) }
  }

  func saveFinanceCategory(_ category: FinanceCategory) throws -> FinanceCategory {
    try failIfNeeded()
    guard access.can(.finansKategoriManage) else { throw RepositoryError.forbidden("Kategori tanımlama yetkiniz yok") }
    let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw RepositoryError.validation("Kategori adı zorunlu") }
    if financeCategoryList.contains(where: {
      $0.id != category.id && $0.kind == category.kind && $0.name.lowercased(with: Money.locale) == name.lowercased(with: Money.locale)
    }) {
      throw RepositoryError.conflict("Bu adla bir kategori zaten var.")
    }
    var saved = category
    saved.name = name
    if let index = financeCategoryList.firstIndex(where: { $0.id == category.id }) {
      guard financeCategoryList[index].kind == category.kind else {
        throw RepositoryError.validation("Kategorinin türü değiştirilemez")
      }
      financeCategoryList[index] = saved
    } else {
      financeCategoryList.append(saved)
    }
    return saved
  }

  // MARK: Belgeler

  func financeDocuments(filter: FinanceDocumentFilter) throws -> [FinanceDocument] {
    try failIfNeeded()
    return financeDocumentList.filter { d in
      d.kind == filter.kind && canRead(d)
        && (filter.projectId == nil || d.projectId == filter.projectId)
        && (filter.costCenterId == nil || d.costCenterId == filter.costCenterId)
        && (filter.categoryId == nil || d.categoryId == filter.categoryId)
        && (filter.cariAccountId == nil || d.cariAccountId == filter.cariAccountId)
        && (filter.status == nil || d.status == filter.status)
        && (filter.from.map { d.documentDate >= $0 } ?? true)
        && (filter.to.map { d.documentDate <= $0 } ?? true)
    }
    .sorted { ($0.documentDate, $0.documentNo) > ($1.documentDate, $1.documentNo) }
  }

  func financeDocument(id: UUID) throws -> FinanceDocument {
    try failIfNeeded()
    return try financeDocumentList[documentIndex(id)]
  }

  func financeDocuments(ids: [UUID]) throws -> [FinanceDocument] {
    try failIfNeeded()
    return financeDocumentList.filter { ids.contains($0.id) && canRead($0) }
  }

  func financeStatuses(documentIds: [UUID]) throws -> [FinanceDocumentStatus] {
    try failIfNeeded()
    return financeDocumentList.filter { documentIds.contains($0.id) && canRead($0) }
      .map { FinanceMath.status(of: $0, settlements: financeSettlementList, today: today) }
  }

  func financeOpenStatuses(kind: FinanceDocKind) throws -> [FinanceDocumentStatus] {
    try failIfNeeded()
    return financeDocumentList.filter { $0.kind == kind && $0.status == .onaylandi && canRead($0) }
      .map { FinanceMath.status(of: $0, settlements: financeSettlementList, today: today) }
      .filter(\.settlementState.isOpen)
      .sorted { $0.dueDate < $1.dueDate }
  }

  func saveFinanceDocument(id: UUID, draft: FinanceDocumentDraft, expectedVersion: Int?) throws -> FinanceDocument {
    try failIfNeeded()
    guard can(draft.kind, \.writePermission, draft.scope) else {
      throw RepositoryError.forbidden("Bu kapsamda \(draft.kind.title.lowercased(with: Money.locale)) kaydetme yetkiniz yok")
    }
    let isDemo: Bool
    switch draft.scope {
    case .project(let projectId):
      guard let project = projects.first(where: { $0.id == projectId }) else { throw RepositoryError.validation("Proje bulunamadı") }
      isDemo = project.isDemo
    case .costCenter(let centerId):
      guard let center = costCenters.first(where: { $0.id == centerId && $0.isActive }) else {
        throw RepositoryError.validation("Masraf merkezi bulunamadı veya pasif")
      }
      isDemo = center.isDemo
    }
    guard draft.amount > 0, HakedisMath.scale(draft.amount) <= 2 else {
      throw RepositoryError.validation("Tutar pozitif ve en çok iki ondalıklı olmalı")
    }
    let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !description.isEmpty else { throw RepositoryError.validation("Açıklama zorunlu") }
    let due = draft.dueDate ?? draft.documentDate
    guard due >= draft.documentDate else { throw RepositoryError.validation("Vade tarihi belge tarihinden önce olamaz") }
    let currency = draft.currency.uppercased()
    let rate = try HakedisMath.exchangeRate(currency: currency, rate: draft.exchangeRate)
    guard financeCategoryList.contains(where: { $0.id == draft.categoryId && $0.kind == draft.kind && $0.isActive }) else {
      throw RepositoryError.validation("Kategori bulunamadı, pasif veya bu türe ait değil")
    }
    if let cariId = draft.cariAccountId {
      guard let account = accounts.first(where: { $0.id == cariId && $0.isActive }) else {
        throw RepositoryError.validation("Cari hesap bulunamadı veya pasif")
      }
      guard account.isDemo == isDemo else {
        throw RepositoryError.validation("Demo kayıtlar gerçek kayıtlarla aynı belgede kullanılamaz")
      }
    }
    let sourceId = draft.reportedSettled ? draft.reportedSourceId : nil
    if draft.reportedSettled {
      guard paymentSourceList.contains(where: { $0.id == sourceId && $0.isActive }) else {
        throw RepositoryError.validation("Peşin ödeme/tahsilat için ödeme kaynağı seçilmeli")
      }
    }
    var document = FinanceDocument(
      id: id, kind: draft.kind, documentNo: "", scope: draft.scope, categoryId: draft.categoryId,
      cariAccountId: draft.cariAccountId, description: description, documentDate: draft.documentDate, dueDate: due,
      amount: draft.amount, currency: currency, exchangeRate: rate, invoiceNo: draft.invoiceNo.nilIfBlank,
      documentRef: draft.documentRef.nilIfBlank, notes: draft.notes.nilIfBlank, reportedSettled: draft.reportedSettled,
      reportedSourceId: sourceId, reportedBy: draft.reportedSettled ? draft.reportedBy.nilIfBlank : nil,
      createdBy: profile.id, isDemo: isDemo)

    if let index = financeDocumentList.firstIndex(where: { $0.id == id }) {
      let existing = financeDocumentList[index]
      // Görünürlük kuralı: göremediği belgeyi güncelleyemez veya tekrar gönderemez.
      guard canRead(existing) else { throw RepositoryError.conflict("Bu kimlikle başka bir belge var") }
      guard let expectedVersion else {
        // Tekrar gönderim: içerik aynıysa aynı belge döner.
        guard existing.kind == document.kind, existing.categoryId == document.categoryId,
              existing.description == document.description, existing.amount == document.amount,
              existing.documentDate == document.documentDate, existing.dueDate == document.dueDate,
              existing.scope == document.scope, existing.currency == document.currency,
              existing.exchangeRate == document.exchangeRate, existing.cariAccountId == document.cariAccountId,
              existing.invoiceNo == document.invoiceNo, existing.reportedSettled == document.reportedSettled,
              existing.reportedSourceId == document.reportedSourceId, existing.reportedBy == document.reportedBy,
              existing.documentRef == document.documentRef, existing.notes == document.notes else {
          throw RepositoryError.conflict("Bu kimlikle farklı bir belge var")
        }
        return existing
      }
      guard existing.kind == draft.kind else { throw RepositoryError.validation("Belge türü değiştirilemez") }
      guard existing.status == .taslak else {
        throw RepositoryError.validation("Yalnızca taslak belge düzenlenir; onaylı belge iptal edilip yeniden oluşturulur")
      }
      guard existing.version == expectedVersion else {
        throw RepositoryError.conflict("Belge başka biri tarafından değiştirildi; yenileyip tekrar deneyin")
      }
      guard can(existing.kind, \.writePermission, existing.scope) else {
        throw RepositoryError.forbidden("Bu belgeyi düzenleme yetkiniz yok")
      }
      guard existing.isDemo == isDemo else {
        throw RepositoryError.validation("Demo belge gerçek kapsama taşınamaz (veya tersi)")
      }
      document.documentNo = existing.documentNo
      document.createdBy = existing.createdBy
      document.version = existing.version + 1
      financeDocumentList[index] = document
      financeEvent(id, "guncelle", from: "taslak", to: "taslak")
      return document
    }
    financeDocumentSequence += 1
    document.documentNo = (draft.kind == .gider ? "GD-" : "GL-") + String(format: "%06d", financeDocumentSequence)
    financeDocumentList.append(document)
    financeEvent(id, "olustur", from: nil, to: "taslak")
    return document
  }

  func approveFinanceDocument(id: UUID, expectedVersion: Int?, settlementId: UUID?) throws -> FinanceDocument {
    try failIfNeeded()
    let index = try documentIndex(id)
    var document = financeDocumentList[index]
    guard can(document.kind, \.approvePermission, document.scope) else {
      throw RepositoryError.forbidden("Belge onaylama yetkiniz yok")
    }
    if document.status == .onaylandi { return document }  // tekrar onay ikinci yükümlülük açmaz
    guard document.status == .taslak else { throw RepositoryError.validation("İptal edilmiş belge onaylanamaz") }
    if let expectedVersion, document.version != expectedVersion {
      throw RepositoryError.conflict("Belge onaydan önce değişti; yenileyip tekrar inceleyin")
    }
    if document.reportedSettled, !can(document.kind, \.settlePermission, document.scope) {
      throw RepositoryError.forbidden("Peşin ödenmiş/tahsil edilmiş belgeyi onaylamak için ödeme/tahsilat yetkisi de gerekir")
    }
    if let cariId = document.cariAccountId {
      let entryId = UUID()
      entries.append(StoredEntry(draft: CariEntryDraft(
        id: entryId, cariAccountId: cariId, scope: cariScope(document.scope), entryDate: document.documentDate,
        direction: document.kind == .gider ? .alacak : .borc, kind: document.kind == .gider ? .gider : .fatura,
        amount: document.amountTry, description: document.description,
        documentNo: document.invoiceNo ?? document.documentNo), reversalOf: nil, sequence: entries.count))
      document.cariEntryId = entryId
    }
    document.status = .onaylandi
    document.approvedAt = Date()
    document.version += 1
    financeDocumentList[index] = document
    financeEvent(id, "onayla", from: "taslak", to: "onaylandi")
    if document.reportedSettled, let source = document.reportedSourceId {
      _ = try settle(document, id: settlementId ?? UUID(), amount: document.amount, source: source,
                     date: document.documentDate, by: document.reportedBy,
                     description: document.kind == .gider ? "Peşin ödendi (sahadan bildirildi)" : "Peşin tahsil edildi",
                     rate: document.exchangeRate)
    }
    return document
  }

  private func settle(_ document: FinanceDocument, id: UUID, amount: Decimal, source: UUID, date: CalendarDate,
                      by: String?, description: String?, rate: Decimal?) throws -> FinanceSettlement {
    guard document.status == .onaylandi else {
      throw RepositoryError.validation("Ödeme/tahsilat yalnızca onaylı belgeye kaydedilir")
    }
    guard amount > 0, HakedisMath.scale(amount) <= 2 else {
      throw RepositoryError.validation("Tutar pozitif ve en çok iki ondalıklı olmalı")
    }
    guard paymentSourceList.contains(where: { $0.id == source && $0.isActive }) else {
      throw RepositoryError.validation("Ödeme kaynağı bulunamadı veya pasif")
    }
    let resolved = try HakedisMath.exchangeRate(currency: document.currency, rate: rate)
    let open = document.amount - settled(document.id)
    guard amount <= open else {
      throw RepositoryError.validation("Tutar kalan tutarı aşıyor (kalan \(Money.format(open, currency: document.currency)))")
    }
    var cariEntryId: UUID?
    if let cariId = document.cariAccountId, document.cariEntryId != nil {
      let entryId = UUID()
      entries.append(StoredEntry(draft: CariEntryDraft(
        id: entryId, cariAccountId: cariId, scope: cariScope(document.scope), entryDate: date,
        direction: document.kind == .gider ? .borc : .alacak, kind: document.kind == .gider ? .odeme : .tahsilat,
        amount: FinanceMath.toTry(amount, rate: resolved),
        description: description ?? "\(document.kind.settlementTitle) · \(document.description)",
        documentNo: document.invoiceNo ?? document.documentNo), reversalOf: nil, sequence: entries.count))
      cariEntryId = entryId
    }
    let settlement = FinanceSettlement(id: id, documentId: document.id, kind: document.kind.settlementKind, amount: amount,
                                       settlementDate: date, paymentSourceId: source, settledBy: by.nilIfBlank,
                                       description: description.nilIfBlank, exchangeRate: resolved,
                                       cariEntryId: cariEntryId, isDemo: document.isDemo)
    financeSettlementList.append(settlement)
    financeEvent(document.id, document.kind.settlementKind.rawValue, from: "onaylandi", to: "onaylandi")
    return settlement
  }

  func recordFinanceSettlement(_ draft: FinanceSettlementDraft) throws -> FinanceSettlement {
    try failIfNeeded()
    let document = try financeDocumentList[documentIndex(draft.documentId)]
    guard can(document.kind, \.settlePermission, document.scope) else {
      throw RepositoryError.forbidden("Ödeme/tahsilat kaydetme yetkiniz yok")
    }
    if let existing = financeSettlementList.first(where: { $0.id == draft.id }) {
      guard existing.status == .aktif else {
        throw RepositoryError.conflict("Bu kimlikli ödeme/tahsilat iptal edilmiş; yeni kayıt için yeniden deneyin")
      }
      let rate = try HakedisMath.exchangeRate(currency: document.currency, rate: draft.exchangeRate)
      guard existing.documentId == draft.documentId, existing.amount == draft.amount,
            existing.paymentSourceId == draft.paymentSourceId, existing.settlementDate == draft.settlementDate,
            existing.exchangeRate == rate, existing.settledBy == draft.settledBy.nilIfBlank,
            existing.description == draft.description.nilIfBlank else {
        throw RepositoryError.conflict(
          "Bu kimlikle farklı bir ödeme/tahsilat var (belge, tutar, kaynak, tarih, kur, ödeyen veya açıklama farklı)")
      }
      return existing
    }
    return try settle(document, id: draft.id, amount: draft.amount, source: draft.paymentSourceId,
                      date: draft.settlementDate, by: draft.settledBy, description: draft.description,
                      rate: draft.exchangeRate)
  }

  func cancelFinanceSettlement(id: UUID, reason: String) throws -> FinanceSettlement {
    try failIfNeeded()
    guard let index = financeSettlementList.firstIndex(where: { $0.id == id }),
          let document = financeDocumentList.first(where: { $0.id == financeSettlementList[index].documentId }),
          can(document.kind, \.settlePermission, document.scope) else {
      throw RepositoryError.forbidden("Ödeme/tahsilat bulunamadı veya yetkiniz yok")
    }
    guard financeSettlementList[index].status == .aktif else { return financeSettlementList[index] }
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 10 else { throw RepositoryError.validation("İptal gerekçesi en az 10 karakter olmalı") }
    if let entryId = financeSettlementList[index].cariEntryId { reverseFinanceEntry(entryId, reason: trimmed) }
    financeSettlementList[index].status = .iptal
    financeSettlementList[index].cancelReason = trimmed
    financeEvent(document.id, financeSettlementList[index].kind.rawValue + "_iptal", from: document.status.rawValue,
                 to: document.status.rawValue, reason: trimmed)
    return financeSettlementList[index]
  }

  private func cancelDocument(at index: Int, reason: String) throws {
    let document = financeDocumentList[index]
    guard settled(document.id) == 0 else {
      throw RepositoryError.validation("Ödemesi/tahsilatı olan belge iptal edilemez; önce ödeme/tahsilatı iptal edin")
    }
    if let entryId = document.cariEntryId { reverseFinanceEntry(entryId, reason: reason) }
    financeDocumentList[index].status = .iptal
    financeDocumentList[index].cancelledAt = Date()
    financeDocumentList[index].cancelReason = reason
    financeDocumentList[index].version += 1
  }

  func cancelFinanceDocument(id: UUID, reason: String) throws -> FinanceDocument {
    try failIfNeeded()
    let index = try documentIndex(id)
    let document = financeDocumentList[index]
    if document.status == .iptal { return document }
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    if document.status == .taslak {
      guard can(document.kind, \.writePermission, document.scope) else {
        throw RepositoryError.forbidden("Belgeyi iptal etme yetkiniz yok")
      }
      guard trimmed.count >= 3 else { throw RepositoryError.validation("İptal gerekçesi en az 3 karakter olmalı") }
    } else {
      guard can(document.kind, \.approvePermission, document.scope) else {
        throw RepositoryError.forbidden("Onaylı belgeyi iptal etmek için onay yetkisi gerekir")
      }
      guard trimmed.count >= 10 else { throw RepositoryError.validation("İptal gerekçesi en az 10 karakter olmalı") }
    }
    try cancelDocument(at: index, reason: trimmed)
    financeEvent(id, "iptal", from: document.status.rawValue, to: "iptal", reason: trimmed)
    return financeDocumentList[index]
  }

  func reviseFinanceDocument(id: UUID, newId: UUID, reason: String) throws -> FinanceDocument {
    try failIfNeeded()
    let index = try documentIndex(id)
    let document = financeDocumentList[index]
    guard can(document.kind, \.approvePermission, document.scope), can(document.kind, \.writePermission, document.scope) else {
      throw RepositoryError.forbidden("Belge düzeltme yetkiniz yok")
    }
    if let replacement = financeDocumentList.first(where: { $0.replacesId == id }) {
      guard replacement.id == newId else { throw RepositoryError.conflict("Bu belge zaten düzeltilmiş") }
      return replacement
    }
    guard document.status == .onaylandi else {
      throw RepositoryError.validation("Yalnızca onaylı belge düzeltilir; taslak doğrudan düzenlenir")
    }
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 10 else { throw RepositoryError.validation("Düzeltme gerekçesi en az 10 karakter olmalı") }
    try cancelDocument(at: index, reason: trimmed)
    financeEvent(id, "duzelt", from: "onaylandi", to: "iptal", reason: trimmed)
    financeDocumentSequence += 1
    let copy = FinanceDocument(
      id: newId, kind: document.kind, documentNo: (document.kind == .gider ? "GD-" : "GL-") + String(format: "%06d", financeDocumentSequence),
      scope: document.scope, categoryId: document.categoryId, cariAccountId: document.cariAccountId,
      description: document.description, documentDate: document.documentDate, dueDate: document.dueDate,
      amount: document.amount, currency: document.currency, exchangeRate: document.exchangeRate,
      invoiceNo: document.invoiceNo, documentRef: document.documentRef, notes: document.notes, replacesId: id,
      createdBy: profile.id, isDemo: document.isDemo)
    financeDocumentList.append(copy)
    financeEvent(newId, "olustur", from: nil, to: "taslak", reason: trimmed)
    return copy
  }

  func financeDocumentEvents(documentId: UUID) throws -> [FinanceDocumentEvent] {
    try failIfNeeded()
    _ = try documentIndex(documentId)
    return financeDocumentEvents.filter { $0.documentId == documentId }.sorted { $0.occurredAt > $1.occurredAt }
  }

  func financeSettlements(documentId: UUID) throws -> [FinanceSettlement] {
    try failIfNeeded()
    _ = try documentIndex(documentId)
    return financeSettlementList.filter { $0.documentId == documentId }
      .sorted { $0.settlementDate > $1.settlementDate }
  }

  // MARK: Raporlar

  func financeReport(kind: FinanceDocKind, group: FinanceReportGroup, from: CalendarDate?, to: CalendarDate?,
                     projectId: UUID?, costCenterId: UUID?) throws -> [FinanceReportRow] {
    try failIfNeeded()
    func inScope(_ d: FinanceDocument) -> Bool {
      d.kind == kind && can(kind, \.readPermission, d.scope)
        && (d.projectId.map { access.can(.finansRaporRead, in: $0) } ?? access.can(.finansRaporRead))
        && (projectId == nil || d.projectId == projectId) && (costCenterId == nil || d.costCenterId == costCenterId)
    }
    if group == .kaynak {
      let rows = financeSettlementList.filter { s in
        s.status == .aktif && (from.map { s.settlementDate >= $0 } ?? true) && (to.map { s.settlementDate <= $0 } ?? true)
          && financeDocumentList.contains { $0.id == s.documentId && inScope($0) }
      }
      return Dictionary(grouping: rows, by: \.paymentSourceId).map { sourceId, items in
        FinanceReportRow(groupKey: sourceId.uuidString.lowercased(),
                         label: paymentSourceList.first { $0.id == sourceId }?.name ?? "Kaynak",
                         documentCount: Set(items.map(\.documentId)).count, accruedTry: 0,
                         settledTry: items.reduce(0) { $0 + $1.amountTry }, openTry: 0, overdueTry: 0)
      }
      .sorted { $0.settledTry > $1.settledTry }
    }
    let documents = financeDocumentList.filter { d in
      d.status == .onaylandi && inScope(d)
        && (from.map { d.documentDate >= $0 } ?? true) && (to.map { d.documentDate <= $0 } ?? true)
    }
    let grouped = Dictionary(grouping: documents) { d -> String in
      switch group {
      case .proje: (d.projectId ?? d.costCenterId)?.uuidString.lowercased() ?? "-"
      case .kategori: d.categoryId.uuidString.lowercased()
      case .cari: d.cariAccountId?.uuidString.lowercased() ?? "-"
      case .ay, .kaynak: String(d.documentDate.iso.prefix(7))
      }
    }
    let rows = grouped.map { key, items -> FinanceReportRow in
      let first = items[0]
      let label: String = switch group {
      case .proje:
        if let project = projects.first(where: { $0.id == first.projectId }) { "\(project.code) · \(project.name)" }
        else { "Genel · " + (costCenters.first { $0.id == first.costCenterId }?.name ?? "") }
      case .kategori: financeCategoryList.first { $0.id == first.categoryId }?.name ?? "Kategori"
      case .cari: accounts.first { $0.id == first.cariAccountId }?.title ?? "Cari bağlantısız"
      case .ay, .kaynak: key
      }
      let statuses = items.map { FinanceMath.status(of: $0, settlements: financeSettlementList, today: today) }
      return FinanceReportRow(
        groupKey: key, label: label, documentCount: items.count,
        accruedTry: items.reduce(0) { $0 + $1.amountTry }, settledTry: statuses.reduce(0) { $0 + $1.settledTry },
        openTry: statuses.reduce(0) { $0 + $1.remainingTry },
        overdueTry: statuses.filter(\.isOverdue).reduce(0) { $0 + $1.remainingTry })
    }
    return group == .ay ? rows.sorted { $0.groupKey < $1.groupKey } : rows.sorted { $0.accruedTry > $1.accruedTry }
  }

  /// Gider ve gelir sütunları; hakediş sütunları bellek içi örnekte yalnızca
  /// deftere işlenmiş hakedişlerden ve ödemelerden hesaplanır.
  func projectCosts(projectId: UUID?) throws -> [ProjectCostRow] {
    try failIfNeeded()
    return projects.filter { (projectId == nil || $0.id == projectId) && access.can(.finansRaporRead, in: $0.id) }
      .map { project in
        let docs = financeDocumentList.filter { $0.projectId == project.id && $0.status == .onaylandi }
        let statuses = docs.map { FinanceMath.status(of: $0, settlements: financeSettlementList, today: today) }
        func sum(_ kind: FinanceDocKind, _ value: (FinanceDocumentStatus) -> Decimal) -> Decimal {
          statuses.filter { $0.kind == kind }.reduce(0) { $0 + value($1) }
        }
        let gider = access.can(.giderRead, in: project.id)
        let gelir = access.can(.gelirRead, in: project.id)
        let hakedis = access.can(.hakedisRead, in: project.id)
        let posted = hakedisRecords.filter { $0.projectId == project.id && $0.status == .onaylandi && $0.isPosted }
        let unposted = hakedisRecords.filter { $0.projectId == project.id && $0.status == .onaylandi && !$0.isPosted }
        let contractIds = Set(contractList.filter { $0.projectId == project.id }.map(\.id))
        let payments = financePaymentList.filter { contractIds.contains($0.contractId) && $0.status == .aktif }
        let docTry: (FinanceDocKind) -> Decimal = { kind in docs.filter { $0.kind == kind }.reduce(0) { $0 + $1.amountTry } }
        return ProjectCostRow(
          projectId: project.id, projectLabel: "\(project.code) · \(project.name)",
          expenseAccruedTry: gider ? docTry(.gider) : nil, expensePaidTry: gider ? sum(.gider, \.settledTry) : nil,
          expenseOpenTry: gider ? sum(.gider, \.remainingTry) : nil,
          hakedisAccruedTry: hakedis ? posted.reduce(0) { $0 + $1.grossAmount + $1.kdvAmount } : nil,
          hakedisUnpostedTry: hakedis ? unposted.reduce(0) { $0 + $1.grossAmount + $1.kdvAmount } : nil,
          hakedisPaidTry: hakedis ? payments.filter { $0.kind == .odeme && $0.hakedisId != nil }.reduce(0) { $0 + $1.amount } : nil,
          advancePaidTry: hakedis ? payments.filter { $0.kind == .avans }.reduce(0) { $0 + $1.amount } : nil,
          advanceDeductedTry: hakedis ? posted.reduce(0) { $0 + $1.advanceAmount } : nil,
          incomeAccruedTry: gelir ? docTry(.gelir) : nil, incomeCollectedTry: gelir ? sum(.gelir, \.settledTry) : nil)
      }
  }
}

struct InMemoryFinance: FinanceRepository {
  let backend: InMemoryBackend

  func categories(kind: FinanceDocKind?, includeInactive: Bool) async throws -> [FinanceCategory] {
    try await backend.financeCategories(kind: kind, includeInactive: includeInactive)
  }
  func saveCategory(_ category: FinanceCategory) async throws -> FinanceCategory {
    try await backend.saveFinanceCategory(category)
  }
  func documents(filter: FinanceDocumentFilter) async throws -> [FinanceDocument] {
    try await backend.financeDocuments(filter: filter)
  }
  func document(id: UUID) async throws -> FinanceDocument { try await backend.financeDocument(id: id) }
  func documents(ids: [UUID]) async throws -> [FinanceDocument] { try await backend.financeDocuments(ids: ids) }
  func statuses(documentIds: [UUID]) async throws -> [FinanceDocumentStatus] {
    try await backend.financeStatuses(documentIds: documentIds)
  }
  func openStatuses(kind: FinanceDocKind) async throws -> [FinanceDocumentStatus] {
    try await backend.financeOpenStatuses(kind: kind)
  }
  func saveDocument(id: UUID, draft: FinanceDocumentDraft, expectedVersion: Int?) async throws -> FinanceDocument {
    try await backend.saveFinanceDocument(id: id, draft: draft, expectedVersion: expectedVersion)
  }
  func approve(id: UUID, expectedVersion: Int?, settlementId: UUID?) async throws -> FinanceDocument {
    try await backend.approveFinanceDocument(id: id, expectedVersion: expectedVersion, settlementId: settlementId)
  }
  func cancel(id: UUID, reason: String) async throws -> FinanceDocument {
    try await backend.cancelFinanceDocument(id: id, reason: reason)
  }
  func revise(id: UUID, newId: UUID, reason: String) async throws -> FinanceDocument {
    try await backend.reviseFinanceDocument(id: id, newId: newId, reason: reason)
  }
  func events(documentId: UUID) async throws -> [FinanceDocumentEvent] {
    try await backend.financeDocumentEvents(documentId: documentId)
  }
  func settlements(documentId: UUID) async throws -> [FinanceSettlement] {
    try await backend.financeSettlements(documentId: documentId)
  }
  func recordSettlement(_ draft: FinanceSettlementDraft) async throws -> FinanceSettlement {
    try await backend.recordFinanceSettlement(draft)
  }
  func cancelSettlement(id: UUID, reason: String) async throws -> FinanceSettlement {
    try await backend.cancelFinanceSettlement(id: id, reason: reason)
  }
  func report(kind: FinanceDocKind, group: FinanceReportGroup, from: CalendarDate?, to: CalendarDate?,
              projectId: UUID?, costCenterId: UUID?) async throws -> [FinanceReportRow] {
    try await backend.financeReport(kind: kind, group: group, from: from, to: to, projectId: projectId,
                                    costCenterId: costCenterId)
  }
  func projectCosts(projectId: UUID?) async throws -> [ProjectCostRow] {
    try await backend.projectCosts(projectId: projectId)
  }
}
