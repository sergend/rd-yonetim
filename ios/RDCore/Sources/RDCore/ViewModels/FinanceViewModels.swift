import Foundation
import Observation

// Gider, gelir ve borç/alacak ekranlarının view model'leri (Aşama 5).
// Tutar ve durum hesabı sunucudadır; burada yalnızca giriş doğrulaması,
// filtreleme ve gruplama yapılır. Kasa veya banka bakiyesi hesaplanmaz.

// MARK: - Liste

@MainActor
@Observable
public final class FinanceDocumentListViewModel {
  /// Hızlı durum filtresi.
  public enum StateFilter: String, CaseIterable, Identifiable, Sendable {
    case tumu, onayBekleyen, acik, gecikmis, kapanan, iptal

    public var id: String { rawValue }

    public func title(for kind: FinanceDocKind) -> String {
      switch self {
      case .tumu: "Tümü"
      case .onayBekleyen: "Onay bekleyen"
      case .acik: kind == .gider ? "Ödenmemiş" : "Tahsil edilmemiş"
      case .gecikmis: "Vadesi geçmiş"
      case .kapanan: kind == .gider ? "Tamamen ödenmiş" : "Tamamen tahsil edilmiş"
      case .iptal: "İptal"
      }
    }
  }

  public enum Period: String, CaseIterable, Identifiable, Sendable {
    case buAy, son3Ay, buYil, tumu

    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .buAy: "Bu ay"
      case .son3Ay: "Son 3 ay"
      case .buYil: "Bu yıl"
      case .tumu: "Tüm zamanlar"
      }
    }

    public func range(today: CalendarDate) -> (CalendarDate?, CalendarDate?) {
      switch self {
      case .buAy: (CalendarDate(year: today.year, month: today.month, day: 1), nil)
      case .son3Ay: (today.adding(days: -92), nil)
      case .buYil: (CalendarDate(year: today.year, month: 1, day: 1), nil)
      case .tumu: (nil, nil)
      }
    }
  }

  public private(set) var documents: [FinanceDocument] = []
  public private(set) var statuses: [UUID: FinanceDocumentStatus] = [:]
  public private(set) var categories: [FinanceCategory] = []
  public private(set) var accounts: [UUID: CariAccount] = [:]
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  public var searchText = ""
  public var stateFilter: StateFilter = .tumu
  public var categoryId: UUID?
  /// Değiştiğinde ekran `load()` çağırır (dönem sunucuda filtrelenir).
  public var period: Period = .tumu

  public let kind: FinanceDocKind
  public let projectId: UUID?
  public let access: AccessControl
  private let repositories: Repositories
  private let today: CalendarDate

  public init(kind: FinanceDocKind, projectId: UUID? = nil, access: AccessControl, repositories: Repositories,
              today: CalendarDate = .today()) {
    self.kind = kind
    self.projectId = projectId
    self.access = access
    self.repositories = repositories
    self.today = today
  }

  public var canCreate: Bool {
    if let projectId { return access.can(kind.writePermission, in: projectId) }
    return access.canAnywhere(kind.writePermission)
  }

  public func categoryName(_ id: UUID) -> String { categories.first { $0.id == id }?.name ?? "Kategori" }
  public func cariName(_ id: UUID?) -> String? { id.flatMap { accounts[$0]?.title } }
  public func status(_ document: FinanceDocument) -> FinanceDocumentStatus? { statuses[document.id] }

  public var filtered: [FinanceDocument] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased(with: Money.locale)
    return documents.filter { document in
      if let categoryId, document.categoryId != categoryId { return false }
      if !matches(document) { return false }
      guard !query.isEmpty else { return true }
      let haystack = [document.description, document.documentNo, document.invoiceNo ?? "", document.notes ?? "",
                      categoryName(document.categoryId), cariName(document.cariAccountId) ?? "",
                      DecimalInput.format(document.amount, maxFractionDigits: 2)]
        .joined(separator: " ").lowercased(with: Money.locale)
      return haystack.contains(query)
    }
  }

  private func matches(_ document: FinanceDocument) -> Bool {
    let state = statuses[document.id]
    switch stateFilter {
    case .tumu: return document.status != .iptal
    case .onayBekleyen: return document.status == .taslak
    case .acik: return state?.settlementState.isOpen ?? false
    case .gecikmis: return state?.isOverdue ?? false
    case .kapanan: return state?.settlementState == .kapandi
    case .iptal: return document.status == .iptal
    }
  }

  /// Onay bekleyen belge sayısı (filtre rozetleri için).
  public var pendingApprovalCount: Int { documents.filter { $0.status == .taslak }.count }
  public var overdueCount: Int { statuses.values.filter(\.isOverdue).count }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    let (from, to) = period.range(today: today)
    do {
      async let docs = repositories.finance.documents(filter: FinanceDocumentFilter(kind: kind, projectId: projectId,
                                                                                    from: from, to: to))
      async let cats = repositories.finance.categories(kind: kind, includeInactive: true)
      let loaded = try await docs
      categories = try await cats
      let rows = try await repositories.finance.statuses(documentIds: loaded.map(\.id))
      documents = loaded
      statuses = Dictionary(rows.map { ($0.documentId, $0) }, uniquingKeysWith: { $1 })
      if access.canAnywhere(.cariRead), loaded.contains(where: { $0.cariAccountId != nil }) {
        let list = (try? await repositories.cari.listAccounts(type: nil, search: nil)) ?? []
        accounts = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
      }
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Kaydedilen/güncellenen belgeyi listeye yansıtır ve durumunu yeniler.
  public func upsert(_ document: FinanceDocument) async {
    if let index = documents.firstIndex(where: { $0.id == document.id }) {
      documents[index] = document
    } else {
      documents.insert(document, at: 0)
    }
    if let row = try? await repositories.finance.statuses(documentIds: [document.id]).first {
      statuses[document.id] = row
    }
  }
}

// MARK: - Form (hızlı giriş)

/// Gider/gelir girişi. Zorunlu alanlar: kapsam (proje veya genel masraf
/// merkezi), kategori, açıklama ve tutar. Diğer alanlar isteğe bağlıdır.
/// Belge kimliği form açılırken üretilir; ağ hatasından sonra tekrar
/// gönderim aynı kimliği kullanır ve ikinci belge açılmaz.
@MainActor
@Observable
public final class FinanceDocumentFormViewModel {
  public enum ScopeChoice: Hashable, Sendable { case project, costCenter }

  public var scopeChoice: ScopeChoice
  public var projectId: UUID?
  public var costCenterId: UUID?
  public var categoryId: UUID?
  public var descriptionText = ""
  public var amountText = ""
  public var documentDate = Date()
  public var hasDueDate = false
  public var dueDate = Date()
  public var currency = "TRY"
  public var rateText = ""
  public var cariAccountId: UUID?
  public var invoiceNo = ""
  public var documentRef = ""
  public var notes = ""
  /// "Peşin ödendi / tahsil edildi" (sahadan bildirim; onayda ödeme kaydına dönüşür).
  public var reportedSettled = false
  public var reportedSourceId: UUID?
  public var reportedBy = ""

  public private(set) var categories: [FinanceCategory] = []
  public private(set) var accounts: [CariAccount] = []
  public private(set) var paymentSources: [PaymentSource] = []
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?
  public private(set) var documentId: UUID

  public let kind: FinanceDocKind
  public let editing: FinanceDocument?
  public let projects: [Project]
  public let costCenters: [CostCenter]
  public static let currencies = ["TRY", "USD", "EUR"]

  private let access: AccessControl
  private let repositories: Repositories

  public init(kind: FinanceDocKind, editing: FinanceDocument? = nil, access: AccessControl, projects: [Project],
              costCenters: [CostCenter], preselectedProject: UUID? = nil, repositories: Repositories) {
    self.kind = kind
    self.editing = editing
    self.access = access
    self.repositories = repositories
    self.documentId = editing?.id ?? UUID()
    self.projects = projects.filter { access.can(kind.writePermission, in: $0.id) && $0.status != .tamamlandi }
    self.costCenters = access.can(kind.writePermission) ? costCenters.filter(\.isActive) : []
    scopeChoice = self.projects.isEmpty && !self.costCenters.isEmpty ? .costCenter : .project
    projectId = preselectedProject.flatMap { id in self.projects.first { $0.id == id }?.id }
      ?? (self.projects.count == 1 ? self.projects.first?.id : nil)
    costCenterId = self.costCenters.count == 1 ? self.costCenters.first?.id : nil
    if let editing { fill(from: editing) }
  }

  private func fill(from d: FinanceDocument) {
    if let project = d.projectId {
      scopeChoice = .project
      projectId = project
    } else {
      scopeChoice = .costCenter
      costCenterId = d.costCenterId
    }
    categoryId = d.categoryId
    descriptionText = d.description
    amountText = DecimalInput.format(d.amount, maxFractionDigits: 2)
    documentDate = d.documentDate.date()
    hasDueDate = d.dueDate != d.documentDate
    dueDate = d.dueDate.date()
    currency = d.currency
    rateText = d.currency == "TRY" ? "" : DecimalInput.format(d.exchangeRate, maxFractionDigits: 6)
    cariAccountId = d.cariAccountId
    invoiceNo = d.invoiceNo ?? ""
    documentRef = d.documentRef ?? ""
    notes = d.notes ?? ""
    reportedSettled = d.reportedSettled
    reportedSourceId = d.reportedSourceId
    reportedBy = d.reportedBy ?? ""
  }

  public var formTitle: String {
    editing == nil ? (kind == .gider ? "Yeni gider" : "Yeni gelir") : "\(editing?.documentNo ?? "") düzenle"
  }

  public var canPickCari: Bool { access.canAnywhere(.cariRead) }
  public var settledLabel: String { kind == .gider ? "Peşin ödendi" : "Peşin tahsil edildi" }
  public var activeCategories: [FinanceCategory] { categories.filter(\.isActive) }
  public var amount: Decimal? { Money.parse(amountText) }
  public var exchangeRate: Decimal? { currency == "TRY" ? nil : HakedisMath.parseExchangeRate(rateText) }

  /// Seçilen kapsamın DEMO işareti; cari aynı işaretli olmalı.
  private var scopeIsDemo: Bool? {
    switch scopeChoice {
    case .project: projectId.flatMap { id in projects.first { $0.id == id }?.isDemo }
    case .costCenter: costCenterId.flatMap { id in costCenters.first { $0.id == id }?.isDemo }
    }
  }

  /// Kapsamla aynı DEMO işaretli etkin cariler.
  public var selectableAccounts: [CariAccount] {
    accounts.filter { $0.isActive && (scopeIsDemo == nil || $0.isDemo == scopeIsDemo) }
  }

  public var scope: FinanceScope? {
    switch scopeChoice {
    case .project: projectId.map(FinanceScope.project)
    case .costCenter: costCenterId.map(FinanceScope.costCenter)
    }
  }

  public var validationMessage: String? {
    if scope == nil { return "Proje veya genel masraf merkezi seçin." }
    if categoryId == nil { return "Kategori seçin." }
    if descriptionText.nilIfBlank == nil { return "Açıklama yazın." }
    guard let amount, amount > 0 else {
      return amountText.isEmpty ? "Tutarı girin." : "Tutar geçersiz (en fazla 2 ondalık)."
    }
    if amount >= 1_000_000_000_000 { return "Tutar çok büyük." }
    if CalendarDate(documentDate) > .today() { return "İleri tarihli belge girilemez." }
    if hasDueDate, CalendarDate(dueDate) < CalendarDate(documentDate) { return "Vade, belge tarihinden önce olamaz." }
    if currency != "TRY" {
      guard let rate = exchangeRate else { return rateText.isEmpty ? "\(currency) için kur zorunlu." : "Kur geçersiz." }
      if HakedisMath.scale(rate) > 6 { return "Kur en çok 6 ondalıklı olmalı." }
    }
    if reportedSettled, reportedSourceId == nil {
      return kind == .gider ? "Ödemenin yapıldığı kaynağı seçin." : "Tahsilatın yapıldığı kaynağı seçin."
    }
    if let cariAccountId, let account = accounts.first(where: { $0.id == cariAccountId }), let demo = scopeIsDemo,
       account.isDemo != demo {
      return "Demo cari gerçek kayıtla (veya tersi) kullanılamaz."
    }
    return nil
  }

  public var canSave: Bool { validationMessage == nil && !isSaving }

  public var draft: FinanceDocumentDraft? {
    guard validationMessage == nil, let scope, let categoryId, let amount,
          let description = descriptionText.nilIfBlank else { return nil }
    return FinanceDocumentDraft(
      kind: kind, scope: scope, categoryId: categoryId, description: description, amount: amount,
      documentDate: CalendarDate(documentDate), dueDate: hasDueDate ? CalendarDate(dueDate) : nil, currency: currency,
      exchangeRate: exchangeRate, cariAccountId: cariAccountId, invoiceNo: invoiceNo.nilIfBlank,
      documentRef: documentRef.nilIfBlank, notes: notes.nilIfBlank, reportedSettled: reportedSettled,
      reportedSourceId: reportedSettled ? reportedSourceId : nil,
      reportedBy: reportedSettled ? reportedBy.nilIfBlank : nil)
  }

  public func loadLookups() async {
    do {
      categories = try await repositories.finance.categories(kind: kind, includeInactive: false)
      paymentSources = (try? await repositories.contracts.paymentSources()) ?? []
      if canPickCari { accounts = (try? await repositories.cari.listAccounts(type: nil, search: nil)) ?? [] }
      if categoryId == nil, categories.count == 1 { categoryId = categories.first?.id }
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func save() async -> FinanceDocument? {
    if let validationMessage {
      errorMessage = validationMessage
      return nil
    }
    guard let draft else { return nil }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      return try await repositories.finance.saveDocument(id: documentId, draft: draft, expectedVersion: editing?.version)
    } catch {
      errorMessage = message(for: error)
      return nil
    }
  }

  /// "Kaydet ve yeni": kapsam, kategori ve tarih korunur; yeni kimlik üretilir.
  public func resetForNext() {
    guard editing == nil else { return }
    documentId = UUID()
    descriptionText = ""
    amountText = ""
    invoiceNo = ""
    documentRef = ""
    notes = ""
    cariAccountId = nil
    reportedSettled = false
    reportedBy = ""
    hasDueDate = false
    errorMessage = nil
  }
}

// MARK: - Detay

@MainActor
@Observable
public final class FinanceDocumentDetailViewModel {
  public private(set) var document: FinanceDocument
  public private(set) var status: FinanceDocumentStatus?
  public private(set) var settlements: [FinanceSettlement] = []
  public private(set) var events: [FinanceDocumentEvent] = []
  public private(set) var categoryName: String?
  public private(set) var cariAccount: CariAccount?
  public private(set) var paymentSources: [PaymentSource] = []
  public private(set) var replacement: FinanceDocument?
  public private(set) var isLoading = false
  public private(set) var isWorking = false
  public private(set) var errorMessage: String?
  /// Sonuçlanmamış ödeme denemesinin kimliği: aynı ödemeyi tekrar gönderirken
  /// kullanılır, sunucu ikinci ödeme açmaz. Başarılı kayıttan sonra yenilenir.
  public private(set) var pendingSettlementId = UUID()
  private var pendingSettlementKey: String?

  public let access: AccessControl
  private let repositories: Repositories

  public init(document: FinanceDocument, access: AccessControl, repositories: Repositories) {
    self.document = document
    self.access = access
    self.repositories = repositories
  }

  private func can(_ key: PermissionKey) -> Bool {
    if let project = document.projectId { return access.can(key, in: project) }
    return access.can(key)
  }

  public var kind: FinanceDocKind { document.kind }
  public var remaining: Decimal { status?.remainingAmount ?? 0 }
  public var activeSettlements: [FinanceSettlement] { settlements.filter { $0.status == .aktif } }
  public var stateTitle: String { (status?.settlementState ?? .taslak).title(for: kind) }

  public var canEdit: Bool { document.status == .taslak && can(kind.writePermission) }
  public var canApprove: Bool {
    document.status == .taslak && can(kind.approvePermission) && (!document.reportedSettled || can(kind.settlePermission))
  }
  /// Onay yetkisi var ama peşin bildirim için ödeme yetkisi eksik.
  public var approveNeedsSettlePermission: Bool {
    document.status == .taslak && can(kind.approvePermission) && document.reportedSettled && !can(kind.settlePermission)
  }
  public var canSettle: Bool { document.status == .onaylandi && remaining > 0 && can(kind.settlePermission) }
  public var canCancelSettlement: Bool { can(kind.settlePermission) }
  public var canCancel: Bool {
    switch document.status {
    case .taslak: can(kind.writePermission)
    case .onaylandi: can(kind.approvePermission) && activeSettlements.isEmpty
    case .iptal: false
    }
  }
  public var canRevise: Bool {
    document.status == .onaylandi && can(kind.approvePermission) && can(kind.writePermission)
      && activeSettlements.isEmpty && replacement == nil
  }
  /// Onaylı belgede iptal için gereken gerekçe uzunluğu (taslakta 3).
  public var cancelReasonMinimum: Int { document.status == .taslak ? 3 : 10 }

  public func sourceName(_ id: UUID?) -> String? {
    id.flatMap { id in paymentSources.first { $0.id == id }?.name }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      document = try await repositories.finance.document(id: document.id)
      async let statusRows = repositories.finance.statuses(documentIds: [document.id])
      async let settlementRows = repositories.finance.settlements(documentId: document.id)
      async let eventRows = repositories.finance.events(documentId: document.id)
      async let categoryRows = repositories.finance.categories(kind: document.kind, includeInactive: true)
      status = try await statusRows.first
      settlements = try await settlementRows
      events = try await eventRows
      categoryName = try await categoryRows.first { $0.id == document.categoryId }?.name
      paymentSources = (try? await repositories.contracts.paymentSources()) ?? paymentSources
      if let cariId = document.cariAccountId, access.canAnywhere(.cariRead) {
        cariAccount = try? await repositories.cari.getAccount(id: cariId)
      }
      if document.status == .iptal {
        let all = try await repositories.finance.documents(filter: FinanceDocumentFilter(
          kind: document.kind, projectId: document.projectId, costCenterId: document.costCenterId))
        replacement = all.first { $0.replacesId == document.id }
      }
    } catch {
      errorMessage = message(for: error)
    }
  }

  private func perform(_ work: () async throws -> Void) async -> Bool {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await work()
      await load()
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  public func approve(settlementId: UUID = UUID()) async -> Bool {
    let version = document.version
    return await perform {
      document = try await repositories.finance.approve(id: document.id, expectedVersion: version,
                                                        settlementId: document.reportedSettled ? settlementId : nil)
    }
  }

  /// Kısmi veya tam ödeme/tahsilat. Aynı girdiyle tekrar deneme (ör. ağ
  /// hatasından sonra) aynı kimliği kullanır, sunucu ikinci ödeme açmaz; girdi
  /// değişirse yeni kimlik üretilir. Sunucu kimliği reddederse (farklı içerik
  /// veya iptal edilmiş kayıt) sonraki deneme yeni kimlikle yapılır.
  public func recordSettlement(amount: Decimal, sourceId: UUID, date: CalendarDate, settledBy: String?,
                               description: String?, exchangeRate: Decimal?) async -> Bool {
    let by = settledBy?.nilIfBlank
    let note = description?.nilIfBlank
    let key = [ "\(amount)", sourceId.uuidString, date.iso, exchangeRate.map { "\($0)" } ?? "", by ?? "", note ?? "" ]
      .joined(separator: "|")
    if pendingSettlementKey != key {
      pendingSettlementId = UUID()
      pendingSettlementKey = key
    }
    let draft = FinanceSettlementDraft(id: pendingSettlementId, documentId: document.id, amount: amount,
                                       paymentSourceId: sourceId, settlementDate: date, settledBy: by,
                                       description: note, exchangeRate: exchangeRate)
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      _ = try await repositories.finance.recordSettlement(draft)
      pendingSettlementId = UUID()
      pendingSettlementKey = nil
      await load()
      return true
    } catch {
      if case RepositoryError.conflict = error {
        pendingSettlementId = UUID()
        pendingSettlementKey = nil
      }
      errorMessage = message(for: error)
      return false
    }
  }

  public func cancelSettlement(_ settlement: FinanceSettlement, reason: String) async -> Bool {
    await perform { _ = try await repositories.finance.cancelSettlement(id: settlement.id, reason: reason) }
  }

  public func cancel(reason: String) async -> Bool {
    await perform { document = try await repositories.finance.cancel(id: document.id, reason: reason) }
  }

  /// Onaylı belgeyi iptal edip düzeltme taslağı açar; yeni taslağı döner.
  public func revise(newId: UUID = UUID(), reason: String) async -> FinanceDocument? {
    var created: FinanceDocument?
    _ = await perform { created = try await repositories.finance.revise(id: document.id, newId: newId, reason: reason) }
    return created
  }

  public func didSave(_ updated: FinanceDocument) async {
    document = updated
    await load()
  }
}

// MARK: - Bekleyen borçlar / alacaklar

@MainActor
@Observable
public final class PayablesViewModel {
  public struct Item: Identifiable, Hashable, Sendable {
    public let document: FinanceDocument
    public let status: FinanceDocumentStatus
    public var id: UUID { document.id }
  }

  public enum Bucket: String, CaseIterable, Identifiable, Sendable {
    case gecikmis, buHafta, sonra

    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .gecikmis: "Vadesi geçmiş"
      case .buHafta: "7 gün içinde"
      case .sonra: "Daha sonra"
      }
    }
  }

  public private(set) var items: [Item] = []
  public private(set) var accounts: [UUID: CariAccount] = [:]
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?
  public var searchText = ""
  public var projectId: UUID?

  public let kind: FinanceDocKind
  private let access: AccessControl
  private let repositories: Repositories
  private let today: CalendarDate

  public init(kind: FinanceDocKind = .gider, access: AccessControl, repositories: Repositories,
              today: CalendarDate = .today()) {
    self.kind = kind
    self.access = access
    self.repositories = repositories
    self.today = today
  }

  public var title: String { kind == .gider ? "Bekleyen borçlar" : "Bekleyen alacaklar" }

  public func bucket(_ item: Item) -> Bucket {
    if item.status.isOverdue { return .gecikmis }
    return item.status.dueDate <= today.adding(days: 7) ? .buHafta : .sonra
  }

  public var visible: [Item] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased(with: Money.locale)
    return items.filter { item in
      if let projectId, item.document.projectId != projectId { return false }
      guard !query.isEmpty else { return true }
      return [item.document.description, item.document.documentNo, item.document.invoiceNo ?? "",
              cariName(item.document.cariAccountId) ?? ""]
        .joined(separator: " ").lowercased(with: Money.locale).contains(query)
    }
  }

  public func items(in bucket: Bucket) -> [Item] { visible.filter { self.bucket($0) == bucket } }

  /// Gruptaki kalan tutarların TL karşılığı (belge kuruyla).
  public func remainingTry(in bucket: Bucket) -> Decimal {
    items(in: bucket).reduce(0) { $0 + $1.status.remainingTry }
  }

  public func cariName(_ id: UUID?) -> String? { id.flatMap { accounts[$0]?.title } }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      let statuses = try await repositories.finance.openStatuses(kind: kind)
      let documents = try await repositories.finance.documents(ids: statuses.map(\.documentId))
      let byId = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
      items = statuses.compactMap { status in byId[status.documentId].map { Item(document: $0, status: status) } }
        .sorted { ($0.status.dueDate, $0.document.documentNo) < ($1.status.dueDate, $1.document.documentNo) }
      if access.canAnywhere(.cariRead), documents.contains(where: { $0.cariAccountId != nil }) {
        let list = (try? await repositories.cari.listAccounts(type: nil, search: nil)) ?? []
        accounts = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
      }
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - Raporlar

@MainActor
@Observable
public final class FinanceReportViewModel {
  public enum Mode: String, CaseIterable, Identifiable, Sendable {
    case gider, gelir, projeMaliyeti

    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .gider: "Gider"
      case .gelir: "Gelir"
      case .projeMaliyeti: "Proje maliyeti"
      }
    }
  }

  public private(set) var rows: [FinanceReportRow] = []
  public private(set) var projectCosts: [ProjectCostRow] = []
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  public var mode: Mode = .gider
  public var group: FinanceReportGroup = .kategori
  public var period: FinanceDocumentListViewModel.Period = .buYil
  public var projectId: UUID?

  private let access: AccessControl
  private let repositories: Repositories
  private let today: CalendarDate

  public init(access: AccessControl, repositories: Repositories, today: CalendarDate = .today()) {
    self.access = access
    self.repositories = repositories
    self.today = today
    if !access.canAnywhere(.giderRead), access.canAnywhere(.gelirRead) { mode = .gelir }
  }

  public var availableModes: [Mode] {
    var modes: [Mode] = []
    if access.canAnywhere(.giderRead) { modes.append(.gider) }
    if access.canAnywhere(.gelirRead) { modes.append(.gelir) }
    modes.append(.projeMaliyeti)
    return modes
  }

  public var kind: FinanceDocKind { mode == .gelir ? .gelir : .gider }
  public var settledTitle: String { kind == .gider ? "Ödenen" : "Tahsil edilen" }
  /// Ödeme kaynağı grubunda yalnızca dönem içindeki ödeme/tahsilatlar gösterilir.
  public var isSourceGroup: Bool { group == .kaynak }

  public var totalAccrued: Decimal { rows.reduce(0) { $0 + $1.accruedTry } }
  public var totalSettled: Decimal { rows.reduce(0) { $0 + $1.settledTry } }
  public var totalOpen: Decimal { rows.reduce(0) { $0 + $1.openTry } }
  public var totalOverdue: Decimal { rows.reduce(0) { $0 + $1.overdueTry } }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      if mode == .projeMaliyeti {
        projectCosts = try await repositories.finance.projectCosts(projectId: projectId)
        rows = []
      } else {
        let (from, to) = period.range(today: today)
        rows = try await repositories.finance.report(kind: kind, group: group, from: from, to: to,
                                                     projectId: projectId, costCenterId: nil)
        projectCosts = []
      }
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - Kategoriler

@MainActor
@Observable
public final class FinanceCategoryListViewModel {
  public private(set) var categories: [FinanceCategory] = []
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?
  public var kind: FinanceDocKind

  public let canManage: Bool
  private let repository: FinanceRepository

  public init(kind: FinanceDocKind = .gider, access: AccessControl, repository: FinanceRepository) {
    self.kind = kind
    self.canManage = access.can(.finansKategoriManage)
    self.repository = repository
  }

  public var visible: [FinanceCategory] { categories.filter { $0.kind == kind } }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      categories = try await repository.categories(kind: nil, includeInactive: true)
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Yeni kategori veya ad/sıra/etkinlik değişikliği. Kategori silinmez, pasif yapılır.
  public func save(_ category: FinanceCategory) async -> Bool {
    errorMessage = nil
    guard category.name.nilIfBlank != nil else {
      errorMessage = "Kategori adı zorunlu."
      return false
    }
    do {
      let saved = try await repository.saveCategory(category)
      if let index = categories.firstIndex(where: { $0.id == saved.id }) {
        categories[index] = saved
      } else {
        categories.append(saved)
      }
      categories.sort { ($0.kind.rawValue, $0.sortOrder, $0.name) < ($1.kind.rawValue, $1.sortOrder, $1.name) }
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }
}
