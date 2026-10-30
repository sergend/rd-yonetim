import RDCore
import SwiftUI

struct TaskRow: View {
  let task: TaskItem
  let projectName: String?

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: task.status == .tamamlandi ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(task.status == .tamamlandi ? .green : task.priority.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(task.title).strikethrough(task.status == .tamamlandi)
        HStack(spacing: 8) {
          if let projectName { Text(projectName) }
          if let due = task.dueDate {
            Text(due.display).foregroundStyle(task.isOverdue() ? .red : .secondary)
          }
          if task.status == .devam { Text(task.status.title) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}

struct TaskListView: View {
  let app: AppModel
  @State private var model: TaskListViewModel
  @State private var showingNew = false

  init(projectId: UUID?, app: AppModel) {
    self.app = app
    _model = State(initialValue: TaskListViewModel(projectId: projectId, projects: app.projects, access: app.access,
                                                   repository: app.repositories.tasks))
  }

  var body: some View {
    List {
      if let error = model.errorMessage {
        ErrorBanner(message: error).listRowBackground(Color.clear)
      }
      Section {
        Picker("Proje", selection: $model.projectId) {
          Text("Tüm projeler").tag(UUID?.none)
          ForEach(model.projects) { Text($0.name).tag(Optional($0.id)) }
        }
        Toggle("Yalnızca açık işler", isOn: $model.openOnly)
      }
      .onChange(of: model.projectId) { _, _ in Task { await model.load() } }
      .onChange(of: model.openOnly) { _, _ in Task { await model.load() } }

      Section {
        ForEach(model.tasks) { task in
          TaskRow(task: task, projectName: model.projectId == nil ? model.projectName(task.projectId) : nil)
            .swipeActions(edge: .trailing) {
              if model.canChangeStatus(task) && task.status.isOpen {
                Button("Tamamlandı") { Task { await model.setStatus(task, to: .tamamlandi) } }.tint(.green)
                Button("Devam") { Task { await model.setStatus(task, to: .devam) } }.tint(.blue)
              }
            }
        }
      }
    }
    .overlay {
      if model.tasks.isEmpty && !model.isLoading {
        ContentUnavailableView("İş yok", systemImage: "checklist", description: Text("Seçili filtreye uyan iş bulunamadı."))
      }
    }
    .navigationTitle("İş takibi")
    .toolbar {
      if model.canCreate {
        Button("Yeni iş", systemImage: "plus") { showingNew = true }
      }
    }
    .sheet(isPresented: $showingNew) {
      NavigationStack {
        Form {
          TextField("İş başlığı", text: $model.newTitle)
          Picker("Öncelik", selection: $model.newPriority) {
            ForEach(TaskPriority.allCases) { Text($0.title).tag($0) }
          }
          Toggle("Son tarih", isOn: $model.newHasDueDate)
          if model.newHasDueDate {
            DatePicker("Son tarih", selection: $model.newDueDate, displayedComponents: .date)
          }
          LabeledContent("Kapsam", value: model.projectName(model.projectId))
        }
        .environment(\.locale, Money.locale)
        .navigationTitle("Yeni iş")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { showingNew = false } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Ekle") { Task { if await model.addTask() { showingNew = false } } }
          }
        }
      }
      .presentationDetents([.medium])
    }
    .refreshable { await model.load() }
    .task { await model.load() }
  }
}
