import Foundation
import Observation

// Malzeme, stok ve satın alma ekranlarının view model'leri (Aşama 7).
// Stok miktarı sunucudaki defterden okunur; burada hesaplanmaz, yalnızca
// gösterilir. Formlar kimliği istemcide üretir ve başarılı olana kadar aynı
// kimliği kullanır: bağlantı koptuğunda tekrar gönderim ikinci hareket açmaz.
// Hiçbir ekran kasa, banka veya toplam para göstermez.

public extension AccessControl {
  /// Depo veya sipariş kapsamında izin: proje deposunda proje izni, genel depoda genel izin.
  func can(_ key: PermissionKey, scope project: UUID?) -> Bool {
    project.map { can(key, in: $0) } ?? can(key)
  }
}

// MARK: - Katalog sözlüğü

/// Ekranların ad ve birim göstermek için paylaştığı katalog verisi.
public struct InventoryLookup: Sendable {
  public var units: [UUID: MaterialUnit] = [:]
  public var categories: [UUID: MaterialCategory] = [:]
  public var materials: [UUID: Material] = [:]
  public var warehouses: [UUID: Warehouse] = [:]
  public var conversions: [MaterialUnitConversion] = []

  public init() {}

  public init(units: [MaterialUnit], categories: [MaterialCategory], materials: [Material], warehouses: [Warehouse],
              conversions: [MaterialUnitConversion] = []) {
    self.units = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    self.categories = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    self.materials = Dictionary(materials.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    self.warehouses = Dictionary(warehouses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    self.conversions = conversions
  }

  static func load(_ repo: InventoryRepository, includeInactive: Bool = true) async throws -> InventoryLookup {
    async let units = repo.units(includeInactive: true)
    async let categories = repo.categories(includeInactive: true)
    async let materials = repo.materials(search: nil, categoryId: nil, includeInactive: includeInactive)
    async let warehouses = repo.warehouses(projectId: nil, includeInactive: true)
    async let conversions = repo.conversions(materialId: nil)
    return try await InventoryLookup(units: units, categories: categories, materials: materials, warehouses: warehouses,
                                     conversions: conversions)
  }

  public func materialName(_ id: UUID) -> String { materials[id]?.name ?? "Malzeme" }
  public func warehouseName(_ id: UUID?) -> String { id.flatMap { warehouses[$0]?.name } ?? "Depo" }
  public func baseUnit(of material: UUID) -> MaterialUnit? { materials[material].flatMap { units[$0.baseUnitId] } }

  /// "110 adet", "2,5 ton".
  public func format(_ quantity: Decimal, unit: UUID?) -> String {
    let u = unit.flatMap { units[$0] }
    let text = DecimalInput.format(quantity, maxFractionDigits: u?.decimals ?? InventoryMath.quantityScale)
    return u.map { "\(text) \($0.symbol)" } ?? text
  }

  /// Temel birimde miktar.
  public func formatBase(_ quantity: Decimal, material: UUID) -> String {
    format(quantity, unit: materials[material]?.baseUnitId)
  }

  /// Malzemede kullanılabilen birimler: temel birim ve açık dönüşüm oranı tanımlı olanlar.
  public func allowedUnits(for material: UUID) -> [MaterialUnit] {
    guard let m = materials[material], let base = units[m.baseUnitId] else { return [] }
    let extra = conversions.filter { $0.materialId == material && $0.isActive }.compactMap { units[$0.unitId] }
    return [base] + extra.sorted { $0.sortOrder < $1.sortOrder }
  }

  public func factor(material: UUID, unit: UUID) -> Decimal? {
    guard let m = materials[material] else { return nil }
    return InventoryMath.factor(materialId: material, baseUnitId: m.baseUnitId, unitId: unit, conversions: conversions)
  }
}

// MARK: - Malzeme kataloğu

@MainActor
@Observable
public final class MaterialCatalogViewModel {
  public private(set) var lookup = InventoryLookup()
  public private(set) var materials: [Material] = []
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?
  public var searchText = ""
  public var categoryId: UUID?
  public var showInactive = false

  public let access: AccessControl
  private let repositories: Repositories

  public init(access: AccessControl, repositories: Repositories) {
    self.access = access
    self.repositories = repositories
  }

  public var canManage: Bool { access.canAnywhere(.malzemeManage) }

  public var categories: [MaterialCategory] {
    lookup.categories.values.filter(\.isActive).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
  }

  public var filtered: [Material] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased(with: Money.locale)
    return materials.filter { m in
      if !showInactive, !m.isActive { return false }
      if let categoryId, m.categoryId != categoryId { return false }
      guard !query.isEmpty else { return true }
      return [m.name, m.code, m.description ?? "", lookup.categories[m.categoryId]?.name ?? ""]
        .joined(separator: " ").lowercased(with: Money.locale).contains(query)
    }
  }

  /// Kategoriye göre gruplu liste (kategori sırasıyla).
  public var grouped: [(category: MaterialCategory?, materials: [Material])] {
    let groups = Dictionary(grouping: filtered) { $0.categoryId }
    return groups.map { (lookup.categories[$0.key], $0.value.sorted { $0.name < $1.name }) }
      .sorted { ($0.0?.sortOrder ?? 999, $0.0?.name ?? "") < ($1.0?.sortOrder ?? 999, $1.0?.name ?? "") }
  }

  public func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      lookup = try await InventoryLookup.load(repositories.inventory)
      materials = lookup.materials.values.sorted { $0.name < $1.name }
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - Malzeme formu ve dönüşüm oranları

@MainActor
@Observable
public final class MaterialFormViewModel {
  public var name = ""
  public var code = ""
  public var categoryId: UUID?
  public var baseUnitId: UUID?
  public var description = ""
  public var isActive = true
  public private(set) var units: [MaterialUnit] = []
  public private(set) var categories: [MaterialCategory] = []
  public private(set) var conversions: [MaterialUnitConversion] = []
  public private(set) var material: Material?
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?

  // Yeni dönüşüm oranı
  public var conversionUnitId: UUID?
  public var conversionFactorText = ""
  public var conversionNote = ""

  private var pendingId = UUID()
  private var pendingConversionId = UUID()
  private let repositories: Repositories
  public let access: AccessControl

  public init(material: Material? = nil, access: AccessControl, repositories: Repositories) {
    self.material = material
    self.access = access
    self.repositories = repositories
    if let material {
      name = material.name
      code = material.code
      categoryId = material.categoryId
      baseUnitId = material.baseUnitId
      description = material.description ?? ""
      isActive = material.isActive
    }
  }

  public var isNew: Bool { material == nil }
  public var canManage: Bool { access.canAnywhere(.malzemeManage) }

  public func unitName(_ id: UUID) -> String { units.first { $0.id == id }?.name ?? "Birim" }
  public func unitSymbol(_ id: UUID?) -> String { id.flatMap { id in units.first { $0.id == id }?.symbol } ?? "" }

  /// Dönüşüm tanımlanabilecek birimler (temel birim ve etkin oranı olanlar hariç).
  public var conversionCandidates: [MaterialUnit] {
    units.filter { u in
      u.isActive && u.id != (material?.baseUnitId ?? baseUnitId)
        && !conversions.contains { $0.unitId == u.id && $0.isActive }
    }
  }

  public func load() async {
    do {
      async let units = repositories.inventory.units(includeInactive: false)
      async let categories = repositories.inventory.categories(includeInactive: false)
      self.units = try await units
      self.categories = try await categories
      if let id = material?.id { conversions = try await repositories.inventory.conversions(materialId: id) }
      if categoryId == nil { categoryId = self.categories.first?.id }
      if baseUnitId == nil { baseUnitId = self.units.first?.id }
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  public var draft: MaterialDraft? {
    guard let categoryId, let baseUnitId else { return nil }
    return MaterialDraft(name: name, categoryId: categoryId, baseUnitId: baseUnitId, code: code.nilIfBlank,
                         description: description.nilIfBlank, isActive: isActive)
  }

  public var validationMessage: String? {
    guard let draft else { return "Kategori ve birim seçin." }
    return draft.validationMessage
  }

  @discardableResult
  public func save() async -> Material? {
    guard let draft else {
      errorMessage = "Kategori ve birim seçin."
      return nil
    }
    if let validation = draft.validationMessage {
      errorMessage = validation
      return nil
    }
    isSaving = true
    defer { isSaving = false }
    do {
      let saved = try await repositories.inventory.saveMaterial(id: material?.id ?? pendingId, draft: draft,
                                                                expectedVersion: material?.version)
      material = saved
      pendingId = UUID()
      errorMessage = nil
      return saved
    } catch {
      errorMessage = message(for: error)
      return nil
    }
  }

  /// "1 ton = 1000 kg" biçiminde açık oran. Tahmin yapılmaz.
  public func addConversion() async {
    guard let materialId = material?.id, let unitId = conversionUnitId else {
      errorMessage = "Önce malzemeyi kaydedin ve birimi seçin."
      return
    }
    guard let factor = DecimalInput.parse(conversionFactorText, maxFractionDigits: 6), factor > 0 else {
      errorMessage = "Oran sıfırdan büyük bir sayı olmalı (en çok 6 ondalık)."
      return
    }
    do {
      let saved = try await repositories.inventory.saveConversion(
        MaterialUnitConversion(id: pendingConversionId, materialId: materialId, unitId: unitId, factor: factor,
                               note: conversionNote.nilIfBlank))
      conversions.append(saved)
      pendingConversionId = UUID()
      conversionUnitId = nil
      conversionFactorText = ""
      conversionNote = ""
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func deactivate(_ conversion: MaterialUnitConversion) async {
    do {
      let updated = try await repositories.inventory.setConversionActive(id: conversion.id, isActive: false)
      if let index = conversions.firstIndex(where: { $0.id == updated.id }) { conversions[index] = updated }
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - Malzeme detayı (depolardaki miktarlar)

@MainActor
@Observable
public final class MaterialDetailViewModel {
  public private(set) var material: Material
  public private(set) var lookup = InventoryLookup()
  public private(set) var balances: [StockBalance] = []
  public private(set) var movements: [StockMovement] = []
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  public let access: AccessControl
  private let repositories: Repositories

  public init(material: Material, access: AccessControl, repositories: Repositories) {
    self.material = material
    self.access = access
    self.repositories = repositories
  }

  public var canManage: Bool { access.canAnywhere(.malzemeManage) }
  public var conversions: [MaterialUnitConversion] {
    lookup.conversions.filter { $0.materialId == material.id }.sorted { $0.isActive && !$1.isActive }
  }

  public func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      lookup = try await InventoryLookup.load(repositories.inventory)
      material = lookup.materials[material.id] ?? material
      balances = try await repositories.inventory.balances(warehouseId: nil)
        .filter { $0.materialId == material.id && $0.quantity != 0 }
      if access.canAnywhere(.stokRead) {
        movements = try await Array(repositories.inventory.movements(filter: StockMovementFilter(materialId: material.id))
          .prefix(30))
      }
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - Stok durumu (depo seçimi)

@MainActor
@Observable
public final class StockOverviewViewModel {
  public struct Row: Identifiable, Hashable, Sendable {
    public var materialId: UUID
    public var quantity: Decimal
    public var pendingOut: Decimal
    public var pendingIn: Decimal
    public var lastEntryDate: CalendarDate?
    public var id: UUID { materialId }
  }

  public private(set) var lookup = InventoryLookup()
  public private(set) var warehouses: [Warehouse] = []
  public private(set) var rows: [Row] = []
  public private(set) var pendingMovements: [StockMovement] = []
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?
  public var selectedWarehouseId: UUID?
  public var searchText = ""
  public var showEmpty = false

  /// nil: tüm projelerin ve genel depoların listesi.
  public let projectId: UUID?
  public let access: AccessControl
  private let repositories: Repositories

  public init(projectId: UUID? = nil, access: AccessControl, repositories: Repositories) {
    self.projectId = projectId
    self.access = access
    self.repositories = repositories
  }

  public var selectedWarehouse: Warehouse? { selectedWarehouseId.flatMap { lookup.warehouses[$0] } }
  private var scope: UUID? { selectedWarehouse?.projectId }

  public var canRead: Bool { selectedWarehouse.map { access.can(.stokRead, scope: $0.projectId) } ?? false }
  public var canWrite: Bool { selectedWarehouse.map { $0.isActive && access.can(.stokWrite, scope: $0.projectId) } ?? false }
  public var canApprove: Bool { selectedWarehouse.map { access.can(.stokApprove, scope: $0.projectId) } ?? false }

  public var filteredRows: [Row] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased(with: Money.locale)
    return rows.filter { row in
      if !showEmpty, row.quantity == 0, row.pendingIn == 0, row.pendingOut == 0 { return false }
      guard !query.isEmpty, let m = lookup.materials[row.materialId] else { return true }
      return "\(m.name) \(m.code)".lowercased(with: Money.locale).contains(query)
    }
  }

  public func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      lookup = try await InventoryLookup.load(repositories.inventory)
      warehouses = try await repositories.inventory.warehouses(projectId: projectId, includeInactive: false)
        .filter { access.can(.stokRead, scope: $0.projectId) }
      if selectedWarehouseId == nil || !warehouses.contains(where: { $0.id == selectedWarehouseId }) {
        selectedWarehouseId = warehouses.first { $0.isDefault }?.id ?? warehouses.first?.id
      }
      try await loadStock()
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func select(_ warehouseId: UUID) async {
    selectedWarehouseId = warehouseId
    do {
      try await loadStock()
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  private func loadStock() async throws {
    guard let warehouseId = selectedWarehouseId else {
      rows = []
      pendingMovements = []
      return
    }
    async let balances = repositories.inventory.balances(warehouseId: warehouseId)
    async let pending = repositories.inventory.pending(warehouseId: warehouseId)
    async let movements = repositories.inventory.movements(filter: StockMovementFilter(warehouseId: warehouseId,
                                                                                         status: .bekliyor))
    var byMaterial: [UUID: Row] = [:]
    for b in try await balances {
      byMaterial[b.materialId] = Row(materialId: b.materialId, quantity: b.quantity, pendingOut: 0, pendingIn: 0,
                                     lastEntryDate: b.lastEntryDate)
    }
    for p in try await pending {
      var row = byMaterial[p.materialId] ?? Row(materialId: p.materialId, quantity: 0, pendingOut: 0, pendingIn: 0)
      row.pendingOut = p.pendingOut
      row.pendingIn = p.pendingIn
      byMaterial[p.materialId] = row
    }
    if showEmpty {
      for m in lookup.materials.values where m.isActive && byMaterial[m.id] == nil {
        byMaterial[m.id] = Row(materialId: m.id, quantity: 0, pendingOut: 0, pendingIn: 0)
      }
    }
    rows = byMaterial.values.sorted { lookup.materialName($0.materialId) < lookup.materialName($1.materialId) }
    pendingMovements = try await movements
  }
}

// MARK: - Hareket geçmişi

@MainActor
@Observable
public final class StockMovementListViewModel {
  public private(set) var lookup = InventoryLookup()
  public private(set) var movements: [StockMovement] = []
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?
  public var statusFilter: StockMovementStatus?
  public var kindFilter: StockMovementKind?

  public let warehouseId: UUID?
  public let materialId: UUID?
  public let access: AccessControl
  private let repositories: Repositories

  public init(warehouseId: UUID? = nil, materialId: UUID? = nil, access: AccessControl, repositories: Repositories) {
    self.warehouseId = warehouseId
    self.materialId = materialId
    self.access = access
    self.repositories = repositories
  }

  public var filtered: [StockMovement] {
    movements.filter { m in
      (statusFilter == nil || m.status == statusFilter) && (kindFilter == nil || m.kind == kindFilter)
    }
  }

  /// Hareketin seçili depodaki işaretli etkisi (temel birim).
  public func signedQuantity(_ m: StockMovement) -> Decimal {
    let base = m.kind == .sayim ? (m.adjustment ?? 0) : m.baseQuantity
    if m.kind == .tersKayit { return 0 }
    if m.kind == .sayim { return base }
    if m.kind == .transfer, let warehouseId { return m.targetWarehouseId == warehouseId ? base : -base }
    return m.kind.decreasesSource ? -base : base
  }

  public func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      lookup = try await InventoryLookup.load(repositories.inventory)
      movements = try await repositories.inventory.movements(
        filter: StockMovementFilter(warehouseId: warehouseId, materialId: materialId))
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - Hareket detayı ve onay

@MainActor
@Observable
public final class StockMovementDetailViewModel {
  public private(set) var movement: StockMovement
  public private(set) var reversal: StockMovement?
  public private(set) var original: StockMovement?
  public private(set) var lookup = InventoryLookup()
  public private(set) var isWorking = false
  public private(set) var errorMessage: String?
  public var reason = ""

  private var reversalId = UUID()
  public let access: AccessControl
  private let repositories: Repositories

  public init(movement: StockMovement, access: AccessControl, repositories: Repositories) {
    self.movement = movement
    self.access = access
    self.repositories = repositories
  }

  private func scope(_ warehouse: UUID?) -> UUID? { warehouse.flatMap { lookup.warehouses[$0]?.projectId } }

  private func allWarehouses(_ key: PermissionKey) -> Bool {
    let source = access.can(key, scope: scope(movement.warehouseId))
    let target = movement.targetWarehouseId.map { access.can(key, scope: scope($0)) } ?? true
    return source && target
  }

  public var canApprove: Bool { movement.status == .bekliyor && allWarehouses(.stokApprove) }
  public var canReject: Bool {
    guard movement.status == .bekliyor else { return false }
    let own = movement.createdBy != nil && movement.createdBy == currentUserId
      && access.can(.stokWrite, scope: scope(movement.warehouseId))
    return own || access.can(.stokApprove, scope: scope(movement.warehouseId))
  }
  public var canReverse: Bool { movement.canBeReversed && allWarehouses(.stokCancel) }

  /// Geri çekme izni için oturumdaki kullanıcı (ekran verir).
  public var currentUserId: UUID?

  public func load() async {
    do {
      lookup = try await InventoryLookup.load(repositories.inventory)
      movement = try await repositories.inventory.movement(id: movement.id)
      reversal = try await movement.reversedById.asyncMap { try await repositories.inventory.movement(id: $0) }
      original = try await movement.reversalOfId.asyncMap { try await repositories.inventory.movement(id: $0) }
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func approve() async {
    await run { try await self.repositories.inventory.approveMovement(id: self.movement.id, expectedVersion: self.movement.version) }
  }

  public func reject() async {
    guard (reason.nilIfBlank?.count ?? 0) >= 3 else {
      errorMessage = "Reddetme gerekçesi yazın."
      return
    }
    await run { try await self.repositories.inventory.rejectMovement(id: self.movement.id, reason: self.reason) }
  }

  /// Silme yoktur; ters kayıt açılır. Aynı kimlikle tekrar deneme ikinci ters kayıt açmaz.
  public func reverse() async {
    guard (reason.nilIfBlank?.count ?? 0) >= 10 else {
      errorMessage = "İptal gerekçesi en az 10 karakter olmalı."
      return
    }
    isWorking = true
    defer { isWorking = false }
    do {
      reversal = try await repositories.inventory.reverseMovement(id: movement.id, reversalId: reversalId, reason: reason)
      movement = try await repositories.inventory.movement(id: movement.id)
      reason = ""
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  private func run(_ action: @escaping () async throws -> StockMovement) async {
    isWorking = true
    defer { isWorking = false }
    do {
      movement = try await action()
      reason = ""
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }
}

extension Optional {
  func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
    guard let value = self else { return nil }
    return try await transform(value)
  }
}

// MARK: - Hareket formu (giriş, kullanım, transfer, iade, sayım)

@MainActor
@Observable
public final class StockMovementFormViewModel {
  public var kind: StockMovementKind {
    didSet { if kind != .transfer { targetWarehouseId = nil }; if kind == .sayim { unitId = nil } }
  }
  public var warehouseId: UUID?
  public var targetWarehouseId: UUID?
  public var materialId: UUID? { didSet { if oldValue != materialId { unitId = nil } } }
  /// nil: temel birim.
  public var unitId: UUID?
  public var quantityText = ""
  public var movementDate: CalendarDate
  public var description = ""
  public var reason = ""
  public var performedBy = ""
  public var documentId: UUID?
  public var materialSearch = ""

  public private(set) var lookup = InventoryLookup()
  public private(set) var warehouses: [Warehouse] = []
  public private(set) var currentStock: Decimal?
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?
  public private(set) var saved: StockMovement?

  /// Başarılı olana kadar aynı kimlik kullanılır (tekrar gönderim güvenli).
  public private(set) var pendingId = UUID()
  public let projectId: UUID?
  public let access: AccessControl
  private let repositories: Repositories

  public init(kind: StockMovementKind = .kullanim, warehouseId: UUID? = nil, materialId: UUID? = nil,
              projectId: UUID? = nil, access: AccessControl, repositories: Repositories, today: CalendarDate = .today()) {
    self.kind = kind
    self.warehouseId = warehouseId
    self.materialId = materialId
    self.projectId = projectId
    self.access = access
    self.repositories = repositories
    self.movementDate = today
  }

  /// Yazma izni olan depolar (kaynak).
  public var sourceWarehouses: [Warehouse] {
    warehouses.filter { $0.isActive && access.can(.stokWrite, scope: $0.projectId) }
  }

  /// Transfer hedefi: yazma izni olan, aynı DEMO işaretli diğer depolar.
  public var targetWarehouses: [Warehouse] {
    let source = warehouseId.flatMap { lookup.warehouses[$0] }
    return lookup.warehouses.values.filter { w in
      w.isActive && w.id != warehouseId && access.can(.stokWrite, scope: w.projectId) && w.isDemo == (source?.isDemo ?? w.isDemo)
    }.sorted { ($0.projectId == nil ? 0 : 1, $0.name) < ($1.projectId == nil ? 0 : 1, $1.name) }
  }

  public var materials: [Material] {
    let query = materialSearch.trimmingCharacters(in: .whitespaces).lowercased(with: Money.locale)
    return lookup.materials.values.filter { m in
      m.isActive && (query.isEmpty || "\(m.name) \(m.code)".lowercased(with: Money.locale).contains(query))
    }.sorted { $0.name < $1.name }
  }

  public var allowedUnits: [MaterialUnit] {
    guard let materialId else { return [] }
    let units = lookup.allowedUnits(for: materialId)
    return kind == .sayim ? Array(units.prefix(1)) : units
  }

  public var selectedUnit: MaterialUnit? {
    guard let materialId else { return nil }
    return unitId.flatMap { lookup.units[$0] } ?? lookup.baseUnit(of: materialId)
  }

  public var quantity: Decimal? {
    DecimalInput.parse(quantityText, maxFractionDigits: selectedUnit?.decimals ?? InventoryMath.quantityScale)
  }

  /// Temel birimde karşılık (dönüşüm yoksa nil).
  public var baseQuantity: Decimal? {
    guard let quantity, let materialId, let unit = selectedUnit, let factor = lookup.factor(material: materialId, unit: unit.id) else {
      return nil
    }
    return InventoryMath.toBase(quantity, factor: factor)
  }

  /// Kaydedenin onay yetkisi varsa hareket hemen stoka işlenir.
  public var postsImmediately: Bool {
    guard let source = warehouseId.flatMap({ lookup.warehouses[$0] }) else { return false }
    let target = targetWarehouseId.flatMap { lookup.warehouses[$0] }
    return access.can(.stokApprove, scope: source.projectId) && (target.map { access.can(.stokApprove, scope: $0.projectId) } ?? true)
  }

  public var draft: StockMovementDraft? {
    guard let materialId, let warehouseId, let quantity else { return nil }
    return StockMovementDraft(id: pendingId, kind: kind, materialId: materialId, warehouseId: warehouseId,
                              quantity: quantity, unitId: kind == .sayim ? nil : unitId,
                              targetWarehouseId: kind == .transfer ? targetWarehouseId : nil, movementDate: movementDate,
                              description: description.nilIfBlank, reason: reason.nilIfBlank, documentId: documentId,
                              performedBy: performedBy.nilIfBlank)
  }

  public var validationMessage: String? {
    guard warehouseId != nil else { return "Depoyu seçin." }
    guard materialId != nil else { return "Malzemeyi seçin." }
    guard let quantity = self.quantity else {
      return quantityText.nilIfBlank == nil ? "Miktarı girin."
        : "Miktar geçersiz (\(selectedUnit?.name ?? "birim") için en çok \(selectedUnit?.decimals ?? 3) ondalık)."
    }
    _ = quantity
    guard let draft else { return "Eksik bilgi." }
    if let message = draft.validationMessage { return message }
    if kind.decreasesSource, let base = baseQuantity, let stock = currentStock, base > stock {
      return "Yetersiz stok: depoda \(lookup.formatBase(stock, material: draft.materialId)) var."
    }
    return nil
  }

  public func load() async {
    do {
      lookup = try await InventoryLookup.load(repositories.inventory, includeInactive: false)
      warehouses = try await repositories.inventory.warehouses(projectId: projectId, includeInactive: false)
      if warehouseId == nil {
        warehouseId = sourceWarehouses.first { $0.isDefault }?.id ?? sourceWarehouses.first?.id
      }
      await refreshStock()
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Seçili depo ve malzemenin güncel miktarı (bilgi; asıl kontrol sunucuda).
  public func refreshStock() async {
    guard let warehouseId, let materialId else {
      currentStock = nil
      return
    }
    let balances = (try? await repositories.inventory.balances(warehouseId: warehouseId)) ?? []
    currentStock = balances.first { $0.materialId == materialId }?.quantity ?? 0
  }

  @discardableResult
  public func submit() async -> StockMovement? {
    if let validation = validationMessage {
      errorMessage = validation
      return nil
    }
    guard let draft else { return nil }
    isSaving = true
    defer { isSaving = false }
    do {
      let movement = try await repositories.inventory.createMovement(draft)
      saved = movement
      errorMessage = nil
      reset()
      return movement
    } catch {
      // Kimlik korunur: bağlantı hatasında tekrar gönderim aynı hareketi döner.
      errorMessage = message(for: error)
      return nil
    }
  }

  /// Sonraki hareket için formu temizler (depo ve tür korunur).
  public func reset() {
    pendingId = UUID()
    quantityText = ""
    description = ""
    reason = ""
    performedBy = ""
    documentId = nil
  }
}

// MARK: - Satın alma listesi

@MainActor
@Observable
public final class PurchaseOrderListViewModel {
  public private(set) var orders: [PurchaseOrder] = []
  public private(set) var accounts: [UUID: CariAccount] = [:]
  public private(set) var lookup = InventoryLookup()
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?
  public var statusFilter: PurchaseOrderStatus?
  public var searchText = ""

  public let projectId: UUID?
  public let access: AccessControl
  private let repositories: Repositories

  public init(projectId: UUID? = nil, access: AccessControl, repositories: Repositories) {
    self.projectId = projectId
    self.access = access
    self.repositories = repositories
  }

  public var canCreate: Bool {
    projectId.map { access.can(.satinalmaWrite, in: $0) } ?? access.canAnywhere(.satinalmaWrite)
  }

  public func supplierName(_ id: UUID) -> String { accounts[id]?.title ?? "Tedarikçi" }

  public var filtered: [PurchaseOrder] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased(with: Money.locale)
    return orders.filter { o in
      if let statusFilter, o.status != statusFilter { return false }
      guard !query.isEmpty else { return true }
      return [o.orderNo, o.description ?? "", supplierName(o.cariAccountId), lookup.warehouseName(o.warehouseId)]
        .joined(separator: " ").lowercased(with: Money.locale).contains(query)
    }
  }

  /// Teslim bekleyen (onaylı veya kısmen teslim) sipariş sayısı.
  public var awaitingDeliveryCount: Int { orders.filter(\.status.canReceive).count }

  public func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      async let orders = repositories.inventory.purchaseOrders(projectId: projectId, status: nil)
      async let lookup = InventoryLookup.load(repositories.inventory)
      self.orders = try await orders
      self.lookup = try await lookup
      // Tedarikçi adı: cari okuma izni yoksa ad gösterilmez.
      if access.canAnywhere(.cariRead) {
        let list = try await repositories.cari.listAccounts(type: nil, search: nil)
        accounts = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      }
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - Sipariş formu

@MainActor
@Observable
public final class PurchaseOrderFormViewModel {
  public struct LineInput: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var materialId: UUID?
    public var unitId: UUID?
    public var quantityText: String
    public var unitPriceText: String
    public var note: String

    public init(id: UUID = UUID(), materialId: UUID? = nil, unitId: UUID? = nil, quantityText: String = "",
                unitPriceText: String = "", note: String = "") {
      self.id = id
      self.materialId = materialId
      self.unitId = unitId
      self.quantityText = quantityText
      self.unitPriceText = unitPriceText
      self.note = note
    }
  }

  public var cariAccountId: UUID?
  public var warehouseId: UUID?
  public var lines: [LineInput] = [LineInput()]
  public var orderDate: CalendarDate
  public var hasExpectedDate = false
  public var expectedDate: CalendarDate
  public var currency = "TRY"
  public var description = ""
  public var notes = ""

  public private(set) var order: PurchaseOrder?
  public private(set) var suppliers: [CariAccount] = []
  public private(set) var warehouses: [Warehouse] = []
  public private(set) var lookup = InventoryLookup()
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?

  private var pendingId = UUID()
  public let projectId: UUID?
  public let access: AccessControl
  private let repositories: Repositories

  public init(order: PurchaseOrder? = nil, projectId: UUID? = nil, access: AccessControl, repositories: Repositories,
              today: CalendarDate = .today()) {
    self.order = order
    self.projectId = projectId ?? order?.projectId
    self.access = access
    self.repositories = repositories
    self.orderDate = order?.orderDate ?? today
    self.expectedDate = order?.expectedDate ?? today.adding(days: 7)
    if let order {
      cariAccountId = order.cariAccountId
      warehouseId = order.warehouseId
      hasExpectedDate = order.expectedDate != nil
      currency = order.currency
      description = order.description ?? ""
      notes = order.notes ?? ""
    }
  }

  public var isNew: Bool { order == nil }
  /// Fiyat alanı yalnızca fiyat görme izni olana gösterilir.
  public var canSeePrices: Bool { access.can(.satinalmaRead, scope: warehouseId.flatMap { lookup.warehouses[$0]?.projectId } ?? projectId) }

  public var materials: [Material] { lookup.materials.values.filter(\.isActive).sorted { $0.name < $1.name } }

  public var selectedWarehouse: Warehouse? { warehouseId.flatMap { lookup.warehouses[$0] } }

  /// Seçili depoyla aynı DEMO işaretli tedarikçiler.
  public var eligibleSuppliers: [CariAccount] {
    suppliers.filter { cari in cari.isActive && (selectedWarehouse.map { cari.isDemo == $0.isDemo } ?? true) }
  }

  public func units(for line: LineInput) -> [MaterialUnit] {
    line.materialId.map { lookup.allowedUnits(for: $0) } ?? []
  }

  public func addLine() { lines.append(LineInput()) }
  public func removeLine(id: UUID) {
    lines.removeAll { $0.id == id }
    if lines.isEmpty { lines = [LineInput()] }
  }

  public func load() async {
    do {
      lookup = try await InventoryLookup.load(repositories.inventory, includeInactive: false)
      warehouses = try await repositories.inventory.warehouses(projectId: projectId, includeInactive: false)
        .filter { access.can(.satinalmaWrite, scope: $0.projectId) }
      if warehouseId == nil { warehouseId = warehouses.first { $0.isDefault }?.id ?? warehouses.first?.id }
      if access.canAnywhere(.cariRead) {
        suppliers = try await repositories.cari.listAccounts(type: nil, search: nil)
          .filter { $0.type != .musteri || $0.id == cariAccountId }
          .sorted { $0.title < $1.title }
      }
      if let order {
        let stored = try await repositories.inventory.purchaseOrderLines(orderId: order.id)
        let prices = canSeePrices ? ((try? await repositories.inventory.purchaseOrderPrices(orderId: order.id)) ?? []) : []
        lines = stored.map { line in
          let price = prices.first { $0.orderLineId == line.id }?.unitPrice
          return LineInput(id: line.id, materialId: line.materialId, unitId: line.unitId,
                           quantityText: DecimalInput.format(line.quantity, maxFractionDigits: 3),
                           unitPriceText: price.map { DecimalInput.format($0, maxFractionDigits: 4) } ?? "",
                           note: line.note ?? "")
        }
        if lines.isEmpty { lines = [LineInput()] }
      }
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Formdaki satırları sunucu biçimine çevirir; ilk hatalı satırın mesajını döner.
  public func buildDraft() -> Result<PurchaseOrderDraft, RepositoryError> {
    guard let cariAccountId else { return .failure(.validation("Tedarikçiyi seçin.")) }
    guard let warehouseId else { return .failure(.validation("Teslim deposunu seçin.")) }
    var drafts: [PurchaseOrderLineDraft] = []
    for (index, line) in lines.enumerated() {
      if line.materialId == nil, line.quantityText.nilIfBlank == nil { continue }  // boş satır
      guard let materialId = line.materialId else { return .failure(.validation("Satır \(index + 1): malzemeyi seçin.")) }
      let unit = line.unitId.flatMap { lookup.units[$0] } ?? lookup.baseUnit(of: materialId)
      guard let quantity = DecimalInput.parse(line.quantityText, maxFractionDigits: unit?.decimals ?? 3), quantity > 0 else {
        return .failure(.validation("Satır \(index + 1): miktar geçersiz."))
      }
      var price: Decimal?
      if let text = line.unitPriceText.nilIfBlank {
        guard let parsed = DecimalInput.parse(text, maxFractionDigits: 4), parsed >= 0 else {
          return .failure(.validation("Satır \(index + 1): birim fiyat geçersiz."))
        }
        price = parsed
      }
      drafts.append(PurchaseOrderLineDraft(id: line.id, materialId: materialId, quantity: quantity, unitId: line.unitId,
                                           unitPrice: price, note: line.note.nilIfBlank))
    }
    let draft = PurchaseOrderDraft(cariAccountId: cariAccountId, warehouseId: warehouseId, lines: drafts,
                                   orderDate: orderDate, expectedDate: hasExpectedDate ? expectedDate : nil,
                                   currency: currency.uppercased(), description: description.nilIfBlank,
                                   notes: notes.nilIfBlank)
    if let message = draft.validationMessage { return .failure(.validation(message)) }
    return .success(draft)
  }

  @discardableResult
  public func save() async -> PurchaseOrder? {
    let draft: PurchaseOrderDraft
    switch buildDraft() {
    case .success(let value): draft = value
    case .failure(let error):
      errorMessage = error.errorDescription
      return nil
    }
    isSaving = true
    defer { isSaving = false }
    do {
      let saved = try await repositories.inventory.savePurchaseOrder(id: order?.id ?? pendingId, draft: draft,
                                                                     expectedVersion: order?.version)
      order = saved
      pendingId = UUID()
      errorMessage = nil
      return saved
    } catch {
      errorMessage = message(for: error)
      return nil
    }
  }
}

// MARK: - Sipariş detayı

@MainActor
@Observable
public final class PurchaseOrderDetailViewModel {
  public private(set) var order: PurchaseOrder
  public private(set) var lines: [PurchaseOrderLine] = []
  /// Fiyat görme izni yoksa boş.
  public private(set) var prices: [UUID: PurchaseOrderLinePrice] = [:]
  public private(set) var receipts: [PurchaseReceipt] = []
  public private(set) var expenseLinks: [PurchaseOrderExpenseLink] = []
  public private(set) var linkedExpenses: [UUID: FinanceDocument] = [:]
  public private(set) var documentLinks: [PurchaseOrderDocumentLink] = []
  public private(set) var linkedDocuments: [UUID: ArchiveDocument] = [:]
  public private(set) var events: [PurchaseOrderEvent] = []
  public private(set) var supplier: CariAccount?
  public private(set) var lookup = InventoryLookup()
  public private(set) var isLoading = false
  public private(set) var isWorking = false
  public private(set) var errorMessage: String?
  public var reason = ""

  public let access: AccessControl
  private let repositories: Repositories

  public init(order: PurchaseOrder, access: AccessControl, repositories: Repositories) {
    self.order = order
    self.access = access
    self.repositories = repositories
  }

  private var scope: UUID? { order.projectId }
  public var canSeePrices: Bool { access.can(.satinalmaRead, scope: scope) }
  public var canEdit: Bool { order.status == .taslak && access.can(.satinalmaWrite, scope: scope) }
  public var canApprove: Bool { order.status == .taslak && access.can(.satinalmaApprove, scope: scope) }
  public var canReceive: Bool { order.status.canReceive && access.can(.satinalmaReceive, scope: scope) }
  public var canClose: Bool { order.status.canReceive && access.can(.satinalmaApprove, scope: scope) }
  public var canCancel: Bool {
    switch order.status {
    case .taslak: access.can(.satinalmaWrite, scope: scope)
    case .onaylandi: access.can(.satinalmaCancel, scope: scope) && !receipts.contains { $0.status == .aktif }
    default: false
    }
  }
  public var canCancelReceipt: Bool {
    access.can(.satinalmaReceive, scope: scope) && access.can(.stokCancel, scope: lookup.warehouses[order.warehouseId]?.projectId)
  }
  public var canLinkExpense: Bool {
    order.status != .taslak && order.status != .iptal && access.can(.satinalmaWrite, scope: scope)
  }
  public var canLinkDocument: Bool {
    order.status != .iptal && (access.can(.satinalmaWrite, scope: scope) || access.can(.satinalmaReceive, scope: scope))
  }

  /// Bilgi amaçlı sipariş tutarı (finans kaydı değildir; borç doğurmaz).
  public var informationalTotal: Decimal? {
    guard canSeePrices else { return nil }
    let totals = lines.compactMap { prices[$0.id]?.lineTotal }
    return totals.isEmpty ? nil : totals.reduce(0, +)
  }

  public var activeExpenseLinks: [PurchaseOrderExpenseLink] { expenseLinks.filter { $0.status == .aktif } }
  public var activeDocumentLinks: [PurchaseOrderDocumentLink] { documentLinks.filter { $0.status == .aktif } }

  public func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      lookup = try await InventoryLookup.load(repositories.inventory)
      order = try await repositories.inventory.purchaseOrder(id: order.id)
      async let lines = repositories.inventory.purchaseOrderLines(orderId: order.id)
      async let receipts = repositories.inventory.receipts(orderId: order.id)
      async let documentLinks = repositories.inventory.documentLinks(orderId: order.id)
      async let events = repositories.inventory.events(orderId: order.id)
      self.lines = try await lines
      self.receipts = try await receipts
      self.documentLinks = try await documentLinks
      self.events = try await events
      if canSeePrices {
        let list = try await repositories.inventory.purchaseOrderPrices(orderId: order.id)
        prices = Dictionary(list.map { ($0.orderLineId, $0) }, uniquingKeysWith: { a, _ in a })
        expenseLinks = try await repositories.inventory.expenseLinks(orderId: order.id, financeDocumentId: nil)
        let ids = expenseLinks.filter { $0.status == .aktif }.map(\.financeDocumentId)
        if !ids.isEmpty, access.can(.giderRead, scope: scope) {
          let docs = try await repositories.finance.documents(ids: ids)
          linkedExpenses = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
      } else {
        prices = [:]
        expenseLinks = []
      }
      var docs: [UUID: ArchiveDocument] = [:]
      for link in self.documentLinks where link.status == .aktif {
        if let doc = try? await repositories.documents.document(id: link.documentId) { docs[doc.id] = doc }
      }
      linkedDocuments = docs
      if access.can(.cariRead, scope: scope) || access.canAnywhere(.cariRead) {
        supplier = try? await repositories.cari.getAccount(id: order.cariAccountId)
      }
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func perform(_ action: PurchaseOrderAction) async {
    if action.requiresReason {
      let minimum = (action == .iptal && order.status == .taslak) ? 3 : 10
      guard (reason.nilIfBlank?.count ?? 0) >= minimum else {
        errorMessage = "Gerekçe en az \(minimum) karakter olmalı."
        return
      }
    }
    isWorking = true
    defer { isWorking = false }
    do {
      order = try await repositories.inventory.transition(orderId: order.id, action: action, reason: reason.nilIfBlank,
                                                         expectedVersion: order.version)
      reason = ""
      errorMessage = nil
      await load()
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func cancelReceipt(_ receipt: PurchaseReceipt) async {
    guard (reason.nilIfBlank?.count ?? 0) >= 10 else {
      errorMessage = "Teslim iptali için en az 10 karakterlik gerekçe yazın."
      return
    }
    isWorking = true
    defer { isWorking = false }
    do {
      _ = try await repositories.inventory.cancelReceipt(id: receipt.id, reason: reason)
      reason = ""
      errorMessage = nil
      await load()
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Bağlanabilecek giderler: aynı proje, iptal edilmemiş, başka siparişe bağlı olmayan.
  public func expenseCandidates() async -> [FinanceDocument] {
    do {
      let docs = try await repositories.finance.documents(filter: FinanceDocumentFilter(kind: .gider, projectId: order.projectId))
      return docs.filter { d in
        d.status != .iptal && d.projectId == order.projectId && d.isDemo == order.isDemo
          && (d.cariAccountId == nil || d.cariAccountId == order.cariAccountId)
          && !activeExpenseLinks.contains { $0.financeDocumentId == d.id }
      }
    } catch {
      errorMessage = message(for: error)
      return []
    }
  }

  public func linkExpense(_ document: FinanceDocument, linkId: UUID = UUID()) async {
    isWorking = true
    defer { isWorking = false }
    do {
      _ = try await repositories.inventory.linkExpense(id: linkId, orderId: order.id, financeDocumentId: document.id, note: nil)
      errorMessage = nil
      await load()
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func unlinkExpense(_ link: PurchaseOrderExpenseLink) async {
    isWorking = true
    defer { isWorking = false }
    do {
      _ = try await repositories.inventory.unlinkExpense(id: link.id, reason: reason.nilIfBlank ?? "Yanlış bağlantı")
      reason = ""
      errorMessage = nil
      await load()
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Bağlanabilecek arşiv belgeleri (aynı proje, yüklenmiş).
  public func documentCandidates() async -> [ArchiveDocument] {
    do {
      let docs = try await repositories.documents.documents(filter: DocumentFilter(projectId: order.projectId))
      return docs.filter { d in
        (d.status == .yuklendi || d.status == .arsivlendi) && d.isDemo == order.isDemo
          && !activeDocumentLinks.contains { $0.documentId == d.id }
      }
    } catch {
      errorMessage = message(for: error)
      return []
    }
  }

  public func linkDocument(_ document: ArchiveDocument, linkId: UUID = UUID()) async {
    isWorking = true
    defer { isWorking = false }
    do {
      _ = try await repositories.inventory.linkDocument(id: linkId, orderId: order.id, documentId: document.id)
      errorMessage = nil
      await load()
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func unlinkDocument(_ link: PurchaseOrderDocumentLink) async {
    isWorking = true
    defer { isWorking = false }
    do {
      _ = try await repositories.inventory.unlinkDocument(id: link.id, reason: reason.nilIfBlank ?? "Yanlış bağlantı")
      reason = ""
      errorMessage = nil
      await load()
    } catch {
      errorMessage = message(for: error)
    }
  }
}

// MARK: - Teslim alma

@MainActor
@Observable
public final class PurchaseReceiptFormViewModel {
  public private(set) var order: PurchaseOrder
  public private(set) var lines: [PurchaseOrderLine] = []
  public private(set) var lookup = InventoryLookup()
  /// Sipariş satırı → girilen miktar (sipariş biriminde).
  public var quantities: [UUID: String] = [:]
  public var receiptDate: CalendarDate
  public var waybillNo = ""
  public var note = ""
  public var performedBy = ""
  public var documentId: UUID?
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?
  public private(set) var saved: PurchaseReceipt?

  /// Başarılı olana kadar aynı kimlik: tekrar gönderim ikinci stok girişi açmaz.
  public private(set) var pendingId = UUID()
  public let access: AccessControl
  private let repositories: Repositories

  public init(order: PurchaseOrder, access: AccessControl, repositories: Repositories, today: CalendarDate = .today()) {
    self.order = order
    self.access = access
    self.repositories = repositories
    self.receiptDate = today
  }

  public var openLines: [PurchaseOrderLine] { lines.filter { !$0.isFullyReceived } }

  public func load() async {
    do {
      lookup = try await InventoryLookup.load(repositories.inventory)
      lines = try await repositories.inventory.purchaseOrderLines(orderId: order.id)
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Kalanın tamamını doldurur (sahada tek dokunuşla tam teslim).
  public func fillRemaining() {
    for line in openLines {
      quantities[line.id] = DecimalInput.format(line.remainingQuantity, maxFractionDigits: lookup.units[line.unitId]?.decimals ?? 3)
    }
  }

  public func inputs() -> Result<[PurchaseReceiptLineInput], RepositoryError> {
    var result: [PurchaseReceiptLineInput] = []
    for line in lines {
      guard let text = quantities[line.id]?.nilIfBlank else { continue }
      let decimals = lookup.units[line.unitId]?.decimals ?? 3
      guard let quantity = DecimalInput.parse(text, maxFractionDigits: decimals), quantity >= 0 else {
        return .failure(.validation("Satır \(line.lineNo): miktar geçersiz."))
      }
      if quantity > 0 { result.append(PurchaseReceiptLineInput(orderLineId: line.id, quantity: quantity)) }
    }
    if result.isEmpty { return .failure(.validation("Teslim alınan en az bir satırın miktarını girin.")) }
    if let over = InventoryMath.receiptOverflow(result, lines: lines) {
      return .failure(.validation("Satır \(over.lineNo): kalan \(lookup.format(over.remainingQuantity, unit: over.unitId)); fazlası teslim alınamaz."))
    }
    return .success(result)
  }

  @discardableResult
  public func submit() async -> PurchaseReceipt? {
    let inputs: [PurchaseReceiptLineInput]
    switch self.inputs() {
    case .success(let value): inputs = value
    case .failure(let error):
      errorMessage = error.errorDescription
      return nil
    }
    isSaving = true
    defer { isSaving = false }
    do {
      let receipt = try await repositories.inventory.receive(
        PurchaseReceiptDraft(id: pendingId, orderId: order.id, lines: inputs, receiptDate: receiptDate,
                             waybillNo: waybillNo.nilIfBlank, note: note.nilIfBlank, documentId: documentId,
                             performedBy: performedBy.nilIfBlank))
      saved = receipt
      pendingId = UUID()
      quantities = [:]
      errorMessage = nil
      lines = (try? await repositories.inventory.purchaseOrderLines(orderId: order.id)) ?? lines
      order = (try? await repositories.inventory.purchaseOrder(id: order.id)) ?? order
      return receipt
    } catch {
      errorMessage = message(for: error)
      return nil
    }
  }
}
