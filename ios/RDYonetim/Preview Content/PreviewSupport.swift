import RDCore
import RDDesign
import SwiftUI

#if DEBUG
  /// Önizlemeler bellek içi örnek veriyle (PreviewData, tamamı DEMO) çalışır;
  /// sunucuya bağlanmaz.
  @MainActor
  enum PreviewSupport {
    static func app(grants: [PermissionGrant]? = nil) async -> AppModel {
      let backend = await PreviewData.backend()
      if let grants { await backend.set(grants: grants) }
      let app = AppModel(repositories: backend.repositories)
      await app.session.start()
      await app.reloadLookups()
      return app
    }

    /// Sivas projesinde şantiye şefi: finans görmez; projesinin ekip ve personelini görür.
    static let siteChiefGrants = ["proje.read", "proje.write", "is.read", "is.write", "taseron.read", "personel.read",
                                  "personel_iletisim.read", "gorevlendirme.read", "gorevlendirme.write"].map {
      PermissionGrant(projectId: PreviewData.sivas.id, permissionKey: $0)
    }
  }

  struct PreviewHost<Content: View>: View {
    var grants: [PermissionGrant]?
    @ViewBuilder let content: (AppModel) -> Content
    @State private var app: AppModel?

    var body: some View {
      Group {
        if let app { content(app).environment(app) } else { ProgressView() }
      }
      .tint(RDColor.brandText)
      .task { app = await PreviewSupport.app(grants: grants) }
    }
  }

  #Preview("Giriş") {
    LoginView(session: SessionViewModel(repositories: InMemoryBackend().repositories))
      .tint(RDColor.brandText)
  }

  #Preview("Giriş · koyu") {
    LoginView(session: SessionViewModel(repositories: InMemoryBackend().repositories))
      .tint(RDColor.brandText)
      .preferredColorScheme(.dark)
  }

  #Preview("Ana sayfa") {
    PreviewHost { _ in AppRootView() }
  }

  #Preview("Ana sayfa · koyu") {
    PreviewHost { _ in AppRootView() }.preferredColorScheme(.dark)
  }

  #Preview("Ana sayfa · büyük yazı") {
    PreviewHost { _ in AppRootView() }.dynamicTypeSize(.accessibility2)
  }

  #Preview("Ana sayfa · şantiye şefi") {
    PreviewHost(grants: PreviewSupport.siteChiefGrants) { _ in AppRootView() }
  }

  #Preview("Projeler") {
    PreviewHost { app in NavigationStack { ProjectListView(app: app) } }
  }

  #Preview("Proje detayı") {
    PreviewHost { app in NavigationStack { ProjectDetailView(project: PreviewData.sivas, app: app) } }
  }

  #Preview("Cari hesaplar") {
    PreviewHost { app in NavigationStack { CariListView(projectId: nil, app: app) } }
  }

  #Preview("Cari detay") {
    PreviewHost { app in NavigationStack { CariDetailView(account: PreviewData.taseron, app: app) } }
  }

  #Preview("Cari detay · koyu") {
    PreviewHost { app in NavigationStack { CariDetailView(account: PreviewData.taseron, app: app) } }
      .preferredColorScheme(.dark)
  }

  #Preview("İş takibi") {
    PreviewHost { app in NavigationStack { TaskListView(projectId: nil, app: app) } }
  }

  #Preview("Genel giderler") {
    PreviewHost { app in NavigationStack { GeneralExpensesView(app: app) } }
  }

  #Preview("Taşeronlar") {
    PreviewHost { app in NavigationStack { SubcontractorListView(app: app) } }
  }

  #Preview("Taşeron detayı") {
    PreviewHost { app in NavigationStack { SubcontractorDetailView(subcontractor: PreviewData.kabaTaseron, app: app) } }
  }

  #Preview("Taşeron detayı · koyu") {
    PreviewHost { app in NavigationStack { SubcontractorDetailView(subcontractor: PreviewData.kabaTaseron, app: app) } }
      .preferredColorScheme(.dark)
  }

  #Preview("Personel") {
    PreviewHost { app in NavigationStack { PersonnelListView(app: app) } }
  }

  #Preview("Personel detayı · büyük yazı") {
    PreviewHost { app in NavigationStack { PersonnelDetailView(person: PreviewData.kalipUstasi, app: app) } }
      .dynamicTypeSize(.accessibility2)
  }

  #Preview("Ekipler") {
    PreviewHost { app in NavigationStack { CrewListView(app: app) } }
  }

  #Preview("Ekip detayı · koyu") {
    PreviewHost { app in NavigationStack { CrewDetailView(crew: PreviewData.kalipEkibi, app: app) } }
      .preferredColorScheme(.dark)
  }

  #Preview("Proje ekip ve personel · şantiye şefi") {
    PreviewHost(grants: PreviewSupport.siteChiefGrants) { app in
      NavigationStack { ProjectWorkforceView(project: PreviewData.sivas, app: app) }
    }
  }

  #Preview("Yeni personel") {
    PersonnelFormView(model: PersonnelFormViewModel(repository: InMemoryBackend().repositories.workforce),
                      showsPhone: true) { _ in }
      .tint(RDColor.brandText)
  }

  /// Tasarım sistemi bileşenleri tek ekranda (açık ve koyu temada kontrol için).
  struct DesignSystemGallery: View {
    @State private var text = ""

    var body: some View {
      List {
        Section("Butonlar") {
          RDPrimaryButton(title: "Birincil eylem") {}
          RDPrimaryButton(title: "Yükleniyor", isLoading: true) {}
          Button("İkincil eylem") {}.buttonStyle(.rdSecondary)
          Button("Devre dışı") {}.buttonStyle(.rdPrimary).disabled(true)
        }
        Section("Alanlar") {
          RDTextField(label: "E-posta", text: $text, prompt: "ad.soyad@rdinsaat.com")
          RDTextField(label: "Şifre", text: $text, isSecure: true, error: "En az 10 karakter girin.")
        }
        Section("Etiketler") {
          HStack {
            ForEach(StatusTone.allCases, id: \.self) { RDStatusBadge(text: "\($0)", tone: $0) }
          }
          RDDemoBadge()
        }
        Section("Satırlar") {
          RDRow(symbol: "building.2", symbolTint: RDColor.brandText, title: "Sivas 30 Daire Projesi",
                subtitle: "DEMO-SVS · Sivas") {
            RDDemoBadge()
          } trailing: {
            RDStatusBadge(text: "Devam ediyor", tone: .success)
          }
          RDInfoRow(label: "Başlangıç", value: "1 Mar 2026")
          RDAmount(amount: -250_000, showsSide: true)
        }
        Section("Durumlar") {
          RDErrorBanner(message: "Sunucuya ulaşılamadı.")
          RDStateView(kind: .empty(title: "Kayıt yok", message: "Filtreye uyan kayıt bulunamadı.", symbol: "tray"))
            .frame(height: 220)
        }
      }
      .listStyle(.insetGrouped)
      .rdScreen()
      .tint(RDColor.brandText)
    }
  }

  #Preview("Tasarım sistemi") { DesignSystemGallery() }
  #Preview("Tasarım sistemi · koyu") { DesignSystemGallery().preferredColorScheme(.dark) }
#endif
