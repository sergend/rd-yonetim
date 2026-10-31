import Foundation

// Şirket gider, gelir ve borç/alacak takibi (Aşama 5).
//
// Ayrı tutulan kavramlar:
//   belge (gider/gelir) · onay (yükümlülük/alacak doğar) · ödeme/tahsilat
//   (birden çok, kısmi olabilir) · ödeme kaynağı (yalnızca bilgi).
// Hesap ve kurallar veritabanındadır (supabase/migrations/20261104000000_gider_gelir.sql);
// buradaki `FinanceMath` aynı kuralların istemci kopyasıdır (önizleme ve testler için).
// Kasa, banka bakiyesi veya toplam mevcut para hesaplanmaz.

// MARK: - Türler

public enum FinanceDocKind: String, Codable, CaseIterable, Sendable, Identifiable {
  case gider, gelir

  public var id: String { rawValue }
  public var title: String { self == .gider ? "Gider" : "Gelir" }
  /// Ödeme (gider) veya tahsilat (gelir).
  public var settlementTitle: String { self == .gider ? "Ödeme" : "Tahsilat" }
  public var settlementKind: FinanceSettlementKind { self == .gider ? .odeme : .tahsilat }
  public var counterpartyTitle: String { self == .gider ? "Tedarikçi / cari" : "Müşteri / cari" }

  /// İlgili izinler (veritabanındaki private.fin_doc_permission ile aynı).
  public var readPermission: PermissionKey { self == .gider ? .giderRead : .gelirRead }
  public var writePermission: PermissionKey { self == .gider ? .giderWrite : .gelirWrite }
  public var approvePermission: PermissionKey { self == .gider ? .giderApprove : .gelirApprove }
  public var settlePermission: PermissionKey { self == .gider ? .giderPay : .gelirCollect }
}

public enum FinanceDocStatus: String, Codable, CaseIterable, Sendable, Identifiable {
  case taslak, onaylandi, iptal

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .taslak: "Onay bekliyor"
    case .onaylandi: "Onaylı"
    case .iptal: "İptal"
    }
  }
}

public enum FinanceSettlementKind: String, Codable, Sendable {
  case odeme, tahsilat
  public var title: String { self == .odeme ? "Ödeme" : "Tahsilat" }
}

/// Belgenin ödeme/tahsilat durumu (v_finance_document_status.settlement_status).
public enum FinanceSettlementState: String, Codable, CaseIterable, Sendable, Identifiable {
  case taslak, iptal, acik, kismi, kapandi

  public var id: String { rawValue }

  public func title(for kind: FinanceDocKind) -> String {
    switch (self, kind) {
    case (.taslak, _): "Onay bekliyor"
    case (.iptal, _): "İptal"
    case (.acik, .gider): "Ödenmedi"
    case (.kismi, .gider): "Kısmen ödendi"
    case (.kapandi, .gider): "Tamamen ödendi"
    case (.acik, .gelir): "Tahsil edilmedi"
    case (.kismi, .gelir): "Kısmen tahsil edildi"
    case (.kapandi, .gelir): "Tamamen tahsil edildi"
    }
  }

  public var isOpen: Bool { self == .acik || self == .kismi }
}

// MARK: - Kategori

/// Kategoriler veridir; uygulamada sabit liste yoktur.
public struct FinanceCategory: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var kind: FinanceDocKind
  public var name: String
  public var sortOrder: Int
  public var isActive: Bool

  public init(id: UUID = UUID(), kind: FinanceDocKind, name: String, sortOrder: Int = 100, isActive: Bool = true) {
    self.id = id
    self.kind = kind
    self.name = name
    self.sortOrder = sortOrder
    self.isActive = isActive
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, name
    case sortOrder = "sort_order", isActive = "is_active"
  }
}

// MARK: - Belge

public enum FinanceScope: Hashable, Sendable {
  case project(UUID)
  case costCenter(UUID)

  public var projectId: UUID? { if case .project(let id) = self { id } else { nil } }
  public var costCenterId: UUID? { if case .costCenter(let id) = self { id } else { nil } }
}

public struct FinanceDocument: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var kind: FinanceDocKind
  public var documentNo: String
  public var status: FinanceDocStatus
  public var projectId: UUID?
  public var costCenterId: UUID?
  public var categoryId: UUID
  public var cariAccountId: UUID?
  public var description: String
  public var documentDate: CalendarDate
  public var dueDate: CalendarDate
  public var amount: Decimal
  public var currency: String
  public var exchangeRate: Decimal
  public var amountTry: Decimal
  public var invoiceNo: String?
  public var documentRef: String?
  public var notes: String?
  public var reportedSettled: Bool
  public var reportedSourceId: UUID?
  public var reportedBy: String?
  public var approvedAt: Date?
  public var cariEntryId: UUID?
  public var cancelledAt: Date?
  public var cancelReason: String?
  public var replacesId: UUID?
  public var createdBy: UUID?
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), kind: FinanceDocKind, documentNo: String, status: FinanceDocStatus = .taslak,
              scope: FinanceScope, categoryId: UUID, cariAccountId: UUID? = nil, description: String,
              documentDate: CalendarDate, dueDate: CalendarDate? = nil, amount: Decimal, currency: String = "TRY",
              exchangeRate: Decimal = 1, invoiceNo: String? = nil, documentRef: String? = nil, notes: String? = nil,
              reportedSettled: Bool = false, reportedSourceId: UUID? = nil, reportedBy: String? = nil,
              approvedAt: Date? = nil, cariEntryId: UUID? = nil, cancelledAt: Date? = nil, cancelReason: String? = nil,
              replacesId: UUID? = nil, createdBy: UUID? = nil, isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.kind = kind
    self.documentNo = documentNo
    self.status = status
    self.projectId = scope.projectId
    self.costCenterId = scope.costCenterId
    self.categoryId = categoryId
    self.cariAccountId = cariAccountId
    self.description = description
    self.documentDate = documentDate
    self.dueDate = dueDate ?? documentDate
    self.amount = amount
    self.currency = currency
    self.exchangeRate = exchangeRate
    self.amountTry = FinanceMath.toTry(amount, rate: exchangeRate)
    self.invoiceNo = invoiceNo
    self.documentRef = documentRef
    self.notes = notes
    self.reportedSettled = reportedSettled
    self.reportedSourceId = reportedSourceId
    self.reportedBy = reportedBy
    self.approvedAt = approvedAt
    self.cariEntryId = cariEntryId
    self.cancelledAt = cancelledAt
    self.cancelReason = cancelReason
    self.replacesId = replacesId
    self.createdBy = createdBy
    self.isDemo = isDemo
    self.version = version
  }

  public var scope: FinanceScope {
    if let projectId { return .project(projectId) }
    return .costCenter(costCenterId ?? UUID())
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, status, description, amount, currency, notes, version
    case documentNo = "document_no", projectId = "project_id", costCenterId = "cost_center_id"
    case categoryId = "category_id", cariAccountId = "cari_account_id", documentDate = "document_date"
    case dueDate = "due_date", exchangeRate = "exchange_rate", amountTry = "amount_try", invoiceNo = "invoice_no"
    case documentRef = "document_ref", reportedSettled = "reported_settled", reportedSourceId = "reported_source_id"
    case reportedBy = "reported_by", approvedAt = "approved_at", cariEntryId = "cari_entry_id"
    case cancelledAt = "cancelled_at", cancelReason = "cancel_reason", replacesId = "replaces_id"
    case createdBy = "created_by", isDemo = "is_demo"
  }
}

/// Belge kaydı için girdi (yeni belge veya taslak güncellemesi).
public struct FinanceDocumentDraft: Equatable, Sendable {
  public var kind: FinanceDocKind
  public var scope: FinanceScope
  public var categoryId: UUID
  public var description: String
  public var amount: Decimal
  public var documentDate: CalendarDate
  /// Boşsa belge tarihi (peşin).
  public var dueDate: CalendarDate?
  public var currency: String
  /// TRY dışında zorunlu; TRY'de nil (1).
  public var exchangeRate: Decimal?
  public var cariAccountId: UUID?
  public var invoiceNo: String?
  public var documentRef: String?
  public var notes: String?
  /// Sahada "peşin ödendi / tahsil edildi" bildirimi; onayda ödeme kaydına dönüşür.
  public var reportedSettled: Bool
  public var reportedSourceId: UUID?
  public var reportedBy: String?

  public init(kind: FinanceDocKind, scope: FinanceScope, categoryId: UUID, description: String, amount: Decimal,
              documentDate: CalendarDate, dueDate: CalendarDate? = nil, currency: String = "TRY",
              exchangeRate: Decimal? = nil, cariAccountId: UUID? = nil, invoiceNo: String? = nil,
              documentRef: String? = nil, notes: String? = nil, reportedSettled: Bool = false,
              reportedSourceId: UUID? = nil, reportedBy: String? = nil) {
    self.kind = kind
    self.scope = scope
    self.categoryId = categoryId
    self.description = description
    self.amount = amount
    self.documentDate = documentDate
    self.dueDate = dueDate
    self.currency = currency
    self.exchangeRate = exchangeRate
    self.cariAccountId = cariAccountId
    self.invoiceNo = invoiceNo
    self.documentRef = documentRef
    self.notes = notes
    self.reportedSettled = reportedSettled
    self.reportedSourceId = reportedSourceId
    self.reportedBy = reportedBy
  }
}

/// Belge listesi filtresi. Boş alanlar filtre uygulamaz.
public struct FinanceDocumentFilter: Equatable, Sendable {
  public var kind: FinanceDocKind
  public var projectId: UUID?
  public var costCenterId: UUID?
  public var categoryId: UUID?
  public var cariAccountId: UUID?
  public var status: FinanceDocStatus?
  public var from: CalendarDate?
  public var to: CalendarDate?

  public init(kind: FinanceDocKind, projectId: UUID? = nil, costCenterId: UUID? = nil, categoryId: UUID? = nil,
              cariAccountId: UUID? = nil, status: FinanceDocStatus? = nil, from: CalendarDate? = nil,
              to: CalendarDate? = nil) {
    self.kind = kind
    self.projectId = projectId
    self.costCenterId = costCenterId
    self.categoryId = categoryId
    self.cariAccountId = cariAccountId
    self.status = status
    self.from = from
    self.to = to
  }
}

// MARK: - Ödeme / tahsilat

public struct FinanceSettlement: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var documentId: UUID
  public var kind: FinanceSettlementKind
  public var amount: Decimal
  public var settlementDate: CalendarDate
  public var paymentSourceId: UUID
  public var settledBy: String?
  public var description: String?
  public var exchangeRate: Decimal
  public var amountTry: Decimal
  public var cariEntryId: UUID?
  public var status: FinanceRecordStatus
  public var cancelReason: String?
  public var isDemo: Bool

  public init(id: UUID = UUID(), documentId: UUID, kind: FinanceSettlementKind, amount: Decimal,
              settlementDate: CalendarDate, paymentSourceId: UUID, settledBy: String? = nil, description: String? = nil,
              exchangeRate: Decimal = 1, cariEntryId: UUID? = nil, status: FinanceRecordStatus = .aktif,
              cancelReason: String? = nil, isDemo: Bool = false) {
    self.id = id
    self.documentId = documentId
    self.kind = kind
    self.amount = amount
    self.settlementDate = settlementDate
    self.paymentSourceId = paymentSourceId
    self.settledBy = settledBy
    self.description = description
    self.exchangeRate = exchangeRate
    self.amountTry = FinanceMath.toTry(amount, rate: exchangeRate)
    self.cariEntryId = cariEntryId
    self.status = status
    self.cancelReason = cancelReason
    self.isDemo = isDemo
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, amount, description, status
    case documentId = "document_id", settlementDate = "settlement_date", paymentSourceId = "payment_source_id"
    case settledBy = "settled_by", exchangeRate = "exchange_rate", amountTry = "amount_try"
    case cariEntryId = "cari_entry_id", cancelReason = "cancel_reason", isDemo = "is_demo"
  }
}

public struct FinanceSettlementDraft: Equatable, Sendable {
  /// İstemcide üretilir: tekrar gönderim ikinci ödeme açmaz.
  public var id: UUID
  public var documentId: UUID
  public var amount: Decimal
  public var paymentSourceId: UUID
  public var settlementDate: CalendarDate
  /// Ödemeyi yapan / tahsil eden kişi (bilgi).
  public var settledBy: String?
  public var description: String?
  /// TRY dışında zorunlu (işlem tarihindeki kur).
  public var exchangeRate: Decimal?

  public init(id: UUID = UUID(), documentId: UUID, amount: Decimal, paymentSourceId: UUID,
              settlementDate: CalendarDate, settledBy: String? = nil, description: String? = nil,
              exchangeRate: Decimal? = nil) {
    self.id = id
    self.documentId = documentId
    self.amount = amount
    self.paymentSourceId = paymentSourceId
    self.settlementDate = settlementDate
    self.settledBy = settledBy
    self.description = description
    self.exchangeRate = exchangeRate
  }
}

/// Belgenin ödeme durumu (v_finance_document_status).
public struct FinanceDocumentStatus: Hashable, Codable, Sendable {
  public var documentId: UUID
  public var kind: FinanceDocKind
  public var status: FinanceDocStatus
  public var amount: Decimal
  public var currency: String
  public var settledAmount: Decimal
  public var settledTry: Decimal
  public var remainingAmount: Decimal
  public var remainingTry: Decimal
  public var settlementState: FinanceSettlementState
  public var dueDate: CalendarDate
  public var isOverdue: Bool
  public var daysOverdue: Int

  public init(documentId: UUID, kind: FinanceDocKind, status: FinanceDocStatus, amount: Decimal, currency: String,
              settledAmount: Decimal, settledTry: Decimal, remainingAmount: Decimal, remainingTry: Decimal,
              settlementState: FinanceSettlementState, dueDate: CalendarDate, isOverdue: Bool, daysOverdue: Int) {
    self.documentId = documentId
    self.kind = kind
    self.status = status
    self.amount = amount
    self.currency = currency
    self.settledAmount = settledAmount
    self.settledTry = settledTry
    self.remainingAmount = remainingAmount
    self.remainingTry = remainingTry
    self.settlementState = settlementState
    self.dueDate = dueDate
    self.isOverdue = isOverdue
    self.daysOverdue = daysOverdue
  }

  enum CodingKeys: String, CodingKey {
    case kind, status, amount, currency
    case documentId = "document_id", settledAmount = "settled_amount", settledTry = "settled_try"
    case remainingAmount = "remaining_amount", remainingTry = "remaining_try"
    case settlementState = "settlement_status", dueDate = "due_date", isOverdue = "is_overdue"
    case daysOverdue = "days_overdue"
  }
}

/// Değiştirilemez belge geçmişi.
public struct FinanceDocumentEvent: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var documentId: UUID
  public var action: String
  public var fromStatus: String?
  public var toStatus: String?
  public var reason: String?
  public var actorId: UUID?
  public var occurredAt: Date

  public init(id: UUID = UUID(), documentId: UUID, action: String, fromStatus: String? = nil, toStatus: String? = nil,
              reason: String? = nil, actorId: UUID? = nil, occurredAt: Date = Date()) {
    self.id = id
    self.documentId = documentId
    self.action = action
    self.fromStatus = fromStatus
    self.toStatus = toStatus
    self.reason = reason
    self.actorId = actorId
    self.occurredAt = occurredAt
  }

  public var title: String {
    switch action {
    case "olustur": "Kaydedildi"
    case "guncelle": "Taslak güncellendi"
    case "onayla": "Onaylandı"
    case "odeme": "Ödeme kaydedildi"
    case "tahsilat": "Tahsilat kaydedildi"
    case "odeme_iptal": "Ödeme iptal edildi"
    case "tahsilat_iptal": "Tahsilat iptal edildi"
    case "iptal": "Belge iptal edildi"
    case "duzelt": "Düzeltme için iptal edildi"
    default: action.replacingOccurrences(of: "_", with: " ")
    }
  }

  enum CodingKeys: String, CodingKey {
    case id, action, reason
    case documentId = "document_id", fromStatus = "from_status", toStatus = "to_status"
    case actorId = "actor_id", occurredAt = "occurred_at"
  }
}

// MARK: - Raporlar

public enum FinanceReportGroup: String, CaseIterable, Sendable, Identifiable {
  case proje, kategori, cari, ay, kaynak

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .proje: "Proje / masraf merkezi"
    case .kategori: "Kategori"
    case .cari: "Tedarikçi / cari"
    case .ay: "Aylık"
    case .kaynak: "Ödeme kaynağı"
    }
  }
}

/// Rapor satırı (TL karşılığı). Tahakkuk, ödenen ve kalan ayrı sütundur.
/// `kaynak` grubunda yalnızca `settledTry` doludur.
public struct FinanceReportRow: Identifiable, Hashable, Codable, Sendable {
  public var groupKey: String
  public var label: String
  public var documentCount: Int
  public var accruedTry: Decimal
  public var settledTry: Decimal
  public var openTry: Decimal
  public var overdueTry: Decimal

  public var id: String { groupKey }

  public init(groupKey: String, label: String, documentCount: Int, accruedTry: Decimal, settledTry: Decimal,
              openTry: Decimal, overdueTry: Decimal) {
    self.groupKey = groupKey
    self.label = label
    self.documentCount = documentCount
    self.accruedTry = accruedTry
    self.settledTry = settledTry
    self.openTry = openTry
    self.overdueTry = overdueTry
  }

  enum CodingKeys: String, CodingKey {
    case label
    case groupKey = "group_key", documentCount = "document_count", accruedTry = "accrued_try"
    case settledTry = "settled_try", openTry = "open_try", overdueTry = "overdue_try"
  }
}

/// Proje maliyet satırı. Gider, hakediş ve gelir ayrı sütunlardır ve
/// birbirine eklenmez; avans ödeme değildir. İzni olmayan grup nil gelir.
public struct ProjectCostRow: Identifiable, Hashable, Codable, Sendable {
  public var projectId: UUID
  public var projectLabel: String
  public var expenseAccruedTry: Decimal?
  public var expensePaidTry: Decimal?
  public var expenseOpenTry: Decimal?
  public var hakedisAccruedTry: Decimal?
  public var hakedisUnpostedTry: Decimal?
  public var hakedisPaidTry: Decimal?
  public var advancePaidTry: Decimal?
  public var advanceDeductedTry: Decimal?
  public var incomeAccruedTry: Decimal?
  public var incomeCollectedTry: Decimal?

  public var id: UUID { projectId }

  public init(projectId: UUID, projectLabel: String, expenseAccruedTry: Decimal? = nil, expensePaidTry: Decimal? = nil,
              expenseOpenTry: Decimal? = nil, hakedisAccruedTry: Decimal? = nil, hakedisUnpostedTry: Decimal? = nil,
              hakedisPaidTry: Decimal? = nil, advancePaidTry: Decimal? = nil, advanceDeductedTry: Decimal? = nil,
              incomeAccruedTry: Decimal? = nil, incomeCollectedTry: Decimal? = nil) {
    self.projectId = projectId
    self.projectLabel = projectLabel
    self.expenseAccruedTry = expenseAccruedTry
    self.expensePaidTry = expensePaidTry
    self.expenseOpenTry = expenseOpenTry
    self.hakedisAccruedTry = hakedisAccruedTry
    self.hakedisUnpostedTry = hakedisUnpostedTry
    self.hakedisPaidTry = hakedisPaidTry
    self.advancePaidTry = advancePaidTry
    self.advanceDeductedTry = advanceDeductedTry
    self.incomeAccruedTry = incomeAccruedTry
    self.incomeCollectedTry = incomeCollectedTry
  }

  /// Hakedişin ödenmemiş kısmı (deftere işlenmiş tahakkuk − ödeme − mahsup edilen avans).
  /// Avans ödemesi ayrıca gösterilir; bu farka eklenmez.
  public var hakedisOpenTry: Decimal? {
    guard let accrued = hakedisAccruedTry, let paid = hakedisPaidTry else { return nil }
    return accrued - paid - (advanceDeductedTry ?? 0)
  }

  enum CodingKeys: String, CodingKey {
    case projectId = "project_id", projectLabel = "project_label"
    case expenseAccruedTry = "expense_accrued_try", expensePaidTry = "expense_paid_try"
    case expenseOpenTry = "expense_open_try", hakedisAccruedTry = "hakedis_accrued_try"
    case hakedisUnpostedTry = "hakedis_unposted_try", hakedisPaidTry = "hakedis_paid_try"
    case advancePaidTry = "advance_paid_try", advanceDeductedTry = "advance_deducted_try"
    case incomeAccruedTry = "income_accrued_try", incomeCollectedTry = "income_collected_try"
  }
}

// MARK: - Kurallar (istemci kopyası)

public enum FinanceMath {
  /// TL karşılığı: tutar × kur, 2 haneye yuvarlanır (veritabanı round(...,2) ile aynı).
  public static func toTry(_ amount: Decimal, rate: Decimal) -> Decimal {
    round(amount * rate, scale: 2)
  }

  public static func round(_ value: Decimal, scale: Int) -> Decimal {
    var input = value
    var result = Decimal()
    NSDecimalRound(&result, &input, scale, .plain)
    return result
  }

  /// Belgenin ödeme durumu; v_finance_document_status ile aynı kurallar.
  public static func status(of document: FinanceDocument, settlements: [FinanceSettlement],
                            today: CalendarDate) -> FinanceDocumentStatus {
    let active = settlements.filter { $0.documentId == document.id && $0.status == .aktif }
    let settled = active.reduce(Decimal(0)) { $0 + $1.amount }
    let settledTry = active.reduce(Decimal(0)) { $0 + $1.amountTry }
    let approved = document.status == .onaylandi
    let remaining = approved ? document.amount - settled : 0
    let state: FinanceSettlementState = switch document.status {
    case .iptal: .iptal
    case .taslak: .taslak
    case .onaylandi: settled == 0 ? .acik : (settled < document.amount ? .kismi : .kapandi)
    }
    let days = max(document.dueDate.days(until: today), 0)
    return FinanceDocumentStatus(
      documentId: document.id, kind: document.kind, status: document.status, amount: document.amount,
      currency: document.currency, settledAmount: settled, settledTry: settledTry, remainingAmount: remaining,
      remainingTry: approved ? toTry(remaining, rate: document.exchangeRate) : 0, settlementState: state,
      dueDate: document.dueDate, isOverdue: approved && settled < document.amount && document.dueDate < today,
      daysOverdue: days)
  }
}

extension CalendarDate {
  /// Bu tarihten `other` tarihine gün farkı (other sonra ise pozitif).
  func days(until other: CalendarDate) -> Int {
    let calendar = Calendar(identifier: .gregorian)
    var utc = calendar
    utc.timeZone = TimeZone(identifier: "UTC")!
    let from = utc.date(from: DateComponents(year: year, month: month, day: day))!
    let to = utc.date(from: DateComponents(year: other.year, month: other.month, day: other.day))!
    return utc.dateComponents([.day], from: from, to: to).day ?? 0
  }
}
