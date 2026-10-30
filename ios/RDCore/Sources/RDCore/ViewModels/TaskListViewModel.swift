import Foundation
import Observation

@MainActor
@Observable
public final class TaskListViewModel {
  public private(set) var tasks: [TaskItem] = []
  public var projectId: UUID?
  public var openOnly = true
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  // Hızlı iş ekleme
  public var newTitle = ""
  public var newPriority: TaskPriority = .normal
  public var newHasDueDate = false
  public var newDueDate = Date()

  public let projects: [Project]
  private let access: AccessControl
  private let repository: TaskRepository

  public init(projectId: UUID? = nil, projects: [Project], access: AccessControl, repository: TaskRepository) {
    self.projectId = projectId
    self.projects = projects
    self.access = access
    self.repository = repository
  }

  /// İş açılabilecek kapsam: seçili proje ya da (genel izinle) şirket geneli.
  public var canCreate: Bool {
    if let projectId { return access.can(.isWrite, in: projectId) }
    return access.can(.isWrite)
  }

  public func canChangeStatus(_ task: TaskItem) -> Bool {
    if let project = task.projectId { return access.can(.isWrite, in: project) }
    return access.can(.isWrite)
  }

  public func projectName(_ id: UUID?) -> String {
    guard let id else { return "Şirket geneli" }
    return projects.first { $0.id == id }?.name ?? "Proje"
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      tasks = try await repository.list(projectId: projectId, openOnly: openOnly)
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func addTask() async -> Bool {
    guard let title = newTitle.nilIfBlank else {
      errorMessage = "İş başlığı zorunlu."
      return false
    }
    guard canCreate else {
      errorMessage = RepositoryError.forbidden(nil).errorDescription
      return false
    }
    let task = TaskItem(projectId: projectId, title: title,
                        dueDate: newHasDueDate ? CalendarDate(newDueDate) : nil, priority: newPriority)
    do {
      let created = try await repository.create(task)
      tasks.insert(created, at: 0)
      newTitle = ""
      newHasDueDate = false
      newPriority = .normal
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  public func setStatus(_ task: TaskItem, to status: TaskStatus) async {
    do {
      try await repository.setStatus(id: task.id, status: status)
      if let index = tasks.firstIndex(where: { $0.id == task.id }) {
        if openOnly && !status.isOpen {
          tasks.remove(at: index)
        } else {
          tasks[index].status = status
        }
      }
    } catch {
      errorMessage = message(for: error)
    }
  }
}
