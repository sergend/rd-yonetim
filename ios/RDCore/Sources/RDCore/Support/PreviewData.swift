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

  /// Önizlemeler için dolu, oturum açık bir bellek içi sunucu.
  public static func backend() async -> InMemoryBackend {
    let backend = InMemoryBackend()
    await backend.seed(projects: [sivas], costCenters: [office], accounts: [taseron, tedarikci],
                       tasks: [TaskItem(projectId: sivas.id, title: "B Blok 3. kat döşeme betonu",
                                        dueDate: .today().adding(days: 2), priority: .yuksek)])
    let profile = await backend.profile
    await backend.set(session: AuthSession(userId: profile.id, email: profile.email))
    try? await backend.post(CariEntryDraft(cariAccountId: taseron.id, scope: .project(sivas.id),
                                           entryDate: CalendarDate(year: 2026, month: 9, day: 30), direction: .alacak,
                                           kind: .manuel, amount: 450_000, description: "1 nolu hakediş (örnek)"))
    try? await backend.post(CariEntryDraft(cariAccountId: taseron.id, scope: .project(sivas.id),
                                           entryDate: CalendarDate(year: 2026, month: 10, day: 10), direction: .borc,
                                           kind: .odeme, amount: 200_000, description: "Kısmi ödeme (örnek)"))
    return backend
  }
}
