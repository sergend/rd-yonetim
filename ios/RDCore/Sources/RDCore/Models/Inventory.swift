import Foundation

// MARK: - Malzeme, stok ve satın alma (Aşama 7)
//
// Stok miktarı hiçbir kayıtta elle tutulmaz: sunucudaki değiştirilemez stok
// defterinin (stock_entries) toplamıdır. Hareketler ve siparişler yalnızca
// RPC'lerle yazılır; kimlikler istemcide üretilir ve tekrar gönderim ikinci
// kayıt açmaz. Stok hareketlerinde tutar yoktur; satın alma siparişi borç,
// gider veya ödeme oluşturmaz (gerçek borç Aşama 5 gider onayından doğar).

// MARK: Katalog

/// Ölçü birimi (veri olarak yönetilir; kodda sabit liste yoktur).
public struct MaterialUnit: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var code: String
  public var name: String
  public var symbol: String
  /// İzin verilen ondalık hane (adet 0, kg 3).
  public var decimals: Int
  public var sortOrder: Int
  public var isActive: Bool
  public var version: Int

  public init(id: UUID = UUID(), code: String, name: String, symbol: String, decimals: Int = 0,
              sortOrder: Int = 100, isActive: Bool = true, version: Int = 1) {
    self.id = id
    self.code = code
    self.name = name
    self.symbol = symbol
    self.decimals = decimals
    self.sortOrder = sortOrder
    self.isActive = isActive
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, code, name, symbol, decimals, version
    case sortOrder = "sort_order", isActive = "is_active"
  }
}

public struct MaterialCategory: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var name: String
  public var sortOrder: Int
  public var isActive: Bool
  public var version: Int

  public init(id: UUID = UUID(), name: String, sortOrder: Int = 100, isActive: Bool = true, version: Int = 1) {
    self.id = id
    self.name = name
    self.sortOrder = sortOrder
    self.isActive = isActive
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, name, version
    case sortOrder = "sort_order", isActive = "is_active"
  }
}

public struct Material: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var code: String
  public var name: String
  public var categoryId: UUID
  /// Hareket, sipariş satırı veya dönüşüm oranı varken değiştirilemez.
  public var baseUnitId: UUID
  public var description: String?
  public var isActive: Bool
  public var version: Int

  public init(id: UUID = UUID(), code: String, name: String, categoryId: UUID, baseUnitId: UUID,
              description: String? = nil, isActive: Bool = true, version: Int = 1) {
    self.id = id
    self.code = code
    self.name = name
    self.categoryId = categoryId
    self.baseUnitId = baseUnitId
    self.description = description
    self.isActive = isActive
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, code, name, description, version
    case categoryId = "category_id", baseUnitId = "base_unit_id", isActive = "is_active"
  }
}

public struct MaterialDraft: Hashable, Sendable {
  public var name: String
  public var categoryId: UUID
  public var baseUnitId: UUID
  /// Boşsa sunucu MLZ-0001 biçiminde kod verir.
  public var code: String?
  public var description: String?
  public var isActive: Bool

  public init(name: String, categoryId: UUID, baseUnitId: UUID, code: String? = nil,
              description: String? = nil, isActive: Bool = true) {
    self.name = name
    self.categoryId = categoryId
    self.baseUnitId = baseUnitId
    self.code = code
    self.description = description
    self.isActive = isActive
  }

  public init(_ material: Material) {
    self.init(name: material.name, categoryId: material.categoryId, baseUnitId: material.baseUnitId,
              code: material.code, description: material.description, isActive: material.isActive)
  }

  public var validationMessage: String? {
    name.nilIfBlank == nil ? "Malzeme adı zorunlu." : nil
  }
}

/// Açık dönüşüm oranı: 1 `unit` = `factor` temel birim. Otomatik tahmin
/// yapılmaz; tanımlı olmayan birimle hareket girilemez. Oran değişmez,
/// pasifleştirilip yenisi tanımlanır.
public struct MaterialUnitConversion: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var materialId: UUID
  public var unitId: UUID
  public var factor: Decimal
  public var note: String?
  public var isActive: Bool

  public init(id: UUID = UUID(), materialId: UUID, unitId: UUID, factor: Decimal, note: String? = nil,
              isActive: Bool = true) {
    self.id = id
    self.materialId = materialId
    self.unitId = unitId
    self.factor = factor
    self.note = note
    self.isActive = isActive
  }

  enum CodingKeys: String, CodingKey {
    case id, factor, note
    case materialId = "material_id", unitId = "unit_id", isActive = "is_active"
  }
}

// MARK: Depolar

public enum WarehouseKind: String, Codable, CaseIterable, Sendable {
  case proje, genel

  public var title: String {
    switch self {
    case .proje: "Proje deposu"
    case .genel: "Genel depo"
    }
  }
}

public struct Warehouse: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var kind: WarehouseKind
  public var projectId: UUID?
  public var name: String
  /// Projenin otomatik açılan ana deposu.
  public var isDefault: Bool
  public var isActive: Bool
  public var isDemo: Bool
  public var notes: String?
  public var version: Int

  public init(id: UUID = UUID(), kind: WarehouseKind, projectId: UUID? = nil, name: String, isDefault: Bool = false,
              isActive: Bool = true, isDemo: Bool = false, notes: String? = nil, version: Int = 1) {
    self.id = id
    self.kind = kind
    self.projectId = projectId
    self.name = name
    self.isDefault = isDefault
    self.isActive = isActive
    self.isDemo = isDemo
    self.notes = notes
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, name, notes, version
    case projectId = "project_id", isDefault = "is_default", isActive = "is_active", isDemo = "is_demo"
  }
}

public struct WarehouseDraft: Hashable, Sendable {
  public var name: String
  /// nil: genel depo.
  public var projectId: UUID?
  /// Yalnızca genel depoda ve oluştururken; proje deposu projeden alır.
  public var isDemo: Bool
  public var isActive: Bool
  public var notes: String?

  public init(name: String, projectId: UUID? = nil, isDemo: Bool = false, isActive: Bool = true, notes: String? = nil) {
    self.name = name
    self.projectId = projectId
    self.isDemo = isDemo
    self.isActive = isActive
    self.notes = notes
  }
}

// MARK: Stok hareketleri

public enum StockMovementKind: String, Codable, CaseIterable, Sendable, Identifiable {
  case giris
  case kullanim
  case transfer
  case iadeDepo = "iade_depo"
  case iadeTedarikci = "iade_tedarikci"
  case sayim
  case tersKayit = "ters_kayit"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .giris: "Giriş"
    case .kullanim: "Kullanım"
    case .transfer: "Transfer"
    case .iadeDepo: "Depoya iade"
    case .iadeTedarikci: "Tedarikçiye iade"
    case .sayim: "Sayım düzeltmesi"
    case .tersKayit: "Ters kayıt"
    }
  }

  public var symbol: String {
    switch self {
    case .giris: "arrow.down.to.line"
    case .kullanim: "hammer"
    case .transfer: "arrow.left.arrow.right"
    case .iadeDepo: "arrow.uturn.backward"
    case .iadeTedarikci: "arrow.uturn.forward"
    case .sayim: "list.number"
    case .tersKayit: "arrow.counterclockwise"
    }
  }

  /// Formdan elle girilebilen türler (ters kayıt iptal işlemiyle oluşur).
  public static let manual: [StockMovementKind] = [.giris, .kullanim, .transfer, .iadeDepo, .iadeTedarikci, .sayim]

  /// Kaynak depodan stok düşer mi (transferde kaynak depo).
  public var decreasesSource: Bool { self == .kullanim || self == .transfer || self == .iadeTedarikci }

  /// Sayımda gerekçe zorunludur (en az 10 karakter).
  public var requiresReason: Bool { self == .sayim }
}

public enum StockMovementStatus: String, Codable, CaseIterable, Sendable {
  case bekliyor, onaylandi, reddedildi

  public var title: String {
    switch self {
    case .bekliyor: "Onay bekliyor"
    case .onaylandi: "Stoka işlendi"
    case .reddedildi: "Reddedildi"
    }
  }
}

public struct StockMovement: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var movementNo: String
  public var kind: StockMovementKind
  public var status: StockMovementStatus
  public var movementDate: CalendarDate
  public var materialId: UUID
  public var warehouseId: UUID
  public var targetWarehouseId: UUID?
  /// Girilen miktar (sayımda sayılan miktar, temel birim).
  public var quantity: Decimal
  public var unitId: UUID
  public var unitFactor: Decimal
  public var baseQuantity: Decimal
  /// Sayımın onay anındaki farkı (sayılan − mevcut).
  public var adjustment: Decimal?
  public var description: String?
  public var reason: String?
  public var performedBy: String?
  public var documentId: UUID?
  public var purchaseOrderId: UUID?
  public var purchaseReceiptId: UUID?
  public var reversalOfId: UUID?
  public var reversedById: UUID?
  public var approvedAt: Date?
  public var approvedBy: UUID?
  public var rejectedAt: Date?
  public var rejectReason: String?
  public var createdBy: UUID?
  public var createdAt: Date?
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), movementNo: String, kind: StockMovementKind, status: StockMovementStatus,
              movementDate: CalendarDate, materialId: UUID, warehouseId: UUID, targetWarehouseId: UUID? = nil,
              quantity: Decimal, unitId: UUID, unitFactor: Decimal = 1, baseQuantity: Decimal,
              adjustment: Decimal? = nil, description: String? = nil, reason: String? = nil,
              performedBy: String? = nil, documentId: UUID? = nil, purchaseOrderId: UUID? = nil,
              purchaseReceiptId: UUID? = nil, reversalOfId: UUID? = nil, reversedById: UUID? = nil,
              approvedAt: Date? = nil, approvedBy: UUID? = nil, rejectedAt: Date? = nil, rejectReason: String? = nil,
              createdBy: UUID? = nil, createdAt: Date? = nil, isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.movementNo = movementNo
    self.kind = kind
    self.status = status
    self.movementDate = movementDate
    self.materialId = materialId
    self.warehouseId = warehouseId
    self.targetWarehouseId = targetWarehouseId
    self.quantity = quantity
    self.unitId = unitId
    self.unitFactor = unitFactor
    self.baseQuantity = baseQuantity
    self.adjustment = adjustment
    self.description = description
    self.reason = reason
    self.performedBy = performedBy
    self.documentId = documentId
    self.purchaseOrderId = purchaseOrderId
    self.purchaseReceiptId = purchaseReceiptId
    self.reversalOfId = reversalOfId
    self.reversedById = reversedById
    self.approvedAt = approvedAt
    self.approvedBy = approvedBy
    self.rejectedAt = rejectedAt
    self.rejectReason = rejectReason
    self.createdBy = createdBy
    self.createdAt = createdAt
    self.isDemo = isDemo
    self.version = version
  }

  /// Satın alma teslimiyle oluşan giriş: tek başına iptal edilmez, teslim iptal edilir.
  public var isFromReceipt: Bool { purchaseReceiptId != nil }
  public var isReversed: Bool { reversedById != nil }
  /// Ters kayıtla iptal edilebilir mi (yetki ayrıca gerekir).
  public var canBeReversed: Bool { status == .onaylandi && kind != .tersKayit && !isReversed && !isFromReceipt }

  /// Depodaki stok etkisi (temel birim). Onaysız hareketin etkisi yoktur.
  public func effect(on warehouse: UUID) -> Decimal {
    guard status == .onaylandi else { return 0 }
    switch kind {
    case .giris, .iadeDepo: return warehouse == warehouseId ? baseQuantity : 0
    case .kullanim, .iadeTedarikci: return warehouse == warehouseId ? -baseQuantity : 0
    case .transfer:
      if warehouse == warehouseId { return -baseQuantity }
      return warehouse == targetWarehouseId ? baseQuantity : 0
    case .sayim: return warehouse == warehouseId ? (adjustment ?? 0) : 0
    case .tersKayit: return 0  // ters kaydın etkisi defterde; asıl hareketin tersidir
    }
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, status, quantity, adjustment, description, reason, version
    case movementNo = "movement_no", movementDate = "movement_date", materialId = "material_id"
    case warehouseId = "warehouse_id", targetWarehouseId = "target_warehouse_id", unitId = "unit_id"
    case unitFactor = "unit_factor", baseQuantity = "base_quantity", performedBy = "performed_by"
    case documentId = "document_id", purchaseOrderId = "purchase_order_id", purchaseReceiptId = "purchase_receipt_id"
    case reversalOfId = "reversal_of_id", reversedById = "reversed_by_id", approvedAt = "approved_at"
    case approvedBy = "approved_by", rejectedAt = "rejected_at", rejectReason = "reject_reason"
    case createdBy = "created_by", createdAt = "created_at", isDemo = "is_demo"
  }
}

/// Yeni hareket. `id` istemcide üretilir: aynı kimlikle aynı istek aynı
/// hareketi döner, farklı içerik `.conflict` alır.
public struct StockMovementDraft: Hashable, Sendable {
  public var id: UUID
  public var kind: StockMovementKind
  public var materialId: UUID
  public var warehouseId: UUID
  /// Sayımda sayılan miktar (temel birim; 0 olabilir).
  public var quantity: Decimal
  /// nil: malzemenin temel birimi.
  public var unitId: UUID?
  public var targetWarehouseId: UUID?
  public var movementDate: CalendarDate?
  public var description: String?
  public var reason: String?
  public var documentId: UUID?
  public var performedBy: String?

  public init(id: UUID = UUID(), kind: StockMovementKind, materialId: UUID, warehouseId: UUID, quantity: Decimal,
              unitId: UUID? = nil, targetWarehouseId: UUID? = nil, movementDate: CalendarDate? = nil,
              description: String? = nil, reason: String? = nil, documentId: UUID? = nil, performedBy: String? = nil) {
    self.id = id
    self.kind = kind
    self.materialId = materialId
    self.warehouseId = warehouseId
    self.quantity = quantity
    self.unitId = unitId
    self.targetWarehouseId = targetWarehouseId
    self.movementDate = movementDate
    self.description = description
    self.reason = reason
    self.documentId = documentId
    self.performedBy = performedBy
  }

  /// Sunucu kurallarının istemci tarafı ön kontrolü (asıl kontrol sunucudadır).
  public var validationMessage: String? {
    if kind == .tersKayit { return "Ters kayıt yalnızca iptal işlemiyle oluşur." }
    if kind == .sayim {
      if quantity < 0 { return "Sayılan miktar negatif olamaz." }
      if (reason.nilIfBlank?.count ?? 0) < 10 { return "Sayım düzeltmesi için en az 10 karakterlik gerekçe yazın." }
    } else if quantity <= 0 {
      return "Miktar sıfırdan büyük olmalı."
    }
    if kind == .transfer {
      guard let target = targetWarehouseId else { return "Hedef depoyu seçin." }
      if target == warehouseId { return "Kaynak ve hedef depo aynı olamaz." }
    } else if targetWarehouseId != nil {
      return "Hedef depo yalnızca transferde seçilir."
    }
    return nil
  }
}

public struct StockMovementFilter: Hashable, Sendable {
  /// Kaynak veya hedef depo.
  public var warehouseId: UUID?
  public var materialId: UUID?
  public var status: StockMovementStatus?
  public var purchaseOrderId: UUID?

  public init(warehouseId: UUID? = nil, materialId: UUID? = nil, status: StockMovementStatus? = nil,
              purchaseOrderId: UUID? = nil) {
    self.warehouseId = warehouseId
    self.materialId = materialId
    self.status = status
    self.purchaseOrderId = purchaseOrderId
  }
}

/// Defter toplamı (v_stock_balances). Temel birimdedir.
public struct StockBalance: Hashable, Codable, Sendable {
  public var warehouseId: UUID
  public var materialId: UUID
  public var quantity: Decimal
  public var entryCount: Int
  public var lastEntryDate: CalendarDate?
  public var isDemo: Bool

  public init(warehouseId: UUID, materialId: UUID, quantity: Decimal, entryCount: Int = 1,
              lastEntryDate: CalendarDate? = nil, isDemo: Bool = false) {
    self.warehouseId = warehouseId
    self.materialId = materialId
    self.quantity = quantity
    self.entryCount = entryCount
    self.lastEntryDate = lastEntryDate
    self.isDemo = isDemo
  }

  enum CodingKeys: String, CodingKey {
    case quantity
    case warehouseId = "warehouse_id", materialId = "material_id", entryCount = "entry_count"
    case lastEntryDate = "last_entry_date", isDemo = "is_demo"
  }
}

/// Onay bekleyen hareketlerin etkisi (stoka işlenmemiştir).
public struct StockPending: Hashable, Codable, Sendable {
  public var warehouseId: UUID
  public var materialId: UUID
  public var pendingOut: Decimal
  public var pendingIn: Decimal
  public var movementCount: Int

  public init(warehouseId: UUID, materialId: UUID, pendingOut: Decimal, pendingIn: Decimal, movementCount: Int) {
    self.warehouseId = warehouseId
    self.materialId = materialId
    self.pendingOut = pendingOut
    self.pendingIn = pendingIn
    self.movementCount = movementCount
  }

  enum CodingKeys: String, CodingKey {
    case warehouseId = "warehouse_id", materialId = "material_id", pendingOut = "pending_out"
    case pendingIn = "pending_in", movementCount = "movement_count"
  }
}

/// Depo dönem özeti (stock_summary). Ters kayıtlar asıl hareketin türünde sayılır.
public struct StockSummaryRow: Hashable, Codable, Sendable {
  public var materialId: UUID
  public var opening: Decimal
  public var received: Decimal
  public var used: Decimal
  /// Net transfer (gelen − giden).
  public var transferred: Decimal
  public var returnedToStock: Decimal
  public var returnedToVendor: Decimal
  public var adjusted: Decimal
  public var closing: Decimal

  public init(materialId: UUID, opening: Decimal = 0, received: Decimal = 0, used: Decimal = 0, transferred: Decimal = 0,
              returnedToStock: Decimal = 0, returnedToVendor: Decimal = 0, adjusted: Decimal = 0, closing: Decimal = 0) {
    self.materialId = materialId
    self.opening = opening
    self.received = received
    self.used = used
    self.transferred = transferred
    self.returnedToStock = returnedToStock
    self.returnedToVendor = returnedToVendor
    self.adjusted = adjusted
    self.closing = closing
  }

  enum CodingKeys: String, CodingKey {
    case opening, received, used, transferred, adjusted, closing
    case materialId = "material_id", returnedToStock = "returned_to_stock", returnedToVendor = "returned_to_vendor"
  }
}

// MARK: Satın alma

public enum PurchaseOrderStatus: String, Codable, CaseIterable, Sendable {
  case taslak
  case onaylandi
  case kismiTeslim = "kismi_teslim"
  case tamamlandi
  case iptal

  public var title: String {
    switch self {
    case .taslak: "Taslak"
    case .onaylandi: "Onaylı"
    case .kismiTeslim: "Kısmen teslim"
    case .tamamlandi: "Tamamlandı"
    case .iptal: "İptal"
    }
  }

  /// Teslim alınabilir durumlar.
  public var canReceive: Bool { self == .onaylandi || self == .kismiTeslim }
  public var isEditable: Bool { self == .taslak }
}

public enum PurchaseOrderAction: String, Codable, Sendable {
  case onayla, iptal, kapat

  public var title: String {
    switch self {
    case .onayla: "Onayla"
    case .iptal: "İptal et"
    case .kapat: "Eksik teslimle kapat"
    }
  }

  public var requiresReason: Bool { self != .onayla }
}

public struct PurchaseOrder: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var orderNo: String
  public var status: PurchaseOrderStatus
  public var cariAccountId: UUID
  public var warehouseId: UUID
  /// Depodan türetilir (genel depoda nil).
  public var projectId: UUID?
  public var orderDate: CalendarDate
  public var expectedDate: CalendarDate?
  public var currency: String
  public var description: String?
  public var notes: String?
  public var approvedAt: Date?
  public var approvedBy: UUID?
  public var closedAt: Date?
  public var closeReason: String?
  public var cancelledAt: Date?
  public var cancelReason: String?
  public var createdBy: UUID?
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), orderNo: String, status: PurchaseOrderStatus = .taslak, cariAccountId: UUID,
              warehouseId: UUID, projectId: UUID? = nil, orderDate: CalendarDate, expectedDate: CalendarDate? = nil,
              currency: String = "TRY", description: String? = nil, notes: String? = nil, approvedAt: Date? = nil,
              approvedBy: UUID? = nil, closedAt: Date? = nil, closeReason: String? = nil, cancelledAt: Date? = nil,
              cancelReason: String? = nil, createdBy: UUID? = nil, isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.orderNo = orderNo
    self.status = status
    self.cariAccountId = cariAccountId
    self.warehouseId = warehouseId
    self.projectId = projectId
    self.orderDate = orderDate
    self.expectedDate = expectedDate
    self.currency = currency
    self.description = description
    self.notes = notes
    self.approvedAt = approvedAt
    self.approvedBy = approvedBy
    self.closedAt = closedAt
    self.closeReason = closeReason
    self.cancelledAt = cancelledAt
    self.cancelReason = cancelReason
    self.createdBy = createdBy
    self.isDemo = isDemo
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, status, currency, description, notes, version
    case orderNo = "order_no", cariAccountId = "cari_account_id", warehouseId = "warehouse_id"
    case projectId = "project_id", orderDate = "order_date", expectedDate = "expected_date"
    case approvedAt = "approved_at", approvedBy = "approved_by", closedAt = "closed_at", closeReason = "close_reason"
    case cancelledAt = "cancelled_at", cancelReason = "cancel_reason", createdBy = "created_by", isDemo = "is_demo"
  }
}

/// Sipariş satırı ve teslim durumu (v_purchase_order_line_status). Fiyat
/// burada yoktur: yalnızca satinalma.read ile ayrıca okunur.
public struct PurchaseOrderLine: Identifiable, Hashable, Codable, Sendable {
  public var id: UUID
  public var orderId: UUID
  public var lineNo: Int
  public var materialId: UUID
  public var unitId: UUID
  public var quantity: Decimal
  public var unitFactor: Decimal
  public var baseQuantity: Decimal
  public var note: String?
  public var receivedBaseQuantity: Decimal
  public var remainingBaseQuantity: Decimal

  public init(id: UUID = UUID(), orderId: UUID, lineNo: Int, materialId: UUID, unitId: UUID, quantity: Decimal,
              unitFactor: Decimal = 1, baseQuantity: Decimal? = nil, note: String? = nil,
              receivedBaseQuantity: Decimal = 0, remainingBaseQuantity: Decimal? = nil) {
    self.id = id
    self.orderId = orderId
    self.lineNo = lineNo
    self.materialId = materialId
    self.unitId = unitId
    self.quantity = quantity
    self.unitFactor = unitFactor
    let base = baseQuantity ?? InventoryMath.toBase(quantity, factor: unitFactor)
    self.baseQuantity = base
    self.note = note
    self.receivedBaseQuantity = receivedBaseQuantity
    self.remainingBaseQuantity = remainingBaseQuantity ?? (base - receivedBaseQuantity)
  }

  /// Kalan miktar sipariş biriminde.
  public var remainingQuantity: Decimal { InventoryMath.fromBase(remainingBaseQuantity, factor: unitFactor) }
  public var receivedQuantity: Decimal { InventoryMath.fromBase(receivedBaseQuantity, factor: unitFactor) }
  public var isFullyReceived: Bool { remainingBaseQuantity <= 0 }

  enum CodingKeys: String, CodingKey {
    case id = "order_line_id"
    case quantity, note
    case orderId = "order_id", lineNo = "line_no", materialId = "material_id", unitId = "unit_id"
    case unitFactor = "unit_factor", baseQuantity = "base_quantity"
    case receivedBaseQuantity = "received_base_quantity", remainingBaseQuantity = "remaining_base_quantity"
  }
}

public struct PurchaseOrderLineDraft: Identifiable, Hashable, Sendable {
  public var id: UUID
  public var materialId: UUID
  public var quantity: Decimal
  /// nil: malzemenin temel birimi.
  public var unitId: UUID?
  /// Bilgi amaçlı birim fiyat; borç doğurmaz.
  public var unitPrice: Decimal?
  public var note: String?

  public init(id: UUID = UUID(), materialId: UUID, quantity: Decimal, unitId: UUID? = nil, unitPrice: Decimal? = nil,
              note: String? = nil) {
    self.id = id
    self.materialId = materialId
    self.quantity = quantity
    self.unitId = unitId
    self.unitPrice = unitPrice
    self.note = note
  }
}

public struct PurchaseOrderDraft: Hashable, Sendable {
  public var cariAccountId: UUID
  public var warehouseId: UUID
  public var lines: [PurchaseOrderLineDraft]
  public var orderDate: CalendarDate?
  public var expectedDate: CalendarDate?
  public var currency: String
  public var description: String?
  public var notes: String?

  public init(cariAccountId: UUID, warehouseId: UUID, lines: [PurchaseOrderLineDraft], orderDate: CalendarDate? = nil,
              expectedDate: CalendarDate? = nil, currency: String = "TRY", description: String? = nil,
              notes: String? = nil) {
    self.cariAccountId = cariAccountId
    self.warehouseId = warehouseId
    self.lines = lines
    self.orderDate = orderDate
    self.expectedDate = expectedDate
    self.currency = currency
    self.description = description
    self.notes = notes
  }

  public var validationMessage: String? {
    if lines.isEmpty { return "En az bir malzeme satırı ekleyin." }
    if lines.contains(where: { $0.quantity <= 0 }) { return "Satır miktarları sıfırdan büyük olmalı." }
    if lines.contains(where: { ($0.unitPrice ?? 0) < 0 }) { return "Birim fiyat negatif olamaz." }
    if Set(lines.map(\.id)).count != lines.count { return "Aynı satır iki kez eklenemez." }
    if let expected = expectedDate, let order = orderDate, expected < order {
      return "Beklenen teslim tarihi sipariş tarihinden önce olamaz."
    }
    if currency.count != 3 || currency.uppercased() != currency { return "Para birimi üç büyük harf olmalı (TRY)." }
    return nil
  }
}

/// Satır fiyatı (purchase_order_prices; yalnızca satinalma.read).
public struct PurchaseOrderLinePrice: Hashable, Codable, Sendable {
  public var orderLineId: UUID
  public var unitPrice: Decimal?
  public var lineTotal: Decimal?

  public init(orderLineId: UUID, unitPrice: Decimal?, lineTotal: Decimal?) {
    self.orderLineId = orderLineId
    self.unitPrice = unitPrice
    self.lineTotal = lineTotal
  }

  enum CodingKeys: String, CodingKey {
    case orderLineId = "order_line_id", unitPrice = "unit_price", lineTotal = "line_total"
  }
}

public enum PurchaseRecordStatus: String, Codable, Sendable {
  case aktif, iptal
}

/// Teslim alma (irsaliye). Her satır bir stok girişi açar; aynı kimlikle
/// tekrar gönderim ikinci giriş açmaz.
public struct PurchaseReceipt: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var receiptNo: String
  public var orderId: UUID
  public var warehouseId: UUID
  public var receiptDate: CalendarDate
  public var waybillNo: String?
  public var note: String?
  public var documentId: UUID?
  public var status: PurchaseRecordStatus
  public var cancelledAt: Date?
  public var cancelReason: String?
  public var createdBy: UUID?
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), receiptNo: String, orderId: UUID, warehouseId: UUID, receiptDate: CalendarDate,
              waybillNo: String? = nil, note: String? = nil, documentId: UUID? = nil, status: PurchaseRecordStatus = .aktif,
              cancelledAt: Date? = nil, cancelReason: String? = nil, createdBy: UUID? = nil, isDemo: Bool = false,
              version: Int = 1) {
    self.id = id
    self.receiptNo = receiptNo
    self.orderId = orderId
    self.warehouseId = warehouseId
    self.receiptDate = receiptDate
    self.waybillNo = waybillNo
    self.note = note
    self.documentId = documentId
    self.status = status
    self.cancelledAt = cancelledAt
    self.cancelReason = cancelReason
    self.createdBy = createdBy
    self.isDemo = isDemo
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, note, status, version
    case receiptNo = "receipt_no", orderId = "order_id", warehouseId = "warehouse_id", receiptDate = "receipt_date"
    case waybillNo = "waybill_no", documentId = "document_id", cancelledAt = "cancelled_at"
    case cancelReason = "cancel_reason", createdBy = "created_by", isDemo = "is_demo"
  }
}

public struct PurchaseReceiptLine: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var receiptId: UUID
  public var orderLineId: UUID
  /// Sipariş satırının biriminde.
  public var quantity: Decimal
  public var baseQuantity: Decimal
  public var stockMovementId: UUID

  public init(id: UUID = UUID(), receiptId: UUID, orderLineId: UUID, quantity: Decimal, baseQuantity: Decimal,
              stockMovementId: UUID) {
    self.id = id
    self.receiptId = receiptId
    self.orderLineId = orderLineId
    self.quantity = quantity
    self.baseQuantity = baseQuantity
    self.stockMovementId = stockMovementId
  }

  enum CodingKeys: String, CodingKey {
    case id, quantity
    case receiptId = "receipt_id", orderLineId = "order_line_id", baseQuantity = "base_quantity"
    case stockMovementId = "stock_movement_id"
  }
}

public struct PurchaseReceiptLineInput: Hashable, Sendable {
  public var orderLineId: UUID
  /// Sipariş satırının biriminde.
  public var quantity: Decimal

  public init(orderLineId: UUID, quantity: Decimal) {
    self.orderLineId = orderLineId
    self.quantity = quantity
  }
}

public struct PurchaseReceiptDraft: Hashable, Sendable {
  public var id: UUID
  public var orderId: UUID
  public var lines: [PurchaseReceiptLineInput]
  public var receiptDate: CalendarDate?
  public var waybillNo: String?
  public var note: String?
  public var documentId: UUID?
  public var performedBy: String?

  public init(id: UUID = UUID(), orderId: UUID, lines: [PurchaseReceiptLineInput], receiptDate: CalendarDate? = nil,
              waybillNo: String? = nil, note: String? = nil, documentId: UUID? = nil, performedBy: String? = nil) {
    self.id = id
    self.orderId = orderId
    self.lines = lines
    self.receiptDate = receiptDate
    self.waybillNo = waybillNo
    self.note = note
    self.documentId = documentId
    self.performedBy = performedBy
  }

  /// Sıfır satırlar gönderilmez (formda boş bırakılan satırlar).
  public var nonZeroLines: [PurchaseReceiptLineInput] { lines.filter { $0.quantity != 0 } }
}

/// Gider belgesi (Aşama 5) ile sipariş arasındaki bilgi bağlantısı. Yeni
/// finans kaydı açmaz; bir gider en fazla bir siparişe bağlanır.
public struct PurchaseOrderExpenseLink: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var orderId: UUID
  public var financeDocumentId: UUID
  public var note: String?
  public var status: PurchaseRecordStatus
  public var cancelReason: String?

  public init(id: UUID = UUID(), orderId: UUID, financeDocumentId: UUID, note: String? = nil,
              status: PurchaseRecordStatus = .aktif, cancelReason: String? = nil) {
    self.id = id
    self.orderId = orderId
    self.financeDocumentId = financeDocumentId
    self.note = note
    self.status = status
    self.cancelReason = cancelReason
  }

  enum CodingKeys: String, CodingKey {
    case id, note, status
    case orderId = "order_id", financeDocumentId = "finance_document_id", cancelReason = "cancel_reason"
  }
}

/// Arşivdeki belgenin (Aşama 6) siparişe bağlantısı.
public struct PurchaseOrderDocumentLink: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var orderId: UUID
  public var documentId: UUID
  public var status: PurchaseRecordStatus
  public var cancelReason: String?

  public init(id: UUID = UUID(), orderId: UUID, documentId: UUID, status: PurchaseRecordStatus = .aktif,
              cancelReason: String? = nil) {
    self.id = id
    self.orderId = orderId
    self.documentId = documentId
    self.status = status
    self.cancelReason = cancelReason
  }

  enum CodingKeys: String, CodingKey {
    case id, status
    case orderId = "order_id", documentId = "document_id", cancelReason = "cancel_reason"
  }
}

public struct PurchaseOrderEvent: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var orderId: UUID
  public var action: String
  public var fromStatus: String?
  public var toStatus: String?
  public var reason: String?
  public var actorId: UUID?
  public var occurredAt: Date?

  public init(id: UUID = UUID(), orderId: UUID, action: String, fromStatus: String? = nil, toStatus: String? = nil,
              reason: String? = nil, actorId: UUID? = nil, occurredAt: Date? = Date()) {
    self.id = id
    self.orderId = orderId
    self.action = action
    self.fromStatus = fromStatus
    self.toStatus = toStatus
    self.reason = reason
    self.actorId = actorId
    self.occurredAt = occurredAt
  }

  public var title: String {
    switch action {
    case "olustur": "Sipariş oluşturuldu"
    case "guncelle": "Taslak güncellendi"
    case "onayla": "Onaylandı"
    case "teslim": "Teslim alındı"
    case "teslim_iptal": "Teslim iptal edildi"
    case "kapat": "Eksik teslimle kapatıldı"
    case "iptal": "İptal edildi"
    case "gider_bagla": "Gider bağlandı"
    case "gider_bag_kaldir": "Gider bağlantısı kaldırıldı"
    case "belge_bagla": "Belge bağlandı"
    case "belge_bag_kaldir": "Belge bağlantısı kaldırıldı"
    default: action
    }
  }

  enum CodingKeys: String, CodingKey {
    case id, action, reason
    case orderId = "order_id", fromStatus = "from_status", toStatus = "to_status", actorId = "actor_id"
    case occurredAt = "occurred_at"
  }
}

// MARK: Hesap kuralları

/// Sunucuyla aynı miktar kuralları (numeric(14,3), oran numeric(18,6)).
public enum InventoryMath {
  /// Miktar ondalık hanesi (stok miktarları üç haneyle saklanır).
  public static let quantityScale = 3

  public static func round(_ value: Decimal, scale: Int = quantityScale) -> Decimal {
    var input = value
    var output = Decimal()
    NSDecimalRound(&output, &input, scale, .plain)
    return output
  }

  /// Girilen birimdeki miktarı temel birime çevirir (1 birim = factor temel birim).
  public static func toBase(_ quantity: Decimal, factor: Decimal) -> Decimal { round(quantity * factor) }

  public static func fromBase(_ base: Decimal, factor: Decimal) -> Decimal {
    guard factor != 0 else { return 0 }
    return round(base / factor)
  }

  /// Miktar birimin izin verdiği ondalık haneye uyuyor mu.
  public static func fits(_ quantity: Decimal, decimals: Int) -> Bool { round(quantity, scale: decimals) == quantity }

  /// Malzemenin birim oranı: temel birimde 1, aksi halde yalnızca etkin ve
  /// açıkça tanımlı oran (tahmin yok). Bulunamazsa nil.
  public static func factor(materialId: UUID, baseUnitId: UUID, unitId: UUID,
                            conversions: [MaterialUnitConversion]) -> Decimal? {
    if unitId == baseUnitId { return 1 }
    return conversions.first { $0.materialId == materialId && $0.unitId == unitId && $0.isActive }?.factor
  }

  /// Sipariş durumunun satırlardan türetilmesi (onaylı siparişte).
  public static func orderStatus(current: PurchaseOrderStatus, lines: [PurchaseOrderLine]) -> PurchaseOrderStatus {
    guard current.canReceive || current == .tamamlandi else { return current }
    if !lines.isEmpty, lines.allSatisfy(\.isFullyReceived) { return .tamamlandi }
    return lines.contains { $0.receivedBaseQuantity > 0 } ? .kismiTeslim : .onaylandi
  }

  /// Teslim edilebilir mi: hiçbir satır kalan miktarı aşmamalı.
  public static func receiptOverflow(_ inputs: [PurchaseReceiptLineInput], lines: [PurchaseOrderLine]) -> PurchaseOrderLine? {
    for input in inputs {
      guard let line = lines.first(where: { $0.id == input.orderLineId }) else { continue }
      if toBase(input.quantity, factor: line.unitFactor) > line.remainingBaseQuantity { return line }
    }
    return nil
  }

  /// Satır tutarı (bilgi amaçlı; finans kaydı değildir).
  public static func lineTotal(quantity: Decimal, unitPrice: Decimal?) -> Decimal? {
    unitPrice.map { round(quantity * $0, scale: 2) }
  }
}
