import Foundation
import RDCore
import RDSupabase
import XCTest

/// Yerel Supabase (supabase db reset + seed.sql) üzerinde repository'lerin
/// uçtan uca testi. RD_SUPABASE_URL ve RD_SUPABASE_ANON_KEY yoksa atlanır.
/// Hiçbir zaman canlı veritabanına yöneltilmez: yalnızca 127.0.0.1 kabul edilir.
final class SupabaseRepositoryTests: XCTestCase {
  private let password = "yerel-test-1234"
  private let taseronCode = "DEMO-C01"

  private func repositories() throws -> Repositories {
    let env = ProcessInfo.processInfo.environment
    guard let raw = env["RD_SUPABASE_URL"], let url = URL(string: raw), let key = env["RD_SUPABASE_ANON_KEY"] else {
      throw XCTSkip("Yerel Supabase ayarı yok (RD_SUPABASE_URL / RD_SUPABASE_ANON_KEY)")
    }
    guard url.host == "127.0.0.1" || url.host == "localhost" else {
      XCTFail("Entegrasyon testleri yalnızca yerel Supabase'e bağlanır")
      throw XCTSkip("yerel olmayan adres")
    }
    return SupabaseEnvironment.makeRepositories(config: SupabaseConfig(url: url, anonKey: key))
  }

  private func signedIn(_ email: String) async throws -> Repositories {
    let repos = try repositories()
    _ = try await repos.auth.signIn(email: email, password: password)
    return repos
  }

  func testWrongPasswordMapsToInvalidCredentials() async throws {
    let repos = try repositories()
    do {
      _ = try await repos.auth.signIn(email: "muhasebe@example.test", password: "yanlis-sifre-000")
      XCTFail("giriş başarılı olmamalı")
    } catch let error as RepositoryError {
      XCTAssertEqual(error, .invalidCredentials)
    }
  }

  func testAccountantSeesDemoProjectAndBalances() async throws {
    let repos = try await signedIn("muhasebe@example.test")
    let profile = try await repos.access.myProfile()
    XCTAssertEqual(profile.email, "muhasebe@example.test")
    let access = AccessControl(grants: try await repos.access.myPermissions())
    XCTAssertTrue(access.can(.cariHareketWrite))

    let projects = try await repos.projects.list(includeCompleted: true)
    let sivas = try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
    XCTAssertEqual(sivas.name, "Sivas 30 Daire Projesi")
    XCTAssertTrue(sivas.isDemo)

    let accounts = try await repos.cari.listAccounts(type: .taseron, search: nil)
    let taseron = try XCTUnwrap(accounts.first { $0.code == taseronCode })
    let lines = try await repos.cari.statement(accountId: taseron.id, filter: CariFilter(projectId: sivas.id))
    XCTAssertGreaterThanOrEqual(lines.count, 3)
    let balances = try await repos.cari.balances(filter: CariFilter(projectId: sivas.id))
    let balance = try XCTUnwrap(balances.first { $0.cariAccountId == taseron.id })
    XCTAssertEqual(balance.balanceTry, lines.last?.runningBalanceTry, "bakiye ekstrenin son satırıyla aynı")

    let costCenters = try await repos.costCenters.list()
    XCTAssertTrue(costCenters.contains { $0.code == "GENEL-OFIS" })
  }

  func testPostRetryIsIdempotentAndReversalWorks() async throws {
    let repos = try await signedIn("muhasebe@example.test")
    let projects = try await repos.projects.list(includeCompleted: true)
    let sivas = try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
    let found = try await repos.cari.listAccounts(type: nil, search: taseronCode)
    let taseron = try XCTUnwrap(found.first)
    let before = try await repos.cari.balances(filter: CariFilter()).first { $0.cariAccountId == taseron.id }?.balanceTry ?? 0

    let draft = CariEntryDraft(cariAccountId: taseron.id, scope: .project(sivas.id), entryDate: .today(),
                               direction: .borc, kind: .odeme, amount: Decimal(string: "1234.56")!,
                               description: "Entegrasyon testi ödemesi")
    try await repos.cari.post(draft)
    try await repos.cari.post(draft)  // ağ hatası sonrası tekrar
    let afterPost = try await repos.cari.balances(filter: CariFilter()).first { $0.cariAccountId == taseron.id }!.balanceTry
    XCTAssertEqual(afterPost - before, Decimal(string: "1234.56")!, "tekrar gönderim ikinci borç oluşturmaz")

    var changed = draft
    changed.amount = 99
    do {
      try await repos.cari.post(changed)
      XCTFail("aynı kimlikle farklı tutar reddedilmeli")
    } catch let error as RepositoryError {
      guard case .conflict = error else { return XCTFail("beklenen conflict, gelen \(error)") }
    }

    try await repos.cari.reverse(entryId: draft.id, reason: "Test iptali", reversalId: UUID())
    let afterReverse = try await repos.cari.balances(filter: CariFilter()).first { $0.cariAccountId == taseron.id }!.balanceTry
    XCTAssertEqual(afterReverse, before)
    do {
      try await repos.cari.reverse(entryId: draft.id, reason: "İkinci iptal", reversalId: UUID())
      XCTFail("ikinci iptal reddedilmeli")
    } catch let error as RepositoryError {
      XCTAssertEqual(error, .validation("Bu hareket zaten iptal edilmiş"))
    }
  }

  func testSiteChiefCannotSeeOrPostFinance() async throws {
    let repos = try await signedIn("sef@example.test")
    let projects = try await repos.projects.list(includeCompleted: true)
    let sivas = try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
    let accounts = try await repos.cari.listAccounts(type: nil, search: nil)
    let balances = try await repos.cari.balances(filter: CariFilter())
    XCTAssertTrue(accounts.isEmpty)
    XCTAssertTrue(balances.isEmpty)
    let tasks = try await repos.tasks.list(projectId: sivas.id, openOnly: true)
    XCTAssertFalse(tasks.isEmpty, "şantiye şefi projesinin işlerini görür")

    let draft = CariEntryDraft(cariAccountId: UUID(), scope: .project(sivas.id), entryDate: .today(),
                               direction: .borc, kind: .odeme, amount: 1, description: "izinsiz")
    do {
      try await repos.cari.post(draft)
      XCTFail("şantiye şefi hareket girememeli")
    } catch let error as RepositoryError {
      XCTAssertEqual(error, .forbidden("Cari hareket girme yetkiniz yok"))
    }
  }

  func testProjectEditUsesOptimisticLock() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let code = "TEST-IOS-\(Int.random(in: 1000...9999))"
    let created = try await repos.projects.create(ProjectDraft(code: code, name: "Entegrasyon projesi", city: "Sivas"))
    XCTAssertEqual(created.version, 1)
    XCTAssertFalse(created.isDemo)

    var draft = ProjectDraft(created)
    draft.status = .devam
    draft.city = nil
    let updated = try await repos.projects.update(id: created.id, expectedVersion: 1, with: draft)
    XCTAssertEqual(updated.version, 2)
    XCTAssertNil(updated.city, "boşaltılan alan sunucuda da temizlenir")

    do {
      _ = try await repos.projects.update(id: created.id, expectedVersion: 1, with: draft)
      XCTFail("eski sürümle güncelleme reddedilmeli")
    } catch let error as RepositoryError {
      guard case .conflict = error else { return XCTFail("beklenen conflict, gelen \(error)") }
    }

    do {
      _ = try await repos.projects.create(ProjectDraft(code: code, name: "Aynı kod"))
      XCTFail("aynı kod reddedilmeli")
    } catch let error as RepositoryError {
      guard case .conflict = error else { return XCTFail("beklenen conflict, gelen \(error)") }
    }
  }

  func testCariAccountCreateAndEdit() async throws {
    let repos = try await signedIn("muhasebe@example.test")
    let created = try await repos.cari.createAccount(CariAccountDraft(title: "Entegrasyon Tedarikçi", type: .tedarikci,
                                                                     taxNumber: "1234567890"))
    XCTAssertTrue(created.code.hasPrefix("C-"), "kod sunucuda üretilir")
    var draft = CariAccountDraft(created)
    draft.phone = "0000 000 00 00"
    let updated = try await repos.cari.updateAccount(id: created.id, expectedVersion: created.version, with: draft)
    XCTAssertEqual(updated.phone, "0000 000 00 00")
    XCTAssertEqual(updated.version, created.version + 1)
  }
}
