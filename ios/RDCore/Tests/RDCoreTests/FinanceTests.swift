import Foundation
import XCTest
@testable import RDCore

private func grants(_ keys: [PermissionKey], project: UUID? = nil) -> [PermissionGrant] {
  keys.map { PermissionGrant(projectId: project, permissionKey: $0.rawValue) }
}

/// Bellek içi sunucu: proje, genel ofis, demir tedarikçisi, kategoriler ve
/// iki ödeme kaynağı (şirket, kişisel kart). Bugün 2026-10-31.
private struct Fixture {
  let backend: InMemoryBackend
  let repo: FinanceRepository
  let project = Project(code: "T-1", name: "Test projesi", status: .devam)
  let other = Project(code: "T-2", name: "Diğer proje", status: .devam)
  let office = CostCenter(code: "OFIS", name: "Merkez ofis")
  let supplier = CariAccount(code: "C-1", title: "Test Demir", type: .tedarikci)
  let demoSupplier = CariAccount(code: "C-2", title: "Demo Tedarikçi", type: .tedarikci, isDemo: true)
  let customer = CariAccount(code: "C-3", title: "Test Alıcı", type: .musteri)
  let demir = FinanceCategory(kind: .gider, name: "Demir", sortOrder: 10)
  let yakit = FinanceCategory(kind: .gider, name: "Akaryakıt", sortOrder: 70)
  let pasif = FinanceCategory(kind: .gider, name: "Eski kategori", isActive: false)
  let satis = FinanceCategory(kind: .gelir, name: "Satış geliri", sortOrder: 10)
  let company = PaymentSource(name: "Şirket", kind: .sirket)
  let card = PaymentSource(name: "Kürşat kartı", kind: .kart)
  static let today = CalendarDate(year: 2026, month: 10, day: 31)

  init(grants: [PermissionGrant]? = nil) async {
    backend = InMemoryBackend(grants: grants ?? PermissionKey.allCases.map {
      PermissionGrant(projectId: nil, permissionKey: $0.rawValue)
    })
    repo = backend.repositories.finance
    await backend.seed(projects: [project, other], costCenters: [office], accounts: [supplier, demoSupplier, customer])
    await backend.seedFinance(categories: [demir, yakit, pasif, satis], paymentSources: [company, card])
    await backend.set(today: Self.today)
  }

  func expense(_ amount: Decimal = 10_000, cari: UUID? = nil, scope: FinanceScope? = nil,
               due: CalendarDate? = nil, date: CalendarDate = CalendarDate(year: 2026, month: 10, day: 1)) -> FinanceDocumentDraft {
    FinanceDocumentDraft(kind: .gider, scope: scope ?? .project(project.id), categoryId: demir.id,
                         description: "Demir alımı", amount: amount, documentDate: date, dueDate: due,
                         cariAccountId: cari)
  }

  func cariEntries() async -> [InMemoryBackend.StoredEntry] { await backend.entries }
}

// MARK: - Kurallar

final class FinanceMathTests: XCTestCase {
  func testStatusDistinguishesUnpaidPartialAndPaid() {
    let today = CalendarDate(year: 2026, month: 10, day: 31)
    var doc = FinanceDocument(kind: .gider, documentNo: "GD-1", status: .onaylandi, scope: .project(UUID()),
                              categoryId: UUID(), description: "x", documentDate: CalendarDate(year: 2026, month: 10, day: 1),
                              dueDate: CalendarDate(year: 2026, month: 10, day: 20), amount: 1_000)
    XCTAssertEqual(FinanceMath.status(of: doc, settlements: [], today: today).settlementState, .acik)
    let part = FinanceSettlement(documentId: doc.id, kind: .odeme, amount: 400, settlementDate: today, paymentSourceId: UUID())
    let status = FinanceMath.status(of: doc, settlements: [part], today: today)
    XCTAssertEqual(status.settlementState, .kismi)
    XCTAssertEqual(status.remainingAmount, 600)
    XCTAssertTrue(status.isOverdue)
    XCTAssertEqual(status.daysOverdue, 11)
    var cancelled = part
    cancelled.status = .iptal
    XCTAssertEqual(FinanceMath.status(of: doc, settlements: [cancelled], today: today).remainingAmount, 1_000,
                   "iptal edilen ödeme kalanı azaltmaz")
    let rest = FinanceSettlement(documentId: doc.id, kind: .odeme, amount: 600, settlementDate: today, paymentSourceId: UUID())
    let closed = FinanceMath.status(of: doc, settlements: [part, rest], today: today)
    XCTAssertEqual(closed.settlementState, .kapandi)
    XCTAssertFalse(closed.isOverdue, "kapanan belge gecikmiş sayılmaz")
    doc.status = .taslak
    let draft = FinanceMath.status(of: doc, settlements: [], today: today)
    XCTAssertEqual(draft.remainingAmount, 0, "onaysız belge borç doğurmaz")
    XCTAssertFalse(draft.isOverdue)
  }

  func testStateTitlesSeparateExpenseAndIncome() {
    XCTAssertEqual(FinanceSettlementState.kismi.title(for: .gider), "Kısmen ödendi")
    XCTAssertEqual(FinanceSettlementState.kismi.title(for: .gelir), "Kısmen tahsil edildi")
    XCTAssertEqual(FinanceSettlementState.acik.title(for: .gider), "Ödenmedi")
  }

  func testTryConversionRoundsTwoDecimals() {
    XCTAssertEqual(FinanceMath.toTry(Decimal(string: "100.10")!, rate: Decimal(string: "34.123456")!),
                   Decimal(string: "3415.76"))
    XCTAssertEqual(FinanceMath.toTry(Decimal(string: "0.01")!, rate: Decimal(string: "0.5")!), Decimal(string: "0.01"))
  }

  func testModulesFollowFinancePermissions() {
    let project = UUID()
    let chief = AccessControl(grants: grants([.giderWrite, .projeRead], project: project))
    XCTAssertTrue(AppModule.giderler.isVisible(for: chief), "şantiye şefi hızlı gider girer")
    XCTAssertFalse(AppModule.borclar.isVisible(for: chief), "borç listesi okuma izni ister")
    XCTAssertFalse(AppModule.gelirler.isVisible(for: chief))
    XCTAssertFalse(AppModule.raporlar.isVisible(for: chief))
    let accounting = AccessControl(grants: grants([.giderRead, .gelirRead, .finansRaporRead]))
    XCTAssertTrue(AppModule.borclar.isVisible(for: accounting))
    XCTAssertTrue(AppModule.gelirler.isVisible(for: accounting))
    XCTAssertTrue(AppModule.raporlar.isVisible(for: accounting))
  }
}

// MARK: - Belge, onay ve ödeme

final class FinanceRepositoryTests: XCTestCase {
  func testCreateIsDraftAndCreatesNoDebtOrCariEntry() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(cari: f.supplier.id), expectedVersion: nil)
    XCTAssertEqual(doc.status, .taslak)
    XCTAssertEqual(doc.documentNo, "GD-000001")
    XCTAssertEqual(doc.dueDate, doc.documentDate, "vade boşsa peşin (belge tarihi)")
    let status = try await f.repo.statuses(documentIds: [doc.id]).first
    XCTAssertEqual(status?.settlementState, .taslak)
    XCTAssertEqual(status?.remainingAmount, 0)
    let entries = await f.cariEntries()
    XCTAssertTrue(entries.isEmpty, "taslak cari deftere yazılmaz")
  }

  func testResendWithSameIdReturnsSameDocumentAndDifferentContentConflicts() async throws {
    let f = await Fixture()
    let id = UUID()
    let first = try await f.repo.saveDocument(id: id, draft: f.expense(), expectedVersion: nil)
    let again = try await f.repo.saveDocument(id: id, draft: f.expense(), expectedVersion: nil)
    XCTAssertEqual(first, again)
    let docs = try await f.repo.documents(filter: FinanceDocumentFilter(kind: .gider))
    XCTAssertEqual(docs.count, 1, "tekrar gönderim ikinci belge açmaz")
    do {
      _ = try await f.repo.saveDocument(id: id, draft: f.expense(20_000), expectedVersion: nil)
      XCTFail("farklı içerik aynı kimlikle kabul edilmemeli")
    } catch RepositoryError.conflict {}
  }

  func testValidationRejectsBadInput() async throws {
    let f = await Fixture()
    func rejects(_ draft: FinanceDocumentDraft, _ label: String) async {
      do {
        _ = try await f.repo.saveDocument(id: UUID(), draft: draft, expectedVersion: nil)
        XCTFail(label)
      } catch {}
    }
    await rejects(f.expense(0), "sıfır tutar")
    await rejects(f.expense(Decimal(string: "10.005")!), "üç ondalık")
    var noDesc = f.expense()
    noDesc.description = "  "
    await rejects(noDesc, "boş açıklama")
    await rejects(f.expense(due: CalendarDate(year: 2026, month: 9, day: 1)), "vade belge tarihinden önce")
    var usd = f.expense()
    usd.currency = "USD"
    await rejects(usd, "döviz kuru yok")
    var passive = f.expense()
    passive.categoryId = f.pasif.id
    await rejects(passive, "pasif kategori")
    var wrongKind = f.expense()
    wrongKind.categoryId = f.satis.id
    await rejects(wrongKind, "gelir kategorisi gidere")
    await rejects(f.expense(cari: f.demoSupplier.id), "demo cari gerçek projede")
    var reported = f.expense()
    reported.reportedSettled = true
    await rejects(reported, "peşin ödendi ama kaynak yok")
  }

  func testApproveCreatesSingleCariEntryAndIsIdempotent() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(cari: f.supplier.id), expectedVersion: nil)
    let approved = try await f.repo.approve(id: doc.id, expectedVersion: doc.version, settlementId: nil)
    XCTAssertEqual(approved.status, .onaylandi)
    _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
    let entries = await f.cariEntries()
    XCTAssertEqual(entries.count, 1, "tekrar onay ikinci yükümlülük açmaz")
    XCTAssertEqual(entries.first?.draft.direction, .alacak)
    XCTAssertEqual(entries.first?.draft.kind, .gider)
    let status = try await f.repo.statuses(documentIds: [doc.id]).first
    XCTAssertEqual(status?.settlementState, .acik)
    XCTAssertEqual(status?.remainingAmount, 10_000)
  }

  func testApproveWithStaleVersionConflicts() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(), expectedVersion: nil)
    _ = try await f.repo.saveDocument(id: doc.id, draft: f.expense(12_000), expectedVersion: doc.version)
    do {
      _ = try await f.repo.approve(id: doc.id, expectedVersion: doc.version, settlementId: nil)
      XCTFail("onaylayan kişinin gördüğü sürüm eskidi")
    } catch RepositoryError.conflict {}
  }

  func testApprovedDocumentCannotBeEdited() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(), expectedVersion: nil)
    let approved = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
    do {
      _ = try await f.repo.saveDocument(id: doc.id, draft: f.expense(1), expectedVersion: approved.version)
      XCTFail("onaylı belge düzenlenemez")
    } catch RepositoryError.validation {}
  }

  func testPartialPaymentsCannotExceedRemaining() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(cari: f.supplier.id), expectedVersion: nil)
    _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
    let p1 = FinanceSettlementDraft(documentId: doc.id, amount: 4_000, paymentSourceId: f.company.id,
                                    settlementDate: Fixture.today)
    _ = try await f.repo.recordSettlement(p1)
    _ = try await f.repo.recordSettlement(p1)  // tekrar gönderim
    var status = try await f.repo.statuses(documentIds: [doc.id]).first
    XCTAssertEqual(status?.settlementState, .kismi)
    XCTAssertEqual(status?.remainingAmount, 6_000, "tekrar gönderim çift ödeme açmaz")
    do {
      _ = try await f.repo.recordSettlement(FinanceSettlementDraft(documentId: doc.id, amount: 6_000.01,
                                                                   paymentSourceId: f.company.id, settlementDate: Fixture.today))
      XCTFail("kalanı aşan ödeme")
    } catch RepositoryError.validation {}
    do {
      var changed = p1
      changed.amount = 5_000
      _ = try await f.repo.recordSettlement(changed)
      XCTFail("aynı kimlikle farklı tutar")
    } catch RepositoryError.conflict {}
    _ = try await f.repo.recordSettlement(FinanceSettlementDraft(documentId: doc.id, amount: 6_000,
                                                                 paymentSourceId: f.card.id, settlementDate: Fixture.today))
    status = try await f.repo.statuses(documentIds: [doc.id]).first
    XCTAssertEqual(status?.settlementState, .kapandi)
    let entries = await f.cariEntries()
    XCTAssertEqual(entries.count, 3, "bir yükümlülük + iki ödeme")
    XCTAssertEqual(entries.filter { $0.draft.kind == .odeme }.map(\.draft.amount), [4_000, 6_000])
  }

  func testPaymentRequiresApprovedDocument() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(), expectedVersion: nil)
    do {
      _ = try await f.repo.recordSettlement(FinanceSettlementDraft(documentId: doc.id, amount: 1, paymentSourceId: f.company.id,
                                                                   settlementDate: Fixture.today))
      XCTFail("taslak belgeye ödeme yapılmaz")
    } catch RepositoryError.validation {}
  }

  func testCancelSettlementReversesAndReopens() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(cari: f.supplier.id), expectedVersion: nil)
    _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
    let payment = try await f.repo.recordSettlement(FinanceSettlementDraft(
      documentId: doc.id, amount: 10_000, paymentSourceId: f.company.id, settlementDate: Fixture.today))
    do {
      _ = try await f.repo.cancelSettlement(id: payment.id, reason: "kısa")
      XCTFail("gerekçe en az 10 karakter")
    } catch RepositoryError.validation {}
    do {
      _ = try await f.repo.cancel(id: doc.id, reason: "Yanlış belge girildi")
      XCTFail("ödemesi olan belge iptal edilemez")
    } catch RepositoryError.validation {}
    let cancelled = try await f.repo.cancelSettlement(id: payment.id, reason: "Yanlış hesaptan ödendi")
    XCTAssertEqual(cancelled.status, .iptal)
    let status = try await f.repo.statuses(documentIds: [doc.id]).first
    XCTAssertEqual(status?.settlementState, .acik)
    let entries = await f.cariEntries()
    XCTAssertEqual(entries.filter { $0.reversalOf != nil }.count, 1, "ödeme ters kayıtla kapanır, silinmez")
    let settlements = try await f.repo.settlements(documentId: doc.id)
    XCTAssertEqual(settlements.count, 1, "iptal edilen ödeme geçmişte kalır")
  }

  func testReportedCardPaymentBecomesSettlementOnApprovalWithoutDebtToCardOwner() async throws {
    let f = await Fixture()
    var draft = f.expense(4_250.50)
    draft.categoryId = f.yakit.id
    draft.reportedSettled = true
    draft.reportedSourceId = f.card.id
    draft.reportedBy = "Kürşat"
    let doc = try await f.repo.saveDocument(id: UUID(), draft: draft, expectedVersion: nil)
    let settlementId = UUID()
    _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: settlementId)
    _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: UUID())
    let settlements = try await f.repo.settlements(documentId: doc.id)
    XCTAssertEqual(settlements.map(\.id), [settlementId], "peşin ödeme tek kayıt")
    XCTAssertEqual(settlements.first?.paymentSourceId, f.card.id)
    XCTAssertEqual(settlements.first?.settledBy, "Kürşat")
    let status = try await f.repo.statuses(documentIds: [doc.id]).first
    XCTAssertEqual(status?.settlementState, .kapandi)
    let entries = await f.cariEntries()
    XCTAssertTrue(entries.isEmpty, "kart sahibine otomatik ikinci borç yazılmaz; carisiz gider deftere girmez")
  }

  func testReportedSettlementNeedsPayPermissionToApprove() async throws {
    let f = await Fixture(grants: grants([.giderRead, .giderWrite, .giderApprove]))
    var draft = f.expense()
    draft.reportedSettled = true
    draft.reportedSourceId = f.card.id
    let doc = try await f.repo.saveDocument(id: UUID(), draft: draft, expectedVersion: nil)
    do {
      _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
      XCTFail("ödeme yetkisi olmadan peşin belge onaylanmaz")
    } catch RepositoryError.forbidden {}
  }

  func testSiteChiefSeesOnlyOwnEntriesAndCannotApproveOrPay() async throws {
    let f = await Fixture()
    await f.backend.set(profile: UserProfile(id: UUID(), email: "muhasebe@example.test", fullName: "Muhasebe"))
    let accountantDoc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(), expectedVersion: nil)
    await f.backend.set(profile: UserProfile(id: UUID(), email: "sef@example.test", fullName: "Şef"))
    await f.backend.set(grants: grants([.giderWrite], project: f.project.id))
    let own = try await f.repo.saveDocument(id: UUID(), draft: f.expense(500), expectedVersion: nil)
    let visible = try await f.repo.documents(filter: FinanceDocumentFilter(kind: .gider))
    XCTAssertEqual(visible.map(\.id), [own.id], "şantiye şefi yalnızca kendi girdiğini görür")
    do {
      _ = try await f.repo.document(id: accountantDoc.id)
      XCTFail("başkasının belgesi görünmemeli")
    } catch RepositoryError.notFound {}
    do {
      _ = try await f.repo.approve(id: own.id, expectedVersion: nil, settlementId: nil)
      XCTFail("şef onaylayamaz")
    } catch RepositoryError.forbidden {}
    do {
      _ = try await f.repo.saveDocument(id: UUID(), draft: f.expense(scope: .project(f.other.id)), expectedVersion: nil)
      XCTFail("yetkisi olmayan projeye gider girilemez")
    } catch RepositoryError.forbidden {}
    do {
      _ = try await f.repo.saveDocument(id: UUID(), draft: f.expense(scope: .costCenter(f.office.id)), expectedVersion: nil)
      XCTFail("genel masraf merkezi genel izin ister")
    } catch RepositoryError.forbidden {}
  }

  func testReviseCancelsWithReversalAndOpensReplacementDraft() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(cari: f.supplier.id), expectedVersion: nil)
    _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
    let newId = UUID()
    let copy = try await f.repo.revise(id: doc.id, newId: newId, reason: "Fatura tutarı hatalı girildi")
    let again = try await f.repo.revise(id: doc.id, newId: newId, reason: "Fatura tutarı hatalı girildi")
    XCTAssertEqual(copy.id, again.id, "tekrar çağrı aynı taslağı döner")
    XCTAssertEqual(copy.replacesId, doc.id)
    XCTAssertEqual(copy.status, .taslak)
    let old = try await f.repo.document(id: doc.id)
    XCTAssertEqual(old.status, .iptal)
    let entries = await f.cariEntries()
    XCTAssertEqual(entries.count, 2, "asıl kayıt ve ters kaydı; silme yok")
    let events = try await f.repo.events(documentId: doc.id)
    XCTAssertTrue(events.contains { $0.action == "duzelt" && $0.reason == "Fatura tutarı hatalı girildi" })
  }

  func testIncomeCollectionPostsReceivableOnce() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: FinanceDocumentDraft(
      kind: .gelir, scope: .project(f.project.id), categoryId: f.satis.id, description: "Daire satışı peşinat",
      amount: 750_000, documentDate: Fixture.today, dueDate: Fixture.today.adding(days: 30), cariAccountId: f.customer.id),
      expectedVersion: nil)
    XCTAssertTrue(doc.documentNo.hasPrefix("GL-"))
    _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
    _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
    _ = try await f.repo.recordSettlement(FinanceSettlementDraft(documentId: doc.id, amount: 250_000,
                                                                 paymentSourceId: f.company.id, settlementDate: Fixture.today))
    let entries = await f.cariEntries()
    XCTAssertEqual(entries.filter { $0.draft.kind == .fatura }.count, 1, "alacak deftere bir kez yazılır")
    XCTAssertEqual(entries.first { $0.draft.kind == .fatura }?.draft.direction, .borc)
    XCTAssertEqual(entries.first { $0.draft.kind == .tahsilat }?.draft.direction, .alacak)
    let open = try await f.repo.openStatuses(kind: .gelir)
    XCTAssertEqual(open.first?.remainingAmount, 500_000)
  }

  func testForeignCurrencyNeedsExplicitRateAndReportsTryAtDocumentRate() async throws {
    let f = await Fixture()
    var draft = f.expense(1_000)
    draft.currency = "USD"
    draft.exchangeRate = Decimal(string: "34.5")
    let doc = try await f.repo.saveDocument(id: UUID(), draft: draft, expectedVersion: nil)
    XCTAssertEqual(doc.amountTry, 34_500)
    _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
    do {
      _ = try await f.repo.recordSettlement(FinanceSettlementDraft(documentId: doc.id, amount: 100,
                                                                   paymentSourceId: f.company.id, settlementDate: Fixture.today))
      XCTFail("dövizli ödemede kur zorunlu")
    } catch RepositoryError.validation {}
    _ = try await f.repo.recordSettlement(FinanceSettlementDraft(
      documentId: doc.id, amount: 400, paymentSourceId: f.company.id, settlementDate: Fixture.today,
      exchangeRate: Decimal(string: "35")))
    let status = try await f.repo.statuses(documentIds: [doc.id]).first
    XCTAssertEqual(status?.remainingAmount, 600)
    XCTAssertEqual(status?.settledTry, 14_000, "ödeme kendi kuruyla")
    XCTAssertEqual(status?.remainingTry, 20_700, "kalan belge kuruyla; kur farkı hesaplanmaz")
  }

  func testReportsSeparateAccruedPaidOpenAndOverdue() async throws {
    let f = await Fixture()
    let a = try await f.repo.saveDocument(id: UUID(), draft: f.expense(10_000, due: CalendarDate(year: 2026, month: 10, day: 15)),
                                          expectedVersion: nil)
    _ = try await f.repo.approve(id: a.id, expectedVersion: nil, settlementId: nil)
    _ = try await f.repo.recordSettlement(FinanceSettlementDraft(documentId: a.id, amount: 3_000, paymentSourceId: f.card.id,
                                                                 settlementDate: Fixture.today))
    var b = f.expense(5_000, due: CalendarDate(year: 2026, month: 11, day: 30))
    b.categoryId = f.yakit.id
    let bDoc = try await f.repo.saveDocument(id: UUID(), draft: b, expectedVersion: nil)
    _ = try await f.repo.approve(id: bDoc.id, expectedVersion: nil, settlementId: nil)
    _ = try await f.repo.saveDocument(id: UUID(), draft: f.expense(99_999), expectedVersion: nil)  // taslak: raporda yok

    let byCategory = try await f.repo.report(kind: .gider, group: .kategori, from: nil, to: nil, projectId: nil, costCenterId: nil)
    XCTAssertEqual(byCategory.reduce(0) { $0 + $1.accruedTry }, 15_000, "taslak tahakkuk sayılmaz")
    let demirRow = try XCTUnwrap(byCategory.first { $0.label == "Demir" })
    XCTAssertEqual(demirRow.settledTry, 3_000)
    XCTAssertEqual(demirRow.openTry, 7_000)
    XCTAssertEqual(demirRow.overdueTry, 7_000)
    let bySource = try await f.repo.report(kind: .gider, group: .kaynak, from: nil, to: nil, projectId: nil, costCenterId: nil)
    XCTAssertEqual(bySource.map(\.label), ["Kürşat kartı"])
    XCTAssertEqual(bySource.first?.settledTry, 3_000)
    let costs = try await f.repo.projectCosts(projectId: f.project.id)
    XCTAssertEqual(costs.first?.expenseAccruedTry, 15_000)
    XCTAssertEqual(costs.first?.expensePaidTry, 3_000)
    XCTAssertEqual(costs.first?.expenseOpenTry, 12_000)
    XCTAssertEqual(costs.first?.hakedisAccruedTry, 0, "hakediş gider tablosuna yazılmaz, ayrı sütundur")
  }

  func testReportHidesRowsWithoutReportPermission() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(), expectedVersion: nil)
    _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
    await f.backend.set(grants: grants([.giderRead]))
    let rows = try await f.repo.report(kind: .gider, group: .proje, from: nil, to: nil, projectId: nil, costCenterId: nil)
    XCTAssertTrue(rows.isEmpty)
    await f.backend.set(grants: grants([.finansRaporRead]))
    let costs = try await f.repo.projectCosts(projectId: nil)
    XCTAssertNil(costs.first?.expenseAccruedTry, "gider okuma izni yoksa gider sütunu boş")
    XCTAssertNil(costs.first?.hakedisAccruedTry, "hakediş okuma izni yoksa hakediş sütunu boş")
  }

  func testCategoriesAreDataAndManagedWithPermission() async throws {
    let f = await Fixture()
    let new = try await f.repo.saveCategory(FinanceCategory(kind: .gider, name: "  Elektrik  "))
    XCTAssertEqual(new.name, "Elektrik")
    do {
      _ = try await f.repo.saveCategory(FinanceCategory(kind: .gider, name: "demir"))
      XCTFail("aynı ad (büyük/küçük harf farkıyla) tekrar eklenmez")
    } catch RepositoryError.conflict {}
    var passive = new
    passive.isActive = false
    _ = try await f.repo.saveCategory(passive)
    let active = try await f.repo.categories(kind: .gider, includeInactive: false)
    XCTAssertFalse(active.contains { $0.id == new.id })
    await f.backend.set(grants: grants([.giderWrite]))
    do {
      _ = try await f.repo.saveCategory(FinanceCategory(kind: .gider, name: "Yetkisiz"))
      XCTFail("kategori yönetimi izin ister")
    } catch RepositoryError.forbidden {}
  }
}

// MARK: - View model'ler

@MainActor
final class FinanceViewModelTests: XCTestCase {
  func testFormRequiresOnlyFewFieldsAndKeepsIdForRetry() async throws {
    let f = await Fixture()
    let access = AccessControl(grants: await f.backend.grants)
    let form = FinanceDocumentFormViewModel(kind: .gider, access: access, projects: [f.project], costCenters: [f.office],
                                            repositories: f.backend.repositories)
    await form.loadLookups()
    XCTAssertEqual(form.projectId, f.project.id, "tek proje otomatik seçilir")
    XCTAssertEqual(form.validationMessage, "Kategori seçin.")
    form.categoryId = f.demir.id
    form.descriptionText = "Bağ teli"
    form.amountText = "1.250,50"
    XCTAssertNil(form.validationMessage)
    await f.backend.set(nextError: .network)
    let failed = await form.save()
    XCTAssertNil(failed)
    let id = form.documentId
    let result = await form.save()
    let saved = try XCTUnwrap(result)
    XCTAssertEqual(saved.id, id, "ağ hatasından sonra aynı kimlikle tekrar gönderilir")
    XCTAssertEqual(saved.amount, Decimal(string: "1250.50"))
    form.resetForNext()
    XCTAssertNotEqual(form.documentId, id)
    XCTAssertEqual(form.categoryId, f.demir.id, "kaydet ve yeni: kategori korunur")
    XCTAssertEqual(form.amountText, "")
  }

  func testFormForeignCurrencyAndReportedPaymentValidation() async {
    let f = await Fixture()
    let access = AccessControl(grants: await f.backend.grants)
    let form = FinanceDocumentFormViewModel(kind: .gider, access: access, projects: [f.project], costCenters: [],
                                            repositories: f.backend.repositories)
    form.categoryId = f.demir.id
    form.descriptionText = "İthal ekipman"
    form.amountText = "100"
    form.currency = "USD"
    XCTAssertEqual(form.validationMessage, "USD için kur zorunlu.")
    form.rateText = "34,1234567"
    XCTAssertEqual(form.validationMessage, "Kur en çok 6 ondalıklı olmalı.")
    form.rateText = "34,5"
    XCTAssertNil(form.validationMessage)
    form.reportedSettled = true
    XCTAssertEqual(form.validationMessage, "Ödemenin yapıldığı kaynağı seçin.")
    form.hasDueDate = true
    form.dueDate = Date(timeIntervalSinceNow: -86_400 * 30)
    form.reportedSourceId = f.card.id
    XCTAssertEqual(form.validationMessage, "Vade, belge tarihinden önce olamaz.")
  }

  func testDetailPermissionsAndSettlementRetryUsesSameId() async throws {
    let f = await Fixture()
    let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(cari: f.supplier.id), expectedVersion: nil)
    let access = AccessControl(grants: await f.backend.grants)
    let vm = FinanceDocumentDetailViewModel(document: doc, access: access, repositories: f.backend.repositories)
    await vm.load()
    XCTAssertTrue(vm.canApprove)
    XCTAssertTrue(vm.canEdit)
    XCTAssertFalse(vm.canSettle, "onaysız belgeye ödeme yok")
    let approved = await vm.approve()
    XCTAssertTrue(approved)
    XCTAssertTrue(vm.canSettle)
    XCTAssertFalse(vm.canEdit)
    XCTAssertTrue(vm.canRevise)

    await f.backend.set(nextError: .network)
    let firstTry = await vm.recordSettlement(amount: 2_500, sourceId: f.company.id, date: Fixture.today, settledBy: nil,
                                             description: nil, exchangeRate: nil)
    XCTAssertFalse(firstTry)
    let retryId = vm.pendingSettlementId
    let secondTry = await vm.recordSettlement(amount: 2_500, sourceId: f.company.id, date: Fixture.today, settledBy: nil,
                                              description: nil, exchangeRate: nil)
    XCTAssertTrue(secondTry)
    XCTAssertEqual(vm.settlements.map(\.id), [retryId])
    XCTAssertEqual(vm.stateTitle, "Kısmen ödendi")
    XCTAssertEqual(vm.remaining, 7_500)
    XCTAssertFalse(vm.canRevise, "ödemesi olan belge önce ödeme iptaliyle düzeltilir")
    XCTAssertFalse(vm.canCancel)
  }

  func testPayablesGroupOverdueThisWeekAndLater() async throws {
    let f = await Fixture()
    for (amount, due) in [(Decimal(1_000), CalendarDate(year: 2026, month: 10, day: 20)),
                          (Decimal(2_000), CalendarDate(year: 2026, month: 11, day: 3)),
                          (Decimal(3_000), CalendarDate(year: 2026, month: 12, day: 15))] {
      let doc = try await f.repo.saveDocument(id: UUID(), draft: f.expense(amount, due: due), expectedVersion: nil)
      _ = try await f.repo.approve(id: doc.id, expectedVersion: nil, settlementId: nil)
    }
    let paid = try await f.repo.saveDocument(id: UUID(), draft: f.expense(500), expectedVersion: nil)
    _ = try await f.repo.approve(id: paid.id, expectedVersion: nil, settlementId: nil)
    _ = try await f.repo.recordSettlement(FinanceSettlementDraft(documentId: paid.id, amount: 500, paymentSourceId: f.company.id,
                                                                 settlementDate: Fixture.today))
    let vm = PayablesViewModel(access: AccessControl(grants: await f.backend.grants), repositories: f.backend.repositories,
                               today: Fixture.today)
    await vm.load()
    XCTAssertEqual(vm.items.count, 3, "tamamen ödenen belge bekleyen borçta yok")
    XCTAssertEqual(vm.remainingTry(in: .gecikmis), 1_000)
    XCTAssertEqual(vm.remainingTry(in: .buHafta), 2_000)
    XCTAssertEqual(vm.remainingTry(in: .sonra), 3_000)
  }

  func testListFiltersAndSearch() async throws {
    let f = await Fixture()
    let a = try await f.repo.saveDocument(id: UUID(), draft: f.expense(cari: f.supplier.id), expectedVersion: nil)
    _ = try await f.repo.approve(id: a.id, expectedVersion: nil, settlementId: nil)
    var fuel = f.expense(750)
    fuel.categoryId = f.yakit.id
    fuel.description = "Jeneratör motorini"
    _ = try await f.repo.saveDocument(id: UUID(), draft: fuel, expectedVersion: nil)
    let vm = FinanceDocumentListViewModel(kind: .gider, access: AccessControl(grants: await f.backend.grants),
                                          repositories: f.backend.repositories, today: Fixture.today)
    await vm.load()
    XCTAssertEqual(vm.filtered.count, 2)
    vm.stateFilter = .onayBekleyen
    XCTAssertEqual(vm.filtered.map(\.description), ["Jeneratör motorini"])
    vm.stateFilter = .acik
    XCTAssertEqual(vm.filtered.map(\.id), [a.id])
    vm.stateFilter = .tumu
    vm.searchText = "test demir"
    XCTAssertEqual(vm.filtered.map(\.id), [a.id], "cari adıyla arama")
    vm.searchText = "akaryakıt"
    XCTAssertEqual(vm.filtered.count, 1, "kategori adıyla arama")
    XCTAssertEqual(vm.pendingApprovalCount, 1)
  }

  func testPreviewDataBuildsConsistentFinanceSample() async throws {
    let backend = await PreviewData.financeBackend()
    let repo = backend.repositories.finance
    let expenses = try await repo.documents(filter: FinanceDocumentFilter(kind: .gider))
    XCTAssertEqual(expenses.count, 4)
    let open = try await repo.openStatuses(kind: .gider)
    XCTAssertEqual(open.count, 2, "kısmen ödenen demir ve ödenmemiş nakliye")
    let income = try await repo.openStatuses(kind: .gelir)
    XCTAssertEqual(income.first?.remainingAmount, 500_000)
  }
}
