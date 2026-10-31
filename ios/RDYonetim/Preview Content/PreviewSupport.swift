import RDCore
import RDDesign
import SwiftUI

#if DEBUG
  /// Önizlemeler bellek içi örnek veriyle (PreviewData, tamamı DEMO) çalışır;
  /// sunucuya bağlanmaz.
  @MainActor
  enum PreviewSupport {
    static func app(grants: [PermissionGrant]? = nil, contracts: Bool = false) async -> AppModel {
      let backend = contracts ? await PreviewData.contractsBackend() : await PreviewData.backend()
      if let grants { await backend.set(grants: grants) }
      let app = AppModel(repositories: backend.repositories)
      await app.session.start()
      await app.reloadLookups()
      return app
    }

    /// Sivas projesinde şantiye şefi: finans görmez; projesinin ekip ve personelini
    /// görür, puantaj girer ama onaylayamaz.
    static let siteChiefGrants = ["proje.read", "proje.write", "is.read", "is.write", "taseron.read", "personel.read",
                                  "personel_iletisim.read", "gorevlendirme.read", "gorevlendirme.write",
                                  "puantaj.read", "puantaj.write"].map {
      PermissionGrant(projectId: PreviewData.sivas.id, permissionKey: $0)
    }
  }

  struct PreviewHost<Content: View>: View {
    var grants: [PermissionGrant]?
    var contracts = false
    @ViewBuilder let content: (AppModel) -> Content
    @State private var app: AppModel?

    var body: some View {
      Group {
        if let app { content(app).environment(app) } else { ProgressView() }
      }
      .tint(RDColor.brandText)
      .task { app = await PreviewSupport.app(grants: grants, contracts: contracts) }
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

  /// Sivas puantajı yüklenmiş view model ile içerik (sayfa ve özet önizlemeleri).
  struct PuantajPreviewHost<Content: View>: View {
    var grants: [PermissionGrant]?
    @ViewBuilder let content: (PuantajViewModel) -> Content
    @State private var model: PuantajViewModel?

    var body: some View {
      Group {
        if let model { content(model) } else { ProgressView() }
      }
      .tint(RDColor.brandText)
      .task {
        let app = await PreviewSupport.app(grants: grants)
        let model = PuantajViewModel(project: PreviewData.sivas, access: app.access, repository: app.repositories.puantaj)
        await model.load()
        self.model = model
      }
    }
  }

  #Preview("Puantaj · ay tablosu") {
    PreviewHost { app in NavigationStack { PuantajView(project: PreviewData.sivas, app: app) } }
  }

  #Preview("Puantaj · ay tablosu · koyu") {
    PreviewHost { app in NavigationStack { PuantajView(project: PreviewData.sivas, app: app) } }
      .preferredColorScheme(.dark)
  }

  #Preview("Puantaj · şantiye şefi · büyük yazı") {
    PreviewHost(grants: PreviewSupport.siteChiefGrants) { app in
      NavigationStack { PuantajView(project: PreviewData.sivas, app: app) }
    }
    .dynamicTypeSize(.accessibility2)
  }

  #Preview("Puantaj · hücre") {
    PuantajPreviewHost { model in
      PuantajCellSheet(model: model, selection: PuantajCellSelection(
        personnelId: PreviewData.kalipUstasi.id, day: CalendarDate.today().adding(days: -1)))
    }
  }

  #Preview("Puantaj · toplu işlem") {
    PuantajPreviewHost { model in PuantajBulkSheet(model: model, day: .today()) }
  }

  #Preview("Puantaj · aylık özet") {
    PuantajPreviewHost { model in PuantajSummaryView(model: model) }
  }

  #Preview("Puantaj · ay durumu · koyu") {
    PuantajPreviewHost { model in PuantajPeriodSheet(model: model) }
      .preferredColorScheme(.dark)
  }

  // MARK: Sözleşme ve hakediş (Aşama 4)

  /// Örnek sözleşmenin ilk hakedişiyle detay ekranı.
  struct HakedisPreviewHost: View {
    @State private var app: AppModel?
    @State private var hakedis: Hakedis?

    var body: some View {
      Group {
        if let app, let hakedis {
          NavigationStack { HakedisDetailView(hakedis: hakedis, contract: PreviewData.sozlesme, app: app) }
            .environment(app)
        } else {
          ProgressView()
        }
      }
      .tint(RDColor.brandText)
      .task {
        let app = await PreviewSupport.app(contracts: true)
        hakedis = try? await app.repositories.contracts.hakedisList(contractId: PreviewData.sozlesme.id).first
        self.app = app
      }
    }
  }

  #Preview("Sözleşmeler") {
    PreviewHost(contracts: true) { app in NavigationStack { ContractListView(projectId: nil, app: app) } }
  }

  #Preview("Sözleşme detayı") {
    PreviewHost(contracts: true) { app in NavigationStack { ContractDetailView(contract: PreviewData.sozlesme, app: app) } }
  }

  #Preview("Sözleşme detayı · koyu") {
    PreviewHost(contracts: true) { app in NavigationStack { ContractDetailView(contract: PreviewData.sozlesme, app: app) } }
      .preferredColorScheme(.dark)
  }

  #Preview("Yeni sözleşme") {
    PreviewHost(contracts: true) { app in ContractFormLoader(app: app, projectId: PreviewData.sivas.id) { _ in } }
  }

  #Preview("Hakediş detayı") { HakedisPreviewHost() }

  #Preview("Hakediş detayı · büyük yazı") { HakedisPreviewHost().dynamicTypeSize(.accessibility2) }

  #Preview("Hakediş detayı · koyu") { HakedisPreviewHost().preferredColorScheme(.dark) }

  #Preview("Hakedişler") {
    PreviewHost(contracts: true) { app in NavigationStack { HakedisListView(app: app) } }
  }

  #Preview("İmalat · şantiye şefi") {
    PreviewHost(grants: PreviewSupport.siteChiefGrants + ["imalat.read", "imalat.write"].map {
      PermissionGrant(projectId: PreviewData.sivas.id, permissionKey: $0)
    }, contracts: true) { app in
      NavigationStack { ImalatView(project: PreviewData.sivas, app: app) }
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
