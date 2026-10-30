import Foundation

/// Repository hataları; arayüz bu mesajları doğrudan gösterir.
public enum RepositoryError: Error, Equatable, LocalizedError, Sendable {
  case notAuthenticated
  case invalidCredentials
  case forbidden(String?)
  case conflict(String?)
  case validation(String)
  case notFound
  case network
  case server(String)

  public var errorDescription: String? {
    switch self {
    case .notAuthenticated: "Oturum sona erdi. Lütfen yeniden giriş yapın."
    case .invalidCredentials: "E-posta veya şifre hatalı."
    case .forbidden(let message): message ?? "Bu işlem için yetkiniz yok."
    case .conflict(let message): message ?? "Kayıt başka biri tarafından değiştirilmiş veya zaten var."
    case .validation(let message): message
    case .notFound: "Kayıt bulunamadı."
    case .network: "Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin."
    case .server(let message): message
    }
  }
}

public struct AuthSession: Equatable, Sendable {
  public let userId: UUID
  public let email: String?

  public init(userId: UUID, email: String?) {
    self.userId = userId
    self.email = email
  }
}

public protocol AuthRepository: Sendable {
  /// Cihazda saklı geçerli oturum (yoksa nil). Gerekirse yeniler.
  func restoreSession() async -> AuthSession?
  func signIn(email: String, password: String) async throws -> AuthSession
  func signOut() async throws
  func sendPasswordReset(email: String) async throws
}

public protocol AccessRepository: Sendable {
  func myPermissions() async throws -> [PermissionGrant]
  func myProfile() async throws -> UserProfile
}

public protocol ProjectRepository: Sendable {
  func list(includeCompleted: Bool) async throws -> [Project]
  func get(id: UUID) async throws -> Project
  func create(_ draft: ProjectDraft) async throws -> Project
  /// İyimser kilit: `expectedVersion` sunucudakiyle aynı değilse `.conflict`.
  func update(id: UUID, expectedVersion: Int, with draft: ProjectDraft) async throws -> Project
}

public protocol CostCenterRepository: Sendable {
  func list() async throws -> [CostCenter]
}

public protocol CariRepository: Sendable {
  func listAccounts(type: CariType?, search: String?) async throws -> [CariAccount]
  func getAccount(id: UUID) async throws -> CariAccount
  func createAccount(_ draft: CariAccountDraft) async throws -> CariAccount
  func updateAccount(id: UUID, expectedVersion: Int, with draft: CariAccountDraft) async throws -> CariAccount
  /// Kullanıcının görebildiği hareketlerden hesaplanan bakiyeler.
  func balances(filter: CariFilter) async throws -> [CariBalance]
  func statement(accountId: UUID, filter: CariFilter) async throws -> [CariStatementLine]
  func post(_ entry: CariEntryDraft) async throws
  func reverse(entryId: UUID, reason: String, reversalId: UUID) async throws
}

public protocol TaskRepository: Sendable {
  /// projectId nil ise görülebilen tüm işler.
  func list(projectId: UUID?, openOnly: Bool) async throws -> [TaskItem]
  func create(_ task: TaskItem) async throws -> TaskItem
  func setStatus(id: UUID, status: TaskStatus) async throws
}

/// Taşeron, personel, ekip ve proje görevlendirmeleri. Kartlar şirket geneli
/// kayıtlardır; görevlendirmeler projeye aittir. Üyelik ve görevlendirmeler
/// silinmez, `end...` çağrılarıyla bitiş tarihi yazılır.
public protocol WorkforceRepository: Sendable {
  // Taşeron
  func subcontractors() async throws -> [Subcontractor]
  func createSubcontractor(_ draft: SubcontractorDraft) async throws -> Subcontractor
  func updateSubcontractor(id: UUID, expectedVersion: Int, with draft: SubcontractorDraft) async throws -> Subcontractor
  func documents(subcontractorId: UUID) async throws -> [SubcontractorDocument]
  func addDocument(_ document: SubcontractorDocument) async throws -> SubcontractorDocument
  func subcontractorProjects(subcontractorId: UUID?, projectId: UUID?) async throws -> [SubcontractorProject]
  func addSubcontractorProject(_ link: SubcontractorProject) async throws -> SubcontractorProject
  func endSubcontractorProject(id: UUID, on endDate: CalendarDate) async throws

  // Personel
  func personnel() async throws -> [Personnel]
  func createPersonnel(_ draft: PersonnelDraft) async throws -> Personnel
  func updatePersonnel(id: UUID, expectedVersion: Int, with draft: PersonnelDraft) async throws -> Personnel
  /// Yetki yoksa veya kayıt yoksa nil (iletişim bilgisi ayrı izinlidir).
  func contact(personnelId: UUID) async throws -> PersonnelContact?
  func setPhone(_ phone: String?, personnelId: UUID) async throws

  // Ekip
  func crews() async throws -> [Crew]
  func createCrew(_ draft: CrewDraft) async throws -> Crew
  func updateCrew(id: UUID, expectedVersion: Int, with draft: CrewDraft) async throws -> Crew
  func memberships(crewId: UUID?, personnelId: UUID?) async throws -> [CrewMembership]
  func addMembership(_ membership: CrewMembership) async throws -> CrewMembership
  func endMembership(id: UUID, on endDate: CalendarDate) async throws

  // Görevlendirme
  func assignments(projectId: UUID?, personnelId: UUID?, crewId: UUID?) async throws -> [ProjectAssignment]
  func assign(_ assignment: ProjectAssignment) async throws -> ProjectAssignment
  func endAssignment(id: UUID, on endDate: CalendarDate) async throws
  /// Projeye görevlendirilebilecek etkin personel ve ekipler (yalnızca ad ve görev).
  func candidates(projectId: UUID) async throws -> [AssignmentCandidate]
  /// Belirtilen günde projede çalışanlar (doğrudan ya da ekip üzerinden).
  func workforce(projectId: UUID, on day: CalendarDate) async throws -> [WorkforceEntry]
}

/// Uygulamanın kullandığı tüm repository'ler (bağımlılık enjeksiyonu için).
public struct Repositories: Sendable {
  public let auth: AuthRepository
  public let access: AccessRepository
  public let projects: ProjectRepository
  public let costCenters: CostCenterRepository
  public let cari: CariRepository
  public let tasks: TaskRepository
  public let workforce: WorkforceRepository

  public init(auth: AuthRepository, access: AccessRepository, projects: ProjectRepository,
              costCenters: CostCenterRepository, cari: CariRepository, tasks: TaskRepository,
              workforce: WorkforceRepository) {
    self.auth = auth
    self.access = access
    self.projects = projects
    self.costCenters = costCenters
    self.cari = cari
    self.tasks = tasks
    self.workforce = workforce
  }
}
