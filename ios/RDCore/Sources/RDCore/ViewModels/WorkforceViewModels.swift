import Foundation
import Observation

/// Arama metnine göre (Türkçe büyük/küçük harf duyarsız) süzme.
func matches(_ query: String, _ fields: String?...) -> Bool {
  guard let query = query.nilIfBlank?.lowercased(with: Money.locale) else { return true }
  return fields.contains { $0?.lowercased(with: Money.locale).contains(query) == true }
}

// MARK: - Taşeron listesi

@MainActor
@Observable
public final class SubcontractorListViewModel {
  public private(set) var items: [Subcontractor] = []
  public var searchText = ""
  public var showInactive = false
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let access: AccessControl
  private let repository: WorkforceRepository

  public init(access: AccessControl, repository: WorkforceRepository) {
    self.access = access
    self.repository = repository
  }

  public var canCreate: Bool { access.can(.taseronWrite) }

  public var filtered: [Subcontractor] {
    items.filter { (showInactive || $0.isActive) && matches(searchText, $0.name, $0.trade?.title, $0.contactName) }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      items = try await repository.subcontractors()
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func upsert(_ item: Subcontractor) {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
    } else {
      items.append(item)
      items.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
  }
}

// MARK: - Taşeron detayı

/// Taşeron kartı: bağlı cari, çalıştığı projeler, belgeler, ekipler ve personel.
@MainActor
@Observable
public final class SubcontractorDetailViewModel {
  public private(set) var subcontractor: Subcontractor
  public private(set) var cariAccount: CariAccount?
  public private(set) var projectLinks: [SubcontractorProject] = []
  public private(set) var documents: [SubcontractorDocument] = []
  public private(set) var crews: [Crew] = []
  public private(set) var people: [Personnel] = []
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let access: AccessControl
  private let repositories: Repositories

  public init(subcontractor: Subcontractor, access: AccessControl, repositories: Repositories) {
    self.subcontractor = subcontractor
    self.access = access
    self.repositories = repositories
  }

  public var canEdit: Bool { access.can(.taseronWrite) }
  public var canManagePeople: Bool { access.can(.personelWrite) }

  /// Taşeronun kaydedilebileceği projeler (görevlendirme yetkisi olan, demo durumu aynı).
  public func linkableProjects(_ projects: [Project]) -> [Project] {
    projects.filter { access.can(.gorevlendirmeWrite, in: $0.id) && $0.isDemo == subcontractor.isDemo }
  }

  public var currentLinks: [SubcontractorProject] { projectLinks.filter { $0.period.isOngoing() } }
  public var pastLinks: [SubcontractorProject] { projectLinks.filter { !$0.period.isOngoing() } }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    let workforce = repositories.workforce
    do {
      if let updated = try await workforce.subcontractors().first(where: { $0.id == subcontractor.id }) {
        subcontractor = updated
      }
      async let links = workforce.subcontractorProjects(subcontractorId: subcontractor.id, projectId: nil)
      async let docs = workforce.documents(subcontractorId: subcontractor.id)
      async let crewList = workforce.crews()
      async let personList = workforce.personnel()
      projectLinks = try await links.sorted { $0.startDate > $1.startDate }
      documents = try await docs
      crews = try await crewList.filter { $0.subcontractorId == subcontractor.id }
      people = try await personList.filter { $0.subcontractorId == subcontractor.id }
    } catch {
      errorMessage = message(for: error)
    }
    // Cari kart ayrı izinlidir; göremeyen kullanıcıya yalnızca bağlı olduğu bilgisi gösterilir.
    if let cariId = subcontractor.cariAccountId, access.canAnywhere(.cariRead) {
      cariAccount = try? await repositories.cari.getAccount(id: cariId)
    } else {
      cariAccount = nil
    }
  }

  public func didSave(_ subcontractor: Subcontractor) { self.subcontractor = subcontractor }

  public func addDocument(title: String, documentNo: String, validUntil: CalendarDate?) async -> Bool {
    guard let title = title.nilIfBlank else {
      errorMessage = "Belge adı zorunlu."
      return false
    }
    do {
      let document = try await repositories.workforce.addDocument(SubcontractorDocument(
        subcontractorId: subcontractor.id, title: title, documentNo: documentNo.nilIfBlank, validUntil: validUntil))
      documents.append(document)
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  public func addProject(_ projectId: UUID, start: CalendarDate, scope: String) async -> Bool {
    let link = SubcontractorProject(subcontractorId: subcontractor.id, projectId: projectId, startDate: start,
                                    scope: scope.nilIfBlank)
    if projectLinks.contains(where: { $0.projectId == projectId && $0.period.overlaps(link.period) }) {
      errorMessage = "Taşeron bu projede aynı tarihlerde zaten kayıtlı."
      return false
    }
    do {
      projectLinks.insert(try await repositories.workforce.addSubcontractorProject(link), at: 0)
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  public func canEnd(_ link: SubcontractorProject) -> Bool {
    link.endDate == nil && access.can(.gorevlendirmeWrite, in: link.projectId)
  }

  public func end(_ link: SubcontractorProject, on day: CalendarDate = .today()) async {
    do {
      try await repositories.workforce.endSubcontractorProject(id: link.id, on: day)
      if let index = projectLinks.firstIndex(where: { $0.id == link.id }) { projectLinks[index].endDate = day }
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - Personel listesi

@MainActor
@Observable
public final class PersonnelListViewModel {
  public private(set) var people: [Personnel] = []
  public private(set) var subcontractors: [UUID: Subcontractor] = [:]
  public var searchText = ""
  public var employmentFilter: EmploymentType?
  public var showInactive = false
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let access: AccessControl
  private let repository: WorkforceRepository

  public init(access: AccessControl, repository: WorkforceRepository) {
    self.access = access
    self.repository = repository
  }

  public var canCreate: Bool { access.can(.personelWrite) }

  public func subcontractorName(_ id: UUID?) -> String? { id.flatMap { subcontractors[$0]?.name } }

  public var filtered: [Personnel] {
    people.filter {
      (showInactive || $0.isActive) && (employmentFilter == nil || $0.employmentType == employmentFilter)
        && matches(searchText, $0.fullName, $0.jobTitle, $0.trade?.title, subcontractorName($0.subcontractorId))
    }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      async let people = repository.personnel()
      async let subs = repository.subcontractors()
      self.people = try await people
      subcontractors = Dictionary(uniqueKeysWithValues: try await subs.map { ($0.id, $0) })
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func upsert(_ person: Personnel) {
    if let index = people.firstIndex(where: { $0.id == person.id }) {
      people[index] = person
    } else {
      people.append(person)
      people.sort { $0.fullName.localizedCompare($1.fullName) == .orderedAscending }
    }
  }
}

// MARK: - Personel detayı

/// Personel kartı: iletişim (yetkiliyse), ekip üyelik geçmişi ve görevlendirmeler.
@MainActor
@Observable
public final class PersonnelDetailViewModel {
  public private(set) var person: Personnel
  public private(set) var phone: String?
  public private(set) var memberships: [CrewMembership] = []
  public private(set) var assignments: [ProjectAssignment] = []
  public private(set) var crews: [UUID: Crew] = [:]
  public private(set) var subcontractor: Subcontractor?
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let access: AccessControl
  private let repository: WorkforceRepository

  public init(person: Personnel, access: AccessControl, repository: WorkforceRepository) {
    self.person = person
    self.access = access
    self.repository = repository
  }

  public var canEdit: Bool { access.can(.personelWrite) }
  public var canSeeContact: Bool { access.canAnywhere(.personelIletisimRead) }
  public var canSeeAssignments: Bool { access.canAnywhere(.gorevlendirmeRead) }

  public func crewName(_ id: UUID) -> String { crews[id]?.name ?? "Ekip" }

  /// Bugün devam eden üyelik (en fazla bir tane olabilir).
  public var currentMembership: CrewMembership? {
    memberships.first { $0.period.contains(.today()) }
  }

  public var currentAssignments: [ProjectAssignment] { assignments.filter { $0.period.isOngoing() } }
  public var pastAssignments: [ProjectAssignment] { assignments.filter { !$0.period.isOngoing() } }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      if let updated = try await repository.personnel().first(where: { $0.id == person.id }) { person = updated }
      async let memberships = repository.memberships(crewId: nil, personnelId: person.id)
      async let crewList = repository.crews()
      async let subs = repository.subcontractors()
      self.memberships = try await memberships.sorted { $0.startDate > $1.startDate }
      crews = Dictionary(uniqueKeysWithValues: try await crewList.map { ($0.id, $0) })
      subcontractor = try await subs.first { $0.id == person.subcontractorId }
      if canSeeAssignments {
        assignments = try await repository.assignments(projectId: nil, personnelId: person.id, crewId: nil)
          .sorted { $0.startDate > $1.startDate }
      }
      phone = canSeeContact ? try await repository.contact(personnelId: person.id)?.phone : nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func didSave(_ person: Personnel) { self.person = person }
}

// MARK: - Ekip listesi

@MainActor
@Observable
public final class CrewListViewModel {
  public private(set) var crews: [Crew] = []
  public private(set) var subcontractors: [UUID: Subcontractor] = [:]
  public private(set) var memberCounts: [UUID: Int] = [:]
  public var searchText = ""
  public var showInactive = false
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let access: AccessControl
  private let repository: WorkforceRepository

  public init(access: AccessControl, repository: WorkforceRepository) {
    self.access = access
    self.repository = repository
  }

  public var canCreate: Bool { access.can(.personelWrite) }

  /// "Şirket" ya da taşeronun adı.
  public func ownerName(_ crew: Crew) -> String {
    crew.subcontractorId.map { subcontractors[$0]?.name ?? "Taşeron" } ?? "Şirket ekibi"
  }

  public var filtered: [Crew] {
    crews.filter { (showInactive || $0.isActive) && matches(searchText, $0.name, $0.trade?.title, ownerName($0)) }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      async let crews = repository.crews()
      async let subs = repository.subcontractors()
      async let memberships = repository.memberships(crewId: nil, personnelId: nil)
      self.crews = try await crews
      subcontractors = Dictionary(uniqueKeysWithValues: try await subs.map { ($0.id, $0) })
      let today = CalendarDate.today()
      memberCounts = Dictionary(grouping: try await memberships.filter { $0.period.contains(today) }, by: \.crewId)
        .mapValues(\.count)
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func upsert(_ crew: Crew) {
    if let index = crews.firstIndex(where: { $0.id == crew.id }) {
      crews[index] = crew
    } else {
      crews.append(crew)
      crews.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
  }
}

// MARK: - Ekip detayı

/// Ekip: güncel üyeler, üyelik geçmişi ve görevli olduğu projeler. Üyelik
/// silinmez; ayrılışta bitiş tarihi yazılır.
@MainActor
@Observable
public final class CrewDetailViewModel {
  public private(set) var crew: Crew
  public private(set) var memberships: [CrewMembership] = []
  public private(set) var assignments: [ProjectAssignment] = []
  public private(set) var people: [UUID: Personnel] = [:]
  public private(set) var subcontractor: Subcontractor?
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let access: AccessControl
  private let repository: WorkforceRepository

  public init(crew: Crew, access: AccessControl, repository: WorkforceRepository) {
    self.crew = crew
    self.access = access
    self.repository = repository
  }

  public var canManage: Bool { access.can(.personelWrite) }
  public var canSeeAssignments: Bool { access.canAnywhere(.gorevlendirmeRead) }

  public func name(_ personId: UUID) -> String { people[personId]?.fullName ?? "Personel" }
  public var leaderName: String? { crew.leaderId.map(name) }

  public var currentMembers: [CrewMembership] {
    memberships.filter { $0.period.isOngoing() }.sorted { name($0.personnelId) < name($1.personnelId) }
  }
  public var pastMembers: [CrewMembership] { memberships.filter { !$0.period.isOngoing() } }

  /// Ekibe eklenebilecek kişiler: ekibin sahibine bağlı, etkin, şu an ekipte olmayan.
  public var eligiblePeople: [Personnel] {
    let current = Set(currentMembers.map(\.personnelId))
    return people.values.filter { WorkforceRules.canJoin($0, crew) && $0.isActive && !current.contains($0.id) }
      .sorted { $0.fullName < $1.fullName }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      if let updated = try await repository.crews().first(where: { $0.id == crew.id }) { crew = updated }
      async let memberships = repository.memberships(crewId: crew.id, personnelId: nil)
      async let people = repository.personnel()
      async let subs = repository.subcontractors()
      self.memberships = try await memberships.sorted { $0.startDate > $1.startDate }
      self.people = Dictionary(uniqueKeysWithValues: try await people.map { ($0.id, $0) })
      subcontractor = try await subs.first { $0.id == crew.subcontractorId }
      if canSeeAssignments {
        assignments = try await repository.assignments(projectId: nil, personnelId: nil, crewId: crew.id)
          .sorted { $0.startDate > $1.startDate }
      }
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func didSave(_ crew: Crew) { self.crew = crew }

  /// Kişiyi ekibe ekler. Kişinin diğer ekiplerdeki üyelikleri de denetlenir.
  public func addMember(_ personId: UUID, start: CalendarDate, roleTitle: String) async -> Bool {
    guard let person = people[personId] else { return false }
    let membership = CrewMembership(crewId: crew.id, personnelId: personId, startDate: start,
                                    roleTitle: roleTitle.nilIfBlank)
    do {
      let existing = try await repository.memberships(crewId: nil, personnelId: personId)
      if let problem = WorkforceRules.membershipProblem(person: person, crew: crew, period: membership.period,
                                                        existing: existing, crewName: { _ in nil }) {
        errorMessage = problem
        return false
      }
      memberships.insert(try await repository.addMembership(membership), at: 0)
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  public func end(_ membership: CrewMembership, on day: CalendarDate = .today()) async {
    guard day >= membership.startDate else {
      errorMessage = "Bitiş tarihi başlangıç tarihinden önce olamaz."
      return
    }
    do {
      try await repository.endMembership(id: membership.id, on: day)
      if let index = memberships.firstIndex(where: { $0.id == membership.id }) { memberships[index].endDate = day }
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - Proje görevlendirmeleri

/// Bir projenin personel ve ekip görevlendirmeleri ile bugün sahadaki kişiler.
@MainActor
@Observable
public final class ProjectWorkforceViewModel {
  public private(set) var assignments: [ProjectAssignment] = []
  public private(set) var today: [WorkforceEntry] = []
  public private(set) var subcontractorLinks: [SubcontractorProject] = []
  public private(set) var people: [UUID: Personnel] = [:]
  public private(set) var crews: [UUID: Crew] = [:]
  public private(set) var subcontractors: [UUID: Subcontractor] = [:]
  public private(set) var candidates: [AssignmentCandidate] = []
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  public let project: Project
  private let access: AccessControl
  private let repository: WorkforceRepository

  public init(project: Project, access: AccessControl, repository: WorkforceRepository) {
    self.project = project
    self.access = access
    self.repository = repository
  }

  public var canSee: Bool { access.can(.gorevlendirmeRead, in: project.id) }
  public var canAssign: Bool { access.can(.gorevlendirmeWrite, in: project.id) }

  public var current: [ProjectAssignment] { assignments.filter { $0.period.isOngoing() } }
  public var past: [ProjectAssignment] { assignments.filter { !$0.period.isOngoing() } }

  public func title(_ assignment: ProjectAssignment) -> String {
    switch assignment.target {
    case .personnel(let id): people[id]?.fullName ?? candidates.first { $0.id == id }?.name ?? "Personel"
    case .crew(let id): crews[id]?.name ?? candidates.first { $0.id == id }?.name ?? "Ekip"
    }
  }

  public func isCrew(_ assignment: ProjectAssignment) -> Bool { assignment.crewId != nil }

  public func load() async {
    guard canSee else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      async let assignments = repository.assignments(projectId: project.id, personnelId: nil, crewId: nil)
      async let today = repository.workforce(projectId: project.id, on: .today())
      async let links = repository.subcontractorProjects(subcontractorId: nil, projectId: project.id)
      async let people = repository.personnel()
      async let crews = repository.crews()
      async let subs = repository.subcontractors()
      self.assignments = try await assignments.sorted { $0.startDate > $1.startDate }
      self.today = try await today
      subcontractorLinks = try await links.filter { $0.period.isOngoing() }
      self.people = Dictionary(uniqueKeysWithValues: try await people.map { ($0.id, $0) })
      self.crews = Dictionary(uniqueKeysWithValues: try await crews.map { ($0.id, $0) })
      subcontractors = Dictionary(uniqueKeysWithValues: try await subs.map { ($0.id, $0) })
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Seçim listesi; zaten görevli olanlar en sona değil, listeden çıkarılır.
  public func loadCandidates() async {
    guard canAssign else { return }
    do {
      let ongoing = Set(current.map(\.target))
      candidates = try await repository.candidates(projectId: project.id).filter { !ongoing.contains($0.target) }
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func assign(_ candidate: AssignmentCandidate, start: CalendarDate, end: CalendarDate? = nil,
                     description: String = "") async -> Bool {
    let assignment = ProjectAssignment(projectId: project.id, target: candidate.target, startDate: start, endDate: end,
                                       description: description.nilIfBlank)
    if let problem = WorkforceRules.assignmentProblem(projectId: project.id, target: assignment.target,
                                                      period: assignment.period, existing: assignments) {
      errorMessage = problem
      return false
    }
    do {
      _ = try await repository.assign(assignment)
      await load()
      candidates.removeAll { $0.id == candidate.id }
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  public func end(_ assignment: ProjectAssignment, on day: CalendarDate = .today()) async {
    guard day >= assignment.startDate else {
      errorMessage = "Bitiş tarihi başlangıç tarihinden önce olamaz."
      return
    }
    do {
      try await repository.endAssignment(id: assignment.id, on: day)
      await load()
    } catch {
      errorMessage = message(for: error)
    }
  }
}
