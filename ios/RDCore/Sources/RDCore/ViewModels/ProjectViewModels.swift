import Foundation
import Observation

@MainActor
@Observable
public final class ProjectListViewModel {
  public private(set) var projects: [Project] = []
  public var searchText = ""
  public var includeCompleted = false
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let access: AccessControl
  private let repository: ProjectRepository

  public init(access: AccessControl, repository: ProjectRepository) {
    self.access = access
    self.repository = repository
  }

  public var canCreate: Bool { access.can(.projeCreate) }

  public var filtered: [Project] {
    guard let query = searchText.nilIfBlank?.lowercased(with: Money.locale) else { return projects }
    return projects.filter {
      $0.name.lowercased(with: Money.locale).contains(query)
        || $0.code.lowercased(with: Money.locale).contains(query)
        || ($0.city?.lowercased(with: Money.locale).contains(query) ?? false)
    }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      projects = try await repository.list(includeCompleted: includeCompleted)
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Form kaydettikten sonra listeyi yeniden çekmeden günceller.
  public func upsert(_ project: Project) {
    if let index = projects.firstIndex(where: { $0.id == project.id }) {
      projects[index] = project
    } else {
      projects.append(project)
      projects.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
  }
}

/// Proje oluşturma ve düzenleme formu.
@MainActor
@Observable
public final class ProjectFormViewModel {
  public var code: String
  public var name: String
  public var city: String
  public var address: String
  public var notes: String
  public var status: ProjectStatus
  public var hasStartDate: Bool
  public var startDate: Date
  public var hasEndDate: Bool
  public var endDate: Date

  public private(set) var isSaving = false
  public private(set) var errorMessage: String?

  public let editing: Project?
  private let repository: ProjectRepository

  public init(editing: Project? = nil, repository: ProjectRepository) {
    self.editing = editing
    self.repository = repository
    let draft = editing.map(ProjectDraft.init) ?? ProjectDraft()
    code = draft.code
    name = draft.name
    city = draft.city ?? ""
    address = draft.address ?? ""
    notes = draft.notes ?? ""
    status = draft.status
    hasStartDate = draft.startDate != nil
    startDate = (draft.startDate ?? .today()).date()
    hasEndDate = draft.endDate != nil
    endDate = (draft.endDate ?? .today()).date()
  }

  public var title: String { editing == nil ? "Yeni proje" : "Projeyi düzenle" }

  public var draft: ProjectDraft {
    ProjectDraft(code: code.trimmingCharacters(in: .whitespaces).uppercased(),
                 name: name.trimmingCharacters(in: .whitespaces),
                 address: address.nilIfBlank, city: city.nilIfBlank,
                 startDate: hasStartDate ? CalendarDate(startDate) : nil,
                 endDate: hasEndDate ? CalendarDate(endDate) : nil,
                 status: status, notes: notes.nilIfBlank)
  }

  /// Kaydetmeyi engelleyen ilk sorun (yoksa nil).
  public var validationMessage: String? {
    let draft = draft
    if draft.code.isEmpty { return "Proje kodu zorunlu." }
    if draft.name.isEmpty { return "Proje adı zorunlu." }
    if let start = draft.startDate, let end = draft.endDate, end < start {
      return "Bitiş tarihi başlangıçtan önce olamaz."
    }
    return nil
  }

  public var canSave: Bool { validationMessage == nil && !isSaving }

  /// Başarılıysa kaydedilen projeyi döner.
  public func save() async -> Project? {
    if let validationMessage {
      errorMessage = validationMessage
      return nil
    }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      if let editing {
        return try await repository.update(id: editing.id, expectedVersion: editing.version, with: draft)
      }
      return try await repository.create(draft)
    } catch RepositoryError.conflict(let detail) {
      errorMessage = detail ?? "Bu proje siz düzenlerken değiştirildi veya kod başka bir projede kullanılıyor. Kapatıp yeniden açın."
    } catch {
      errorMessage = message(for: error)
    }
    return nil
  }
}

@MainActor
@Observable
public final class ProjectDetailViewModel {
  public private(set) var project: Project
  public private(set) var tasks: [TaskItem] = []
  public private(set) var errorMessage: String?

  private let access: AccessControl
  private let repositories: Repositories

  public init(project: Project, access: AccessControl, repositories: Repositories) {
    self.project = project
    self.access = access
    self.repositories = repositories
  }

  public var canEdit: Bool { access.can(.projeWrite, in: project.id) }
  public var canSeeCari: Bool { access.can(.cariHareketRead, in: project.id) }
  public var canSeeTasks: Bool { access.can(.isRead, in: project.id) }

  public func load() async {
    errorMessage = nil
    do {
      project = try await repositories.projects.get(id: project.id)
      if canSeeTasks {
        tasks = try await repositories.tasks.list(projectId: project.id, openOnly: true)
      }
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func didSave(_ project: Project) {
    self.project = project
  }
}
