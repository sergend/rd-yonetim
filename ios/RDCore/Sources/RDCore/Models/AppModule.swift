import Foundation

/// Ana ekrandaki modül girişleri. Geliştirilmemiş modüller "yakında" olarak
/// gösterilir ve veri girişi sunmaz.
public enum AppModule: String, CaseIterable, Identifiable, Sendable {
  case projeler, isTakibi, cari, genelGider
  case puantaj, taseronSozlesmeleri, hakedis, giderler, daireler, raporlar, kullanicilar

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .projeler: "Projeler"
    case .isTakibi: "İş takibi"
    case .cari: "Cari hesaplar"
    case .genelGider: "Şirket genel giderleri"
    case .puantaj: "Puantaj"
    case .taseronSozlesmeleri: "Taşeron sözleşmeleri"
    case .hakedis: "Hakediş"
    case .giderler: "Proje giderleri"
    case .daireler: "Daireler ve satış"
    case .raporlar: "Raporlar"
    case .kullanicilar: "Kullanıcılar ve yetkiler"
    }
  }

  /// SF Symbols adı.
  public var symbol: String {
    switch self {
    case .projeler: "building.2"
    case .isTakibi: "checklist"
    case .cari: "person.2.crop.square.stack"
    case .genelGider: "building.columns"
    case .puantaj: "calendar.badge.clock"
    case .taseronSozlesmeleri: "doc.text"
    case .hakedis: "doc.badge.gearshape"
    case .giderler: "cart"
    case .daireler: "house"
    case .raporlar: "chart.bar.doc.horizontal"
    case .kullanicilar: "person.badge.key"
    }
  }

  public var isAvailable: Bool {
    switch self {
    case .projeler, .isTakibi, .cari, .genelGider: true
    default: false
    }
  }

  /// Modül girişinin görünmesi için gereken izin.
  public var requiredPermission: PermissionKey {
    switch self {
    case .projeler: .projeRead
    case .isTakibi: .isRead
    case .cari, .taseronSozlesmeleri, .hakedis: .cariRead
    case .genelGider, .giderler: .cariHareketRead
    case .puantaj, .daireler: .projeRead
    case .raporlar: .cariHareketRead
    case .kullanicilar: .kullaniciManage
    }
  }

  public func isVisible(for access: AccessControl) -> Bool {
    switch self {
    case .genelGider, .kullanicilar: access.can(requiredPermission)  // proje dışı: genel izin gerekir
    default: access.canAnywhere(requiredPermission)
    }
  }
}
