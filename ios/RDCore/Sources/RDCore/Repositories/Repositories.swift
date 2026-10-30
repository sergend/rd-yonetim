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

/// Uygulamanın kullandığı tüm repository'ler (bağımlılık enjeksiyonu için).
public struct Repositories: Sendable {
  public let auth: AuthRepository
  public let access: AccessRepository
  public let projects: ProjectRepository
  public let costCenters: CostCenterRepository
  public let cari: CariRepository
  public let tasks: TaskRepository

  public init(auth: AuthRepository, access: AccessRepository, projects: ProjectRepository,
              costCenters: CostCenterRepository, cari: CariRepository, tasks: TaskRepository) {
    self.auth = auth
    self.access = access
    self.projects = projects
    self.costCenters = costCenters
    self.cari = cari
    self.tasks = tasks
  }
}
