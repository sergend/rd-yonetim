import Foundation
import Observation

/// Miktar, birim fiyat ve oran girdisi ("1.250,5", "12,3456"). Ondalık ayracı
/// virgüldür; tek noktadan sonra tam 3 hane binlik ayraç sayılır ("10.000"). Ondalık
/// sınırı aşan veya geçersiz girdi nil döner; boş girdi `empty` döner.
public enum DecimalInput {
  public static func parse(_ raw: String, maxFractionDigits: Int, empty: Decimal? = nil) -> Decimal? {
    var text = raw.filter { !$0.isWhitespace && $0 != "₺" && $0 != "%" }
    if text.isEmpty { return empty }
    if text.contains(",") {
      text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
    } else if text.filter({ $0 == "." }).count > 1 {
      text = text.replacingOccurrences(of: ".", with: "")
    } else if let dot = text.firstIndex(of: "."), text[text.index(after: dot)...].count == 3 {
      text = text.replacingOccurrences(of: ".", with: "")  // "10.000" binlik ayraç (Türkçe yazım)
    }
    guard text.allSatisfy({ $0.isASCIIDigit || $0 == "." }), text.filter({ $0 == "." }).count <= 1,
          let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
    if let dot = text.firstIndex(of: "."), text[text.index(after: dot)...].count > maxFractionDigits { return nil }
    return value
  }

  public static func format(_ value: Decimal?, maxFractionDigits: Int = 4) -> String {
    guard let value else { return "" }
    let formatter = NumberFormatter()
    formatter.locale = Money.locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = maxFractionDigits
    return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
  }
}

// MARK: - Sözleşme listesi

@MainActor
@Observable
public final class ContractListViewModel {
  public private(set) var contracts: [Contract] = []
  /// Sözleşmenin en son hakedişi (durum rozeti için; tutar içermez).
  public private(set) var latestHakedis: [UUID: Hakedis] = [:]
  public var searchText = ""
  public var showClosed = false
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  public let projectId: UUID?
  private let access: AccessControl
  private let repository: ContractRepository

  public init(projectId: UUID? = nil, access: AccessControl, repository: ContractRepository) {
    self.projectId = projectId
    self.access = access
    self.repository = repository
  }

  public var canCreate: Bool {
    projectId.map { access.can(.sozlesmeWrite, in: $0) } ?? access.canAnywhere(.sozlesmeWrite)
  }

  public var filtered: [Contract] {
    let query = searchText.nilIfBlank?.lowercased(with: Money.locale)
    return contracts.filter { contract in
      (showClosed || contract.status == .taslak || contract.status == .aktif)
        && (query.map {
          contract.contractNo.lowercased(with: Money.locale).contains($0)
            || contract.title.lowercased(with: Money.locale).contains($0)
        } ?? true)
    }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      contracts = try await repository.contracts(projectId: projectId)
      if access.canAnywhere(.hakedisRead) {
        let all = try await repository.hakedisList(contractId: nil)
        var latest: [UUID: Hakedis] = [:]
        for item in all where item.status != .iptal {
          if (latest[item.contractId]?.hakedisNo ?? 0) < item.hakedisNo { latest[item.contractId] = item }
        }
        latestHakedis = latest
      }
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func upsert(_ contract: Contract) {
    if let index = contracts.firstIndex(where: { $0.id == contract.id }) {
      contracts[index] = contract
    } else {
      contracts.append(contract)
      contracts.sort { $0.contractNo < $1.contractNo }
    }
  }
}

// MARK: - Sözleşme kalemi formu

/// Tek kalemin metin girdileri. Yönteme göre gereksiz alanlar gizlenir.
public struct ContractItemForm: Equatable, Sendable, Identifiable {
  public var itemKey: UUID
  public var method: ContractItemMethod
  public var description: String
  public var unit: ContractUnit
  public var quantityText: String
  public var priceText: String
  public var overtimeText: String
  public var paidBases: Set<PaidBasis>
  public var personnelId: UUID?
  /// Daha önceki hakedişlerde kullanılmış kalem (silinemez, miktarı düşürülemez).
  public var isUsed: Bool

  public var id: UUID { itemKey }

  public init(itemKey: UUID = UUID(), method: ContractItemMethod = .birimFiyat, description: String = "",
              unit: ContractUnit = .m2, quantityText: String = "", priceText: String = "", overtimeText: String = "",
              paidBases: Set<PaidBasis> = [.calisilanGun], personnelId: UUID? = nil, isUsed: Bool = false) {
    self.itemKey = itemKey
    self.method = method
    self.description = description
    self.unit = unit
    self.quantityText = quantityText
    self.priceText = priceText
    self.overtimeText = overtimeText
    self.paidBases = paidBases
    self.personnelId = personnelId
    self.isUsed = isUsed
  }

  public init(_ draft: ContractItemDraft, isUsed: Bool = false) {
    self.init(itemKey: draft.itemKey, method: draft.method, description: draft.description, unit: draft.unit,
              quantityText: DecimalInput.format(draft.quantity, maxFractionDigits: 3),
              priceText: DecimalInput.format(draft.unitPrice), overtimeText: DecimalInput.format(draft.overtimeUnitPrice),
              paidBases: Set(draft.paidBases), personnelId: draft.personnelId, isUsed: isUsed)
  }

  public var quantity: Decimal? { DecimalInput.parse(quantityText, maxFractionDigits: 3) }
  public var price: Decimal? { DecimalInput.parse(priceText, maxFractionDigits: 4) }
  public var overtimePrice: Decimal? { DecimalInput.parse(overtimeText, maxFractionDigits: 4) }

  public var priceLabel: String {
    switch method {
    case .birimFiyat: "Birim fiyat"
    case .gunluk: "Adam-gün ücreti"
    case .goturu: "Götürü bedel"
    }
  }

  /// Girdi geçersizse açıklayıcı mesaj.
  public var validationMessage: String? {
    if description.trimmingCharacters(in: .whitespaces).isEmpty { return "Kalem açıklaması zorunlu." }
    guard let price, !priceText.isEmpty else { return "\(priceLabel) geçersiz (en çok 4 ondalık)." }
    if method == .goturu && price <= 0 { return "Götürü bedel sıfırdan büyük olmalı." }
    if method != .goturu && !quantityText.isEmpty && quantity == nil { return "Miktar geçersiz (en çok 3 ondalık)." }
    if method == .birimFiyat && quantity == nil { return "Birim fiyatlı kalemde sözleşme miktarı zorunlu." }
    if method == .gunluk && !overtimeText.isEmpty && overtimePrice == nil { return "Fazla mesai saat ücreti geçersiz." }
    return draft?.validationMessage
  }

  public var draft: ContractItemDraft? {
    guard let price else { return nil }
    var bases = paidBases
    bases.insert(.calisilanGun)
    return ContractItemDraft(itemKey: itemKey, method: method, description: description.trimmingCharacters(in: .whitespaces),
                             unit: unit, quantity: method == .goturu ? nil : quantity, unitPrice: price,
                             overtimeUnitPrice: overtimeText.isEmpty ? nil : overtimePrice,
                             paidBases: PaidBasis.allCases.filter { bases.contains($0) }, personnelId: personnelId)
  }

  /// Satırın sözleşme tutarı (önizleme).
  public var amountPreview: Decimal? { draft?.method == .goturu ? draft?.unitPrice : quantity.flatMap { q in price.map { HakedisMath.amount(q, $0) } } }
}

// MARK: - Sözleşme formu

/// Yeni sözleşme veya taslak revizyonun düzenlenmesi. Az zorunlu alan:
/// proje, taşeron, sözleşme no, başlık ve en az bir kalem.
@MainActor
@Observable
public final class ContractFormViewModel {
  public var projectId: UUID?
  public var subcontractorId: UUID?
  public var contractNo: String
  public var title: String
  public var signedDate: CalendarDate?
  public var currency: String
  public var scope: String
  public var startDate: CalendarDate?
  public var endDate: CalendarDate?
  public var totalAmountText: String
  public var retentionRateText: String
  public var advanceRateText: String
  public var paymentTerms: String
  public var notes: String
  public var taxCodes: Set<String>
  public var items: [ContractItemForm]

  public private(set) var isSaving = false
  public private(set) var errorMessage: String?

  public let editing: Contract?
  public let projects: [Project]
  /// Yalnızca cari kartı bağlı taşeronlar seçilebilir (ikinci cari açılmaz).
  public let subcontractors: [Subcontractor]
  public let taxRules: [TaxRule]
  private let repository: ContractRepository
  private let newId = UUID()

  /// Hazır teminat oranları; başka oran elle girilebilir.
  public static let retentionPresets: [Decimal] = [0, 5, 10, 15, 20]

  public init(editing: Contract? = nil, version: ContractVersion? = nil, items: [ContractItem] = [],
              taxCodes: [String] = [], usedItemKeys: Set<UUID> = [], projectId: UUID? = nil, projects: [Project],
              subcontractors: [Subcontractor], taxRules: [TaxRule], repository: ContractRepository) {
    self.editing = editing
    self.projects = projects
    self.subcontractors = subcontractors.filter { $0.cariAccountId != nil && ($0.isActive || $0.id == editing?.subcontractorId) }
    self.taxRules = taxRules.filter(\.isActive)
    self.repository = repository
    self.projectId = editing?.projectId ?? projectId
    subcontractorId = editing?.subcontractorId
    contractNo = editing?.contractNo ?? ""
    title = editing?.title ?? ""
    signedDate = editing?.signedDate
    currency = editing?.currency ?? "TRY"
    scope = version?.scope ?? ""
    startDate = version?.startDate
    endDate = version?.endDate
    totalAmountText = DecimalInput.format(version?.totalAmount, maxFractionDigits: 2)
    retentionRateText = DecimalInput.format(version?.retentionRate ?? 0)
    advanceRateText = DecimalInput.format(version?.advanceDeductionRate)
    paymentTerms = version?.paymentTerms ?? ""
    notes = version?.notes ?? ""
    self.taxCodes = Set(taxCodes)
    self.items = items.sorted { $0.lineNo < $1.lineNo }
      .map { ContractItemForm(ContractItemDraft($0), isUsed: usedItemKeys.contains($0.itemKey)) }
    if self.items.isEmpty { self.items = [ContractItemForm()] }
  }

  public var formTitle: String { editing == nil ? "Yeni sözleşme" : "Sözleşmeyi düzenle" }
  /// Onaylanmış sözleşmenin numarası, projesi ve taşeronu revizyonda değişmez.
  public var identityLocked: Bool { editing.map { $0.status != .taslak } ?? false }

  public var selectedSubcontractor: Subcontractor? { subcontractors.first { $0.id == subcontractorId } }
  public var retentionRate: Decimal? { DecimalInput.parse(retentionRateText, maxFractionDigits: 4, empty: 0) }
  public var totalAmount: Decimal? { DecimalInput.parse(totalAmountText, maxFractionDigits: 2) }
  public var itemsTotal: Decimal { items.compactMap(\.amountPreview).reduce(0, +) }

  /// Kodlara göre gruplanmış, doğrulanmış en güncel vergi kuralları.
  public var selectableTaxCodes: [TaxRule] {
    var latest: [String: TaxRule] = [:]
    for rule in taxRules where (latest[rule.code]?.validFrom ?? CalendarDate(year: 1, month: 1, day: 1)) < rule.validFrom {
      latest[rule.code] = rule
    }
    return latest.values.sorted { $0.code < $1.code }
  }

  public func addItem(_ method: ContractItemMethod) {
    items.append(ContractItemForm(method: method, unit: method == .gunluk ? .adamGun : method == .goturu ? .goturu : .m2))
  }

  public func removeItem(_ id: UUID) {
    guard let item = items.first(where: { $0.id == id }), !item.isUsed else { return }
    items.removeAll { $0.id == id }
  }

  public var validationMessage: String? {
    if projectId == nil { return "Proje seçin." }
    if subcontractorId == nil { return "Taşeron seçin (cari kartı bağlı olmalı)." }
    if contractNo.trimmingCharacters(in: .whitespaces).isEmpty { return "Sözleşme numarası zorunlu." }
    if title.trimmingCharacters(in: .whitespaces).isEmpty { return "Sözleşme başlığı zorunlu." }
    if items.isEmpty { return "En az bir kalem ekleyin." }
    for (index, item) in items.enumerated() {
      if let message = item.validationMessage { return "\(index + 1). kalem: \(message)" }
    }
    guard let rate = retentionRate, rate >= 0, rate <= 100 else { return "Teminat oranı 0 ile 100 arasında olmalı." }
    if !totalAmountText.isEmpty && (totalAmount ?? 0) <= 0 { return "Sözleşme bedeli geçersiz." }
    if !advanceRateText.isEmpty, DecimalInput.parse(advanceRateText, maxFractionDigits: 4).map({ $0 < 0 || $0 > 100 }) ?? true {
      return "Avans kesinti oranı 0 ile 100 arasında olmalı."
    }
    if let startDate, let endDate, endDate < startDate { return "Bitiş tarihi başlangıçtan önce olamaz." }
    return nil
  }

  public var draft: ContractDraft? {
    guard let projectId, let subcontractorId else { return nil }
    return ContractDraft(projectId: projectId, subcontractorId: subcontractorId,
                         contractNo: contractNo.trimmingCharacters(in: .whitespaces).uppercased(),
                         title: title.trimmingCharacters(in: .whitespaces), items: items.compactMap(\.draft),
                         signedDate: signedDate, currency: currency, scope: scope.nilIfBlank, startDate: startDate,
                         endDate: endDate, totalAmount: totalAmountText.isEmpty ? nil : totalAmount,
                         retentionRate: retentionRate ?? 0,
                         advanceDeductionRate: advanceRateText.isEmpty ? nil : DecimalInput.parse(advanceRateText, maxFractionDigits: 4),
                         paymentTerms: paymentTerms.nilIfBlank, notes: notes.nilIfBlank,
                         taxCodes: taxCodes.sorted())
  }

  public var canSave: Bool { validationMessage == nil && !isSaving }

  public func save() async -> Contract? {
    if let validationMessage {
      errorMessage = validationMessage
      return nil
    }
    guard let draft else { return nil }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      return try await repository.saveContract(id: editing?.id ?? newId, draft: draft, expectedVersion: editing?.version)
    } catch {
      errorMessage = message(for: error)
      return nil
    }
  }
}

// MARK: - Sözleşme detayı

@MainActor
@Observable
public final class ContractDetailViewModel {
  public private(set) var contract: Contract
  public private(set) var versions: [ContractVersion] = []
  public private(set) var items: [ContractItem] = []
  public private(set) var draftItems: [ContractItem] = []
  public private(set) var taxCodes: [String] = []
  public private(set) var hakedisList: [Hakedis] = []
  public private(set) var paymentStatus: [UUID: HakedisPaymentStatus] = [:]
  public private(set) var summary: ContractFinanceSummary?
  public private(set) var releases: [TeminatRelease] = []
  public private(set) var payments: [FinancePayment] = []
  public private(set) var events: [FinanceEvent] = []
  public private(set) var paymentSources: [PaymentSource] = []
  public private(set) var isLoading = false
  public private(set) var isWorking = false
  public private(set) var errorMessage: String?
  public private(set) var notice: String?

  private let access: AccessControl
  private let repository: ContractRepository

  public init(contract: Contract, access: AccessControl, repository: ContractRepository) {
    self.contract = contract
    self.access = access
    self.repository = repository
  }

  private var project: UUID { contract.projectId }

  public var currentVersion: ContractVersion? { versions.first { $0.status == .onaylandi } }
  public var draftVersion: ContractVersion? { versions.first { $0.status == .taslak } }
  public var openHakedis: Hakedis? { hakedisList.first { $0.status.isOpen } }

  public var canSeeFinance: Bool { access.can(.hakedisRead, in: project) }
  public var canEdit: Bool { access.can(.sozlesmeWrite, in: project) && draftVersion != nil && contract.status != .iptal }
  public var canApprove: Bool { access.can(.sozlesmeApprove, in: project) && draftVersion != nil }
  public var canStartRevision: Bool {
    access.can(.sozlesmeWrite, in: project) && contract.status == .aktif && draftVersion == nil
  }
  public var canClose: Bool { access.can(.sozlesmeApprove, in: project) && contract.status == .aktif && openHakedis == nil }
  public var canCreateHakedis: Bool {
    access.can(.hakedisPrepare, in: project) && contract.status == .aktif && openHakedis == nil
  }
  public var canReleaseTeminat: Bool {
    access.can(.teminatRelease, in: project) && (summary?.retentionBalance ?? 0) > 0
  }
  public var canPay: Bool { access.can(.odemeWrite, in: project) }

  /// Kalemin kullanılmış (onaylı hakedişlerde) miktarı ve tutarı yok; kullanılan
  /// kalemleri işaretlemek için yeterli bilgi: hakediş satırı olan kalemler.
  public private(set) var usedItemKeys: Set<UUID> = []

  public func paidAmount(_ hakedis: Hakedis) -> Decimal { paymentStatus[hakedis.id]?.paidAmount ?? 0 }

  /// Ödemesi tamamlanmamış, deftere işlenmiş teminat iadeleri.
  public func unpaidRelease(_ release: TeminatRelease) -> Decimal {
    release.amount - payments.filter { $0.teminatReleaseId == release.id && $0.status == .aktif }.reduce(0) { $0 + $1.amount }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      versions = try await repository.versions(contractId: contract.id)
      if let current = currentVersion {
        items = try await repository.items(versionId: current.id)
        taxCodes = try await repository.taxCodes(versionId: current.id)
      } else {
        items = []
      }
      if let draft = draftVersion {
        draftItems = try await repository.items(versionId: draft.id)
        if currentVersion == nil { taxCodes = try await repository.taxCodes(versionId: draft.id) }
      } else {
        draftItems = []
      }
      if canSeeFinance {
        hakedisList = try await repository.hakedisList(contractId: contract.id)
        let statuses = try await repository.paymentStatus(hakedisIds: hakedisList.map(\.id))
        paymentStatus = Dictionary(uniqueKeysWithValues: statuses.map { ($0.hakedisId, $0) })
        summary = try await repository.financeSummary(contractId: contract.id)
        releases = try await repository.teminatReleases(contractId: contract.id)
        payments = try await repository.payments(contractId: contract.id)
        var used = Set<UUID>()
        for hakedis in hakedisList where hakedis.status == .onaylandi {
          for line in try await repository.lines(hakedisId: hakedis.id) where line.quantity != 0 || line.amount != 0 {
            used.insert(line.itemKey)
          }
        }
        usedItemKeys = used
      }
      events = try await repository.events(contractId: contract.id)
      if canPay { paymentSources = try await repository.paymentSources() }
    } catch {
      errorMessage = message(for: error)
    }
  }

  private func perform(_ success: String, _ operation: () async throws -> Void) async -> Bool {
    isWorking = true
    errorMessage = nil
    notice = nil
    defer { isWorking = false }
    do {
      try await operation()
      notice = success
      await load()
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  @discardableResult
  public func transition(_ action: ContractAction, reason: String? = nil) async -> Bool {
    let text = switch action {
    case .onayla: "Sözleşme onaylandı."
    case .revizyon: "Revizyon taslağı açıldı. Onaylanana kadar eski fiyatlar geçerli."
    case .kapat: "Sözleşme kapatıldı."
    case .iptal: "Sözleşme iptal edildi."
    }
    return await perform(text) {
      contract = try await repository.transition(contractId: contract.id, action: action, reason: reason,
                                                 expectedVersion: contract.version)
    }
  }

  public func didSave(_ updated: Contract) async {
    contract = updated
    await load()
  }

  /// Yeni hakediş açar. Dönem varsayılanı: son hakedişin ertesi günü – bugün.
  public func suggestedPeriod(today: CalendarDate = .today()) -> (CalendarDate, CalendarDate) {
    let last = hakedisList.filter { $0.status == .onaylandi }.map(\.periodEnd).max()
    let start = last?.adding(days: 1) ?? currentVersion?.startDate ?? CalendarDate(year: today.year, month: today.month, day: 1)
    return (min(start, today), today)
  }

  public func createHakedis(id: UUID = UUID(), start: CalendarDate, end: CalendarDate, note: String?) async -> Hakedis? {
    var created: Hakedis?
    _ = await perform("Hakediş taslağı açıldı.") {
      created = try await repository.createHakedis(id: id, contractId: contract.id, periodStart: start, periodEnd: end,
                                                   note: note?.nilIfBlank)
    }
    return created
  }

  @discardableResult
  public func releaseTeminat(id: UUID = UUID(), amount: Decimal, reason: String, date: CalendarDate,
                             exchangeRate: Decimal? = nil) async -> Bool {
    await perform("Teminat serbest bırakıldı. Nakit ödemesi ayrıca kaydedilir.") {
      _ = try await repository.releaseTeminat(id: id, contractId: contract.id, amount: amount, reason: reason, date: date,
                                              exchangeRate: exchangeRate)
    }
  }

  /// TRY dışı sözleşmede her finansal işlem kur ister.
  public var needsExchangeRate: Bool { contract.currency != "TRY" }

  /// Avans için kalan tavan (onaylı sözleşme bedeli − etkin avanslar). Bedel
  /// tanımlı değilse nil: avans verilemez, tavan türetilmez.
  public var advanceRoom: Decimal? {
    guard let limit = summary?.contractAmount else { return nil }
    return max(0, limit - (summary?.advancePaidTotal ?? 0))
  }

  /// Avans verilemiyorsa nedeni (ekranda gösterilir).
  public var advanceBlockedReason: String? {
    guard summary != nil else { return nil }
    guard let room = advanceRoom else {
      return "Sözleşme bedeli tanımlı olmadığı için avans verilemez. Önce bedeli içeren bir revizyon onaylayın."
    }
    return room > 0 ? nil : "Verilen avans sözleşme bedeline ulaştı; yeni avans verilemez."
  }

  @discardableResult
  public func cancelRelease(_ release: TeminatRelease, reason: String) async -> Bool {
    await perform("Teminat iadesi iptal edildi (ters kayıtla).") {
      _ = try await repository.cancelTeminatRelease(id: release.id, reason: reason)
    }
  }

  @discardableResult
  public func recordPayment(_ draft: FinancePaymentDraft) async -> Bool {
    await perform(draft.kind == .avans ? "Avans kaydedildi." : "Ödeme kaydedildi.") {
      _ = try await repository.recordPayment(draft)
    }
  }

  @discardableResult
  public func cancelPayment(_ payment: FinancePayment, reason: String) async -> Bool {
    await perform("Ödeme iptal edildi (ters kayıtla).") {
      _ = try await repository.cancelPayment(id: payment.id, reason: reason)
    }
  }
}

// MARK: - Hakediş detayı

@MainActor
@Observable
public final class HakedisDetailViewModel {
  public private(set) var hakedis: Hakedis
  public private(set) var lines: [HakedisLine] = []
  public private(set) var adjustments: [HakedisAdjustment] = []
  public private(set) var puantajLinks: [HakedisPuantajLink] = []
  public private(set) var payments: [FinancePayment] = []
  public private(set) var events: [FinanceEvent] = []
  public private(set) var paymentSources: [PaymentSource] = []
  public private(set) var isLoading = false
  public private(set) var isWorking = false
  public private(set) var errorMessage: String?
  public private(set) var notice: String?
  /// Düzeltme sonrası açılan yeni hakediş (ekran ona geçer).
  public private(set) var replacement: Hakedis?

  public let contract: Contract
  private let access: AccessControl
  private let repository: ContractRepository

  public init(hakedis: Hakedis, contract: Contract, access: AccessControl, repository: ContractRepository) {
    self.hakedis = hakedis
    self.contract = contract
    self.access = access
    self.repository = repository
  }

  private var project: UUID { hakedis.projectId }

  public var paid: Decimal {
    payments.filter { $0.hakedisId == hakedis.id && $0.status == .aktif }.reduce(0) { $0 + $1.amount }
  }
  public var breakdown: HakedisBreakdown { HakedisBreakdown(hakedis, paid: paid) }
  public var mainLines: [HakedisLine] { lines.filter { $0.lineKind == .ana || $0.quantity != 0 } }
  public var isEditable: Bool { hakedis.status == .taslak && access.can(.hakedisPrepare, in: project) }

  public var canSubmit: Bool { hakedis.status == .taslak && access.can(.hakedisPrepare, in: project) && hakedis.grossAmount > 0 }
  public var canReturn: Bool { hakedis.status == .incelemede && access.can(.hakedisApprove, in: project) }
  public var canApprove: Bool {
    hakedis.status == .incelemede && access.can(.hakedisApprove, in: project) && !hakedis.needsLimitOverride
  }
  public var canOverrideLimit: Bool {
    hakedis.status.isOpen && hakedis.needsLimitOverride && access.can(.hakedisLimitOverride, in: project)
  }
  public var canCancelDraft: Bool { hakedis.status.isOpen && access.can(.hakedisPrepare, in: project) }
  public var canRevise: Bool {
    hakedis.status == .onaylandi && access.can(.hakedisApprove, in: project) && access.can(.hakedisPrepare, in: project)
      && !payments.contains { $0.hakedisId == hakedis.id && $0.status == .aktif }
  }
  public var canPost: Bool { hakedis.status == .onaylandi && !hakedis.isPosted && access.can(.hakedisPost, in: project) }
  public var canPay: Bool {
    hakedis.status == .onaylandi && hakedis.isPosted && breakdown.remaining > 0 && access.can(.odemeWrite, in: project)
  }

  /// Ödeme durumu metni: "Ödenmedi", "Kısmen ödendi", "Ödendi".
  public var paymentStateTitle: String {
    guard hakedis.status == .onaylandi else { return "Onay bekliyor" }
    if !hakedis.isPosted { return "Deftere işlenmedi" }
    if paid == 0 { return "Ödenmedi" }
    return breakdown.remaining > 0 ? "Kısmen ödendi" : "Ödendi"
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      hakedis = try await repository.hakedis(id: hakedis.id)
      lines = try await repository.lines(hakedisId: hakedis.id)
        .sorted { ($0.method.rawValue, $0.description, $0.lineKind.rawValue) < ($1.method.rawValue, $1.description, $1.lineKind.rawValue) }
      adjustments = try await repository.adjustments(hakedisId: hakedis.id)
      puantajLinks = try await repository.puantajLinks(hakedisId: hakedis.id)
      payments = try await repository.payments(contractId: hakedis.contractId).filter { $0.hakedisId == hakedis.id }
      events = try await repository.events(contractId: hakedis.contractId).filter { $0.entityId == hakedis.id }
      if access.can(.odemeWrite, in: project) { paymentSources = try await repository.paymentSources() }
    } catch {
      errorMessage = message(for: error)
    }
  }

  private func perform(_ success: String, _ operation: () async throws -> Hakedis?) async -> Bool {
    isWorking = true
    errorMessage = nil
    notice = nil
    defer { isWorking = false }
    do {
      if let updated = try await operation() { hakedis = updated }
      notice = success
      await load()
      return true
    } catch {
      errorMessage = message(for: error)
      await load()
      return false
    }
  }

  @discardableResult
  public func recalculate() async -> Bool {
    await perform("Yeniden hesaplandı.") { try await repository.refreshHakedis(id: hakedis.id) }
  }

  @discardableResult
  public func setProgress(_ line: HakedisLine, percentText: String) async -> Bool {
    guard let percent = DecimalInput.parse(percentText, maxFractionDigits: 2), percent >= 0, percent <= 100 else {
      errorMessage = "İlerleme 0 ile 100 arasında olmalı."
      return false
    }
    return await perform("İlerleme kaydedildi.") {
      try await repository.setProgress(hakedisId: hakedis.id, itemKey: line.itemKey, percent: percent)
    }
  }

  @discardableResult
  public func setDeduction(_ kind: HakedisAdjustmentKind, amountText: String, description: String?) async -> Bool {
    guard let amount = Money.parse(amountText.isEmpty ? "0" : amountText), amount >= 0 else {
      errorMessage = "Tutar geçersiz."
      return false
    }
    return await perform(amount == 0 ? "\(kind.title) kaldırıldı." : "\(kind.title) kaydedildi.") {
      try await repository.setDeduction(hakedisId: hakedis.id, kind: kind, amount: amount, description: description)
    }
  }

  @discardableResult
  public func overrideLimit(reason: String) async -> Bool {
    await perform("Limit aşımı için izin kaydedildi.") {
      try await repository.overrideLimit(hakedisId: hakedis.id, reason: reason)
    }
  }

  @discardableResult
  public func transition(_ action: HakedisAction, reason: String? = nil) async -> Bool {
    let text = switch action {
    case .gonder: "İncelemeye gönderildi."
    case .iade: "Düzeltmeye iade edildi."
    case .onayla: "Onaylandı. Ödeme için önce cari deftere işlenmeli."
    case .iptal: "Hakediş iptal edildi."
    }
    return await perform(text) {
      try await repository.transition(hakedisId: hakedis.id, action: action, reason: reason,
                                      expectedVersion: hakedis.version)
    }
  }

  /// Onaylı hakedişi iptal edip aynı dönem için düzeltme taslağı açar.
  @discardableResult
  public func revise(reason: String, newId: UUID = UUID()) async -> Bool {
    await perform("Hakediş iptal edildi; düzeltme taslağı açıldı.") {
      let fresh = try await repository.revise(hakedisId: hakedis.id, newId: newId, reason: reason)
      replacement = fresh
      return nil
    }
  }

  @discardableResult
  public func post(entryDate: CalendarDate? = nil, exchangeRate: Decimal? = nil) async -> Bool {
    await perform("Cari deftere işlendi. Ödemeye uygun tutar henüz ödenmiş değildir.") {
      try await repository.post(hakedisId: hakedis.id, entryDate: entryDate, exchangeRate: exchangeRate)
    }
  }

  /// TRY dışı hakediş deftere işleme ve ödemede kur ister.
  public var needsExchangeRate: Bool { hakedis.currency != "TRY" }

  @discardableResult
  public func recordPayment(id: UUID = UUID(), amount: Decimal, sourceId: UUID, date: CalendarDate,
                            description: String?, exchangeRate: Decimal? = nil) async -> Bool {
    await perform("Ödeme kaydedildi.") {
      _ = try await repository.recordPayment(FinancePaymentDraft(
        id: id, contractId: hakedis.contractId, target: .hakedis(hakedis.id), amount: amount,
        paymentSourceId: sourceId, paymentDate: date, description: description?.nilIfBlank, exchangeRate: exchangeRate))
      return nil
    }
  }

  @discardableResult
  public func cancelPayment(_ payment: FinancePayment, reason: String) async -> Bool {
    await perform("Ödeme iptal edildi (ters kayıtla).") {
      _ = try await repository.cancelPayment(id: payment.id, reason: reason)
      return nil
    }
  }
}

// MARK: - Hakediş listesi (modül girişi)

@MainActor
@Observable
public final class HakedisListViewModel {
  public private(set) var items: [Hakedis] = []
  public private(set) var contracts: [UUID: Contract] = [:]
  public var statusFilter: HakedisStatus?
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let repository: ContractRepository

  public init(repository: ContractRepository) {
    self.repository = repository
  }

  public var filtered: [Hakedis] {
    items.filter { statusFilter == nil ? $0.status != .iptal : $0.status == statusFilter }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      items = try await repository.hakedisList(contractId: nil)
      contracts = Dictionary(uniqueKeysWithValues: try await repository.contracts(projectId: nil).map { ($0.id, $0) })
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - İmalat (metraj) girişi

/// Proje bazında birim fiyatlı kalemlere metraj girişi. Fiyat ve tutar
/// gösterilmez; şantiye şefi de kullanabilir.
@MainActor
@Observable
public final class ImalatViewModel {
  public private(set) var items: [ImalatItem] = []
  public private(set) var pending: [WorkQuantity] = []
  public private(set) var isLoading = false
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?
  public private(set) var notice: String?

  public let project: Project
  private let access: AccessControl
  private let repository: ContractRepository

  public init(project: Project, access: AccessControl, repository: ContractRepository) {
    self.project = project
    self.access = access
    self.repository = repository
  }

  public var canWrite: Bool { access.can(.imalatWrite, in: project.id) }
  public var canApprove: Bool { access.can(.imalatApprove, in: project.id) }

  public func item(for quantity: WorkQuantity) -> ImalatItem? {
    items.first { $0.contractId == quantity.contractId && $0.itemKey == quantity.itemKey }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      items = try await repository.imalatItems(projectId: project.id)
      var rows: [WorkQuantity] = []
      for contractId in Set(items.map(\.contractId)) {
        rows += try await repository.workQuantities(contractId: contractId).filter { $0.status == .taslak }
      }
      pending = rows.sorted { $0.workDate > $1.workDate }
    } catch {
      errorMessage = message(for: error)
    }
  }

  @discardableResult
  public func save(item: ImalatItem, quantityText: String, date: CalendarDate, location: String?, note: String?,
                   id: UUID = UUID()) async -> Bool {
    guard let quantity = DecimalInput.parse(quantityText, maxFractionDigits: 3), quantity > 0 else {
      errorMessage = "Miktar sıfırdan büyük ve en çok 3 ondalık olmalı."
      return false
    }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      _ = try await repository.saveWorkQuantity(WorkQuantity(
        id: id, contractId: item.contractId, projectId: project.id, itemKey: item.itemKey, workDate: date,
        quantity: quantity, location: location?.nilIfBlank, note: note?.nilIfBlank))
      notice = "\(DecimalInput.format(quantity, maxFractionDigits: 3)) \(ContractUnit.title(item.unit)) kaydedildi; onay bekliyor."
      await load()
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  @discardableResult
  public func approvePending() async -> Bool {
    guard !pending.isEmpty else { return false }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      let count = try await repository.approveWorkQuantities(ids: pending.map(\.id))
      notice = "\(count) imalat kaydı onaylandı."
      await load()
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  @discardableResult
  public func cancel(_ quantity: WorkQuantity, reason: String) async -> Bool {
    do {
      _ = try await repository.cancelWorkQuantity(id: quantity.id, reason: reason)
      await load()
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }
}
