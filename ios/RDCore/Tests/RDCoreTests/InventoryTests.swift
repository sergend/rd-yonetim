import Foundation
import XCTest
@testable import RDCore

private func grants(_ keys: [PermissionKey], project: UUID? = nil) -> [PermissionGrant] {
  keys.map { PermissionGrant(projectId: project, permissionKey: $0.rawValue) }
}

/// Bellek içi sunucu: iki proje (ana depoları otomatik), bir DEMO proje,
/// plywood (adet), demir (kg, 1 ton = 1000 kg) ve iki tedarikçi. Bugün 2026-11-10.
private struct Fixture {
  let backend: InMemoryBackend
  let repo: InventoryRepository
  let repos: Repositories
  let project = Project(code: "T-1", name: "Test projesi", status: .devam)
  let other = Project(code: "T-2", name: "Diğer proje", status: .devam)
  let demo = Project(code: "DEMO-T", name: "Deneme projesi", status: .devam, isDemo: true)
  let supplier = CariAccount(code: "C-1", title: "Kalıp Tedarik", type: .tedarikci)
  let demoSupplier = CariAccount(code: "C-2", title: "Demo Tedarik", type: .tedarikci, isDemo: true)
  static let today = CalendarDate(year: 2026, month: 11, day: 10)
  var plywood: Material!
  var demir: Material!
  var w1: Warehouse!
  var w2: Warehouse!
  var wDemo: Warehouse!
  var ton: MaterialUnit!

  init(grants: [PermissionGrant]? = nil) async {
    backend = InMemoryBackend(grants: grants ?? PermissionKey.allCases.map {
      PermissionGrant(projectId: nil, permissionKey: $0.rawValue)
    })
    repos = backend.repositories
    repo = repos.inventory
    await backend.seed(projects: [project, other, demo], accounts: [supplier, demoSupplier])
    await backend.set(today: Self.today)
    let adet = await backend.inventoryUnit(code: "adet")!
    let kg = await backend.inventoryUnit(code: "kg")!
    ton = await backend.inventoryUnit(code: "ton")!
    let kalip = await backend.inventoryCategory(name: "Kalıp ve iskele")!
    let demirCat = await backend.inventoryCategory(name: "Demir")!
    plywood = Material(code: "MLZ-0001", name: "Plywood", categoryId: kalip.id, baseUnitId: adet.id)
    demir = Material(code: "MLZ-0002", name: "İnşaat demiri", categoryId: demirCat.id, baseUnitId: kg.id)
    await backend.seedInventory(materials: [plywood, demir],
                                conversions: [MaterialUnitConversion(materialId: demir.id, unitId: ton.id, factor: 1000)])
    w1 = await backend.defaultWarehouse(projectId: project.id)
    w2 = await backend.defaultWarehouse(projectId: other.id)
    wDemo = await backend.defaultWarehouse(projectId: demo.id)
  }

  func stock(_ w: Warehouse, _ m: Material) async -> Decimal { await backend.rawStock(warehouseId: w.id, materialId: m.id) }

  @discardableResult
  func giris(_ q: Decimal, _ m: Material? = nil, into w: Warehouse? = nil) async throws -> StockMovement {
    try await repo.createMovement(StockMovementDraft(kind: .giris, materialId: (m ?? plywood).id, warehouseId: (w ?? w1).id,
                                                     quantity: q))
  }

  func order(_ lines: [PurchaseOrderLineDraft], warehouse: Warehouse? = nil, cari: CariAccount? = nil,
             id: UUID = UUID()) async throws -> PurchaseOrder {
    try await repo.savePurchaseOrder(id: id, draft: PurchaseOrderDraft(cariAccountId: (cari ?? supplier).id,
                                                                       warehouseId: (warehouse ?? w1).id, lines: lines,
                                                                       orderDate: Self.today), expectedVersion: nil)
  }

  func approvedOrder(_ lines: [PurchaseOrderLineDraft]) async throws -> PurchaseOrder {
    let o = try await order(lines)
    return try await repo.transition(orderId: o.id, action: .onayla, reason: nil, expectedVersion: nil)
  }
}

private func assertThrows(_ expected: (RepositoryError) -> Bool, _ message: String = "",
                          file: StaticString = #filePath, line: UInt = #line,
                          _ body: () async throws -> some Any) async {
  do {
    _ = try await body()
    XCTFail("hata bekleniyordu: \(message)", file: file, line: line)
  } catch let error as RepositoryError {
    XCTAssertTrue(expected(error), "beklenmeyen hata: \(error) \(message)", file: file, line: line)
  } catch {
    XCTFail("beklenmeyen hata türü: \(error)", file: file, line: line)
  }
}

private func isValidation(_ e: RepositoryError) -> Bool { if case .validation = e { return true }; return false }
private func isConflict(_ e: RepositoryError) -> Bool { if case .conflict = e { return true }; return false }
private func isForbidden(_ e: RepositoryError) -> Bool { if case .forbidden = e { return true }; return false }
private func isNotFound(_ e: RepositoryError) -> Bool { e == .notFound }

// MARK: - Hesap kuralları

final class InventoryMathTests: XCTestCase {
  func testBaseConversionUsesOnlyExplicitRatios() {
    let material = UUID(), base = UUID(), ton = UUID(), m3 = UUID()
    let conversions = [MaterialUnitConversion(materialId: material, unitId: ton, factor: 1000),
                       MaterialUnitConversion(materialId: material, unitId: m3, factor: 2400, isActive: false)]
    XCTAssertEqual(InventoryMath.factor(materialId: material, baseUnitId: base, unitId: base, conversions: conversions), 1)
    XCTAssertEqual(InventoryMath.factor(materialId: material, baseUnitId: base, unitId: ton, conversions: conversions), 1000)
    XCTAssertNil(InventoryMath.factor(materialId: material, baseUnitId: base, unitId: m3, conversions: conversions),
                 "pasif oran kullanılmaz")
    XCTAssertNil(InventoryMath.factor(materialId: material, baseUnitId: base, unitId: UUID(), conversions: conversions),
                 "tanımsız birim için tahmin yapılmaz")
    XCTAssertEqual(InventoryMath.toBase(Decimal(string: "2.5")!, factor: 1000), 2500)
    XCTAssertEqual(InventoryMath.toBase(Decimal(string: "0.3333")!, factor: 1), Decimal(string: "0.333"))
  }

  func testUnitDecimalsAreEnforced() {
    XCTAssertTrue(InventoryMath.fits(10, decimals: 0))
    XCTAssertFalse(InventoryMath.fits(Decimal(string: "10.5")!, decimals: 0))
    XCTAssertTrue(InventoryMath.fits(Decimal(string: "10.125")!, decimals: 3))
  }

  func testOrderStatusFollowsReceivedLines() {
    let order = UUID()
    let open = PurchaseOrderLine(orderId: order, lineNo: 1, materialId: UUID(), unitId: UUID(), quantity: 10)
    var partial = open
    partial.receivedBaseQuantity = 4
    partial.remainingBaseQuantity = 6
    var full = open
    full.receivedBaseQuantity = 10
    full.remainingBaseQuantity = 0
    XCTAssertEqual(InventoryMath.orderStatus(current: .onaylandi, lines: [open]), .onaylandi)
    XCTAssertEqual(InventoryMath.orderStatus(current: .onaylandi, lines: [partial, open]), .kismiTeslim)
    XCTAssertEqual(InventoryMath.orderStatus(current: .kismiTeslim, lines: [full, full]), .tamamlandi)
    XCTAssertEqual(InventoryMath.orderStatus(current: .taslak, lines: [full]), .taslak, "taslak teslimle değişmez")
    XCTAssertEqual(InventoryMath.orderStatus(current: .iptal, lines: [full]), .iptal)
    XCTAssertEqual(InventoryMath.receiptOverflow([PurchaseReceiptLineInput(orderLineId: partial.id, quantity: 7)],
                                                 lines: [partial])?.id, partial.id)
    XCTAssertNil(InventoryMath.receiptOverflow([PurchaseReceiptLineInput(orderLineId: partial.id, quantity: 6)], lines: [partial]))
  }

  func testDraftValidation() {
    let w = UUID(), m = UUID()
    XCTAssertNotNil(StockMovementDraft(kind: .kullanim, materialId: m, warehouseId: w, quantity: 0).validationMessage)
    XCTAssertNotNil(StockMovementDraft(kind: .transfer, materialId: m, warehouseId: w, quantity: 1).validationMessage)
    XCTAssertNotNil(StockMovementDraft(kind: .transfer, materialId: m, warehouseId: w, quantity: 1, targetWarehouseId: w)
      .validationMessage, "aynı depoya transfer olmaz")
    XCTAssertNotNil(StockMovementDraft(kind: .sayim, materialId: m, warehouseId: w, quantity: 0, reason: "kısa").validationMessage)
    XCTAssertNil(StockMovementDraft(kind: .sayim, materialId: m, warehouseId: w, quantity: 0,
                                    reason: "Ay sonu sayımında eksik çıktı").validationMessage, "sayımda 0 olabilir")
    XCTAssertNotNil(StockMovementDraft(kind: .tersKayit, materialId: m, warehouseId: w, quantity: 1).validationMessage)
    XCTAssertNotNil(PurchaseOrderDraft(cariAccountId: UUID(), warehouseId: w, lines: []).validationMessage)
  }

  func testMovementEffectAndReversalRules() {
    let w = UUID(), t = UUID()
    let transfer = StockMovement(movementNo: "SH-1", kind: .transfer, status: .onaylandi, movementDate: .today(),
                                 materialId: UUID(), warehouseId: w, targetWarehouseId: t, quantity: 5, unitId: UUID(),
                                 baseQuantity: 5)
    XCTAssertEqual(transfer.effect(on: w), -5)
    XCTAssertEqual(transfer.effect(on: t), 5)
    var pending = transfer
    pending.status = .bekliyor
    XCTAssertEqual(pending.effect(on: t), 0, "onaysız hareket stoka işlemez")
    XCTAssertTrue(transfer.canBeReversed)
    var receipt = transfer
    receipt.purchaseReceiptId = UUID()
    XCTAssertFalse(receipt.canBeReversed, "teslim hareketi teslim iptaliyle geri alınır")
  }

  func testModulesFollowStockPermissions() {
    let project = UUID()
    let chief = AccessControl(grants: grants([.stokRead, .stokWrite, .satinalmaReceive, .projeRead], project: project))
    XCTAssertTrue(AppModule.stoklar.isVisible(for: chief))
    XCTAssertTrue(AppModule.malzemeler.isVisible(for: chief))
    XCTAssertTrue(AppModule.satinAlma.isVisible(for: chief), "şef teslim almak için siparişleri görür")
    XCTAssertFalse(chief.can(.satinalmaApprove, in: project), "şef sipariş onaylayamaz")
    XCTAssertFalse(chief.can(.giderPay, in: project), "stok izni ödeme yetkisi vermez")
    let tasksOnly = AccessControl(grants: grants([.isRead], project: project))
    XCTAssertFalse(AppModule.stoklar.isVisible(for: tasksOnly))
    XCTAssertFalse(AppModule.satinAlma.isVisible(for: tasksOnly))
  }
}

// MARK: - Stok hareketleri

final class StockMovementTests: XCTestCase {
  func testEachProjectGetsDefaultWarehouse() async throws {
    let f = await Fixture()
    let list = try await f.repo.warehouses(projectId: nil, includeInactive: false)
    XCTAssertEqual(list.filter(\.isDefault).count, 3)
    XCTAssertTrue(f.wDemo.isDemo, "DEMO projenin deposu DEMO'dur")
  }

  func testStockIsComputedFromLedgerAndNeverNegative() async throws {
    let f = await Fixture()
    let entry = try await f.giris(100)
    XCTAssertEqual(entry.status, .onaylandi, "onay yetkisi olan kaydeden için hemen stoka işlenir")
    _ = try await f.repo.createMovement(StockMovementDraft(kind: .kullanim, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                           quantity: 40))
    let balance = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(balance, 60)
    await assertThrows(isValidation, "negatif stok") {
      try await f.repo.createMovement(StockMovementDraft(kind: .kullanim, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                         quantity: 61))
    }
    let after = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(after, 60, "reddedilen çıkış stoka dokunmaz")
    let balances = try await f.repo.balances(warehouseId: f.w1.id)
    XCTAssertEqual(balances.first { $0.materialId == f.plywood.id }?.quantity, 60)
  }

  func testRepeatedRequestCreatesNoSecondMovement() async throws {
    let f = await Fixture()
    try await f.giris(50)
    let draft = StockMovementDraft(kind: .kullanim, materialId: f.plywood.id, warehouseId: f.w1.id, quantity: 10,
                                   description: "Kat 3 kalıbı")
    let first = try await f.repo.createMovement(draft)
    let again = try await f.repo.createMovement(draft)
    XCTAssertEqual(first.id, again.id)
    XCTAssertEqual(first.movementNo, again.movementNo)
    let stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 40, "tekrar gönderim ikinci çıkış yapmaz")

    var different = draft
    different.quantity = 11
    await assertThrows(isConflict, "aynı kimlik farklı içerik") { try await f.repo.createMovement(different) }
  }

  func testWrongUuidFromAnotherUserConflicts() async throws {
    let f = await Fixture()
    let entry = try await f.giris(5)
    await f.backend.set(profile: UserProfile(id: UUID(), email: "baska@example.test", fullName: "Başka"))
    await assertThrows(isConflict, "başkasının kimliği") {
      try await f.repo.createMovement(StockMovementDraft(id: entry.id, kind: .giris, materialId: f.plywood.id,
                                                         warehouseId: f.w1.id, quantity: 5))
    }
  }

  func testTransferMovesStockBothWaysAndChecksBothWarehouses() async throws {
    let f = await Fixture()
    try await f.giris(30)
    _ = try await f.repo.createMovement(StockMovementDraft(kind: .transfer, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                           quantity: 12, targetWarehouseId: f.w2.id))
    var s1 = await f.stock(f.w1, f.plywood)
    var s2 = await f.stock(f.w2, f.plywood)
    XCTAssertEqual(s1, 18)
    XCTAssertEqual(s2, 12)
    _ = try await f.repo.createMovement(StockMovementDraft(kind: .transfer, materialId: f.plywood.id, warehouseId: f.w2.id,
                                                           quantity: 2, targetWarehouseId: f.w1.id))
    s1 = await f.stock(f.w1, f.plywood)
    s2 = await f.stock(f.w2, f.plywood)
    XCTAssertEqual(s1, 20, "ters yönde transfer")
    XCTAssertEqual(s2, 10)

    // Yalnızca kaynak projede yetkili kullanıcı hedef depoya aktaramaz.
    await f.backend.set(grants: grants([.stokRead, .stokWrite, .stokApprove], project: f.project.id))
    await assertThrows({ isForbidden($0) || isNotFound($0) }, "hedef depoda yetki yok") {
      try await f.repo.createMovement(StockMovementDraft(kind: .transfer, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                         quantity: 1, targetWarehouseId: f.w2.id))
    }
  }

  func testDemoAndRealWarehousesAreSeparated() async throws {
    let f = await Fixture()
    try await f.giris(10)
    await assertThrows(isValidation, "DEMO↔gerçek transfer") {
      try await f.repo.createMovement(StockMovementDraft(kind: .transfer, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                         quantity: 1, targetWarehouseId: f.wDemo.id))
    }
    await assertThrows(isValidation, "DEMO cari gerçek depoya sipariş veremez") {
      try await f.order([PurchaseOrderLineDraft(materialId: f.plywood.id, quantity: 1)], cari: f.demoSupplier)
    }
  }

  func testPendingFlowForSiteChief() async throws {
    let f = await Fixture()
    try await f.giris(20)
    let chiefId = UUID()
    await f.backend.set(profile: UserProfile(id: chiefId, email: "sef@example.test", fullName: "Şef"))
    await f.backend.set(grants: grants([.stokRead, .stokWrite, .satinalmaReceive], project: f.project.id))
    let usage = try await f.repo.createMovement(StockMovementDraft(kind: .kullanim, materialId: f.plywood.id,
                                                                   warehouseId: f.w1.id, quantity: 5))
    XCTAssertEqual(usage.status, .bekliyor, "şefin hareketi onay bekler")
    var stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 20, "onaysız hareket stoka işlenmez")
    let pending = try await f.repo.pending(warehouseId: f.w1.id)
    XCTAssertEqual(pending.first?.pendingOut, 5)
    await assertThrows(isForbidden, "şef onaylayamaz") { try await f.repo.approveMovement(id: usage.id, expectedVersion: nil) }

    await f.backend.set(grants: grants([.stokRead, .stokWrite, .stokApprove], project: f.project.id))
    let approved = try await f.repo.approveMovement(id: usage.id, expectedVersion: usage.version)
    XCTAssertEqual(approved.status, .onaylandi)
    let again = try await f.repo.approveMovement(id: usage.id, expectedVersion: nil)
    XCTAssertEqual(again.status, .onaylandi, "tekrar onay ikinci defter satırı açmaz")
    stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 15)
  }

  func testReturnsAndCountAdjustment() async throws {
    let f = await Fixture()
    try await f.giris(50)
    _ = try await f.repo.createMovement(StockMovementDraft(kind: .iadeTedarikci, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                           quantity: 5, reason: "Hasarlı geldi"))
    _ = try await f.repo.createMovement(StockMovementDraft(kind: .iadeDepo, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                           quantity: 3))
    var stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 48)
    await assertThrows(isValidation, "sayım gerekçesiz") {
      try await f.repo.createMovement(StockMovementDraft(kind: .sayim, materialId: f.plywood.id, warehouseId: f.w1.id, quantity: 45))
    }
    let count = try await f.repo.createMovement(StockMovementDraft(kind: .sayim, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                                   quantity: 45, reason: "Ay sonu sayımında 3 eksik"))
    XCTAssertEqual(count.adjustment, -3)
    stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 45)
    let summary = try await f.repo.summary(warehouseId: f.w1.id, from: nil, to: nil)
    let row = try XCTUnwrap(summary.first { $0.materialId == f.plywood.id })
    XCTAssertEqual(row.received, 50)
    XCTAssertEqual(row.returnedToVendor, 5)
    XCTAssertEqual(row.returnedToStock, 3)
    XCTAssertEqual(row.adjusted, -3)
    XCTAssertEqual(row.closing, 45)
  }

  func testReversalInsteadOfDelete() async throws {
    let f = await Fixture()
    let entry = try await f.giris(10)
    let usage = try await f.repo.createMovement(StockMovementDraft(kind: .kullanim, materialId: f.plywood.id,
                                                                   warehouseId: f.w1.id, quantity: 4))
    let reversalId = UUID()
    await assertThrows(isValidation, "kısa gerekçe") {
      try await f.repo.reverseMovement(id: usage.id, reversalId: reversalId, reason: "yanlış")
    }
    let reversal = try await f.repo.reverseMovement(id: usage.id, reversalId: reversalId, reason: "Yanlış kalemden düşüldü")
    XCTAssertEqual(reversal.kind, .tersKayit)
    XCTAssertEqual(reversal.reversalOfId, usage.id)
    let replay = try await f.repo.reverseMovement(id: usage.id, reversalId: reversalId, reason: "Yanlış kalemden düşüldü")
    XCTAssertEqual(replay.id, reversal.id, "aynı kimlikle tekrar iptal ikinci ters kayıt açmaz")
    var stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 10)
    await assertThrows(isValidation, "ters kayıt iptal edilmez") {
      try await f.repo.reverseMovement(id: reversal.id, reversalId: UUID(), reason: "Ters kaydı da geri al")
    }
    let movements = try await f.repo.movements(filter: StockMovementFilter(warehouseId: f.w1.id))
    XCTAssertEqual(movements.count, 3, "hiçbir hareket silinmez")

    // Kullanılmış girişin iptali stoku eksiye düşüremez.
    _ = try await f.repo.createMovement(StockMovementDraft(kind: .kullanim, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                           quantity: 8))
    await assertThrows(isValidation, "kullanılmış giriş iptal edilemez") {
      try await f.repo.reverseMovement(id: entry.id, reversalId: UUID(), reason: "Giriş yanlış depoya yapıldı")
    }
    stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 2)
  }

  func testUnitConversionAndBaseUnitLock() async throws {
    let f = await Fixture()
    let entry = try await f.repo.createMovement(StockMovementDraft(kind: .giris, materialId: f.demir.id, warehouseId: f.w1.id,
                                                                   quantity: Decimal(string: "2.5")!, unitId: f.ton.id))
    XCTAssertEqual(entry.baseQuantity, 2500)
    XCTAssertEqual(entry.unitFactor, 1000)
    let m3 = await f.backend.inventoryUnit(code: "m3")!
    await assertThrows(isValidation, "tanımsız oran") {
      try await f.repo.createMovement(StockMovementDraft(kind: .giris, materialId: f.demir.id, warehouseId: f.w1.id,
                                                         quantity: 1, unitId: m3.id))
    }
    var draft = MaterialDraft(f.demir)
    draft.baseUnitId = (await f.backend.inventoryUnit(code: "ton"))!.id
    await assertThrows(isValidation, "hareket varken temel birim değişmez") {
      try await f.repo.saveMaterial(id: f.demir.id, draft: draft, expectedVersion: f.demir.version)
    }
    await assertThrows(isValidation, "adet ondalıklı olamaz") {
      try await f.repo.createMovement(StockMovementDraft(kind: .giris, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                         quantity: Decimal(string: "1.5")!))
    }
  }

  func testUnauthorizedProjectWarehouseIsRejectedAndHidden() async throws {
    let f = await Fixture()
    try await f.giris(10)
    try await f.giris(7, into: f.w2)
    await f.backend.set(grants: grants([.stokRead, .stokWrite], project: f.project.id))
    let visible = try await f.repo.warehouses(projectId: nil, includeInactive: false)
    XCTAssertEqual(visible.map(\.id), [f.w1.id], "kullanıcı yalnız kendi projesinin deposunu görür")
    let balances = try await f.repo.balances(warehouseId: nil)
    XCTAssertEqual(Set(balances.map(\.warehouseId)), [f.w1.id])
    await assertThrows(isNotFound, "başka projenin deposu") {
      try await f.repo.createMovement(StockMovementDraft(kind: .kullanim, materialId: f.plywood.id, warehouseId: f.w2.id,
                                                         quantity: 1))
    }
    await f.backend.set(grants: grants([.stokRead], project: f.project.id))
    await assertThrows(isForbidden, "yalnız okuma") {
      try await f.repo.createMovement(StockMovementDraft(kind: .kullanim, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                         quantity: 1))
    }
  }
}

// MARK: - Satın alma

final class PurchaseOrderTests: XCTestCase {
  func testPartialReceiptsAndOverReceiptRejected() async throws {
    let f = await Fixture()
    let line = PurchaseOrderLineDraft(materialId: f.plywood.id, quantity: 160, unitPrice: 850)
    let order = try await f.approvedOrder([line])
    XCTAssertEqual(order.status, .onaylandi)
    let stockBefore = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stockBefore, 0, "sipariş stok girişi yapmaz")

    let first = PurchaseReceiptDraft(orderId: order.id, lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 100)],
                                     waybillNo: "IRS-1")
    _ = try await f.repo.receive(first)
    var current = try await f.repo.purchaseOrder(id: order.id)
    XCTAssertEqual(current.status, .kismiTeslim)
    let replay = try await f.repo.receive(first)
    XCTAssertEqual(replay.id, first.id)
    var stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 100, "aynı teslimin tekrar gönderimi ikinci giriş açmaz")

    await assertThrows(isValidation, "fazla teslim") {
      try await f.repo.receive(PurchaseReceiptDraft(orderId: order.id,
                                                    lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 61)]))
    }
    var changed = first
    changed.lines = [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 99)]
    await assertThrows(isConflict, "aynı teslim kimliği farklı içerik") { try await f.repo.receive(changed) }

    _ = try await f.repo.receive(PurchaseReceiptDraft(orderId: order.id,
                                                      lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 60)]))
    current = try await f.repo.purchaseOrder(id: order.id)
    XCTAssertEqual(current.status, .tamamlandi)
    stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 160)
    let lines = try await f.repo.purchaseOrderLines(orderId: order.id)
    XCTAssertEqual(lines.first?.remainingBaseQuantity, 0)
    let movements = try await f.repo.movements(filter: StockMovementFilter(purchaseOrderId: order.id))
    XCTAssertEqual(movements.count, 2)
    XCTAssertTrue(movements.allSatisfy { $0.isFromReceipt && $0.kind == .giris })
  }

  func testReceiptInOrderUnitConvertsToBase() async throws {
    let f = await Fixture()
    let line = PurchaseOrderLineDraft(materialId: f.demir.id, quantity: 12, unitId: f.ton.id, unitPrice: 20_000)
    let order = try await f.approvedOrder([line])
    _ = try await f.repo.receive(PurchaseReceiptDraft(orderId: order.id,
                                                      lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 5)]))
    let stock = await f.stock(f.w1, f.demir)
    XCTAssertEqual(stock, 5000)
    let lines = try await f.repo.purchaseOrderLines(orderId: order.id)
    XCTAssertEqual(lines.first?.remainingQuantity, 7)
  }

  func testPurchaseOrderCreatesNoFinanceRecord() async throws {
    let f = await Fixture()
    let line = PurchaseOrderLineDraft(materialId: f.plywood.id, quantity: 10, unitPrice: 100)
    let order = try await f.approvedOrder([line])
    _ = try await f.repo.receive(PurchaseReceiptDraft(orderId: order.id,
                                                      lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 10)]))
    let entries = await f.backend.entries
    let docs = await f.backend.financeDocumentList
    let settlements = await f.backend.financeSettlementList
    XCTAssertTrue(entries.isEmpty, "sipariş ve teslim cari borç oluşturmaz")
    XCTAssertTrue(docs.isEmpty, "gider kaydı oluşmaz")
    XCTAssertTrue(settlements.isEmpty, "ödeme oluşmaz")
  }

  func testExpenseLinkDoesNotDuplicateFinance() async throws {
    let f = await Fixture()
    let category = FinanceCategory(kind: .gider, name: "Malzeme")
    await f.backend.seedFinance(categories: [category])
    let line = PurchaseOrderLineDraft(materialId: f.plywood.id, quantity: 10, unitPrice: 100)
    let order = try await f.approvedOrder([line])
    let expense = try await f.repos.finance.saveDocument(
      id: UUID(), draft: FinanceDocumentDraft(kind: .gider, scope: .project(f.project.id), categoryId: category.id,
                                              description: "Plywood faturası", amount: 1_000, documentDate: Fixture.today,
                                              cariAccountId: f.supplier.id), expectedVersion: nil)
    let approved = try await f.repos.finance.approve(id: expense.id, expectedVersion: nil, settlementId: nil)
    let entriesBefore = await f.backend.entries.count
    let docsBefore = await f.backend.financeDocumentList

    let linkId = UUID()
    let link = try await f.repo.linkExpense(id: linkId, orderId: order.id, financeDocumentId: approved.id, note: nil)
    let replay = try await f.repo.linkExpense(id: linkId, orderId: order.id, financeDocumentId: approved.id, note: nil)
    XCTAssertEqual(link.id, replay.id)
    await assertThrows(isConflict, "gider ikinci siparişe bağlanmaz") {
      try await f.repo.linkExpense(id: UUID(), orderId: order.id, financeDocumentId: approved.id, note: nil)
    }
    let entriesAfter = await f.backend.entries.count
    let docsAfter = await f.backend.financeDocumentList
    XCTAssertEqual(entriesAfter, entriesBefore, "bağlantı cari hareket açmaz")
    XCTAssertEqual(docsAfter, docsBefore, "bağlantı gider kaydını değiştirmez")
  }

  func testDocumentLinkDoesNotChangeFinance() async throws {
    let f = await Fixture()
    let order = try await f.approvedOrder([PurchaseOrderLineDraft(materialId: f.plywood.id, quantity: 1)])
    let doc = ArchiveDocument(id: UUID(), kind: .irsaliye, title: "İrsaliye", documentDate: Fixture.today, linkType: .proje,
                              projectId: f.project.id, mimeType: .pdf, byteSize: 10, sha256: String(repeating: "a", count: 64),
                              storagePath: "x/y.pdf", status: .yuklendi, uploadedAt: Date())
    await f.backend.seedArchiveDocument(doc)
    let link = try await f.repo.linkDocument(id: UUID(), orderId: order.id, documentId: doc.id)
    XCTAssertEqual(link.status, .aktif)
    let entries = await f.backend.entries
    XCTAssertTrue(entries.isEmpty)
    let demoDoc = ArchiveDocument(id: UUID(), kind: .irsaliye, title: "Demo", documentDate: Fixture.today, linkType: .proje,
                                  projectId: f.demo.id, mimeType: .pdf, byteSize: 10, sha256: String(repeating: "b", count: 64),
                                  storagePath: "x/z.pdf", status: .yuklendi, uploadedAt: Date(), isDemo: true)
    await f.backend.seedArchiveDocument(demoDoc)
    await assertThrows(isValidation, "DEMO belge gerçek siparişe bağlanmaz") {
      try await f.repo.linkDocument(id: UUID(), orderId: order.id, documentId: demoDoc.id)
    }
  }

  func testChiefCannotApproveOrSeePrices() async throws {
    let f = await Fixture()
    let line = PurchaseOrderLineDraft(materialId: f.plywood.id, quantity: 10, unitPrice: 100)
    let draftOrder = try await f.order([line])
    await f.backend.set(grants: grants([.stokRead, .stokWrite, .satinalmaReceive], project: f.project.id))
    await assertThrows(isForbidden, "şef onaylayamaz") {
      try await f.repo.transition(orderId: draftOrder.id, action: .onayla, reason: nil, expectedVersion: nil)
    }
    await assertThrows(isForbidden, "şef fiyat göremez") { try await f.repo.purchaseOrderPrices(orderId: draftOrder.id) }
    await f.backend.set(grants: PermissionKey.allCases.map { PermissionGrant(projectId: nil, permissionKey: $0.rawValue) })
    _ = try await f.repo.transition(orderId: draftOrder.id, action: .onayla, reason: nil, expectedVersion: nil)
    await f.backend.set(grants: grants([.stokRead, .stokWrite, .satinalmaReceive], project: f.project.id))
    let receipt = try await f.repo.receive(PurchaseReceiptDraft(orderId: draftOrder.id,
                                                                lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 4)]))
    XCTAssertEqual(receipt.status, .aktif, "şef teslim alabilir")
  }

  func testReceiptCancelReversesStockAndReopensOrder() async throws {
    let f = await Fixture()
    let line = PurchaseOrderLineDraft(materialId: f.plywood.id, quantity: 10)
    let order = try await f.approvedOrder([line])
    let receipt = try await f.repo.receive(PurchaseReceiptDraft(orderId: order.id,
                                                                lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 10)]))
    _ = try await f.repo.createMovement(StockMovementDraft(kind: .kullanim, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                           quantity: 3))
    await assertThrows(isValidation, "kullanılmış teslim iptal edilemez") {
      try await f.repo.cancelReceipt(id: receipt.id, reason: "Yanlış siparişe teslim alındı")
    }
    let movements = try await f.repo.movements(filter: StockMovementFilter(purchaseOrderId: order.id))
    await assertThrows(isValidation, "teslim hareketi tek başına iptal edilmez") {
      try await f.repo.reverseMovement(id: movements[0].id, reversalId: UUID(), reason: "Teslim hareketini geri al")
    }
    let usage = try await f.repo.movements(filter: StockMovementFilter(warehouseId: f.w1.id)).first { $0.kind == .kullanim }!
    _ = try await f.repo.reverseMovement(id: usage.id, reversalId: UUID(), reason: "Kullanım yanlış girildi")
    let cancelled = try await f.repo.cancelReceipt(id: receipt.id, reason: "Yanlış siparişe teslim alındı")
    XCTAssertEqual(cancelled.status, .iptal)
    let stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 0)
    let reopened = try await f.repo.purchaseOrder(id: order.id)
    XCTAssertEqual(reopened.status, .onaylandi)
  }

  func testOrderVersionAndCancelRules() async throws {
    let f = await Fixture()
    let order = try await f.order([PurchaseOrderLineDraft(materialId: f.plywood.id, quantity: 5)])
    var draft = PurchaseOrderDraft(cariAccountId: f.supplier.id, warehouseId: f.w1.id,
                                   lines: [PurchaseOrderLineDraft(materialId: f.plywood.id, quantity: 6)], orderDate: Fixture.today)
    let updated = try await f.repo.savePurchaseOrder(id: order.id, draft: draft, expectedVersion: order.version)
    await assertThrows(isConflict, "eski sürüm") {
      try await f.repo.savePurchaseOrder(id: order.id, draft: draft, expectedVersion: order.version)
    }
    draft.description = "değişti"
    await assertThrows(isConflict, "aynı kimlik farklı içerik") {
      try await f.repo.savePurchaseOrder(id: order.id, draft: draft, expectedVersion: nil)
    }
    let approved = try await f.repo.transition(orderId: updated.id, action: .onayla, reason: nil, expectedVersion: updated.version)
    await assertThrows(isValidation, "onaylı sipariş düzenlenmez") {
      try await f.repo.savePurchaseOrder(id: order.id, draft: draft, expectedVersion: approved.version)
    }
    await assertThrows(isValidation, "kısa gerekçe") {
      try await f.repo.transition(orderId: order.id, action: .iptal, reason: "hata", expectedVersion: nil)
    }
    let cancelled = try await f.repo.transition(orderId: order.id, action: .iptal, reason: "Tedarikçi ürünü bulamadı",
                                                expectedVersion: nil)
    XCTAssertEqual(cancelled.status, .iptal)
    let events = try await f.repo.events(orderId: order.id)
    XCTAssertEqual(events.map(\.action), ["olustur", "guncelle", "onayla", "iptal"])
  }
}

// MARK: - View model'ler

@MainActor
final class InventoryViewModelTests: XCTestCase {
  func testMovementFormKeepsIdUntilSuccess() async throws {
    let f = await Fixture()
    try await f.giris(10)
    let access = AccessControl(grants: PermissionKey.allCases.map { PermissionGrant(projectId: nil, permissionKey: $0.rawValue) })
    let vm = StockMovementFormViewModel(kind: .kullanim, warehouseId: f.w1.id, materialId: f.plywood.id,
                                        access: access, repositories: f.repos, today: Fixture.today)
    await vm.load()
    vm.quantityText = "4"
    let id = vm.pendingId
    await f.backend.set(nextError: .network)
    let failed = await vm.submit()
    XCTAssertNil(failed)
    XCTAssertEqual(vm.pendingId, id, "bağlantı hatasında kimlik korunur")
    let saved = await vm.submit()
    XCTAssertEqual(saved?.id, id)
    XCTAssertNotEqual(vm.pendingId, id, "başarıdan sonra yeni kimlik")
    let stock = await f.stock(f.w1, f.plywood)
    XCTAssertEqual(stock, 6)

    vm.quantityText = "7"
    await vm.refreshStock()
    XCTAssertNotNil(vm.validationMessage, "yetersiz stok formda da gösterilir")
  }

  func testStockOverviewMergesBalancesAndPending() async throws {
    let f = await Fixture()
    try await f.giris(10)
    await f.backend.set(grants: grants([.stokRead, .stokWrite], project: f.project.id))
    _ = try await f.repo.createMovement(StockMovementDraft(kind: .kullanim, materialId: f.plywood.id, warehouseId: f.w1.id,
                                                           quantity: 3))
    let access = AccessControl(grants: grants([.stokRead, .stokWrite], project: f.project.id))
    let vm = StockOverviewViewModel(projectId: f.project.id, access: access, repositories: f.repos)
    await vm.load()
    XCTAssertEqual(vm.selectedWarehouseId, f.w1.id)
    XCTAssertEqual(vm.rows.first?.quantity, 10)
    XCTAssertEqual(vm.rows.first?.pendingOut, 3)
    XCTAssertTrue(vm.canWrite)
    XCTAssertFalse(vm.canApprove)
    XCTAssertEqual(vm.pendingMovements.count, 1)
  }

  func testReceiptFormRejectsOverReceiptBeforeSending() async throws {
    let f = await Fixture()
    let line = PurchaseOrderLineDraft(materialId: f.plywood.id, quantity: 10)
    let order = try await f.approvedOrder([line])
    let access = AccessControl(grants: PermissionKey.allCases.map { PermissionGrant(projectId: nil, permissionKey: $0.rawValue) })
    let vm = PurchaseReceiptFormViewModel(order: order, access: access, repositories: f.repos, today: Fixture.today)
    await vm.load()
    vm.quantities[line.id] = "11"
    let rejected = await vm.submit()
    XCTAssertNil(rejected)
    XCTAssertNotNil(vm.errorMessage)
    vm.fillRemaining()
    XCTAssertEqual(vm.quantities[line.id], "10")
    let receipt = await vm.submit()
    XCTAssertNotNil(receipt)
    XCTAssertEqual(vm.order.status, .tamamlandi)
  }

  func testPreviewDataHasStockAndOrders() async throws {
    let backend = await PreviewData.backend()
    let repo = backend.repositories.inventory
    let found = await backend.defaultWarehouse(projectId: PreviewData.sivas.id)
    let depot = try XCTUnwrap(found)
    let balances = try await repo.balances(warehouseId: depot.id)
    XCTAssertEqual(Set(balances.map(\.quantity)), [60, 200, 5000], "plywood 100−40, direk 200, demir 5 ton")
    let orders = try await repo.purchaseOrders(projectId: PreviewData.sivas.id, status: nil)
    XCTAssertEqual(Set(orders.map(\.status)), [.kismiTeslim])
    let entries = await backend.entries.count
    XCTAssertEqual(entries, 2, "örnek veride yalnız iki manuel cari hareket var; stok cari yazmaz")
  }

  func testOrderFormHidesPricesWithoutPermission() async throws {
    let f = await Fixture()
    let access = AccessControl(grants: grants([.satinalmaWrite, .stokRead], project: f.project.id))
    let vm = PurchaseOrderFormViewModel(projectId: f.project.id, access: access, repositories: f.repos, today: Fixture.today)
    await f.backend.set(grants: grants([.satinalmaWrite, .stokRead], project: f.project.id))
    await vm.load()
    XCTAssertFalse(vm.canSeePrices)
    vm.cariAccountId = f.supplier.id
    vm.lines = [.init(materialId: f.plywood.id, quantityText: "5")]
    let saved = await vm.save()
    XCTAssertEqual(saved?.status, .taslak)
  }
}
