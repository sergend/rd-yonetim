import Foundation

/// İş kolu / uzmanlık (veritabanında work_trade).
public enum WorkTrade: String, Codable, CaseIterable, Sendable, Identifiable {
  case kalip, demir, beton, duvar, siva, alci, boya, seramik, elektrik, tesisat, mekanik
  case izolasyon, cati, dograma, hafriyat, peyzaj, genel, diger

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .kalip: "Kalıp"
    case .demir: "Demir"
    case .beton: "Beton"
    case .duvar: "Duvar"
    case .siva: "Sıva"
    case .alci: "Alçı"
    case .boya: "Boya"
    case .seramik: "Seramik"
    case .elektrik: "Elektrik"
    case .tesisat: "Tesisat"
    case .mekanik: "Mekanik"
    case .izolasyon: "İzolasyon"
    case .cati: "Çatı"
    case .dograma: "Doğrama"
    case .hafriyat: "Hafriyat"
    case .peyzaj: "Peyzaj"
    case .genel: "Genel"
    case .diger: "Diğer"
    }
  }
}

/// Çalışma ilişkisi. Taşeron personelinin taşeronu zorunludur (veritabanı kuralı).
public enum EmploymentType: String, Codable, CaseIterable, Sendable, Identifiable {
  case sirket, taseron, diger

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .sirket: "Şirket personeli"
    case .taseron: "Taşeron personeli"
    case .diger: "Diğer (günlük, serbest)"
    }
  }
}

/// Başlangıç ve (varsa) bitiş günü dahil tarih aralığı. Bitiş boşsa devam ediyor.
/// Veritabanındaki `daterange(start, end, '[]')` ile aynı anlamdadır.
public struct DatePeriod: Hashable, Sendable {
  public var start: CalendarDate
  public var end: CalendarDate?

  public init(start: CalendarDate, end: CalendarDate? = nil) {
    self.start = start
    self.end = end
  }

  public var isValid: Bool { end.map { $0 >= start } ?? true }

  public func contains(_ day: CalendarDate) -> Bool {
    day >= start && end.map { day <= $0 } ?? true
  }

  public func overlaps(_ other: DatePeriod) -> Bool {
    let startsBeforeOtherEnds = other.end.map { start <= $0 } ?? true
    let otherStartsBeforeEnd = end.map { other.start <= $0 } ?? true
    return startsBeforeOtherEnds && otherStartsBeforeEnd
  }

  /// Bugün ya da ileride devam ediyor mu (bitmemiş).
  public func isOngoing(today: CalendarDate = .today()) -> Bool { end.map { $0 >= today } ?? true }
}

// MARK: - Taşeron

/// Taşeron kartı. Finansal kimlik bağlı cari karttır; burada vergi numarası
/// veya IBAN yoktur. Bir cari kart en fazla bir taşerona bağlanır.
public struct Subcontractor: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var name: String
  public var trade: WorkTrade?
  public var cariAccountId: UUID?
  public var contactName: String?
  public var phone: String?
  public var email: String?
  public var notes: String?
  public var isActive: Bool
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), name: String, trade: WorkTrade? = nil, cariAccountId: UUID? = nil,
              contactName: String? = nil, phone: String? = nil, email: String? = nil, notes: String? = nil,
              isActive: Bool = true, isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.name = name
    self.trade = trade
    self.cariAccountId = cariAccountId
    self.contactName = contactName
    self.phone = phone
    self.email = email
    self.notes = notes
    self.isActive = isActive
    self.isDemo = isDemo
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, name, trade, phone, email, notes, version
    case cariAccountId = "cari_account_id", contactName = "contact_name", isActive = "is_active", isDemo = "is_demo"
  }
}

public struct SubcontractorDraft: Equatable, Sendable, Encodable {
  public var name: String
  public var trade: WorkTrade?
  public var cariAccountId: UUID?
  public var contactName: String?
  public var phone: String?
  public var email: String?
  public var notes: String?
  public var isActive: Bool

  public init(name: String = "", trade: WorkTrade? = nil, cariAccountId: UUID? = nil, contactName: String? = nil,
              phone: String? = nil, email: String? = nil, notes: String? = nil, isActive: Bool = true) {
    self.name = name
    self.trade = trade
    self.cariAccountId = cariAccountId
    self.contactName = contactName
    self.phone = phone
    self.email = email
    self.notes = notes
    self.isActive = isActive
  }

  public init(_ subcontractor: Subcontractor) {
    self.init(name: subcontractor.name, trade: subcontractor.trade, cariAccountId: subcontractor.cariAccountId,
              contactName: subcontractor.contactName, phone: subcontractor.phone, email: subcontractor.email,
              notes: subcontractor.notes, isActive: subcontractor.isActive)
  }

  enum CodingKeys: String, CodingKey {
    case name, trade, phone, email, notes
    case cariAccountId = "cari_account_id", contactName = "contact_name", isActive = "is_active"
  }

  /// Boş alanlar da gönderilir; böylece düzenlemede silinen değer sunucuda da silinir.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(trade, forKey: .trade)
    try c.encode(cariAccountId, forKey: .cariAccountId)
    try c.encode(contactName, forKey: .contactName)
    try c.encode(phone, forKey: .phone)
    try c.encode(email, forKey: .email)
    try c.encode(notes, forKey: .notes)
    try c.encode(isActive, forKey: .isActive)
  }
}

/// Taşeron belgesi (vergi levhası, SGK, sözleşme...). Dosya eki sonraki aşamada.
public struct SubcontractorDocument: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let subcontractorId: UUID
  public var title: String
  public var documentNo: String?
  public var validUntil: CalendarDate?
  public var notes: String?

  public init(id: UUID = UUID(), subcontractorId: UUID, title: String, documentNo: String? = nil,
              validUntil: CalendarDate? = nil, notes: String? = nil) {
    self.id = id
    self.subcontractorId = subcontractorId
    self.title = title
    self.documentNo = documentNo
    self.validUntil = validUntil
    self.notes = notes
  }

  public func isExpired(today: CalendarDate = .today()) -> Bool { validUntil.map { $0 < today } ?? false }

  enum CodingKeys: String, CodingKey {
    case id, title, notes
    case subcontractorId = "subcontractor_id", documentNo = "document_no", validUntil = "valid_until"
  }
}

/// Taşeronun bir projede çalıştığı dönem.
public struct SubcontractorProject: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let subcontractorId: UUID
  public let projectId: UUID
  public var startDate: CalendarDate
  public var endDate: CalendarDate?
  public var scope: String?

  public init(id: UUID = UUID(), subcontractorId: UUID, projectId: UUID, startDate: CalendarDate,
              endDate: CalendarDate? = nil, scope: String? = nil) {
    self.id = id
    self.subcontractorId = subcontractorId
    self.projectId = projectId
    self.startDate = startDate
    self.endDate = endDate
    self.scope = scope
  }

  public var period: DatePeriod { DatePeriod(start: startDate, end: endDate) }

  enum CodingKeys: String, CodingKey {
    case id, scope
    case subcontractorId = "subcontractor_id", projectId = "project_id"
    case startDate = "start_date", endDate = "end_date"
  }
}

// MARK: - Personel

/// Personel kimliği. Ekip üyeliği ve görevlendirmeler ayrı kayıtlardır.
/// Telefon bu yapıda yoktur: ayrı izinle `PersonnelContact` olarak okunur.
public struct Personnel: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var fullName: String
  public var jobTitle: String?
  public var trade: WorkTrade?
  public var employmentType: EmploymentType
  public var subcontractorId: UUID?
  public var notes: String?
  public var isActive: Bool
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), fullName: String, jobTitle: String? = nil, trade: WorkTrade? = nil,
              employmentType: EmploymentType = .sirket, subcontractorId: UUID? = nil, notes: String? = nil,
              isActive: Bool = true, isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.fullName = fullName
    self.jobTitle = jobTitle
    self.trade = trade
    self.employmentType = employmentType
    self.subcontractorId = subcontractorId
    self.notes = notes
    self.isActive = isActive
    self.isDemo = isDemo
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, trade, notes, version
    case fullName = "full_name", jobTitle = "job_title", employmentType = "employment_type"
    case subcontractorId = "subcontractor_id", isActive = "is_active", isDemo = "is_demo"
  }
}

public struct PersonnelDraft: Equatable, Sendable, Encodable {
  public var fullName: String
  public var jobTitle: String?
  public var trade: WorkTrade?
  public var employmentType: EmploymentType
  public var subcontractorId: UUID?
  public var notes: String?
  public var isActive: Bool

  public init(fullName: String = "", jobTitle: String? = nil, trade: WorkTrade? = nil,
              employmentType: EmploymentType = .sirket, subcontractorId: UUID? = nil, notes: String? = nil,
              isActive: Bool = true) {
    self.fullName = fullName
    self.jobTitle = jobTitle
    self.trade = trade
    self.employmentType = employmentType
    self.subcontractorId = subcontractorId
    self.notes = notes
    self.isActive = isActive
  }

  public init(_ person: Personnel) {
    self.init(fullName: person.fullName, jobTitle: person.jobTitle, trade: person.trade,
              employmentType: person.employmentType, subcontractorId: person.subcontractorId, notes: person.notes,
              isActive: person.isActive)
  }

  enum CodingKeys: String, CodingKey {
    case trade, notes
    case fullName = "full_name", jobTitle = "job_title", employmentType = "employment_type"
    case subcontractorId = "subcontractor_id", isActive = "is_active"
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(fullName, forKey: .fullName)
    try c.encode(jobTitle, forKey: .jobTitle)
    try c.encode(trade, forKey: .trade)
    try c.encode(employmentType, forKey: .employmentType)
    try c.encode(subcontractorId, forKey: .subcontractorId)
    try c.encode(notes, forKey: .notes)
    try c.encode(isActive, forKey: .isActive)
  }
}

public struct PersonnelContact: Hashable, Codable, Sendable {
  public let personnelId: UUID
  public var phone: String?

  public init(personnelId: UUID, phone: String?) {
    self.personnelId = personnelId
    self.phone = phone
  }

  enum CodingKeys: String, CodingKey {
    case phone
    case personnelId = "personnel_id"
  }
}

// MARK: - Ekip

/// Ekip. `subcontractorId` boşsa şirketin kendi ekibidir.
public struct Crew: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var name: String
  public var subcontractorId: UUID?
  public var trade: WorkTrade?
  public var leaderId: UUID?
  public var notes: String?
  public var isActive: Bool
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), name: String, subcontractorId: UUID? = nil, trade: WorkTrade? = nil,
              leaderId: UUID? = nil, notes: String? = nil, isActive: Bool = true, isDemo: Bool = false,
              version: Int = 1) {
    self.id = id
    self.name = name
    self.subcontractorId = subcontractorId
    self.trade = trade
    self.leaderId = leaderId
    self.notes = notes
    self.isActive = isActive
    self.isDemo = isDemo
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, name, trade, notes, version
    case subcontractorId = "subcontractor_id", leaderId = "leader_id", isActive = "is_active", isDemo = "is_demo"
  }
}

public struct CrewDraft: Equatable, Sendable, Encodable {
  public var name: String
  public var subcontractorId: UUID?
  public var trade: WorkTrade?
  public var leaderId: UUID?
  public var notes: String?
  public var isActive: Bool

  public init(name: String = "", subcontractorId: UUID? = nil, trade: WorkTrade? = nil, leaderId: UUID? = nil,
              notes: String? = nil, isActive: Bool = true) {
    self.name = name
    self.subcontractorId = subcontractorId
    self.trade = trade
    self.leaderId = leaderId
    self.notes = notes
    self.isActive = isActive
  }

  public init(_ crew: Crew) {
    self.init(name: crew.name, subcontractorId: crew.subcontractorId, trade: crew.trade, leaderId: crew.leaderId,
              notes: crew.notes, isActive: crew.isActive)
  }

  enum CodingKeys: String, CodingKey {
    case name, trade, notes
    case subcontractorId = "subcontractor_id", leaderId = "leader_id", isActive = "is_active"
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(subcontractorId, forKey: .subcontractorId)
    try c.encode(trade, forKey: .trade)
    try c.encode(leaderId, forKey: .leaderId)
    try c.encode(notes, forKey: .notes)
    try c.encode(isActive, forKey: .isActive)
  }
}

/// Ekip üyeliği. Silinmez; ayrılışta bitiş tarihi yazılır.
public struct CrewMembership: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let crewId: UUID
  public let personnelId: UUID
  public var startDate: CalendarDate
  public var endDate: CalendarDate?
  public var roleTitle: String?

  public init(id: UUID = UUID(), crewId: UUID, personnelId: UUID, startDate: CalendarDate,
              endDate: CalendarDate? = nil, roleTitle: String? = nil) {
    self.id = id
    self.crewId = crewId
    self.personnelId = personnelId
    self.startDate = startDate
    self.endDate = endDate
    self.roleTitle = roleTitle
  }

  public var period: DatePeriod { DatePeriod(start: startDate, end: endDate) }

  enum CodingKeys: String, CodingKey {
    case id
    case crewId = "crew_id", personnelId = "personnel_id", startDate = "start_date", endDate = "end_date"
    case roleTitle = "role_title"
  }
}

// MARK: - Proje görevlendirmesi

public enum AssignmentTarget: Hashable, Sendable {
  case personnel(UUID)
  case crew(UUID)
}

/// Kişi ya da ekibin bir projedeki görev dönemi. Silinmez; bitiş tarihiyle kapanır.
public struct ProjectAssignment: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let projectId: UUID
  public let personnelId: UUID?
  public let crewId: UUID?
  public var startDate: CalendarDate
  public var endDate: CalendarDate?
  public var description: String?

  public init(id: UUID = UUID(), projectId: UUID, target: AssignmentTarget, startDate: CalendarDate,
              endDate: CalendarDate? = nil, description: String? = nil) {
    self.id = id
    self.projectId = projectId
    switch target {
    case .personnel(let person):
      personnelId = person
      crewId = nil
    case .crew(let crew):
      personnelId = nil
      crewId = crew
    }
    self.startDate = startDate
    self.endDate = endDate
    self.description = description
  }

  public var target: AssignmentTarget {
    if let personnelId { return .personnel(personnelId) }
    return .crew(crewId!)
  }

  public var period: DatePeriod { DatePeriod(start: startDate, end: endDate) }

  enum CodingKeys: String, CodingKey {
    case id, description
    case projectId = "project_id", personnelId = "personnel_id", crewId = "crew_id"
    case startDate = "start_date", endDate = "end_date"
  }
}

/// Görevlendirme ekranındaki seçim listesi satırı (iletişim bilgisi içermez).
public struct AssignmentCandidate: Identifiable, Hashable, Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case personel, ekip
  }

  public let kind: Kind
  public let id: UUID
  public let name: String
  public let detail: String?
  public let subcontractorName: String?
  public let isDemo: Bool

  public init(kind: Kind, id: UUID, name: String, detail: String? = nil, subcontractorName: String? = nil,
              isDemo: Bool = false) {
    self.kind = kind
    self.id = id
    self.name = name
    self.detail = detail
    self.subcontractorName = subcontractorName
    self.isDemo = isDemo
  }

  public var target: AssignmentTarget { kind == .personel ? .personnel(id) : .crew(id) }

  enum CodingKeys: String, CodingKey {
    case kind, id, name, detail
    case subcontractorName = "subcontractor_name", isDemo = "is_demo"
  }
}

/// Belirli bir günde projede çalışan kişi (project_workforce satırı).
public struct WorkforceEntry: Identifiable, Hashable, Codable, Sendable {
  public enum Via: String, Codable, Sendable {
    case dogrudan, ekip
  }

  public let personnelId: UUID
  public let fullName: String
  public let jobTitle: String?
  public let via: Via
  public let crewId: UUID?
  public let crewName: String?
  public let assignmentId: UUID
  public let membershipId: UUID?

  public init(personnelId: UUID, fullName: String, jobTitle: String? = nil, via: Via, crewId: UUID? = nil,
              crewName: String? = nil, assignmentId: UUID, membershipId: UUID? = nil) {
    self.personnelId = personnelId
    self.fullName = fullName
    self.jobTitle = jobTitle
    self.via = via
    self.crewId = crewId
    self.crewName = crewName
    self.assignmentId = assignmentId
    self.membershipId = membershipId
  }

  public var id: UUID { personnelId }

  enum CodingKeys: String, CodingKey {
    case via
    case personnelId = "personnel_id", fullName = "full_name", jobTitle = "job_title", crewId = "crew_id"
    case crewName = "crew_name", assignmentId = "assignment_id", membershipId = "membership_id"
  }
}

// MARK: - Kurallar

/// Veritabanı kurallarının istemci kopyası: kullanıcıya kaydetmeden önce
/// anlaşılır mesaj vermek için. Asıl denetim veritabanındadır (pgTAP 070).
public enum WorkforceRules {
  /// Taşeron personeli yalnızca kendi taşeronunun, şirket personeli şirket ekibine katılır.
  public static func canJoin(_ person: Personnel, _ crew: Crew) -> Bool {
    person.subcontractorId == crew.subcontractorId && person.isDemo == crew.isDemo
  }

  /// Yeni üyelik için engel mesajı (yoksa nil). `existing`: kişinin tüm üyelikleri.
  public static func membershipProblem(person: Personnel, crew: Crew, period: DatePeriod,
                                       existing: [CrewMembership], crewName: (UUID) -> String?) -> String? {
    if !period.isValid { return "Bitiş tarihi başlangıç tarihinden önce olamaz." }
    if !person.isActive { return "Pasif personel ekibe eklenemez." }
    if !crew.isActive { return "Pasif ekibe üye eklenemez." }
    if !canJoin(person, crew) {
      return "Taşeron personeli yalnızca kendi taşeronunun, şirket personeli yalnızca şirketin ekibine katılabilir."
    }
    if let clash = existing.first(where: { $0.personnelId == person.id && $0.period.overlaps(period) }) {
      let name = crewName(clash.crewId).map { "\"\($0)\" ekibinde" } ?? "başka bir ekipte"
      return "Kişi bu tarihlerde \(name); aynı anda yalnızca bir ekipte olabilir."
    }
    return nil
  }

  /// Aynı kişi/ekibin aynı projeye çakışan görevlendirmesi var mı.
  public static func assignmentProblem(projectId: UUID, target: AssignmentTarget, period: DatePeriod,
                                       existing: [ProjectAssignment]) -> String? {
    if !period.isValid { return "Bitiş tarihi başlangıç tarihinden önce olamaz." }
    if existing.contains(where: { $0.projectId == projectId && $0.target == target && $0.period.overlaps(period) }) {
      return "Bu projede aynı tarihlerde zaten görevlendirme var."
    }
    return nil
  }

  /// Kişinin çalışma ilişkisi ile taşeronu tutarlı mı (taşeron personelinde zorunlu).
  public static func employmentProblem(type: EmploymentType, subcontractorId: UUID?) -> String? {
    switch (type, subcontractorId) {
    case (.taseron, nil): "Taşeron personeli için taşeron seçin."
    case (.sirket, .some), (.diger, .some): "Yalnızca taşeron personeli bir taşerona bağlanır."
    default: nil
    }
  }
}
