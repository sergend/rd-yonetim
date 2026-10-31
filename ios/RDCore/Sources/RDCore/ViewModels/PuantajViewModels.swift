import Foundation
import Observation

// MARK: - Aylık tablo

/// Tablonun bir satırı: kişi ve ay içindeki görev aralıkları.
public struct PuantajRow: Identifiable, Hashable, Sendable {
  public let personnelId: UUID
  public let name: String
  public let jobTitle: String?
  public let subcontractorId: UUID?
  public let subcontractorName: String?
  public internal(set) var links: [PuantajRosterLink]

  public var id: UUID { personnelId }

  /// O gün geçerli bağlantı: önce doğrudan görevlendirme (sunucuyla aynı öncelik).
  public func link(on day: CalendarDate) -> PuantajRosterLink? {
    let matches = links.filter { $0.covers(day) }
    return matches.first { $0.via == .dogrudan } ?? matches.first
  }

  public func isAssigned(on day: CalendarDate) -> Bool { links.contains { $0.covers(day) } }

  public var crewIds: Set<UUID> { Set(links.compactMap(\.crewId)) }

  /// Ay içindeki son ekip (yoksa "Doğrudan görevli").
  public var groupName: String {
    links.max { $0.startDate < $1.startDate }?.crewName ?? "Doğrudan görevli"
  }

  /// Ay içinde ekip değişikliği var mı? (tabloda işaretlenir)
  public var changedCrewInMonth: Bool { Set(links.map { $0.crewId?.uuidString ?? "-" }).count > 1 }
}

public struct PuantajCellKey: Hashable, Sendable {
  public let personnelId: UUID
  public let day: CalendarDate

  public init(_ personnelId: UUID, _ day: CalendarDate) {
    self.personnelId = personnelId
    self.day = day
  }
}

/// Bir projenin bir aylık puantajı: satırlar, hücreler ve özetler.
public struct PuantajGrid: Sendable {
  public let month: PuantajMonth
  public private(set) var rows: [PuantajRow]
  public private(set) var entries: [PuantajCellKey: PuantajEntry]

  public init(month: PuantajMonth, roster: [PuantajRosterLink] = [], entries: [PuantajEntry] = []) {
    self.month = month
    var rows: [UUID: PuantajRow] = [:]
    for link in roster {
      rows[link.personnelId, default: PuantajRow(personnelId: link.personnelId, name: link.fullName, jobTitle: link.jobTitle,
                                                 subcontractorId: link.subcontractorId,
                                                 subcontractorName: link.subcontractorName, links: [])]
        .links.append(link)
    }
    // Görevi sonradan kısaltılan kişinin eski kayıtları da görünür kalır.
    for entry in entries where rows[entry.personnelId] == nil {
      rows[entry.personnelId] = PuantajRow(personnelId: entry.personnelId, name: entry.personnelName, jobTitle: nil,
                                           subcontractorId: entry.subcontractorId, subcontractorName: nil, links: [])
    }
    self.rows = rows.values.sorted {
      ($0.groupName.lowercased(with: Money.locale), $0.name.lowercased(with: Money.locale))
        < ($1.groupName.lowercased(with: Money.locale), $1.name.lowercased(with: Money.locale))
    }
    self.entries = Dictionary(entries.filter { month.contains($0.workDate) }.map { (PuantajCellKey($0.personnelId, $0.workDate), $0) },
                              uniquingKeysWith: { _, last in last })
  }

  public func row(_ personnelId: UUID) -> PuantajRow? { rows.first { $0.personnelId == personnelId } }

  public func entry(_ personnelId: UUID, _ day: CalendarDate) -> PuantajEntry? { entries[PuantajCellKey(personnelId, day)] }

  public func entries(for personnelId: UUID) -> [PuantajEntry] {
    entries.values.filter { $0.personnelId == personnelId }.sorted { $0.workDate < $1.workDate }
  }

  public func entries(on day: CalendarDate) -> [PuantajEntry] { entries.values.filter { $0.workDate == day } }

  public var allEntries: [PuantajEntry] { Array(entries.values) }

  // MARK: Kaydetme sonucunu uygula

  /// Sunucu yanıtını yerel tabloya işler (her hücre için yeniden istek yapmadan).
  /// Atlanan hücreler için doğru değeri sunucudan okumak gerekir; true döner.
  @discardableResult
  public mutating func apply(_ outcomes: [PuantajSaveOutcome], inputs: [PuantajCellInput], projectId: UUID) -> Bool {
    var needsRefresh = false
    let byKey = Dictionary(inputs.map { (PuantajCellKey($0.personnelId, $0.workDate), $0) }, uniquingKeysWith: { a, _ in a })
    for outcome in outcomes {
      let key = PuantajCellKey(outcome.personnelId, outcome.workDate)
      guard let input = byKey[key] else { continue }
      switch outcome.result {
      case .eklendi:
        guard let status = input.status, let id = outcome.entryId else { continue }
        let row = row(outcome.personnelId)
        let link = row?.link(on: outcome.workDate)
        entries[key] = PuantajEntry(id: id, projectId: projectId, personnelId: outcome.personnelId,
                                    workDate: outcome.workDate, status: status, overtimeHours: input.overtimeHours,
                                    overtimeNote: input.overtimeNote, note: input.note,
                                    assignmentId: link?.assignmentId, membershipId: link?.membershipId,
                                    crewId: link?.crewId, subcontractorId: row?.subcontractorId,
                                    employmentType: link?.employmentType ?? .sirket,
                                    personnelName: row?.name ?? "Personel", crewName: link?.crewName,
                                    version: outcome.version ?? 1)
      case .guncellendi:
        guard var entry = entries[key], let status = input.status else { needsRefresh = true; continue }
        if entry.status != status || entry.overtimeHours != input.overtimeHours { entry.overtimeApprovedAt = nil }
        entry.status = status
        entry.overtimeHours = input.overtimeHours
        entry.overtimeNote = input.overtimeNote
        entry.note = input.note
        entry.version = outcome.version ?? entry.version + 1
        entries[key] = entry
      case .silindi:
        entries[key] = nil
      case .atlandi:
        needsRefresh = true  // başkasının değeri okunmalı
      case .degismedi, .bos:
        break
      }
    }
    return needsRefresh
  }

  // MARK: Özetler

  public func summary(for personnelId: UUID) -> PuantajSummary { PuantajSummary(entries: entries(for: personnelId)) }

  public var projectSummary: PuantajSummary { PuantajSummary(entries: entries.values) }

  /// Ekip bazında özet. Kayıt, girildiği gün kişinin bağlı olduğu ekibe sayılır
  /// (ay ortasında ekip değiştiren kişi iki ekipte de görünür).
  public var crewSummaries: [PuantajGroupSummary] {
    let groups = Dictionary(grouping: entries.values) { $0.crewId }
    return groups.map { crewId, items in
      PuantajGroupSummary(id: crewId, name: items.first?.crewName ?? "Doğrudan görevli",
                          people: Set(items.map(\.personnelId)).count, summary: PuantajSummary(entries: items))
    }.sorted { ($0.id == nil ? 1 : 0, $0.name) < ($1.id == nil ? 1 : 0, $1.name) }
  }

  /// Görevli olduğu ama henüz işlenmemiş günler (bugüne kadar). Bilgi amaçlıdır;
  /// devamsızlık sayılmaz.
  public func unprocessedDays(for row: PuantajRow, today: CalendarDate = .today()) -> Int {
    month.days.filter { $0 <= today && row.isAssigned(on: $0) && entry(row.personnelId, $0) == nil }.count
  }
}

public struct PuantajGroupSummary: Identifiable, Hashable, Sendable {
  public let id: UUID?
  public let name: String
  public let people: Int
  public let summary: PuantajSummary
}

// MARK: - Toplu işlem planı

/// Toplu işlem önizlemesi: hangi kişiye, hangi güne, ne uygulanacak.
public struct PuantajPlan: Sendable {
  public enum Kind: Equatable, Sendable {
    /// Boş hücreye yazılacak.
    case ekle
    /// Dolu hücrenin üzerine yazılacak (yalnızca kullanıcı seçtiyse).
    case uzerineYaz
    /// Dolu hücre korunacak.
    case korunacak
    /// Zaten aynı değer.
    case ayni
    /// Kişi o gün projede görevli değil.
    case gorevliDegil
    /// Kopyalanacak kaynak günde kayıt yok.
    case kaynakYok

    public var title: String {
      switch self {
      case .ekle: "Eklenecek"
      case .uzerineYaz: "Üzerine yazılacak"
      case .korunacak: "Dolu, korunacak"
      case .ayni: "Zaten aynı"
      case .gorevliDegil: "O gün görevli değil"
      case .kaynakYok: "Önceki günde kayıt yok"
      }
    }

    public var willSave: Bool { self == .ekle || self == .uzerineYaz }
  }

  public struct Line: Identifiable, Hashable, Sendable {
    public let personnelId: UUID
    public let name: String
    public let day: CalendarDate
    public let current: PuantajStatus?
    public let new: PuantajStatus?
    public let kind: Kind
    public var id: PuantajCellKey { PuantajCellKey(personnelId, day) }
  }

  public let lines: [Line]
  public let items: [PuantajCellInput]
  public let overwrite: Bool

  public var saveCount: Int { lines.filter { $0.kind.willSave }.count }
  public var overwriteCount: Int { lines.filter { $0.kind == .uzerineYaz }.count }
  public var keptCount: Int { lines.filter { $0.kind == .korunacak }.count }
  public var isEmpty: Bool { items.isEmpty }

  /// Seçilen kişilere aynı günü aynı durumla işler.
  public static func fill(_ grid: PuantajGrid, day: CalendarDate, people: [UUID], status: PuantajStatus,
                          overwrite: Bool) -> PuantajPlan {
    build(grid, day: day, people: people, overwrite: overwrite) { _ in .some(status) }
  }

  /// Kaynak günün durumlarını hedef güne kopyalar (fazla mesai kopyalanmaz).
  /// Kaynak gün başka aydaysa kayıtları `sourceEntries` ile verilir.
  public static func copy(_ grid: PuantajGrid, from source: CalendarDate, to target: CalendarDate, people: [UUID],
                          overwrite: Bool, sourceEntries: [UUID: PuantajEntry]? = nil) -> PuantajPlan {
    build(grid, day: target, people: people, overwrite: overwrite) { person in
      let entry = sourceEntries.map { $0[person] } ?? grid.entry(person, source)
      return entry.map { .some($0.status) } ?? nil
    }
  }

  /// newStatus: nil → kaynak yok; .some(status) → uygulanacak durum.
  private static func build(_ grid: PuantajGrid, day: CalendarDate, people: [UUID], overwrite: Bool,
                            newStatus: (UUID) -> PuantajStatus??) -> PuantajPlan {
    var lines: [Line] = []
    var items: [PuantajCellInput] = []
    for person in people {
      guard let row = grid.row(person) else { continue }
      let existing = grid.entry(person, day)
      func line(_ new: PuantajStatus?, _ kind: Kind) {
        lines.append(Line(personnelId: person, name: row.name, day: day, current: existing?.status, new: new, kind: kind))
      }
      guard row.isAssigned(on: day) else { line(nil, .gorevliDegil); continue }
      guard let wrapped = newStatus(person), let status = wrapped else { line(nil, .kaynakYok); continue }
      if let existing {
        if existing.status == status { line(status, .ayni); continue }
        guard overwrite else { line(status, .korunacak); continue }
        line(status, .uzerineYaz)
        // Okunan sürümle gönderilir: arada başkası değiştirdiyse sunucu reddeder.
        items.append(PuantajCellInput(personnelId: person, workDate: day, status: status, note: existing.note,
                                      expectedVersion: existing.version))
      } else {
        line(status, .ekle)
        items.append(PuantajCellInput(personnelId: person, workDate: day, status: status))
      }
    }
    return PuantajPlan(lines: lines, items: items, overwrite: overwrite)
  }
}

// MARK: - Ekran modeli

/// Bir projenin aylık puantaj ekranı.
@MainActor
@Observable
public final class PuantajViewModel {
  public private(set) var month: PuantajMonth
  public private(set) var grid: PuantajGrid
  public private(set) var period: PuantajPeriod?
  public private(set) var events: [PuantajPeriodEvent] = []
  public private(set) var isLoading = false
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?
  /// Son işlemin kısa sonucu ("4 hücre eklendi, 1 atlandı").
  public private(set) var notice: String?

  public var crewFilter: UUID?
  public var subcontractorFilter: UUID?
  public var searchText = ""

  public let project: Project
  private let access: AccessControl
  private let repository: PuantajRepository
  private let today: () -> CalendarDate

  public init(project: Project, access: AccessControl, repository: PuantajRepository,
              month: PuantajMonth = .current(), today: @escaping () -> CalendarDate = { .today() }) {
    self.project = project
    self.access = access
    self.repository = repository
    self.month = month
    self.today = today
    grid = PuantajGrid(month: month)
  }

  // MARK: Yetki ve durum

  public var status: PuantajPeriodStatus { period?.status ?? .taslak }
  public var canRead: Bool { access.can(.puantajRead, in: project.id) }

  /// Bu ayda kayıt girebilir mi? (onaylı/kilitli ayda kimse giremez)
  public var canEdit: Bool {
    guard let permission = status.editPermission else { return false }
    return access.can(permission, in: project.id)
  }

  public var canApproveOvertime: Bool { access.can(.puantajApprove, in: project.id) && status.editPermission != nil }

  /// Kullanıcının bu ay için yapabileceği durum işlemleri.
  public var availableActions: [PuantajAction] {
    PuantajAction.allCases.filter {
      $0.allowedFrom.contains(status) && access.can($0.requiredPermission(from: status), in: project.id)
    }
  }

  public var editBlockedReason: String? {
    switch status {
    case .onaylandi: "Bu ay onaylandı. Düzeltme için ayın yetkili kişi tarafından gerekçeyle yeniden açılması gerekir."
    case .kilitli: "Bu ay kilitli. Düzeltme için ayın yetkili kişi tarafından gerekçeyle yeniden açılması gerekir."
    case .incelemede where !canEdit: "Ay incelemede. Değişiklik yalnızca inceleme yetkisi olan kişi tarafından yapılır."
    default: canEdit ? nil : "Bu projede puantaj girme yetkiniz yok."
    }
  }

  public var isCurrentMonth: Bool { month == PuantajMonth(containing: today()) }
  public var todayValue: CalendarDate { today() }

  // MARK: Filtre

  public var visibleRows: [PuantajRow] {
    grid.rows.filter { row in
      (crewFilter.map { row.crewIds.contains($0) } ?? true)
        && (subcontractorFilter.map { row.subcontractorId == $0 } ?? true)
        && matches(searchText, row.name, row.jobTitle, row.subcontractorName, row.groupName)
    }
  }

  public var crewOptions: [(id: UUID, name: String)] {
    var seen: [UUID: String] = [:]
    for link in grid.rows.flatMap(\.links) { if let id = link.crewId { seen[id] = link.crewName ?? "Ekip" } }
    return seen.map { (id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
  }

  public var subcontractorOptions: [(id: UUID, name: String)] {
    var seen: [UUID: String] = [:]
    for row in grid.rows { if let id = row.subcontractorId { seen[id] = row.subcontractorName ?? "Taşeron" } }
    return seen.map { (id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
  }

  public var hasFilter: Bool { crewFilter != nil || subcontractorFilter != nil }

  public func clearFilters() {
    crewFilter = nil
    subcontractorFilter = nil
  }

  // MARK: Yükleme

  /// Ayın tüm verisi tek seferde (satırlar, kayıtlar, dönem): hücre başına istek yok.
  public func load() async {
    guard canRead else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    let month = month
    do {
      async let roster = repository.roster(projectId: project.id, month: month)
      async let entries = repository.entries(projectId: project.id, month: month)
      async let period = repository.period(projectId: project.id, month: month)
      let loaded = PuantajGrid(month: month, roster: try await roster, entries: try await entries)
      let loadedPeriod = try await period
      guard month == self.month else { return }  // bu arada ay değiştiyse eski yanıtı at
      grid = loaded
      self.period = loadedPeriod
      if let loadedPeriod {
        events = try await repository.events(periodId: loadedPeriod.id)
      } else {
        events = []
      }
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func show(month newMonth: PuantajMonth) async {
    guard newMonth != month else { return }
    month = newMonth
    grid = PuantajGrid(month: newMonth)
    period = nil
    events = []
    notice = nil
    await load()
  }

  public func showNextMonth() async { await show(month: month.next) }
  public func showPreviousMonth() async { await show(month: month.previous) }

  // MARK: Tek hücre

  /// Hücreyi kaydeder; status nil ise temizler. Okunan sürümle gönderilir.
  public func setCell(personnelId: UUID, day: CalendarDate, status: PuantajStatus?, overtimeHours: Decimal = 0,
                      overtimeNote: String? = nil, note: String? = nil) async -> Bool {
    let existing = grid.entry(personnelId, day)
    if existing == nil && status == nil { return true }
    if let problem = cellProblem(personnelId: personnelId, day: day, status: status, overtimeHours: overtimeHours) {
      errorMessage = problem
      return false
    }
    let input = PuantajCellInput(personnelId: personnelId, workDate: day, status: status, overtimeHours: overtimeHours,
                                 overtimeNote: overtimeNote, note: note, expectedVersion: existing?.version)
    return await save([input], announce: false)
  }

  /// Hızlı durum seçimi: kurallar `PuantajCellInput.statusChange` içindedir
  /// (fazla mesai desteklemeyen duruma geçişte mesai düşer).
  public func setStatus(personnelId: UUID, day: CalendarDate, status: PuantajStatus?) async -> Bool {
    let existing = grid.entry(personnelId, day)
    if existing == nil && status == nil { return true }
    let input = PuantajCellInput.statusChange(personnelId: personnelId, workDate: day, from: existing, to: status)
    if let problem = cellProblem(personnelId: personnelId, day: day, status: status, overtimeHours: input.overtimeHours) {
      errorMessage = problem
      return false
    }
    return await save([input], announce: false)
  }

  /// Sunucuya gitmeden yakalanabilen hatalar (sunucu aynı kuralları uygular).
  public func cellProblem(personnelId: UUID, day: CalendarDate, status: PuantajStatus?, overtimeHours: Decimal) -> String? {
    if let reason = editBlockedReason { return reason }
    guard month.contains(day) else { return "Gün bu aya ait değil." }
    if status != nil, grid.entry(personnelId, day) == nil, grid.row(personnelId)?.isAssigned(on: day) != true {
      return "Kişi bu tarihte projede görevli değil; önce görevlendirme veya ekip üyeliği ekleyin."
    }
    if let status {
      if overtimeHours > 0 && !status.allowsOvertime {
        return "Fazla mesai yalnızca tam veya yarım gün çalışılan güne yazılabilir."
      }
      if overtimeHours < 0 || overtimeHours > OvertimeInput.maximumHours {
        return "Fazla mesai 0 ile 16 saat arasında olmalı."
      }
      if status.isWork && day > today() { return "İleri bir tarihe çalışma girilemez." }
    }
    return nil
  }

  // MARK: Toplu işlem

  public func planFill(day: CalendarDate, people: [UUID], status: PuantajStatus, overwrite: Bool) -> PuantajPlan {
    PuantajPlan.fill(grid, day: day, people: people, status: status, overwrite: overwrite)
  }

  /// Kaynak gün önceki aydaysa (ayın 1'i için) o günün kayıtları ayrıca okunur.
  public func planCopy(from source: CalendarDate, to target: CalendarDate, people: [UUID],
                       overwrite: Bool) async -> PuantajPlan {
    var sourceEntries: [UUID: PuantajEntry]?
    if !month.contains(source) {
      do {
        let other = try await repository.entries(projectId: project.id, month: PuantajMonth(containing: source))
        sourceEntries = Dictionary(other.filter { $0.workDate == source }.map { ($0.personnelId, $0) },
                                   uniquingKeysWith: { a, _ in a })
      } catch {
        errorMessage = message(for: error)
        sourceEntries = [:]
      }
    }
    return PuantajPlan.copy(grid, from: source, to: target, people: people, overwrite: overwrite,
                            sourceEntries: sourceEntries)
  }

  /// Önizlemesi gösterilen planı tek istekte kaydeder.
  public func commit(_ plan: PuantajPlan) async -> Bool {
    guard !plan.isEmpty else {
      notice = "Kaydedilecek değişiklik yok."
      return true
    }
    if let reason = editBlockedReason {
      errorMessage = reason
      return false
    }
    if plan.items.contains(where: { ($0.status?.isWork ?? false) && $0.workDate > today() }) {
      errorMessage = "İleri bir tarihe çalışma girilemez."
      return false
    }
    return await save(plan.items, announce: true)
  }

  private func save(_ items: [PuantajCellInput], announce: Bool) async -> Bool {
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      // Sürümü bilinen hücreler sürümle, boş hücreler "üzerine yazma" kapalı
      // gönderilir: arada başkasının doldurduğu hücre ezilmez, atlanır.
      let outcomes = try await repository.save(projectId: project.id, items: items, overwrite: false)
      let needsRefresh = grid.apply(outcomes, inputs: items, projectId: project.id)
      if announce || outcomes.contains(where: { $0.result == .atlandi }) { notice = Self.notice(for: outcomes) }
      if needsRefresh { await reloadEntries() }
      return true
    } catch {
      errorMessage = message(for: error)
      if case RepositoryError.conflict = error { await reloadEntries() }
      return false
    }
  }

  private func reloadEntries() async {
    do {
      let entries = try await repository.entries(projectId: project.id, month: month)
      grid = PuantajGrid(month: month, roster: grid.rows.flatMap(\.links), entries: entries)
    } catch {
      errorMessage = message(for: error)
    }
  }

  static func notice(for outcomes: [PuantajSaveOutcome]) -> String {
    let counts = Dictionary(grouping: outcomes, by: \.result).mapValues(\.count)
    var parts: [String] = []
    if let n = counts[.eklendi] { parts.append("\(n) hücre eklendi") }
    if let n = counts[.guncellendi] { parts.append("\(n) güncellendi") }
    if let n = counts[.silindi] { parts.append("\(n) temizlendi") }
    if let n = counts[.atlandi] { parts.append("\(n) hücre başka biri tarafından doldurulduğu için korundu") }
    if parts.isEmpty { return "Değişiklik yok; kayıtlar zaten güncel." }
    return parts.joined(separator: ", ") + "."
  }

  // MARK: Ay durumu

  public func perform(_ action: PuantajAction, reason: String? = nil) async -> Bool {
    if action.requiresReason && (reason.nilIfBlank?.count ?? 0) < PuantajAction.minimumReasonLength {
      errorMessage = "Gerekçe en az \(PuantajAction.minimumReasonLength) karakter olmalı."
      return false
    }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      period = try await repository.transition(projectId: project.id, month: month, action: action,
                                               reason: reason.nilIfBlank, expectedVersion: period?.version)
      if let period { events = try await repository.events(periodId: period.id) }
      notice = "\(month.title): \(status.title.lowercased(with: Money.locale))."
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  /// Ayın onay bekleyen fazla mesaileri.
  public var pendingOvertime: [PuantajEntry] {
    grid.allEntries.filter { $0.hasOvertime && !$0.isOvertimeApproved }.sorted { ($0.workDate, $0.personnelName) < ($1.workDate, $1.personnelName) }
  }

  public func approveOvertime(_ entries: [PuantajEntry]) async {
    guard !entries.isEmpty else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      let count = try await repository.approveOvertime(entryIds: entries.map(\.id))
      notice = "\(count) fazla mesai onaylandı."
      await reloadEntries()
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func dismissNotice() { notice = nil }
}
