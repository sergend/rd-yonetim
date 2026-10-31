import Foundation
import RDCore
import Supabase

// MARK: - Sözleşme ve hakediş

/// Okumalar RLS'li tablolardan, yazmalar yalnızca RPC'lerle yapılır.
/// Tutarlar sunucuda hesaplanır; istemci yalnızca miktar, yüzde ve elle
/// girilen kesinti gönderir.
struct SupabaseContractRepository: ContractRepository {
  let client: SupabaseClient

  private let contractColumns =
    "id,contract_no,project_id,subcontractor_id,cari_account_id,title,signed_date,currency,status,is_demo,version"
  private let versionColumns =
    "id,contract_id,revision,status,scope,start_date,end_date,total_amount,retention_rate,advance_deduction_rate," +
    "payment_terms,notes,reason,approved_at"
  private let itemColumns =
    "id,version_id,contract_id,item_key,line_no,method,description,unit,quantity,unit_price,overtime_unit_price," +
    "paid_bases,personnel_id"
  private let quantityColumns =
    "id,contract_id,project_id,item_key,work_date,quantity,location,note,status,is_demo,version"
  private let hakedisColumns =
    "id,contract_id,version_id,project_id,subcontractor_id,cari_account_id,hakedis_no,period_start,period_end," +
    "status,currency,replaces_id,note,gross_amount,kdv_amount,tax_deduction_amount,other_deduction_amount," +
    "retention_amount,advance_amount,payable_amount,limit_exceeded,limit_messages,limit_override_reason," +
    "submitted_at,approved_at,approved_by,cancelled_at,cancel_reason,posted_at,cari_entry_id,is_demo,version"
  private let lineColumns =
    "id,hakedis_id,item_key,line_kind,method,description,unit,unit_price,contract_quantity,quantity," +
    "previous_quantity,cumulative_quantity,amount,previous_amount,cumulative_amount,progress_percent"
  private let adjustmentColumns = "id,hakedis_id,kind,tax_code,base_amount,rate,amount,description,is_manual"
  private let linkColumns =
    "id,hakedis_id,personnel_id,personnel_name,work_date,status,pay_basis,day_delta,overtime_delta," +
    "period_revision,entry_version,is_correction"
  private let releaseColumns = "id,contract_id,amount,release_date,reason,status,cancel_reason"
  private let paymentColumns =
    "id,contract_id,kind,amount,payment_date,payment_source_id,hakedis_id,teminat_release_id,description,status,cancel_reason"
  private let eventColumns = "id,entity,entity_id,action,from_status,to_status,reason,actor_id,occurred_at"

  /// Boş (nil) değerleri de gönderir: RPC parametre adları eksiksiz eşleşmeli.
  private struct Params: Encodable {
    let values: [String: AnyJSON]
    func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }
  }

  private func rpc<T: Decodable>(_ name: String, _ values: [String: AnyJSON]) async throws -> T {
    try await mapped { try await client.rpc(name, params: Params(values: values)).execute().value }
  }

  private static func json<T: Codable>(_ value: T?) -> AnyJSON {
    guard let value else { return .null }
    return (try? AnyJSON(value)) ?? .null
  }

  private static func decimal(_ value: Decimal?) -> AnyJSON {
    guard let value else { return .null }
    return .string(NSDecimalNumber(decimal: value).stringValue)  // tam ondalık; numeric'e çevrilir
  }

  // MARK: Sözleşme

  func contracts(projectId: UUID?) async throws -> [Contract] {
    try await mapped {
      var query = client.from("contracts").select(contractColumns)
      if let projectId { query = query.eq("project_id", value: projectId) }
      return try await query.order("contract_no").execute().value
    }
  }

  func versions(contractId: UUID) async throws -> [ContractVersion] {
    try await mapped {
      try await client.from("contract_versions").select(versionColumns).eq("contract_id", value: contractId)
        .order("revision", ascending: false).execute().value
    }
  }

  func items(versionId: UUID) async throws -> [ContractItem] {
    try await mapped {
      try await client.from("contract_items").select(itemColumns).eq("version_id", value: versionId)
        .order("line_no").execute().value
    }
  }

  private struct TaxCodeRow: Decodable { let tax_code: String }

  func taxCodes(versionId: UUID) async throws -> [String] {
    try await mapped {
      let rows: [TaxCodeRow] = try await client.from("contract_version_taxes").select("tax_code")
        .eq("version_id", value: versionId).order("tax_code").execute().value
      return rows.map(\.tax_code)
    }
  }

  func saveContract(id: UUID, draft: ContractDraft, expectedVersion: Int?) async throws -> Contract {
    try await rpc("save_contract", [
      "p_contract_id": .string(id.uuidString),
      "p_project_id": .string(draft.projectId.uuidString),
      "p_subcontractor_id": .string(draft.subcontractorId.uuidString),
      "p_contract_no": .string(draft.contractNo),
      "p_title": .string(draft.title),
      "p_items": .array(draft.items.map(Self.itemJSON)),
      "p_signed_date": Self.json(draft.signedDate),
      "p_currency": .string(draft.currency),
      "p_scope": Self.json(draft.scope),
      "p_start_date": Self.json(draft.startDate),
      "p_end_date": Self.json(draft.endDate),
      "p_total_amount": Self.decimal(draft.totalAmount),
      "p_retention_rate": Self.decimal(draft.retentionRate),
      "p_advance_deduction_rate": Self.decimal(draft.advanceDeductionRate),
      "p_payment_terms": Self.json(draft.paymentTerms),
      "p_notes": Self.json(draft.notes),
      "p_tax_codes": .array(draft.taxCodes.map { .string($0) }),
      "p_expected_version": expectedVersion.map { .integer($0) } ?? .null,
    ])
  }

  private static func itemJSON(_ item: ContractItemDraft) -> AnyJSON {
    var object: [String: AnyJSON] = [
      "item_key": .string(item.itemKey.uuidString),
      "method": .string(item.method.rawValue),
      "description": .string(item.description),
      "unit": .string(item.unit.rawValue),
      "unit_price": decimal(item.unitPrice),
    ]
    if let quantity = item.quantity { object["quantity"] = decimal(quantity) }
    if item.method == .gunluk {
      object["paid_bases"] = .array(item.paidBases.map { .string($0.rawValue) })
      if let overtime = item.overtimeUnitPrice { object["overtime_unit_price"] = decimal(overtime) }
      if let person = item.personnelId { object["personnel_id"] = .string(person.uuidString) }
    }
    return .object(object)
  }

  func transition(contractId: UUID, action: ContractAction, reason: String?, expectedVersion: Int?) async throws -> Contract {
    try await rpc("contract_transition", [
      "p_contract_id": .string(contractId.uuidString), "p_action": .string(action.rawValue),
      "p_reason": Self.json(reason), "p_expected_version": expectedVersion.map { .integer($0) } ?? .null,
    ])
  }

  func taxRules() async throws -> [TaxRule] {
    try await mapped {
      try await client.from("tax_rules").select("id,code,name,kind,rate,base,valid_from,valid_to,verified_at,is_active")
        .order("code").order("valid_from", ascending: false).execute().value
    }
  }

  func paymentSources() async throws -> [PaymentSource] {
    try await mapped {
      try await client.from("payment_sources").select("id,name,kind,is_active").eq("is_active", value: true)
        .order("name").execute().value
    }
  }

  // MARK: İmalat

  func imalatItems(projectId: UUID) async throws -> [ImalatItem] {
    try await rpc("imalat_items", ["p_project_id": .string(projectId.uuidString)])
  }

  func workQuantities(contractId: UUID) async throws -> [WorkQuantity] {
    try await mapped {
      try await client.from("work_quantities").select(quantityColumns).eq("contract_id", value: contractId)
        .order("work_date", ascending: false).execute().value
    }
  }

  func saveWorkQuantity(_ quantity: WorkQuantity) async throws -> WorkQuantity {
    try await rpc("save_work_quantity", [
      "p_id": .string(quantity.id.uuidString), "p_contract_id": .string(quantity.contractId.uuidString),
      "p_item_key": .string(quantity.itemKey.uuidString), "p_work_date": .string(quantity.workDate.iso),
      "p_quantity": Self.decimal(quantity.quantity), "p_location": Self.json(quantity.location),
      "p_note": Self.json(quantity.note),
    ])
  }

  func approveWorkQuantities(ids: [UUID]) async throws -> Int {
    try await rpc("approve_work_quantities", ["p_ids": .array(ids.map { .string($0.uuidString) })])
  }

  func cancelWorkQuantity(id: UUID, reason: String) async throws -> WorkQuantity {
    try await rpc("cancel_work_quantity", ["p_id": .string(id.uuidString), "p_reason": .string(reason)])
  }

  // MARK: Hakediş

  func hakedisList(contractId: UUID?) async throws -> [Hakedis] {
    try await mapped {
      var query = client.from("hakedis").select(hakedisColumns)
      if let contractId { query = query.eq("contract_id", value: contractId) }
      return try await query.order("period_end", ascending: false).order("hakedis_no", ascending: false)
        .execute().value
    }
  }

  func hakedis(id: UUID) async throws -> Hakedis {
    try await mapped {
      try await client.from("hakedis").select(hakedisColumns).eq("id", value: id).single().execute().value
    }
  }

  func lines(hakedisId: UUID) async throws -> [HakedisLine] {
    try await mapped {
      let rows: [HakedisLine] = try await client.from("hakedis_lines").select(lineColumns)
        .eq("hakedis_id", value: hakedisId).execute().value
      return rows
    }
  }

  func adjustments(hakedisId: UUID) async throws -> [HakedisAdjustment] {
    try await mapped {
      try await client.from("hakedis_adjustments").select(adjustmentColumns).eq("hakedis_id", value: hakedisId)
        .order("kind").execute().value
    }
  }

  func puantajLinks(hakedisId: UUID) async throws -> [HakedisPuantajLink] {
    try await mapped {
      try await client.from("hakedis_puantaj_links").select(linkColumns).eq("hakedis_id", value: hakedisId)
        .eq("active", value: true).order("personnel_name").order("work_date").execute().value
    }
  }

  func createHakedis(id: UUID, contractId: UUID, periodStart: CalendarDate, periodEnd: CalendarDate,
                     note: String?) async throws -> Hakedis {
    try await rpc("create_hakedis", [
      "p_id": .string(id.uuidString), "p_contract_id": .string(contractId.uuidString),
      "p_period_start": .string(periodStart.iso), "p_period_end": .string(periodEnd.iso), "p_note": Self.json(note),
    ])
  }

  func refreshHakedis(id: UUID) async throws -> Hakedis {
    try await rpc("refresh_hakedis", ["p_hakedis_id": .string(id.uuidString)])
  }

  func setProgress(hakedisId: UUID, itemKey: UUID, percent: Decimal) async throws -> Hakedis {
    try await rpc("set_hakedis_progress", [
      "p_hakedis_id": .string(hakedisId.uuidString), "p_item_key": .string(itemKey.uuidString),
      "p_percent": Self.decimal(percent),
    ])
  }

  func setDeduction(hakedisId: UUID, kind: HakedisAdjustmentKind, amount: Decimal,
                    description: String?) async throws -> Hakedis {
    try await rpc("set_hakedis_deduction", [
      "p_hakedis_id": .string(hakedisId.uuidString), "p_kind": .string(kind.rawValue),
      "p_amount": Self.decimal(amount), "p_description": Self.json(description),
    ])
  }

  func overrideLimit(hakedisId: UUID, reason: String) async throws -> Hakedis {
    try await rpc("override_hakedis_limit", ["p_hakedis_id": .string(hakedisId.uuidString), "p_reason": .string(reason)])
  }

  func transition(hakedisId: UUID, action: HakedisAction, reason: String?, expectedVersion: Int?) async throws -> Hakedis {
    try await rpc("hakedis_transition", [
      "p_hakedis_id": .string(hakedisId.uuidString), "p_action": .string(action.rawValue),
      "p_reason": Self.json(reason), "p_expected_version": expectedVersion.map { .integer($0) } ?? .null,
    ])
  }

  func revise(hakedisId: UUID, newId: UUID, reason: String) async throws -> Hakedis {
    try await rpc("revise_hakedis", [
      "p_hakedis_id": .string(hakedisId.uuidString), "p_new_id": .string(newId.uuidString), "p_reason": .string(reason),
    ])
  }

  func post(hakedisId: UUID, entryDate: CalendarDate?) async throws -> Hakedis {
    try await rpc("post_hakedis", ["p_hakedis_id": .string(hakedisId.uuidString), "p_entry_date": Self.json(entryDate)])
  }

  // MARK: Teminat ve ödeme

  func teminatReleases(contractId: UUID) async throws -> [TeminatRelease] {
    try await mapped {
      try await client.from("teminat_releases").select(releaseColumns).eq("contract_id", value: contractId)
        .order("release_date", ascending: false).execute().value
    }
  }

  func releaseTeminat(id: UUID, contractId: UUID, amount: Decimal, reason: String,
                      date: CalendarDate?) async throws -> TeminatRelease {
    try await rpc("release_teminat", [
      "p_id": .string(id.uuidString), "p_contract_id": .string(contractId.uuidString),
      "p_amount": Self.decimal(amount), "p_reason": .string(reason), "p_release_date": Self.json(date),
    ])
  }

  func cancelTeminatRelease(id: UUID, reason: String) async throws -> TeminatRelease {
    try await rpc("cancel_teminat_release", ["p_id": .string(id.uuidString), "p_reason": .string(reason)])
  }

  func payments(contractId: UUID) async throws -> [FinancePayment] {
    try await mapped {
      try await client.from("finance_payments").select(paymentColumns).eq("contract_id", value: contractId)
        .order("payment_date", ascending: false).execute().value
    }
  }

  func recordPayment(_ draft: FinancePaymentDraft) async throws -> FinancePayment {
    var hakedisId: AnyJSON = .null
    var releaseId: AnyJSON = .null
    switch draft.target {
    case .hakedis(let id): hakedisId = .string(id.uuidString)
    case .teminatRelease(let id): releaseId = .string(id.uuidString)
    case .advance: break
    }
    return try await rpc("record_finance_payment", [
      "p_id": .string(draft.id.uuidString), "p_contract_id": .string(draft.contractId.uuidString),
      "p_kind": .string(draft.kind.rawValue), "p_amount": Self.decimal(draft.amount),
      "p_payment_source_id": .string(draft.paymentSourceId.uuidString), "p_payment_date": .string(draft.paymentDate.iso),
      "p_hakedis_id": hakedisId, "p_teminat_release_id": releaseId, "p_description": Self.json(draft.description),
    ])
  }

  func cancelPayment(id: UUID, reason: String) async throws -> FinancePayment {
    try await rpc("cancel_finance_payment", ["p_id": .string(id.uuidString), "p_reason": .string(reason)])
  }

  func financeSummary(contractId: UUID) async throws -> ContractFinanceSummary {
    try await mapped {
      try await client.rpc("contract_finance_summary", params: Params(values: ["p_contract_id": .string(contractId.uuidString)]))
        .single().execute().value
    }
  }

  func paymentStatus(hakedisIds: [UUID]) async throws -> [HakedisPaymentStatus] {
    guard !hakedisIds.isEmpty else { return [] }
    return try await mapped {
      try await client.from("v_hakedis_payment_status").select("hakedis_id,payable_amount,paid_amount,remaining_amount")
        .in("hakedis_id", values: hakedisIds.map(\.uuidString)).execute().value
    }
  }

  func events(contractId: UUID) async throws -> [FinanceEvent] {
    try await mapped {
      try await client.from("finance_events").select(eventColumns).eq("contract_id", value: contractId)
        .order("occurred_at", ascending: false).limit(200).execute().value
    }
  }
}
