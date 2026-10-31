import Foundation
import XCTest
@testable import RDCore

private func grants(_ keys: [String], project: UUID? = nil) -> [PermissionGrant] {
  keys.map { PermissionGrant(projectId: project, permissionKey: $0) }
}

@MainActor
final class SessionViewModelTests: XCTestCase {
  func testSignInLoadsProfileAndPermissions() async {
    let backend = InMemoryBackend()
    let vm = SessionViewModel(repositories: backend.repositories)
    await vm.start()
    XCTAssertEqual(vm.state, .signedOut)

    vm.email = " Deneme@Example.test "
    vm.password = "yerel-test-1234"
    await vm.signIn()
    XCTAssertNotNil(vm.context)
    XCTAssertTrue(vm.context?.access.can(.cariRead) ?? false)
    XCTAssertEqual(vm.password, "", "şifre bellekte tutulmaz")
  }

  func testWrongPasswordShowsTurkishMessage() async {
    let vm = SessionViewModel(repositories: InMemoryBackend().repositories)
    await vm.start()
    vm.email = "deneme@example.test"
    vm.password = "yanlis-sifre-123"
    await vm.signIn()
    XCTAssertEqual(vm.state, .signedOut)
    XCTAssertEqual(vm.errorMessage, "E-posta veya şifre hatalı.")
  }

  func testShortPasswordIsRejectedBeforeNetwork() async {
    let vm = SessionViewModel(repositories: InMemoryBackend().repositories)
    vm.email = "deneme@example.test"
    vm.password = "kisa"
    XCTAssertFalse(vm.canSubmit)
    await vm.signIn()
    XCTAssertNotNil(vm.errorMessage)
  }

  func testInactiveProfileCannotEnter() async {
    let backend = InMemoryBackend()
    await backend.set(profileActive: false)
    let vm = SessionViewModel(repositories: backend.repositories)
    vm.email = "deneme@example.test"
    vm.password = "yerel-test-1234"
    await vm.signIn()
    XCTAssertNil(vm.context)
    XCTAssertEqual(vm.errorMessage, "Hesabınız pasif. Yöneticinize başvurun.")
  }

  func testRestoredSessionWithFailingProfileSignsOut() async {
    let backend = InMemoryBackend()
    let profile = await backend.profile
    await backend.set(session: AuthSession(userId: profile.id, email: profile.email))
    await backend.set(nextError: .network)
    let vm = SessionViewModel(repositories: backend.repositories)
    await vm.start()
    XCTAssertEqual(vm.state, .signedOut)
    let session = await backend.session
    XCTAssertNil(session)
  }
}

@MainActor
final class HomeViewModelTests: XCTestCase {
  func testHomeShowsProjectsTasksAndModulesWithoutAmounts() async throws {
    let backend = await PreviewData.backend()
    let profile = await backend.profile
    let context = SessionContext(session: AuthSession(userId: profile.id, email: profile.email), profile: profile,
                                 access: AccessControl(grants: await backend.grants))
    let vm = HomeViewModel(context: context, repositories: backend.repositories)
    await vm.load()
    XCTAssertEqual(vm.activeProjects.map(\.name), ["Sivas 30 Daire Projesi"])
    XCTAssertEqual(vm.openTaskCount(projectId: PreviewData.sivas.id), 1)
    XCTAssertTrue(vm.availableModules.contains(.cari))
    XCTAssertTrue(vm.availableModules.contains(.puantaj))
    XCTAssertTrue(vm.upcomingModules.contains(.hakedis))
    XCTAssertFalse(vm.upcomingModules.contains { $0.isAvailable })
  }

  func testSiteChiefDoesNotSeeFinanceModules() async {
    let backend = await PreviewData.backend()
    let project = PreviewData.sivas.id
    let access = AccessControl(grants: grants(["proje.read", "is.read", "is.write"], project: project))
    let profile = await backend.profile
    let vm = HomeViewModel(context: SessionContext(session: AuthSession(userId: profile.id, email: nil),
                                                   profile: profile, access: access),
                           repositories: backend.repositories)
    XCTAssertFalse(vm.availableModules.contains(.cari))
    XCTAssertFalse(vm.availableModules.contains(.genelGider))
  }
}

@MainActor
final class ProjectViewModelTests: XCTestCase {
  func testCreateProjectValidatesAndSaves() async {
    let backend = InMemoryBackend()
    let form = ProjectFormViewModel(repository: backend.repositories.projects)
    XCTAssertEqual(form.validationMessage, "Proje kodu zorunlu.")
    form.code = " svs-02 "
    form.name = "Sivas 30 Daire Projesi"
    form.hasStartDate = true
    form.startDate = CalendarDate(year: 2026, month: 3, day: 1).date()
    form.hasEndDate = true
    form.endDate = CalendarDate(year: 2026, month: 2, day: 1).date()
    XCTAssertEqual(form.validationMessage, "Bitiş tarihi başlangıçtan önce olamaz.")
    form.hasEndDate = false
    let saved = await form.save()
    XCTAssertEqual(saved?.code, "SVS-02")
    XCTAssertEqual(saved?.startDate, CalendarDate(year: 2026, month: 3, day: 1))
  }

  func testStaleEditIsRejected() async {
    let backend = InMemoryBackend()
    await backend.seed(projects: [PreviewData.sivas])
    let first = ProjectFormViewModel(editing: PreviewData.sivas, repository: backend.repositories.projects)
    let second = ProjectFormViewModel(editing: PreviewData.sivas, repository: backend.repositories.projects)
    first.name = "Sivas 30 Daire (güncel)"
    let firstSave = await first.save()
    XCTAssertEqual(firstSave?.version, 2)
    second.notes = "eski sürüm üzerinden"
    let secondSave = await second.save()
    XCTAssertNil(secondSave)
    XCTAssertNotNil(second.errorMessage)
  }

  func testListFiltersBySearchWithTurkishCase() async {
    let backend = InMemoryBackend()
    await backend.seed(projects: [PreviewData.sivas, Project(code: "IZM-1", name: "İzmir Konutları", status: .devam)])
    let vm = ProjectListViewModel(access: AccessControl(grants: grants(["proje.read"])),
                                  repository: backend.repositories.projects)
    await vm.load()
    vm.searchText = "izmir"
    XCTAssertEqual(vm.filtered.map(\.code), ["IZM-1"])
    XCTAssertFalse(vm.canCreate)
  }
}

@MainActor
final class CariViewModelTests: XCTestCase {
  func testCariFormValidation() async {
    let form = CariFormViewModel(repository: InMemoryBackend().repositories.cari)
    XCTAssertEqual(form.validationMessage, "Cari unvanı zorunlu.")
    form.title = "Örnek Taşeron"
    form.taxNumber = "123"
    XCTAssertNotNil(form.validationMessage)
    form.taxNumber = "1234567890"
    form.iban = "TR33 0006 1005 1978 6457 8413 26"
    XCTAssertNil(form.validationMessage)
    let saved = await form.save()
    XCTAssertEqual(saved?.iban, "TR330006100519786457841326")
  }

  func testEntryFormRetryDoesNotCreateSecondDebt() async throws {
    let backend = await PreviewData.backend()
    let access = AccessControl(grants: await backend.grants)
    let form = CariEntryFormViewModel(account: PreviewData.taseron, access: access, projects: [PreviewData.sivas],
                                      costCenters: [PreviewData.office], repository: backend.repositories.cari)
    form.kind = .odeme
    form.amountText = "50.000"
    form.descriptionText = "Ek ödeme"
    let firstSave = await form.save()
    XCTAssertTrue(firstSave)
    // Ağ kopması sonrası kullanıcı tekrar "Kaydet"e basar: aynı kimlik gider.
    let retry = await form.save()
    XCTAssertTrue(retry)
    let entries = await backend.entries
    XCTAssertEqual(entries.filter { $0.draft.id == form.entryId }.count, 1)
    let balances = try await backend.balances(filter: CariFilter())
    XCTAssertEqual(balances.first { $0.cariAccountId == PreviewData.taseron.id }?.balanceTry, -200_000)
  }

  func testEntryKindLocksDirection() async {
    let form = CariEntryFormViewModel(account: PreviewData.taseron, access: AccessControl(grants: []),
                                      projects: [], costCenters: [], repository: InMemoryBackend().repositories.cari)
    form.kind = .tahsilat
    XCTAssertEqual(form.direction, .alacak)
    XCTAssertTrue(form.isDirectionFixed)
    form.kind = .manuel
    XCTAssertFalse(form.isDirectionFixed)
  }

  func testEntryFormOffersOnlyPermittedAndSameKindScopes() async {
    let real = Project(code: "GERCEK-1", name: "Gerçek proje")
    let other = Project(code: "DEMO-02", name: "Başka demo", isDemo: true)
    let access = AccessControl(grants: grants(["cari_hareket.write"], project: PreviewData.sivas.id))
    let form = CariEntryFormViewModel(account: PreviewData.taseron, access: access,
                                      projects: [PreviewData.sivas, real, other], costCenters: [PreviewData.office],
                                      repository: InMemoryBackend().repositories.cari)
    XCTAssertEqual(form.projects.map(\.code), ["DEMO-SVS"], "yetkili ve demo durumu aynı projeler")
    XCTAssertTrue(form.costCenters.isEmpty, "genel gider için genel izin gerekir")
  }

  func testEntryValidation() async {
    let access = AccessControl(grants: grants(["cari_hareket.write"]))
    let form = CariEntryFormViewModel(account: PreviewData.taseron, access: access, projects: [PreviewData.sivas],
                                      costCenters: [], repository: InMemoryBackend().repositories.cari)
    form.amountText = "0"
    XCTAssertNotNil(form.validationMessage)
    form.amountText = "1.000,123"
    XCTAssertNotNil(form.validationMessage)
    form.amountText = "1.000,12"
    XCTAssertEqual(form.validationMessage, "Açıklama zorunlu.")
    form.descriptionText = "Avans"
    form.date = CalendarDate.today().adding(days: 3).date()
    XCTAssertEqual(form.validationMessage, "İleri tarihli hareket girilemez.")
  }

  func testDetailSummaryAndReversal() async throws {
    let backend = await PreviewData.backend()
    let access = AccessControl(grants: await backend.grants)
    let detail = CariDetailViewModel(account: PreviewData.taseron, access: access, repository: backend.repositories.cari)
    await detail.load()
    XCTAssertEqual(detail.lines.count, 2)
    XCTAssertEqual(detail.summary.closing, -250_000)
    XCTAssertEqual(detail.summary.side, .weOwe)

    let payment = try XCTUnwrap(detail.lines.first { $0.kind == .odeme })
    XCTAssertTrue(detail.canReverse(payment))
    let emptyReason = await detail.reverse(payment, reason: "  ")
    XCTAssertFalse(emptyReason)
    let reversalId = UUID()
    let reversed = await detail.reverse(payment, reason: "Yanlış tutar", reversalId: reversalId)
    XCTAssertTrue(reversed)
    XCTAssertEqual(detail.summary.closing, -450_000, "ters kayıt ödemeyi geri alır")
    XCTAssertFalse(detail.canReverse(try XCTUnwrap(detail.lines.first { $0.id == payment.id })))
    // Aynı iptal isteği tekrarlanırsa ikinci ters kayıt oluşmaz.
    _ = await detail.reverse(payment, reason: "Yanlış tutar", reversalId: reversalId)
    XCTAssertEqual(detail.lines.filter { $0.kind == .tersKayit }.count, 1)
  }

  func testDetailDateFilterKeepsOpeningBalance() async {
    let backend = await PreviewData.backend()
    let detail = CariDetailViewModel(account: PreviewData.taseron, access: AccessControl(grants: await backend.grants),
                                     repository: backend.repositories.cari)
    detail.filter.from = CalendarDate(year: 2026, month: 10, day: 1)
    await detail.load()
    XCTAssertEqual(detail.lines.count, 1)
    XCTAssertEqual(detail.summary.opening, -450_000)
    XCTAssertEqual(detail.summary.closing, -250_000)
  }

  func testListHidesBalancesWithoutPermission() async {
    let backend = await PreviewData.backend()
    let access = AccessControl(grants: grants(["cari.read"]))
    await backend.set(grants: grants(["cari.read"]))
    let vm = CariListViewModel(access: access, repository: backend.repositories.cari)
    await vm.load()
    XCTAssertEqual(vm.accounts.count, 2)
    XCTAssertFalse(vm.canSeeBalances)
    XCTAssertTrue(vm.balances.isEmpty)
  }

  func testListShowsBalancesAndTypeFilter() async {
    let backend = await PreviewData.backend()
    let vm = CariListViewModel(access: AccessControl(grants: await backend.grants), repository: backend.repositories.cari)
    vm.typeFilter = .taseron
    await vm.load()
    XCTAssertEqual(vm.accounts.map(\.code), ["DEMO-C01"])
    XCTAssertEqual(vm.balance(for: PreviewData.taseron)?.balanceTry, -250_000)
  }

  func testGeneralExpensesGroupsByCostCenter() async throws {
    let backend = await PreviewData.backend()
    try await backend.post(CariEntryDraft(cariAccountId: PreviewData.tedarikci.id, scope: .costCenter(PreviewData.office.id),
                                          entryDate: .today(), direction: .alacak, kind: .manuel, amount: 15_000,
                                          description: "Ofis kirası (örnek)"))
    let vm = GeneralExpensesViewModel(repositories: backend.repositories)
    await vm.load()
    XCTAssertEqual(vm.totalAlacak(for: PreviewData.office), 15_000)
    XCTAssertEqual(vm.balances(for: PreviewData.office).count, 1, "proje hareketleri genel gidere karışmaz")
  }
}

@MainActor
final class TaskListViewModelTests: XCTestCase {
  func testAddAndCompleteTask() async {
    let backend = await PreviewData.backend()
    let access = AccessControl(grants: grants(["is.read", "is.write"], project: PreviewData.sivas.id))
    await backend.set(grants: grants(["is.read", "is.write"], project: PreviewData.sivas.id))
    let vm = TaskListViewModel(projectId: PreviewData.sivas.id, projects: [PreviewData.sivas], access: access,
                               repository: backend.repositories.tasks)
    await vm.load()
    XCTAssertEqual(vm.tasks.count, 1)
    vm.newTitle = "İskele kontrolü"
    let added = await vm.addTask()
    XCTAssertTrue(added)
    XCTAssertEqual(vm.tasks.count, 2)
    await vm.setStatus(vm.tasks[0], to: .tamamlandi)
    XCTAssertEqual(vm.tasks.count, 1, "tamamlanan iş açık listeden düşer")
  }

  func testGeneralTaskNeedsGlobalPermission() async {
    let access = AccessControl(grants: grants(["is.write"], project: UUID()))
    let vm = TaskListViewModel(projects: [], access: access, repository: InMemoryBackend().repositories.tasks)
    XCTAssertFalse(vm.canCreate)
  }
}

@MainActor
final class CariPermissionTests: XCTestCase {
  func testProjectScopedWriterCannotCreateOrEditCards() async {
    let access = AccessControl(grants: [PermissionGrant(projectId: UUID(), permissionKey: "cari.write")])
    let list = CariListViewModel(access: access, repository: InMemoryBackend().repositories.cari)
    let detail = CariDetailViewModel(account: PreviewData.taseron, access: access,
                                     repository: InMemoryBackend().repositories.cari)
    XCTAssertFalse(list.canCreate, "cari kart açmak genel izin ister")
    XCTAssertFalse(detail.canEditAccount)
  }
}
