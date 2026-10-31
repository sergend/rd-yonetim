import Foundation

/// Önizleme ve demo için örnek veri. Tamamen hayalidir; gerçek kayıt içermez.
public enum PreviewData {
  public static let sivas = Project(code: "DEMO-SVS", name: "Sivas 30 Daire Projesi", city: "Sivas",
                                    startDate: CalendarDate(year: 2026, month: 3, day: 1), status: .devam,
                                    notes: "Örnek proje: 2 blok, 30 daire.", isDemo: true)
  public static let office = CostCenter(code: "GENEL-OFIS", name: "Merkez ofis", isDemo: true)
  public static let taseron = CariAccount(code: "DEMO-C01", title: "Örnek Kaba İnşaat Taşeronu", type: .taseron,
                                          taxNumber: "1111111111", isDemo: true)
  public static let tedarikci = CariAccount(code: "DEMO-C02", title: "Örnek Hazır Beton Tedarikçisi",
                                            type: .tedarikci, isDemo: true)

  // Taşeron, personel ve ekip (Aşama 2). Adlar hayalidir.
  public static let kabaTaseron = Subcontractor(name: "Örnek Kaba İnşaat Taşeronu", trade: .kalip,
                                                cariAccountId: taseron.id, contactName: "Deneme Ekip Başı",
                                                phone: "0000 000 00 11", isDemo: true)
  public static let kalipUstasi = Personnel(fullName: "Deneme Kalıp Ustası", jobTitle: "Kalıp ustası", trade: .kalip,
                                            employmentType: .taseron, subcontractorId: kabaTaseron.id, isDemo: true)
  public static let kalipKalfasi = Personnel(fullName: "Deneme Kalıp Kalfası", jobTitle: "Kalfa", trade: .kalip,
                                             employmentType: .taseron, subcontractorId: kabaTaseron.id, isDemo: true)
  public static let tekniker = Personnel(fullName: "Deneme Şantiye Teknikeri", jobTitle: "Tekniker", trade: .genel,
                                         isDemo: true)
  public static let kalipEkibi = Crew(name: "Kalıp Ekibi", subcontractorId: kabaTaseron.id, trade: .kalip,
                                      leaderId: kalipUstasi.id, isDemo: true)

  /// Önizlemeler için dolu, oturum açık bir bellek içi sunucu.
  public static func backend() async -> InMemoryBackend {
    let backend = InMemoryBackend()
    await backend.seed(projects: [sivas], costCenters: [office], accounts: [taseron, tedarikci],
                       tasks: [TaskItem(projectId: sivas.id, title: "B Blok 3. kat döşeme betonu",
                                        dueDate: .today().adding(days: 2), priority: .yuksek)])
    let start = CalendarDate(year: 2026, month: 3, day: 1)
    await backend.seedWorkforce(
      subcontractors: [kabaTaseron], personnel: [kalipUstasi, kalipKalfasi, tekniker],
      contacts: [kalipUstasi.id: "0000 000 00 21", tekniker.id: "0000 000 00 22"], crews: [kalipEkibi],
      memberships: [CrewMembership(crewId: kalipEkibi.id, personnelId: kalipUstasi.id, startDate: start, roleTitle: "Usta"),
                    CrewMembership(crewId: kalipEkibi.id, personnelId: kalipKalfasi.id, startDate: start, roleTitle: "Kalfa")],
      assignments: [ProjectAssignment(projectId: sivas.id, target: .crew(kalipEkibi.id), startDate: start,
                                      description: "Temel ve bodrum kalıbı"),
                    ProjectAssignment(projectId: sivas.id, target: .personnel(tekniker.id), startDate: start)],
      subcontractorProjects: [SubcontractorProject(subcontractorId: kabaTaseron.id, projectId: sivas.id, startDate: start,
                                                   scope: "Kaba inşaat (örnek)")],
      documents: [SubcontractorDocument(subcontractorId: kabaTaseron.id, title: "Vergi levhası (örnek)",
                                        validUntil: CalendarDate(year: 2026, month: 12, day: 31))])
    let profile = await backend.profile
    await backend.set(session: AuthSession(userId: profile.id, email: profile.email))
    await seedPuantaj(backend)
    try? await backend.post(CariEntryDraft(cariAccountId: taseron.id, scope: .project(sivas.id),
                                           entryDate: CalendarDate(year: 2026, month: 9, day: 30), direction: .alacak,
                                           kind: .manuel, amount: 450_000, description: "1 nolu hakediş (örnek)"))
    try? await backend.post(CariEntryDraft(cariAccountId: taseron.id, scope: .project(sivas.id),
                                           entryDate: CalendarDate(year: 2026, month: 10, day: 10), direction: .borc,
                                           kind: .odeme, amount: 200_000, description: "Kısmi ödeme (örnek)"))
    return backend
  }

  /// Bu ayın dünkü güne kadarki iş günleri (Pazar boş). Örnek: rapor, yarım
  /// gün ve fazla mesai; bir gün bilerek boş (henüz işlenmedi).
  static func seedPuantaj(_ backend: InMemoryBackend) async {
    let today = CalendarDate.today()
    let month = PuantajMonth(containing: today)
    var items: [PuantajCellInput] = []
    for day in month.days where day < today && day.isoWeekday != 7 && day.day != 3 {
      items.append(PuantajCellInput(personnelId: tekniker.id, workDate: day, status: .tamGun))
      items.append(PuantajCellInput(personnelId: kalipUstasi.id, workDate: day, status: .tamGun,
                                    overtimeHours: day.day == 9 ? 2 : 0, overtimeNote: day.day == 9 ? "Döşeme betonu" : nil))
      let kalfa: PuantajStatus = day.day == 6 || day.day == 7 ? .raporlu : day.day == 13 ? .yarimGun : .tamGun
      items.append(PuantajCellInput(personnelId: kalipKalfasi.id, workDate: day, status: kalfa))
    }
    guard !items.isEmpty else { return }
    _ = try? await backend.savePuantaj(projectId: sivas.id, items: items, overwrite: false)
  }
}
