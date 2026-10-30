import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable, Identifiable {
  case acik, devam, tamamlandi, iptal

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .acik: "Açık"
    case .devam: "Devam ediyor"
    case .tamamlandi: "Tamamlandı"
    case .iptal: "İptal"
    }
  }
  public var isOpen: Bool { self == .acik || self == .devam }
}

public enum TaskPriority: String, Codable, CaseIterable, Sendable, Identifiable {
  case dusuk, normal, yuksek

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .dusuk: "Düşük"
    case .normal: "Normal"
    case .yuksek: "Yüksek"
    }
  }
}

/// İş takibi kaydı. Proje boşsa şirket genelidir.
public struct TaskItem: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var projectId: UUID?
  public var title: String
  public var description: String?
  public var assigneeId: UUID?
  public var dueDate: CalendarDate?
  public var status: TaskStatus
  public var priority: TaskPriority

  public init(id: UUID = UUID(), projectId: UUID? = nil, title: String, description: String? = nil,
              assigneeId: UUID? = nil, dueDate: CalendarDate? = nil, status: TaskStatus = .acik,
              priority: TaskPriority = .normal) {
    self.id = id
    self.projectId = projectId
    self.title = title
    self.description = description
    self.assigneeId = assigneeId
    self.dueDate = dueDate
    self.status = status
    self.priority = priority
  }

  public func isOverdue(today: CalendarDate = .today()) -> Bool {
    guard status.isOpen, let dueDate else { return false }
    return dueDate < today
  }

  enum CodingKeys: String, CodingKey {
    case id, title, description, status, priority
    case projectId = "project_id", assigneeId = "assignee_id", dueDate = "due_date"
  }
}
