import Foundation
import RDCore
import Supabase

// MARK: - Malzeme, stok ve satın alma

/// Okumalar RLS'li tablolardan ve görünümlerden (v_stock_balances,
/// v_stock_pending, v_purchase_order_line_status); yazmalar yalnızca RPC'lerle
/// yapılır. Sipariş satırı fiyatı sütun yetkisiyle kapalıdır: satırlar fiyatsız
/// görünümden, fiyatlar purchase_order_prices() ile (satinalma.read) okunur.
struct SupabaseInventoryRepository: InventoryRepository {
  let client: SupabaseClient

  private let unitColumns = "id,code,name,symbol,decimals,sort_order,is_active,version"
  private let categoryColumns = "id,name,sort_order,is_active,version"
  private let materialColumns = "id,code,name,category_id,base_unit_id,description,is_active,version"
  private let conversionColumns = "id,material_id,unit_id,factor,note,is_active"
  private let warehouseColumns = "id,kind,project_id,name,is_default,is_active,is_demo,notes,version"
  private let movementColumns =
    "id,movement_no,kind,status,movement_date,material_id,warehouse_id,target_warehouse_id,quantity,unit_id," +
    "unit_factor,base_quantity,adjustment,description,reason,performed_by,document_id,purchase_order_id," +
    "purchase_receipt_id,reversal_of_id,reversed_by_id,approved_at,approved_by,rejected_at,reject_reason," +
    "created_by,created_at,is_demo,version"
  private let balanceColumns = "warehouse_id,material_id,quantity,entry_count,last_entry_date,is_demo"
  private let pendingColumns = "warehouse_id,material_id,pending_out,pending_in,movement_count"
  private let orderColumns =
    "id,order_no,status,cari_account_id,warehouse_id,project_id,order_date,expected_date,currency,description,notes," +
    "approved_at,approved_by,closed_at,close_reason,cancelled_at,cancel_reason,created_by,is_demo,version"
  /// Fiyatsız: unit_price ve line_total bu görünümde yoktur.
  private let lineColumns =
    "order_line_id,order_id,line_no,material_id,unit_id,quantity,unit_factor,base_quantity,note," +
    "received_base_quantity,remaining_base_quantity"
  private let receiptColumns =
    "id,receipt_no,order_id,warehouse_id,receipt_date,waybill_no,note,document_id,status,cancelled_at,cancel_reason," +
    "created_by,is_demo,version"
  private let receiptLineColumns = "id,receipt_id,order_line_id,quantity,base_quantity,stock_movement_id"
  private let expenseLinkColumns = "id,order_id,finance_document_id,note,status,cancel_reason"
  private let documentLinkColumns = "id,order_id,document_id,status,cancel_reason"
  private let eventColumns = "id,order_id,action,from_status,to_status,reason,actor_id,occurred_at"

  /// Boş (nil) değerleri de gönderir: RPC parametre adları eksiksiz eşleşmeli.
  private struct Params: Encodable {
    let values: [String: AnyJSON]
    func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }
  }

  private func rpc<T: Decodable>(_ name: String, _ values: [String: AnyJSON]) async throws -> T {
    try await mapped { try await client.rpc(name, params: Params(values: values)).execute().value }
  }

  private static func text(_ value: String?) -> AnyJSON { value.nilIfBlank.map { .string($0) } ?? .null }
  private static func uuid(_ value: UUID?) -> AnyJSON { value.map { .string($0.uuidString) } ?? .null }
  private static func date(_ value: CalendarDate?) -> AnyJSON { value.map { .string($0.iso) } ?? .null }
  private static func version(_ value: Int?) -> AnyJSON { value.map { .integer($0) } ?? .null }
  private static func decimal(_ value: Decimal?) -> AnyJSON {
    guard let value else { return .null }
    return .string(NSDecimalNumber(decimal: value).stringValue)  // tam ondalık; numeric'e çevrilir
  }
  /// jsonb içinde metin olarak: sunucu `->> ... ::numeric` ile kayıpsız okur.
  private static func number(_ value: Decimal) -> AnyJSON { .string(NSDecimalNumber(decimal: value).stringValue) }

  // MARK: Katalog

  func units(includeInactive: Bool) async throws -> [MaterialUnit] {
    try await mapped {
      var query = client.from("material_units").select(unitColumns)
      if !includeInactive { query = query.eq("is_active", value: true) }
      return try await query.order("sort_order").order("name").execute().value
    }
  }

  func saveUnit(_ unit: MaterialUnit) async throws -> MaterialUnit {
    try await rpc("save_material_unit", [
      "p_id": .string(unit.id.uuidString), "p_code": .string(unit.code), "p_name": .string(unit.name),
      "p_symbol": .string(unit.symbol), "p_decimals": .integer(unit.decimals), "p_sort_order": .integer(unit.sortOrder),
      "p_is_active": .bool(unit.isActive),
    ])
  }

  func categories(includeInactive: Bool) async throws -> [MaterialCategory] {
    try await mapped {
      var query = client.from("material_categories").select(categoryColumns)
      if !includeInactive { query = query.eq("is_active", value: true) }
      return try await query.order("sort_order").order("name").execute().value
    }
  }

  func saveCategory(_ category: MaterialCategory) async throws -> MaterialCategory {
    try await rpc("save_material_category", [
      "p_id": .string(category.id.uuidString), "p_name": .string(category.name),
      "p_sort_order": .integer(category.sortOrder), "p_is_active": .bool(category.isActive),
    ])
  }

  func materials(search: String?, categoryId: UUID?, includeInactive: Bool) async throws -> [Material] {
    let all: [Material] = try await mapped {
      var query = client.from("materials").select(materialColumns)
      if let categoryId { query = query.eq("category_id", value: categoryId) }
      if !includeInactive { query = query.eq("is_active", value: true) }
      return try await query.order("name").limit(2000).execute().value
    }
    // Katalog küçüktür; arama istemcide yapılır (Türkçe büyük/küçük harf duyarsız).
    guard let term = search.nilIfBlank?.lowercased(with: Money.locale) else { return all }
    return all.filter { "\($0.name) \($0.code)".lowercased(with: Money.locale).contains(term) }
  }

  func material(id: UUID) async throws -> Material {
    try await mapped {
      try await client.from("materials").select(materialColumns).eq("id", value: id).single().execute().value
    }
  }

  func saveMaterial(id: UUID, draft: MaterialDraft, expectedVersion: Int?) async throws -> Material {
    try await rpc("save_material", [
      "p_id": .string(id.uuidString), "p_name": .string(draft.name), "p_category_id": .string(draft.categoryId.uuidString),
      "p_base_unit_id": .string(draft.baseUnitId.uuidString), "p_code": Self.text(draft.code),
      "p_description": Self.text(draft.description), "p_is_active": .bool(draft.isActive),
      "p_expected_version": Self.version(expectedVersion),
    ])
  }

  func conversions(materialId: UUID?) async throws -> [MaterialUnitConversion] {
    try await mapped {
      var query = client.from("material_unit_conversions").select(conversionColumns)
      if let materialId { query = query.eq("material_id", value: materialId) }
      return try await query.order("is_active", ascending: false).limit(2000).execute().value
    }
  }

  func saveConversion(_ conversion: MaterialUnitConversion) async throws -> MaterialUnitConversion {
    try await rpc("save_material_unit_conversion", [
      "p_id": .string(conversion.id.uuidString), "p_material_id": .string(conversion.materialId.uuidString),
      "p_unit_id": .string(conversion.unitId.uuidString), "p_factor": Self.decimal(conversion.factor),
      "p_note": Self.text(conversion.note),
    ])
  }

  func setConversionActive(id: UUID, isActive: Bool) async throws -> MaterialUnitConversion {
    try await rpc("set_material_unit_conversion_active", ["p_id": .string(id.uuidString), "p_is_active": .bool(isActive)])
  }

  // MARK: Depolar

  func warehouses(projectId: UUID?, includeInactive: Bool) async throws -> [Warehouse] {
    try await mapped {
      var query = client.from("warehouses").select(warehouseColumns)
      if let projectId { query = query.eq("project_id", value: projectId) }
      if !includeInactive { query = query.eq("is_active", value: true) }
      return try await query.order("kind", ascending: false).order("is_default", ascending: false).order("name")
        .limit(1000).execute().value
    }
  }

  func saveWarehouse(id: UUID, draft: WarehouseDraft, expectedVersion: Int?) async throws -> Warehouse {
    try await rpc("save_warehouse", [
      "p_id": .string(id.uuidString), "p_name": .string(draft.name), "p_project_id": Self.uuid(draft.projectId),
      "p_is_demo": .bool(draft.isDemo), "p_is_active": .bool(draft.isActive), "p_notes": Self.text(draft.notes),
      "p_expected_version": Self.version(expectedVersion),
    ])
  }

  // MARK: Stok

  func balances(warehouseId: UUID?) async throws -> [StockBalance] {
    try await mapped {
      var query = client.from("v_stock_balances").select(balanceColumns)
      if let warehouseId { query = query.eq("warehouse_id", value: warehouseId) }
      return try await query.limit(5000).execute().value
    }
  }

  func pending(warehouseId: UUID?) async throws -> [StockPending] {
    try await mapped {
      var query = client.from("v_stock_pending").select(pendingColumns)
      if let warehouseId { query = query.eq("warehouse_id", value: warehouseId) }
      return try await query.limit(5000).execute().value
    }
  }

  func movements(filter: StockMovementFilter) async throws -> [StockMovement] {
    try await mapped {
      var query = client.from("stock_movements").select(movementColumns)
      if let w = filter.warehouseId {
        query = query.or("warehouse_id.eq.\(w.uuidString),target_warehouse_id.eq.\(w.uuidString)")
      }
      if let m = filter.materialId { query = query.eq("material_id", value: m) }
      if let s = filter.status { query = query.eq("status", value: s.rawValue) }
      if let o = filter.purchaseOrderId { query = query.eq("purchase_order_id", value: o) }
      return try await query.order("movement_date", ascending: false).order("movement_no", ascending: false)
        .limit(500).execute().value
    }
  }

  func movement(id: UUID) async throws -> StockMovement {
    try await mapped {
      try await client.from("stock_movements").select(movementColumns).eq("id", value: id).single().execute().value
    }
  }

  func createMovement(_ draft: StockMovementDraft) async throws -> StockMovement {
    try await rpc("create_stock_movement", [
      "p_id": .string(draft.id.uuidString), "p_kind": .string(draft.kind.rawValue),
      "p_material_id": .string(draft.materialId.uuidString), "p_warehouse_id": .string(draft.warehouseId.uuidString),
      "p_quantity": Self.decimal(draft.quantity), "p_unit_id": Self.uuid(draft.unitId),
      "p_target_warehouse_id": Self.uuid(draft.targetWarehouseId), "p_movement_date": Self.date(draft.movementDate),
      "p_description": Self.text(draft.description), "p_reason": Self.text(draft.reason),
      "p_document_id": Self.uuid(draft.documentId), "p_performed_by": Self.text(draft.performedBy),
    ])
  }

  func approveMovement(id: UUID, expectedVersion: Int?) async throws -> StockMovement {
    try await rpc("approve_stock_movement", ["p_id": .string(id.uuidString), "p_expected_version": Self.version(expectedVersion)])
  }

  func rejectMovement(id: UUID, reason: String) async throws -> StockMovement {
    try await rpc("reject_stock_movement", ["p_id": .string(id.uuidString), "p_reason": .string(reason)])
  }

  func reverseMovement(id: UUID, reversalId: UUID, reason: String) async throws -> StockMovement {
    try await rpc("reverse_stock_movement", [
      "p_id": .string(id.uuidString), "p_reversal_id": .string(reversalId.uuidString), "p_reason": .string(reason),
    ])
  }

  func summary(warehouseId: UUID, from: CalendarDate?, to: CalendarDate?) async throws -> [StockSummaryRow] {
    try await rpc("stock_summary", [
      "p_warehouse_id": .string(warehouseId.uuidString), "p_from": Self.date(from), "p_to": Self.date(to),
    ])
  }

  // MARK: Satın alma

  func purchaseOrders(projectId: UUID?, status: PurchaseOrderStatus?) async throws -> [PurchaseOrder] {
    try await mapped {
      var query = client.from("purchase_orders").select(orderColumns)
      if let projectId { query = query.eq("project_id", value: projectId) }
      if let status { query = query.eq("status", value: status.rawValue) }
      return try await query.order("order_date", ascending: false).order("order_no", ascending: false)
        .limit(500).execute().value
    }
  }

  func purchaseOrder(id: UUID) async throws -> PurchaseOrder {
    try await mapped {
      try await client.from("purchase_orders").select(orderColumns).eq("id", value: id).single().execute().value
    }
  }

  func purchaseOrderLines(orderId: UUID) async throws -> [PurchaseOrderLine] {
    try await mapped {
      try await client.from("v_purchase_order_line_status").select(lineColumns).eq("order_id", value: orderId)
        .order("line_no").execute().value
    }
  }

  func purchaseOrderPrices(orderId: UUID) async throws -> [PurchaseOrderLinePrice] {
    try await rpc("purchase_order_prices", ["p_order_id": .string(orderId.uuidString)])
  }

  func savePurchaseOrder(id: UUID, draft: PurchaseOrderDraft, expectedVersion: Int?) async throws -> PurchaseOrder {
    let lines: [AnyJSON] = draft.lines.map { line in
      var object: [String: AnyJSON] = [
        "id": .string(line.id.uuidString), "material_id": .string(line.materialId.uuidString),
        "quantity": Self.number(line.quantity),
      ]
      if let unit = line.unitId { object["unit_id"] = .string(unit.uuidString) }
      if let price = line.unitPrice { object["unit_price"] = Self.number(price) }
      if let note = line.note.nilIfBlank { object["note"] = .string(note) }
      return .object(object)
    }
    return try await rpc("save_purchase_order", [
      "p_id": .string(id.uuidString), "p_cari_account_id": .string(draft.cariAccountId.uuidString),
      "p_warehouse_id": .string(draft.warehouseId.uuidString), "p_lines": .array(lines),
      "p_order_date": Self.date(draft.orderDate), "p_expected_date": Self.date(draft.expectedDate),
      "p_currency": .string(draft.currency), "p_description": Self.text(draft.description),
      "p_notes": Self.text(draft.notes), "p_expected_version": Self.version(expectedVersion),
    ])
  }

  func transition(orderId: UUID, action: PurchaseOrderAction, reason: String?, expectedVersion: Int?) async throws -> PurchaseOrder {
    try await rpc("purchase_order_transition", [
      "p_id": .string(orderId.uuidString), "p_action": .string(action.rawValue), "p_reason": Self.text(reason),
      "p_expected_version": Self.version(expectedVersion),
    ])
  }

  func receipts(orderId: UUID) async throws -> [PurchaseReceipt] {
    try await mapped {
      try await client.from("purchase_receipts").select(receiptColumns).eq("order_id", value: orderId)
        .order("receipt_date").order("receipt_no").execute().value
    }
  }

  func receiptLines(receiptId: UUID) async throws -> [PurchaseReceiptLine] {
    try await mapped {
      try await client.from("purchase_receipt_lines").select(receiptLineColumns).eq("receipt_id", value: receiptId)
        .execute().value
    }
  }

  func receive(_ draft: PurchaseReceiptDraft) async throws -> PurchaseReceipt {
    let lines: [AnyJSON] = draft.nonZeroLines.map {
      .object(["order_line_id": .string($0.orderLineId.uuidString), "quantity": Self.number($0.quantity)])
    }
    return try await rpc("receive_purchase_order", [
      "p_id": .string(draft.id.uuidString), "p_order_id": .string(draft.orderId.uuidString), "p_lines": .array(lines),
      "p_receipt_date": Self.date(draft.receiptDate), "p_waybill_no": Self.text(draft.waybillNo),
      "p_note": Self.text(draft.note), "p_document_id": Self.uuid(draft.documentId),
      "p_performed_by": Self.text(draft.performedBy),
    ])
  }

  func cancelReceipt(id: UUID, reason: String) async throws -> PurchaseReceipt {
    try await rpc("cancel_purchase_receipt", ["p_id": .string(id.uuidString), "p_reason": .string(reason)])
  }

  func expenseLinks(orderId: UUID?, financeDocumentId: UUID?) async throws -> [PurchaseOrderExpenseLink] {
    try await mapped {
      var query = client.from("purchase_order_expense_links").select(expenseLinkColumns)
      if let orderId { query = query.eq("order_id", value: orderId) }
      if let financeDocumentId { query = query.eq("finance_document_id", value: financeDocumentId) }
      return try await query.limit(500).execute().value
    }
  }

  func linkExpense(id: UUID, orderId: UUID, financeDocumentId: UUID, note: String?) async throws -> PurchaseOrderExpenseLink {
    try await rpc("link_purchase_order_expense", [
      "p_id": .string(id.uuidString), "p_order_id": .string(orderId.uuidString),
      "p_finance_document_id": .string(financeDocumentId.uuidString), "p_note": Self.text(note),
    ])
  }

  func unlinkExpense(id: UUID, reason: String) async throws -> PurchaseOrderExpenseLink {
    try await rpc("unlink_purchase_order_expense", ["p_id": .string(id.uuidString), "p_reason": .string(reason)])
  }

  func documentLinks(orderId: UUID) async throws -> [PurchaseOrderDocumentLink] {
    try await mapped {
      try await client.from("purchase_order_documents").select(documentLinkColumns).eq("order_id", value: orderId)
        .execute().value
    }
  }

  func linkDocument(id: UUID, orderId: UUID, documentId: UUID) async throws -> PurchaseOrderDocumentLink {
    try await rpc("link_purchase_order_document", [
      "p_id": .string(id.uuidString), "p_order_id": .string(orderId.uuidString), "p_document_id": .string(documentId.uuidString),
    ])
  }

  func unlinkDocument(id: UUID, reason: String) async throws -> PurchaseOrderDocumentLink {
    try await rpc("unlink_purchase_order_document", ["p_id": .string(id.uuidString), "p_reason": .string(reason)])
  }

  func events(orderId: UUID) async throws -> [PurchaseOrderEvent] {
    try await mapped {
      try await client.from("purchase_order_events").select(eventColumns).eq("order_id", value: orderId)
        .order("occurred_at").limit(500).execute().value
    }
  }
}
