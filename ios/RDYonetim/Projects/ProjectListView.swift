import RDCore
import RDDesign
import SwiftUI

struct ProjectListView: View {
  let app: AppModel
  @State private var model: ProjectListViewModel
  @State private var showingForm = false

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: ProjectListViewModel(access: app.access, repository: app.repositories.projects))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.projects.isEmpty {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ForEach(model.filtered) { project in
          NavigationLink(value: AppRoute.project(project)) { ProjectRow(project: project) }
        }
      } footer: {
        Toggle("Tamamlananları göster", isOn: $model.includeCompleted)
          .font(RDFont.secondary)
          .padding(.top, .rdS)
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .onChange(of: model.includeCompleted) { _, _ in Task { await model.load() } }
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Proje yok", message: "Görüntüleme yetkiniz olan proje bulunamadı.",
                                  symbol: "building.2"),
                    retry: { Task { await model.load() } })
    .searchable(text: $model.searchText, prompt: "Proje adı, kodu veya şehir")
    .navigationTitle("Projeler")
    .toolbar {
      if model.canCreate {
        Button("Yeni proje", systemImage: "plus") { showingForm = true }
      }
    }
    .sheet(isPresented: $showingForm) {
      ProjectFormView(model: ProjectFormViewModel(repository: app.repositories.projects)) { saved in
        model.upsert(saved)
        Task { await app.session.refreshAccess() }
      }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
  }
}

struct ProjectDetailView: View {
  let app: AppModel
  @State private var model: ProjectDetailViewModel
  @State private var editing = false

  init(project: Project, app: AppModel) {
    self.app = app
    _model = State(initialValue: ProjectDetailViewModel(project: project, access: app.access, repositories: app.repositories))
  }

  var body: some View {
    let project = model.project
    List {
      if let error = model.errorMessage {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        VStack(alignment: .leading, spacing: .rdS) {
          HStack(spacing: .rdS) {
            RDStatusBadge(text: project.status.title, tone: project.status.tone)
            if project.isDemo { RDDemoBadge() }
          }
          Text(project.name)
            .font(RDFont.sectionTitle)
            .foregroundStyle(RDColor.textPrimary)
          Text([project.code, project.city].compactMap { $0 }.joined(separator: " · "))
            .font(RDFont.secondary)
            .foregroundStyle(RDColor.textSecondary)
        }
        .padding(.vertical, .rdXS)
        if project.isDemo {
          Label("Demo proje: kayıtları gerçek verilere karışmaz.", systemImage: "info.circle")
            .font(RDFont.caption)
            .foregroundStyle(RDColor.tone(.warning))
        }
      }
      .rdRowBackground()

      Section("Bilgiler") {
        if let address = project.address { RDInfoRow(label: "Adres", value: address) }
        RDInfoRow(label: "Başlangıç", value: project.startDate?.display ?? "Belirtilmedi")
        RDInfoRow(label: "Bitiş", value: project.endDate?.display ?? "Belirtilmedi")
        if let notes = project.notes { RDInfoRow(label: "Not", value: notes) }
      }
      .rdRowBackground()

      if model.canSeeTasks {
        Section {
          if model.tasks.isEmpty {
            Text("Açık iş yok.").foregroundStyle(RDColor.textSecondary)
          }
          ForEach(model.tasks.prefix(5)) { task in
            TaskRow(task: task, projectName: nil)
          }
          NavigationLink(value: AppRoute.tasks(projectId: project.id)) {
            Text("Projenin tüm işleri").foregroundStyle(RDColor.brandText)
          }
        } header: {
          Text("Açık işler (\(model.tasks.count))")
        }
        .rdRowBackground()
      }

      if app.access.can(.gorevlendirmeRead, in: project.id) || app.access.can(.puantajRead, in: project.id)
        || app.access.can(.imalatRead, in: project.id) {
        Section("Saha") {
          if app.access.can(.gorevlendirmeRead, in: project.id) {
            NavigationLink(value: AppRoute.projectWorkforce(project)) {
              RDRow(symbol: AppModule.ekipler.symbol, symbolTint: RDColor.brandText,
                    title: "Ekip ve personel", subtitle: "Bugün sahada olanlar, taşeronlar ve görevlendirmeler")
            }
          }
          if app.access.can(.puantajRead, in: project.id) {
            NavigationLink(value: AppRoute.puantaj(project)) {
              RDRow(symbol: AppModule.puantaj.symbol, symbolTint: RDColor.brandText,
                    title: "Puantaj", subtitle: "Aylık tablo, günlük giriş ve onay")
            }
          }
          if app.access.can(.imalatRead, in: project.id) {
            NavigationLink(value: AppRoute.imalat(project)) {
              RDRow(symbol: AppModule.imalat.symbol, symbolTint: RDColor.brandText,
                    title: "İmalat (metraj)", subtitle: "Birim fiyatlı kalemlere miktar girişi (fiyatsız)")
            }
          }
        }
        .rdRowBackground()
      }

      if app.access.can(.stokRead, in: project.id) || app.access.can(.satinalmaRead, in: project.id)
        || app.access.can(.satinalmaWrite, in: project.id) || app.access.can(.satinalmaReceive, in: project.id) {
        Section("Malzeme ve stok") {
          if app.access.can(.stokRead, in: project.id) {
            NavigationLink(value: AppRoute.stock(projectId: project.id)) {
              RDRow(symbol: AppModule.stoklar.symbol, symbolTint: RDColor.brandText,
                    title: "Proje deposu", subtitle: "Mevcut stok, giriş, kullanım, transfer ve sayım")
            }
          }
          if app.access.can(.satinalmaRead, in: project.id) || app.access.can(.satinalmaWrite, in: project.id)
            || app.access.can(.satinalmaReceive, in: project.id) {
            NavigationLink(value: AppRoute.purchaseOrders(projectId: project.id)) {
              RDRow(symbol: AppModule.satinAlma.symbol, symbolTint: RDColor.brandText,
                    title: "Satın alma siparişleri", subtitle: "Sipariş, onay ve parça parça teslim alma")
            }
          }
        }
        .rdRowBackground()
      }

      if app.access.can(.belgeRead, in: project.id) {
        Section("Belgeler") {
          NavigationLink(value: AppRoute.documents(link: .project(project.id), title: "\(project.code) belgeleri",
                                                   projectId: project.id)) {
            RDRow(symbol: AppModule.belgeler.symbol, symbolTint: RDColor.brandText,
                  title: "Proje belgeleri", subtitle: "İrsaliye, tutanak, ruhsat; tara veya dosya ekle")
          }
        }
        .rdRowBackground()
      }

      if model.canSeeCari || app.access.can(.sozlesmeRead, in: project.id)
        || app.access.can(.giderRead, in: project.id) || app.access.can(.giderWrite, in: project.id)
        || app.access.can(.gelirRead, in: project.id) {
        Section("Finans") {
          if app.access.can(.giderRead, in: project.id) || app.access.can(.giderWrite, in: project.id) {
            NavigationLink(value: AppRoute.financeList(.gider, projectId: project.id)) {
              RDRow(symbol: AppModule.giderler.symbol, symbolTint: RDColor.brandText,
                    title: "Proje giderleri", subtitle: "Gider girişi, onay ve ödeme durumu")
            }
          }
          if app.access.can(.gelirRead, in: project.id) {
            NavigationLink(value: AppRoute.financeList(.gelir, projectId: project.id)) {
              RDRow(symbol: AppModule.gelirler.symbol, symbolTint: RDColor.brandText,
                    title: "Proje gelirleri", subtitle: "Tahakkuk ve tahsilat")
            }
          }
          if app.access.can(.sozlesmeRead, in: project.id) {
            NavigationLink(value: AppRoute.contracts(projectId: project.id)) {
              RDRow(symbol: AppModule.taseronSozlesmeleri.symbol, symbolTint: RDColor.brandText,
                    title: "Taşeron sözleşmeleri", subtitle: "Kalemler, hakediş, teminat ve ödemeler")
            }
          }
          if model.canSeeCari {
            NavigationLink(value: AppRoute.cariList(projectId: project.id)) {
              RDRow(symbol: AppModule.cari.symbol, symbolTint: RDColor.brandText,
                    title: "Proje carileri", subtitle: "Bakiyeler ve hareketler")
            }
          }
        }
        .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(project.code)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.canEdit {
        Button("Düzenle") { editing = true }
      }
    }
    .sheet(isPresented: $editing) {
      ProjectFormView(model: ProjectFormViewModel(editing: project, repository: app.repositories.projects)) { saved in
        model.didSave(saved)
      }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
  }
}

struct ProjectFormView: View {
  @State var model: ProjectFormViewModel
  let onSaved: (Project) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Proje kodu (ör. SVS-01)", text: $model.code)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
          TextField("Proje adı", text: $model.name)
          Picker("Durum", selection: $model.status) {
            ForEach(ProjectStatus.allCases) { Text($0.title).tag($0) }
          }
        }
        .rdRowBackground()
        Section("Konum") {
          TextField("Şehir", text: $model.city)
          TextField("Adres", text: $model.address, axis: .vertical)
        }
        .rdRowBackground()
        Section("Tarihler") {
          Toggle("Başlangıç tarihi", isOn: $model.hasStartDate)
          if model.hasStartDate {
            DatePicker("Başlangıç", selection: $model.startDate, displayedComponents: .date)
          }
          Toggle("Bitiş tarihi", isOn: $model.hasEndDate)
          if model.hasEndDate {
            DatePicker("Bitiş", selection: $model.endDate, displayedComponents: .date)
          }
        }
        .rdRowBackground()
        Section("Notlar") {
          TextField("Not", text: $model.notes, axis: .vertical).lineLimit(3...6)
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage ?? model.validationMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle(model.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            Task {
              if let saved = await model.save() {
                onSaved(saved)
                dismiss()
              }
            }
          }
          .fontWeight(.semibold)
          .disabled(!model.canSave)
        }
      }
      .interactiveDismissDisabled(model.isSaving)
    }
  }
}
