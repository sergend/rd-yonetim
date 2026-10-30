import Foundation

/// Taşeron, personel, ekip ve görevlendirmelerin bellek içi uygulaması.
/// Veritabanı kurallarını ve proje bazlı görünürlüğü basitçe taklit eder.
extension InMemoryBackend {
  public func seedWorkforce(subcontractors: [Subcontractor] = [], personnel: [Personnel] = [],
                            contacts: [UUID: String] = [:], crews: [Crew] = [],
                            memberships: [CrewMembership] = [], assignments: [ProjectAssignment] = [],
                            subcontractorProjects: [SubcontractorProject] = [],
                            documents: [SubcontractorDocument] = []) {
    subcontractorList += subcontractors
    personnelList += personnel
    self.contacts.merge(contacts) { _, new in new }
    crewList += crews
    membershipList += memberships
    assignmentList += assignments
    subcontractorProjectLinks += subcontractorProjects
    subcontractorDocuments += documents
  }

  // MARK: Görünürlük

  /// Kişinin görünür olduğu projeler (doğrudan ya da ekip üyeliği dönemiyle).
  private func projects(ofPersonnel id: UUID) -> Set<UUID> {
    var result = Set(assignmentList.filter { $0.personnelId == id }.map(\.projectId))
    for membership in membershipList where membership.personnelId == id {
      for assignment in assignmentList where assignment.crewId == membership.crewId
        && assignment.period.overlaps(membership.period) {
        result.insert(assignment.projectId)
      }
    }
    return result
  }

  private func canRead(personnel id: UUID, _ key: PermissionKey = .personelRead) -> Bool {
    access.can(key) || projects(ofPersonnel: id).contains { access.can(key, in: $0) }
  }

  private func canRead(crew id: UUID) -> Bool {
    access.can(.personelRead)
      || assignmentList.contains { $0.crewId == id && access.can(.personelRead, in: $0.projectId) }
  }

  private func canRead(membership: CrewMembership) -> Bool {
    access.can(.personelRead) || assignmentList.contains {
      $0.crewId == membership.crewId && $0.period.overlaps(membership.period)
        && access.can(.personelRead, in: $0.projectId)
    }
  }

  private func canRead(subcontractor id: UUID) -> Bool {
    if access.can(.taseronRead) { return true }
    var projects = Set(subcontractorProjectLinks.filter { $0.subcontractorId == id }.map(\.projectId))
    for assignment in assignmentList {
      let owner: UUID? = if let person = assignment.personnelId {
        personnelList.first { $0.id == person }?.subcontractorId
      } else {
        crewList.first { $0.id == assignment.crewId }?.subcontractorId
      }
      if owner == id { projects.insert(assignment.projectId) }
    }
    return projects.contains { access.can(.taseronRead, in: $0) }
  }

  private func require(_ allowed: Bool) throws {
    guard allowed else { throw RepositoryError.forbidden(nil) }
  }

  // MARK: Taşeron

  func listSubcontractors() throws -> [Subcontractor] {
    try failIfNeeded()
    return subcontractorList.filter { canRead(subcontractor: $0.id) }.sorted { $0.name < $1.name }
  }

  func saveSubcontractor(id: UUID?, expectedVersion: Int?, draft: SubcontractorDraft) throws -> Subcontractor {
    try failIfNeeded()
    try require(access.can(.taseronWrite))
    if let cari = draft.cariAccountId,
       let owner = subcontractorList.first(where: { $0.cariAccountId == cari && $0.id != id }) {
      throw RepositoryError.conflict("Bu cari hesap zaten \"\(owner.name)\" taşeronuna bağlı")
    }
    guard let id else {
      let created = Subcontractor(name: draft.name, trade: draft.trade, cariAccountId: draft.cariAccountId,
                                  contactName: draft.contactName, phone: draft.phone, email: draft.email,
                                  notes: draft.notes, isActive: draft.isActive)
      subcontractorList.append(created)
      return created
    }
    guard let index = subcontractorList.firstIndex(where: { $0.id == id }),
          subcontractorList[index].version == expectedVersion else {
      throw RepositoryError.conflict("Taşeron siz düzenlerken değiştirildi.")
    }
    var item = subcontractorList[index]
    item.name = draft.name
    item.trade = draft.trade
    item.cariAccountId = draft.cariAccountId
    item.contactName = draft.contactName
    item.phone = draft.phone
    item.email = draft.email
    item.notes = draft.notes
    item.isActive = draft.isActive
    item.version += 1
    subcontractorList[index] = item
    return item
  }

  func listDocuments(subcontractorId: UUID) throws -> [SubcontractorDocument] {
    try failIfNeeded()
    guard canRead(subcontractor: subcontractorId) else { return [] }
    return subcontractorDocuments.filter { $0.subcontractorId == subcontractorId }
  }

  func addDocument(_ document: SubcontractorDocument) throws -> SubcontractorDocument {
    try failIfNeeded()
    try require(access.can(.taseronWrite))
    subcontractorDocuments.append(document)
    return document
  }

  func listSubcontractorProjects(subcontractorId: UUID?, projectId: UUID?) throws -> [SubcontractorProject] {
    try failIfNeeded()
    return subcontractorProjectLinks.filter {
      (subcontractorId == nil || $0.subcontractorId == subcontractorId)
        && (projectId == nil || $0.projectId == projectId)
        && (access.can(.gorevlendirmeRead, in: $0.projectId) || access.can(.taseronRead, in: $0.projectId))
    }
  }

  func addSubcontractorProject(_ link: SubcontractorProject) throws -> SubcontractorProject {
    try failIfNeeded()
    try require(access.can(.gorevlendirmeWrite, in: link.projectId))
    guard link.period.isValid else { throw RepositoryError.validation("Bitiş tarihi başlangıç tarihinden önce olamaz.") }
    if subcontractorProjectLinks.contains(where: {
      $0.subcontractorId == link.subcontractorId && $0.projectId == link.projectId && $0.period.overlaps(link.period)
    }) {
      throw RepositoryError.conflict("Taşeron bu projede aynı tarihlerde zaten kayıtlı")
    }
    subcontractorProjectLinks.append(link)
    return link
  }

  func endSubcontractorProject(id: UUID, on endDate: CalendarDate) throws {
    try failIfNeeded()
    guard let index = subcontractorProjectLinks.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    try require(access.can(.gorevlendirmeWrite, in: subcontractorProjectLinks[index].projectId))
    guard endDate >= subcontractorProjectLinks[index].startDate else {
      throw RepositoryError.validation("Bitiş tarihi başlangıç tarihinden önce olamaz.")
    }
    subcontractorProjectLinks[index].endDate = endDate
  }

  // MARK: Personel

  func listPersonnel() throws -> [Personnel] {
    try failIfNeeded()
    return personnelList.filter { canRead(personnel: $0.id) }.sorted { $0.fullName < $1.fullName }
  }

  func savePersonnel(id: UUID?, expectedVersion: Int?, draft: PersonnelDraft) throws -> Personnel {
    try failIfNeeded()
    try require(access.can(.personelWrite))
    if let problem = WorkforceRules.employmentProblem(type: draft.employmentType, subcontractorId: draft.subcontractorId) {
      throw RepositoryError.validation(problem)
    }
    guard let id else {
      let created = Personnel(fullName: draft.fullName, jobTitle: draft.jobTitle, trade: draft.trade,
                              employmentType: draft.employmentType, subcontractorId: draft.subcontractorId,
                              notes: draft.notes, isActive: draft.isActive)
      personnelList.append(created)
      return created
    }
    guard let index = personnelList.firstIndex(where: { $0.id == id }),
          personnelList[index].version == expectedVersion else {
      throw RepositoryError.conflict("Personel kaydı siz düzenlerken değiştirildi.")
    }
    var person = personnelList[index]
    if person.subcontractorId != draft.subcontractorId
      && membershipList.contains(where: { $0.personnelId == id && $0.period.isOngoing() }) {
      throw RepositoryError.validation(
        "Kişinin devam eden ekip üyeliği var; çalışma ilişkisini değiştirmeden önce üyeliği bitirin")
    }
    person.fullName = draft.fullName
    person.jobTitle = draft.jobTitle
    person.trade = draft.trade
    person.employmentType = draft.employmentType
    person.subcontractorId = draft.subcontractorId
    person.notes = draft.notes
    person.isActive = draft.isActive
    person.version += 1
    personnelList[index] = person
    return person
  }

  func contact(personnelId: UUID) throws -> PersonnelContact? {
    try failIfNeeded()
    guard canRead(personnel: personnelId, .personelIletisimRead), let phone = contacts[personnelId] else { return nil }
    return PersonnelContact(personnelId: personnelId, phone: phone)
  }

  func setPhone(_ phone: String?, personnelId: UUID) throws {
    try failIfNeeded()
    try require(access.can(.personelWrite))
    contacts[personnelId] = phone
  }

  // MARK: Ekip

  func listCrews() throws -> [Crew] {
    try failIfNeeded()
    return crewList.filter { canRead(crew: $0.id) }.sorted { $0.name < $1.name }
  }

  func saveCrew(id: UUID?, expectedVersion: Int?, draft: CrewDraft) throws -> Crew {
    try failIfNeeded()
    try require(access.can(.personelWrite))
    if let leader = draft.leaderId.flatMap({ id in personnelList.first { $0.id == id } }),
       leader.subcontractorId != draft.subcontractorId {
      throw RepositoryError.validation(
        "Ekip sorumlusu ekibin bağlı olduğu taşeronun (şirket ekibinde şirketin) personeli olmalı")
    }
    guard let id else {
      let created = Crew(name: draft.name, subcontractorId: draft.subcontractorId, trade: draft.trade,
                         leaderId: draft.leaderId, notes: draft.notes, isActive: draft.isActive)
      crewList.append(created)
      return created
    }
    guard let index = crewList.firstIndex(where: { $0.id == id }), crewList[index].version == expectedVersion else {
      throw RepositoryError.conflict("Ekip siz düzenlerken değiştirildi.")
    }
    var crew = crewList[index]
    if crew.subcontractorId != draft.subcontractorId && membershipList.contains(where: { $0.crewId == id }) {
      throw RepositoryError.validation("Üyelik geçmişi olan ekibin bağlı olduğu taşeron değiştirilemez; yeni ekip açın")
    }
    crew.name = draft.name
    crew.subcontractorId = draft.subcontractorId
    crew.trade = draft.trade
    crew.leaderId = draft.leaderId
    crew.notes = draft.notes
    crew.isActive = draft.isActive
    crew.version += 1
    crewList[index] = crew
    return crew
  }

  func listMemberships(crewId: UUID?, personnelId: UUID?) throws -> [CrewMembership] {
    try failIfNeeded()
    return membershipList.filter {
      (crewId == nil || $0.crewId == crewId) && (personnelId == nil || $0.personnelId == personnelId)
        && canRead(membership: $0)
    }
    .sorted { $0.startDate > $1.startDate }
  }

  func addMembership(_ membership: CrewMembership) throws -> CrewMembership {
    try failIfNeeded()
    try require(access.can(.personelWrite))
    guard let person = personnelList.first(where: { $0.id == membership.personnelId }),
          let crew = crewList.first(where: { $0.id == membership.crewId }) else { throw RepositoryError.notFound }
    if let problem = WorkforceRules.membershipProblem(
      person: person, crew: crew, period: membership.period, existing: membershipList,
      crewName: { id in self.crewList.first { $0.id == id }?.name }) {
      throw problem.contains("aynı anda") ? RepositoryError.conflict(problem) : RepositoryError.validation(problem)
    }
    membershipList.append(membership)
    return membership
  }

  func endMembership(id: UUID, on endDate: CalendarDate) throws {
    try failIfNeeded()
    try require(access.can(.personelWrite))
    guard let index = membershipList.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    guard endDate >= membershipList[index].startDate else {
      throw RepositoryError.validation("Bitiş tarihi başlangıç tarihinden önce olamaz.")
    }
    membershipList[index].endDate = endDate
  }

  // MARK: Görevlendirme

  func listAssignments(projectId: UUID?, personnelId: UUID?, crewId: UUID?) throws -> [ProjectAssignment] {
    try failIfNeeded()
    return assignmentList.filter {
      (projectId == nil || $0.projectId == projectId) && (personnelId == nil || $0.personnelId == personnelId)
        && (crewId == nil || $0.crewId == crewId) && access.can(.gorevlendirmeRead, in: $0.projectId)
    }
    .sorted { $0.startDate > $1.startDate }
  }

  func assign(_ assignment: ProjectAssignment) throws -> ProjectAssignment {
    try failIfNeeded()
    try require(access.can(.gorevlendirmeWrite, in: assignment.projectId))
    if let problem = WorkforceRules.assignmentProblem(projectId: assignment.projectId, target: assignment.target,
                                                      period: assignment.period, existing: assignmentList) {
      throw assignment.period.isValid ? RepositoryError.conflict(problem) : RepositoryError.validation(problem)
    }
    assignmentList.append(assignment)
    return assignment
  }

  func endAssignment(id: UUID, on endDate: CalendarDate) throws {
    try failIfNeeded()
    guard let index = assignmentList.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    try require(access.can(.gorevlendirmeWrite, in: assignmentList[index].projectId))
    guard endDate >= assignmentList[index].startDate else {
      throw RepositoryError.validation("Bitiş tarihi başlangıç tarihinden önce olamaz.")
    }
    assignmentList[index].endDate = endDate
  }

  func candidates(projectId: UUID) throws -> [AssignmentCandidate] {
    try failIfNeeded()
    try require(access.can(.gorevlendirmeWrite, in: projectId))
    let isDemo = projects.first { $0.id == projectId }?.isDemo ?? false
    let subName = { (id: UUID?) in id.flatMap { id in self.subcontractorList.first { $0.id == id }?.name } }
    let people = personnelList.filter { $0.isActive && $0.isDemo == isDemo }.map {
      AssignmentCandidate(kind: .personel, id: $0.id, name: $0.fullName, detail: $0.jobTitle,
                          subcontractorName: subName($0.subcontractorId), isDemo: $0.isDemo)
    }
    let crews = crewList.filter { $0.isActive && $0.isDemo == isDemo }.map {
      AssignmentCandidate(kind: .ekip, id: $0.id, name: $0.name, subcontractorName: subName($0.subcontractorId),
                          isDemo: $0.isDemo)
    }
    return crews.sorted { $0.name < $1.name } + people.sorted { $0.name < $1.name }
  }

  func workforce(projectId: UUID, on day: CalendarDate) throws -> [WorkforceEntry] {
    try failIfNeeded()
    guard access.can(.gorevlendirmeRead, in: projectId) else { return [] }
    var entries: [UUID: WorkforceEntry] = [:]
    for assignment in assignmentList where assignment.projectId == projectId && assignment.period.contains(day) {
      if let person = assignment.personnelId, let p = personnelList.first(where: { $0.id == person }) {
        entries[person] = WorkforceEntry(personnelId: person, fullName: p.fullName, jobTitle: p.jobTitle,
                                         via: .dogrudan, assignmentId: assignment.id)
      } else if let crewId = assignment.crewId {
        let crewName = crewList.first { $0.id == crewId }?.name
        for membership in membershipList where membership.crewId == crewId && membership.period.contains(day) {
          guard entries[membership.personnelId] == nil,
                let p = personnelList.first(where: { $0.id == membership.personnelId }) else { continue }
          entries[p.id] = WorkforceEntry(personnelId: p.id, fullName: p.fullName, jobTitle: p.jobTitle, via: .ekip,
                                         crewId: crewId, crewName: crewName, assignmentId: assignment.id,
                                         membershipId: membership.id)
        }
      }
    }
    return entries.values.sorted { ($0.crewName ?? "", $0.fullName) < ($1.crewName ?? "", $1.fullName) }
  }
}

struct InMemoryWorkforce: WorkforceRepository {
  let backend: InMemoryBackend

  func subcontractors() async throws -> [Subcontractor] { try await backend.listSubcontractors() }
  func createSubcontractor(_ draft: SubcontractorDraft) async throws -> Subcontractor {
    try await backend.saveSubcontractor(id: nil, expectedVersion: nil, draft: draft)
  }
  func updateSubcontractor(id: UUID, expectedVersion: Int, with draft: SubcontractorDraft) async throws -> Subcontractor {
    try await backend.saveSubcontractor(id: id, expectedVersion: expectedVersion, draft: draft)
  }
  func documents(subcontractorId: UUID) async throws -> [SubcontractorDocument] {
    try await backend.listDocuments(subcontractorId: subcontractorId)
  }
  func addDocument(_ document: SubcontractorDocument) async throws -> SubcontractorDocument {
    try await backend.addDocument(document)
  }
  func subcontractorProjects(subcontractorId: UUID?, projectId: UUID?) async throws -> [SubcontractorProject] {
    try await backend.listSubcontractorProjects(subcontractorId: subcontractorId, projectId: projectId)
  }
  func addSubcontractorProject(_ link: SubcontractorProject) async throws -> SubcontractorProject {
    try await backend.addSubcontractorProject(link)
  }
  func endSubcontractorProject(id: UUID, on endDate: CalendarDate) async throws {
    try await backend.endSubcontractorProject(id: id, on: endDate)
  }

  func personnel() async throws -> [Personnel] { try await backend.listPersonnel() }
  func createPersonnel(_ draft: PersonnelDraft) async throws -> Personnel {
    try await backend.savePersonnel(id: nil, expectedVersion: nil, draft: draft)
  }
  func updatePersonnel(id: UUID, expectedVersion: Int, with draft: PersonnelDraft) async throws -> Personnel {
    try await backend.savePersonnel(id: id, expectedVersion: expectedVersion, draft: draft)
  }
  func contact(personnelId: UUID) async throws -> PersonnelContact? { try await backend.contact(personnelId: personnelId) }
  func setPhone(_ phone: String?, personnelId: UUID) async throws { try await backend.setPhone(phone, personnelId: personnelId) }

  func crews() async throws -> [Crew] { try await backend.listCrews() }
  func createCrew(_ draft: CrewDraft) async throws -> Crew {
    try await backend.saveCrew(id: nil, expectedVersion: nil, draft: draft)
  }
  func updateCrew(id: UUID, expectedVersion: Int, with draft: CrewDraft) async throws -> Crew {
    try await backend.saveCrew(id: id, expectedVersion: expectedVersion, draft: draft)
  }
  func memberships(crewId: UUID?, personnelId: UUID?) async throws -> [CrewMembership] {
    try await backend.listMemberships(crewId: crewId, personnelId: personnelId)
  }
  func addMembership(_ membership: CrewMembership) async throws -> CrewMembership {
    try await backend.addMembership(membership)
  }
  func endMembership(id: UUID, on endDate: CalendarDate) async throws { try await backend.endMembership(id: id, on: endDate) }

  func assignments(projectId: UUID?, personnelId: UUID?, crewId: UUID?) async throws -> [ProjectAssignment] {
    try await backend.listAssignments(projectId: projectId, personnelId: personnelId, crewId: crewId)
  }
  func assign(_ assignment: ProjectAssignment) async throws -> ProjectAssignment { try await backend.assign(assignment) }
  func endAssignment(id: UUID, on endDate: CalendarDate) async throws { try await backend.endAssignment(id: id, on: endDate) }
  func candidates(projectId: UUID) async throws -> [AssignmentCandidate] { try await backend.candidates(projectId: projectId) }
  func workforce(projectId: UUID, on day: CalendarDate) async throws -> [WorkforceEntry] {
    try await backend.workforce(projectId: projectId, on: day)
  }
}
