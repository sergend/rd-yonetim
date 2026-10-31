import Foundation
import XCTest
@testable import RDCore

private func day(_ month: Int, _ day: Int, _ year: Int = 2026) -> CalendarDate {
  CalendarDate(year: year, month: month, day: day)
}

private func grants(_ keys: [PermissionKey], project: UUID? = nil) -> [PermissionGrant] {
  keys.map { PermissionGrant(projectId: project, permissionKey: $0.rawValue) }
}

private let today = day(10, 30)

final class PuantajModelTests: XCTestCase {
  func testMonthLengthsIncludingLeapYears() {
    XCTAssertEqual(PuantajMonth(year: 2026, month: 2).dayCount, 28)
    XCTAssertEqual(PuantajMonth(year: 2024, month: 2).dayCount, 29)
    XCTAssertEqual(PuantajMonth(year: 2000, month: 2).dayCount, 29, "400'e bölünen yıl artık yıldır")
    XCTAssertEqual(PuantajMonth(year: 1900, month: 2).dayCount, 28, "100'e bölünüp 400'e bölünmeyen yıl artık değildir")
    XCTAssertEqual(PuantajMonth(year: 2026, month: 4).dayCount, 30)
    XCTAssertEqual(PuantajMonth(year: 2026, month: 10).dayCount, 31)
    XCTAssertEqual(PuantajMonth(year: 2024, month: 2).days.last, day(2, 29, 2024))
    XCTAssertEqual(PuantajMonth(year: 2026, month: 12).next, PuantajMonth(year: 2027, month: 1))
    XCTAssertEqual(PuantajMonth(year: 2026, month: 1).previous, PuantajMonth(year: 2025, month: 12))
    XCTAssertEqual(PuantajMonth(year: 2026, month: 10).title, "Ekim 2026")
  }

  func testWeekdays() {
    XCTAssertEqual(day(10, 30).isoWeekday, 5, "30 Ekim 2026 Cuma")
    XCTAssertEqual(day(11, 1).weekdayShort, "Paz")
    XCTAssertEqual(day(10, 5).dotted, "05.10.2026")
  }

  func testCountingAndPayMeaningAreSeparate() {
    XCTAssertEqual(PuantajStatus.tamGun.workEquivalent, 1)
    XCTAssertEqual(PuantajStatus.yarimGun.workEquivalent, Decimal(string: "0.5"))
    XCTAssertEqual(PuantajStatus.ucretliIzin.workEquivalent, 0, "ücretli izin fiilî çalışmayı artırmaz")
    XCTAssertEqual(PuantajStatus.ucretliIzin.payBasis, .ucretliIzin)
    XCTAssertEqual(PuantajStatus.resmiTatil.workEquivalent, 0, "resmî tatil çalışılmış sayılmaz")
    XCTAssertFalse(PuantajStatus.resmiTatil.isWork)
    XCTAssertEqual(PuantajStatus.allCases.filter(\.allowsOvertime), [.tamGun, .yarimGun])
  }

  func testCellInputDropsOvertimeOnNonWorkDaysAndEncodesClearAsNull() throws {
    let person = UUID()
    let leave = PuantajCellInput(personnelId: person, workDate: day(10, 1), status: .ucretliIzin, overtimeHours: 3,
                                 overtimeNote: "x")
    XCTAssertEqual(leave.overtimeHours, 0)
    XCTAssertNil(leave.overtimeNote)
    let clear = PuantajCellInput(personnelId: person, workDate: day(10, 1), status: nil, expectedVersion: 4)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clear)) as! [String: Any]
    XCTAssertTrue(json["status"] is NSNull, "hücre temizleme null gönderilir")
    XCTAssertEqual(json["expected_version"] as? Int, 4)
    XCTAssertEqual(json["work_date"] as? String, "2026-10-01")
  }

  func testQuickStatusChangeKeepsOvertimeOnlyBetweenWorkStatuses() {
    let person = UUID()
    let entry = PuantajEntry(projectId: UUID(), personnelId: person, workDate: day(10, 5), status: .tamGun,
                             overtimeHours: 2, overtimeNote: "beton", note: "B blok", personnelName: "Kalfa")
    let toHalf = PuantajCellInput.statusChange(personnelId: person, workDate: day(10, 5), from: entry, to: .yarimGun)
    XCTAssertEqual(toHalf.overtimeHours, 2)
    XCTAssertEqual(toHalf.overtimeNote, "beton")
    XCTAssertEqual(toHalf.note, "B blok")
    XCTAssertEqual(toHalf.expectedVersion, entry.version)
    for status in PuantajStatus.allCases where !status.allowsOvertime {
      let input = PuantajCellInput.statusChange(personnelId: person, workDate: day(10, 5), from: entry, to: status)
      XCTAssertEqual(input.overtimeHours, 0, "\(status)")
      XCTAssertNil(input.overtimeNote, "\(status)")
      XCTAssertEqual(input.note, "B blok", "not korunur")
    }
    let cleared = PuantajCellInput.statusChange(personnelId: person, workDate: day(10, 5), from: entry, to: nil)
    XCTAssertNil(cleared.status)
    XCTAssertEqual(cleared.overtimeHours, 0)
    XCTAssertNil(cleared.overtimeNote)
    XCTAssertNil(cleared.note)
    XCTAssertEqual(cleared.expectedVersion, entry.version)
  }

  func testOvertimeInput() {
    XCTAssertEqual(OvertimeInput.parse("2,5"), Decimal(string: "2.5"))
    XCTAssertEqual(OvertimeInput.parse(""), 0)
    XCTAssertNil(OvertimeInput.parse("17"))
    XCTAssertNil(OvertimeInput.parse("-1"))
    XCTAssertEqual(OvertimeInput.format(Decimal(string: "1.5")!), "1,5")
  }

  func testActionPermissions() {
    XCTAssertEqual(PuantajAction.yenidenAc.requiredPermission(from: .onaylandi), .puantajApprove)
    XCTAssertEqual(PuantajAction.yenidenAc.requiredPermission(from: .kilitli), .puantajUnlock)
    XCTAssertTrue(PuantajAction.onayla.allowedFrom.contains(.taslak), "basit akış: taslak doğrudan onaylanabilir")
    XCTAssertNil(PuantajPeriodStatus.kilitli.editPermission)
    XCTAssertNil(PuantajPeriodStatus.onaylandi.editPermission)
    XCTAssertEqual(PuantajPeriodStatus.incelemede.editPermission, .puantajReview)
  }
}

final class PuantajSummaryTests: XCTestCase {
  private func entry(_ status: PuantajStatus, _ d: Int, ot: Decimal = 0, approved: Bool = false,
                     person: UUID = UUID(), crew: UUID? = nil, crewName: String? = nil) -> PuantajEntry {
    PuantajEntry(projectId: UUID(), personnelId: person, workDate: day(4, d), status: status, overtimeHours: ot,
                 overtimeApprovedAt: approved ? Date() : nil, crewId: crew, personnelName: "Deneme", crewName: crewName)
  }

  func testCategoriesAreCountedSeparately() {
    let summary = PuantajSummary(entries: [
      entry(.tamGun, 1), entry(.yarimGun, 2), entry(.calismadi, 3), entry(.ucretliIzin, 4),
      entry(.ucretsizIzin, 6), entry(.raporlu, 7), entry(.resmiTatil, 8),
      entry(.tamGun, 9, ot: 3, approved: true), entry(.yarimGun, 10, ot: Decimal(string: "1.5")!),
    ])
    XCTAssertEqual(summary.recordedDays, 9)
    XCTAssertEqual(summary.fullDays, 2)
    XCTAssertEqual(summary.halfDays, 2)
    XCTAssertEqual(summary.workEquivalent, 3, "tam × 1 + yarım × 0,5; izin ve tatil eklenmez")
    XCTAssertEqual(summary.absentDays, 1)
    XCTAssertEqual(summary.paidLeaveDays, 1)
    XCTAssertEqual(summary.unpaidLeaveDays, 1)
    XCTAssertEqual(summary.sickDays, 1)
    XCTAssertEqual(summary.publicHolidayDays, 1)
    XCTAssertEqual(summary.overtimeHours, Decimal(string: "4.5"))
    XCTAssertEqual(summary.approvedOvertimeHours, 3)
  }

  func testUnenteredDaysAreNotAbsence() {
    let summary = PuantajSummary(entries: [entry(.tamGun, 1)])
    XCTAssertEqual(summary.absentDays, 0, "29 girilmemiş gün devamsızlık sayılmaz")
    XCTAssertEqual(summary.recordedDays, 1)
  }

  func testCrewSummaryUsesCrewOfThatDay() {
    let person = UUID()
    let crewA = UUID()
    let crewB = UUID()
    var entries: [PuantajEntry] = []
    for d in 1...10 { entries.append(entry(.tamGun, d, person: person, crew: crewA, crewName: "A Ekibi")) }
    for d in 11...20 { entries.append(entry(.yarimGun, d, person: person, crew: crewB, crewName: "B Ekibi")) }
    let grid = PuantajGrid(month: PuantajMonth(year: 2026, month: 4), entries: entries)
    let crews = grid.crewSummaries
    XCTAssertEqual(crews.map(\.name), ["A Ekibi", "B Ekibi"])
    XCTAssertEqual(crews[0].summary.fullDays, 10)
    XCTAssertEqual(crews[1].summary.halfDays, 10)
    XCTAssertEqual(grid.projectSummary.workEquivalent, 15)
  }
}

// MARK: - Bellek içi sunucu ile ekran modeli

@MainActor
final class PuantajViewModelTests: XCTestCase {
  private var backend: InMemoryBackend!
  private let project = Project(code: "TEST-PT", name: "Test projesi", startDate: day(1, 1))
  private let other = Project(code: "TEST-PT-B", name: "Diğer proje", startDate: day(1, 1))
  private let k1 = Personnel(fullName: "Gezici Usta")
  private let k2 = Personnel(fullName: "Kalfa")
  private let k3 = Personnel(fullName: "Tekniker")
  private let crewA = Crew(name: "A Ekibi")
  private let crewB = Crew(name: "B Ekibi")

  override func setUp() async throws {
    backend = InMemoryBackend()
    await backend.set(today: today)
    await backend.seed(projects: [project, other])
    // k1: 1–10 Ekim A ekibinde, 11'inden itibaren B ekibinde; B ekibi 20 Ekim'e
    // kadar bu projede, sonra diğer projede.
    await backend.seedWorkforce(
      personnel: [k1, k2, k3], crews: [crewA, crewB],
      memberships: [CrewMembership(crewId: crewA.id, personnelId: k1.id, startDate: day(10, 1), endDate: day(10, 10)),
                    CrewMembership(crewId: crewB.id, personnelId: k1.id, startDate: day(10, 11)),
                    CrewMembership(crewId: crewA.id, personnelId: k2.id, startDate: day(1, 1))],
      assignments: [ProjectAssignment(projectId: project.id, target: .crew(crewA.id), startDate: day(1, 1)),
                    ProjectAssignment(projectId: project.id, target: .crew(crewB.id), startDate: day(10, 1), endDate: day(10, 20)),
                    ProjectAssignment(projectId: other.id, target: .crew(crewB.id), startDate: day(10, 21)),
                    ProjectAssignment(projectId: project.id, target: .personnel(k3.id), startDate: day(1, 1)),
                    ProjectAssignment(projectId: other.id, target: .personnel(k3.id), startDate: day(1, 1))])
  }

  private func model(_ keys: [PermissionKey] = PermissionKey.allCases, project scope: UUID? = nil,
                     for project: Project? = nil, month: PuantajMonth = PuantajMonth(year: 2026, month: 10)) async -> PuantajViewModel {
    let list = grants(keys, project: scope)
    await backend.set(grants: list)
    return PuantajViewModel(project: project ?? self.project, access: AccessControl(grants: list),
                            repository: backend.repositories.puantaj, month: month, today: { today })
  }

  func testRosterShowsMidMonthCrewChangeAndProjectExit() async {
    let vm = await model()
    await vm.load()
    XCTAssertNil(vm.errorMessage)
    let row = try! XCTUnwrap(vm.grid.row(k1.id))
    XCTAssertEqual(row.link(on: day(10, 5))?.crewName, "A Ekibi")
    XCTAssertEqual(row.link(on: day(10, 15))?.crewName, "B Ekibi")
    XCTAssertFalse(row.isAssigned(on: day(10, 25)), "21 Ekim'den sonra diğer projede")
    XCTAssertTrue(row.changedCrewInMonth)
    XCTAssertEqual(vm.grid.rows.count, 3)
  }

  func testSingleCellSaveRecordsCrewOfThatDayAndKeepsHistory() async {
    let vm = await model()
    await vm.load()
    let saved1 = await vm.setCell(personnelId: k1.id, day: day(10, 2), status: .tamGun)
    let saved2 = await vm.setCell(personnelId: k1.id, day: day(10, 12), status: .tamGun)
    XCTAssertTrue(saved1 && saved2)
    let stored = await backend.puantajEntries.filter { $0.personnelId == k1.id }.sorted { $0.workDate < $1.workDate }
    XCTAssertEqual(stored.map(\.crewName), ["A Ekibi", "B Ekibi"], "her gün o günkü ekibe bağlanır")
    XCTAssertEqual(vm.grid.entry(k1.id, day(10, 12))?.status, .tamGun, "yerel tablo yeniden istek yapmadan güncellenir")

    let notAssigned = await vm.setCell(personnelId: k1.id, day: day(10, 25), status: .tamGun)
    XCTAssertFalse(notAssigned)
    XCTAssertEqual(vm.errorMessage, "Kişi bu tarihte projede görevli değil; önce görevlendirme veya ekip üyeliği ekleyin.")
  }

  func testSamePersonCanWorkInTwoProjectsSameDay() async {
    let vm = await model()
    await vm.load()
    let first = await vm.setCell(personnelId: k3.id, day: day(10, 2), status: .yarimGun)
    let otherVM = await model(for: other)
    await otherVM.load()
    let second = await otherVM.setCell(personnelId: k3.id, day: day(10, 2), status: .yarimGun)
    XCTAssertTrue(first && second)
    let count = await backend.puantajEntries.filter { $0.personnelId == k3.id && $0.workDate == day(10, 2) }.count
    XCTAssertEqual(count, 2)
  }

  func testRules() async {
    let vm = await model()
    await vm.load()
    XCTAssertEqual(vm.cellProblem(personnelId: k2.id, day: day(10, 31), status: .tamGun, overtimeHours: 0),
                   "İleri bir tarihe çalışma girilemez.")
    XCTAssertNil(vm.cellProblem(personnelId: k2.id, day: day(10, 31), status: .ucretliIzin, overtimeHours: 0),
                 "planlı izin ileri tarihe girilebilir")
    XCTAssertEqual(vm.cellProblem(personnelId: k2.id, day: day(10, 2), status: .calismadi, overtimeHours: 2),
                   "Fazla mesai yalnızca tam veya yarım gün çalışılan güne yazılabilir.")
  }

  func testClearingCellReturnsToUnprocessed() async {
    let vm = await model()
    await vm.load()
    _ = await vm.setCell(personnelId: k2.id, day: day(10, 2), status: .tamGun)
    let cleared = await vm.setCell(personnelId: k2.id, day: day(10, 2), status: nil)
    XCTAssertTrue(cleared)
    XCTAssertNil(vm.grid.entry(k2.id, day(10, 2)))
    XCTAssertEqual(vm.grid.summary(for: k2.id).absentDays, 0, "temizlenen gün devamsızlık değildir")
    XCTAssertEqual(vm.grid.unprocessedDays(for: vm.grid.row(k2.id)!, today: today), 30,
                   "1–30 Ekim işlenmemiş (bilgi amaçlı)")
  }

  func testBulkFillKeepsExistingUnlessOverwriteChosen() async {
    let vm = await model()
    await vm.load()
    _ = await vm.setCell(personnelId: k2.id, day: day(10, 5), status: .raporlu)
    let people = [k1.id, k2.id, k3.id]
    let keep = vm.planFill(day: day(10, 5), people: people, status: .tamGun, overwrite: false)
    XCTAssertEqual(keep.lines.map(\.kind), [.ekle, .korunacak, .ekle])
    XCTAssertEqual(keep.items.count, 2)
    XCTAssertEqual(keep.keptCount, 1)

    let over = vm.planFill(day: day(10, 5), people: people, status: .tamGun, overwrite: true)
    XCTAssertEqual(over.overwriteCount, 1)
    XCTAssertEqual(over.items.first { $0.personnelId == k2.id }?.expectedVersion, 1, "üzerine yazma okunan sürümle gider")

    let saved = await vm.commit(keep)
    XCTAssertTrue(saved)
    XCTAssertEqual(vm.notice, "2 hücre eklendi.")
    XCTAssertEqual(vm.grid.entry(k2.id, day(10, 5))?.status, .raporlu, "dolu hücre korundu")

    let calls = await backend.saveCallCount
    let again = await vm.commit(vm.planFill(day: day(10, 5), people: people, status: .tamGun, overwrite: false))
    XCTAssertTrue(again)
    XCTAssertEqual(vm.notice, "Kaydedilecek değişiklik yok.", "tekrar uygulama mükerrer kayıt üretmez")
    let callsAfter = await backend.saveCallCount
    XCTAssertEqual(calls, callsAfter, "değişiklik yoksa istek gönderilmez")
  }

  func testResubmittingSameItemsIsIdempotent() async {
    let vm = await model()
    await vm.load()
    let items = [PuantajCellInput(personnelId: k2.id, workDate: day(10, 6), status: .tamGun),
                 PuantajCellInput(personnelId: k3.id, workDate: day(10, 6), status: .tamGun)]
    let repo = backend.repositories.puantaj
    let first = try! await repo.save(projectId: project.id, items: items, overwrite: false)
    let second = try! await repo.save(projectId: project.id, items: items, overwrite: false)
    XCTAssertEqual(first.map(\.result), [.eklendi, .eklendi])
    XCTAssertEqual(second.map(\.result), [.degismedi, .degismedi], "ağ hatası sonrası tekrar gönderim güvenli")
    let count = await backend.puantajEntries.count
    XCTAssertEqual(count, 2)
  }

  func testConcurrentEditIsRejectedAndTableReloads() async {
    let mine = await model()
    await mine.load()
    _ = await mine.setCell(personnelId: k2.id, day: day(10, 7), status: .tamGun)

    // Başka kullanıcı aynı hücreyi değiştirir.
    let theirs = await model()
    await theirs.load()
    _ = await theirs.setCell(personnelId: k2.id, day: day(10, 7), status: .yarimGun)

    let saved = await mine.setCell(personnelId: k2.id, day: day(10, 7), status: .calismadi)
    XCTAssertFalse(saved)
    XCTAssertEqual(mine.errorMessage,
                   "Kalfa için 07.10.2026 tarihli kayıt siz düzenlerken başka biri tarafından değiştirildi. Tabloyu yenileyip tekrar deneyin.")
    XCTAssertEqual(mine.grid.entry(k2.id, day(10, 7))?.status, .yarimGun, "tablo güncel değerle yenilenir")
  }

  func testCopyPreviousDayShowsWhatWillBeAppliedAndSkipsOvertime() async {
    let vm = await model()
    await vm.load()
    _ = await vm.setCell(personnelId: k2.id, day: day(10, 8), status: .tamGun, overtimeHours: 2)
    _ = await vm.setCell(personnelId: k3.id, day: day(10, 8), status: .ucretliIzin)
    _ = await vm.setCell(personnelId: k3.id, day: day(10, 9), status: .raporlu)
    let plan = await vm.planCopy(from: day(10, 8), to: day(10, 9), people: [k1.id, k2.id, k3.id], overwrite: false)
    let byPerson = Dictionary(uniqueKeysWithValues: plan.lines.map { ($0.personnelId, $0) })
    XCTAssertEqual(byPerson[k1.id]?.kind, .kaynakYok)
    XCTAssertEqual(byPerson[k2.id]?.kind, .ekle)
    XCTAssertEqual(byPerson[k3.id]?.kind, .korunacak)
    XCTAssertEqual(plan.items.count, 1)
    XCTAssertEqual(plan.items.first?.overtimeHours, 0, "fazla mesai kopyalanmaz")
  }

  func testCopyToFirstDayReadsPreviousMonth() async {
    let september = await model(month: PuantajMonth(year: 2026, month: 9))
    await september.load()
    _ = await september.setCell(personnelId: k2.id, day: day(9, 30), status: .yarimGun)
    let vm = await model()
    await vm.load()
    let plan = await vm.planCopy(from: day(9, 30), to: day(10, 1), people: [k2.id], overwrite: false)
    XCTAssertEqual(plan.lines.first?.new, .yarimGun)
    XCTAssertEqual(plan.lines.first?.kind, .ekle)
  }

  func testMonthNavigation() async {
    let vm = await model()
    await vm.load()
    await vm.showPreviousMonth()
    XCTAssertEqual(vm.month, PuantajMonth(year: 2026, month: 9))
    XCTAssertEqual(vm.grid.month.dayCount, 30)
    await vm.showNextMonth()
    await vm.showNextMonth()
    XCTAssertEqual(vm.month.title, "Kasım 2026")
  }

  func testApprovalLockAndReopenFlow() async {
    let chief = await model([.puantajRead, .puantajWrite], project: project.id)
    await chief.load()
    _ = await chief.setCell(personnelId: k2.id, day: day(10, 2), status: .tamGun)
    XCTAssertEqual(chief.availableActions, [.gonder], "şantiye şefi yalnızca incelemeye gönderir")
    let sent = await chief.perform(.gonder)
    XCTAssertTrue(sent)
    XCTAssertFalse(chief.canEdit, "incelemedeki aya şef yazamaz")

    let manager = await model([.puantajRead, .puantajWrite, .puantajReview, .puantajApprove], project: project.id)
    await manager.load()
    XCTAssertTrue(manager.canEdit)
    XCTAssertEqual(Set(manager.availableActions), [.iade, .onayla])
    let approved = await manager.perform(.onayla)
    XCTAssertTrue(approved)
    XCTAssertFalse(manager.canEdit, "onaylı ayda kimse yazamaz")
    let edit = await manager.setCell(personnelId: k2.id, day: day(10, 3), status: .tamGun)
    XCTAssertFalse(edit)

    let locked = await manager.perform(.kilitle)
    XCTAssertTrue(locked)
    XCTAssertEqual(manager.availableActions, [], "kilitli ayı proje müdürü açamaz")

    let admin = await model()
    await admin.load()
    let noReason = await admin.perform(.yenidenAc, reason: "kısa")
    XCTAssertFalse(noReason)
    let reopened = await admin.perform(.yenidenAc, reason: "Kalfanın raporlu günleri eksik")
    XCTAssertTrue(reopened)
    XCTAssertEqual(admin.status, .taslak)
    XCTAssertEqual(admin.period?.revision, 1)
    XCTAssertNotNil(admin.period?.firstApprovedAt, "ilk onay bilgisi korunur")
    XCTAssertEqual(admin.events.map(\.action), [.gonder, .onayla, .kilitle, .yenidenAc])
  }

  func testOvertimeApproval() async {
    let vm = await model()
    await vm.load()
    _ = await vm.setCell(personnelId: k2.id, day: day(10, 9), status: .tamGun, overtimeHours: 3)
    XCTAssertEqual(vm.pendingOvertime.count, 1)
    await vm.approveOvertime(vm.pendingOvertime)
    XCTAssertEqual(vm.grid.summary(for: k2.id).approvedOvertimeHours, 3)
    _ = await vm.setCell(personnelId: k2.id, day: day(10, 9), status: .tamGun, overtimeHours: 4)
    XCTAssertEqual(vm.grid.summary(for: k2.id).approvedOvertimeHours, 0, "saati değişen fazla mesainin onayı düşer")
  }

  func testQuickStatusChangeFromOvertimeDayToNonWorkStatus() async {
    let vm = await model()
    await vm.load()
    _ = await vm.setCell(personnelId: k2.id, day: day(10, 9), status: .tamGun, overtimeHours: 2,
                         overtimeNote: "beton", note: "B blok")
    let half = await vm.setStatus(personnelId: k2.id, day: day(10, 9), status: .yarimGun)
    XCTAssertTrue(half)
    XCTAssertEqual(vm.grid.entry(k2.id, day(10, 9))?.overtimeHours, 2, "çalışma durumları arasında mesai korunur")
    XCTAssertEqual(vm.grid.entry(k2.id, day(10, 9))?.overtimeNote, "beton")
    for status in PuantajStatus.allCases where !status.allowsOvertime {
      _ = await vm.setStatus(personnelId: k2.id, day: day(10, 9), status: .tamGun)
      _ = await vm.setCell(personnelId: k2.id, day: day(10, 9), status: .tamGun, overtimeHours: 2,
                           overtimeNote: "beton", note: "B blok")
      let ok = await vm.setStatus(personnelId: k2.id, day: day(10, 9), status: status)
      XCTAssertTrue(ok, "\(status): \(vm.errorMessage ?? "")")
      let entry = vm.grid.entry(k2.id, day(10, 9))
      XCTAssertEqual(entry?.status, status)
      XCTAssertEqual(entry?.overtimeHours, 0, "\(status)")
      XCTAssertNil(entry?.overtimeNote, "\(status)")
      XCTAssertEqual(entry?.note, "B blok")
    }
    let cleared = await vm.setStatus(personnelId: k2.id, day: day(10, 9), status: nil)
    XCTAssertTrue(cleared)
    XCTAssertNil(vm.grid.entry(k2.id, day(10, 9)))
    XCTAssertEqual(vm.grid.summary(for: k2.id).overtimeHours, 0, "temizlenen hücrede artık mesai kalmaz")
  }

  func testOvertimeApprovalIsRejectedInApprovedMonth() async {
    let vm = await model()
    await vm.load()
    _ = await vm.setCell(personnelId: k2.id, day: day(10, 9), status: .tamGun, overtimeHours: 3)
    let pending = vm.pendingOvertime
    XCTAssertEqual(pending.count, 1)
    let approved = await vm.perform(.onayla)
    XCTAssertTrue(approved)
    XCTAssertEqual(vm.status, .onaylandi)
    await vm.approveOvertime(pending)
    XCTAssertNotNil(vm.errorMessage)
    XCTAssertEqual(vm.grid.summary(for: k2.id).approvedOvertimeHours, 0)
  }

  func testOtherProjectAndMissingPermission() async {
    let chief = await model([.puantajRead, .puantajWrite], project: project.id, for: other)
    XCTAssertFalse(chief.canRead)
    await chief.load()
    XCTAssertTrue(chief.grid.rows.isEmpty, "başka projenin puantajı yüklenmez")
    do {
      _ = try await backend.repositories.puantaj.save(
        projectId: other.id, items: [PuantajCellInput(personnelId: k3.id, workDate: day(10, 2), status: .tamGun)],
        overwrite: false)
      XCTFail("başka projeye yazılmamalı")
    } catch {
      XCTAssertEqual(error as? RepositoryError, .forbidden("Bu projede puantaj girme yetkiniz yok"))
    }
    let accountant = await model([.puantajRead, .cariRead, .cariHareketWrite])
    await accountant.load()
    XCTAssertFalse(accountant.canEdit)
    XCTAssertEqual(accountant.availableActions, [], "finans yetkisi puantaj onay yetkisi değildir")
  }

  func testDemoAndRealRecordsDoNotMix() async {
    let demoProject = Project(code: "DEMO-PT", name: "Demo", startDate: day(1, 1), isDemo: true)
    await backend.seed(projects: [demoProject])
    await backend.seedWorkforce(assignments: [ProjectAssignment(projectId: demoProject.id, target: .personnel(k2.id),
                                                                startDate: day(1, 1))])
    let vm = await model(for: demoProject)
    await vm.load()
    let saved = await vm.setCell(personnelId: k2.id, day: day(10, 2), status: .tamGun)
    XCTAssertFalse(saved)
    XCTAssertEqual(vm.errorMessage, "Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez")
  }

  func testPuantajCreatesNoFinancialRecords() async {
    let vm = await model()
    await vm.load()
    let before = await backend.entries.count
    _ = await vm.commit(vm.planFill(day: day(10, 2), people: [k1.id, k2.id, k3.id], status: .tamGun, overwrite: false))
    _ = await vm.perform(.onayla)
    _ = await vm.perform(.kilitle)
    let after = await backend.entries.count
    XCTAssertEqual(before, after, "puantaj, onay ve kilit cari hareket oluşturmaz")
  }

  func testPuantajModuleVisibility() {
    let chief = AccessControl(grants: grants([.puantajRead], project: UUID()))
    XCTAssertTrue(AppModule.puantaj.isVisible(for: chief))
    XCTAssertTrue(AppModule.puantaj.isAvailable)
    XCTAssertFalse(AppModule.puantaj.isVisible(for: AccessControl(grants: grants([.cariRead]))))
  }
}
