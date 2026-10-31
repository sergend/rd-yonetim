import Foundation

public enum CariType: String, Codable, CaseIterable, Sendable, Identifiable {
  case taseron, tedarikci, musteri, hizmetSaglayici = "hizmet_saglayici", diger

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .taseron: "Taşeron"
    case .tedarikci: "Tedarikçi"
    case .musteri: "Müşteri"
    case .hizmetSaglayici: "Hizmet sağlayıcı"
    case .diger: "Diğer"
    }
  }
}

/// Karşı tarafın hesabı açısından yön. Bakiye = borç − alacak.
public enum CariDirection: String, Codable, CaseIterable, Sendable, Identifiable {
  case borc, alacak

  public var id: String { rawValue }
  public var title: String { self == .borc ? "Borç" : "Alacak" }
}

public enum CariEntryKind: String, Codable, CaseIterable, Sendable, Identifiable {
  case acilis, manuel, avans, odeme, tahsilat
  case tersKayit = "ters_kayit"
  case hakedis, gider, fatura, kesinti
  case teminatIadesi = "teminat_iadesi"

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .acilis: "Açılış"
    case .manuel: "Manuel kayıt"
    case .avans: "Avans"
    case .odeme: "Ödeme"
    case .tahsilat: "Tahsilat"
    case .tersKayit: "Ters kayıt (iptal)"
    case .hakedis: "Hakediş"
    case .gider: "Gider"
    case .fatura: "Fatura"
    case .kesinti: "Kesinti"
    case .teminatIadesi: "Teminat iadesi"
    }
  }

  /// Uygulamadan elle girilebilen türler. Diğerleri kaynak modülden oluşur.
  public static let manualKinds: [CariEntryKind] = [.odeme, .avans, .tahsilat, .manuel, .acilis]

  /// Türün zorunlu yönü (yoksa kullanıcı seçer). Veritabanı kısıtıyla aynıdır.
  public var fixedDirection: CariDirection? {
    switch self {
    case .avans, .odeme: .borc
    case .tahsilat: .alacak
    default: nil
    }
  }
}

public struct CariAccount: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var code: String
  public var title: String
  public var type: CariType
  public var taxNumber: String?
  public var taxOffice: String?
  public var phone: String?
  public var email: String?
  public var address: String?
  public var iban: String?
  public var notes: String?
  public var isActive: Bool
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), code: String, title: String, type: CariType, taxNumber: String? = nil,
              taxOffice: String? = nil, phone: String? = nil, email: String? = nil, address: String? = nil,
              iban: String? = nil, notes: String? = nil, isActive: Bool = true, isDemo: Bool = false,
              version: Int = 1) {
    self.id = id
    self.code = code
    self.title = title
    self.type = type
    self.taxNumber = taxNumber
    self.taxOffice = taxOffice
    self.phone = phone
    self.email = email
    self.address = address
    self.iban = iban
    self.notes = notes
    self.isActive = isActive
    self.isDemo = isDemo
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, code, title, type, phone, email, address, iban, notes, version
    case taxNumber = "tax_number", taxOffice = "tax_office", isActive = "is_active", isDemo = "is_demo"
  }
}

/// Cari kart formunun gönderdiği alanlar. Bakiye burada yoktur: bakiye
/// yalnızca hareketlerden hesaplanır, elle düzenlenemez.
public struct CariAccountDraft: Equatable, Sendable, Encodable {
  public var code: String?   // boşsa veritabanı C-00001 biçiminde üretir
  public var title: String
  public var type: CariType
  public var taxNumber: String?
  public var taxOffice: String?
  public var phone: String?
  public var email: String?
  public var address: String?
  public var iban: String?
  public var notes: String?
  public var isActive: Bool

  public init(code: String? = nil, title: String = "", type: CariType = .taseron, taxNumber: String? = nil,
              taxOffice: String? = nil, phone: String? = nil, email: String? = nil, address: String? = nil,
              iban: String? = nil, notes: String? = nil, isActive: Bool = true) {
    self.code = code
    self.title = title
    self.type = type
    self.taxNumber = taxNumber
    self.taxOffice = taxOffice
    self.phone = phone
    self.email = email
    self.address = address
    self.iban = iban
    self.notes = notes
    self.isActive = isActive
  }

  public init(_ account: CariAccount) {
    self.init(code: account.code, title: account.title, type: account.type, taxNumber: account.taxNumber,
              taxOffice: account.taxOffice, phone: account.phone, email: account.email, address: account.address,
              iban: account.iban, notes: account.notes, isActive: account.isActive)
  }

  enum CodingKeys: String, CodingKey {
    case code, title, type, phone, email, address, iban, notes
    case taxNumber = "tax_number", taxOffice = "tax_office", isActive = "is_active"
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(code, forKey: .code)  // kod yoksa varsayılan kullanılsın
    try c.encode(title, forKey: .title)
    try c.encode(type, forKey: .type)
    try c.encode(taxNumber, forKey: .taxNumber)
    try c.encode(taxOffice, forKey: .taxOffice)
    try c.encode(phone, forKey: .phone)
    try c.encode(email, forKey: .email)
    try c.encode(address, forKey: .address)
    try c.encode(iban, forKey: .iban)
    try c.encode(notes, forKey: .notes)
    try c.encode(isActive, forKey: .isActive)
  }
}

/// Elle girilen cari hareket. `id` istemcide üretilir: ağ hatasında aynı
/// istek tekrar gönderilirse sunucu ikinci kayıt açmaz.
public struct CariEntryDraft: Equatable, Sendable {
  public enum Scope: Hashable, Sendable {
    case project(UUID)
    case costCenter(UUID)
  }

  public var id: UUID
  public var cariAccountId: UUID
  public var scope: Scope
  public var entryDate: CalendarDate
  public var direction: CariDirection
  public var kind: CariEntryKind
  public var amount: Decimal
  public var description: String
  public var documentNo: String?

  public init(id: UUID = UUID(), cariAccountId: UUID, scope: Scope, entryDate: CalendarDate,
              direction: CariDirection, kind: CariEntryKind, amount: Decimal, description: String,
              documentNo: String? = nil) {
    self.id = id
    self.cariAccountId = cariAccountId
    self.scope = scope
    self.entryDate = entryDate
    self.direction = direction
    self.kind = kind
    self.amount = amount
    self.description = description
    self.documentNo = documentNo
  }
}

/// Cari ekstresinin bir satırı (sunucuda yürüyen bakiyeyle hesaplanır).
public struct CariStatementLine: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let entryDate: CalendarDate
  public let kind: CariEntryKind
  public let direction: CariDirection
  public let description: String
  public let documentNo: String?
  public let projectId: UUID?
  public let costCenterId: UUID?
  public let amount: Decimal
  public let currency: String
  public let borcTry: Decimal
  public let alacakTry: Decimal
  public let runningBalanceTry: Decimal
  public let reversalOfId: UUID?
  public let isReversed: Bool

  public init(id: UUID = UUID(), entryDate: CalendarDate, kind: CariEntryKind, direction: CariDirection,
              description: String, documentNo: String? = nil, projectId: UUID? = nil, costCenterId: UUID? = nil,
              amount: Decimal, currency: String = "TRY", borcTry: Decimal, alacakTry: Decimal,
              runningBalanceTry: Decimal, reversalOfId: UUID? = nil, isReversed: Bool = false) {
    self.id = id
    self.entryDate = entryDate
    self.kind = kind
    self.direction = direction
    self.description = description
    self.documentNo = documentNo
    self.projectId = projectId
    self.costCenterId = costCenterId
    self.amount = amount
    self.currency = currency
    self.borcTry = borcTry
    self.alacakTry = alacakTry
    self.runningBalanceTry = runningBalanceTry
    self.reversalOfId = reversalOfId
    self.isReversed = isReversed
  }

  /// İptal edilebilir mi: ters kayıt değil, daha önce iptal edilmemiş, kaynak belgeye bağlı değil.
  public var isReversible: Bool {
    kind != .tersKayit && !isReversed && CariEntryKind.manualKinds.contains(kind)
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, direction, description, amount, currency
    case entryDate = "entry_date", documentNo = "document_no", projectId = "project_id"
    case costCenterId = "cost_center_id", borcTry = "borc_try", alacakTry = "alacak_try"
    case runningBalanceTry = "running_balance_try", reversalOfId = "reversal_of_id", isReversed = "is_reversed"
  }
}

public struct CariBalance: Hashable, Codable, Sendable {
  public let cariAccountId: UUID
  public let totalBorcTry: Decimal
  public let totalAlacakTry: Decimal
  public let balanceTry: Decimal
  public let entryCount: Int
  public let lastEntryDate: CalendarDate?

  public init(cariAccountId: UUID, totalBorcTry: Decimal, totalAlacakTry: Decimal,
              entryCount: Int = 0, lastEntryDate: CalendarDate? = nil) {
    self.cariAccountId = cariAccountId
    self.totalBorcTry = totalBorcTry
    self.totalAlacakTry = totalAlacakTry
    self.balanceTry = totalBorcTry - totalAlacakTry
    self.entryCount = entryCount
    self.lastEntryDate = lastEntryDate
  }

  enum CodingKeys: String, CodingKey {
    case cariAccountId = "cari_account_id", totalBorcTry = "total_borc_try", totalAlacakTry = "total_alacak_try"
    case balanceTry = "balance_try", entryCount = "entry_count", lastEntryDate = "last_entry_date"
  }

  /// Bakiyenin kullanıcıya okunuşu.
  public var side: BalanceSide { BalanceSide(balanceTry) }
}

public enum BalanceSide: Equatable, Sendable {
  case theyOwe      // karşı taraf bize borçlu (borç bakiyesi)
  case weOwe        // biz borçluyuz (alacak bakiyesi)
  case settled

  public init(_ balance: Decimal) {
    self = balance > 0 ? .theyOwe : balance < 0 ? .weOwe : .settled
  }

  public var title: String {
    switch self {
    case .theyOwe: "Borç bakiyesi (bize borçlu)"
    case .weOwe: "Alacak bakiyesi (biz borçluyuz)"
    case .settled: "Kapalı"
    }
  }
}

/// Ekstre ve bakiye filtresi.
public struct CariFilter: Equatable, Sendable {
  public var projectId: UUID?
  public var costCenterId: UUID?
  public var from: CalendarDate?
  public var to: CalendarDate?

  public init(projectId: UUID? = nil, costCenterId: UUID? = nil, from: CalendarDate? = nil, to: CalendarDate? = nil) {
    self.projectId = projectId
    self.costCenterId = costCenterId
    self.from = from
    self.to = to
  }

  public var isEmpty: Bool { self == CariFilter() }
}
