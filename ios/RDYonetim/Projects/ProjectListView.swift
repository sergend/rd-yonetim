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

      if model.canSeeCari {
        Section("Finans") {
          NavigationLink(value: AppRoute.cariList(projectId: project.id)) {
            RDRow(symbol: AppModule.cari.symbol, symbolTint: RDColor.brandText,
                  title: "Proje carileri", subtitle: "Bakiyeler ve hareketler")
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
