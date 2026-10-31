import Foundation
import RDCore
import RDSupabase
import XCTest

/// Gider/gelir repository'sinin yerel Supabase (seed.sql demo verisi) üzerinde
/// uçtan uca testi. Ayar yoksa atlanır. Yazan testler her çalıştırmada yeni
/// kimlikli demo belgeler açar; seed belgelerini değiştirmez.
final class FinanceRepositoryTests: XCTestCase {
  private let doc101 = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
  private let doc102 = UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
  private let doc103 = UUID(uuidString: "00000000-0000-4000-8000-000000000103")!
  private let doc105 = UUID(uuidString: "00000000-0000-4000-8000-000000000105")!
  private let companySource = UUID(uuidString: "00000000-0000-4000-8000-0000000000f1")!
  private let cardSource = UUID(uuidString: "00000000-0000-4000-8000-0000000000f4")!

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

  private func sivas(_ repos: Repositories) async throws -> Project {
    let projects = try await repos.projects.list(includeCompleted: true)
    return try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
  }

  func testSeedKeepsAccruedPaidAndRemainingApart() async throws {
    let repos = try await signedIn("muhasebe@example.test")
    let demir = try await repos.finance.document(id: doc101)
    XCTAssertEqual(demir.status, .onaylandi)
    XCTAssertEqual(demir.amount, 240_000)
    XCTAssertNotNil(demir.cariEntryId, "cari bağlantılı belge deftere işlenir")
    let statuses = try await repos.finance.statuses(documentIds: [doc101, doc102, doc103])
    let demirStatus = try XCTUnwrap(statuses.first { $0.documentId == doc101 })
    XCTAssertEqual(demirStatus.settlementState, .kismi)
    XCTAssertEqual(demirStatus.settledAmount, 100_000)
    XCTAssertEqual(demirStatus.remainingAmount, 140_000)
    XCTAssertTrue(demirStatus.isOverdue)
    XCTAssertEqual(statuses.first { $0.documentId == doc102 }?.settlementState, .kapandi)
    XCTAssertEqual(statuses.first { $0.documentId == doc103 }?.settlementState, .taslak)

    let card = try await repos.finance.settlements(documentId: doc102)
    XCTAssertEqual(card.map(\.paymentSourceId), [cardSource], "kişisel kartla peşin ödeme")
    XCTAssertNil(card.first?.cariEntryId, "carisiz gider deftere girmez; kart sahibine borç yazılmaz")

    let events = try await repos.finance.events(documentId: doc101)
    XCTAssertTrue(Set(events.map(\.action)).isSuperset(of: ["olustur", "onayla", "odeme"]))

    let open = try await repos.finance.openStatuses(kind: .gider)
    XCTAssertTrue(open.contains { $0.documentId == doc101 })
    XCTAssertFalse(open.contains { $0.documentId == doc102 }, "kapanan belge bekleyen borçta yok")

    let categories = try await repos.finance.categories(kind: .gider, includeInactive: false)
    XCTAssertTrue(categories.contains { $0.name == "Demir" }, "kategoriler veritabanından gelir")
  }

  func testReportsAndProjectCostsSeparateHakedisFromExpenses() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let bySource = try await repos.finance.report(kind: .gider, group: .kaynak, from: nil, to: nil, projectId: nil,
                                                  costCenterId: nil)
    XCTAssertTrue(bySource.contains { $0.label == "Kürşat kartı (demo)" && $0.settledTry >= Decimal(string: "4250.50")! })
    let byCategory = try await repos.finance.report(kind: .gider, group: .kategori, from: nil, to: nil, projectId: nil,
                                                    costCenterId: nil)
    let demirRow = try XCTUnwrap(byCategory.first { $0.label == "Demir" })
    XCTAssertEqual(demirRow.accruedTry - demirRow.settledTry, demirRow.openTry)
    let months = try await repos.finance.report(kind: .gider, group: .ay, from: nil, to: nil, projectId: nil, costCenterId: nil)
    XCTAssertEqual(months.map(\.groupKey), months.map(\.groupKey).sorted(), "aylık rapor sıralı")

    let project = try await sivas(repos)
    let fetched1 = try await repos.finance.projectCosts(projectId: project.id).first
    let cost = try XCTUnwrap(fetched1)
    XCTAssertNotNil(cost.hakedisAccruedTry, "yönetici hakediş sütununu görür")
    XCTAssertNotNil(cost.expenseAccruedTry)
    XCTAssertGreaterThan(cost.advancePaidTry ?? 0, 0, "avans ayrı sütundur")
    XCTAssertEqual(cost.expenseAccruedTry.map { $0 - (cost.expensePaidTry ?? 0) }, cost.expenseOpenTry)
  }

  func testExpenseFlowIsIdempotentAndCancellationKeepsHistory() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let project = try await sivas(repos)
    let categories = try await repos.finance.categories(kind: .gider, includeInactive: false)
    let nakliye = try XCTUnwrap(categories.first { $0.name == "Nakliye" })
    let id = UUID()
    let draft = FinanceDocumentDraft(kind: .gider, scope: .project(project.id), categoryId: nakliye.id,
                                     description: "Entegrasyon testi nakliye (demo)", amount: Decimal(string: "1000.10")!,
                                     documentDate: .today(), dueDate: CalendarDate.today().adding(days: 10))
    let created = try await repos.finance.saveDocument(id: id, draft: draft, expectedVersion: nil)
    let resent = try await repos.finance.saveDocument(id: id, draft: draft, expectedVersion: nil)
    XCTAssertEqual(created.documentNo, resent.documentNo, "tekrar gönderim aynı belgeyi döner")
    XCTAssertEqual(created.amount, Decimal(string: "1000.10"), "tam ondalık")
    XCTAssertTrue(created.isDemo, "demo projedeki belge demo işaretlidir")

    let approved = try await repos.finance.approve(id: id, expectedVersion: created.version, settlementId: nil)
    XCTAssertEqual(approved.status, .onaylandi)
    let payment = FinanceSettlementDraft(documentId: id, amount: 400, paymentSourceId: companySource,
                                         settlementDate: .today(), settledBy: "Entegrasyon testi")
    _ = try await repos.finance.recordSettlement(payment)
    _ = try await repos.finance.recordSettlement(payment)
    let fetched2 = try await repos.finance.statuses(documentIds: [id]).first
    var status = try XCTUnwrap(fetched2)
    XCTAssertEqual(status.remainingAmount, Decimal(string: "600.10"), "tekrar gönderim çift ödeme açmaz")
    XCTAssertEqual(status.settlementState, .kismi)

    do {
      _ = try await repos.finance.recordSettlement(FinanceSettlementDraft(
        documentId: id, amount: 700, paymentSourceId: companySource, settlementDate: .today()))
      XCTFail("kalanı aşan ödeme reddedilmeli")
    } catch let error as RepositoryError {
      guard case .validation = error else { return XCTFail("beklenmeyen hata: \(error)") }
    }
    do {
      _ = try await repos.finance.cancel(id: id, reason: "Ödemesi olan belge iptal denemesi")
      XCTFail("ödemesi olan belge iptal edilemez")
    } catch is RepositoryError {}

    _ = try await repos.finance.cancelSettlement(id: payment.id, reason: "Entegrasyon testi ödeme iptali")
    let fetched3 = try await repos.finance.statuses(documentIds: [id]).first
    status = try XCTUnwrap(fetched3)
    XCTAssertEqual(status.settlementState, .acik)
    let cancelled = try await repos.finance.cancel(id: id, reason: "Entegrasyon testi belge iptali")
    XCTAssertEqual(cancelled.status, .iptal)
    let settlements = try await repos.finance.settlements(documentId: id)
    XCTAssertEqual(settlements.map(\.status), [.iptal], "iptal edilen ödeme geçmişte kalır")
    let events = try await repos.finance.events(documentId: id)
    XCTAssertTrue(Set(events.map(\.action)).isSuperset(of: ["olustur", "onayla", "odeme", "odeme_iptal", "iptal"]))
  }

  func testCariLinkedIncomePostsLedgerOnceAndCollectionAllocates() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let project = try await sivas(repos)
    let fetched4 = try await repos.finance.document(id: doc105).cariAccountId
    let musteri = try XCTUnwrap(fetched4)
    let categories = try await repos.finance.categories(kind: .gelir, includeInactive: false)
    let category = try XCTUnwrap(categories.first { $0.name == "Satış geliri" })
    let id = UUID()
    let invoice = "ENT-\(id.uuidString.prefix(8))"
    _ = try await repos.finance.saveDocument(id: id, draft: FinanceDocumentDraft(
      kind: .gelir, scope: .project(project.id), categoryId: category.id, description: "Entegrasyon testi gelir (demo)",
      amount: 5_000, documentDate: .today(), cariAccountId: musteri, invoiceNo: invoice), expectedVersion: nil)
    _ = try await repos.finance.approve(id: id, expectedVersion: nil, settlementId: nil)
    _ = try await repos.finance.approve(id: id, expectedVersion: nil, settlementId: nil)
    _ = try await repos.finance.recordSettlement(FinanceSettlementDraft(
      documentId: id, amount: 2_000, paymentSourceId: companySource, settlementDate: .today()))
    let lines = try await repos.cari.statement(accountId: musteri, filter: CariFilter())
      .filter { $0.documentNo == invoice }
    XCTAssertEqual(lines.filter { $0.kind == .fatura }.count, 1, "alacak deftere bir kez yazılır")
    XCTAssertEqual(lines.filter { $0.kind == .tahsilat }.count, 1)
    XCTAssertEqual(lines.first { $0.kind == .fatura }?.direction, .borc)
  }

  func testSiteChiefQuickEntryWithoutSeeingOthersOrApproving() async throws {
    let repos = try await signedIn("sef@example.test")
    let visible = try await repos.finance.documents(filter: FinanceDocumentFilter(kind: .gider))
    XCTAssertFalse(visible.contains { $0.id == doc101 }, "şef muhasebenin girdiği gideri görmez")
    let income = try await repos.finance.documents(filter: FinanceDocumentFilter(kind: .gelir))
    XCTAssertTrue(income.isEmpty)

    let project = try await sivas(repos)
    let categories = try await repos.finance.categories(kind: .gider, includeInactive: false)
    let fuel = try XCTUnwrap(categories.first { $0.name == "Akaryakıt" })
    let id = UUID()
    let doc = try await repos.finance.saveDocument(id: id, draft: FinanceDocumentDraft(
      kind: .gider, scope: .project(project.id), categoryId: fuel.id, description: "Şantiye jeneratör yakıtı (demo)",
      amount: 850, documentDate: .today(), reportedSettled: true, reportedSourceId: cardSource,
      reportedBy: "Şantiye şefi"), expectedVersion: nil)
    XCTAssertEqual(doc.status, .taslak)
    let own = try await repos.finance.documents(filter: FinanceDocumentFilter(kind: .gider))
    XCTAssertTrue(own.contains { $0.id == id }, "kendi girdiğini görür")
    do {
      _ = try await repos.finance.approve(id: id, expectedVersion: nil, settlementId: nil)
      XCTFail("şef onaylayamaz")
    } catch let error as RepositoryError {
      guard case .forbidden = error else { return XCTFail("beklenmeyen hata: \(error)") }
    }
    do {
      _ = try await repos.finance.report(kind: .gider, group: .proje, from: nil, to: nil, projectId: nil, costCenterId: nil)
        .first.map { _ in XCTFail("şef rapor satırı görmemeli") }
    } catch is RepositoryError {}
  }
}
