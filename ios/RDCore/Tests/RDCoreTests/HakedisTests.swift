import Foundation
import XCTest
@testable import RDCore

private func day(_ month: Int, _ day: Int) -> CalendarDate { CalendarDate(year: 2026, month: month, day: day) }

private func grants(_ keys: [PermissionKey], project: UUID? = nil) -> [PermissionGrant] {
  keys.map { PermissionGrant(projectId: project, permissionKey: $0.rawValue) }
}

// MARK: - Hesap kuralları

final class HakedisMathTests: XCTestCase {
  func testTwentyPercentRetentionExample() {
    // Brüt 1.000.000, %20 teminat 200.000, ödemeye uygun 800.000, ödenen 0.
    let gross = HakedisMath.amount(100, 10_000)
    let retention = HakedisMath.percent(gross, 20)
    let payable = HakedisMath.payable(gross: gross, retention: retention)
    XCTAssertEqual(gross, 1_000_000)
    XCTAssertEqual(retention, 200_000)
    XCTAssertEqual(payable, 800_000)

    let hakedis = Hakedis(contractId: UUID(), versionId: UUID(), projectId: UUID(), subcontractorId: UUID(),
                          cariAccountId: UUID(), hakedisNo: 1, periodStart: day(9, 1), periodEnd: day(9, 30),
                          status: .onaylandi, grossAmount: gross, retentionAmount: retention, payableAmount: payable)
    let breakdown = HakedisBreakdown(hakedis, paid: 0)
    XCTAssertEqual(breakdown.paid, 0, "800.000 TL'lik hakediş ödendi anlamına gelmez")
    XCTAssertEqual(breakdown.remaining, 800_000)
    XCTAssertEqual(breakdown.deducted, 200_000)
    XCTAssertTrue(breakdown.isConsistent)
  }

  func testRoundingIsPerLineHalfUpTwoDecimals() {
    XCTAssertEqual(HakedisMath.amount(3, Decimal(string: "33.3333")!), 100.00)
    XCTAssertEqual(HakedisMath.percent(100, Decimal(string: "12.5")!), Decimal(string: "12.5"))
    XCTAssertEqual(HakedisMath.round2(Decimal(string: "0.005")!), Decimal(string: "0.01"))
    XCTAssertEqual(HakedisMath.round2(Decimal(string: "2.345")!), Decimal(string: "2.35"))
    XCTAssertEqual(HakedisMath.amount(Decimal(string: "0.1")!, Decimal(string: "0.2")!), Decimal(string: "0.02"))
  }

  func testMixedContractExampleMatchesDatabaseTest() {
    // pgTAP 090 karma örneği: brüt 51.600; KDV %20; stopaj %3; teminat %10.
    let gross: Decimal = 11_000 + 600 + 40_000
    let kdv = HakedisMath.percent(gross, 20)
    let stopaj = HakedisMath.percent(gross, 3)
    let retention = HakedisMath.percent(gross, 10)
    XCTAssertEqual(HakedisMath.payable(gross: gross, kdv: kdv, stopaj: stopaj, retention: retention), 55_212)
  }

  func testExchangeRateRuleMatchesDatabase() throws {
    XCTAssertEqual(try HakedisMath.exchangeRate(currency: "TRY", rate: nil), 1)
    XCTAssertEqual(try HakedisMath.exchangeRate(currency: "TRY", rate: 1), 1)
    XCTAssertThrowsError(try HakedisMath.exchangeRate(currency: "TRY", rate: 2), "TL'de kur yalnızca 1")
    XCTAssertThrowsError(try HakedisMath.exchangeRate(currency: "USD", rate: nil), "döviz kuru tahmin edilmez")
    XCTAssertThrowsError(try HakedisMath.exchangeRate(currency: "USD", rate: 0))
    XCTAssertThrowsError(try HakedisMath.exchangeRate(currency: "EUR", rate: Decimal(string: "41.1234567")!))
    XCTAssertEqual(try HakedisMath.exchangeRate(currency: "EUR", rate: Decimal(string: "44.123456")!),
                   Decimal(string: "44.123456"))
  }

  func testExchangeRateInputHasNoThousandsSeparator() {
    XCTAssertEqual(HakedisMath.parseExchangeRate("41,5"), Decimal(string: "41.5"))
    XCTAssertEqual(HakedisMath.parseExchangeRate("41.500"), Decimal(string: "41.5"), "kurda nokta binlik değil ondalıktır")
    XCTAssertNil(HakedisMath.parseExchangeRate("1.234,5"))
    XCTAssertNil(HakedisMath.parseExchangeRate(""))
    XCTAssertNil(HakedisMath.parseExchangeRate("0"))
    XCTAssertNil(HakedisMath.parseExchangeRate("-3"))
  }

  func testLumpSumUsesCumulativeProgress() {
    XCTAssertEqual(HakedisMath.lumpSum(price: 100_000, cumulativePercent: 40, previousAmount: 0), 40_000)
    XCTAssertEqual(HakedisMath.lumpSum(price: 100_000, cumulativePercent: 75, previousAmount: 40_000), 35_000)
  }

  func testDecimalInputLimitsFractionDigits() {
    XCTAssertEqual(DecimalInput.parse("12,3456", maxFractionDigits: 4), Decimal(string: "12.3456"))
    XCTAssertNil(DecimalInput.parse("12,34567", maxFractionDigits: 4))
    XCTAssertEqual(DecimalInput.parse("1.250,5", maxFractionDigits: 3), Decimal(string: "1250.5"))
    XCTAssertEqual(DecimalInput.parse("%20", maxFractionDigits: 4), 20)
    XCTAssertNil(DecimalInput.parse("abc", maxFractionDigits: 2))
    XCTAssertEqual(DecimalInput.parse("", maxFractionDigits: 2, empty: 0), 0)
  }

  func testItemFormRules() {
    var item = ContractItemForm(method: .birimFiyat, description: "Beton", unit: .m3, priceText: "10.000")
    XCTAssertNotNil(item.validationMessage, "birim fiyatlı kalemde miktar zorunlu")
    item.quantityText = "150"
    XCTAssertNil(item.validationMessage)
    XCTAssertEqual(item.amountPreview, 1_500_000)

    let lump = ContractItemForm(method: .goturu, description: "İskele", unit: .goturu, quantityText: "5", priceText: "100000")
    XCTAssertNil(lump.validationMessage)
    XCTAssertNil(lump.draft?.quantity, "götürü kalemde miktar gönderilmez")
    XCTAssertEqual(lump.draft?.unit, .goturu)

    let daily = ContractItemForm(method: .gunluk, description: "Usta", unit: .m2, priceText: "2000", overtimeText: "",
                                 paidBases: [.resmiTatil])
    XCTAssertEqual(daily.draft?.unit, .adamGun)
    XCTAssertEqual(daily.draft?.paidBases, [.calisilanGun, .resmiTatil], "çalışılan gün her zaman ücretlendirilir")
    XCTAssertNil(daily.draft?.overtimeUnitPrice, "fazla mesai ücreti tanımlanmadıysa ödenmez")
  }

  func testDecodingServerRows() throws {
    let json = """
    {"id":"00000000-0000-4000-8000-0000000000e2","contract_id":"00000000-0000-4000-8000-0000000000c1",
     "version_id":"00000000-0000-4000-8000-0000000000c2","project_id":"00000000-0000-4000-8000-0000000000c3",
     "subcontractor_id":"00000000-0000-4000-8000-0000000000c4","cari_account_id":"00000000-0000-4000-8000-0000000000c5",
     "hakedis_no":1,"period_start":"2026-09-01","period_end":"2026-09-30","status":"onaylandi","currency":"TRY",
     "replaces_id":null,"note":null,"gross_amount":312000.00,"kdv_amount":0,"tax_deduction_amount":0,
     "other_deduction_amount":0,"retention_amount":31200.00,"advance_amount":50000.00,"payable_amount":230800.00,
     "limit_exceeded":false,"limit_messages":[],"limit_override_reason":null,"submitted_at":null,"approved_at":null,
     "approved_by":null,"cancelled_at":null,"cancel_reason":null,"posted_at":null,"cari_entry_id":null,
     "is_demo":true,"version":4}
    """
    let hakedis = try JSONDecoder().decode(Hakedis.self, from: Data(json.utf8))
    XCTAssertEqual(hakedis.payableAmount, 230_800)
    XCTAssertEqual(hakedis.retentionAmount, 31_200)
    XCTAssertTrue(HakedisBreakdown(hakedis, paid: 0).isConsistent)
    XCTAssertEqual(try JSONDecoder().decode(CariEntryKind.self, from: Data("\"teminat_iadesi\"".utf8)), .teminatIadesi)
  }
}

// MARK: - Akış (bellek içi sunucu ve ViewModel'ler)

@MainActor
final class HakedisFlowTests: XCTestCase {
  private var backend: InMemoryBackend!
  private let project = Project(code: "TEST-HK", name: "Test projesi", status: .devam)
  private let cari = CariAccount(code: "TEST-C1", title: "Test taşeronu", type: .taseron)
  private lazy var sub = Subcontractor(name: "Test taşeronu", cariAccountId: cari.id)
  private let source = PaymentSource(name: "Şirket ödemesi")

  override func setUp() async throws {
    backend = InMemoryBackend()
    await backend.seed(projects: [project], accounts: [cari])
    await backend.seedWorkforce(subcontractors: [sub, Subcontractor(name: "Carisiz taşeron")])
    await backend.seedContracts(paymentSources: [source])
    await backend.set(today: day(10, 31))
  }

  private var repository: ContractRepository { backend.repositories.contracts }
  private var admin: AccessControl { AccessControl(grants: grants(PermissionKey.allCases)) }

  /// %20 teminatlı, 150 m³ × 10.000 birim fiyatlı onaylı sözleşme.
  private func makeContract(currency: String = "TRY") async throws -> (ContractDetailViewModel, ContractItem) {
    let form = ContractFormViewModel(projectId: project.id, projects: [project], subcontractors: [sub],
                                     taxRules: [], repository: repository)
    form.currency = currency
    form.subcontractorId = sub.id
    form.contractNo = "test-s-1"
    form.title = "Kaba yapı betonu"
    form.retentionRateText = "20"
    form.totalAmountText = "1.500.000"
    form.items = [ContractItemForm(method: .birimFiyat, description: "C30 beton", unit: .m3, quantityText: "150",
                                   priceText: "10000")]
    let saved = await form.save()
    let contract = try XCTUnwrap(saved, form.errorMessage ?? "")
    XCTAssertEqual(contract.contractNo, "TEST-S-1")
    XCTAssertEqual(contract.cariAccountId, cari.id, "taşeronun mevcut cari kartı kullanılır")
    let detail = ContractDetailViewModel(contract: contract, access: admin, repository: repository)
    await detail.load()
    let approved = await detail.transition(.onayla)
    XCTAssertTrue(approved, detail.errorMessage ?? "")
    XCTAssertEqual(detail.contract.status, .aktif)
    return (detail, try XCTUnwrap(detail.items.first))
  }

  private func enterImalat(_ quantity: String, date: CalendarDate, access: AccessControl? = nil) async -> Bool {
    let imalat = ImalatViewModel(project: project, access: access ?? admin, repository: repository)
    await imalat.load()
    guard let item = imalat.items.first else { return false }
    let saved = await imalat.save(item: item, quantityText: quantity, date: date, location: nil, note: nil)
    guard saved else { return false }
    return await imalat.approvePending()
  }

  func testSubcontractorWithoutCariCannotGetContract() async {
    let carisiz = await backend.subcontractorList.first { $0.cariAccountId == nil }!
    let form = ContractFormViewModel(projectId: project.id, projects: [project], subcontractors: [sub, carisiz],
                                     taxRules: [], repository: repository)
    XCTAssertEqual(form.subcontractors.map(\.id), [sub.id], "cari kartı olmayan taşeron seçilemez")
    let accounts = await backend.accounts.count
    XCTAssertEqual(accounts, 1, "sözleşme yeni cari kart açmaz")
  }

  func testTwentyPercentRetentionFlowKeepsAmountsApart() async throws {
    let (detail, _) = try await makeContract()
    let entered = await enterImalat("100", date: day(9, 20))
    XCTAssertTrue(entered)
    let created = await detail.createHakedis(start: day(9, 1), end: day(9, 30), note: nil)
    let hakedis = try XCTUnwrap(created, detail.errorMessage ?? "")
    XCTAssertEqual(hakedis.grossAmount, 1_000_000)
    XCTAssertEqual(hakedis.retentionAmount, 200_000)
    XCTAssertEqual(hakedis.payableAmount, 800_000)

    let model = HakedisDetailViewModel(hakedis: hakedis, contract: detail.contract, access: admin, repository: repository)
    await model.load()
    XCTAssertFalse(model.canApprove, "taslak doğrudan onaylanmaz")
    var ok = await model.transition(.gonder)
    XCTAssertTrue(ok)
    ok = await model.transition(.onayla)
    XCTAssertTrue(ok, model.errorMessage ?? "")
    XCTAssertEqual(model.paymentStateTitle, "Deftere işlenmedi")
    XCTAssertFalse(model.canPay, "deftere işlenmeden ödeme yapılamaz")

    ok = await model.post()
    XCTAssertTrue(ok)
    ok = await model.post()
    XCTAssertTrue(ok, "tekrar gönderim hata vermez")
    let hakedisEntries = await backend.entries.filter { $0.draft.kind == .hakedis }.count
    XCTAssertEqual(hakedisEntries, 1, "tekrar işleme ikinci hakediş hareketi açmaz")
    XCTAssertEqual(model.paymentStateTitle, "Ödenmedi")
    XCTAssertEqual(model.breakdown.payable, 800_000)
    XCTAssertEqual(model.breakdown.paid, 0)

    // Cari: 1.000.000 alacak, 200.000 teminat kesintisi borç → 800.000 borçluyuz.
    let balance = try await backend.repositories.cari.balances(filter: CariFilter()).first { $0.cariAccountId == cari.id }
    XCTAssertEqual(balance?.balanceTry, -800_000)

    ok = await model.recordPayment(amount: 300_000, sourceId: source.id, date: day(10, 10), description: nil)
    XCTAssertTrue(ok)
    XCTAssertEqual(model.paymentStateTitle, "Kısmen ödendi")
    XCTAssertEqual(model.breakdown.remaining, 500_000)
    ok = await model.recordPayment(amount: 500_001, sourceId: source.id, date: day(10, 10), description: nil)
    XCTAssertFalse(ok, "kalanı aşan ödeme reddedilir")

    await detail.load()
    let summary = try XCTUnwrap(detail.summary)
    XCTAssertEqual(summary.grossTotal, 1_000_000)
    XCTAssertEqual(summary.retentionBalance, 200_000)
    XCTAssertEqual(summary.payableTotal, 800_000)
    XCTAssertEqual(summary.paidTotal, 300_000)
    XCTAssertEqual(summary.remainingTotal, 500_000)
  }

  func testRetentionReleaseIsSeparateFromPaymentAndCannotExceedBalance() async throws {
    let (detail, _) = try await makeContract()
    _ = await enterImalat("100", date: day(9, 20))
    let hakedisValue = await detail.createHakedis(start: day(9, 1), end: day(9, 30), note: nil)
    let hakedis = try XCTUnwrap(hakedisValue)
    let model = HakedisDetailViewModel(hakedis: hakedis, contract: detail.contract, access: admin, repository: repository)
    _ = await model.transition(.gonder)
    _ = await model.transition(.onayla)
    _ = await model.post()
    await detail.load()

    var ok = await detail.releaseTeminat(amount: 200_001, reason: "Geçici kabul yapıldı", date: day(10, 20))
    XCTAssertFalse(ok, "biriken teminattan fazlası bırakılamaz")
    ok = await detail.releaseTeminat(amount: 50_000, reason: "Geçici kabul yapıldı", date: day(10, 20))
    XCTAssertTrue(ok)
    XCTAssertEqual(detail.summary?.retentionBalance, 150_000)
    XCTAssertEqual(detail.summary?.remainingTotal, 850_000, "iade borcu artırır; hakediş ikinci kez borçlanmaz")
    let hakedisEntries = await backend.entries.filter { $0.draft.kind == .hakedis }.count
    XCTAssertEqual(hakedisEntries, 1)

    let release = try XCTUnwrap(detail.releases.first)
    XCTAssertEqual(detail.unpaidRelease(release), 50_000, "serbest bırakma nakit ödemesi değildir")
    ok = await detail.recordPayment(FinancePaymentDraft(contractId: detail.contract.id, target: .teminatRelease(release.id),
                                                        amount: 50_000, paymentSourceId: source.id, paymentDate: day(10, 21)))
    XCTAssertTrue(ok)
    XCTAssertEqual(detail.unpaidRelease(release), 0)
    XCTAssertEqual(detail.summary?.remainingTotal, 800_000)
  }

  func testImalatIsUsedOnceAndRevisionDoesNotChangeOldHakedis() async throws {
    let (detail, item) = try await makeContract()
    _ = await enterImalat("100", date: day(9, 20))
    let firstValue = await detail.createHakedis(start: day(9, 1), end: day(9, 30), note: nil)
    let first = try XCTUnwrap(firstValue)
    let model = HakedisDetailViewModel(hakedis: first, contract: detail.contract, access: admin, repository: repository)
    _ = await model.transition(.gonder)
    _ = await model.transition(.onayla)
    await detail.load()

    // Fiyat revizyonu: 12.000. Eski hakediş değişmez.
    var ok = await detail.transition(.revizyon, reason: "Birim fiyat artışı (ek protokol)")
    XCTAssertTrue(ok, detail.errorMessage ?? "")
    let form = ContractFormViewModel(editing: detail.contract, version: detail.draftVersion, items: detail.draftItems,
                                     projects: [project], subcontractors: [sub], taxRules: [], repository: repository)
    form.items[0].priceText = "12000"
    let savedValue = await form.save()
    let saved = try XCTUnwrap(savedValue, form.errorMessage ?? "")
    await detail.didSave(saved)
    ok = await detail.transition(.onayla)
    XCTAssertTrue(ok, detail.errorMessage ?? "")
    XCTAssertEqual(detail.items.first?.unitPrice, 12_000)
    XCTAssertEqual(detail.items.first?.itemKey, item.itemKey, "kalem kimliği revizyonlarda aynı kalır")
    let old = try await repository.hakedis(id: first.id)
    XCTAssertEqual(old.grossAmount, 1_000_000, "onaylı eski hakediş yeni fiyattan etkilenmez")

    _ = await enterImalat("30", date: day(10, 10))
    let secondValue = await detail.createHakedis(start: day(10, 1), end: day(10, 31), note: nil)
    let second = try XCTUnwrap(secondValue)
    let lines = try await repository.lines(hakedisId: second.id)
    XCTAssertEqual(lines.first?.quantity, 30, "ilk hakedişte kullanılan imalat tekrar gelmez")
    XCTAssertEqual(lines.first?.previousQuantity, 100)
    XCTAssertEqual(lines.first?.cumulativeQuantity, 130)
    XCTAssertEqual(second.grossAmount, 360_000, "yeni dönem yeni fiyatla")
  }

  func testQuantityOverContractNeedsExplicitOverride() async throws {
    let (detail, _) = try await makeContract()
    _ = await enterImalat("160", date: day(9, 20))
    let hakedisValue = await detail.createHakedis(start: day(9, 1), end: day(9, 30), note: nil)
    let hakedis = try XCTUnwrap(hakedisValue)
    XCTAssertTrue(hakedis.limitExceeded)
    let model = HakedisDetailViewModel(hakedis: hakedis, contract: detail.contract, access: admin, repository: repository)
    _ = await model.transition(.gonder)
    XCTAssertFalse(model.canApprove, "limit aşımı izinsiz onaylanmaz")
    var ok = await model.transition(.onayla)
    XCTAssertFalse(ok)
    ok = await model.overrideLimit(reason: "Ek metraj tutanağı onaylandı")
    XCTAssertTrue(ok)
    ok = await model.transition(.onayla)
    XCTAssertTrue(ok, model.errorMessage ?? "")
  }

  func testCancellingApprovedHakedisReversesLedgerAndFreesImalat() async throws {
    let (detail, _) = try await makeContract()
    _ = await enterImalat("100", date: day(9, 20))
    let hakedisValue = await detail.createHakedis(start: day(9, 1), end: day(9, 30), note: nil)
    let hakedis = try XCTUnwrap(hakedisValue)
    let model = HakedisDetailViewModel(hakedis: hakedis, contract: detail.contract, access: admin, repository: repository)
    _ = await model.transition(.gonder)
    _ = await model.transition(.onayla)
    _ = await model.post()
    var ok = await model.revise(reason: "kısa")
    XCTAssertFalse(ok, "gerekçe en az 10 karakter")
    ok = await model.revise(reason: "Metraj hatası düzeltilecek")
    XCTAssertTrue(ok, model.errorMessage ?? "")
    XCTAssertEqual(model.hakedis.status, .iptal)
    let fresh = try XCTUnwrap(model.replacement)
    XCTAssertEqual(fresh.replacesId, hakedis.id)
    XCTAssertEqual(fresh.grossAmount, 1_000_000, "serbest kalan imalat düzeltme hakedişine gelir")
    let reversals = await backend.entries.filter { $0.draft.kind == .tersKayit }.count
    XCTAssertEqual(reversals, 2, "hakediş ve teminat kesintisi ters kayıtla kapatılır")
    let balance = try await backend.repositories.cari.balances(filter: CariFilter()).first { $0.cariAccountId == cari.id }
    XCTAssertEqual(balance?.balanceTry, 0)
  }

  func testSiteChiefSeesImalatButNoFinance() async throws {
    let (detail, _) = try await makeContract()
    let chief = AccessControl(grants: grants([.projeRead, .puantajRead, .puantajWrite, .imalatRead, .imalatWrite],
                                             project: project.id))
    XCTAssertFalse(AppModule.hakedis.isVisible(for: chief), "puantaj izni hakediş tutarlarına erişim vermez")
    XCTAssertFalse(AppModule.taseronSozlesmeleri.isVisible(for: chief))
    XCTAssertTrue(AppModule.imalat.isVisible(for: chief))

    await backend.set(grants: grants([.projeRead, .puantajRead, .puantajWrite, .imalatRead, .imalatWrite],
                                     project: project.id))
    let imalat = ImalatViewModel(project: project, access: chief, repository: repository)
    await imalat.load()
    XCTAssertEqual(imalat.items.count, 1)
    XCTAssertFalse(imalat.canApprove)
    let saved = await imalat.save(item: imalat.items[0], quantityText: "10", date: day(10, 1), location: nil, note: nil)
    XCTAssertTrue(saved)
    let approved = await imalat.approvePending()
    XCTAssertFalse(approved, "şef imalatı onaylayamaz")

    let chiefDetail = ContractDetailViewModel(contract: detail.contract, access: chief, repository: repository)
    XCTAssertFalse(chiefDetail.canSeeFinance)
    let list = try await repository.hakedisList(contractId: nil)
    XCTAssertTrue(list.isEmpty)
    do {
      _ = try await repository.financeSummary(contractId: detail.contract.id)
      XCTFail("finans özeti görülmemeli")
    } catch {
      XCTAssertEqual(error as? RepositoryError, .forbidden("Sözleşme finans özetini görme yetkiniz yok"))
    }
  }

  /// Onaylanmış (deftere işlenmemiş) %20 teminatlı hakediş: brüt 1.000.000, ödemeye uygun 800.000.
  private func approvedHakedis(_ detail: ContractDetailViewModel) async throws -> HakedisDetailViewModel {
    _ = await enterImalat("100", date: day(9, 20))
    let created = await detail.createHakedis(start: day(9, 1), end: day(9, 30), note: nil)
    let hakedis = try XCTUnwrap(created, detail.errorMessage ?? "")
    let model = HakedisDetailViewModel(hakedis: hakedis, contract: detail.contract, access: admin, repository: repository)
    _ = await model.transition(.gonder)
    _ = await model.transition(.onayla)
    return model
  }

  func testRepeatedPaymentIdWithDifferentSourceOrDateIsRejected() async throws {
    let (detail, _) = try await makeContract()
    let model = try await approvedHakedis(detail)
    _ = await model.post()
    let card = PaymentSource(name: "Kürşat kartı", kind: .kart)
    await backend.seedContracts(paymentSources: [card])
    let draft = FinancePaymentDraft(contractId: detail.contract.id, target: .hakedis(model.hakedis.id), amount: 300_000,
                                    paymentSourceId: source.id, paymentDate: day(10, 10))
    _ = try await repository.recordPayment(draft)
    _ = try await repository.recordPayment(draft)  // aynı niyet: aynı kayıt

    var otherSource = draft
    otherSource.paymentSourceId = card.id
    var otherDate = draft
    otherDate.paymentDate = day(10, 11)
    for changed in [otherSource, otherDate] {
      do {
        _ = try await repository.recordPayment(changed)
        XCTFail("farklı kaynak veya tarihle aynı kimlik kabul edilmemeli")
      } catch {
        guard case .conflict = error as? RepositoryError else { return XCTFail("\(error)") }
      }
    }
    let payments = try await repository.payments(contractId: detail.contract.id)
    XCTAssertEqual(payments.count, 1)
    XCTAssertEqual(payments.first?.paymentSourceId, source.id, "ilk kaydın kaynağı korunur")
  }

  func testForeignCurrencyRequiresExplicitExchangeRate() async throws {
    let (detail, _) = try await makeContract(currency: "USD")
    XCTAssertTrue(detail.needsExchangeRate)
    let model = try await approvedHakedis(detail)
    XCTAssertTrue(model.needsExchangeRate)
    var ok = await model.post()
    XCTAssertFalse(ok, "USD hakediş kursuz deftere işlenmez")
    ok = await model.post(exchangeRate: Decimal(string: "41.5"))
    XCTAssertTrue(ok, model.errorMessage ?? "")
    ok = await model.recordPayment(amount: 1_000, sourceId: source.id, date: day(10, 20), description: nil)
    XCTAssertFalse(ok, "USD ödeme kursuz kaydedilmez")
    ok = await model.recordPayment(amount: 1_000, sourceId: source.id, date: day(10, 20), description: nil, exchangeRate: 42)
    XCTAssertTrue(ok, model.errorMessage ?? "")
    await detail.load()
    ok = await detail.releaseTeminat(amount: 100, reason: "Kısmi kabul yapıldı", date: day(10, 25))
    XCTAssertFalse(ok, "USD teminat iadesi kursuz yapılmaz")
    ok = await detail.releaseTeminat(amount: 100, reason: "Kısmi kabul yapıldı", date: day(10, 25), exchangeRate: 44)
    XCTAssertTrue(ok, detail.errorMessage ?? "")
  }

  func testTryRejectsExchangeRateOtherThanOne() async throws {
    let (detail, _) = try await makeContract()
    XCTAssertFalse(detail.needsExchangeRate)
    let model = try await approvedHakedis(detail)
    var ok = await model.post(exchangeRate: 2)
    XCTAssertFalse(ok, "TL hakedişte kur 1 dışında olamaz")
    ok = await model.post()
    XCTAssertTrue(ok)
  }

  func testAdvanceIsLimitedByContractAmount() async throws {
    let (detail, _) = try await makeContract()
    var ok = await detail.recordPayment(FinancePaymentDraft(contractId: detail.contract.id, target: .advance,
                                                            amount: 1_000_000, paymentSourceId: source.id, paymentDate: day(9, 1)))
    XCTAssertTrue(ok, detail.errorMessage ?? "")
    ok = await detail.recordPayment(FinancePaymentDraft(contractId: detail.contract.id, target: .advance,
                                                        amount: Decimal(string: "500000.01")!, paymentSourceId: source.id,
                                                        paymentDate: day(9, 2)))
    XCTAssertFalse(ok, "toplam avans sözleşme bedelini (1.500.000) aşamaz")
    XCTAssertEqual(detail.summary?.advancePaidTotal, 1_000_000)
    XCTAssertEqual(detail.summary?.paidTotal, 0, "avans gerçekleşen ödeme sayılmaz")
  }

  func testAdvanceDeductionCannotExceedOpenAdvance() async throws {
    let (detail, _) = try await makeContract()
    var ok = await detail.recordPayment(FinancePaymentDraft(contractId: detail.contract.id, target: .advance,
                                                            amount: 100_000, paymentSourceId: source.id, paymentDate: day(9, 1)))
    XCTAssertTrue(ok)
    _ = await enterImalat("100", date: day(9, 20))
    let hakedisValue = await detail.createHakedis(start: day(9, 1), end: day(9, 30), note: nil)
    let hakedis = try XCTUnwrap(hakedisValue)
    let model = HakedisDetailViewModel(hakedis: hakedis, contract: detail.contract, access: admin, repository: repository)
    ok = await model.setDeduction(.avansMahsubu, amountText: "100.001", description: nil)
    XCTAssertFalse(ok, "açık avanstan fazla mahsup edilemez")
    ok = await model.setDeduction(.avansMahsubu, amountText: "60.000", description: nil)
    XCTAssertTrue(ok)
    XCTAssertEqual(model.hakedis.advanceAmount, 60_000)
    XCTAssertEqual(model.hakedis.payableAmount, 740_000, "1.000.000 − 200.000 teminat − 60.000 avans")
    XCTAssertTrue(model.breakdown.isConsistent)
  }
}
