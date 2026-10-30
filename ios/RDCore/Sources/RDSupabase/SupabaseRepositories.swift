import Foundation
import RDCore
import Supabase

// MARK: - Oturum

struct SupabaseAuthRepository: AuthRepository {
  let client: SupabaseClient

  func restoreSession() async -> AuthSession? {
    // `session` süresi dolmuşsa yeniler; yenilenemiyorsa hata verir.
    guard let session = try? await client.auth.session else { return nil }
    return AuthSession(userId: session.user.id, email: session.user.email)
  }

  func signIn(email: String, password: String) async throws -> AuthSession {
    try await mapped {
      let session = try await client.auth.signIn(email: email, password: password)
      return AuthSession(userId: session.user.id, email: session.user.email)
    }
  }

  func signOut() async throws {
    try await mapped { try await client.auth.signOut() }
  }

  func sendPasswordReset(email: String) async throws {
    try await mapped { try await client.auth.resetPasswordForEmail(email) }
  }
}

struct SupabaseAccessRepository: AccessRepository {
  let client: SupabaseClient

  func myPermissions() async throws -> [PermissionGrant] {
    try await mapped { try await client.rpc("my_permissions").execute().value }
  }

  func myProfile() async throws -> UserProfile {
    try await mapped { try await client.rpc("my_profile").single().execute().value }
  }
}

// MARK: - Projeler


struct SupabaseProjectRepository: ProjectRepository {
  let client: SupabaseClient
  private let columns = "id,code,name,address,city,start_date,end_date,status,notes,is_demo,version"

  func list(includeCompleted: Bool) async throws -> [Project] {
    try await mapped {
      var query = client.from("projects").select(columns).is("deleted_at", value: nil)
      if !includeCompleted { query = query.neq("status", value: ProjectStatus.tamamlandi.rawValue) }
      return try await query.order("name").execute().value
    }
  }

  func get(id: UUID) async throws -> Project {
    try await mapped {
      try await client.from("projects").select(columns).eq("id", value: id).single().execute().value
    }
  }

  func create(_ draft: ProjectDraft) async throws -> Project {
    try await mapped {
      try await client.from("projects").insert(draft).select(columns).single().execute().value
    }
  }

  func update(id: UUID, expectedVersion: Int, with draft: ProjectDraft) async throws -> Project {
    try await mapped {
      let rows: [Project] = try await client.from("projects").update(draft)
        .eq("id", value: id).eq("version", value: expectedVersion)
        .select(columns).execute().value
      guard let project = rows.first else {
        throw RepositoryError.conflict("Proje siz düzenlerken değiştirildi ya da düzenleme yetkiniz yok.")
      }
      return project
    }
  }
}

struct SupabaseCostCenterRepository: CostCenterRepository {
  let client: SupabaseClient

  func list() async throws -> [CostCenter] {
    try await mapped {
      try await client.from("cost_centers").select("id,code,name,description,is_active,is_demo")
        .is("deleted_at", value: nil).order("name").execute().value
    }
  }
}

// MARK: - Cari

struct SupabaseCariRepository: CariRepository {
  let client: SupabaseClient
  private let columns =
    "id,code,title,type,tax_number,tax_office,phone,email,address,iban,notes,is_active,is_demo,version"

  func listAccounts(type: CariType?, search: String?) async throws -> [CariAccount] {
    try await mapped {
      var query = client.from("cari_accounts").select(columns).is("deleted_at", value: nil)
      if let type { query = query.eq("type", value: type.rawValue) }
      if let search = search?.nilIfBlank {
        let escaped = search.replacingOccurrences(of: ",", with: " ")
        query = query.or("title.ilike.*\(escaped)*,code.ilike.*\(escaped)*")
      }
      return try await query.order("title").execute().value
    }
  }

  func getAccount(id: UUID) async throws -> CariAccount {
    try await mapped {
      try await client.from("cari_accounts").select(columns).eq("id", value: id).single().execute().value
    }
  }

  func createAccount(_ draft: CariAccountDraft) async throws -> CariAccount {
    try await mapped {
      try await client.from("cari_accounts").insert(draft).select(columns).single().execute().value
    }
  }

  func updateAccount(id: UUID, expectedVersion: Int, with draft: CariAccountDraft) async throws -> CariAccount {
    try await mapped {
      let rows: [CariAccount] = try await client.from("cari_accounts").update(draft)
        .eq("id", value: id).eq("version", value: expectedVersion)
        .select(columns).execute().value
      guard let account = rows.first else {
        throw RepositoryError.conflict("Cari kart siz düzenlerken değiştirildi ya da düzenleme yetkiniz yok.")
      }
      return account
    }
  }

  private struct BalanceParams: Encodable {
    let p_project_id: UUID?
    let p_cost_center_id: UUID?
    let p_until: CalendarDate?
  }

  func balances(filter: CariFilter) async throws -> [CariBalance] {
    try await mapped {
      try await client.rpc("cari_balances", params: BalanceParams(
        p_project_id: filter.projectId, p_cost_center_id: filter.costCenterId, p_until: filter.to
      )).execute().value
    }
  }

  private struct StatementParams: Encodable {
    let p_cari_account_id: UUID
    let p_project_id: UUID?
    let p_cost_center_id: UUID?
    let p_from: CalendarDate?
    let p_to: CalendarDate?
  }

  func statement(accountId: UUID, filter: CariFilter) async throws -> [CariStatementLine] {
    try await mapped {
      try await client.rpc("cari_statement", params: StatementParams(
        p_cari_account_id: accountId, p_project_id: filter.projectId, p_cost_center_id: filter.costCenterId,
        p_from: filter.from, p_to: filter.to
      )).execute().value
    }
  }

  private struct PostParams: Encodable {
    let p_id: UUID
    let p_cari_account_id: UUID
    let p_entry_date: CalendarDate
    let p_direction: CariDirection
    let p_kind: CariEntryKind
    let p_amount: Decimal
    let p_description: String
    let p_project_id: UUID?
    let p_cost_center_id: UUID?
    let p_document_no: String?
  }

  func post(_ entry: CariEntryDraft) async throws {
    var projectId: UUID?
    var costCenterId: UUID?
    switch entry.scope {
    case .project(let id): projectId = id
    case .costCenter(let id): costCenterId = id
    }
    let params = PostParams(
      p_id: entry.id, p_cari_account_id: entry.cariAccountId, p_entry_date: entry.entryDate,
      p_direction: entry.direction, p_kind: entry.kind, p_amount: entry.amount,
      p_description: entry.description, p_project_id: projectId, p_cost_center_id: costCenterId,
      p_document_no: entry.documentNo)
    try await mapped { _ = try await client.rpc("post_cari_entry", params: params).execute() }
  }

  private struct ReverseParams: Encodable {
    let p_entry_id: UUID
    let p_reason: String
    let p_reversal_id: UUID
  }

  func reverse(entryId: UUID, reason: String, reversalId: UUID) async throws {
    try await mapped {
      _ = try await client.rpc("reverse_cari_entry", params: ReverseParams(
        p_entry_id: entryId, p_reason: reason, p_reversal_id: reversalId)).execute()
    }
  }
}

// MARK: - İş takibi

struct SupabaseTaskRepository: TaskRepository {
  let client: SupabaseClient
  private let columns = "id,project_id,title,description,assignee_id,due_date,status,priority"

  func list(projectId: UUID?, openOnly: Bool) async throws -> [TaskItem] {
    try await mapped {
      var query = client.from("tasks").select(columns).is("deleted_at", value: nil)
      if let projectId { query = query.eq("project_id", value: projectId) }
      if openOnly { query = query.in("status", values: [TaskStatus.acik.rawValue, TaskStatus.devam.rawValue]) }
      return try await query.order("due_date", ascending: true, nullsFirst: false).execute().value
    }
  }

  private struct NewTask: Encodable {
    let id: UUID
    let project_id: UUID?
    let title: String
    let description: String?
    let assignee_id: UUID?
    let due_date: CalendarDate?
    let status: TaskStatus
    let priority: TaskPriority
  }

  func create(_ task: TaskItem) async throws -> TaskItem {
    try await mapped {
      try await client.from("tasks").insert(NewTask(
        id: task.id, project_id: task.projectId, title: task.title, description: task.description,
        assignee_id: task.assigneeId, due_date: task.dueDate, status: task.status, priority: task.priority
      )).select(columns).single().execute().value
    }
  }

  private struct StatusChange: Encodable { let status: TaskStatus }

  func setStatus(id: UUID, status: TaskStatus) async throws {
    try await mapped {
      let rows: [TaskItem] = try await client.from("tasks").update(StatusChange(status: status))
        .eq("id", value: id).select(columns).execute().value
      if rows.isEmpty { throw RepositoryError.forbidden(nil) }
    }
  }
}
