import Foundation

/// Veritabanındaki izin anahtarları (permissions.key).
public enum PermissionKey: String, Sendable, CaseIterable {
  case kullaniciManage = "kullanici.manage"
  case auditRead = "audit.read"
  case projeRead = "proje.read"
  case projeWrite = "proje.write"
  case projeCreate = "proje.create"
  case masrafMerkeziManage = "masraf_merkezi.manage"
  case cariRead = "cari.read"
  case cariWrite = "cari.write"
  case cariHareketRead = "cari_hareket.read"
  case cariHareketWrite = "cari_hareket.write"
  case cariHareketReverse = "cari_hareket.reverse"
  case isRead = "is.read"
  case isWrite = "is.write"
}

/// my_permissions() RPC satırı: project_id boşsa genel izin.
public struct PermissionGrant: Hashable, Codable, Sendable {
  public let projectId: UUID?
  public let permissionKey: String

  public init(projectId: UUID?, permissionKey: String) {
    self.projectId = projectId
    self.permissionKey = permissionKey
  }

  enum CodingKeys: String, CodingKey {
    case projectId = "project_id", permissionKey = "permission_key"
  }
}

/// Oturumdaki kullanıcının etkin izinleri. Ekran erişimi için kullanılır;
/// asıl koruma veritabanındaki RLS'tir, bu yapı yalnızca arayüzü sadeleştirir.
public struct AccessControl: Equatable, Sendable {
  public let global: Set<String>
  public let byProject: [UUID: Set<String>]

  public init(grants: [PermissionGrant]) {
    var global = Set<String>()
    var byProject: [UUID: Set<String>] = [:]
    for grant in grants {
      if let project = grant.projectId {
        byProject[project, default: []].insert(grant.permissionKey)
      } else {
        global.insert(grant.permissionKey)
      }
    }
    self.global = global
    self.byProject = byProject
  }

  public static let none = AccessControl(grants: [])

  /// Genel izin (proje dışı kayıtlar, ör. genel giderler).
  public func can(_ key: PermissionKey) -> Bool { global.contains(key.rawValue) }

  /// Belirli projede izin (genel izin de geçerlidir).
  public func can(_ key: PermissionKey, in project: UUID) -> Bool {
    global.contains(key.rawValue) || byProject[project]?.contains(key.rawValue) == true
  }

  /// Genelde ya da en az bir projede izin (modül girişini göstermek için).
  public func canAnywhere(_ key: PermissionKey) -> Bool {
    global.contains(key.rawValue) || byProject.values.contains { $0.contains(key.rawValue) }
  }
}

public struct UserProfile: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let email: String?
  public let fullName: String?
  public let isActive: Bool

  public init(id: UUID, email: String?, fullName: String?, isActive: Bool = true) {
    self.id = id
    self.email = email
    self.fullName = fullName
    self.isActive = isActive
  }

  public var displayName: String { fullName?.nilIfBlank ?? email ?? "Kullanıcı" }

  enum CodingKeys: String, CodingKey {
    case id, email
    case fullName = "full_name", isActive = "is_active"
  }
}
