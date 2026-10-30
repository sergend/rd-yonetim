import Foundation

public enum ProjectStatus: String, Codable, CaseIterable, Sendable, Identifiable {
  case planlama, devam, durdu, tamamlandi

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .planlama: "Planlama"
    case .devam: "Devam ediyor"
    case .durdu: "Durdu"
    case .tamamlandi: "Tamamlandı"
    }
  }
}

public struct Project: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var code: String
  public var name: String
  public var address: String?
  public var city: String?
  public var startDate: CalendarDate?
  public var endDate: CalendarDate?
  public var status: ProjectStatus
  public var notes: String?
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID = UUID(), code: String, name: String, address: String? = nil, city: String? = nil,
              startDate: CalendarDate? = nil, endDate: CalendarDate? = nil, status: ProjectStatus = .planlama,
              notes: String? = nil, isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.code = code
    self.name = name
    self.address = address
    self.city = city
    self.startDate = startDate
    self.endDate = endDate
    self.status = status
    self.notes = notes
    self.isDemo = isDemo
    self.version = version
  }

  enum CodingKeys: String, CodingKey {
    case id, code, name, address, city, status, notes, version
    case startDate = "start_date", endDate = "end_date", isDemo = "is_demo"
  }
}

/// Proje oluşturma/düzenleme formunun gönderdiği alanlar.
public struct ProjectDraft: Equatable, Sendable, Encodable {
  public var code: String
  public var name: String
  public var address: String?
  public var city: String?
  public var startDate: CalendarDate?
  public var endDate: CalendarDate?
  public var status: ProjectStatus
  public var notes: String?

  public init(code: String = "", name: String = "", address: String? = nil, city: String? = nil,
              startDate: CalendarDate? = nil, endDate: CalendarDate? = nil,
              status: ProjectStatus = .planlama, notes: String? = nil) {
    self.code = code
    self.name = name
    self.address = address
    self.city = city
    self.startDate = startDate
    self.endDate = endDate
    self.status = status
    self.notes = notes
  }

  public init(_ project: Project) {
    self.init(code: project.code, name: project.name, address: project.address, city: project.city,
              startDate: project.startDate, endDate: project.endDate, status: project.status, notes: project.notes)
  }

  enum CodingKeys: String, CodingKey {
    case code, name, address, city, status, notes
    case startDate = "start_date", endDate = "end_date"
  }

  // Boş alanlar null olarak gönderilir; düzenlemede alan temizlenebilsin.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(code, forKey: .code)
    try c.encode(name, forKey: .name)
    try c.encode(address, forKey: .address)
    try c.encode(city, forKey: .city)
    try c.encode(startDate, forKey: .startDate)
    try c.encode(endDate, forKey: .endDate)
    try c.encode(status, forKey: .status)
    try c.encode(notes, forKey: .notes)
  }
}

/// Projeye bağlı olmayan şirket genel gider merkezi (merkez ofis, araçlar...).
public struct CostCenter: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var code: String
  public var name: String
  public var description: String?
  public var isActive: Bool
  public var isDemo: Bool

  public init(id: UUID = UUID(), code: String, name: String, description: String? = nil,
              isActive: Bool = true, isDemo: Bool = false) {
    self.id = id
    self.code = code
    self.name = name
    self.description = description
    self.isActive = isActive
    self.isDemo = isDemo
  }

  enum CodingKeys: String, CodingKey {
    case id, code, name, description
    case isActive = "is_active", isDemo = "is_demo"
  }
}
