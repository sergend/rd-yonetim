import Foundation
import Observation

/// Ana ekran: aktif projeler, açık işler ve modül girişleri. Tutar göstermez.
@MainActor
@Observable
public final class HomeViewModel {
  public private(set) var projects: [Project] = []
  public private(set) var openTasks: [TaskItem] = []
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  public let context: SessionContext
  private let repositories: Repositories

  public init(context: SessionContext, repositories: Repositories) {
    self.context = context
    self.repositories = repositories
  }

  public var availableModules: [AppModule] {
    AppModule.allCases.filter { $0.isAvailable && $0.isVisible(for: context.access) }
  }

  public var upcomingModules: [AppModule] {
    AppModule.allCases.filter { !$0.isAvailable && $0.isVisible(for: context.access) }
  }

  public var activeProjects: [Project] { projects.filter { $0.status == .devam || $0.status == .planlama } }

  public var myTasks: [TaskItem] { openTasks.filter { $0.assigneeId == context.session.userId } }

  public func overdueCount(today: CalendarDate = .today()) -> Int {
    openTasks.filter { $0.isOverdue(today: today) }.count
  }

  public func openTaskCount(projectId: UUID) -> Int {
    openTasks.filter { $0.projectId == projectId }.count
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      let canSeeProjects = context.access.canAnywhere(.projeRead)
      async let projects = canSeeProjects ? repositories.projects.list(includeCompleted: false) : []
      async let tasks = repositories.tasks.list(projectId: nil, openOnly: true)
      self.projects = try await projects
      self.openTasks = try await tasks
    } catch {
      errorMessage = message(for: error)
    }
  }
}
