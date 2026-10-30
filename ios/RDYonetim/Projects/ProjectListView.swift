import RDCore
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
      if let error = model.errorMessage {
        ErrorBanner(message: error).listRowBackground(Color.clear)
      }
      Toggle("Tamamlananları göster", isOn: $model.includeCompleted)
        .onChange(of: model.includeCompleted) { _, _ in Task { await model.load() } }
      ForEach(model.filtered) { project in
        NavigationLink(value: AppRoute.project(project)) {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Text(project.name).font(.body.weight(.medium))
              if project.isDemo { DemoBadge() }
            }
            HStack {
              Text([project.code, project.city].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
              Spacer()
              StatusBadge(text: project.status.title, color: project.status.color)
            }
          }
        }
      }
    }
    .overlay {
      if model.filtered.isEmpty && !model.isLoading {
        ContentUnavailableView("Proje yok", systemImage: "building.2",
                               description: Text("Görüntüleme yetkiniz olan proje bulunamadı."))
      }
    }
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
        ErrorBanner(message: error).listRowBackground(Color.clear)
      }
      Section {
        LabeledContent("Kod", value: project.code)
        LabeledContent("Durum") { StatusBadge(text: project.status.title, color: project.status.color) }
        if let city = project.city { LabeledContent("Şehir", value: city) }
        if let address = project.address { LabeledContent("Adres", value: address) }
        if let start = project.startDate { LabeledContent("Başlangıç", value: start.display) }
        if let end = project.endDate { LabeledContent("Bitiş", value: end.display) }
        if project.isDemo {
          Label("Bu bir demo projedir; kayıtları gerçek verilere karışmaz.", systemImage: "info.circle")
            .font(.footnote).foregroundStyle(.orange)
        }
      }
      if let notes = project.notes {
        Section("Notlar") { Text(notes) }
      }
      if model.canSeeTasks {
        Section {
          ForEach(model.tasks.prefix(5)) { task in
            TaskRow(task: task, projectName: nil)
          }
          NavigationLink("Tüm işler", value: AppRoute.tasks(projectId: project.id))
        } header: {
          Text("Açık işler (\(model.tasks.count))")
        }
      }
      if model.canSeeCari {
        Section("Finans") {
          NavigationLink(value: AppRoute.cariList(projectId: project.id)) {
            Label("Proje carileri ve bakiyeler", systemImage: AppModule.cari.symbol)
          }
        }
      }
    }
    .navigationTitle(project.name)
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
        Section("Konum") {
          TextField("Şehir", text: $model.city)
          TextField("Adres", text: $model.address, axis: .vertical)
        }
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
        Section("Notlar") {
          TextField("Not", text: $model.notes, axis: .vertical).lineLimit(3...6)
        }
        if let message = model.errorMessage ?? model.validationMessage {
          Section { Text(message).foregroundStyle(.red).font(.callout) }
        }
      }
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
          .disabled(!model.canSave)
        }
      }
      .interactiveDismissDisabled(model.isSaving)
    }
  }
}
