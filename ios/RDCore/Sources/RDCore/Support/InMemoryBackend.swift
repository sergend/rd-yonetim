import Foundation

/// Bellekte çalışan repository uygulaması: SwiftUI önizlemeleri ve birim
/// testleri için. Sunucu kurallarının (çift kayıt, ters kayıt, yetki) temel
/// davranışını taklit eder; asıl kurallar veritabanındadır ve pgTAP ile test edilir.
public actor InMemoryBackend {
  public var session: AuthSession?
  public var password = "yerel-test-1234"
  public var profile: UserProfile
  public var grants: [PermissionGrant]
  public var projects: [Project] = []
  public var costCenters: [CostCenter] = []
  public var accounts: [CariAccount] = []
  public var entries: [StoredEntry] = []
  public var tasks: [TaskItem] = []
  // Aşama 2 (bkz. InMemoryWorkforce.swift)
  public var subcontractorList: [Subcontractor] = []
  public var subcontractorDocuments: [SubcontractorDocument] = []
  public var subcontractorProjectLinks: [SubcontractorProject] = []
  public var personnelList: [Personnel] = []
  public var contacts: [UUID: String] = [:]
  public var crewList: [Crew] = []
  public var membershipList: [CrewMembership] = []
  public var assignmentList: [ProjectAssignment] = []
  // Aşama 3 (bkz. InMemoryPuantaj.swift)
  public var puantajEntries: [PuantajEntry] = []
  public var puantajPeriods: [PuantajPeriod] = []
  public var puantajEvents: [UUID: [PuantajPeriodEvent]] = [:]
  // Aşama 4 (bkz. InMemoryHakedis.swift)
  public var contractList: [Contract] = []
  public var contractVersions: [ContractVersion] = []
  public var contractItems: [ContractItem] = []
  public var contractTaxCodes: [UUID: [String]] = [:]
  public var taxRuleList: [TaxRule] = []
  public var paymentSourceList: [PaymentSource] = []
  public var workQuantityList: [WorkQuantity] = []
  public var hakedisRecords: [Hakedis] = []
  public var hakedisLineList: [HakedisLine] = []
  public var hakedisAdjustmentList: [HakedisAdjustment] = []
  /// İmalat kaydı → onu kullanan hakediş (aynı imalat iki kez kullanılamaz).
  public var quantityLinks: [UUID: UUID] = [:]
  public var teminatReleaseList: [TeminatRelease] = []
  public var financePaymentList: [FinancePayment] = []
  public var financeEventList: [FinanceEvent] = []
  /// Deftere işlenen hakedişin oluşturduğu cari hareketler (hakediş ve kesintiler).
  public var postedEntryIds: [UUID: [UUID]] = [:]
  /// Finans hareketinin kuru (ödeme, teminat iadesi, hakediş); TRY'de 1.
  public var exchangeRates: [UUID: Decimal] = [:]
  // Aşama 5 (bkz. InMemoryFinance.swift)
  public var financeCategoryList: [FinanceCategory] = []
  public var financeDocumentList: [FinanceDocument] = []
  public var financeSettlementList: [FinanceSettlement] = []
  public var financeDocumentEvents: [FinanceDocumentEvent] = []
  public var financeDocumentSequence = 0
  public var today = CalendarDate.today()
  public internal(set) var saveCallCount = 0
  /// Sonraki çağrıda fırlatılacak hata (test için).
  public var nextError: RepositoryError?
  public private(set) var postCallCount = 0

  public struct StoredEntry: Sendable {
    public var draft: CariEntryDraft
    public var reversalOf: UUID?
    public var sequence: Int
  }

  public init(profile: UserProfile = UserProfile(id: UUID(), email: "deneme@example.test", fullName: "Deneme Kullanıcı"),
              grants: [PermissionGrant] = PermissionKey.allCases.map { PermissionGrant(projectId: nil, permissionKey: $0.rawValue) }) {
    self.profile = profile
    self.grants = grants
  }

  public func set(nextError: RepositoryError?) { self.nextError = nextError }
  public func set(grants: [PermissionGrant]) { self.grants = grants }
  public func set(session: AuthSession?) { self.session = session }
  public func set(profile: UserProfile) { self.profile = profile }
  public func set(profileActive: Bool) {
    profile = UserProfile(id: profile.id, email: profile.email, fullName: profile.fullName, isActive: profileActive)
  }

  public func seed(projects: [Project] = [], costCenters: [CostCenter] = [], accounts: [CariAccount] = [],
                   tasks: [TaskItem] = []) {
    self.projects += projects
    self.costCenters += costCenters
    self.accounts += accounts
    self.tasks += tasks
  }

  func failIfNeeded() throws {
    if let error = nextError {
      nextError = nil
      throw error
    }
  }

  // MARK: Oturum
  func signIn(email: String, password: String) throws -> AuthSession {
    try failIfNeeded()
    guard email == profile.email, password == self.password else { throw RepositoryError.invalidCredentials }
    let session = AuthSession(userId: profile.id, email: email)
    self.session = session
    return session
  }

  func signOut() { session = nil }

  func myProfile() throws -> UserProfile {
    try failIfNeeded()
    guard session != nil else { throw RepositoryError.notAuthenticated }
    return profile
  }

  func myPermissions() throws -> [PermissionGrant] {
    try failIfNeeded()
    return grants
  }

  var access: AccessControl { AccessControl(grants: grants) }

  // MARK: Projeler
  func listProjects(includeCompleted: Bool) throws -> [Project] {
    try failIfNeeded()
    return projects.filter { (includeCompleted || $0.status != .tamamlandi) && access.can(.projeRead, in: $0.id) }
      .sorted { $0.name < $1.name }
  }

  func project(id: UUID) throws -> Project {
    try failIfNeeded()
    guard let project = projects.first(where: { $0.id == id }) else { throw RepositoryError.notFound }
    return project
  }

  func createProject(_ draft: ProjectDraft) throws -> Project {
    try failIfNeeded()
    guard access.can(.projeCreate) else { throw RepositoryError.forbidden(nil) }
    guard !projects.contains(where: { $0.code.uppercased() == draft.code.uppercased() }) else {
      throw RepositoryError.conflict("Bu proje kodu zaten kullanılıyor.")
    }
    let project = Project(code: draft.code, name: draft.name, address: draft.address, city: draft.city,
                          startDate: draft.startDate, endDate: draft.endDate, status: draft.status, notes: draft.notes)
    projects.append(project)
    return project
  }

  func updateProject(id: UUID, expectedVersion: Int, draft: ProjectDraft) throws -> Project {
    try failIfNeeded()
    guard let index = projects.firstIndex(where: { $0.id == id }), access.can(.projeWrite, in: id),
          projects[index].version == expectedVersion else {
      throw RepositoryError.conflict("Proje siz düzenlerken değiştirildi ya da düzenleme yetkiniz yok.")
    }
    var project = projects[index]
    project.code = draft.code
    project.name = draft.name
    project.address = draft.address
    project.city = draft.city
    project.startDate = draft.startDate
    project.endDate = draft.endDate
    project.status = draft.status
    project.notes = draft.notes
    project.version += 1
    projects[index] = project
    return project
  }

  // MARK: Cari
  func listAccounts(type: CariType?) throws -> [CariAccount] {
    try failIfNeeded()
    guard access.canAnywhere(.cariRead) else { return [] }
    return accounts.filter { type == nil || $0.type == type }.sorted { $0.title < $1.title }
  }

  func account(id: UUID) throws -> CariAccount {
    try failIfNeeded()
    guard access.canAnywhere(.cariRead), let account = accounts.first(where: { $0.id == id }) else {
      throw RepositoryError.notFound
    }
    return account
  }

  func createAccount(_ draft: CariAccountDraft) throws -> CariAccount {
    try failIfNeeded()
    guard access.can(.cariWrite) else { throw RepositoryError.forbidden(nil) }
    let code = draft.code ?? String(format: "C-%05d", accounts.count + 1)
    let account = CariAccount(code: code, title: draft.title, type: draft.type, taxNumber: draft.taxNumber,
                              taxOffice: draft.taxOffice, phone: draft.phone, email: draft.email,
                              address: draft.address, iban: draft.iban, notes: draft.notes, isActive: draft.isActive)
    accounts.append(account)
    return account
  }

  func updateAccount(id: UUID, expectedVersion: Int, draft: CariAccountDraft) throws -> CariAccount {
    try failIfNeeded()
    guard let index = accounts.firstIndex(where: { $0.id == id }), access.can(.cariWrite),
          accounts[index].version == expectedVersion else {
      throw RepositoryError.conflict("Cari kart siz düzenlerken değiştirildi ya da düzenleme yetkiniz yok.")
    }
    var account = accounts[index]
    account.code = draft.code ?? account.code
    account.title = draft.title
    account.type = draft.type
    account.taxNumber = draft.taxNumber
    account.taxOffice = draft.taxOffice
    account.phone = draft.phone
    account.email = draft.email
    account.address = draft.address
    account.iban = draft.iban
    account.notes = draft.notes
    account.isActive = draft.isActive
    account.version += 1
    accounts[index] = account
    return account
  }

  private func canRead(_ entry: StoredEntry) -> Bool {
    switch entry.draft.scope {
    case .project(let id): access.can(.cariHareketRead, in: id)
    case .costCenter: access.can(.cariHareketRead)
    }
  }

  private func visibleEntries(_ filter: CariFilter, includeFrom: Bool) -> [StoredEntry] {
    entries.filter { stored in
      guard canRead(stored) else { return false }
      let entry = stored.draft
      if let project = filter.projectId, entry.scope != .project(project) { return false }
      if let center = filter.costCenterId, entry.scope != .costCenter(center) { return false }
      if let to = filter.to, entry.entryDate > to { return false }
      if includeFrom, let from = filter.from, entry.entryDate < from { return false }
      return true
    }
    .sorted { ($0.draft.entryDate, $0.sequence) < ($1.draft.entryDate, $1.sequence) }
  }

  func balances(filter: CariFilter) throws -> [CariBalance] {
    try failIfNeeded()
    let grouped = Dictionary(grouping: visibleEntries(filter, includeFrom: false)) { $0.draft.cariAccountId }
    return grouped.map { id, rows in
      CariBalance(cariAccountId: id,
                  totalBorcTry: rows.filter { $0.draft.direction == .borc }.reduce(0) { $0 + $1.draft.amount },
                  totalAlacakTry: rows.filter { $0.draft.direction == .alacak }.reduce(0) { $0 + $1.draft.amount },
                  entryCount: rows.count, lastEntryDate: rows.map(\.draft.entryDate).max())
    }
  }

  func statement(accountId: UUID, filter: CariFilter) throws -> [CariStatementLine] {
    try failIfNeeded()
    var running: Decimal = 0
    var lines: [CariStatementLine] = []
    for stored in visibleEntries(filter, includeFrom: false) where stored.draft.cariAccountId == accountId {
      let entry = stored.draft
      running += entry.direction == .borc ? entry.amount : -entry.amount
      if let from = filter.from, entry.entryDate < from { continue }
      var project: UUID?
      var center: UUID?
      switch entry.scope {
      case .project(let id): project = id
      case .costCenter(let id): center = id
      }
      lines.append(CariStatementLine(
        id: entry.id, entryDate: entry.entryDate, kind: entry.kind, direction: entry.direction,
        description: entry.description, documentNo: entry.documentNo, projectId: project, costCenterId: center,
        amount: entry.amount, borcTry: entry.direction == .borc ? entry.amount : 0,
        alacakTry: entry.direction == .alacak ? entry.amount : 0, runningBalanceTry: running,
        reversalOfId: stored.reversalOf, isReversed: entries.contains { $0.reversalOf == entry.id }))
    }
    return lines
  }

  func post(_ draft: CariEntryDraft) throws {
    postCallCount += 1
    try failIfNeeded()
    let allowed: Bool = switch draft.scope {
    case .project(let id): access.can(.cariHareketWrite, in: id)
    case .costCenter: access.can(.cariHareketWrite)
    }
    guard allowed else { throw RepositoryError.forbidden("Cari hareket girme yetkiniz yok") }
    if let existing = entries.first(where: { $0.draft.id == draft.id }) {
      guard existing.draft == draft else { throw RepositoryError.conflict("Bu kimlikle farklı bir cari hareket zaten var") }
      return  // aynı isteğin tekrarı
    }
    entries.append(StoredEntry(draft: draft, reversalOf: nil, sequence: entries.count))
  }

  func reverse(entryId: UUID, reason: String, reversalId: UUID) throws {
    try failIfNeeded()
    if entries.contains(where: { $0.draft.id == reversalId && $0.reversalOf == entryId }) { return }
    guard let original = entries.first(where: { $0.draft.id == entryId }) else { throw RepositoryError.notFound }
    guard original.reversalOf == nil else { throw RepositoryError.validation("Ters kayıt yeniden iptal edilemez") }
    guard !entries.contains(where: { $0.reversalOf == entryId }) else {
      throw RepositoryError.validation("Bu hareket zaten iptal edilmiş")
    }
    var reversal = original.draft
    reversal.id = reversalId
    reversal.kind = .tersKayit
    reversal.direction = original.draft.direction == .borc ? .alacak : .borc
    reversal.entryDate = .today()
    reversal.description = "İptal: \(reason)"
    entries.append(StoredEntry(draft: reversal, reversalOf: entryId, sequence: entries.count))
  }

  // MARK: İş takibi
  func listTasks(projectId: UUID?, openOnly: Bool) throws -> [TaskItem] {
    try failIfNeeded()
    return tasks.filter { task in
      (projectId == nil || task.projectId == projectId) && (!openOnly || task.status.isOpen)
        && (task.assigneeId == profile.id || task.projectId.map { access.can(.isRead, in: $0) } ?? access.can(.isRead))
    }
  }

  func createTask(_ task: TaskItem) throws -> TaskItem {
    try failIfNeeded()
    let allowed = task.projectId.map { access.can(.isWrite, in: $0) } ?? access.can(.isWrite)
    guard allowed else { throw RepositoryError.forbidden(nil) }
    tasks.append(task)
    return task
  }

  func setTaskStatus(id: UUID, status: TaskStatus) throws {
    try failIfNeeded()
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    tasks[index].status = status
  }

  // MARK: Repository'ler
  public nonisolated var repositories: Repositories {
    Repositories(auth: InMemoryAuth(backend: self), access: InMemoryAccess(backend: self),
                 projects: InMemoryProjects(backend: self), costCenters: InMemoryCostCenters(backend: self),
                 cari: InMemoryCari(backend: self), tasks: InMemoryTasks(backend: self),
                 workforce: InMemoryWorkforce(backend: self), puantaj: InMemoryPuantaj(backend: self),
                 contracts: InMemoryContracts(backend: self), finance: InMemoryFinance(backend: self))
  }
}

struct InMemoryAuth: AuthRepository {
  let backend: InMemoryBackend
  func restoreSession() async -> AuthSession? { await backend.session }
  func signIn(email: String, password: String) async throws -> AuthSession {
    try await backend.signIn(email: email, password: password)
  }
  func signOut() async throws { await backend.signOut() }
  func sendPasswordReset(email: String) async throws { try await backend.failIfNeeded() }
}

struct InMemoryAccess: AccessRepository {
  let backend: InMemoryBackend
  func myPermissions() async throws -> [PermissionGrant] { try await backend.myPermissions() }
  func myProfile() async throws -> UserProfile { try await backend.myProfile() }
}

struct InMemoryProjects: ProjectRepository {
  let backend: InMemoryBackend
  func list(includeCompleted: Bool) async throws -> [Project] { try await backend.listProjects(includeCompleted: includeCompleted) }
  func get(id: UUID) async throws -> Project { try await backend.project(id: id) }
  func create(_ draft: ProjectDraft) async throws -> Project { try await backend.createProject(draft) }
  func update(id: UUID, expectedVersion: Int, with draft: ProjectDraft) async throws -> Project {
    try await backend.updateProject(id: id, expectedVersion: expectedVersion, draft: draft)
  }
}

struct InMemoryCostCenters: CostCenterRepository {
  let backend: InMemoryBackend
  func list() async throws -> [CostCenter] { await backend.costCenters }
}

struct InMemoryCari: CariRepository {
  let backend: InMemoryBackend
  func listAccounts(type: CariType?, search: String?) async throws -> [CariAccount] {
    try await backend.listAccounts(type: type)
  }
  func getAccount(id: UUID) async throws -> CariAccount { try await backend.account(id: id) }
  func createAccount(_ draft: CariAccountDraft) async throws -> CariAccount { try await backend.createAccount(draft) }
  func updateAccount(id: UUID, expectedVersion: Int, with draft: CariAccountDraft) async throws -> CariAccount {
    try await backend.updateAccount(id: id, expectedVersion: expectedVersion, draft: draft)
  }
  func balances(filter: CariFilter) async throws -> [CariBalance] { try await backend.balances(filter: filter) }
  func statement(accountId: UUID, filter: CariFilter) async throws -> [CariStatementLine] {
    try await backend.statement(accountId: accountId, filter: filter)
  }
  func post(_ entry: CariEntryDraft) async throws { try await backend.post(entry) }
  func reverse(entryId: UUID, reason: String, reversalId: UUID) async throws {
    try await backend.reverse(entryId: entryId, reason: reason, reversalId: reversalId)
  }
}

struct InMemoryTasks: TaskRepository {
  let backend: InMemoryBackend
  func list(projectId: UUID?, openOnly: Bool) async throws -> [TaskItem] {
    try await backend.listTasks(projectId: projectId, openOnly: openOnly)
  }
  func create(_ task: TaskItem) async throws -> TaskItem { try await backend.createTask(task) }
  func setStatus(id: UUID, status: TaskStatus) async throws { try await backend.setTaskStatus(id: id, status: status) }
}
