import Foundation

// Taşeron sözleşmesi ve hakediş (Aşama 4).
//
// Para kavramları ayrı tutulur ve birbirine eklenmez:
//   brüt hakediş (hak edilen) · KDV · stopaj / diğer kesinti · teminat kesintisi
//   · avans mahsubu · ödemeye uygun · gerçekleşen ödeme · kalan.
// Hesap veritabanında yapılır (private.hakedis_refresh); buradaki
// `HakedisMath` aynı kuralların istemci kopyasıdır (önizleme ve testler için).

// MARK: - Durumlar ve türler

public enum ContractStatus: String, Codable, CaseIterable, Sendable, Identifiable {
  case taslak, aktif, kapandi, iptal

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .taslak: "Taslak"
    case .aktif: "Aktif"
    case .kapandi: "Kapandı"
    case .iptal: "İptal"
    }
  }
}

public enum ContractVersionStatus: String, Codable, CaseIterable, Sendable {
  case taslak, onaylandi
  case yerineGecildi = "yerine_gecildi"

  public var title: String {
    switch self {
    case .taslak: "Taslak"
    case .onaylandi: "Onaylı (geçerli)"
    case .yerineGecildi: "Eski revizyon"
    }
  }
}

public enum ContractAction: String, Codable, Sendable {
  case onayla, revizyon, kapat, iptal
}

/// Kalemin hesap yöntemi. Karma sözleşme, farklı yöntemli kalemlerden oluşur.
public enum ContractItemMethod: String, Codable, CaseIterable, Sendable, Identifiable {
  case birimFiyat = "birim_fiyat"
  case gunluk
  case goturu

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .birimFiyat: "Birim fiyat (metraj)"
    case .gunluk: "Günlük (adam-gün)"
    case .goturu: "Götürü (sabit bedel)"
    }
  }

  /// Hakedişte miktarın kaynağı.
  public var source: String {
    switch self {
    case .birimFiyat: "Onaylı imalat (metraj) kayıtları"
    case .gunluk: "Onaylı veya kilitli puantaj"
    case .goturu: "Onaylanan ilerleme yüzdesi"
    }
  }
}

public enum ContractUnit: String, Codable, CaseIterable, Sendable, Identifiable {
  case m2, m3, m, ton, kg, adet, saat
  case adamGun = "adam_gun"
  case goturu, diger

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .m2: "m²"
    case .m3: "m³"
    case .m: "m"
    case .ton: "ton"
    case .kg: "kg"
    case .adet: "adet"
    case .saat: "saat"
    case .adamGun: "adam-gün"
    case .goturu: "götürü"
    case .diger: "diğer"
    }
  }

  /// Birim fiyatlı kalemde seçilebilen birimler.
  public static let measured: [ContractUnit] = [.m2, .m3, .m, .ton, .kg, .adet, .saat, .diger]

  public static func title(_ raw: String) -> String { ContractUnit(rawValue: raw)?.title ?? raw }
}

/// Günlük kalemde ücretlendirilen puantaj durumları. Çalışılan gün her zaman
/// dahildir; izin, rapor ve resmî tatil yalnızca sözleşme açıkça tanımlarsa.
public enum PaidBasis: String, Codable, CaseIterable, Sendable, Identifiable {
  case calisilanGun = "calisilan_gun"
  case ucretliIzin = "ucretli_izin"
  case rapor
  case resmiTatil = "resmi_tatil"

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .calisilanGun: "Çalışılan gün (tam 1, yarım 0,5)"
    case .ucretliIzin: "Ücretli izin"
    case .rapor: "Raporlu gün"
    case .resmiTatil: "Resmî tatil"
    }
  }
}

public enum WorkQuantityStatus: String, Codable, CaseIterable, Sendable {
  case taslak, onaylandi, iptal

  public var title: String {
    switch self {
    case .taslak: "Onay bekliyor"
    case .onaylandi: "Onaylı"
    case .iptal: "İptal"
    }
  }
}

public enum HakedisStatus: String, Codable, CaseIterable, Sendable, Identifiable {
  case taslak, incelemede, onaylandi, iptal

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .taslak: "Taslak"
    case .incelemede: "İncelemede"
    case .onaylandi: "Onaylandı"
    case .iptal: "İptal"
    }
  }

  public var isOpen: Bool { self == .taslak || self == .incelemede }
}

public enum HakedisAction: String, Codable, Sendable {
  case gonder, iade, onayla, iptal

  public var title: String {
    switch self {
    case .gonder: "İncelemeye gönder"
    case .iade: "Düzeltmeye iade et"
    case .onayla: "Onayla"
    case .iptal: "İptal et"
    }
  }
}

public enum HakedisLineKind: String, Codable, Sendable {
  case ana
  case fazlaMesai = "fazla_mesai"
}

public enum HakedisAdjustmentKind: String, Codable, CaseIterable, Sendable, Identifiable {
  case kdv, stopaj, teminat
  case avansMahsubu = "avans_mahsubu"
  case digerKesinti = "diger_kesinti"

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .kdv: "KDV"
    case .stopaj: "Stopaj"
    case .teminat: "Teminat kesintisi"
    case .avansMahsubu: "Avans mahsubu"
    case .digerKesinti: "Diğer kesinti"
    }
  }

  /// KDV brüte eklenir; diğerleri ödemeye uygun tutardan düşülür.
  public var isAddition: Bool { self == .kdv }
}

public enum TaxRuleKind: String, Codable, CaseIterable, Sendable {
  case kdv, stopaj
  case digerKesinti = "diger_kesinti"

  public var title: String {
    switch self {
    case .kdv: "KDV"
    case .stopaj: "Stopaj"
    case .digerKesinti: "Diğer sözleşmesel kesinti"
    }
  }
}

public enum FinancePaymentKind: String, Codable, CaseIterable, Sendable {
  case odeme, avans

  public var title: String { self == .odeme ? "Ödeme" : "Avans" }
}

public enum PaymentSourceKind: String, Codable, CaseIterable, Sendable {
  case sirket, kart, kisi, diger

  public var title: String {
    switch self {
    case .sirket: "Şirket ödemesi"
    case .kart: "Kart"
    case .kisi: "Kişi"
    case .diger: "Diğer"
    }
  }
}

/// Teminat iadesi ve ödeme kayıtlarının durumu.
public enum FinanceRecordStatus: String, Codable, Sendable {
  case aktif, iptal
}

// MARK: - Sözleşme

public struct Contract: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var contractNo: String
  public var projectId: UUID
  public var subcontractorId: UUID
  /// Taşeronun mevcut cari kartı (sözleşme yeni cari açmaz).
  public var cariAccountId: UUID
  public var title: String
  public var signedDate: CalendarDate?
  public var currency: String
  public var status: ContractStatus
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), contractNo: String, projectId: UUID, subcontractorId: UUID, cariAccountId: UUID,
              title: String, signedDate: CalendarDate? = nil, currency: String = "TRY", status: ContractStatus = .taslak,
              isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.contractNo = contractNo
    self.projectId = projectId
    self.subcontractorId = subcontractorId
    self.cariAccountId = cariAccountId
    self.title = title
    self.signedDate = signedDate
    self.currency = currency
    self.status = status
    self.isDemo = isDemo
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, title, currency, status, version
    case contractNo = "contract_no", projectId = "project_id", subcontractorId = "subcontractor_id"
    case cariAccountId = "cari_account_id", signedDate = "signed_date", isDemo = "is_demo"
  }
}

/// Sözleşmenin bir revizyonu. Onaylı revizyon değişmez; fiyat değişikliği
/// yeni revizyonla yapılır ve yalnızca sonraki hakedişleri etkiler.
public struct ContractVersion: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var contractId: UUID
  public var revision: Int
  public var status: ContractVersionStatus
  public var scope: String?
  public var startDate: CalendarDate?
  public var endDate: CalendarDate?
  /// Sözleşme bedeli üst sınırı (boşsa yalnızca kalem miktarları sınırdır).
  public var totalAmount: Decimal?
  public var retentionRate: Decimal
  public var advanceDeductionRate: Decimal?
  public var paymentTerms: String?
  public var notes: String?
  public var reason: String?
  public var approvedAt: Date?

  public init(id: UUID = UUID(), contractId: UUID, revision: Int = 0, status: ContractVersionStatus = .taslak,
              scope: String? = nil, startDate: CalendarDate? = nil, endDate: CalendarDate? = nil,
              totalAmount: Decimal? = nil, retentionRate: Decimal = 0, advanceDeductionRate: Decimal? = nil,
              paymentTerms: String? = nil, notes: String? = nil, reason: String? = nil, approvedAt: Date? = nil) {
    self.id = id
    self.contractId = contractId
    self.revision = revision
    self.status = status
    self.scope = scope
    self.startDate = startDate
    self.endDate = endDate
    self.totalAmount = totalAmount
    self.retentionRate = retentionRate
    self.advanceDeductionRate = advanceDeductionRate
    self.paymentTerms = paymentTerms
    self.notes = notes
    self.reason = reason
    self.approvedAt = approvedAt
  }

  enum CodingKeys: String, CodingKey {
    case id, revision, status, scope, notes, reason
    case contractId = "contract_id", startDate = "start_date", endDate = "end_date", totalAmount = "total_amount"
    case retentionRate = "retention_rate", advanceDeductionRate = "advance_deduction_rate"
    case paymentTerms = "payment_terms", approvedAt = "approved_at"
  }
}

public struct ContractItem: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var versionId: UUID
  public var contractId: UUID
  /// Revizyonlar arasında aynı kalan kimlik (kümülatif miktar bununla izlenir).
  public var itemKey: UUID
  public var lineNo: Int
  public var method: ContractItemMethod
  public var description: String
  public var unit: String
  public var quantity: Decimal?
  public var unitPrice: Decimal
  public var overtimeUnitPrice: Decimal?
  public var paidBases: [String]
  public var personnelId: UUID?

  public init(id: UUID = UUID(), versionId: UUID, contractId: UUID, itemKey: UUID = UUID(), lineNo: Int,
              method: ContractItemMethod, description: String, unit: String, quantity: Decimal? = nil,
              unitPrice: Decimal, overtimeUnitPrice: Decimal? = nil, paidBases: [String] = [PaidBasis.calisilanGun.rawValue],
              personnelId: UUID? = nil) {
    self.id = id
    self.versionId = versionId
    self.contractId = contractId
    self.itemKey = itemKey
    self.lineNo = lineNo
    self.method = method
    self.description = description
    self.unit = unit
    self.quantity = quantity
    self.unitPrice = unitPrice
    self.overtimeUnitPrice = overtimeUnitPrice
    self.paidBases = paidBases
    self.personnelId = personnelId
  }

  /// Kalemin sözleşme tutarı (götürüde birim fiyat, ölçülende miktar × fiyat).
  public var contractAmount: Decimal? {
    switch method {
    case .goturu: unitPrice
    case .birimFiyat: quantity.map { HakedisMath.amount($0, unitPrice) }
    case .gunluk: quantity.map { HakedisMath.amount($0, unitPrice) }
    }
  }

  enum CodingKeys: String, CodingKey {
    case id, method, description, unit, quantity
    case versionId = "version_id", contractId = "contract_id", itemKey = "item_key", lineNo = "line_no"
    case unitPrice = "unit_price", overtimeUnitPrice = "overtime_unit_price", paidBases = "paid_bases"
    case personnelId = "personnel_id"
  }
}

/// save_contract'a gönderilen kalem (p_items jsonb dizisi).
public struct ContractItemDraft: Identifiable, Hashable, Codable, Sendable {
  public var itemKey: UUID
  public var method: ContractItemMethod
  public var description: String
  public var unit: ContractUnit
  public var quantity: Decimal?
  public var unitPrice: Decimal
  public var overtimeUnitPrice: Decimal?
  public var paidBases: [PaidBasis]
  public var personnelId: UUID?

  public var id: UUID { itemKey }

  public init(itemKey: UUID = UUID(), method: ContractItemMethod, description: String, unit: ContractUnit,
              quantity: Decimal? = nil, unitPrice: Decimal, overtimeUnitPrice: Decimal? = nil,
              paidBases: [PaidBasis] = [.calisilanGun], personnelId: UUID? = nil) {
    self.itemKey = itemKey
    self.method = method
    self.description = description
    self.unit = method == .goturu ? .goturu : method == .gunluk ? .adamGun : unit
    self.quantity = method == .goturu ? nil : quantity
    self.unitPrice = unitPrice
    self.overtimeUnitPrice = method == .gunluk ? overtimeUnitPrice : nil
    self.paidBases = method == .gunluk ? paidBases : [.calisilanGun]
    self.personnelId = method == .gunluk ? personnelId : nil
  }

  public init(_ item: ContractItem) {
    self.init(itemKey: item.itemKey, method: item.method, description: item.description,
              unit: ContractUnit(rawValue: item.unit) ?? .diger, quantity: item.quantity, unitPrice: item.unitPrice,
              overtimeUnitPrice: item.overtimeUnitPrice, paidBases: item.paidBases.compactMap(PaidBasis.init(rawValue:)),
              personnelId: item.personnelId)
  }

  /// Kalem için kurallara uymayan ilk durum (sunucu aynısını denetler).
  public var validationMessage: String? {
    if description.trimmingCharacters(in: .whitespaces).isEmpty { return "Kalem açıklaması zorunlu." }
    if unitPrice < 0 { return "Birim fiyat eksi olamaz." }
    if HakedisMath.scale(unitPrice) > 4 { return "Birim fiyat en çok 4 ondalık içerebilir." }
    if let quantity, quantity <= 0 { return "Miktar sıfırdan büyük olmalı." }
    if method == .birimFiyat && quantity == nil { return "Birim fiyatlı kalemde sözleşme miktarı zorunlu." }
    if method == .goturu && unitPrice <= 0 { return "Götürü bedel sıfırdan büyük olmalı." }
    return nil
  }

  enum CodingKeys: String, CodingKey {
    case method, description, unit, quantity
    case itemKey = "item_key", unitPrice = "unit_price", overtimeUnitPrice = "overtime_unit_price"
    case paidBases = "paid_bases", personnelId = "personnel_id"
  }
}

/// Sözleşme kartı formu (taslak revizyon). Onaylı revizyon bu yolla
/// değiştirilemez; önce revizyon açılır.
public struct ContractDraft: Equatable, Sendable {
  public var projectId: UUID
  public var subcontractorId: UUID
  public var contractNo: String
  public var title: String
  public var items: [ContractItemDraft]
  public var signedDate: CalendarDate?
  public var currency: String
  public var scope: String?
  public var startDate: CalendarDate?
  public var endDate: CalendarDate?
  public var totalAmount: Decimal?
  public var retentionRate: Decimal
  public var advanceDeductionRate: Decimal?
  public var paymentTerms: String?
  public var notes: String?
  public var taxCodes: [String]

  public init(projectId: UUID, subcontractorId: UUID, contractNo: String, title: String, items: [ContractItemDraft],
              signedDate: CalendarDate? = nil, currency: String = "TRY", scope: String? = nil,
              startDate: CalendarDate? = nil, endDate: CalendarDate? = nil, totalAmount: Decimal? = nil,
              retentionRate: Decimal = 0, advanceDeductionRate: Decimal? = nil, paymentTerms: String? = nil,
              notes: String? = nil, taxCodes: [String] = []) {
    self.projectId = projectId
    self.subcontractorId = subcontractorId
    self.contractNo = contractNo
    self.title = title
    self.items = items
    self.signedDate = signedDate
    self.currency = currency
    self.scope = scope
    self.startDate = startDate
    self.endDate = endDate
    self.totalAmount = totalAmount
    self.retentionRate = retentionRate
    self.advanceDeductionRate = advanceDeductionRate
    self.paymentTerms = paymentTerms
    self.notes = notes
    self.taxCodes = taxCodes
  }
}

// MARK: - İmalat (metraj)

/// Birim fiyatlı kalem için yapılan iş miktarı. Fiyat veya tutar içermez;
/// şantiye şefi girebilir, onaydan sonra hakedişe kaynak olur.
public struct WorkQuantity: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var contractId: UUID
  public var projectId: UUID
  public var itemKey: UUID
  public var workDate: CalendarDate
  public var quantity: Decimal
  public var location: String?
  public var note: String?
  public var status: WorkQuantityStatus
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), contractId: UUID, projectId: UUID, itemKey: UUID, workDate: CalendarDate,
              quantity: Decimal, location: String? = nil, note: String? = nil, status: WorkQuantityStatus = .taslak,
              isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.contractId = contractId
    self.projectId = projectId
    self.itemKey = itemKey
    self.workDate = workDate
    self.quantity = quantity
    self.location = location
    self.note = note
    self.status = status
    self.isDemo = isDemo
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, quantity, location, note, status, version
    case contractId = "contract_id", projectId = "project_id", itemKey = "item_key", workDate = "work_date"
    case isDemo = "is_demo"
  }
}

/// imalat_items satırı: projede metraj girilebilecek kalem (fiyatsız).
public struct ImalatItem: Identifiable, Hashable, Codable, Sendable {
  public let contractId: UUID
  public let contractNo: String
  public let subcontractorName: String
  public let itemKey: UUID
  public let description: String
  public let unit: String
  public let contractQuantity: Decimal?
  public let approvedQuantity: Decimal
  public let pendingQuantity: Decimal

  public var id: UUID { itemKey }

  public init(contractId: UUID, contractNo: String, subcontractorName: String, itemKey: UUID, description: String,
              unit: String, contractQuantity: Decimal?, approvedQuantity: Decimal = 0, pendingQuantity: Decimal = 0) {
    self.contractId = contractId
    self.contractNo = contractNo
    self.subcontractorName = subcontractorName
    self.itemKey = itemKey
    self.description = description
    self.unit = unit
    self.contractQuantity = contractQuantity
    self.approvedQuantity = approvedQuantity
    self.pendingQuantity = pendingQuantity
  }

  enum CodingKeys: String, CodingKey {
    case description, unit
    case contractId = "contract_id", contractNo = "contract_no", subcontractorName = "subcontractor_name"
    case itemKey = "item_key", contractQuantity = "contract_quantity", approvedQuantity = "approved_quantity"
    case pendingQuantity = "pending_quantity"
  }
}

// MARK: - Hakediş

public struct Hakedis: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var contractId: UUID
  public var versionId: UUID
  public var projectId: UUID
  public var subcontractorId: UUID
  public var cariAccountId: UUID
  public var hakedisNo: Int
  public var periodStart: CalendarDate
  public var periodEnd: CalendarDate
  public var status: HakedisStatus
  public var currency: String
  public var replacesId: UUID?
  public var note: String?
  /// Bu dönem brüt hakediş (hak edilen iş bedeli).
  public var grossAmount: Decimal
  public var kdvAmount: Decimal
  /// Stopaj.
  public var taxDeductionAmount: Decimal
  public var otherDeductionAmount: Decimal
  /// Teminat kesintisi (ödenmiş sayılmaz; sözleşmede birikir).
  public var retentionAmount: Decimal
  /// Avans mahsubu (daha önce verilen avanstan düşülen).
  public var advanceAmount: Decimal
  /// Ödemeye uygun tutar. Ödendiği anlamına gelmez.
  public var payableAmount: Decimal
  public var limitExceeded: Bool
  public var limitMessages: [String]
  public var limitOverrideReason: String?
  public var submittedAt: Date?
  public var approvedAt: Date?
  public var approvedBy: UUID?
  public var cancelledAt: Date?
  public var cancelReason: String?
  public var postedAt: Date?
  public var cariEntryId: UUID?
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), contractId: UUID, versionId: UUID, projectId: UUID, subcontractorId: UUID,
              cariAccountId: UUID, hakedisNo: Int, periodStart: CalendarDate, periodEnd: CalendarDate,
              status: HakedisStatus = .taslak, currency: String = "TRY", replacesId: UUID? = nil, note: String? = nil,
              grossAmount: Decimal = 0, kdvAmount: Decimal = 0, taxDeductionAmount: Decimal = 0,
              otherDeductionAmount: Decimal = 0, retentionAmount: Decimal = 0, advanceAmount: Decimal = 0,
              payableAmount: Decimal = 0, limitExceeded: Bool = false, limitMessages: [String] = [],
              limitOverrideReason: String? = nil, submittedAt: Date? = nil, approvedAt: Date? = nil,
              approvedBy: UUID? = nil, cancelledAt: Date? = nil, cancelReason: String? = nil, postedAt: Date? = nil,
              cariEntryId: UUID? = nil, isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.contractId = contractId
    self.versionId = versionId
    self.projectId = projectId
    self.subcontractorId = subcontractorId
    self.cariAccountId = cariAccountId
    self.hakedisNo = hakedisNo
    self.periodStart = periodStart
    self.periodEnd = periodEnd
    self.status = status
    self.currency = currency
    self.replacesId = replacesId
    self.note = note
    self.grossAmount = grossAmount
    self.kdvAmount = kdvAmount
    self.taxDeductionAmount = taxDeductionAmount
    self.otherDeductionAmount = otherDeductionAmount
    self.retentionAmount = retentionAmount
    self.advanceAmount = advanceAmount
    self.payableAmount = payableAmount
    self.limitExceeded = limitExceeded
    self.limitMessages = limitMessages
    self.limitOverrideReason = limitOverrideReason
    self.submittedAt = submittedAt
    self.approvedAt = approvedAt
    self.approvedBy = approvedBy
    self.cancelledAt = cancelledAt
    self.cancelReason = cancelReason
    self.postedAt = postedAt
    self.cariEntryId = cariEntryId
    self.isDemo = isDemo
    self.version = version
  }

  public var title: String { "\(hakedisNo) nolu hakediş" }
  public var periodText: String { "\(periodStart.shortText) – \(periodEnd.shortText)" }
  public var isPosted: Bool { postedAt != nil }
  /// Onay için limit izni gerekiyor mu.
  public var needsLimitOverride: Bool { limitExceeded && limitOverrideReason == nil }

  enum CodingKeys: String, CodingKey {
    case id, status, currency, note, version
    case contractId = "contract_id", versionId = "version_id", projectId = "project_id"
    case subcontractorId = "subcontractor_id", cariAccountId = "cari_account_id", hakedisNo = "hakedis_no"
    case periodStart = "period_start", periodEnd = "period_end", replacesId = "replaces_id"
    case grossAmount = "gross_amount", kdvAmount = "kdv_amount", taxDeductionAmount = "tax_deduction_amount"
    case otherDeductionAmount = "other_deduction_amount", retentionAmount = "retention_amount"
    case advanceAmount = "advance_amount", payableAmount = "payable_amount", limitExceeded = "limit_exceeded"
    case limitMessages = "limit_messages", limitOverrideReason = "limit_override_reason"
    case submittedAt = "submitted_at", approvedAt = "approved_at", approvedBy = "approved_by"
    case cancelledAt = "cancelled_at", cancelReason = "cancel_reason", postedAt = "posted_at"
    case cariEntryId = "cari_entry_id", isDemo = "is_demo"
  }
}

/// Hakediş satırı: önceki, bu dönem ve kümülatif miktar/tutar ayrı ayrı.
public struct HakedisLine: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var hakedisId: UUID
  public var itemKey: UUID
  public var lineKind: HakedisLineKind
  public var method: ContractItemMethod
  public var description: String
  public var unit: String
  public var unitPrice: Decimal
  public var contractQuantity: Decimal?
  public var quantity: Decimal
  public var previousQuantity: Decimal
  public var cumulativeQuantity: Decimal
  public var amount: Decimal
  public var previousAmount: Decimal
  public var cumulativeAmount: Decimal
  /// Götürü kalemde kümülatif ilerleme yüzdesi.
  public var progressPercent: Decimal?

  public init(id: UUID = UUID(), hakedisId: UUID, itemKey: UUID, lineKind: HakedisLineKind = .ana,
              method: ContractItemMethod, description: String, unit: String, unitPrice: Decimal,
              contractQuantity: Decimal? = nil, quantity: Decimal = 0, previousQuantity: Decimal = 0,
              cumulativeQuantity: Decimal = 0, amount: Decimal = 0, previousAmount: Decimal = 0,
              cumulativeAmount: Decimal = 0, progressPercent: Decimal? = nil) {
    self.id = id
    self.hakedisId = hakedisId
    self.itemKey = itemKey
    self.lineKind = lineKind
    self.method = method
    self.description = description
    self.unit = unit
    self.unitPrice = unitPrice
    self.contractQuantity = contractQuantity
    self.quantity = quantity
    self.previousQuantity = previousQuantity
    self.cumulativeQuantity = cumulativeQuantity
    self.amount = amount
    self.previousAmount = previousAmount
    self.cumulativeAmount = cumulativeAmount
    self.progressPercent = progressPercent
  }

  public var displayTitle: String { lineKind == .fazlaMesai ? "\(description) · fazla mesai" : description }
  public var unitTitle: String { lineKind == .fazlaMesai ? "saat" : ContractUnit.title(unit) }

  enum CodingKeys: String, CodingKey {
    case id, method, description, unit, quantity, amount
    case hakedisId = "hakedis_id", itemKey = "item_key", lineKind = "line_kind", unitPrice = "unit_price"
    case contractQuantity = "contract_quantity", previousQuantity = "previous_quantity"
    case cumulativeQuantity = "cumulative_quantity", previousAmount = "previous_amount"
    case cumulativeAmount = "cumulative_amount", progressPercent = "progress_percent"
  }
}

/// KDV, stopaj, teminat, avans mahsubu ve diğer kesinti: her biri ayrı satır,
/// matrah ve oranıyla.
public struct HakedisAdjustment: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var hakedisId: UUID
  public var kind: HakedisAdjustmentKind
  public var taxCode: String
  public var baseAmount: Decimal?
  public var rate: Decimal?
  public var amount: Decimal
  public var description: String
  public var isManual: Bool

  public init(id: UUID = UUID(), hakedisId: UUID, kind: HakedisAdjustmentKind, taxCode: String = "",
              baseAmount: Decimal? = nil, rate: Decimal? = nil, amount: Decimal, description: String,
              isManual: Bool = false) {
    self.id = id
    self.hakedisId = hakedisId
    self.kind = kind
    self.taxCode = taxCode
    self.baseAmount = baseAmount
    self.rate = rate
    self.amount = amount
    self.description = description
    self.isManual = isManual
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, rate, amount, description
    case hakedisId = "hakedis_id", taxCode = "tax_code", baseAmount = "base_amount", isManual = "is_manual"
  }
}

/// Hakedişin kaynak aldığı puantaj kaydı (kayıt sürümü ve ay revizyonuyla).
public struct HakedisPuantajLink: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var hakedisId: UUID
  public var personnelId: UUID
  public var personnelName: String
  public var workDate: CalendarDate
  public var status: PuantajStatus
  public var payBasis: String
  public var dayDelta: Decimal
  public var overtimeDelta: Decimal
  public var periodRevision: Int
  public var entryVersion: Int
  public var isCorrection: Bool

  public init(id: UUID = UUID(), hakedisId: UUID, personnelId: UUID, personnelName: String, workDate: CalendarDate,
              status: PuantajStatus, payBasis: String, dayDelta: Decimal, overtimeDelta: Decimal = 0,
              periodRevision: Int = 0, entryVersion: Int = 1, isCorrection: Bool = false) {
    self.id = id
    self.hakedisId = hakedisId
    self.personnelId = personnelId
    self.personnelName = personnelName
    self.workDate = workDate
    self.status = status
    self.payBasis = payBasis
    self.dayDelta = dayDelta
    self.overtimeDelta = overtimeDelta
    self.periodRevision = periodRevision
    self.entryVersion = entryVersion
    self.isCorrection = isCorrection
  }

  enum CodingKeys: String, CodingKey {
    case id, status
    case hakedisId = "hakedis_id", personnelId = "personnel_id", personnelName = "personnel_name"
    case workDate = "work_date", payBasis = "pay_basis", dayDelta = "day_delta", overtimeDelta = "overtime_delta"
    case periodRevision = "period_revision", entryVersion = "entry_version", isCorrection = "is_correction"
  }
}

// MARK: - Teminat ve ödeme

/// Biriken teminatın serbest bırakılması. Hakedişi yeniden borçlandırmaz;
/// nakit ödemesi ayrıca kaydedilir.
public struct TeminatRelease: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var contractId: UUID
  public var amount: Decimal
  public var releaseDate: CalendarDate
  public var reason: String
  public var status: FinanceRecordStatus
  public var cancelReason: String?

  public init(id: UUID = UUID(), contractId: UUID, amount: Decimal, releaseDate: CalendarDate, reason: String,
              status: FinanceRecordStatus = .aktif, cancelReason: String? = nil) {
    self.id = id
    self.contractId = contractId
    self.amount = amount
    self.releaseDate = releaseDate
    self.reason = reason
    self.status = status
    self.cancelReason = cancelReason
  }

  enum CodingKeys: String, CodingKey {
    case id, amount, reason, status
    case contractId = "contract_id", releaseDate = "release_date", cancelReason = "cancel_reason"
  }
}

public struct PaymentSource: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var name: String
  public var kind: PaymentSourceKind
  public var isActive: Bool

  public init(id: UUID = UUID(), name: String, kind: PaymentSourceKind = .sirket, isActive: Bool = true) {
    self.id = id
    self.name = name
    self.kind = kind
    self.isActive = isActive
  }

  enum CodingKeys: String, CodingKey {
    case id, name, kind
    case isActive = "is_active"
  }
}

/// Gerçekleşen ödeme veya verilen avans. Ödeme kaynağı (ör. şirket hesabı,
/// kart) borçtan ayrı bir bilgidir; kaynak bakiyesi tutulmaz.
public struct FinancePayment: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var contractId: UUID
  public var kind: FinancePaymentKind
  public var amount: Decimal
  public var paymentDate: CalendarDate
  public var paymentSourceId: UUID
  public var hakedisId: UUID?
  public var teminatReleaseId: UUID?
  public var description: String?
  public var status: FinanceRecordStatus
  public var cancelReason: String?

  public init(id: UUID = UUID(), contractId: UUID, kind: FinancePaymentKind = .odeme, amount: Decimal,
              paymentDate: CalendarDate, paymentSourceId: UUID, hakedisId: UUID? = nil, teminatReleaseId: UUID? = nil,
              description: String? = nil, status: FinanceRecordStatus = .aktif, cancelReason: String? = nil) {
    self.id = id
    self.contractId = contractId
    self.kind = kind
    self.amount = amount
    self.paymentDate = paymentDate
    self.paymentSourceId = paymentSourceId
    self.hakedisId = hakedisId
    self.teminatReleaseId = teminatReleaseId
    self.description = description
    self.status = status
    self.cancelReason = cancelReason
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, amount, description, status
    case contractId = "contract_id", paymentDate = "payment_date", paymentSourceId = "payment_source_id"
    case hakedisId = "hakedis_id", teminatReleaseId = "teminat_release_id", cancelReason = "cancel_reason"
  }
}

/// Ödeme formunun gönderdiği alanlar. `id` istemcide üretilir; tekrar
/// gönderimde ikinci ödeme oluşmaz.
public struct FinancePaymentDraft: Equatable, Sendable {
  public enum Target: Equatable, Sendable {
    case hakedis(UUID)
    case teminatRelease(UUID)
    case advance
  }

  public var id: UUID
  public var contractId: UUID
  public var target: Target
  public var amount: Decimal
  public var paymentSourceId: UUID
  public var paymentDate: CalendarDate
  public var description: String?

  public init(id: UUID = UUID(), contractId: UUID, target: Target, amount: Decimal, paymentSourceId: UUID,
              paymentDate: CalendarDate, description: String? = nil) {
    self.id = id
    self.contractId = contractId
    self.target = target
    self.amount = amount
    self.paymentSourceId = paymentSourceId
    self.paymentDate = paymentDate
    self.description = description
  }

  public var kind: FinancePaymentKind { target == .advance ? .avans : .odeme }
}

public struct TaxRule: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var code: String
  public var name: String
  public var kind: TaxRuleKind
  public var rate: Decimal
  public var base: String
  public var validFrom: CalendarDate
  public var validTo: CalendarDate?
  public var verifiedAt: Date?
  public var isActive: Bool

  public init(id: UUID = UUID(), code: String, name: String, kind: TaxRuleKind, rate: Decimal, base: String = "brut",
              validFrom: CalendarDate, validTo: CalendarDate? = nil, verifiedAt: Date? = nil, isActive: Bool = true) {
    self.id = id
    self.code = code
    self.name = name
    self.kind = kind
    self.rate = rate
    self.base = base
    self.validFrom = validFrom
    self.validTo = validTo
    self.verifiedAt = verifiedAt
    self.isActive = isActive
  }

  /// Yalnızca kullanıcının doğruladığı kural hakedişte uygulanır.
  public var isVerified: Bool { verifiedAt != nil }

  enum CodingKeys: String, CodingKey {
    case id, code, name, kind, rate, base
    case validFrom = "valid_from", validTo = "valid_to", verifiedAt = "verified_at", isActive = "is_active"
  }
}

/// Sözleşme, imalat, hakediş, teminat ve ödeme işlemlerinin değişmez geçmişi.
public struct FinanceEvent: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var entity: String
  public var entityId: UUID
  public var action: String
  public var fromStatus: String?
  public var toStatus: String?
  public var reason: String?
  public var actorId: UUID?
  public var occurredAt: Date

  public init(id: UUID = UUID(), entity: String, entityId: UUID, action: String, fromStatus: String? = nil,
              toStatus: String? = nil, reason: String? = nil, actorId: UUID? = nil, occurredAt: Date = Date()) {
    self.id = id
    self.entity = entity
    self.entityId = entityId
    self.action = action
    self.fromStatus = fromStatus
    self.toStatus = toStatus
    self.reason = reason
    self.actorId = actorId
    self.occurredAt = occurredAt
  }

  public var title: String {
    let subject = switch entity {
    case "sozlesme": "Sözleşme"
    case "imalat": "İmalat"
    case "hakedis": "Hakediş"
    case "teminat": "Teminat"
    case "odeme": "Ödeme"
    default: entity
    }
    let verb = switch action {
    case "kaydet", "olustur": "kaydedildi"
    case "onayla": "onaylandı"
    case "gonder": "incelemeye gönderildi"
    case "iade": "düzeltmeye iade edildi"
    case "iptal": "iptal edildi"
    case "revizyon": "revizyonu açıldı"
    case "kapat": "kapatıldı"
    case "deftere_isle": "cari deftere işlendi"
    case "serbest_birak": "serbest bırakıldı"
    case "limit_izni": "limit aşımı için izin verildi"
    case "duzeltme": "düzeltme hakedişiyle değiştirildi"
    default: action.replacingOccurrences(of: "_", with: " ")
    }
    return "\(subject) \(verb)"
  }

  enum CodingKeys: String, CodingKey {
    case id, entity, action, reason
    case entityId = "entity_id", fromStatus = "from_status", toStatus = "to_status", actorId = "actor_id"
    case occurredAt = "occurred_at"
  }
}

/// contract_finance_summary: sözleşme düzeyinde ayrı ayrı toplamlar.
public struct ContractFinanceSummary: Hashable, Codable, Sendable {
  public var contractId: UUID
  public var contractAmount: Decimal?
  public var grossTotal: Decimal
  public var kdvTotal: Decimal
  public var taxDeductionTotal: Decimal
  public var otherDeductionTotal: Decimal
  public var advanceDeductedTotal: Decimal
  public var retentionWithheld: Decimal
  public var retentionReleased: Decimal
  public var retentionBalance: Decimal
  public var payableTotal: Decimal
  public var unpostedPayable: Decimal
  public var paidTotal: Decimal
  public var advancePaidTotal: Decimal
  /// Kalan borcumuz = ödemeye uygun + serbest bırakılan teminat − ödenen.
  public var remainingTotal: Decimal
  public var hakedisCount: Int

  public init(contractId: UUID, contractAmount: Decimal? = nil, grossTotal: Decimal = 0, kdvTotal: Decimal = 0,
              taxDeductionTotal: Decimal = 0, otherDeductionTotal: Decimal = 0, advanceDeductedTotal: Decimal = 0,
              retentionWithheld: Decimal = 0, retentionReleased: Decimal = 0, payableTotal: Decimal = 0,
              unpostedPayable: Decimal = 0, paidTotal: Decimal = 0, advancePaidTotal: Decimal = 0,
              hakedisCount: Int = 0) {
    self.contractId = contractId
    self.contractAmount = contractAmount
    self.grossTotal = grossTotal
    self.kdvTotal = kdvTotal
    self.taxDeductionTotal = taxDeductionTotal
    self.otherDeductionTotal = otherDeductionTotal
    self.advanceDeductedTotal = advanceDeductedTotal
    self.retentionWithheld = retentionWithheld
    self.retentionReleased = retentionReleased
    self.retentionBalance = retentionWithheld - retentionReleased
    self.payableTotal = payableTotal
    self.unpostedPayable = unpostedPayable
    self.paidTotal = paidTotal
    self.advancePaidTotal = advancePaidTotal
    self.remainingTotal = payableTotal + retentionReleased - paidTotal
    self.hakedisCount = hakedisCount
  }

  enum CodingKeys: String, CodingKey {
    case contractId = "contract_id", contractAmount = "contract_amount", grossTotal = "gross_total"
    case kdvTotal = "kdv_total", taxDeductionTotal = "tax_deduction_total"
    case otherDeductionTotal = "other_deduction_total", advanceDeductedTotal = "advance_deducted_total"
    case retentionWithheld = "retention_withheld", retentionReleased = "retention_released"
    case retentionBalance = "retention_balance", payableTotal = "payable_total", unpostedPayable = "unposted_payable"
    case paidTotal = "paid_total", advancePaidTotal = "advance_paid_total", remainingTotal = "remaining_total"
    case hakedisCount = "hakedis_count"
  }
}

/// v_hakedis_payment_status satırı.
public struct HakedisPaymentStatus: Hashable, Codable, Sendable {
  public var hakedisId: UUID
  public var payableAmount: Decimal
  public var paidAmount: Decimal
  public var remainingAmount: Decimal

  public init(hakedisId: UUID, payableAmount: Decimal, paidAmount: Decimal) {
    self.hakedisId = hakedisId
    self.payableAmount = payableAmount
    self.paidAmount = paidAmount
    self.remainingAmount = payableAmount - paidAmount
  }

  public var isFullyPaid: Bool { payableAmount > 0 && remainingAmount <= 0 }

  enum CodingKeys: String, CodingKey {
    case hakedisId = "hakedis_id", payableAmount = "payable_amount", paidAmount = "paid_amount"
    case remainingAmount = "remaining_amount"
  }
}

// MARK: - Hesap kuralları

/// Hakediş tutar kuralları (veritabanındaki hesapla aynı). Tutarlar Decimal'dir;
/// yuvarlama her satırda ayrı, 2 ondalık, yarım yukarı (PostgreSQL round).
public enum HakedisMath {
  /// Yarım yukarı (sıfırdan uzağa) 2 ondalığa yuvarlar.
  public static func round2(_ value: Decimal) -> Decimal {
    var input = value
    var result = Decimal()
    NSDecimalRound(&result, &input, 2, .plain)
    return result
  }

  /// Satır tutarı: miktar × birim fiyat, 2 ondalık.
  public static func amount(_ quantity: Decimal, _ unitPrice: Decimal) -> Decimal { round2(quantity * unitPrice) }

  /// Oran uygulaması: matrah × oran / 100, 2 ondalık.
  public static func percent(_ base: Decimal, _ rate: Decimal) -> Decimal { round2(base * rate / 100) }

  /// Götürü kalemin bu dönem tutarı: kümülatif yüzde tutarı − önceki tutar.
  public static func lumpSum(price: Decimal, cumulativePercent: Decimal, previousAmount: Decimal) -> Decimal {
    round2(price * cumulativePercent / 100) - previousAmount
  }

  /// Ödemeye uygun = brüt + KDV − stopaj − diğer kesinti − teminat − avans mahsubu.
  public static func payable(gross: Decimal, kdv: Decimal = 0, stopaj: Decimal = 0, other: Decimal = 0,
                             retention: Decimal = 0, advance: Decimal = 0) -> Decimal {
    gross + kdv - stopaj - other - retention - advance
  }

  /// Ondalık basamak sayısı (girdi denetimi için).
  public static func scale(_ value: Decimal) -> Int {
    max(0, -value.exponent)
  }
}

/// Bir hakedişin ekranda gösterilen ayrı ayrı tutarları. Hiçbir satır diğerine
/// eklenerek "ödendi" anlamı taşımaz.
public struct HakedisBreakdown: Equatable, Sendable {
  public let gross: Decimal
  public let kdv: Decimal
  public let stopaj: Decimal
  public let other: Decimal
  public let retention: Decimal
  public let advance: Decimal
  public let payable: Decimal
  public let paid: Decimal

  public init(_ hakedis: Hakedis, paid: Decimal) {
    gross = hakedis.grossAmount
    kdv = hakedis.kdvAmount
    stopaj = hakedis.taxDeductionAmount
    other = hakedis.otherDeductionAmount
    retention = hakedis.retentionAmount
    advance = hakedis.advanceAmount
    payable = hakedis.payableAmount
    self.paid = paid
  }

  /// Hak edilen: brüt + KDV.
  public var earned: Decimal { gross + kdv }
  /// Toplam kesinti (teminat ve avans dahil; her biri ayrıca gösterilir).
  public var deducted: Decimal { stopaj + other + retention + advance }
  public var remaining: Decimal { payable - paid }
  /// Kayıtlı tutarların kendi içinde tutarlı olup olmadığı.
  public var isConsistent: Bool { earned - deducted == payable }
}

extension CalendarDate {
  /// "05.10.2026"
  public var shortText: String {
    String(format: "%02d.%02d.%04d", day, month, year)
  }
}
