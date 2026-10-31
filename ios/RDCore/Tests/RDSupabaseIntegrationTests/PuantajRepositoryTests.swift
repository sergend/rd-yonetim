import Foundation
import RDCore
import RDSupabase
import XCTest

/// Puantaj repository'sinin yerel Supabase (seed.sql demo verisi) üzerinde
/// uçtan uca testi. Ayar yoksa atlanır. Testler tekrar çalıştırılabilir:
/// rastgele bir geçmiş ay seçilir, mevcut kayıtlar "değişmedi" olarak döner.
final class PuantajRepositoryTests: XCTestCase {
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

  /// Kalıp Ekibi Sivas'ta 1 Mart 2026'dan beri görevli; Nisan–Eylül arası rastgele ay.
  private let month = PuantajMonth(year: 2026, month: Int.random(in: 4...9))

  private func person(_ name: String, in roster: [PuantajRosterLink]) throws -> UUID {
    try XCTUnwrap(roster.first { $0.fullName == name }?.personnelId)
  }

  func testMonthLoadsInOneGoAndSwiftSummaryMatchesServer() async throws {
    let repos = try await signedIn("sef@example.test")
    let sivas = try await sivas(repos)
    let october = PuantajMonth(year: 2026, month: 10)
    let roster = try await repos.puantaj.roster(projectId: sivas.id, month: october)
    XCTAssertTrue(Set(roster.map(\.fullName)).isSuperset(of: ["Deneme Kalıp Ustası", "Deneme Şantiye Teknikeri"]))
    XCTAssertEqual(roster.first { $0.fullName == "Deneme Kalıp Ustası" }?.crewName, "Kalıp Ekibi")
    XCTAssertEqual(roster.first { $0.fullName == "Deneme Kalıp Ustası" }?.endDate, october.lastDay)

    let entries = try await repos.puantaj.entries(projectId: sivas.id, month: october)
    XCTAssertFalse(entries.isEmpty, "demo Ekim puantajı")
    let grid = PuantajGrid(month: october, roster: roster, entries: entries)
    let server = try await repos.puantaj.summary(projectId: sivas.id, month: october)
    XCTAssertFalse(server.isEmpty)
    for row in server {
      XCTAssertEqual(grid.summary(for: row.personnelId), row.summary,
                     "\(row.personnelName): uygulama ile sunucu aynı sayım kurallarını kullanır")
    }
  }

  func testBulkSaveIsIdempotentAndStaleVersionIsRejected() async throws {
    let repos = try await signedIn("sef@example.test")
    let sivas = try await sivas(repos)
    if try await repos.puantaj.period(projectId: sivas.id, month: month)?.status ?? .taslak != .taslak {
      try await reopen(month, in: sivas)
    }
    let roster = try await repos.puantaj.roster(projectId: sivas.id, month: month)
    let usta = try person("Deneme Kalıp Ustası", in: roster)
    let kalfa = try person("Deneme Kalıp Kalfası", in: roster)

    // Her durumdan birer gün: sunucu ve uygulama özeti karşılaştırılır.
    var items: [PuantajCellInput] = []
    for (index, status) in PuantajStatus.allCases.enumerated() {
      items.append(PuantajCellInput(personnelId: kalfa, workDate: CalendarDate(year: 2026, month: month.month, day: index + 1),
                                    status: status, overtimeHours: status == .tamGun ? 2 : 0))
    }
    items.append(PuantajCellInput(personnelId: usta, workDate: month.firstDay, status: .yarimGun))
    let first = try await repos.puantaj.save(projectId: sivas.id, items: items, overwrite: true)
    XCTAssertEqual(first.count, items.count)
    XCTAssertTrue(first.allSatisfy { [.eklendi, .degismedi, .guncellendi].contains($0.result) })

    let again = try await repos.puantaj.save(projectId: sivas.id, items: items, overwrite: false)
    XCTAssertTrue(again.allSatisfy { $0.result == .degismedi }, "tekrar gönderim mükerrer kayıt üretmez")

    let entries = try await repos.puantaj.entries(projectId: sivas.id, month: month)
    let server = try await repos.puantaj.summary(projectId: sivas.id, month: month)
    let grid = PuantajGrid(month: month, roster: roster, entries: entries)
    let kalfaServer = try XCTUnwrap(server.first { $0.personnelId == kalfa })
    XCTAssertEqual(grid.summary(for: kalfa), kalfaServer.summary)
    XCTAssertGreaterThanOrEqual(kalfaServer.fiiliCalisma, Decimal(string: "1.5")!)

    // Başkası hücreyi değiştirmiş gibi: eski sürümle gönderim reddedilir.
    let cell = try XCTUnwrap(entries.first { $0.personnelId == usta && $0.workDate == month.firstDay })
    _ = try await repos.puantaj.save(projectId: sivas.id, items: [
      PuantajCellInput(personnelId: usta, workDate: month.firstDay, status: .tamGun, expectedVersion: cell.version),
    ], overwrite: false)
    do {
      _ = try await repos.puantaj.save(projectId: sivas.id, items: [
        PuantajCellInput(personnelId: usta, workDate: month.firstDay, status: .calismadi, expectedVersion: cell.version),
      ], overwrite: false)
      XCTFail("eski sürüm reddedilmeli")
    } catch let error as RepositoryError {
      guard case .conflict(let message) = error else { return XCTFail("beklenen conflict, gelen \(error)") }
      XCTAssertTrue(message?.contains("başka biri tarafından değiştirildi") == true, message ?? "")
    }
    // Geri al: sonraki çalıştırmada aynı başlangıç durumu.
    let latest = try await repos.puantaj.entries(projectId: sivas.id, month: month)
      .first { $0.personnelId == usta && $0.workDate == month.firstDay }
    _ = try await repos.puantaj.save(projectId: sivas.id, items: [
      PuantajCellInput(personnelId: usta, workDate: month.firstDay, status: .yarimGun, expectedVersion: latest?.version),
    ], overwrite: false)
  }

  func testQuickStatusChangeDropsOvertimeForNonWorkStatus() async throws {
    let repos = try await signedIn("sef@example.test")
    let sivas = try await sivas(repos)
    if try await repos.puantaj.period(projectId: sivas.id, month: month)?.status ?? .taslak != .taslak {
      try await reopen(month, in: sivas)
    }
    let roster = try await repos.puantaj.roster(projectId: sivas.id, month: month)
    let kalfa = try person("Deneme Kalıp Kalfası", in: roster)
    let day = CalendarDate(year: 2026, month: month.month, day: 20)
    func current() async throws -> PuantajEntry? {
      try await repos.puantaj.entries(projectId: sivas.id, month: month).first { $0.personnelId == kalfa && $0.workDate == day }
    }
    _ = try await repos.puantaj.save(projectId: sivas.id, items: [
      PuantajCellInput(personnelId: kalfa, workDate: day, status: .tamGun, overtimeHours: 2, overtimeNote: "beton",
                       note: "B blok"),
    ], overwrite: true)

    _ = try await repos.puantaj.save(projectId: sivas.id, items: [
      PuantajCellInput.statusChange(personnelId: kalfa, workDate: day, from: try await current(), to: .yarimGun),
    ], overwrite: false)
    let half = try await current()
    XCTAssertEqual(half?.overtimeHours, 2, "çalışma durumları arasında mesai korunur")

    for status in PuantajStatus.allCases where !status.allowsOvertime {
      _ = try await repos.puantaj.save(projectId: sivas.id, items: [
        PuantajCellInput(personnelId: kalfa, workDate: day, status: .tamGun, overtimeHours: 2, overtimeNote: "beton",
                         note: "B blok"),
      ], overwrite: true)
      let result = try await repos.puantaj.save(projectId: sivas.id, items: [
        PuantajCellInput.statusChange(personnelId: kalfa, workDate: day, from: try await current(), to: status),
      ], overwrite: false)
      XCTAssertEqual(result.first?.result, .guncellendi, "\(status)")
      let entry = try await current()
      XCTAssertEqual(entry?.status, status)
      XCTAssertEqual(entry?.overtimeHours, 0, "\(status)")
      XCTAssertNil(entry?.overtimeNote, "\(status)")
      XCTAssertEqual(entry?.note, "B blok")
    }
  }

  func testNotAssignedAndFutureWorkAreRejectedInTurkish() async throws {
    let repos = try await signedIn("sef@example.test")
    let sivas = try await sivas(repos)
    let roster = try await repos.puantaj.roster(projectId: sivas.id, month: PuantajMonth(year: 2026, month: 10))
    let usta = try person("Deneme Kalıp Ustası", in: roster)
    do {
      _ = try await repos.puantaj.save(projectId: sivas.id, items: [
        PuantajCellInput(personnelId: usta, workDate: CalendarDate(year: 2026, month: 2, day: 2), status: .tamGun),
      ], overwrite: false)
      XCTFail("görevlendirme öncesi gün reddedilmeli")
    } catch let error as RepositoryError {
      XCTAssertEqual(error, .validation("Deneme Kalıp Ustası bu tarihte (02.02.2026) projede görevli değil; önce görevlendirme veya ekip üyeliği ekleyin"))
    }
    let tomorrow = CalendarDate.today().adding(days: 1)
    do {
      _ = try await repos.puantaj.save(projectId: sivas.id, items: [
        PuantajCellInput(personnelId: usta, workDate: tomorrow, status: .tamGun),
      ], overwrite: false)
      XCTFail("ileri tarihli çalışma reddedilmeli")
    } catch let error as RepositoryError {
      guard case .validation(let message) = error else { return XCTFail("beklenen validation, gelen \(error)") }
      XCTAssertTrue(message.hasPrefix("İleri bir tarihe çalışma girilemez"), message)
    }
  }

  func testApprovalFlowAndFinanceRoleCannotApprove() async throws {
    let chief = try await signedIn("sef@example.test")
    let sivas = try await sivas(chief)
    let flowMonth = PuantajMonth(year: 2026, month: 3)
    if try await chief.puantaj.period(projectId: sivas.id, month: flowMonth)?.status ?? .taslak != .taslak {
      try await reopen(flowMonth, in: sivas)
    }
    let roster = try await chief.puantaj.roster(projectId: sivas.id, month: flowMonth)
    let teknik = try person("Deneme Şantiye Teknikeri", in: roster)
    _ = try await chief.puantaj.save(projectId: sivas.id, items: [
      PuantajCellInput(personnelId: teknik, workDate: CalendarDate(year: 2026, month: 3, day: 2), status: .tamGun),
      PuantajCellInput(personnelId: teknik, workDate: CalendarDate(year: 2026, month: 3, day: 3), status: .tamGun,
                       overtimeHours: 2),
    ], overwrite: false)

    do {
      _ = try await chief.puantaj.transition(projectId: sivas.id, month: flowMonth, action: .onayla, reason: nil,
                                             expectedVersion: nil)
      XCTFail("şantiye şefi onaylayamamalı")
    } catch let error as RepositoryError {
      XCTAssertEqual(error, .forbidden("Puantaj onaylama yetkiniz yok"))
    }
    let sent = try await chief.puantaj.transition(projectId: sivas.id, month: flowMonth, action: .gonder, reason: nil,
                                                  expectedVersion: nil)
    XCTAssertEqual(sent.status, .incelemede)

    let accountant = try await signedIn("muhasebe@example.test")
    let visible = try await accountant.puantaj.entries(projectId: sivas.id, month: flowMonth)
    XCTAssertFalse(visible.isEmpty, "muhasebe puantajı okur")
    do {
      _ = try await accountant.puantaj.transition(projectId: sivas.id, month: flowMonth, action: .onayla, reason: nil,
                                                  expectedVersion: nil)
      XCTFail("finans yetkisi onay yetkisi değildir")
    } catch let error as RepositoryError {
      guard case .forbidden = error else { return XCTFail("beklenen forbidden, gelen \(error)") }
    }

    let admin = try await signedIn("yonetici@example.test")
    let approved = try await admin.puantaj.transition(projectId: sivas.id, month: flowMonth, action: .onayla, reason: nil,
                                                      expectedVersion: sent.version)
    XCTAssertEqual(approved.status, .onaylandi)
    XCTAssertNotNil(approved.firstApprovedAt)
    do {
      _ = try await admin.puantaj.save(projectId: sivas.id, items: [
        PuantajCellInput(personnelId: teknik, workDate: CalendarDate(year: 2026, month: 3, day: 2), status: .calismadi),
      ], overwrite: true)
      XCTFail("onaylı aya yazılmamalı")
    } catch let error as RepositoryError {
      guard case .validation(let message) = error else { return XCTFail("beklenen validation, gelen \(error)") }
      XCTAssertTrue(message.contains("yeniden açılması gerekir"), message)
    }
    let overtime = try await admin.puantaj.entries(projectId: sivas.id, month: flowMonth)
      .filter { $0.personnelId == teknik && $0.hasOvertime && !$0.isOvertimeApproved }
    XCTAssertFalse(overtime.isEmpty)
    do {
      _ = try await admin.puantaj.approveOvertime(entryIds: overtime.map(\.id))
      XCTFail("onaylı ayda fazla mesai onaylanmamalı")
    } catch let error as RepositoryError {
      guard case .validation(let message) = error else { return XCTFail("beklenen validation, gelen \(error)") }
      XCTAssertTrue(message.contains("fazla mesai onayı için"), message)
    }
    let reopened = try await admin.puantaj.transition(projectId: sivas.id, month: flowMonth, action: .yenidenAc,
                                                      reason: "Entegrasyon testi düzeltmesi", expectedVersion: nil)
    XCTAssertEqual(reopened.status, .taslak)
    XCTAssertEqual(reopened.firstApprovedAt != nil, true, "ilk onay korunur")
    let events = try await admin.puantaj.events(periodId: reopened.id)
    XCTAssertEqual(Array(events.suffix(3).map(\.action)), [.gonder, .onayla, .yenidenAc])
  }

  private func reopen(_ month: PuantajMonth, in project: Project) async throws {
    let admin = try await signedIn("yonetici@example.test")
    _ = try await admin.puantaj.transition(projectId: project.id, month: month, action: .yenidenAc,
                                           reason: "Önceki test çalıştırmasından kalan onay", expectedVersion: nil)
  }
}
