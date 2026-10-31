import Foundation
import RDCore
import RDSupabase
import XCTest

/// Taşeron, personel, ekip ve görevlendirme repository'lerinin yerel Supabase
/// (seed.sql demo verisi) üzerinde uçtan uca testi. Ayar yoksa atlanır.
final class WorkforceRepositoryTests: XCTestCase {
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

  func testSiteChiefSeesProjectWorkforceAndContacts() async throws {
    let repos = try await signedIn("sef@example.test")
    let sivas = try await sivas(repos)

    let today = try await repos.workforce.workforce(projectId: sivas.id, on: CalendarDate(year: 2026, month: 6, day: 1))
    XCTAssertEqual(Set(today.map(\.fullName)),
                   ["Deneme Şantiye Teknikeri", "Deneme Kalıp Ustası", "Deneme Kalıp Kalfası", "Deneme Demir Ustası"])
    XCTAssertEqual(today.first { $0.fullName == "Deneme Kalıp Ustası" }?.crewName, "Kalıp Ekibi")

    let people = try await repos.workforce.personnel()
    let usta = try XCTUnwrap(people.first { $0.fullName == "Deneme Kalıp Ustası" })
    XCTAssertEqual(usta.employmentType, .taseron)
    let contact = try await repos.workforce.contact(personnelId: usta.id)
    XCTAssertNotNil(contact?.phone, "şantiye şefi projesindeki personelin telefonunu görür")

    let subs = try await repos.workforce.subcontractors()
    XCTAssertTrue(subs.contains { $0.name == "Örnek Kaba İnşaat Taşeronu" })
    let candidates = try await repos.workforce.candidates(projectId: sivas.id)
    XCTAssertTrue(candidates.contains { $0.kind == .ekip && $0.name == "Elektrik Ekibi" })
  }

  func testSiteChiefCannotCreateCardsAndOverlapIsReportedInTurkish() async throws {
    let repos = try await signedIn("sef@example.test")
    let sivas = try await sivas(repos)
    do {
      _ = try await repos.workforce.createPersonnel(PersonnelDraft(fullName: "İzinsiz kayıt"))
      XCTFail("şantiye şefi personel kartı açamamalı")
    } catch let error as RepositoryError {
      guard case .forbidden = error else { return XCTFail("beklenen forbidden, gelen \(error)") }
    }

    let crews = try await repos.workforce.crews()
    let kalip = try XCTUnwrap(crews.first { $0.name == "Kalıp Ekibi" })
    do {
      _ = try await repos.workforce.assign(ProjectAssignment(projectId: sivas.id, target: .crew(kalip.id),
                                                            startDate: CalendarDate(year: 2026, month: 7, day: 1)))
      XCTFail("çakışan görevlendirme reddedilmeli")
    } catch let error as RepositoryError {
      XCTAssertEqual(error, .conflict("Bu projede aynı tarihlerde zaten görevlendirme var"))
    }
  }

  func testAssignAndEndKeepsHistory() async throws {
    let repos = try await signedIn("sef@example.test")
    let sivas = try await sivas(repos)
    let candidates = try await repos.workforce.candidates(projectId: sivas.id)
    let electrician = try XCTUnwrap(candidates.first { $0.name == "Deneme Elektrikçi" })
    // Uzak gelecekte rastgele bir gün: test tekrar çalıştırıldığında çakışmasın.
    let start = CalendarDate(year: 2040, month: 1, day: 1).adding(days: Int.random(in: 0..<3000))
    let assignment = try await repos.workforce.assign(ProjectAssignment(
      projectId: sivas.id, target: electrician.target, startDate: start, description: "Entegrasyon testi"))
    try await repos.workforce.endAssignment(id: assignment.id, on: start)
    let history = try await repos.workforce.assignments(projectId: sivas.id, personnelId: electrician.id, crewId: nil)
    XCTAssertEqual(history.first { $0.id == assignment.id }?.endDate, start, "bitirilen görevlendirme silinmez")
  }

  func testAccountantSeesPersonnelButNotContacts() async throws {
    let repos = try await signedIn("muhasebe@example.test")
    let people = try await repos.workforce.personnel()
    let usta = try XCTUnwrap(people.first { $0.fullName == "Deneme Kalıp Ustası" })
    let contact = try await repos.workforce.contact(personnelId: usta.id)
    XCTAssertNil(contact, "muhasebe personel iletişim bilgisini göremez")
  }

  func testCariCanBackOnlyOneSubcontractor() async throws {
    let repos = try await signedIn("yonetici@example.test")
    let found = try await repos.cari.listAccounts(type: nil, search: "DEMO-C01")
    let cari = try XCTUnwrap(found.first)
    var draft = SubcontractorDraft(name: "Aynı firma ikinci kayıt", cariAccountId: cari.id)
    draft.isActive = true
    do {
      _ = try await repos.workforce.createSubcontractor(draft)
      XCTFail("aynı cari ikinci taşerona bağlanamamalı")
    } catch let error as RepositoryError {
      XCTAssertEqual(error, .conflict("Bu cari hesap zaten \"Örnek Kaba İnşaat Taşeronu\" taşeronuna bağlı"))
    }
  }
}
