import Foundation

// Malzeme, stok ve satın alma için bellek içi uygulama (önizleme ve birim
// testleri). Asıl kurallar veritabanındadır (20261108000000_malzeme_stok_satinalma.sql,
// pgTAP 120-122); burada yetki, DEMO ayrımı, negatif stok engeli, tekrar
// gönderim, teslim sınırı ve ters kayıt davranışı taklit edilir. Hiçbir işlem
// cari, gider veya ödeme kaydına dokunmaz.

/// Stok defteri satırı (işaretli miktar, temel birim).
public struct StockLedgerEntry: Hashable, Sendable {
  public var movementId: UUID
  public var warehouseId: UUID
  public var materialId: UUID
  public var date: CalendarDate
  public var quantity: Decimal
  public var isDemo: Bool
}

/// Sipariş satırı ve fiyatı (fiyat ayrıca yetkiyle okunur).
public struct StoredPurchaseOrderLine: Hashable, Sendable {
  public var line: PurchaseOrderLine
  public var unitPrice: Decimal?
  public var deleted: Bool
}

extension InMemoryBackend {
  // MARK: Yardımcılar

  private func has(_ key: PermissionKey, _ project: UUID?) -> Bool {
    project.map { access.can(key, in: $0) } ?? access.can(key)
  }

  /// Sunucudaki başlangıç kataloğu ve projelerin ana depoları.
  func ensureInventoryDefaults() {
    if materialUnitList.isEmpty {
      materialUnitList = [("adet", "Adet", "adet", 0), ("kg", "Kilogram", "kg", 3), ("ton", "Ton", "ton", 3),
                          ("m", "Metre", "m", 2), ("m2", "Metrekare", "m²", 2), ("m3", "Metreküp", "m³", 3),
                          ("torba", "Torba", "torba", 0), ("lt", "Litre", "lt", 2), ("paket", "Paket", "paket", 0)]
        .enumerated().map { MaterialUnit(code: $1.0, name: $1.1, symbol: $1.2, decimals: $1.3, sortOrder: ($0 + 1) * 10) }
    }
    if materialCategoryList.isEmpty {
      materialCategoryList = ["Kalıp ve iskele", "Demir", "Beton", "Kereste", "Bağlayıcı", "İnşaat kimyasalları",
                              "Sarf malzemesi"].enumerated().map { MaterialCategory(name: $1, sortOrder: ($0 + 1) * 10) }
        + [MaterialCategory(name: "Diğer", sortOrder: 900)]
    }
    for project in projects where !warehouseList.contains(where: { $0.projectId == project.id && $0.isDefault }) {
      warehouseList.append(Warehouse(kind: .proje, projectId: project.id, name: "Ana depo", isDefault: true,
                                     isDemo: project.isDemo))
    }
  }

  private func nextNo(_ prefix: String) -> String {
    inventorySequence += 1
    return prefix + String(format: "%06d", inventorySequence)
  }

  private func warehouse(_ id: UUID?) -> Warehouse? { id.flatMap { id in warehouseList.first { $0.id == id } } }

  private func canWarehouse(_ key: PermissionKey, _ id: UUID?) -> Bool {
    guard let w = warehouse(id) else { return false }
    return has(key, w.projectId)
  }

  private func canSeeWarehouse(_ w: Warehouse) -> Bool {
    [.stokRead, .stokWrite, .satinalmaRead, .satinalmaWrite, .satinalmaReceive].contains { has($0, w.projectId) }
  }

  private func canSeePurchase(_ project: UUID?) -> Bool {
    has(.satinalmaRead, project) || has(.satinalmaWrite, project) || has(.satinalmaReceive, project)
  }

  private func canReadMovement(_ m: StockMovement) -> Bool {
    canWarehouse(.stokRead, m.warehouseId) || canWarehouse(.stokRead, m.targetWarehouseId)
  }

  private func requireCatalogManager() throws {
    guard access.canAnywhere(.malzemeManage) else { throw RepositoryError.forbidden("Malzeme kataloğunu yönetme yetkiniz yok") }
  }

  func stockBalance(_ warehouse: UUID, _ material: UUID) -> Decimal {
    stockLedger.filter { $0.warehouseId == warehouse && $0.materialId == material }.reduce(0) { $0 + $1.quantity }
  }

  private func unitFactor(material: Material, unitId: UUID) throws -> Decimal {
    guard let factor = InventoryMath.factor(materialId: material.id, baseUnitId: material.baseUnitId, unitId: unitId,
                                            conversions: conversionList) else {
      throw RepositoryError.validation("Bu birim için tanımlı bir dönüşüm oranı yok; önce oranı tanımlayın.")
    }
    return factor
  }

  private func checkQuantity(_ quantity: Decimal, unitId: UUID, allowZero: Bool) throws {
    guard let unit = materialUnitList.first(where: { $0.id == unitId }) else { throw RepositoryError.validation("Birim bulunamadı.") }
    if quantity < 0 || (!allowZero && quantity == 0) { throw RepositoryError.validation("Miktar sıfırdan büyük olmalı.") }
    guard InventoryMath.fits(quantity, decimals: unit.decimals) else {
      throw RepositoryError.validation("\(unit.name) için en çok \(unit.decimals) ondalık girilebilir.")
    }
  }

  /// Defterde negatif bakiye oluşturacak satırları reddeder (sunucudaki tetikleyicinin karşılığı).
  private func appendLedger(_ rows: [StockLedgerEntry]) throws {
    var trial = stockLedger
    trial += rows
    for row in rows where row.quantity < 0 {
      let balance = trial.filter { $0.warehouseId == row.warehouseId && $0.materialId == row.materialId }
        .reduce(Decimal(0)) { $0 + $1.quantity }
      if balance < 0 { throw RepositoryError.validation("Yetersiz stok: bu işlemden sonra miktar \(balance) olurdu") }
    }
    stockLedger = trial
  }

  private func post(_ index: Int) throws {
    var m = stockMovementList[index]
    let row = { (w: UUID, q: Decimal) in
      StockLedgerEntry(movementId: m.id, warehouseId: w, materialId: m.materialId, date: m.movementDate, quantity: q,
                       isDemo: m.isDemo)
    }
    switch m.kind {
    case .giris, .iadeDepo: try appendLedger([row(m.warehouseId, m.baseQuantity)])
    case .kullanim, .iadeTedarikci: try appendLedger([row(m.warehouseId, -m.baseQuantity)])
    case .transfer:
      guard let target = m.targetWarehouseId else { throw RepositoryError.validation("Alıcı depo yok") }
      try appendLedger([row(m.warehouseId, -m.baseQuantity), row(target, m.baseQuantity)])
    case .sayim:
      let delta = m.baseQuantity - stockBalance(m.warehouseId, m.materialId)
      guard delta != 0 else { throw RepositoryError.validation("Sayılan miktar mevcut stokla aynı; düzeltme gerekmez") }
      try appendLedger([row(m.warehouseId, delta)])
      m.adjustment = delta
    case .tersKayit: break
    }
    m.status = .onaylandi
    m.approvedAt = Date()
    m.approvedBy = profile.id
    m.version += 1
    stockMovementList[index] = m
  }

  private func reverse(_ index: Int, reversalId: UUID, reason: String) throws -> StockMovement {
    let original = stockMovementList[index]
    let rows = stockLedger.filter { $0.movementId == original.id }
    let negated = rows.map { StockLedgerEntry(movementId: reversalId, warehouseId: $0.warehouseId, materialId: $0.materialId,
                                              date: today, quantity: -$0.quantity, isDemo: $0.isDemo) }
    let quantity = original.kind == .sayim ? abs(original.adjustment ?? 0) : original.quantity
    let base = original.kind == .sayim ? abs(original.adjustment ?? 0) : original.baseQuantity
    try appendLedger(negated)
    let reversal = StockMovement(id: reversalId, movementNo: nextNo("SH-"), kind: .tersKayit, status: .onaylandi,
                                 movementDate: today, materialId: original.materialId, warehouseId: original.warehouseId,
                                 quantity: quantity, unitId: original.unitId, unitFactor: original.unitFactor,
                                 baseQuantity: base, reason: reason.nilIfBlank, purchaseOrderId: original.purchaseOrderId,
                                 purchaseReceiptId: original.purchaseReceiptId, reversalOfId: original.id,
                                 approvedAt: Date(), approvedBy: profile.id, createdBy: profile.id, createdAt: Date(),
                                 isDemo: original.isDemo)
    stockMovementList.append(reversal)
    stockMovementList[index].reversedById = reversalId
    stockMovementList[index].version += 1
    return reversal
  }

  // MARK: Katalog

  func inventoryUnits(includeInactive: Bool) throws -> [MaterialUnit] {
    try failIfNeeded()
    ensureInventoryDefaults()
    return materialUnitList.filter { includeInactive || $0.isActive }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
  }

  func saveInventoryUnit(_ unit: MaterialUnit) throws -> MaterialUnit {
    try failIfNeeded()
    ensureInventoryDefaults()
    try requireCatalogManager()
    guard (0...3).contains(unit.decimals) else { throw RepositoryError.validation("Ondalık hane 0-3 arasında olmalı.") }
    if let index = materialUnitList.firstIndex(where: { $0.id == unit.id }) {
      let inUse = materialList.contains { $0.baseUnitId == unit.id } || stockMovementList.contains { $0.unitId == unit.id }
      if inUse, materialUnitList[index].decimals != unit.decimals {
        throw RepositoryError.validation("Kullanılan birimin ondalık hanesi değiştirilemez.")
      }
      var updated = unit
      updated.version = materialUnitList[index].version + 1
      materialUnitList[index] = updated
      return updated
    }
    guard !materialUnitList.contains(where: { $0.code.lowercased() == unit.code.lowercased() }) else {
      throw RepositoryError.conflict("Bu birim kodu zaten var.")
    }
    materialUnitList.append(unit)
    return unit
  }

  func inventoryCategories(includeInactive: Bool) throws -> [MaterialCategory] {
    try failIfNeeded()
    ensureInventoryDefaults()
    return materialCategoryList.filter { includeInactive || $0.isActive }
      .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
  }

  func saveInventoryCategory(_ category: MaterialCategory) throws -> MaterialCategory {
    try failIfNeeded()
    ensureInventoryDefaults()
    try requireCatalogManager()
    guard category.name.nilIfBlank != nil else { throw RepositoryError.validation("Kategori adı zorunlu.") }
    if let index = materialCategoryList.firstIndex(where: { $0.id == category.id }) {
      var updated = category
      updated.version = materialCategoryList[index].version + 1
      materialCategoryList[index] = updated
      return updated
    }
    guard !materialCategoryList.contains(where: { $0.name.lowercased() == category.name.lowercased() }) else {
      throw RepositoryError.conflict("Bu kategori zaten var.")
    }
    materialCategoryList.append(category)
    return category
  }

  func inventoryMaterials(search: String?, categoryId: UUID?, includeInactive: Bool) throws -> [Material] {
    try failIfNeeded()
    ensureInventoryDefaults()
    let term = search.nilIfBlank?.lowercased()
    return materialList.filter { m in
      (includeInactive || m.isActive) && (categoryId == nil || m.categoryId == categoryId)
        && (term == nil || m.name.lowercased().contains(term!) || m.code.lowercased().contains(term!))
    }.sorted { $0.name < $1.name }
  }

  func inventoryMaterial(id: UUID) throws -> Material {
    try failIfNeeded()
    guard let m = materialList.first(where: { $0.id == id }) else { throw RepositoryError.notFound }
    return m
  }

  private func baseUnitLocked(_ materialId: UUID) -> Bool {
    stockMovementList.contains { $0.materialId == materialId }
      || purchaseOrderLineStore.contains { $0.line.materialId == materialId }
      || conversionList.contains { $0.materialId == materialId && $0.isActive }
  }

  func saveInventoryMaterial(id: UUID, draft: MaterialDraft, expectedVersion: Int?) throws -> Material {
    try failIfNeeded()
    ensureInventoryDefaults()
    try requireCatalogManager()
    if let message = draft.validationMessage { throw RepositoryError.validation(message) }
    guard materialCategoryList.contains(where: { $0.id == draft.categoryId && $0.isActive }) else {
      throw RepositoryError.validation("Kategori bulunamadı veya pasif")
    }
    guard materialUnitList.contains(where: { $0.id == draft.baseUnitId && $0.isActive }) else {
      throw RepositoryError.validation("Birim bulunamadı veya pasif")
    }
    let name = draft.name.nilIfBlank ?? draft.name
    if let index = materialList.firstIndex(where: { $0.id == id }) {
      let m = materialList[index]
      guard let expectedVersion else {
        if m.name == name, m.categoryId == draft.categoryId, m.baseUnitId == draft.baseUnitId,
           draft.code.nilIfBlank.map({ $0.uppercased() == m.code.uppercased() }) ?? true,
           m.description == draft.description.nilIfBlank, m.isActive == draft.isActive { return m }
        throw RepositoryError.conflict("Bu kimlikle farklı bir malzeme var")
      }
      guard m.version == expectedVersion else {
        throw RepositoryError.conflict("Malzeme başka biri tarafından değiştirildi; yenileyip tekrar deneyin")
      }
      if m.baseUnitId != draft.baseUnitId, baseUnitLocked(m.id) {
        throw RepositoryError.validation("Hareketi, siparişi veya dönüşüm oranı olan malzemenin temel birimi değiştirilemez")
      }
      var updated = m
      updated.name = name
      updated.categoryId = draft.categoryId
      updated.baseUnitId = draft.baseUnitId
      updated.code = draft.code.nilIfBlank ?? m.code
      updated.description = draft.description.nilIfBlank
      updated.isActive = draft.isActive
      updated.version += 1
      materialList[index] = updated
      return updated
    }
    let code = draft.code.nilIfBlank ?? String(format: "MLZ-%04d", materialList.count + 1)
    guard !materialList.contains(where: { $0.code.uppercased() == code.uppercased() }) else {
      throw RepositoryError.conflict("Bu malzeme kodu zaten kullanılıyor.")
    }
    let material = Material(id: id, code: code, name: name, categoryId: draft.categoryId, baseUnitId: draft.baseUnitId,
                            description: draft.description.nilIfBlank, isActive: draft.isActive)
    materialList.append(material)
    return material
  }

  func inventoryConversions(materialId: UUID?) throws -> [MaterialUnitConversion] {
    try failIfNeeded()
    return conversionList.filter { materialId == nil || $0.materialId == materialId }
  }

  func saveInventoryConversion(_ c: MaterialUnitConversion) throws -> MaterialUnitConversion {
    try failIfNeeded()
    ensureInventoryDefaults()
    try requireCatalogManager()
    if let existing = conversionList.first(where: { $0.id == c.id }) {
      if existing.materialId == c.materialId, existing.unitId == c.unitId, existing.factor == c.factor { return existing }
      throw RepositoryError.conflict("Bu kimlikle farklı bir dönüşüm oranı var")
    }
    guard let material = materialList.first(where: { $0.id == c.materialId }) else { throw RepositoryError.notFound }
    guard material.baseUnitId != c.unitId else { throw RepositoryError.validation("Temel birim için dönüşüm tanımlanmaz") }
    guard c.factor > 0, InventoryMath.round(c.factor, scale: 6) == c.factor else {
      throw RepositoryError.validation("Oran sıfırdan büyük ve en çok 6 ondalıklı olmalı")
    }
    guard !conversionList.contains(where: { $0.materialId == c.materialId && $0.unitId == c.unitId && $0.isActive }) else {
      throw RepositoryError.conflict("Bu birim için etkin bir oran zaten var; önce onu pasifleştirin")
    }
    var stored = c
    stored.isActive = true
    stored.note = c.note.nilIfBlank
    conversionList.append(stored)
    return stored
  }

  func setInventoryConversionActive(id: UUID, isActive: Bool) throws -> MaterialUnitConversion {
    try failIfNeeded()
    try requireCatalogManager()
    guard let index = conversionList.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    conversionList[index].isActive = isActive
    return conversionList[index]
  }

  // MARK: Depolar

  func inventoryWarehouses(projectId: UUID?, includeInactive: Bool) throws -> [Warehouse] {
    try failIfNeeded()
    ensureInventoryDefaults()
    return warehouseList.filter { w in
      canSeeWarehouse(w) && (includeInactive || w.isActive) && (projectId == nil || w.projectId == projectId)
    }.sorted { ($0.projectId == nil ? 0 : 1, $0.isDefault ? 0 : 1, $0.name) < ($1.projectId == nil ? 0 : 1, $1.isDefault ? 0 : 1, $1.name) }
  }

  func saveInventoryWarehouse(id: UUID, draft: WarehouseDraft, expectedVersion: Int?) throws -> Warehouse {
    try failIfNeeded()
    ensureInventoryDefaults()
    guard has(.malzemeManage, draft.projectId) else { throw RepositoryError.forbidden("Depo tanımlama yetkiniz yok") }
    guard let name = draft.name.nilIfBlank else { throw RepositoryError.validation("Depo adı zorunlu") }
    let isDemo: Bool
    if let project = draft.projectId {
      guard let p = projects.first(where: { $0.id == project }) else { throw RepositoryError.notFound }
      isDemo = p.isDemo
    } else {
      isDemo = draft.isDemo
    }
    if let index = warehouseList.firstIndex(where: { $0.id == id }) {
      let w = warehouseList[index]
      guard w.projectId == draft.projectId, w.isDemo == isDemo else {
        throw RepositoryError.validation("Deponun projesi ve DEMO işareti değiştirilemez")
      }
      guard let expectedVersion else {
        if w.name == name, w.isActive == draft.isActive, w.notes == draft.notes.nilIfBlank { return w }
        throw RepositoryError.conflict("Bu kimlikle farklı bir depo var")
      }
      guard w.version == expectedVersion else { throw RepositoryError.conflict("Depo başka biri tarafından değiştirildi") }
      if !draft.isActive, materialList.contains(where: { stockBalance(w.id, $0.id) != 0 }) {
        throw RepositoryError.validation("Stoğu olan depo pasifleştirilemez; önce malzemeyi aktarın")
      }
      var updated = w
      updated.name = name
      updated.isActive = draft.isActive
      updated.notes = draft.notes.nilIfBlank
      updated.version += 1
      warehouseList[index] = updated
      return updated
    }
    let w = Warehouse(id: id, kind: draft.projectId == nil ? .genel : .proje, projectId: draft.projectId, name: name,
                      isActive: draft.isActive, isDemo: isDemo, notes: draft.notes.nilIfBlank)
    warehouseList.append(w)
    return w
  }

  // MARK: Stok

  func inventoryBalances(warehouseId: UUID?) throws -> [StockBalance] {
    try failIfNeeded()
    ensureInventoryDefaults()
    let visible = stockLedger.filter { canWarehouse(.stokRead, $0.warehouseId) && (warehouseId == nil || $0.warehouseId == warehouseId) }
    let grouped = Dictionary(grouping: visible) { [$0.warehouseId, $0.materialId] }
    return grouped.map { key, rows in
      StockBalance(warehouseId: key[0], materialId: key[1], quantity: rows.reduce(0) { $0 + $1.quantity },
                   entryCount: rows.count, lastEntryDate: rows.map(\.date).max(), isDemo: rows.contains(where: \.isDemo))
    }.sorted { ($0.warehouseId.uuidString, $0.materialId.uuidString) < ($1.warehouseId.uuidString, $1.materialId.uuidString) }
  }

  func inventoryPending(warehouseId: UUID?) throws -> [StockPending] {
    try failIfNeeded()
    var rows: [String: StockPending] = [:]
    for m in stockMovementList where m.status == .bekliyor && m.kind != .sayim && canReadMovement(m) {
      func add(_ w: UUID, out: Decimal, into: Decimal) {
        guard warehouseId == nil || warehouseId == w, canWarehouse(.stokRead, w) else { return }
        let key = "\(w)-\(m.materialId)"
        var row = rows[key] ?? StockPending(warehouseId: w, materialId: m.materialId, pendingOut: 0, pendingIn: 0, movementCount: 0)
        row.pendingOut += out
        row.pendingIn += into
        row.movementCount += 1
        rows[key] = row
      }
      if m.kind.decreasesSource { add(m.warehouseId, out: m.baseQuantity, into: 0) } else { add(m.warehouseId, out: 0, into: m.baseQuantity) }
      if m.kind == .transfer, let target = m.targetWarehouseId { add(target, out: 0, into: m.baseQuantity) }
    }
    return Array(rows.values)
  }

  func inventoryMovements(filter: StockMovementFilter) throws -> [StockMovement] {
    try failIfNeeded()
    return stockMovementList.filter { m in
      guard canReadMovement(m) else { return false }
      if let w = filter.warehouseId, m.warehouseId != w, m.targetWarehouseId != w { return false }
      if let material = filter.materialId, m.materialId != material { return false }
      if let status = filter.status, m.status != status { return false }
      if let order = filter.purchaseOrderId, m.purchaseOrderId != order { return false }
      return true
    }.sorted { ($0.movementDate, $0.movementNo) > ($1.movementDate, $1.movementNo) }
  }

  func inventoryMovement(id: UUID) throws -> StockMovement {
    try failIfNeeded()
    guard let m = stockMovementList.first(where: { $0.id == id }), canReadMovement(m) else { throw RepositoryError.notFound }
    return m
  }

  func createInventoryMovement(_ d: StockMovementDraft) throws -> StockMovement {
    try failIfNeeded()
    ensureInventoryDefaults()
    guard d.kind != .tersKayit else { throw RepositoryError.validation("Ters kayıt yalnızca iptal işlemiyle oluşur") }
    guard let w = warehouse(d.warehouseId), canWarehouse(.stokRead, w.id) else { throw RepositoryError.notFound }
    guard let material = materialList.first(where: { $0.id == d.materialId }) else { throw RepositoryError.notFound }
    let unitId = d.unitId ?? material.baseUnitId
    let date = d.movementDate ?? today

    if let existing = stockMovementList.first(where: { $0.id == d.id }) {
      guard existing.createdBy == profile.id, canReadMovement(existing) else {
        throw RepositoryError.conflict("Bu kimlikle başka bir hareket var")
      }
      if existing.kind == d.kind, existing.materialId == d.materialId, existing.warehouseId == d.warehouseId,
         existing.targetWarehouseId == d.targetWarehouseId, existing.quantity == d.quantity, existing.unitId == unitId,
         existing.movementDate == date, existing.description == d.description.nilIfBlank,
         existing.reason == d.reason.nilIfBlank, existing.documentId == d.documentId,
         existing.performedBy == d.performedBy.nilIfBlank {
        return existing
      }
      throw RepositoryError.conflict("Bu kimlikle farklı bir hareket var")
    }

    guard canWarehouse(.stokWrite, w.id) else { throw RepositoryError.forbidden("Bu depoda stok hareketi girme yetkiniz yok") }
    guard w.isActive else { throw RepositoryError.validation("Depo pasif") }
    guard material.isActive else { throw RepositoryError.validation("Malzeme pasif") }
    if d.kind == .transfer {
      guard let targetId = d.targetWarehouseId, targetId != w.id else {
        throw RepositoryError.validation("Transfer için farklı bir alıcı depo seçilmeli")
      }
      guard let t = warehouse(targetId), canSeeWarehouse(t) else { throw RepositoryError.notFound }
      guard canWarehouse(.stokWrite, t.id) else { throw RepositoryError.forbidden("Alıcı depoya stok hareketi girme yetkiniz yok") }
      guard t.isActive else { throw RepositoryError.validation("Alıcı depo pasif") }
      guard t.isDemo == w.isDemo else {
        throw RepositoryError.validation("Deneme (DEMO) deposu ile gerçek depo arasında transfer yapılamaz")
      }
    } else if d.targetWarehouseId != nil {
      throw RepositoryError.validation("Alıcı depo yalnızca transferde seçilir")
    }
    guard date <= today.adding(days: 1) else { throw RepositoryError.validation("Hareket tarihi ileri bir tarih olamaz") }

    let factor: Decimal
    let base: Decimal
    if d.kind == .sayim {
      guard unitId == material.baseUnitId else { throw RepositoryError.validation("Sayım temel birimle girilir") }
      guard (d.reason.nilIfBlank?.count ?? 0) >= 10 else {
        throw RepositoryError.validation("Sayım düzeltmesi için en az 10 karakterlik gerekçe zorunlu")
      }
      try checkQuantity(d.quantity, unitId: unitId, allowZero: true)
      factor = 1
      base = d.quantity
    } else {
      try checkQuantity(d.quantity, unitId: unitId, allowZero: false)
      factor = try unitFactor(material: material, unitId: unitId)
      base = InventoryMath.toBase(d.quantity, factor: factor)
    }
    if let documentId = d.documentId {
      guard let doc = archiveDocuments.first(where: { $0.id == documentId }),
            doc.status == .yuklendi || doc.status == .arsivlendi else {
        throw RepositoryError.validation("Belge bulunamadı veya yüklenmemiş")
      }
      guard doc.isDemo == w.isDemo else { throw RepositoryError.validation("DEMO belge gerçek kayda bağlanamaz") }
      guard doc.projectId == nil || doc.projectId == w.projectId else {
        throw RepositoryError.validation("Belge hareketle aynı projeye ait olmalı")
      }
    }
    if d.kind.decreasesSource {
      let available = stockBalance(w.id, material.id)
      guard base <= available else {
        throw RepositoryError.validation("Yetersiz stok: depoda \(DecimalInput.format(available)) var, \(DecimalInput.format(base)) isteniyor")
      }
    }

    let movement = StockMovement(id: d.id, movementNo: nextNo("SH-"), kind: d.kind, status: .bekliyor, movementDate: date,
                                 materialId: material.id, warehouseId: w.id, targetWarehouseId: d.targetWarehouseId,
                                 quantity: d.quantity, unitId: unitId, unitFactor: factor, baseQuantity: base,
                                 description: d.description.nilIfBlank, reason: d.reason.nilIfBlank,
                                 performedBy: d.performedBy.nilIfBlank, documentId: d.documentId,
                                 createdBy: profile.id, createdAt: Date(), isDemo: w.isDemo)
    stockMovementList.append(movement)
    let index = stockMovementList.count - 1
    if canWarehouse(.stokApprove, w.id), d.targetWarehouseId.map({ canWarehouse(.stokApprove, $0) }) ?? true {
      do { try post(index) } catch {
        stockMovementList.remove(at: index)  // tek işlem: hareket de geri alınır
        throw error
      }
    }
    return stockMovementList[index]
  }

  func approveInventoryMovement(id: UUID, expectedVersion: Int?) throws -> StockMovement {
    try failIfNeeded()
    guard let index = stockMovementList.firstIndex(where: { $0.id == id }), canReadMovement(stockMovementList[index]) else {
      throw RepositoryError.notFound
    }
    let m = stockMovementList[index]
    guard canWarehouse(.stokApprove, m.warehouseId), m.targetWarehouseId.map({ canWarehouse(.stokApprove, $0) }) ?? true else {
      throw RepositoryError.forbidden("Bu hareketi onaylama yetkiniz yok")
    }
    if m.status == .onaylandi { return m }
    guard m.status != .reddedildi else { throw RepositoryError.validation("Reddedilmiş hareket onaylanamaz") }
    if let expectedVersion, m.version != expectedVersion {
      throw RepositoryError.conflict("Hareket onaydan önce değişti; yenileyip tekrar inceleyin")
    }
    try post(index)
    return stockMovementList[index]
  }

  func rejectInventoryMovement(id: UUID, reason: String) throws -> StockMovement {
    try failIfNeeded()
    guard let index = stockMovementList.firstIndex(where: { $0.id == id }), canReadMovement(stockMovementList[index]) else {
      throw RepositoryError.notFound
    }
    let m = stockMovementList[index]
    if m.status == .reddedildi { return m }
    guard m.status == .bekliyor else { throw RepositoryError.validation("Onaylı hareket reddedilemez; ters kayıtla iptal edin") }
    let own = m.createdBy == profile.id && canWarehouse(.stokWrite, m.warehouseId)
    guard own || canWarehouse(.stokApprove, m.warehouseId) else { throw RepositoryError.forbidden("Bu hareketi reddetme yetkiniz yok") }
    guard (reason.nilIfBlank?.count ?? 0) >= 3 else { throw RepositoryError.validation("Gerekçe zorunlu") }
    stockMovementList[index].status = .reddedildi
    stockMovementList[index].rejectedAt = Date()
    stockMovementList[index].rejectReason = reason.nilIfBlank
    stockMovementList[index].version += 1
    return stockMovementList[index]
  }

  func reverseInventoryMovement(id: UUID, reversalId: UUID, reason: String) throws -> StockMovement {
    try failIfNeeded()
    guard let index = stockMovementList.firstIndex(where: { $0.id == id }), canReadMovement(stockMovementList[index]) else {
      throw RepositoryError.notFound
    }
    let m = stockMovementList[index]
    guard canWarehouse(.stokCancel, m.warehouseId), m.targetWarehouseId.map({ canWarehouse(.stokCancel, $0) }) ?? true else {
      throw RepositoryError.forbidden("Hareket iptal yetkiniz yok")
    }
    if let reversedBy = m.reversedById {
      if reversedBy == reversalId, let r = stockMovementList.first(where: { $0.id == reversedBy }) { return r }
      throw RepositoryError.conflict("Bu hareket zaten iptal edilmiş")
    }
    guard m.kind != .tersKayit else { throw RepositoryError.validation("Ters kayıt yeniden iptal edilemez") }
    guard m.status == .onaylandi else {
      throw RepositoryError.validation("Yalnızca onaylı hareket iptal edilir; bekleyen hareketi reddedin")
    }
    guard !m.isFromReceipt else {
      throw RepositoryError.validation("Satın alma teslimi, teslim alma kaydı iptal edilerek geri alınır")
    }
    guard (reason.nilIfBlank?.count ?? 0) >= 10 else { throw RepositoryError.validation("İptal gerekçesi en az 10 karakter olmalı") }
    return try reverse(index, reversalId: reversalId, reason: reason)
  }

  func inventorySummary(warehouseId: UUID, from: CalendarDate?, to: CalendarDate?) throws -> [StockSummaryRow] {
    try failIfNeeded()
    guard canWarehouse(.stokRead, warehouseId) else { throw RepositoryError.notFound }
    let kinds = Dictionary(uniqueKeysWithValues: stockMovementList.map { ($0.id, $0) })
    var rows: [UUID: StockSummaryRow] = [:]
    for e in stockLedger where e.warehouseId == warehouseId && (to == nil || e.date <= to!) {
      var row = rows[e.materialId] ?? StockSummaryRow(materialId: e.materialId)
      let movement = kinds[e.movementId]
      let kind = movement.flatMap { $0.reversalOfId.flatMap { kinds[$0]?.kind } ?? $0.kind } ?? .giris
      if let from, e.date < from {
        row.opening += e.quantity
      } else {
        switch kind {
        case .giris: row.received += e.quantity
        case .kullanim: row.used -= e.quantity
        case .transfer: row.transferred += e.quantity
        case .iadeDepo: row.returnedToStock += e.quantity
        case .iadeTedarikci: row.returnedToVendor -= e.quantity
        case .sayim: row.adjusted += e.quantity
        case .tersKayit: break
        }
      }
      row.closing += e.quantity
      rows[e.materialId] = row
    }
    return rows.values.sorted { $0.materialId.uuidString < $1.materialId.uuidString }
  }

  // MARK: Satın alma

  private func orderLines(_ orderId: UUID) -> [PurchaseOrderLine] {
    purchaseOrderLineStore.filter { $0.line.orderId == orderId && !$0.deleted }.map { stored in
      var line = stored.line
      let received = purchaseReceiptLineList.filter { rl in
        rl.orderLineId == line.id && purchaseReceiptList.contains { $0.id == rl.receiptId && $0.status == .aktif }
      }.reduce(Decimal(0)) { $0 + $1.baseQuantity }
      line.receivedBaseQuantity = received
      line.remainingBaseQuantity = line.baseQuantity - received
      return line
    }.sorted { $0.lineNo < $1.lineNo }
  }

  private func orderIndex(_ id: UUID) throws -> Int {
    guard let index = purchaseOrderList.firstIndex(where: { $0.id == id }), canSeePurchase(purchaseOrderList[index].projectId) else {
      throw RepositoryError.notFound
    }
    return index
  }

  private func event(_ order: UUID, _ action: String, from: PurchaseOrderStatus? = nil, to: PurchaseOrderStatus? = nil,
                     reason: String? = nil) {
    purchaseEventList.append(PurchaseOrderEvent(orderId: order, action: action, fromStatus: from?.rawValue,
                                                toStatus: to?.rawValue, reason: reason.nilIfBlank, actorId: profile.id))
  }

  private func refreshOrderStatus(_ index: Int) {
    let o = purchaseOrderList[index]
    guard o.status != .taslak, o.status != .iptal, o.closeReason == nil else { return }
    let status = InventoryMath.orderStatus(current: o.status, lines: orderLines(o.id))
    if status != o.status {
      purchaseOrderList[index].status = status
      purchaseOrderList[index].version += 1
    }
  }

  func inventoryPurchaseOrders(projectId: UUID?, status: PurchaseOrderStatus?) throws -> [PurchaseOrder] {
    try failIfNeeded()
    return purchaseOrderList.filter { o in
      canSeePurchase(o.projectId) && (projectId == nil || o.projectId == projectId) && (status == nil || o.status == status)
    }.sorted { ($0.orderDate, $0.orderNo) > ($1.orderDate, $1.orderNo) }
  }

  func inventoryPurchaseOrder(id: UUID) throws -> PurchaseOrder {
    try failIfNeeded()
    return purchaseOrderList[try orderIndex(id)]
  }

  func inventoryPurchaseOrderLines(orderId: UUID) throws -> [PurchaseOrderLine] {
    try failIfNeeded()
    _ = try orderIndex(orderId)
    return orderLines(orderId)
  }

  func inventoryPurchaseOrderPrices(orderId: UUID) throws -> [PurchaseOrderLinePrice] {
    try failIfNeeded()
    let o = purchaseOrderList[try orderIndex(orderId)]
    guard has(.satinalmaRead, o.projectId) else { throw RepositoryError.forbidden("Sipariş fiyatlarını görme yetkiniz yok") }
    return purchaseOrderLineStore.filter { $0.line.orderId == orderId && !$0.deleted }.map {
      PurchaseOrderLinePrice(orderLineId: $0.line.id, unitPrice: $0.unitPrice,
                             lineTotal: InventoryMath.lineTotal(quantity: $0.line.quantity, unitPrice: $0.unitPrice))
    }
  }

  private func normalizedLines(_ draft: PurchaseOrderDraft, orderId: UUID) throws -> [StoredPurchaseOrderLine] {
    try draft.lines.enumerated().map { index, l in
      guard let material = materialList.first(where: { $0.id == l.materialId && $0.isActive }) else {
        throw RepositoryError.validation("Malzeme bulunamadı veya pasif")
      }
      let unit = l.unitId ?? material.baseUnitId
      try checkQuantity(l.quantity, unitId: unit, allowZero: false)
      let factor = try unitFactor(material: material, unitId: unit)
      let line = PurchaseOrderLine(id: l.id, orderId: orderId, lineNo: index + 1, materialId: material.id, unitId: unit,
                                   quantity: l.quantity, unitFactor: factor, note: l.note.nilIfBlank)
      return StoredPurchaseOrderLine(line: line, unitPrice: l.unitPrice, deleted: false)
    }
  }

  func saveInventoryPurchaseOrder(id: UUID, draft: PurchaseOrderDraft, expectedVersion: Int?) throws -> PurchaseOrder {
    try failIfNeeded()
    ensureInventoryDefaults()
    guard let w = warehouse(draft.warehouseId), canSeeWarehouse(w) else { throw RepositoryError.notFound }
    guard has(.satinalmaWrite, w.projectId) else {
      throw RepositoryError.forbidden("Bu kapsamda satın alma siparişi hazırlama yetkiniz yok")
    }
    guard let cari = accounts.first(where: { $0.id == draft.cariAccountId && $0.isActive }) else {
      throw RepositoryError.validation("Tedarikçi (cari) bulunamadı veya pasif")
    }
    guard cari.isDemo == w.isDemo else {
      throw RepositoryError.validation("Deneme (DEMO) carisi gerçek depoya, gerçek cari deneme deposuna sipariş veremez")
    }
    if let message = draft.validationMessage { throw RepositoryError.validation(message) }
    let date = draft.orderDate ?? today
    if let expected = draft.expectedDate, expected < date {
      throw RepositoryError.validation("Beklenen teslim tarihi sipariş tarihinden önce olamaz")
    }
    let lines = try normalizedLines(draft, orderId: id)
    if lines.contains(where: { l in purchaseOrderLineStore.contains { $0.line.id == l.line.id && $0.line.orderId != id } }) {
      throw RepositoryError.conflict("Satır kimliği başka bir siparişe ait")
    }

    if let index = purchaseOrderList.firstIndex(where: { $0.id == id }) {
      let o = purchaseOrderList[index]
      guard canSeePurchase(o.projectId) else { throw RepositoryError.conflict("Bu kimlikle başka bir sipariş var") }
      guard let expectedVersion else {
        let stored = purchaseOrderLineStore.filter { $0.line.orderId == id && !$0.deleted }
        let same = o.cariAccountId == draft.cariAccountId && o.warehouseId == draft.warehouseId && o.orderDate == date
          && o.expectedDate == draft.expectedDate && o.currency == draft.currency
          && o.description == draft.description.nilIfBlank && o.notes == draft.notes.nilIfBlank
          && stored.map { [$0.line.id.uuidString, "\($0.line.quantity)", $0.line.unitId.uuidString, "\($0.unitPrice ?? -1)"] }
            == lines.map { [$0.line.id.uuidString, "\($0.line.quantity)", $0.line.unitId.uuidString, "\($0.unitPrice ?? -1)"] }
        if same { return o }
        throw RepositoryError.conflict("Bu kimlikle farklı bir sipariş var")
      }
      guard o.status == .taslak else { throw RepositoryError.validation("Yalnızca taslak sipariş düzenlenir") }
      guard o.version == expectedVersion else {
        throw RepositoryError.conflict("Sipariş başka biri tarafından değiştirildi; yenileyip tekrar deneyin")
      }
      guard has(.satinalmaWrite, o.projectId) else { throw RepositoryError.forbidden("Bu siparişi düzenleme yetkiniz yok") }
      guard o.isDemo == w.isDemo else {
        throw RepositoryError.validation("Deneme (DEMO) siparişi gerçek depoya taşınamaz (veya tersi)")
      }
      for i in purchaseOrderLineStore.indices where purchaseOrderLineStore[i].line.orderId == id {
        purchaseOrderLineStore[i].deleted = true
      }
      purchaseOrderLineStore.removeAll { s in s.deleted && lines.contains { $0.line.id == s.line.id } }
      purchaseOrderLineStore += lines
      var updated = o
      updated.cariAccountId = draft.cariAccountId
      updated.warehouseId = w.id
      updated.projectId = w.projectId
      updated.orderDate = date
      updated.expectedDate = draft.expectedDate
      updated.currency = draft.currency
      updated.description = draft.description.nilIfBlank
      updated.notes = draft.notes.nilIfBlank
      updated.version += 1
      purchaseOrderList[index] = updated
      event(id, "guncelle", from: .taslak, to: .taslak)
      return updated
    }

    let order = PurchaseOrder(id: id, orderNo: nextNo("SA-"), cariAccountId: draft.cariAccountId, warehouseId: w.id,
                              projectId: w.projectId, orderDate: date, expectedDate: draft.expectedDate,
                              currency: draft.currency, description: draft.description.nilIfBlank,
                              notes: draft.notes.nilIfBlank, createdBy: profile.id, isDemo: w.isDemo)
    purchaseOrderList.append(order)
    purchaseOrderLineStore += lines
    event(id, "olustur", to: .taslak)
    return order
  }

  func inventoryTransition(orderId: UUID, action: PurchaseOrderAction, reason: String?, expectedVersion: Int?) throws -> PurchaseOrder {
    try failIfNeeded()
    let index = try orderIndex(orderId)
    let o = purchaseOrderList[index]
    if let expectedVersion, o.version != expectedVersion {
      throw RepositoryError.conflict("Sipariş değişti; yenileyip tekrar deneyin")
    }
    let reasonLength = reason.nilIfBlank?.count ?? 0
    var updated = o
    switch action {
    case .onayla:
      if [.onaylandi, .kismiTeslim, .tamamlandi].contains(o.status) { return o }
      guard has(.satinalmaApprove, o.projectId) else { throw RepositoryError.forbidden("Sipariş onaylama yetkiniz yok") }
      guard o.status == .taslak else { throw RepositoryError.validation("İptal edilmiş sipariş onaylanamaz") }
      guard !orderLines(o.id).isEmpty else { throw RepositoryError.validation("Satırı olmayan sipariş onaylanamaz") }
      updated.status = .onaylandi
      updated.approvedAt = Date()
      updated.approvedBy = profile.id
    case .iptal:
      if o.status == .iptal { return o }
      if o.status == .taslak {
        guard has(.satinalmaWrite, o.projectId) else { throw RepositoryError.forbidden("Sipariş iptal yetkiniz yok") }
        guard reasonLength >= 3 else { throw RepositoryError.validation("İptal gerekçesi zorunlu") }
      } else {
        guard has(.satinalmaCancel, o.projectId) else { throw RepositoryError.forbidden("Onaylı siparişi iptal etme yetkiniz yok") }
        guard !purchaseReceiptList.contains(where: { $0.orderId == o.id && $0.status == .aktif }) else {
          throw RepositoryError.validation("Teslim alınmış sipariş iptal edilemez; teslimleri iptal edin veya siparişi kapatın")
        }
        guard reasonLength >= 10 else { throw RepositoryError.validation("İptal gerekçesi en az 10 karakter olmalı") }
      }
      updated.status = .iptal
      updated.cancelledAt = Date()
      updated.cancelReason = reason.nilIfBlank
    case .kapat:
      if o.status == .tamamlandi { return o }
      guard has(.satinalmaApprove, o.projectId) else { throw RepositoryError.forbidden("Siparişi kapatma yetkiniz yok") }
      guard o.status.canReceive else { throw RepositoryError.validation("Yalnızca onaylı sipariş kapatılır") }
      guard reasonLength >= 10 else { throw RepositoryError.validation("Kapatma gerekçesi en az 10 karakter olmalı") }
      updated.status = .tamamlandi
      updated.closedAt = Date()
      updated.closeReason = reason.nilIfBlank
    }
    updated.version += 1
    purchaseOrderList[index] = updated
    event(o.id, action.rawValue, from: o.status, to: updated.status, reason: reason)
    return updated
  }

  func inventoryReceipts(orderId: UUID) throws -> [PurchaseReceipt] {
    try failIfNeeded()
    _ = try orderIndex(orderId)
    return purchaseReceiptList.filter { $0.orderId == orderId }.sorted { ($0.receiptDate, $0.receiptNo) < ($1.receiptDate, $1.receiptNo) }
  }

  func inventoryReceiptLines(receiptId: UUID) throws -> [PurchaseReceiptLine] {
    try failIfNeeded()
    guard let r = purchaseReceiptList.first(where: { $0.id == receiptId }) else { throw RepositoryError.notFound }
    _ = try orderIndex(r.orderId)
    return purchaseReceiptLineList.filter { $0.receiptId == receiptId }
  }

  func inventoryReceive(_ d: PurchaseReceiptDraft) throws -> PurchaseReceipt {
    try failIfNeeded()
    let index = try orderIndex(d.orderId)
    let o = purchaseOrderList[index]
    guard has(.satinalmaReceive, o.projectId) else { throw RepositoryError.forbidden("Malzeme teslim alma yetkiniz yok") }
    let inputs = d.nonZeroLines
    guard !inputs.isEmpty else { throw RepositoryError.validation("Teslim alınacak en az bir satır girilmeli") }
    let date = d.receiptDate ?? today

    if let existing = purchaseReceiptList.first(where: { $0.id == d.id }) {
      guard existing.createdBy == profile.id else { throw RepositoryError.conflict("Bu kimlikle başka bir teslim var") }
      guard existing.status == .aktif else {
        throw RepositoryError.conflict("Bu kimlikli teslim iptal edilmiş; yeni teslim için yeniden deneyin")
      }
      let stored = purchaseReceiptLineList.filter { $0.receiptId == existing.id }
        .map { PurchaseReceiptLineInput(orderLineId: $0.orderLineId, quantity: $0.quantity) }
      if existing.orderId == d.orderId, existing.receiptDate == date, existing.waybillNo == d.waybillNo.nilIfBlank,
         existing.note == d.note.nilIfBlank, existing.documentId == d.documentId,
         Set(stored) == Set(inputs) {
        return existing
      }
      throw RepositoryError.conflict("Bu kimlikle farklı bir teslim var")
    }
    guard o.status.canReceive else { throw RepositoryError.validation("Yalnızca onaylı ve tamamlanmamış siparişe teslim alınır") }
    guard date <= today.adding(days: 1) else { throw RepositoryError.validation("Teslim tarihi ileri bir tarih olamaz") }
    guard date >= o.orderDate else { throw RepositoryError.validation("Teslim tarihi sipariş tarihinden önce olamaz") }
    guard Set(inputs.map(\.orderLineId)).count == inputs.count else {
      throw RepositoryError.validation("Aynı sipariş satırı bir teslimde bir kez girilir")
    }
    let lines = orderLines(o.id)
    for input in inputs {
      guard let line = lines.first(where: { $0.id == input.orderLineId }) else {
        throw RepositoryError.validation("Sipariş satırı bulunamadı")
      }
      try checkQuantity(input.quantity, unitId: line.unitId, allowZero: false)
    }
    if let over = InventoryMath.receiptOverflow(inputs, lines: lines) {
      throw RepositoryError.validation("Teslim miktarı sipariş kalanını aşıyor (satır \(over.lineNo): kalan \(DecimalInput.format(over.remainingBaseQuantity)))")
    }

    let receipt = PurchaseReceipt(id: d.id, receiptNo: nextNo("TS-"), orderId: o.id, warehouseId: o.warehouseId,
                                  receiptDate: date, waybillNo: d.waybillNo.nilIfBlank, note: d.note.nilIfBlank,
                                  documentId: d.documentId, createdBy: profile.id, isDemo: o.isDemo)
    var newMovements: [StockMovement] = []
    var newLines: [PurchaseReceiptLine] = []
    var ledger: [StockLedgerEntry] = []
    for input in inputs {
      let line = lines.first { $0.id == input.orderLineId }!
      let base = InventoryMath.toBase(input.quantity, factor: line.unitFactor)
      let movementId = UUID()
      newMovements.append(StockMovement(id: movementId, movementNo: nextNo("SH-"), kind: .giris, status: .onaylandi,
                                        movementDate: date, materialId: line.materialId, warehouseId: o.warehouseId,
                                        quantity: input.quantity, unitId: line.unitId, unitFactor: line.unitFactor,
                                        baseQuantity: base, description: "\(o.orderNo) teslimi",
                                        performedBy: d.performedBy.nilIfBlank, documentId: d.documentId,
                                        purchaseOrderId: o.id, purchaseReceiptId: receipt.id, approvedAt: Date(),
                                        approvedBy: profile.id, createdBy: profile.id, createdAt: Date(), isDemo: o.isDemo))
      newLines.append(PurchaseReceiptLine(receiptId: receipt.id, orderLineId: line.id, quantity: input.quantity,
                                          baseQuantity: base, stockMovementId: movementId))
      ledger.append(StockLedgerEntry(movementId: movementId, warehouseId: o.warehouseId, materialId: line.materialId,
                                     date: date, quantity: base, isDemo: o.isDemo))
    }
    try appendLedger(ledger)
    purchaseReceiptList.append(receipt)
    purchaseReceiptLineList += newLines
    stockMovementList += newMovements
    refreshOrderStatus(index)
    event(o.id, "teslim", to: purchaseOrderList[index].status)
    return receipt
  }

  func inventoryCancelReceipt(id: UUID, reason: String) throws -> PurchaseReceipt {
    try failIfNeeded()
    guard let rIndex = purchaseReceiptList.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    let r = purchaseReceiptList[rIndex]
    let index = try orderIndex(r.orderId)
    let o = purchaseOrderList[index]
    guard has(.satinalmaReceive, o.projectId), canWarehouse(.stokCancel, r.warehouseId) else {
      throw RepositoryError.forbidden("Teslim iptal yetkiniz yok")
    }
    if r.status == .iptal { return r }
    guard (reason.nilIfBlank?.count ?? 0) >= 10 else { throw RepositoryError.validation("İptal gerekçesi en az 10 karakter olmalı") }
    let snapshot = (stockLedger, stockMovementList)
    do {
      for line in purchaseReceiptLineList where line.receiptId == r.id {
        guard let mIndex = stockMovementList.firstIndex(where: { $0.id == line.stockMovementId }) else { continue }
        _ = try reverse(mIndex, reversalId: UUID(), reason: reason)
      }
    } catch {
      (stockLedger, stockMovementList) = snapshot  // tek işlem
      throw error
    }
    purchaseReceiptList[rIndex].status = .iptal
    purchaseReceiptList[rIndex].cancelledAt = Date()
    purchaseReceiptList[rIndex].cancelReason = reason.nilIfBlank
    purchaseReceiptList[rIndex].version += 1
    // Kapatılmamış siparişin durumu teslimlerden yeniden hesaplanır.
    if o.closeReason == nil, o.status != .iptal {
      let lines = orderLines(o.id)
      let status: PurchaseOrderStatus = lines.allSatisfy(\.isFullyReceived) ? .tamamlandi
        : (lines.contains { $0.receivedBaseQuantity > 0 } ? .kismiTeslim : .onaylandi)
      if status != o.status {
        purchaseOrderList[index].status = status
        purchaseOrderList[index].version += 1
      }
    }
    event(o.id, "teslim_iptal", to: purchaseOrderList[index].status, reason: reason)
    return purchaseReceiptList[rIndex]
  }

  func inventoryExpenseLinks(orderId: UUID?, financeDocumentId: UUID?) throws -> [PurchaseOrderExpenseLink] {
    try failIfNeeded()
    return purchaseExpenseLinkList.filter { link in
      guard let o = purchaseOrderList.first(where: { $0.id == link.orderId }), has(.satinalmaRead, o.projectId) else { return false }
      return (orderId == nil || link.orderId == orderId) && (financeDocumentId == nil || link.financeDocumentId == financeDocumentId)
    }
  }

  func inventoryLinkExpense(id: UUID, orderId: UUID, financeDocumentId: UUID, note: String?) throws -> PurchaseOrderExpenseLink {
    try failIfNeeded()
    guard let o = purchaseOrderList.first(where: { $0.id == orderId }), has(.satinalmaRead, o.projectId) else {
      throw RepositoryError.notFound
    }
    guard has(.satinalmaWrite, o.projectId) else { throw RepositoryError.forbidden("Siparişe gider bağlama yetkiniz yok") }
    guard let d = financeDocumentList.first(where: { $0.id == financeDocumentId }),
          has(d.kind.readPermission, d.projectId) || (d.createdBy == profile.id && has(d.kind.writePermission, d.projectId)) else {
      throw RepositoryError.notFound
    }
    if let existing = purchaseExpenseLinkList.first(where: { $0.id == id }) {
      if existing.orderId == orderId, existing.financeDocumentId == financeDocumentId, existing.status == .aktif { return existing }
      throw RepositoryError.conflict("Bu kimlikle farklı bir bağlantı var")
    }
    guard d.kind == .gider else { throw RepositoryError.validation("Siparişe yalnızca gider kaydı bağlanır") }
    guard d.status != .iptal else { throw RepositoryError.validation("İptal edilmiş gider bağlanamaz") }
    guard o.status != .taslak, o.status != .iptal else { throw RepositoryError.validation("Gider yalnızca onaylı siparişe bağlanır") }
    guard d.projectId == o.projectId else { throw RepositoryError.validation("Gider kaydı siparişle aynı projeye ait olmalı") }
    guard d.cariAccountId == nil || d.cariAccountId == o.cariAccountId else {
      throw RepositoryError.validation("Gider kaydının carisi siparişin tedarikçisiyle aynı olmalı")
    }
    guard d.isDemo == o.isDemo else { throw RepositoryError.validation("DEMO kayıt gerçek kayda bağlanamaz") }
    guard !purchaseExpenseLinkList.contains(where: { $0.financeDocumentId == financeDocumentId && $0.status == .aktif }) else {
      throw RepositoryError.conflict("Bu gider kaydı zaten bir siparişe bağlı")
    }
    let link = PurchaseOrderExpenseLink(id: id, orderId: orderId, financeDocumentId: financeDocumentId, note: note.nilIfBlank)
    purchaseExpenseLinkList.append(link)
    event(orderId, "gider_bagla")
    return link
  }

  func inventoryUnlinkExpense(id: UUID, reason: String) throws -> PurchaseOrderExpenseLink {
    try failIfNeeded()
    guard let index = purchaseExpenseLinkList.firstIndex(where: { $0.id == id }),
          let o = purchaseOrderList.first(where: { $0.id == purchaseExpenseLinkList[index].orderId }),
          has(.satinalmaRead, o.projectId) else { throw RepositoryError.notFound }
    guard has(.satinalmaWrite, o.projectId) else { throw RepositoryError.forbidden("Bağlantıyı kaldırma yetkiniz yok") }
    if purchaseExpenseLinkList[index].status == .iptal { return purchaseExpenseLinkList[index] }
    guard (reason.nilIfBlank?.count ?? 0) >= 3 else { throw RepositoryError.validation("Gerekçe zorunlu") }
    purchaseExpenseLinkList[index].status = .iptal
    purchaseExpenseLinkList[index].cancelReason = reason.nilIfBlank
    event(o.id, "gider_bag_kaldir", reason: reason)
    return purchaseExpenseLinkList[index]
  }

  func inventoryDocumentLinks(orderId: UUID) throws -> [PurchaseOrderDocumentLink] {
    try failIfNeeded()
    _ = try orderIndex(orderId)
    return purchaseDocumentLinkList.filter { $0.orderId == orderId }
  }

  func inventoryLinkDocument(id: UUID, orderId: UUID, documentId: UUID) throws -> PurchaseOrderDocumentLink {
    try failIfNeeded()
    let o = purchaseOrderList[try orderIndex(orderId)]
    guard has(.satinalmaWrite, o.projectId) || has(.satinalmaReceive, o.projectId) else {
      throw RepositoryError.forbidden("Siparişe belge bağlama yetkiniz yok")
    }
    if let existing = purchaseDocumentLinkList.first(where: { $0.id == id }) {
      if existing.orderId == orderId, existing.documentId == documentId, existing.status == .aktif { return existing }
      throw RepositoryError.conflict("Bu kimlikle farklı bir bağlantı var")
    }
    guard o.status != .iptal else { throw RepositoryError.validation("İptal edilmiş siparişe belge bağlanamaz") }
    guard let doc = archiveDocuments.first(where: { $0.id == documentId }),
          doc.status == .yuklendi || doc.status == .arsivlendi else {
      throw RepositoryError.validation("Belge bulunamadı veya yüklenmemiş")
    }
    guard doc.isDemo == o.isDemo else { throw RepositoryError.validation("DEMO belge gerçek kayda bağlanamaz") }
    guard doc.projectId == nil || doc.projectId == o.projectId else {
      throw RepositoryError.validation("Belge siparişle aynı projeye ait olmalı")
    }
    guard !purchaseDocumentLinkList.contains(where: { $0.orderId == orderId && $0.documentId == documentId && $0.status == .aktif }) else {
      throw RepositoryError.conflict("Belge bu siparişe zaten bağlı")
    }
    let link = PurchaseOrderDocumentLink(id: id, orderId: orderId, documentId: documentId)
    purchaseDocumentLinkList.append(link)
    event(orderId, "belge_bagla")
    return link
  }

  func inventoryUnlinkDocument(id: UUID, reason: String) throws -> PurchaseOrderDocumentLink {
    try failIfNeeded()
    guard let index = purchaseDocumentLinkList.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    let o = purchaseOrderList[try orderIndex(purchaseDocumentLinkList[index].orderId)]
    guard has(.satinalmaWrite, o.projectId) else { throw RepositoryError.forbidden("Bağlantıyı kaldırma yetkiniz yok") }
    if purchaseDocumentLinkList[index].status == .iptal { return purchaseDocumentLinkList[index] }
    guard (reason.nilIfBlank?.count ?? 0) >= 3 else { throw RepositoryError.validation("Gerekçe zorunlu") }
    purchaseDocumentLinkList[index].status = .iptal
    purchaseDocumentLinkList[index].cancelReason = reason.nilIfBlank
    event(o.id, "belge_bag_kaldir", reason: reason)
    return purchaseDocumentLinkList[index]
  }

  func inventoryEvents(orderId: UUID) throws -> [PurchaseOrderEvent] {
    try failIfNeeded()
    _ = try orderIndex(orderId)
    return purchaseEventList.filter { $0.orderId == orderId }
  }

  // MARK: Önizleme ve test yardımcıları

  /// Katalog ve depo kayıtlarını doğrudan ekler (yetki denetimi yok).
  public func seedInventory(materials: [Material] = [], conversions: [MaterialUnitConversion] = [],
                            warehouses: [Warehouse] = []) {
    ensureInventoryDefaults()
    materialList += materials
    conversionList += conversions
    warehouseList += warehouses
  }

  public func inventoryUnit(code: String) -> MaterialUnit? {
    ensureInventoryDefaults()
    return materialUnitList.first { $0.code == code }
  }

  public func inventoryCategory(name: String) -> MaterialCategory? {
    ensureInventoryDefaults()
    return materialCategoryList.first { $0.name == name }
  }

  public func defaultWarehouse(projectId: UUID) -> Warehouse? {
    ensureInventoryDefaults()
    return warehouseList.first { $0.projectId == projectId && $0.isDefault }
  }

  /// Arşiv belgesini doğrudan ekler (test ve önizleme).
  public func seedArchiveDocument(_ document: ArchiveDocument) { archiveDocuments.append(document) }

  /// Defterin ham toplamı (yetki denetimi yok; test için).
  public func rawStock(warehouseId: UUID, materialId: UUID) -> Decimal { stockBalance(warehouseId, materialId) }
}

struct InMemoryInventory: InventoryRepository {
  let backend: InMemoryBackend

  func units(includeInactive: Bool) async throws -> [MaterialUnit] { try await backend.inventoryUnits(includeInactive: includeInactive) }
  func saveUnit(_ unit: MaterialUnit) async throws -> MaterialUnit { try await backend.saveInventoryUnit(unit) }
  func categories(includeInactive: Bool) async throws -> [MaterialCategory] {
    try await backend.inventoryCategories(includeInactive: includeInactive)
  }
  func saveCategory(_ category: MaterialCategory) async throws -> MaterialCategory { try await backend.saveInventoryCategory(category) }
  func materials(search: String?, categoryId: UUID?, includeInactive: Bool) async throws -> [Material] {
    try await backend.inventoryMaterials(search: search, categoryId: categoryId, includeInactive: includeInactive)
  }
  func material(id: UUID) async throws -> Material { try await backend.inventoryMaterial(id: id) }
  func saveMaterial(id: UUID, draft: MaterialDraft, expectedVersion: Int?) async throws -> Material {
    try await backend.saveInventoryMaterial(id: id, draft: draft, expectedVersion: expectedVersion)
  }
  func conversions(materialId: UUID?) async throws -> [MaterialUnitConversion] {
    try await backend.inventoryConversions(materialId: materialId)
  }
  func saveConversion(_ conversion: MaterialUnitConversion) async throws -> MaterialUnitConversion {
    try await backend.saveInventoryConversion(conversion)
  }
  func setConversionActive(id: UUID, isActive: Bool) async throws -> MaterialUnitConversion {
    try await backend.setInventoryConversionActive(id: id, isActive: isActive)
  }
  func warehouses(projectId: UUID?, includeInactive: Bool) async throws -> [Warehouse] {
    try await backend.inventoryWarehouses(projectId: projectId, includeInactive: includeInactive)
  }
  func saveWarehouse(id: UUID, draft: WarehouseDraft, expectedVersion: Int?) async throws -> Warehouse {
    try await backend.saveInventoryWarehouse(id: id, draft: draft, expectedVersion: expectedVersion)
  }
  func balances(warehouseId: UUID?) async throws -> [StockBalance] { try await backend.inventoryBalances(warehouseId: warehouseId) }
  func pending(warehouseId: UUID?) async throws -> [StockPending] { try await backend.inventoryPending(warehouseId: warehouseId) }
  func movements(filter: StockMovementFilter) async throws -> [StockMovement] { try await backend.inventoryMovements(filter: filter) }
  func movement(id: UUID) async throws -> StockMovement { try await backend.inventoryMovement(id: id) }
  func createMovement(_ draft: StockMovementDraft) async throws -> StockMovement { try await backend.createInventoryMovement(draft) }
  func approveMovement(id: UUID, expectedVersion: Int?) async throws -> StockMovement {
    try await backend.approveInventoryMovement(id: id, expectedVersion: expectedVersion)
  }
  func rejectMovement(id: UUID, reason: String) async throws -> StockMovement {
    try await backend.rejectInventoryMovement(id: id, reason: reason)
  }
  func reverseMovement(id: UUID, reversalId: UUID, reason: String) async throws -> StockMovement {
    try await backend.reverseInventoryMovement(id: id, reversalId: reversalId, reason: reason)
  }
  func summary(warehouseId: UUID, from: CalendarDate?, to: CalendarDate?) async throws -> [StockSummaryRow] {
    try await backend.inventorySummary(warehouseId: warehouseId, from: from, to: to)
  }
  func purchaseOrders(projectId: UUID?, status: PurchaseOrderStatus?) async throws -> [PurchaseOrder] {
    try await backend.inventoryPurchaseOrders(projectId: projectId, status: status)
  }
  func purchaseOrder(id: UUID) async throws -> PurchaseOrder { try await backend.inventoryPurchaseOrder(id: id) }
  func purchaseOrderLines(orderId: UUID) async throws -> [PurchaseOrderLine] {
    try await backend.inventoryPurchaseOrderLines(orderId: orderId)
  }
  func purchaseOrderPrices(orderId: UUID) async throws -> [PurchaseOrderLinePrice] {
    try await backend.inventoryPurchaseOrderPrices(orderId: orderId)
  }
  func savePurchaseOrder(id: UUID, draft: PurchaseOrderDraft, expectedVersion: Int?) async throws -> PurchaseOrder {
    try await backend.saveInventoryPurchaseOrder(id: id, draft: draft, expectedVersion: expectedVersion)
  }
  func transition(orderId: UUID, action: PurchaseOrderAction, reason: String?, expectedVersion: Int?) async throws -> PurchaseOrder {
    try await backend.inventoryTransition(orderId: orderId, action: action, reason: reason, expectedVersion: expectedVersion)
  }
  func receipts(orderId: UUID) async throws -> [PurchaseReceipt] { try await backend.inventoryReceipts(orderId: orderId) }
  func receiptLines(receiptId: UUID) async throws -> [PurchaseReceiptLine] {
    try await backend.inventoryReceiptLines(receiptId: receiptId)
  }
  func receive(_ draft: PurchaseReceiptDraft) async throws -> PurchaseReceipt { try await backend.inventoryReceive(draft) }
  func cancelReceipt(id: UUID, reason: String) async throws -> PurchaseReceipt {
    try await backend.inventoryCancelReceipt(id: id, reason: reason)
  }
  func expenseLinks(orderId: UUID?, financeDocumentId: UUID?) async throws -> [PurchaseOrderExpenseLink] {
    try await backend.inventoryExpenseLinks(orderId: orderId, financeDocumentId: financeDocumentId)
  }
  func linkExpense(id: UUID, orderId: UUID, financeDocumentId: UUID, note: String?) async throws -> PurchaseOrderExpenseLink {
    try await backend.inventoryLinkExpense(id: id, orderId: orderId, financeDocumentId: financeDocumentId, note: note)
  }
  func unlinkExpense(id: UUID, reason: String) async throws -> PurchaseOrderExpenseLink {
    try await backend.inventoryUnlinkExpense(id: id, reason: reason)
  }
  func documentLinks(orderId: UUID) async throws -> [PurchaseOrderDocumentLink] {
    try await backend.inventoryDocumentLinks(orderId: orderId)
  }
  func linkDocument(id: UUID, orderId: UUID, documentId: UUID) async throws -> PurchaseOrderDocumentLink {
    try await backend.inventoryLinkDocument(id: id, orderId: orderId, documentId: documentId)
  }
  func unlinkDocument(id: UUID, reason: String) async throws -> PurchaseOrderDocumentLink {
    try await backend.inventoryUnlinkDocument(id: id, reason: reason)
  }
  func events(orderId: UUID) async throws -> [PurchaseOrderEvent] { try await backend.inventoryEvents(orderId: orderId) }
}
