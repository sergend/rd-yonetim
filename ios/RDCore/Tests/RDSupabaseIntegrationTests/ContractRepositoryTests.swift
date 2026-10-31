import Foundation
import RDCore
import RDSupabase
import XCTest

/// Sözleşme ve hakediş repository'sinin yerel Supabase (seed.sql demo verisi)
/// üzerinde uçtan uca testi. Ayar yoksa atlanır. Yazan test her çalıştırmada
/// yeni bir demo sözleşme açar (benzersiz numara), seed verisini değiştirmez.
final class ContractRepositoryTests: XCTestCase {
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

  private func demoContract(_ repos: Repositories) async throws -> Contract {
    let contracts = try await repos.contracts.contracts(projectId: nil)
    return try XCTUnwrap(contracts.first { $0.contractNo == "DEMO-S-001" })
  }

  func testSeedContractKeepsGrossRetentionPayablePaidAndRemainingApart() async throws {
    let repos = try await signedIn("muhasebe@example.test")
    let contract = try await demoContract(repos)
    XCTAssertEqual(contract.status, .aktif)

    let hakedisler = try await repos.contracts.hakedisList(contractId: contract.id)
    let first = try XCTUnwrap(hakedisler.first { $0.hakedisNo == 1 })
    XCTAssertEqual(first.status, .onaylandi)
    XCTAssertTrue(first.isPosted)
    XCTAssertEqual(first.grossAmount, 312_000)
    XCTAssertEqual(first.retentionAmount, 31_200)
    XCTAssertEqual(first.advanceAmount, 50_000)
    XCTAssertEqual(first.payableAmount, 230_800)

    let status = try await repos.contracts.paymentStatus(hakedisIds: [first.id]).first
    XCTAssertEqual(status?.paidAmount, 150_000)
    XCTAssertEqual(status?.remainingAmount, 80_800)

    let lines = try await repos.contracts.lines(hakedisId: first.id)
    XCTAssertEqual(lines.reduce(Decimal.zero) { $0 + $1.amount }, 312_000)
    let adjustments = try await repos.contracts.adjustments(hakedisId: first.id)
    XCTAssertEqual(Set(adjustments.map(\.kind)), [.teminat, .avansMahsubu])

    let summary = try await repos.contracts.financeSummary(contractId: contract.id)
    XCTAssertGreaterThanOrEqual(summary.grossTotal, 312_000)
    XCTAssertEqual(summary.retentionBalance, summary.retentionWithheld - summary.retentionReleased)
    XCTAssertEqual(summary.remainingTotal, summary.payableTotal + summary.retentionReleased - summary.paidTotal)

    let events = try await repos.contracts.events(contractId: contract.id)
    XCTAssertTrue(events.contains { $0.entityId == first.id && $0.action == "deftere_isle" })
    let sources = try await repos.contracts.paymentSources()
    XCTAssertTrue(sources.contains { $0.kind == .sirket })
  }

  func testSiteChiefEntersImalatWithoutSeeingPricesOrFinance() async throws {
    let repos = try await signedIn("sef@example.test")
    let contracts = try await repos.contracts.contracts(projectId: nil)
    XCTAssertTrue(contracts.isEmpty, "şantiye şefi sözleşme fiyatlarını görmez")
    let hakedisler = try await repos.contracts.hakedisList(contractId: nil)
    XCTAssertTrue(hakedisler.isEmpty, "puantaj/imalat izni hakediş tutarlarına erişim vermez")

    let projects = try await repos.projects.list(includeCompleted: true)
    let sivas = try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
    let items = try await repos.contracts.imalatItems(projectId: sivas.id)
    XCTAssertTrue(Set(items.map(\.description)).isSuperset(of: ["Temel ve perde kalıbı", "Beton döküm işçiliği"]),
                  "seed sözleşmesinin birim fiyatlı kalemleri (fiyatsız) görünür")

    let seedContract = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!
    do {
      _ = try await repos.contracts.financeSummary(contractId: seedContract)
      XCTFail("finans özeti görülmemeli")
    } catch let error as RepositoryError {
      guard case .forbidden = error else { return XCTFail("beklenmeyen hata: \(error)") }
    }
  }

  func testFullCycleWithExactDecimalsAndIdempotentPosting() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let projects = try await repos.projects.list(includeCompleted: true)
    let sivas = try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
    let subs = try await repos.workforce.subcontractors()
    let sub = try XCTUnwrap(subs.first { $0.name == "Örnek Kaba İnşaat Taşeronu" })
    let sources = try await repos.contracts.paymentSources()
    let source = try XCTUnwrap(sources.first)

    let contractId = UUID()
    let itemKey = UUID()
    let number = "TEST-ENT-\(contractId.uuidString.prefix(8))"
    let draft = ContractDraft(
      projectId: sivas.id, subcontractorId: sub.id, contractNo: number, title: "Entegrasyon testi (demo)",
      items: [ContractItemDraft(itemKey: itemKey, method: .birimFiyat, description: "Sıva", unit: .m2,
                                quantity: Decimal(string: "120.5")!, unitPrice: Decimal(string: "33.3333")!)],
      retentionRate: Decimal(string: "12.5")!)
    var contract = try await repos.contracts.saveContract(id: contractId, draft: draft, expectedVersion: nil)
    XCTAssertEqual(contract.cariAccountId, sub.cariAccountId, "taşeronun mevcut carisi kullanılır")
    contract = try await repos.contracts.transition(contractId: contractId, action: .onayla, reason: nil,
                                                    expectedVersion: contract.version)
    XCTAssertEqual(contract.status, .aktif)
    let versions = try await repos.contracts.versions(contractId: contractId)
    let items = try await repos.contracts.items(versionId: try XCTUnwrap(versions.first).id)
    XCTAssertEqual(items.first?.unitPrice, Decimal(string: "33.3333"), "birim fiyat 4 ondalık korunur")
    XCTAssertEqual(items.first?.quantity, Decimal(string: "120.5"))

    let today = CalendarDate.today()
    let quantity = WorkQuantity(contractId: contractId, projectId: sivas.id, itemKey: itemKey, workDate: today,
                                quantity: 3)
    _ = try await repos.contracts.saveWorkQuantity(quantity)
    let approvedCount = try await repos.contracts.approveWorkQuantities(ids: [quantity.id])
    XCTAssertEqual(approvedCount, 1)

    let hakedisId = UUID()
    var hakedis = try await repos.contracts.createHakedis(id: hakedisId, contractId: contractId,
                                                          periodStart: today.adding(days: -30), periodEnd: today, note: nil)
    XCTAssertEqual(hakedis.grossAmount, 100, "3 × 33,3333 = 99,9999 → 100,00")
    XCTAssertEqual(hakedis.retentionAmount, Decimal(string: "12.5"))
    XCTAssertEqual(hakedis.payableAmount, Decimal(string: "87.5"))

    hakedis = try await repos.contracts.transition(hakedisId: hakedisId, action: .gonder, reason: nil, expectedVersion: nil)
    hakedis = try await repos.contracts.transition(hakedisId: hakedisId, action: .onayla, reason: nil,
                                                   expectedVersion: hakedis.version)
    XCTAssertEqual(hakedis.status, .onaylandi)
    hakedis = try await repos.contracts.post(hakedisId: hakedisId, entryDate: today)
    let again = try await repos.contracts.post(hakedisId: hakedisId, entryDate: today)
    XCTAssertEqual(again.cariEntryId, hakedis.cariEntryId, "tekrar işleme aynı hareketi döner")

    let paymentId = UUID()
    let paymentDraft = FinancePaymentDraft(id: paymentId, contractId: contractId, target: .hakedis(hakedisId),
                                           amount: Decimal(string: "50.25")!, paymentSourceId: source.id,
                                           paymentDate: today)
    _ = try await repos.contracts.recordPayment(paymentDraft)
    _ = try await repos.contracts.recordPayment(paymentDraft)  // ağ hatası sonrası tekrar
    let payments = try await repos.contracts.payments(contractId: contractId)
    XCTAssertEqual(payments.count, 1, "aynı kimlikle ikinci ödeme oluşmaz")
    let status = try await repos.contracts.paymentStatus(hakedisIds: [hakedisId]).first
    XCTAssertEqual(status?.remainingAmount, Decimal(string: "37.25"))

    do {
      _ = try await repos.contracts.recordPayment(FinancePaymentDraft(
        contractId: contractId, target: .hakedis(hakedisId), amount: 38, paymentSourceId: source.id, paymentDate: today))
      XCTFail("kalanı aşan ödeme reddedilmeli")
    } catch let error as RepositoryError {
      guard case .validation = error else { return XCTFail("beklenmeyen hata: \(error)") }
    }

    let summary = try await repos.contracts.financeSummary(contractId: contractId)
    XCTAssertEqual(summary.grossTotal, 100)
    XCTAssertEqual(summary.retentionBalance, Decimal(string: "12.5"))
    XCTAssertEqual(summary.payableTotal, Decimal(string: "87.5"))
    XCTAssertEqual(summary.paidTotal, Decimal(string: "50.25"))
    XCTAssertEqual(summary.remainingTotal, Decimal(string: "37.25"))
  }

  func testForeignCurrencyUsesExplicitRateAndPaymentIdempotencyChecksSourceAndDate() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let projects = try await repos.projects.list(includeCompleted: true)
    let sivas = try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
    let subs = try await repos.workforce.subcontractors()
    let sub = try XCTUnwrap(subs.first { $0.name == "Örnek Kaba İnşaat Taşeronu" })
    let sources = try await repos.contracts.paymentSources()
    let sirket = try XCTUnwrap(sources.first { $0.kind == .sirket })
    let kart = try XCTUnwrap(sources.first { $0.kind == .kart })

    let contractId = UUID()
    let itemKey = UUID()
    let number = "TEST-USD-\(contractId.uuidString.prefix(8))"
    let draft = ContractDraft(
      projectId: sivas.id, subcontractorId: sub.id, contractNo: number, title: "Döviz entegrasyon testi (demo)",
      items: [ContractItemDraft(itemKey: itemKey, method: .birimFiyat, description: "Montaj", unit: .adet,
                                quantity: 10, unitPrice: 1_000)],
      currency: "USD", retentionRate: 10)
    var contract = try await repos.contracts.saveContract(id: contractId, draft: draft, expectedVersion: nil)
    contract = try await repos.contracts.transition(contractId: contractId, action: .onayla, reason: nil,
                                                    expectedVersion: contract.version)
    let today = CalendarDate.today()
    let quantity = WorkQuantity(contractId: contractId, projectId: sivas.id, itemKey: itemKey, workDate: today, quantity: 4)
    _ = try await repos.contracts.saveWorkQuantity(quantity)
    _ = try await repos.contracts.approveWorkQuantities(ids: [quantity.id])
    let hakedisId = UUID()
    var hakedis = try await repos.contracts.createHakedis(id: hakedisId, contractId: contractId,
                                                          periodStart: today.adding(days: -30), periodEnd: today, note: nil)
    hakedis = try await repos.contracts.transition(hakedisId: hakedisId, action: .gonder, reason: nil, expectedVersion: nil)
    hakedis = try await repos.contracts.transition(hakedisId: hakedisId, action: .onayla, reason: nil,
                                                   expectedVersion: hakedis.version)
    XCTAssertEqual(hakedis.payableAmount, 3_600)

    do {
      _ = try await repos.contracts.post(hakedisId: hakedisId, entryDate: today)
      XCTFail("USD hakediş kursuz deftere işlenmemeli")
    } catch let error as RepositoryError {
      guard case .validation = error else { return XCTFail("beklenmeyen hata: \(error)") }
    }
    hakedis = try await repos.contracts.post(hakedisId: hakedisId, entryDate: today, exchangeRate: Decimal(string: "41.5"))
    XCTAssertTrue(hakedis.isPosted)

    let paymentDraft = FinancePaymentDraft(contractId: contractId, target: .hakedis(hakedisId), amount: 1_000,
                                           paymentSourceId: sirket.id, paymentDate: today, exchangeRate: 42)
    _ = try await repos.contracts.recordPayment(paymentDraft)
    _ = try await repos.contracts.recordPayment(paymentDraft)  // aynı niyet
    var otherSource = paymentDraft
    otherSource.paymentSourceId = kart.id
    var otherDate = paymentDraft
    otherDate.paymentDate = today.adding(days: -1)
    var otherRate = paymentDraft
    otherRate.exchangeRate = 43
    for changed in [otherSource, otherDate, otherRate] {
      do {
        _ = try await repos.contracts.recordPayment(changed)
        XCTFail("aynı ödeme kimliği farklı kaynak, tarih veya kurla kabul edilmemeli")
      } catch let error as RepositoryError {
        guard case .conflict = error else { return XCTFail("beklenmeyen hata: \(error)") }
      }
    }
    let payments = try await repos.contracts.payments(contractId: contractId)
    XCTAssertEqual(payments.count, 1)
    XCTAssertEqual(payments.first?.paymentSourceId, sirket.id)

    let lines = try await repos.cari.statement(accountId: try XCTUnwrap(sub.cariAccountId), filter: CariFilter())
      .filter { $0.documentNo?.hasPrefix(number) == true }
    XCTAssertEqual(lines.first { $0.kind == .hakedis }?.alacakTry, 166_000, "4.000 USD × 41,5")
    XCTAssertEqual(lines.first { $0.kind == .kesinti }?.borcTry, 16_600, "400 USD × 41,5")
    XCTAssertEqual(lines.first { $0.kind == .odeme }?.borcTry, 42_000, "1.000 USD × 42")

    let summary = try await repos.contracts.financeSummary(contractId: contractId)
    XCTAssertEqual(summary.paidTotal, 1_000, "özet sözleşme para biriminde")
    XCTAssertEqual(summary.remainingTotal, 2_600)
  }

  func testAdvanceNeedsDefinedContractAmountAndStaysWithinIt() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let projects = try await repos.projects.list(includeCompleted: true)
    let sivas = try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
    let subs = try await repos.workforce.subcontractors()
    let sub = try XCTUnwrap(subs.first { $0.name == "Örnek Kaba İnşaat Taşeronu" })
    let sources = try await repos.contracts.paymentSources()
    let source = try XCTUnwrap(sources.first)
    let today = CalendarDate.today()

    func approvedContract(total: Decimal?) async throws -> UUID {
      let id = UUID()
      let draft = ContractDraft(
        projectId: sivas.id, subcontractorId: sub.id, contractNo: "TEST-AV-\(id.uuidString.prefix(8))",
        title: "Avans tavanı testi (demo)",
        items: [ContractItemDraft(itemKey: UUID(), method: .birimFiyat, description: "Sıva", unit: .m2,
                                  quantity: 10, unitPrice: 100)],
        totalAmount: total)
      let saved = try await repos.contracts.saveContract(id: id, draft: draft, expectedVersion: nil)
      _ = try await repos.contracts.transition(contractId: id, action: .onayla, reason: nil, expectedVersion: saved.version)
      return id
    }
    func advance(_ contractId: UUID, _ amount: Decimal) -> FinancePaymentDraft {
      FinancePaymentDraft(contractId: contractId, target: .advance, amount: amount, paymentSourceId: source.id,
                          paymentDate: today)
    }

    let noTotal = try await approvedContract(total: nil)
    do {
      _ = try await repos.contracts.recordPayment(advance(noTotal, 1))
      XCTFail("bedeli tanımsız sözleşmeye avans verilmemeli")
    } catch let error as RepositoryError {
      guard case .validation(let message) = error else { return XCTFail("beklenmeyen hata: \(error)") }
      XCTAssertTrue(message.contains("bedeli tanımlı olmayan"), message)
    }

    let limited = try await approvedContract(total: 1_000)
    _ = try await repos.contracts.recordPayment(advance(limited, 1_000))  // bedele tam eşit
    do {
      _ = try await repos.contracts.recordPayment(advance(limited, Decimal(string: "0.01")!))
      XCTFail("bedeli aşan avans reddedilmeli")
    } catch let error as RepositoryError {
      guard case .validation = error else { return XCTFail("beklenmeyen hata: \(error)") }
    }
    let summary = try await repos.contracts.financeSummary(contractId: limited)
    XCTAssertEqual(summary.advancePaidTotal, 1_000)
    XCTAssertEqual(summary.paidTotal, 0)
  }
}
