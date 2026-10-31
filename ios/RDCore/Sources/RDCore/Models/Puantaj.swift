import Foundation

// Puantaj (Aşama 3). Puantaj çalışma bilgisidir, finansal borç değildir: bu
// dosyadaki hiçbir tür ücret, tutar veya ödeme taşımaz. Sayım kuralları
// veritabanındaki puantaj_status_definitions ile aynıdır (entegrasyon testi
// karşılaştırır).

/// Günlük çalışma durumu. "Henüz işlenmedi" bir durum değil, kaydın
/// olmamasıdır (nil); devamsızlık sayılmaz.
public enum PuantajStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case tamGun = "tam_gun"
  case yarimGun = "yarim_gun"
  case calismadi
  case ucretliIzin = "ucretli_izin"
  case ucretsizIzin = "ucretsiz_izin"
  case raporlu
  case resmiTatil = "resmi_tatil"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .tamGun: "Tam gün çalıştı"
    case .yarimGun: "Yarım gün çalıştı"
    case .calismadi: "Çalışmadı"
    case .ucretliIzin: "Ücretli izin"
    case .ucretsizIzin: "Ücretsiz izin"
    case .raporlu: "Raporlu"
    case .resmiTatil: "Resmî tatil"
    }
  }

  /// Tablo hücresindeki kısa gösterim.
  public var shortLabel: String {
    switch self {
    case .tamGun: "T"
    case .yarimGun: "Y"
    case .calismadi: "Ç"
    case .ucretliIzin: "Üİ"
    case .ucretsizIzin: "İ"
    case .raporlu: "R"
    case .resmiTatil: "RT"
    }
  }

  /// Fiilî çalışma günü eşdeğeri (imalat/verim). Ücretli izin ve resmî tatil
  /// çalışılmış sayılmaz.
  public var workEquivalent: Decimal {
    switch self {
    case .tamGun: 1
    case .yarimGun: Decimal(string: "0.5")!
    default: 0
    }
  }

  public var category: PuantajCategory {
    switch self {
    case .tamGun, .yarimGun: .calisma
    case .calismadi: .devamsizlik
    case .ucretliIzin, .ucretsizIzin: .izin
    case .raporlu: .rapor
    case .resmiTatil: .tatil
    }
  }

  /// İleride sözleşmeye göre ücret kuralının bağlanacağı sınıf. Bu aşamada
  /// hiçbir hesapta kullanılmaz.
  public var payBasis: PuantajPayBasis {
    switch self {
    case .tamGun, .yarimGun: .calisilanGun
    case .calismadi, .ucretsizIzin: .ucretsiz
    case .ucretliIzin: .ucretliIzin
    case .raporlu: .rapor
    case .resmiTatil: .resmiTatil
    }
  }

  public var isWork: Bool { category == .calisma }
  public var allowsOvertime: Bool { isWork }
}

public enum PuantajCategory: String, Codable, Sendable {
  case calisma, izin, rapor, devamsizlik, tatil
}

public enum PuantajPayBasis: String, Codable, Sendable {
  case calisilanGun = "calisilan_gun"
  case ucretliIzin = "ucretli_izin"
  case ucretsiz, rapor
  case resmiTatil = "resmi_tatil"
}

/// Takvim ayı. Gün sayısı artık yılı hesaba katar.
public struct PuantajMonth: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let year: Int
  public let month: Int

  public init(year: Int, month: Int) {
    precondition((1...12).contains(month), "Geçersiz ay")
    self.year = year
    self.month = month
  }

  public init(containing day: CalendarDate) { self.init(year: day.year, month: day.month) }

  public static func current(today: CalendarDate = .today()) -> PuantajMonth { PuantajMonth(containing: today) }

  public static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

  public var dayCount: Int {
    switch month {
    case 2: Self.isLeap(year) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  public var firstDay: CalendarDate { CalendarDate(year: year, month: month, day: 1) }
  public var lastDay: CalendarDate { CalendarDate(year: year, month: month, day: dayCount) }
  public var days: [CalendarDate] { (1...dayCount).map { CalendarDate(year: year, month: month, day: $0) } }

  public func contains(_ day: CalendarDate) -> Bool { day.year == year && day.month == month }

  public var next: PuantajMonth { month == 12 ? PuantajMonth(year: year + 1, month: 1) : PuantajMonth(year: year, month: month + 1) }
  public var previous: PuantajMonth { month == 1 ? PuantajMonth(year: year - 1, month: 12) : PuantajMonth(year: year, month: month - 1) }

  public static let monthNames = ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos",
                                  "Eylül", "Ekim", "Kasım", "Aralık"]
  public var title: String { "\(Self.monthNames[month - 1]) \(year)" }
  public var description: String { firstDay.iso }

  public static func < (lhs: PuantajMonth, rhs: PuantajMonth) -> Bool { (lhs.year, lhs.month) < (rhs.year, rhs.month) }
}

public extension CalendarDate {
  /// ISO hafta günü: 1 = Pazartesi … 7 = Pazar.
  var isoWeekday: Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .istanbul
    let weekday = calendar.component(.weekday, from: date())  // 1 = Pazar
    return weekday == 1 ? 7 : weekday - 1
  }

  var weekdayShort: String { ["Pzt", "Sal", "Çar", "Per", "Cum", "Cmt", "Paz"][isoWeekday - 1] }

  /// "05.10.2026" (hata ve bilgi mesajları için).
  var dotted: String { String(format: "%02d.%02d.%04d", day, month, year) }
}

/// Günlük puantaj kaydı. Bağlantı ve adlar kayıt anında sunucuda yazılır.
public struct PuantajEntry: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let projectId: UUID
  public let personnelId: UUID
  public let workDate: CalendarDate
  public var status: PuantajStatus
  public var overtimeHours: Decimal
  public var overtimeNote: String?
  public var overtimeApprovedAt: Date?
  public var note: String?
  public let assignmentId: UUID?
  public let membershipId: UUID?
  public let crewId: UUID?
  public let subcontractorId: UUID?
  public let employmentType: EmploymentType
  public let personnelName: String
  public let crewName: String?
  public let isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), projectId: UUID, personnelId: UUID, workDate: CalendarDate, status: PuantajStatus,
              overtimeHours: Decimal = 0, overtimeNote: String? = nil, overtimeApprovedAt: Date? = nil,
              note: String? = nil, assignmentId: UUID? = nil, membershipId: UUID? = nil, crewId: UUID? = nil,
              subcontractorId: UUID? = nil, employmentType: EmploymentType = .sirket, personnelName: String,
              crewName: String? = nil, isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.projectId = projectId
    self.personnelId = personnelId
    self.workDate = workDate
    self.status = status
    self.overtimeHours = overtimeHours
    self.overtimeNote = overtimeNote
    self.overtimeApprovedAt = overtimeApprovedAt
    self.note = note
    self.assignmentId = assignmentId
    self.membershipId = membershipId
    self.crewId = crewId
    self.subcontractorId = subcontractorId
    self.employmentType = employmentType
    self.personnelName = personnelName
    self.crewName = crewName
    self.isDemo = isDemo
    self.version = version
  }

  public var isOvertimeApproved: Bool { overtimeApprovedAt != nil }
  public var hasOvertime: Bool { overtimeHours > 0 }

  enum CodingKeys: String, CodingKey {
    case id, status, note, version
    case projectId = "project_id", personnelId = "personnel_id", workDate = "work_date"
    case overtimeHours = "overtime_hours", overtimeNote = "overtime_note", overtimeApprovedAt = "overtime_approved_at"
    case assignmentId = "assignment_id", membershipId = "membership_id", crewId = "crew_id"
    case subcontractorId = "subcontractor_id", employmentType = "employment_type"
    case personnelName = "personnel_name", crewName = "crew_name", isDemo = "is_demo"
  }
}

// MARK: - Ay durumu

public enum PuantajPeriodStatus: String, Codable, CaseIterable, Sendable {
  case taslak, incelemede, onaylandi, kilitli

  public var title: String {
    switch self {
    case .taslak: "Taslak"
    case .incelemede: "İncelemede"
    case .onaylandi: "Onaylandı"
    case .kilitli: "Kilitli"
    }
  }

  /// Bu durumda kayıt girmek için gereken izin (nil: kimse yazamaz).
  public var editPermission: PermissionKey? {
    switch self {
    case .taslak: .puantajWrite
    case .incelemede: .puantajReview
    case .onaylandi, .kilitli: nil
    }
  }
}

public enum PuantajAction: String, Codable, CaseIterable, Identifiable, Sendable {
  case gonder, iade, onayla, kilitle
  case yenidenAc = "yeniden_ac"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .gonder: "İncelemeye gönder"
    case .iade: "Taslağa iade et"
    case .onayla: "Ayı onayla"
    case .kilitle: "Ayı kilitle"
    case .yenidenAc: "Yeniden aç"
    }
  }

  public var symbol: String {
    switch self {
    case .gonder: "paperplane"
    case .iade: "arrow.uturn.backward"
    case .onayla: "checkmark.seal"
    case .kilitle: "lock"
    case .yenidenAc: "lock.open"
    }
  }

  public var requiresReason: Bool { self == .yenidenAc }

  /// İşlemin yapılabileceği durumlar.
  public var allowedFrom: Set<PuantajPeriodStatus> {
    switch self {
    case .gonder: [.taslak]
    case .iade: [.incelemede]
    case .onayla: [.taslak, .incelemede]
    case .kilitle: [.onaylandi]
    case .yenidenAc: [.onaylandi, .kilitli]
    }
  }

  /// Sunucudaki kuralın aynısı; kilitli ayı açmak ayrı izindir.
  public func requiredPermission(from status: PuantajPeriodStatus) -> PermissionKey {
    switch self {
    case .gonder: .puantajWrite
    case .iade: .puantajReview
    case .onayla, .kilitle: .puantajApprove
    case .yenidenAc: status == .kilitli ? .puantajUnlock : .puantajApprove
    }
  }

  public static let minimumReasonLength = 10
}

/// Projenin bir aylık puantaj dönemi. Henüz kayıt yoksa sunucuda satır da
/// yoktur; arayüz bunu taslak olarak gösterir.
public struct PuantajPeriod: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let projectId: UUID
  public let month: CalendarDate
  public var status: PuantajPeriodStatus
  public var revision: Int
  public var submittedAt: Date?
  public var approvedAt: Date?
  public var approvedBy: UUID?
  public var firstApprovedAt: Date?
  public var firstApprovedBy: UUID?
  public var lockedAt: Date?
  public var version: Int

  public init(id: UUID = UUID(), projectId: UUID, month: PuantajMonth, status: PuantajPeriodStatus = .taslak,
              revision: Int = 0, submittedAt: Date? = nil, approvedAt: Date? = nil, approvedBy: UUID? = nil,
              firstApprovedAt: Date? = nil, firstApprovedBy: UUID? = nil, lockedAt: Date? = nil, version: Int = 1) {
    self.id = id
    self.projectId = projectId
    self.month = month.firstDay
    self.status = status
    self.revision = revision
    self.submittedAt = submittedAt
    self.approvedAt = approvedAt
    self.approvedBy = approvedBy
    self.firstApprovedAt = firstApprovedAt
    self.firstApprovedBy = firstApprovedBy
    self.lockedAt = lockedAt
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, month, status, revision, version
    case projectId = "project_id", submittedAt = "submitted_at", approvedAt = "approved_at", approvedBy = "approved_by"
    case firstApprovedAt = "first_approved_at", firstApprovedBy = "first_approved_by", lockedAt = "locked_at"
  }
}

/// Ay durum geçmişi satırı (onaylı görüntü sunucuda saklanır; uygulama
/// yalnızca olay bilgisini okur).
public struct PuantajPeriodEvent: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let action: PuantajAction
  public let fromStatus: PuantajPeriodStatus
  public let toStatus: PuantajPeriodStatus
  public let revision: Int
  public let reason: String?
  public let actorId: UUID?
  public let occurredAt: Date

  public init(id: UUID = UUID(), action: PuantajAction, fromStatus: PuantajPeriodStatus, toStatus: PuantajPeriodStatus,
              revision: Int, reason: String? = nil, actorId: UUID? = nil, occurredAt: Date = Date()) {
    self.id = id
    self.action = action
    self.fromStatus = fromStatus
    self.toStatus = toStatus
    self.revision = revision
    self.reason = reason
    self.actorId = actorId
    self.occurredAt = occurredAt
  }

  enum CodingKeys: String, CodingKey {
    case id, action, revision, reason
    case fromStatus = "from_status", toStatus = "to_status", actorId = "actor_id", occurredAt = "occurred_at"
  }
}

// MARK: - Aylık tablo satırları

/// puantaj_roster satırı: kişinin ay içindeki bir görev aralığı.
public struct PuantajRosterLink: Hashable, Codable, Sendable {
  public let personnelId: UUID
  public let fullName: String
  public let jobTitle: String?
  public let employmentType: EmploymentType
  public let subcontractorId: UUID?
  public let subcontractorName: String?
  public let via: WorkforceEntry.Via
  public let crewId: UUID?
  public let crewName: String?
  public let assignmentId: UUID
  public let membershipId: UUID?
  public let startDate: CalendarDate
  public let endDate: CalendarDate

  public init(personnelId: UUID, fullName: String, jobTitle: String? = nil, employmentType: EmploymentType = .sirket,
              subcontractorId: UUID? = nil, subcontractorName: String? = nil, via: WorkforceEntry.Via,
              crewId: UUID? = nil, crewName: String? = nil, assignmentId: UUID, membershipId: UUID? = nil,
              startDate: CalendarDate, endDate: CalendarDate) {
    self.personnelId = personnelId
    self.fullName = fullName
    self.jobTitle = jobTitle
    self.employmentType = employmentType
    self.subcontractorId = subcontractorId
    self.subcontractorName = subcontractorName
    self.via = via
    self.crewId = crewId
    self.crewName = crewName
    self.assignmentId = assignmentId
    self.membershipId = membershipId
    self.startDate = startDate
    self.endDate = endDate
  }

  public func covers(_ day: CalendarDate) -> Bool { startDate <= day && day <= endDate }

  enum CodingKeys: String, CodingKey {
    case via
    case personnelId = "personnel_id", fullName = "full_name", jobTitle = "job_title"
    case employmentType = "employment_type", subcontractorId = "subcontractor_id", subcontractorName = "subcontractor_name"
    case crewId = "crew_id", crewName = "crew_name", assignmentId = "assignment_id", membershipId = "membership_id"
    case startDate = "start_date", endDate = "end_date"
  }
}

// MARK: - Kaydetme

/// save_puantaj öğesi. status nil ise hücre temizlenir (henüz işlenmedi).
/// expectedVersion okunan kaydın sürümüdür; yeni hücrede nil.
public struct PuantajCellInput: Hashable, Encodable, Sendable {
  public let personnelId: UUID
  public let workDate: CalendarDate
  public let status: PuantajStatus?
  public let overtimeHours: Decimal
  public let overtimeNote: String?
  public let note: String?
  public let expectedVersion: Int?

  public init(personnelId: UUID, workDate: CalendarDate, status: PuantajStatus?, overtimeHours: Decimal = 0,
              overtimeNote: String? = nil, note: String? = nil, expectedVersion: Int? = nil) {
    self.personnelId = personnelId
    self.workDate = workDate
    self.status = status
    // Çalışılmayan güne fazla mesai yazılmaz (sunucu da reddeder).
    self.overtimeHours = (status?.allowsOvertime ?? false) ? overtimeHours : 0
    self.overtimeNote = (status?.allowsOvertime ?? false) ? overtimeNote.nilIfBlank : nil
    self.note = note.nilIfBlank
    self.expectedVersion = expectedVersion
  }

  enum CodingKeys: String, CodingKey {
    case status, note
    case personnelId = "personnel_id", workDate = "work_date", overtimeHours = "overtime_hours"
    case overtimeNote = "overtime_note", expectedVersion = "expected_version"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(personnelId, forKey: .personnelId)
    try container.encode(workDate, forKey: .workDate)
    try container.encode(status, forKey: .status)  // nil → null: hücreyi temizle
    try container.encode(overtimeHours, forKey: .overtimeHours)
    try container.encode(overtimeNote, forKey: .overtimeNote)
    try container.encode(note, forKey: .note)
    try container.encode(expectedVersion, forKey: .expectedVersion)
  }
}

public enum PuantajSaveResult: String, Codable, Sendable {
  case eklendi, guncellendi, silindi, degismedi, atlandi, bos
}

public struct PuantajSaveOutcome: Hashable, Codable, Sendable {
  public let personnelId: UUID
  public let workDate: CalendarDate
  public let result: PuantajSaveResult
  public let entryId: UUID?
  public let version: Int?

  public init(personnelId: UUID, workDate: CalendarDate, result: PuantajSaveResult, entryId: UUID?, version: Int?) {
    self.personnelId = personnelId
    self.workDate = workDate
    self.result = result
    self.entryId = entryId
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case result, version
    case personnelId = "personnel_id", workDate = "work_date", entryId = "entry_id"
  }
}

// MARK: - Özet

/// Aylık sayımlar. Her alan tek bir kategoriyi sayar; kategoriler toplanıp tek
/// bir "gün" sayısına dönüştürülmez. Girilmemiş gün hiçbir alana girmez.
public struct PuantajSummary: Hashable, Codable, Sendable {
  /// Kaydı olan gün sayısı (her durum dahil).
  public var recordedDays = 0
  public var fullDays = 0
  public var halfDays = 0
  /// Fiilî çalışma günü eşdeğeri: tam × 1 + yarım × 0,5.
  public var workEquivalent: Decimal = 0
  /// "Çalışmadı" (devamsız) günler.
  public var absentDays = 0
  public var paidLeaveDays = 0
  public var unpaidLeaveDays = 0
  public var sickDays = 0
  public var publicHolidayDays = 0
  public var overtimeHours: Decimal = 0
  public var approvedOvertimeHours: Decimal = 0

  public init() {}

  public init<S: Sequence>(entries: S) where S.Element == PuantajEntry {
    for entry in entries { add(entry) }
  }

  public mutating func add(_ entry: PuantajEntry) {
    recordedDays += 1
    workEquivalent += entry.status.workEquivalent
    overtimeHours += entry.overtimeHours
    if entry.isOvertimeApproved { approvedOvertimeHours += entry.overtimeHours }
    switch entry.status {
    case .tamGun: fullDays += 1
    case .yarimGun: halfDays += 1
    case .calismadi: absentDays += 1
    case .ucretliIzin: paidLeaveDays += 1
    case .ucretsizIzin: unpaidLeaveDays += 1
    case .raporlu: sickDays += 1
    case .resmiTatil: publicHolidayDays += 1
    }
  }

  public static func + (lhs: PuantajSummary, rhs: PuantajSummary) -> PuantajSummary {
    var total = lhs
    total.recordedDays += rhs.recordedDays
    total.fullDays += rhs.fullDays
    total.halfDays += rhs.halfDays
    total.workEquivalent += rhs.workEquivalent
    total.absentDays += rhs.absentDays
    total.paidLeaveDays += rhs.paidLeaveDays
    total.unpaidLeaveDays += rhs.unpaidLeaveDays
    total.sickDays += rhs.sickDays
    total.publicHolidayDays += rhs.publicHolidayDays
    total.overtimeHours += rhs.overtimeHours
    total.approvedOvertimeHours += rhs.approvedOvertimeHours
    return total
  }
}

/// puantaj_summary RPC satırı (sunucu hesabı; Swift hesabıyla karşılaştırılır).
public struct PuantajServerSummary: Hashable, Codable, Sendable {
  public let personnelId: UUID
  public let personnelName: String
  public let kayitliGun: Int
  public let tamGun: Int
  public let yarimGun: Int
  public let fiiliCalisma: Decimal
  public let calismadi: Int
  public let ucretliIzin: Int
  public let ucretsizIzin: Int
  public let raporlu: Int
  public let resmiTatil: Int
  public let fazlaMesaiSaat: Decimal
  public let onayliFazlaMesai: Decimal

  public var summary: PuantajSummary {
    var value = PuantajSummary()
    value.recordedDays = kayitliGun
    value.fullDays = tamGun
    value.halfDays = yarimGun
    value.workEquivalent = fiiliCalisma
    value.absentDays = calismadi
    value.paidLeaveDays = ucretliIzin
    value.unpaidLeaveDays = ucretsizIzin
    value.sickDays = raporlu
    value.publicHolidayDays = resmiTatil
    value.overtimeHours = fazlaMesaiSaat
    value.approvedOvertimeHours = onayliFazlaMesai
    return value
  }

  enum CodingKeys: String, CodingKey {
    case calismadi, raporlu
    case personnelId = "personnel_id", personnelName = "personnel_name", kayitliGun = "kayitli_gun"
    case tamGun = "tam_gun", yarimGun = "yarim_gun", fiiliCalisma = "fiili_calisma"
    case ucretliIzin = "ucretli_izin", ucretsizIzin = "ucretsiz_izin", resmiTatil = "resmi_tatil"
    case fazlaMesaiSaat = "fazla_mesai_saat", onayliFazlaMesai = "onayli_fazla_mesai"
  }
}

/// Fazla mesai saati girdisi: "2", "2,5", "1.5"; 0–16 saat, en fazla 2 ondalık.
public enum OvertimeInput {
  public static let maximumHours: Decimal = 16

  public static func parse(_ raw: String) -> Decimal? {
    let text = raw.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return 0 }
    guard let value = Money.parse(text), value >= 0, value <= maximumHours else { return nil }
    return value
  }

  public static func format(_ hours: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Money.locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return formatter.string(from: hours as NSDecimalNumber) ?? "\(hours)"
  }
}
