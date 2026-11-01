import Foundation
import RDCore
import RDSupabase
import XCTest

/// Malzeme, stok ve satın alma repository'sinin yerel Supabase (seed.sql demo
/// verisi) üzerinde uçtan uca testi. Ayar yoksa atlanır. Yazan testler her
/// çalıştırmada yeni kimlikli DEMO genel depolar açar; seed depolarına ve
/// siparişlerine yazmaz (pgTAP eşzamanlılık testi seed stokuna dayanır).
final class InventoryRepositoryTests: XCTestCase {
  private let orderComplete = UUID(uuidString: "00000000-0000-4000-8000-000000000301")!
  private let orderPartial = UUID(uuidString: "00000000-0000-4000-8000-000000000302")!
  private let lineDemir = UUID(uuidString: "00000000-0000-4000-8000-000000000313")!
  private let expense101 = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
  private let pendingUsage = UUID(uuidString: "00000000-0000-4000-8000-000000000333")!

  private func signedIn(_ email: String) async throws -> Repositories {
    let env = ProcessInfo.processInfo.environment
    guard let raw = env["RD_SUPABASE_URL"], let url = URL(string: raw), let key = env["RD_SUPABASE_ANON_KEY"] else {
      throw XCTSkip("Yerel Supabase ayarı yok (RD_SUPABASE_URL / RD_SUPABASE_ANON_KEY)")
    }
    guard url.host == "127.0.0.1" || url.host == "localhost" else {
      XCTFail("Entegrasyon testleri yalnızca yerel Supabase'e bağlanır")
      throw XCTSkip("yerel olmayan adres")
    }
    let repos = SupabaseEnvironment.makeRepositories(config: SupabaseConfig(url: url, anonKey: key))
    _ = try await repos.auth.signIn(email: email, password: "yerel-test-1234")
    return repos
  }

  private func material(_ repos: Repositories, _ name: String) async throws -> Material {
    let list = try await repos.inventory.materials(search: name, categoryId: nil, includeInactive: false)
    return try XCTUnwrap(list.first { $0.name == name }, "seed malzemesi: \(name)")
  }

  /// Her testte yeni DEMO genel depo (seed depolarına dokunulmaz).
  private func freshWarehouse(_ repos: Repositories, _ label: String) async throws -> Warehouse {
    try await repos.inventory.saveWarehouse(id: UUID(), draft: WarehouseDraft(
      name: "Test \(label) \(UUID().uuidString.prefix(8))", isDemo: true), expectedVersion: nil)
  }

  private func stock(_ repos: Repositories, _ w: Warehouse, _ m: Material) async throws -> Decimal {
    try await repos.inventory.balances(warehouseId: w.id).first { $0.materialId == m.id }?.quantity ?? 0
  }

  private func expectError(_ match: (RepositoryError) -> Bool, _ label: String,
                           _ body: () async throws -> some Any) async {
    do {
      _ = try await body()
      XCTFail("hata bekleniyordu: \(label)")
    } catch let error as RepositoryError {
      XCTAssertTrue(match(error), "\(label): beklenmeyen hata \(error)")
    } catch {
      XCTFail("\(label): \(error)")
    }
  }

  private static func conflict(_ e: RepositoryError) -> Bool { if case .conflict = e { return true }; return false }
  private static func validation(_ e: RepositoryError) -> Bool { if case .validation = e { return true }; return false }
  private static func denied(_ e: RepositoryError) -> Bool {
    if case .forbidden = e { return true }
    return e == .notFound
  }

  // MARK: Seed

  func testSeedStockAndPurchaseState() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let units = try await repos.inventory.units(includeInactive: false)
    XCTAssertTrue(units.contains { $0.code == "torba" && $0.decimals == 0 }, "birimler veritabanından gelir")
    let categories = try await repos.inventory.categories(includeInactive: false)
    XCTAssertTrue(categories.contains { $0.name == "Kalıp ve iskele" })

    let projects = try await repos.projects.list(includeCompleted: true)
    let sivas = try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
    let warehouses = try await repos.inventory.warehouses(projectId: sivas.id, includeInactive: false)
    let main = try XCTUnwrap(warehouses.first(where: \.isDefault), "her projenin ana deposu var")
    XCTAssertTrue(main.isDemo)
    let plywood = try await material(repos, "Plywood")
    let plywoodStock = try await stock(repos, main, plywood)
    XCTAssertEqual(plywoodStock, 110, "160 teslim − 40 kullanım − 10 transfer")

    let complete = try await repos.inventory.purchaseOrder(id: orderComplete)
    XCTAssertEqual(complete.status, .tamamlandi)
    let partial = try await repos.inventory.purchaseOrder(id: orderPartial)
    XCTAssertEqual(partial.status, .kismiTeslim)
    let lines = try await repos.inventory.purchaseOrderLines(orderId: orderPartial)
    let demir = try XCTUnwrap(lines.first { $0.id == lineDemir })
    XCTAssertEqual(demir.baseQuantity, 12_000, "12 ton = 12.000 kg (açık oran)")
    XCTAssertEqual(demir.receivedBaseQuantity, 5_000)
    XCTAssertEqual(demir.remainingQuantity, 7)
    let prices = try await repos.inventory.purchaseOrderPrices(orderId: orderPartial)
    XCTAssertEqual(prices.first { $0.orderLineId == lineDemir }?.unitPrice, 20_000)

    let links = try await repos.inventory.expenseLinks(orderId: orderPartial, financeDocumentId: nil)
    XCTAssertEqual(links.filter { $0.status == .aktif }.map(\.financeDocumentId), [expense101])
    let receipts = try await repos.inventory.receipts(orderId: orderComplete)
    XCTAssertEqual(receipts.count, 2, "parça parça iki teslim")
    let events = try await repos.inventory.events(orderId: orderComplete)
    XCTAssertTrue(Set(events.map(\.action)).isSuperset(of: ["olustur", "onayla", "teslim"]))
  }

  func testChiefSeesStockButNotPricesAndCannotApprove() async throws {
    let repos = try await signedIn("sef@example.test")
    let warehouses = try await repos.inventory.warehouses(projectId: nil, includeInactive: false)
    XCTAssertFalse(warehouses.isEmpty)
    XCTAssertTrue(warehouses.allSatisfy { $0.projectId != nil }, "şef genel depoları görmez")
    let pending = try await repos.inventory.movement(id: pendingUsage)
    XCTAssertEqual(pending.status, .bekliyor, "şefin kullanım kaydı onay bekler")

    let lines = try await repos.inventory.purchaseOrderLines(orderId: orderComplete)
    XCTAssertFalse(lines.isEmpty, "şef teslim almak için satırları görür")
    await expectError(Self.denied, "şef fiyat göremez") { try await repos.inventory.purchaseOrderPrices(orderId: orderComplete) }
    await expectError(Self.denied, "şef sipariş onaylayamaz") {
      try await repos.inventory.transition(orderId: orderPartial, action: .kapat, reason: "Eksik teslimle kapatılsın",
                                           expectedVersion: nil)
    }
    await expectError(Self.denied, "şef stok onaylayamaz") {
      try await repos.inventory.approveMovement(id: pendingUsage, expectedVersion: nil)
    }
    let links = try await repos.inventory.expenseLinks(orderId: orderPartial, financeDocumentId: nil)
    XCTAssertTrue(links.isEmpty, "gider bağlantısı satinalma.read ister")
  }

  // MARK: Hareketler

  func testMovementIdempotencyConflictTransferAndReversal() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let plywood = try await material(repos, "Plywood")
    let a = try await freshWarehouse(repos, "A")
    let b = try await freshWarehouse(repos, "B")

    let entry = StockMovementDraft(kind: .giris, materialId: plywood.id, warehouseId: a.id, quantity: 10,
                                   description: "Entegrasyon girişi")
    let first = try await repos.inventory.createMovement(entry)
    XCTAssertEqual(first.status, .onaylandi)
    let replay = try await repos.inventory.createMovement(entry)
    XCTAssertEqual(replay.movementNo, first.movementNo, "tekrar gönderim aynı hareketi döner")
    var changed = entry
    changed.quantity = 11
    await expectError(Self.conflict, "aynı kimlik farklı içerik") { try await repos.inventory.createMovement(changed) }
    var stockA = try await stock(repos, a, plywood)
    XCTAssertEqual(stockA, 10)

    await expectError(Self.validation, "negatif stok") {
      try await repos.inventory.createMovement(StockMovementDraft(kind: .kullanim, materialId: plywood.id, warehouseId: a.id,
                                                                  quantity: 11))
    }
    _ = try await repos.inventory.createMovement(
      StockMovementDraft(kind: .transfer, materialId: plywood.id, warehouseId: a.id, quantity: 4, targetWarehouseId: b.id))
    stockA = try await stock(repos, a, plywood)
    var stockB = try await stock(repos, b, plywood)
    XCTAssertEqual(stockA, 6)
    XCTAssertEqual(stockB, 4)
    let back = try await repos.inventory.createMovement(
      StockMovementDraft(kind: .transfer, materialId: plywood.id, warehouseId: b.id, quantity: 1, targetWarehouseId: a.id))
    stockA = try await stock(repos, a, plywood)
    XCTAssertEqual(stockA, 7, "ters yönde transfer")

    let reversalId = UUID()
    let reversal = try await repos.inventory.reverseMovement(id: back.id, reversalId: reversalId,
                                                             reason: "Yanlış depoya aktarıldı")
    XCTAssertEqual(reversal.kind, .tersKayit)
    let again = try await repos.inventory.reverseMovement(id: back.id, reversalId: reversalId,
                                                          reason: "Yanlış depoya aktarıldı")
    XCTAssertEqual(again.id, reversal.id, "tekrar iptal ikinci ters kayıt açmaz")
    stockA = try await stock(repos, a, plywood)
    stockB = try await stock(repos, b, plywood)
    XCTAssertEqual(stockA, 6)
    XCTAssertEqual(stockB, 4)

    let count = try await repos.inventory.createMovement(
      StockMovementDraft(kind: .sayim, materialId: plywood.id, warehouseId: a.id, quantity: 4,
                         reason: "Entegrasyon sayımında 2 eksik"))
    XCTAssertEqual(count.adjustment, -2)
    let summary = try await repos.inventory.summary(warehouseId: a.id, from: nil, to: nil)
    let row = try XCTUnwrap(summary.first { $0.materialId == plywood.id })
    XCTAssertEqual(row.received, 10)
    XCTAssertEqual(row.transferred, -4, "giden 4, gelen 1 ve iptali")
    XCTAssertEqual(row.adjusted, -2)
    XCTAssertEqual(row.closing, 4)
    let history = try await repos.inventory.movements(filter: StockMovementFilter(warehouseId: a.id))
    XCTAssertEqual(history.count, 4, "giriş, iki transfer ve sayım; iptal edilen hareket silinmez")
    let historyB = try await repos.inventory.movements(filter: StockMovementFilter(warehouseId: b.id))
    XCTAssertEqual(historyB.filter { $0.kind == .tersKayit }.map(\.reversalOfId), [back.id], "ters kayıt asıl deponun geçmişinde")
  }

  func testDemoAndRealWarehousesCannotTransfer() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let plywood = try await material(repos, "Plywood")
    let demo = try await freshWarehouse(repos, "DEMO")
    let real = try await repos.inventory.saveWarehouse(id: UUID(), draft: WarehouseDraft(
      name: "Test gerçek \(UUID().uuidString.prefix(8))", isDemo: false), expectedVersion: nil)
    _ = try await repos.inventory.createMovement(StockMovementDraft(kind: .giris, materialId: plywood.id, warehouseId: demo.id,
                                                                    quantity: 2))
    await expectError(Self.validation, "DEMO→gerçek transfer") {
      try await repos.inventory.createMovement(StockMovementDraft(kind: .transfer, materialId: plywood.id, warehouseId: demo.id,
                                                                  quantity: 1, targetWarehouseId: real.id))
    }
    let chief = try await signedIn("sef@example.test")
    await expectError(Self.denied, "şef genel depoya hareket giremez") {
      try await chief.inventory.createMovement(StockMovementDraft(kind: .giris, materialId: plywood.id, warehouseId: demo.id,
                                                                  quantity: 1))
    }
  }

  // MARK: Satın alma

  func testPartialReceiptOverReceiptAndNoFinanceRecords() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let plywood = try await material(repos, "Plywood")
    let w = try await freshWarehouse(repos, "SA")
    let suppliers = try await repos.cari.listAccounts(type: nil, search: nil)
    let supplier = try XCTUnwrap(suppliers.first { $0.code == "DEMO-C06" })
    let expensesBefore = try await repos.finance.documents(filter: FinanceDocumentFilter(kind: .gider)).count
    let balancesBefore = try await repos.cari.balances(filter: CariFilter())

    let line = PurchaseOrderLineDraft(materialId: plywood.id, quantity: 10, unitPrice: Decimal(string: "125.50")!)
    let draft = PurchaseOrderDraft(cariAccountId: supplier.id, warehouseId: w.id, lines: [line],
                                   description: "Entegrasyon siparişi")
    let orderId = UUID()
    let order = try await repos.inventory.savePurchaseOrder(id: orderId, draft: draft, expectedVersion: nil)
    XCTAssertEqual(order.status, .taslak)
    let replay = try await repos.inventory.savePurchaseOrder(id: orderId, draft: draft, expectedVersion: nil)
    XCTAssertEqual(replay.orderNo, order.orderNo, "tekrar gönderim ikinci sipariş açmaz")
    let approved = try await repos.inventory.transition(orderId: orderId, action: .onayla, reason: nil,
                                                        expectedVersion: order.version)
    XCTAssertEqual(approved.status, .onaylandi)
    let prices = try await repos.inventory.purchaseOrderPrices(orderId: orderId)
    XCTAssertEqual(prices.first?.lineTotal, 1255)

    let firstReceipt = PurchaseReceiptDraft(orderId: orderId, lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 4)],
                                            waybillNo: "IRS-ENT-1")
    _ = try await repos.inventory.receive(firstReceipt)
    _ = try await repos.inventory.receive(firstReceipt)
    var stockNow = try await stock(repos, w, plywood)
    XCTAssertEqual(stockNow, 4, "aynı teslimin tekrarı ikinci stok girişi açmaz")
    var current = try await repos.inventory.purchaseOrder(id: orderId)
    XCTAssertEqual(current.status, .kismiTeslim)
    await expectError(Self.validation, "fazla teslim") {
      try await repos.inventory.receive(PurchaseReceiptDraft(orderId: orderId,
                                                             lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 7)]))
    }
    _ = try await repos.inventory.receive(PurchaseReceiptDraft(orderId: orderId,
                                                               lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 6)]))
    current = try await repos.inventory.purchaseOrder(id: orderId)
    XCTAssertEqual(current.status, .tamamlandi)
    stockNow = try await stock(repos, w, plywood)
    XCTAssertEqual(stockNow, 10)

    let expensesAfter = try await repos.finance.documents(filter: FinanceDocumentFilter(kind: .gider)).count
    let balancesAfter = try await repos.cari.balances(filter: CariFilter())
    XCTAssertEqual(expensesAfter, expensesBefore, "sipariş ve teslim gider kaydı açmaz")
    XCTAssertEqual(balancesAfter.first { $0.cariAccountId == supplier.id }?.balanceTry,
                   balancesBefore.first { $0.cariAccountId == supplier.id }?.balanceTry, "tedarikçiye borç yazılmaz")
  }

  func testExpenseCanBeLinkedOnlyOnce() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let before = try await repos.finance.document(id: expense101)
    await expectError(Self.conflict, "gider ikinci kez bağlanamaz") {
      try await repos.inventory.linkExpense(id: UUID(), orderId: orderPartial, financeDocumentId: expense101, note: nil)
    }
    let after = try await repos.finance.document(id: expense101)
    XCTAssertEqual(after, before, "bağlantı denemesi gider kaydını değiştirmez")
  }

  // MARK: PR #9 incelemesi: bağlantı bütünlüğü ve tekrar gönderim

  func testLinkedExpenseKeepsSupplierAndReplayComparesAllFields() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let plywood = try await material(repos, "Plywood")
    let projects = try await repos.projects.list(includeCompleted: true)
    let sivas = try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
    let sivasWarehouses = try await repos.inventory.warehouses(projectId: sivas.id, includeInactive: false)
    let main = try XCTUnwrap(sivasWarehouses.first(where: \.isDefault))
    let suppliers = try await repos.cari.listAccounts(type: nil, search: nil)
    let supplier = try XCTUnwrap(suppliers.first { $0.code == "DEMO-C06" })
    let otherSupplier = try XCTUnwrap(suppliers.first { $0.code == "DEMO-C03" })
    let categories = try await repos.finance.categories(kind: .gider, includeInactive: false)
    let category = try XCTUnwrap(categories.first)

    let line = PurchaseOrderLineDraft(materialId: plywood.id, quantity: 3)
    let orderId = UUID()
    let order = try await repos.inventory.savePurchaseOrder(
      id: orderId, draft: PurchaseOrderDraft(cariAccountId: supplier.id, warehouseId: main.id, lines: [line],
                                             description: "Entegrasyon bağlantı testi"), expectedVersion: nil)
    _ = try await repos.inventory.transition(orderId: orderId, action: .onayla, reason: nil, expectedVersion: order.version)

    func expenseDraft(_ cari: UUID?) -> FinanceDocumentDraft {
      FinanceDocumentDraft(kind: .gider, scope: .project(sivas.id), categoryId: category.id,
                           description: "Entegrasyon faturası", amount: 300, documentDate: CalendarDate.today(),
                           cariAccountId: cari)
    }
    let expenseId = UUID()
    let expense = try await repos.finance.saveDocument(id: expenseId, draft: expenseDraft(supplier.id), expectedVersion: nil)
    let linkId = UUID()
    _ = try await repos.inventory.linkExpense(id: linkId, orderId: orderId, financeDocumentId: expenseId, note: "İlk not")
    let replay = try await repos.inventory.linkExpense(id: linkId, orderId: orderId, financeDocumentId: expenseId, note: " İlk not ")
    XCTAssertEqual(replay.id, linkId, "aynı not aynı bağlantıyı döner")
    await expectError(Self.conflict, "aynı bağlantı kimliği farklı not") {
      try await repos.inventory.linkExpense(id: linkId, orderId: orderId, financeDocumentId: expenseId, note: "Başka not")
    }
    await expectError(Self.validation, "bağlı taslağın tedarikçisi değiştirilemez") {
      try await repos.finance.saveDocument(id: expenseId, draft: expenseDraft(otherSupplier.id), expectedVersion: expense.version)
    }
    await expectError(Self.validation, "gider bağlı sipariş iptal edilemez") {
      try await repos.inventory.transition(orderId: orderId, action: .iptal, reason: "Entegrasyon iptal denemesi",
                                           expectedVersion: nil)
    }
    let unchanged = try await repos.finance.document(id: expenseId)
    XCTAssertEqual(unchanged.cariAccountId, supplier.id)

    _ = try await repos.finance.cancel(id: expenseId, reason: "Entegrasyon temizliği")
    let links = try await repos.inventory.expenseLinks(orderId: orderId, financeDocumentId: nil)
    XCTAssertFalse(links.contains { $0.status == .aktif }, "iptal edilen giderin etkin bağlantısı kalmaz")

    let receipt = PurchaseReceiptDraft(orderId: orderId, lines: [PurchaseReceiptLineInput(orderLineId: line.id, quantity: 1)],
                                       performedBy: "Ali Usta")
    _ = try await repos.inventory.receive(receipt)
    var same = receipt
    same.performedBy = " Ali Usta "
    let again = try await repos.inventory.receive(same)
    XCTAssertEqual(again.id, receipt.id)
    var other = receipt
    other.performedBy = "Veli Usta"
    await expectError(Self.conflict, "aynı teslim kimliği farklı teslim alan kişi") { try await repos.inventory.receive(other) }
    let movements = try await repos.inventory.movements(filter: StockMovementFilter(purchaseOrderId: orderId))
    XCTAssertEqual(movements.count, 1, "tekrar gönderim ikinci stok girişi açmaz")
    // Temizlik: seed stoku değişmesin (pgTAP eşzamanlılık testi seed stokuna dayanır).
    _ = try await repos.inventory.cancelReceipt(id: receipt.id, reason: "Entegrasyon testi temizliği")
  }
}
