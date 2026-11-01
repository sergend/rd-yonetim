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
  case taseronRead = "taseron.read"
  case taseronWrite = "taseron.write"
  case personelRead = "personel.read"
  case personelWrite = "personel.write"
  case personelIletisimRead = "personel_iletisim.read"
  case gorevlendirmeRead = "gorevlendirme.read"
  case gorevlendirmeWrite = "gorevlendirme.write"
  case puantajRead = "puantaj.read"
  case puantajWrite = "puantaj.write"
  case puantajReview = "puantaj.review"
  case puantajApprove = "puantaj.approve"
  case puantajUnlock = "puantaj.unlock"
  // Aşama 4: sözleşme, imalat, hakediş ve ödeme ayrı izinlerdir. Puantaj
  // izni finansal tutarlara erişim vermez.
  case sozlesmeRead = "sozlesme.read"
  case sozlesmeWrite = "sozlesme.write"
  case sozlesmeApprove = "sozlesme.approve"
  case imalatRead = "imalat.read"
  case imalatWrite = "imalat.write"
  case imalatApprove = "imalat.approve"
  case hakedisRead = "hakedis.read"
  case hakedisPrepare = "hakedis.prepare"
  case hakedisApprove = "hakedis.approve"
  case hakedisLimitOverride = "hakedis.limit_override"
  case hakedisPost = "hakedis.post"
  case teminatRelease = "teminat.release"
  case odemeWrite = "odeme.write"
  case vergiManage = "vergi.manage"
  // Aşama 5: gider, gelir, borç/alacak
  case giderRead = "gider.read"
  case giderWrite = "gider.write"
  case giderApprove = "gider.approve"
  case giderPay = "gider.pay"
  case gelirRead = "gelir.read"
  case gelirWrite = "gelir.write"
  case gelirApprove = "gelir.approve"
  case gelirCollect = "gelir.collect"
  case finansRaporRead = "finans_rapor.read"
  case finansKategoriManage = "finans_kategori.manage"
  // Aşama 6: evrak arşivi. Görüntüleme ve ekleme ayrı; finansal belge türleri ayrı izin ister.
  case belgeRead = "belge.read"
  case belgeFinansRead = "belge.finans_read"
  case belgeWrite = "belge.write"
  case belgeManage = "belge.manage"
  // Aşama 7: malzeme, stok ve satın alma. Stok izinleri tutar göstermez;
  // satın alma onayı ve iptali stok izinlerinden ayrıdır.
  case stokRead = "stok.read"
  case stokWrite = "stok.write"
  case stokApprove = "stok.approve"
  case stokCancel = "stok.cancel"
  case malzemeManage = "malzeme.manage"
  case satinalmaRead = "satinalma.read"
  case satinalmaWrite = "satinalma.write"
  case satinalmaApprove = "satinalma.approve"
  case satinalmaReceive = "satinalma.receive"
  case satinalmaCancel = "satinalma.cancel"
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
