import Foundation
import RDCore
import Supabase

// MARK: - Puantaj

struct SupabasePuantajRepository: PuantajRepository {
  let client: SupabaseClient

  /// Supabase API'si istek başına en fazla 1000 satır döndürür; büyük projelerde
  /// (yüzlerce kişi × 31 gün) ay verisi sayfalar hâlinde okunur.
  static let pageSize = 1000

  private let entryColumns =
    "id,project_id,personnel_id,work_date,status,overtime_hours,overtime_note,overtime_approved_at,note," +
    "assignment_id,membership_id,crew_id,subcontractor_id,employment_type,personnel_name,crew_name,is_demo,version"
  private let periodColumns =
    "id,project_id,month,status,revision,submitted_at,approved_at,approved_by,first_approved_at,first_approved_by,locked_at,version"
  private let eventColumns = "id,action,from_status,to_status,revision,reason,actor_id,occurred_at"

  private struct MonthParams: Encodable {
    let p_project_id: UUID
    let p_month: CalendarDate
  }

  private struct SaveParams: Encodable {
    let p_project_id: UUID
    let p_items: [PuantajCellInput]
    let p_overwrite: Bool
  }

  private struct TransitionParams: Encodable {
    let p_project_id: UUID
    let p_month: CalendarDate
    let p_action: String
    let p_reason: String?
    let p_expected_version: Int?

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(p_project_id, forKey: .p_project_id)
      try container.encode(p_month, forKey: .p_month)
      try container.encode(p_action, forKey: .p_action)
      try container.encode(p_reason, forKey: .p_reason)
      try container.encode(p_expected_version, forKey: .p_expected_version)
    }

    enum CodingKeys: String, CodingKey {
      case p_project_id, p_month, p_action, p_reason, p_expected_version
    }
  }

  private struct OvertimeParams: Encodable {
    let p_entry_ids: [UUID]
  }

  func roster(projectId: UUID, month: PuantajMonth) async throws -> [PuantajRosterLink] {
    try await mapped {
      try await client.rpc("puantaj_roster", params: MonthParams(p_project_id: projectId, p_month: month.firstDay))
        .execute().value
    }
  }

  func entries(projectId: UUID, month: PuantajMonth) async throws -> [PuantajEntry] {
    try await mapped {
      var all: [PuantajEntry] = []
      var from = 0
      while true {
        let page: [PuantajEntry] = try await client.from("puantaj_entries").select(entryColumns)
          .eq("project_id", value: projectId)
          .gte("work_date", value: month.firstDay.iso)
          .lte("work_date", value: month.lastDay.iso)
          .is("deleted_at", value: nil)
          .order("id")
          .range(from: from, to: from + Self.pageSize - 1)
          .execute().value
        all += page
        if page.count < Self.pageSize { return all }
        from += Self.pageSize
      }
    }
  }

  func period(projectId: UUID, month: PuantajMonth) async throws -> PuantajPeriod? {
    try await mapped {
      let rows: [PuantajPeriod] = try await client.from("puantaj_periods").select(periodColumns)
        .eq("project_id", value: projectId).eq("month", value: month.firstDay.iso)
        .execute().value
      return rows.first
    }
  }

  func events(periodId: UUID) async throws -> [PuantajPeriodEvent] {
    try await mapped {
      try await client.from("puantaj_period_events").select(eventColumns)
        .eq("period_id", value: periodId).order("occurred_at").execute().value
    }
  }

  func save(projectId: UUID, items: [PuantajCellInput], overwrite: Bool) async throws -> [PuantajSaveOutcome] {
    try await mapped {
      try await client.rpc("save_puantaj", params: SaveParams(p_project_id: projectId, p_items: items, p_overwrite: overwrite))
        .execute().value
    }
  }

  func transition(projectId: UUID, month: PuantajMonth, action: PuantajAction, reason: String?,
                  expectedVersion: Int?) async throws -> PuantajPeriod {
    try await mapped {
      try await client.rpc("puantaj_transition",
                           params: TransitionParams(p_project_id: projectId, p_month: month.firstDay,
                                                    p_action: action.rawValue, p_reason: reason,
                                                    p_expected_version: expectedVersion))
        .execute().value
    }
  }

  func approveOvertime(entryIds: [UUID]) async throws -> Int {
    try await mapped {
      try await client.rpc("approve_puantaj_overtime", params: OvertimeParams(p_entry_ids: entryIds)).execute().value
    }
  }

  func summary(projectId: UUID, month: PuantajMonth) async throws -> [PuantajServerSummary] {
    try await mapped {
      try await client.rpc("puantaj_summary", params: MonthParams(p_project_id: projectId, p_month: month.firstDay))
        .execute().value
    }
  }
}
