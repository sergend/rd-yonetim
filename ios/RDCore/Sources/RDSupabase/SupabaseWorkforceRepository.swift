import Foundation
import RDCore
import Supabase

// MARK: - Taşeron, personel, ekip ve görevlendirmeler

struct SupabaseWorkforceRepository: WorkforceRepository {
  let client: SupabaseClient

  private let subcontractorColumns =
    "id,name,trade,cari_account_id,contact_name,phone,email,notes,is_active,is_demo,version"
  private let documentColumns = "id,subcontractor_id,title,document_no,valid_until,notes"
  private let linkColumns = "id,subcontractor_id,project_id,start_date,end_date,scope"
  private let personnelColumns =
    "id,full_name,job_title,trade,employment_type,subcontractor_id,notes,is_active,is_demo,version"
  private let crewColumns = "id,name,subcontractor_id,trade,leader_id,notes,is_active,is_demo,version"
  private let membershipColumns = "id,crew_id,personnel_id,start_date,end_date,role_title"
  private let assignmentColumns = "id,project_id,personnel_id,crew_id,start_date,end_date,description"

  private struct EndDate: Encodable {
    let end_date: CalendarDate
  }

  /// Güncellemede 0 satır dönmesi: kayıt başkası tarafından değişti ya da yetki yok.
  private func requireRow<T>(_ rows: [T], _ conflict: String) throws -> T {
    guard let row = rows.first else { throw RepositoryError.conflict(conflict) }
    return row
  }

  private func end(_ table: String, id: UUID, on endDate: CalendarDate) async throws {
    try await mapped {
      let rows: [[String: UUID]] = try await client.from(table).update(EndDate(end_date: endDate))
        .eq("id", value: id).select("id").execute().value
      if rows.isEmpty { throw RepositoryError.forbidden(nil) }
    }
  }

  // MARK: Taşeron

  func subcontractors() async throws -> [Subcontractor] {
    try await mapped {
      try await client.from("subcontractors").select(subcontractorColumns).is("deleted_at", value: nil)
        .order("name").execute().value
    }
  }

  func createSubcontractor(_ draft: SubcontractorDraft) async throws -> Subcontractor {
    try await mapped {
      try await client.from("subcontractors").insert(draft).select(subcontractorColumns).single().execute().value
    }
  }

  func updateSubcontractor(id: UUID, expectedVersion: Int, with draft: SubcontractorDraft) async throws -> Subcontractor {
    try await mapped {
      let rows: [Subcontractor] = try await client.from("subcontractors").update(draft)
        .eq("id", value: id).eq("version", value: expectedVersion).select(subcontractorColumns).execute().value
      return try requireRow(rows, "Taşeron siz düzenlerken değiştirildi ya da düzenleme yetkiniz yok.")
    }
  }

  func documents(subcontractorId: UUID) async throws -> [SubcontractorDocument] {
    try await mapped {
      try await client.from("subcontractor_documents").select(documentColumns)
        .eq("subcontractor_id", value: subcontractorId).is("deleted_at", value: nil)
        .order("valid_until", ascending: true, nullsFirst: false).execute().value
    }
  }

  func addDocument(_ document: SubcontractorDocument) async throws -> SubcontractorDocument {
    try await mapped {
      try await client.from("subcontractor_documents").insert(document).select(documentColumns).single().execute().value
    }
  }

  func subcontractorProjects(subcontractorId: UUID?, projectId: UUID?) async throws -> [SubcontractorProject] {
    try await mapped {
      var query = client.from("subcontractor_projects").select(linkColumns)
      if let subcontractorId { query = query.eq("subcontractor_id", value: subcontractorId) }
      if let projectId { query = query.eq("project_id", value: projectId) }
      return try await query.order("start_date", ascending: false).execute().value
    }
  }

  func addSubcontractorProject(_ link: SubcontractorProject) async throws -> SubcontractorProject {
    try await mapped {
      try await client.from("subcontractor_projects").insert(link).select(linkColumns).single().execute().value
    }
  }

  func endSubcontractorProject(id: UUID, on endDate: CalendarDate) async throws {
    try await end("subcontractor_projects", id: id, on: endDate)
  }

  // MARK: Personel

  func personnel() async throws -> [Personnel] {
    try await mapped {
      try await client.from("personnel").select(personnelColumns).is("deleted_at", value: nil)
        .order("full_name").execute().value
    }
  }

  func createPersonnel(_ draft: PersonnelDraft) async throws -> Personnel {
    try await mapped {
      try await client.from("personnel").insert(draft).select(personnelColumns).single().execute().value
    }
  }

  func updatePersonnel(id: UUID, expectedVersion: Int, with draft: PersonnelDraft) async throws -> Personnel {
    try await mapped {
      let rows: [Personnel] = try await client.from("personnel").update(draft)
        .eq("id", value: id).eq("version", value: expectedVersion).select(personnelColumns).execute().value
      return try requireRow(rows, "Personel kaydı siz düzenlerken değiştirildi ya da düzenleme yetkiniz yok.")
    }
  }

  func contact(personnelId: UUID) async throws -> PersonnelContact? {
    try await mapped {
      let rows: [PersonnelContact] = try await client.from("personnel_contacts").select("personnel_id,phone")
        .eq("personnel_id", value: personnelId).execute().value
      return rows.first
    }
  }

  private struct PhoneRow: Encodable {
    let personnelId: UUID
    let phone: String?

    enum CodingKeys: String, CodingKey {
      case phone
      case personnelId = "personnel_id"
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(personnelId, forKey: .personnelId)
      try c.encode(phone, forKey: .phone)  // boşsa silinsin
    }
  }

  func setPhone(_ phone: String?, personnelId: UUID) async throws {
    try await mapped {
      _ = try await client.from("personnel_contacts")
        .upsert(PhoneRow(personnelId: personnelId, phone: phone), onConflict: "personnel_id", returning: .minimal)
        .execute()
    }
  }

  // MARK: Ekip

  func crews() async throws -> [Crew] {
    try await mapped {
      try await client.from("crews").select(crewColumns).is("deleted_at", value: nil).order("name").execute().value
    }
  }

  func createCrew(_ draft: CrewDraft) async throws -> Crew {
    try await mapped {
      try await client.from("crews").insert(draft).select(crewColumns).single().execute().value
    }
  }

  func updateCrew(id: UUID, expectedVersion: Int, with draft: CrewDraft) async throws -> Crew {
    try await mapped {
      let rows: [Crew] = try await client.from("crews").update(draft)
        .eq("id", value: id).eq("version", value: expectedVersion).select(crewColumns).execute().value
      return try requireRow(rows, "Ekip siz düzenlerken değiştirildi ya da düzenleme yetkiniz yok.")
    }
  }

  func memberships(crewId: UUID?, personnelId: UUID?) async throws -> [CrewMembership] {
    try await mapped {
      var query = client.from("crew_memberships").select(membershipColumns)
      if let crewId { query = query.eq("crew_id", value: crewId) }
      if let personnelId { query = query.eq("personnel_id", value: personnelId) }
      return try await query.order("start_date", ascending: false).execute().value
    }
  }

  func addMembership(_ membership: CrewMembership) async throws -> CrewMembership {
    try await mapped {
      try await client.from("crew_memberships").insert(membership).select(membershipColumns).single().execute().value
    }
  }

  func endMembership(id: UUID, on endDate: CalendarDate) async throws {
    try await end("crew_memberships", id: id, on: endDate)
  }

  // MARK: Görevlendirme

  func assignments(projectId: UUID?, personnelId: UUID?, crewId: UUID?) async throws -> [ProjectAssignment] {
    try await mapped {
      var query = client.from("project_assignments").select(assignmentColumns)
      if let projectId { query = query.eq("project_id", value: projectId) }
      if let personnelId { query = query.eq("personnel_id", value: personnelId) }
      if let crewId { query = query.eq("crew_id", value: crewId) }
      return try await query.order("start_date", ascending: false).execute().value
    }
  }

  func assign(_ assignment: ProjectAssignment) async throws -> ProjectAssignment {
    try await mapped {
      try await client.from("project_assignments").insert(assignment).select(assignmentColumns).single().execute().value
    }
  }

  func endAssignment(id: UUID, on endDate: CalendarDate) async throws {
    try await end("project_assignments", id: id, on: endDate)
  }

  private struct ProjectParam: Encodable {
    let p_project_id: UUID
  }

  func candidates(projectId: UUID) async throws -> [AssignmentCandidate] {
    try await mapped {
      try await client.rpc("assignment_candidates", params: ProjectParam(p_project_id: projectId)).execute().value
    }
  }

  private struct WorkforceParams: Encodable {
    let p_project_id: UUID
    let p_on: CalendarDate
  }

  func workforce(projectId: UUID, on day: CalendarDate) async throws -> [WorkforceEntry] {
    try await mapped {
      try await client.rpc("project_workforce", params: WorkforceParams(p_project_id: projectId, p_on: day))
        .execute().value
    }
  }
}
