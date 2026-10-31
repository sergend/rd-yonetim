import Foundation
import RDCore
import Supabase

// MARK: - Gider, gelir ve borç/alacak

/// Okumalar RLS'li tablolardan ve v_finance_document_status görünümünden;
/// yazmalar yalnızca RPC'lerle yapılır (tablolar API'ye yazmaya kapalıdır).
struct SupabaseFinanceRepository: FinanceRepository {
  let client: SupabaseClient

  private let categoryColumns = "id,kind,name,sort_order,is_active"
  private let documentColumns =
    "id,kind,document_no,status,project_id,cost_center_id,category_id,cari_account_id,description,document_date," +
    "due_date,amount,currency,exchange_rate,amount_try,invoice_no,document_ref,notes,reported_settled," +
    "reported_source_id,reported_by,approved_at,cari_entry_id,cancelled_at,cancel_reason,replaces_id,created_by," +
    "is_demo,version"
  private let settlementColumns =
    "id,document_id,kind,amount,settlement_date,payment_source_id,settled_by,description,exchange_rate,amount_try," +
    "cari_entry_id,status,cancel_reason,is_demo"
  private let statusColumns =
    "document_id,kind,status,amount,currency,settled_amount,settled_try,remaining_amount,remaining_try," +
    "settlement_status,due_date,is_overdue,days_overdue"
  private let eventColumns = "id,document_id,action,from_status,to_status,reason,actor_id,occurred_at"

  /// Boş (nil) değerleri de gönderir: RPC parametre adları eksiksiz eşleşmeli.
  private struct Params: Encodable {
    let values: [String: AnyJSON]
    func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }
  }

  private func rpc<T: Decodable>(_ name: String, _ values: [String: AnyJSON]) async throws -> T {
    try await mapped { try await client.rpc(name, params: Params(values: values)).execute().value }
  }

  private static func text(_ value: String?) -> AnyJSON { value.map { .string($0) } ?? .null }
  private static func uuid(_ value: UUID?) -> AnyJSON { value.map { .string($0.uuidString) } ?? .null }
  private static func date(_ value: CalendarDate?) -> AnyJSON { value.map { .string($0.iso) } ?? .null }
  private static func decimal(_ value: Decimal?) -> AnyJSON {
    guard let value else { return .null }
    return .string(NSDecimalNumber(decimal: value).stringValue)  // tam ondalık; numeric'e çevrilir
  }

  /// Uzun kimlik listelerini URL sınırına takılmadan böler.
  private func chunked<T: Decodable>(_ ids: [UUID], _ fetch: ([String]) async throws -> [T]) async throws -> [T] {
    var result: [T] = []
    var start = 0
    while start < ids.count {
      let slice = ids[start..<min(start + 100, ids.count)].map(\.uuidString)
      result += try await fetch(Array(slice))
      start += 100
    }
    return result
  }

  // MARK: Kategoriler

  func categories(kind: FinanceDocKind?, includeInactive: Bool) async throws -> [FinanceCategory] {
    try await mapped {
      var query = client.from("finance_categories").select(categoryColumns)
      if let kind { query = query.eq("kind", value: kind.rawValue) }
      if !includeInactive { query = query.eq("is_active", value: true) }
      return try await query.order("kind").order("sort_order").order("name").execute().value
    }
  }

  func saveCategory(_ category: FinanceCategory) async throws -> FinanceCategory {
    try await rpc("save_finance_category", [
      "p_id": .string(category.id.uuidString), "p_kind": .string(category.kind.rawValue),
      "p_name": .string(category.name), "p_sort_order": .integer(category.sortOrder),
      "p_is_active": .bool(category.isActive),
    ])
  }

  // MARK: Belgeler

  func documents(filter: FinanceDocumentFilter) async throws -> [FinanceDocument] {
    try await mapped {
      var query = client.from("finance_documents").select(documentColumns).eq("kind", value: filter.kind.rawValue)
      if let id = filter.projectId { query = query.eq("project_id", value: id) }
      if let id = filter.costCenterId { query = query.eq("cost_center_id", value: id) }
      if let id = filter.categoryId { query = query.eq("category_id", value: id) }
      if let id = filter.cariAccountId { query = query.eq("cari_account_id", value: id) }
      if let status = filter.status { query = query.eq("status", value: status.rawValue) }
      if let from = filter.from { query = query.gte("document_date", value: from.iso) }
      if let to = filter.to { query = query.lte("document_date", value: to.iso) }
      return try await query.order("document_date", ascending: false).order("document_no", ascending: false)
        .limit(500).execute().value
    }
  }

  func document(id: UUID) async throws -> FinanceDocument {
    try await mapped {
      try await client.from("finance_documents").select(documentColumns).eq("id", value: id).single().execute().value
    }
  }

  func documents(ids: [UUID]) async throws -> [FinanceDocument] {
    try await mapped {
      try await chunked(ids) { slice in
        try await client.from("finance_documents").select(documentColumns).in("id", values: slice).execute().value
      }
    }
  }

  func statuses(documentIds: [UUID]) async throws -> [FinanceDocumentStatus] {
    try await mapped {
      try await chunked(documentIds) { slice in
        try await client.from("v_finance_document_status").select(statusColumns).in("document_id", values: slice)
          .execute().value
      }
    }
  }

  func openStatuses(kind: FinanceDocKind) async throws -> [FinanceDocumentStatus] {
    try await mapped {
      try await client.from("v_finance_document_status").select(statusColumns).eq("kind", value: kind.rawValue)
        .in("settlement_status", values: ["acik", "kismi"]).order("due_date").limit(500).execute().value
    }
  }

  func saveDocument(id: UUID, draft: FinanceDocumentDraft, expectedVersion: Int?) async throws -> FinanceDocument {
    try await rpc("save_finance_document", [
      "p_id": .string(id.uuidString), "p_kind": .string(draft.kind.rawValue),
      "p_category_id": .string(draft.categoryId.uuidString), "p_description": .string(draft.description),
      "p_amount": Self.decimal(draft.amount), "p_document_date": .string(draft.documentDate.iso),
      "p_project_id": Self.uuid(draft.scope.projectId), "p_cost_center_id": Self.uuid(draft.scope.costCenterId),
      "p_due_date": Self.date(draft.dueDate), "p_currency": .string(draft.currency),
      "p_exchange_rate": Self.decimal(draft.exchangeRate), "p_cari_account_id": Self.uuid(draft.cariAccountId),
      "p_invoice_no": Self.text(draft.invoiceNo), "p_document_ref": Self.text(draft.documentRef),
      "p_notes": Self.text(draft.notes), "p_reported_settled": .bool(draft.reportedSettled),
      "p_reported_source_id": Self.uuid(draft.reportedSourceId), "p_reported_by": Self.text(draft.reportedBy),
      "p_expected_version": expectedVersion.map { .integer($0) } ?? .null,
    ])
  }

  func approve(id: UUID, expectedVersion: Int?, settlementId: UUID?) async throws -> FinanceDocument {
    try await rpc("approve_finance_document", [
      "p_id": .string(id.uuidString), "p_expected_version": expectedVersion.map { .integer($0) } ?? .null,
      "p_settlement_id": Self.uuid(settlementId),
    ])
  }

  func cancel(id: UUID, reason: String) async throws -> FinanceDocument {
    try await rpc("cancel_finance_document", ["p_id": .string(id.uuidString), "p_reason": .string(reason)])
  }

  func revise(id: UUID, newId: UUID, reason: String) async throws -> FinanceDocument {
    try await rpc("revise_finance_document", [
      "p_id": .string(id.uuidString), "p_new_id": .string(newId.uuidString), "p_reason": .string(reason),
    ])
  }

  func events(documentId: UUID) async throws -> [FinanceDocumentEvent] {
    try await mapped {
      try await client.from("finance_document_events").select(eventColumns).eq("document_id", value: documentId)
        .order("occurred_at", ascending: false).limit(200).execute().value
    }
  }

  // MARK: Ödeme / tahsilat

  func settlements(documentId: UUID) async throws -> [FinanceSettlement] {
    try await mapped {
      try await client.from("finance_settlements").select(settlementColumns).eq("document_id", value: documentId)
        .order("settlement_date", ascending: false).execute().value
    }
  }

  func recordSettlement(_ draft: FinanceSettlementDraft) async throws -> FinanceSettlement {
    try await rpc("record_finance_settlement", [
      "p_id": .string(draft.id.uuidString), "p_document_id": .string(draft.documentId.uuidString),
      "p_amount": Self.decimal(draft.amount), "p_payment_source_id": .string(draft.paymentSourceId.uuidString),
      "p_settlement_date": .string(draft.settlementDate.iso), "p_settled_by": Self.text(draft.settledBy),
      "p_description": Self.text(draft.description), "p_exchange_rate": Self.decimal(draft.exchangeRate),
    ])
  }

  func cancelSettlement(id: UUID, reason: String) async throws -> FinanceSettlement {
    try await rpc("cancel_finance_settlement", ["p_id": .string(id.uuidString), "p_reason": .string(reason)])
  }

  // MARK: Raporlar

  func report(kind: FinanceDocKind, group: FinanceReportGroup, from: CalendarDate?, to: CalendarDate?,
              projectId: UUID?, costCenterId: UUID?) async throws -> [FinanceReportRow] {
    try await rpc("finance_report", [
      "p_kind": .string(kind.rawValue), "p_group": .string(group.rawValue), "p_from": Self.date(from),
      "p_to": Self.date(to), "p_project_id": Self.uuid(projectId), "p_cost_center_id": Self.uuid(costCenterId),
    ])
  }

  func projectCosts(projectId: UUID?) async throws -> [ProjectCostRow] {
    try await rpc("project_cost_report", ["p_project_id": Self.uuid(projectId)])
  }
}
