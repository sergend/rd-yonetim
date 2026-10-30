import RDCore
import RDDesign
import SwiftUI

/// İş satırı. `onToggle` verilirse daire simgesi tek dokunuşla işi tamamlar.
struct TaskRow: View {
  let task: TaskItem
  let projectName: String?
  var onToggle: (() -> Void)?

  var body: some View {
    HStack(spacing: .rdM) {
      statusIcon
      VStack(alignment: .leading, spacing: 2) {
        Text(task.title)
          .font(RDFont.body)
          .foregroundStyle(task.status.isOpen ? RDColor.textPrimary : RDColor.textSecondary)
          .strikethrough(task.status == .tamamlandi)
        if !details.isEmpty {
          Text(details.joined(separator: " · "))
            .font(RDFont.caption)
            .foregroundStyle(task.isOverdue() ? RDColor.tone(.danger) : RDColor.textSecondary)
        }
      }
      Spacer(minLength: 0)
      if task.priority == .yuksek && task.status.isOpen {
        RDStatusBadge(text: task.priority.title, tone: task.priority.tone)
      }
    }
    .frame(minHeight: Metrics.minTouchTarget)
  }

  private var details: [String] {
    var parts: [String] = []
    if let projectName { parts.append(projectName) }
    if let due = task.dueDate { parts.append(task.isOverdue() ? "Gecikti: \(due.display)" : due.display) }
    if task.status == .devam { parts.append(task.status.title) }
    return parts
  }

  @ViewBuilder private var statusIcon: some View {
    let done = task.status == .tamamlandi
    let image = Image(systemName: done ? "checkmark.circle.fill" : "circle")
      .font(.title3)
      .foregroundStyle(done ? RDColor.tone(.success) : RDColor.textSecondary)
    if let onToggle, task.status.isOpen {
      Button(action: onToggle) {
        image.frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget).contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Tamamlandı olarak işaretle: \(task.title)")
    } else {
      image.accessibilityLabel(task.status.title)
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
      if let error = model.errorMessage, !model.tasks.isEmpty {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ForEach(model.tasks) { task in
          TaskRow(task: task, projectName: model.projectId == nil ? model.projectName(task.projectId) : nil,
                  onToggle: model.canChangeStatus(task) ? { Task { await model.setStatus(task, to: .tamamlandi) } } : nil)
            .swipeActions(edge: .trailing) {
              if model.canChangeStatus(task) && task.status == .acik {
                Button("Başladı") { Task { await model.setStatus(task, to: .devam) } }
                  .tint(RDColor.tone(.info))
              }
            }
        }
      } header: {
        Text(scopeTitle)
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .rdContentState(isLoading: model.isLoading, isEmpty: model.tasks.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "İş yok", message: "Seçili filtreye uyan iş bulunamadı.", symbol: "checklist"),
                    retry: { Task { await model.load() } })
    .onChange(of: model.projectId) { _, _ in Task { await model.load() } }
    .onChange(of: model.openOnly) { _, _ in Task { await model.load() } }
    .navigationTitle("İş takibi")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) { filterMenu }
      if model.canCreate {
        ToolbarItem(placement: .primaryAction) {
          Button("Yeni iş", systemImage: "plus") { showingNew = true }
        }
      }
    }
    .sheet(isPresented: $showingNew) { newTaskSheet }
    .refreshable { await model.load() }
    .task { await model.load() }
  }

  private var scopeTitle: String {
    let scope = model.projectId.map { model.projectName($0) } ?? "Tüm projeler"
    return model.openOnly ? "\(scope) · açık işler" : scope
  }

  private var filterMenu: some View {
    Menu {
      Picker("Proje", selection: $model.projectId) {
        Text("Tüm projeler").tag(UUID?.none)
        ForEach(model.projects) { Text($0.name).tag(Optional($0.id)) }
      }
      Toggle("Yalnızca açık işler", isOn: $model.openOnly)
    } label: {
      Label("Filtre", systemImage: "line.3.horizontal.decrease.circle")
    }
  }

  private var newTaskSheet: some View {
    NavigationStack {
      Form {
        Section {
          TextField("İş başlığı", text: $model.newTitle)
          Picker("Öncelik", selection: $model.newPriority) {
            ForEach(TaskPriority.allCases) { Text($0.title).tag($0) }
          }
          Toggle("Son tarih", isOn: $model.newHasDueDate)
          if model.newHasDueDate {
            DatePicker("Son tarih", selection: $model.newDueDate, displayedComponents: .date)
          }
        } footer: {
          Text("Kapsam: \(model.projectName(model.projectId))")
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle("Yeni iş")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { showingNew = false } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Ekle") { Task { if await model.addTask() { showingNew = false } } }
            .fontWeight(.semibold)
            .disabled(model.newTitle.nilIfBlank == nil)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}
