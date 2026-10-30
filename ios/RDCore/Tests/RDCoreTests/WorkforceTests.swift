import Foundation
import XCTest
@testable import RDCore

private func day(_ month: Int, _ day: Int) -> CalendarDate { CalendarDate(year: 2026, month: month, day: day) }

private func grants(_ keys: [PermissionKey], project: UUID? = nil) -> [PermissionGrant] {
  keys.map { PermissionGrant(projectId: project, permissionKey: $0.rawValue) }
}

final class WorkforceRuleTests: XCTestCase {
  func testPeriodOverlapIncludesBothEndsAndOpenEnd() {
    let jan = DatePeriod(start: day(1, 1), end: day(1, 31))
    XCTAssertTrue(jan.overlaps(DatePeriod(start: day(1, 31), end: day(2, 10))), "bitiş günü dahil")
    XCTAssertFalse(jan.overlaps(DatePeriod(start: day(2, 1))))
    XCTAssertTrue(DatePeriod(start: day(3, 1)).overlaps(DatePeriod(start: day(9, 1))), "bitişsiz dönemler çakışır")
    XCTAssertTrue(DatePeriod(start: day(3, 1)).overlaps(DatePeriod(start: day(1, 1), end: day(3, 1))))
    XCTAssertFalse(DatePeriod(start: day(5, 1), end: day(4, 1)).isValid)
    XCTAssertTrue(jan.contains(day(1, 31)))
    XCTAssertFalse(jan.isOngoing(today: day(2, 1)))
    XCTAssertTrue(jan.isOngoing(today: day(1, 31)), "bitiş günü hâlâ devam ediyor sayılır")
  }

  func testSubcontractorWorkerJoinsOnlyOwnSubcontractorsCrew() {
    let sub = UUID()
    let worker = Personnel(fullName: "Deneme İşçi", employmentType: .taseron, subcontractorId: sub)
    let company = Personnel(fullName: "Deneme Usta")
    XCTAssertTrue(WorkforceRules.canJoin(worker, Crew(name: "Kalıp", subcontractorId: sub)))
    XCTAssertFalse(WorkforceRules.canJoin(worker, Crew(name: "Şirket kalıp")))
    XCTAssertFalse(WorkforceRules.canJoin(company, Crew(name: "Kalıp", subcontractorId: sub)))
    XCTAssertTrue(WorkforceRules.canJoin(company, Crew(name: "Şirket kalıp")))
  }

  func testPersonCanBeInOnlyOneCrewAtATime() {
    let person = Personnel(fullName: "Deneme Usta")
    let crewA = Crew(name: "A ekibi")
    let crewB = Crew(name: "B ekibi")
    let existing = [CrewMembership(crewId: crewA.id, personnelId: person.id, startDate: day(1, 1), endDate: day(3, 31))]
    let names = [crewA.id: crewA.name]
    let clash = WorkforceRules.membershipProblem(person: person, crew: crewB, period: DatePeriod(start: day(3, 15)),
                                                 existing: existing, crewName: { names[$0] })
    XCTAssertEqual(clash, "Kişi bu tarihlerde \"A ekibi\" ekibinde; aynı anda yalnızca bir ekipte olabilir.")
    XCTAssertNil(WorkforceRules.membershipProblem(person: person, crew: crewB, period: DatePeriod(start: day(4, 1)),
                                                  existing: existing, crewName: { names[$0] }))
  }

  func testSameProjectOverlapRejectedButOtherProjectAllowed() {
    let person = UUID()
    let projectA = UUID()
    let projectB = UUID()
    let existing = [ProjectAssignment(projectId: projectA, target: .personnel(person), startDate: day(1, 1))]
    XCTAssertNotNil(WorkforceRules.assignmentProblem(projectId: projectA, target: .personnel(person),
                                                     period: DatePeriod(start: day(6, 1)), existing: existing))
    XCTAssertNil(WorkforceRules.assignmentProblem(projectId: projectB, target: .personnel(person),
                                                  period: DatePeriod(start: day(6, 1)), existing: existing),
                 "aynı kişi farklı projelerde aynı anda çalışabilir")
  }

  func testEmploymentNeedsSubcontractorOnlyForSubcontractorWorkers() {
    XCTAssertNotNil(WorkforceRules.employmentProblem(type: .taseron, subcontractorId: nil))
    XCTAssertNotNil(WorkforceRules.employmentProblem(type: .sirket, subcontractorId: UUID()))
    XCTAssertNil(WorkforceRules.employmentProblem(type: .sirket, subcontractorId: nil))
    XCTAssertNil(WorkforceRules.employmentProblem(type: .taseron, subcontractorId: UUID()))
  }

  func testPhoneFormat() {
    XCTAssertTrue(isValidPhone("0000 000 00 21"))
    XCTAssertTrue(isValidPhone("+90 (555) 000-0000"))
    XCTAssertFalse(isValidPhone("12ab"))
  }
}

final class WorkforceCodingTests: XCTestCase {
  func testAssignmentDecodesFromDatabaseRow() throws {
    let json = """
      {"id":"00000000-0000-4000-8000-000000000001","project_id":"00000000-0000-4000-8000-000000000002",
       "personnel_id":null,"crew_id":"00000000-0000-4000-8000-000000000003",
       "start_date":"2026-03-01","end_date":null,"description":"Temel kalıbı"}
      """
    let assignment = try JSONDecoder().decode(ProjectAssignment.self, from: Data(json.utf8))
    XCTAssertEqual(assignment.target, .crew(UUID(uuidString: "00000000-0000-4000-8000-000000000003")!))
    XCTAssertEqual(assignment.startDate, day(3, 1))
    XCTAssertNil(assignment.endDate)
  }

  func testDraftsSendClearedFieldsAndNoContactOrIdentityNumbers() throws {
    let data = try JSONEncoder().encode(PersonnelDraft(fullName: "Deneme Usta"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertTrue(object["job_title"] is NSNull, "silinen alan sunucuda da silinir")
    XCTAssertNil(object["phone"], "telefon personel kartına yazılmaz (ayrı izinli kayıt)")
    XCTAssertNil(object["tc_kimlik"])
    let sub = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SubcontractorDraft(name: "Deneme"))) as? [String: Any]
    XCTAssertTrue(sub?["cari_account_id"] is NSNull)
    XCTAssertNil(sub?["tax_number"], "taşeron kartı vergi numarası taşımaz")
  }

  func testWorkforceRowDecodes() throws {
    let json = """
      [{"personnel_id":"00000000-0000-4000-8000-000000000001","full_name":"Deneme Usta","job_title":null,
        "via":"ekip","crew_id":"00000000-0000-4000-8000-000000000002","crew_name":"Kalıp Ekibi",
        "assignment_id":"00000000-0000-4000-8000-000000000003","membership_id":"00000000-0000-4000-8000-000000000004"}]
      """
    let rows = try JSONDecoder().decode([WorkforceEntry].self, from: Data(json.utf8))
    XCTAssertEqual(rows.first?.via, .ekip)
    XCTAssertEqual(rows.first?.crewName, "Kalıp Ekibi")
  }
}

final class WorkforceModuleTests: XCTestCase {
  func testWorkforceModulesFollowPermissions() {
    let project = UUID()
    let chief = AccessControl(grants: grants([.projeRead, .taseronRead, .personelRead, .gorevlendirmeRead],
                                             project: project))
    XCTAssertTrue(AppModule.taseronlar.isVisible(for: chief))
    XCTAssertTrue(AppModule.personel.isVisible(for: chief))
    XCTAssertTrue(AppModule.ekipler.isVisible(for: chief))
    let tasksOnly = AccessControl(grants: grants([.projeRead, .isRead], project: project))
    XCTAssertFalse(AppModule.taseronlar.isVisible(for: tasksOnly))
    XCTAssertFalse(AppModule.personel.isVisible(for: tasksOnly))
  }
}

// MARK: - ViewModel'ler (bellek içi sunucu ile)

@MainActor
final class WorkforceViewModelTests: XCTestCase {
  private let projectA = Project(code: "TEST-A", name: "A projesi", status: .devam)
  private let projectB = Project(code: "TEST-B", name: "B projesi", status: .devam)
  private let sub = Subcontractor(name: "Deneme Kalıp Taşeronu", trade: .kalip)

  private func backend(grants: [PermissionGrant]? = nil) async -> InMemoryBackend {
    let backend = InMemoryBackend()
    if let grants { await backend.set(grants: grants) }
    await backend.seed(projects: [projectA, projectB])
    await backend.seedWorkforce(subcontractors: [sub])
    return backend
  }

  func testPersonnelFormRequiresOnlyNameAndSubcontractorForSubcontractorWorker() async {
    let backend = await backend()
    let form = PersonnelFormViewModel(repository: backend.repositories.workforce)
    XCTAssertEqual(form.validationMessage, "Ad soyad zorunlu.")
    form.fullName = "Deneme Kalfa"
    XCTAssertNil(form.validationMessage, "telefon, görev ve iş kolu isteğe bağlı")
    form.employmentType = .taseron
    XCTAssertEqual(form.validationMessage, "Taşeron personeli için taşeron seçin.")
    form.subcontractorId = sub.id
    XCTAssertNil(form.validationMessage)
    form.employmentType = .sirket
    XCTAssertNil(form.draft.subcontractorId, "şirket personeline taşeron gönderilmez")
  }

  func testPhoneIsSavedSeparatelyAndHiddenWithoutContactPermission() async throws {
    let backend = await backend()
    let form = PersonnelFormViewModel(repository: backend.repositories.workforce)
    form.fullName = "Deneme Usta"
    form.phone = "0000 000 00 31"
    let result = await form.save()
    let saved = try XCTUnwrap(result)
    let contact = try await backend.repositories.workforce.contact(personnelId: saved.id)
    XCTAssertEqual(contact?.phone, "0000 000 00 31")

    await backend.set(grants: grants([.personelRead]))
    let detail = PersonnelDetailViewModel(person: saved, access: AccessControl(grants: await backend.grants),
                                          repository: backend.repositories.workforce)
    await detail.load()
    XCTAssertFalse(detail.canSeeContact)
    XCTAssertNil(detail.phone, "iletişim izni olmayan telefonu göremez")
  }

  func testCrewMembershipRulesAndHistory() async throws {
    let backend = await backend()
    let repo = backend.repositories.workforce
    let worker = try await repo.createPersonnel(PersonnelDraft(fullName: "Deneme İşçi", employmentType: .taseron,
                                                               subcontractorId: sub.id))
    let companyPerson = try await repo.createPersonnel(PersonnelDraft(fullName: "Deneme Tekniker"))
    let kalip = try await repo.createCrew(CrewDraft(name: "Kalıp Ekibi", subcontractorId: sub.id))
    let demir = try await repo.createCrew(CrewDraft(name: "Demir Ekibi", subcontractorId: sub.id))
    let access = AccessControl(grants: await backend.grants)

    let kalipVM = CrewDetailViewModel(crew: kalip, access: access, repository: repo)
    await kalipVM.load()
    XCTAssertEqual(kalipVM.eligiblePeople.map(\.fullName), ["Deneme İşçi"], "şirket personeli taşeron ekibine önerilmez")
    let joined = await kalipVM.addMember(worker.id, start: day(1, 1), roleTitle: "İşçi")
    XCTAssertTrue(joined)
    let companyJoined = await kalipVM.addMember(companyPerson.id, start: day(1, 1), roleTitle: "")
    XCTAssertFalse(companyJoined)

    let demirVM = CrewDetailViewModel(crew: demir, access: access, repository: repo)
    await demirVM.load()
    let clash = await demirVM.addMember(worker.id, start: day(3, 1), roleTitle: "")
    XCTAssertFalse(clash)
    XCTAssertEqual(demirVM.errorMessage, "Kişi bu tarihlerde başka bir ekipte; aynı anda yalnızca bir ekipte olabilir.")

    let first = try XCTUnwrap(kalipVM.memberships.first)
    await kalipVM.end(first, on: day(2, 28))
    let moved = await demirVM.addMember(worker.id, start: day(3, 1), roleTitle: "")
    XCTAssertTrue(moved)
    let history = try await repo.memberships(crewId: nil, personnelId: worker.id)
    XCTAssertEqual(history.count, 2, "eski üyelik silinmez")
    XCTAssertEqual(history.first { $0.crewId == kalip.id }?.endDate, day(2, 28))
  }

  func testSiteChiefAssignsOnlyInOwnProjectAndSeesWorkforce() async throws {
    let backend = await backend()
    let repo = backend.repositories.workforce
    let worker = try await repo.createPersonnel(PersonnelDraft(fullName: "Deneme İşçi", employmentType: .taseron,
                                                               subcontractorId: sub.id))
    let other = try await repo.createPersonnel(PersonnelDraft(fullName: "Deneme B Elektrikçisi"))
    let crew = try await repo.createCrew(CrewDraft(name: "Kalıp Ekibi", subcontractorId: sub.id))
    _ = try await repo.addMembership(CrewMembership(crewId: crew.id, personnelId: worker.id, startDate: day(1, 1)))
    _ = try await repo.assign(ProjectAssignment(projectId: projectB.id, target: .personnel(other.id), startDate: day(1, 1)))

    let chief = grants([.projeRead, .personelRead, .gorevlendirmeRead, .gorevlendirmeWrite], project: projectA.id)
    await backend.set(grants: chief)
    let vm = ProjectWorkforceViewModel(project: projectA, access: AccessControl(grants: chief), repository: repo)
    await vm.load()
    XCTAssertTrue(vm.canAssign)
    await vm.loadCandidates()
    let crewCandidate = try XCTUnwrap(vm.candidates.first { $0.id == crew.id })
    let assigned = await vm.assign(crewCandidate, start: day(1, 1))
    XCTAssertTrue(assigned)
    XCTAssertEqual(vm.today.map(\.fullName), ["Deneme İşçi"], "ekip üzerinden bugün sahada")
    XCTAssertEqual(vm.today.first?.via, .ekip)
    let again = await vm.assign(crewCandidate, start: day(6, 1))
    XCTAssertFalse(again)
    XCTAssertEqual(vm.errorMessage, "Bu projede aynı tarihlerde zaten görevlendirme var.")

    let visible = try await repo.personnel().map(\.fullName)
    XCTAssertEqual(visible, ["Deneme İşçi"], "B projesindeki personel görünmez")
    let bAssignments = try await repo.assignments(projectId: projectB.id, personnelId: nil, crewId: nil)
    XCTAssertTrue(bAssignments.isEmpty)
    let bVM = ProjectWorkforceViewModel(project: projectB, access: AccessControl(grants: chief), repository: repo)
    XCTAssertFalse(bVM.canSee)
    XCTAssertFalse(bVM.canAssign)
  }

  func testSubcontractorFormOffersOnlyFreeNonCustomerCari() async throws {
    let free = CariAccount(code: "C-1", title: "Serbest taşeron", type: .taseron)
    let customer = CariAccount(code: "C-2", title: "Daire alıcısı", type: .musteri)
    let taken = CariAccount(code: "C-3", title: "Bağlı taşeron", type: .taseron)
    let backend = InMemoryBackend()
    await backend.seed(accounts: [free, customer, taken])
    await backend.seedWorkforce(subcontractors: [Subcontractor(name: "Mevcut", cariAccountId: taken.id)])
    let access = AccessControl(grants: await backend.grants)
    let form = SubcontractorFormViewModel(access: access, repositories: backend.repositories)
    await form.loadOptions()
    XCTAssertEqual(form.cariOptions.map(\.title), ["Serbest taşeron"])

    form.name = "İkinci kayıt"
    form.cariAccountId = taken.id
    let saved = await form.save()
    XCTAssertNil(saved)
    XCTAssertEqual(form.errorMessage, "Bu cari hesap zaten \"Mevcut\" taşeronuna bağlı")
  }

  func testCardsNeedGlobalWritePermission() async {
    let project = UUID()
    let chief = AccessControl(grants: grants([.personelRead, .taseronRead, .gorevlendirmeWrite], project: project))
    let backend = InMemoryBackend()
    XCTAssertFalse(PersonnelListViewModel(access: chief, repository: backend.repositories.workforce).canCreate)
    XCTAssertFalse(SubcontractorListViewModel(access: chief, repository: backend.repositories.workforce).canCreate)
    XCTAssertFalse(CrewListViewModel(access: chief, repository: backend.repositories.workforce).canCreate)
  }
}
