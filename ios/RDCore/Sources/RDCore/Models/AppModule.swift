import Foundation

/// Ana ekrandaki modül girişleri. Geliştirilmemiş modüller "yakında" olarak
/// gösterilir ve veri girişi sunmaz.
public enum AppModule: String, CaseIterable, Identifiable, Sendable {
  case projeler, isTakibi, taseronlar, personel, ekipler, cari, genelGider
  case puantaj, imalat, taseronSozlesmeleri, hakedis, giderler, borclar, gelirler, raporlar, daireler, kullanicilar

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .projeler: "Projeler"
    case .isTakibi: "İş takibi"
    case .taseronlar: "Taşeronlar"
    case .personel: "Personel"
    case .ekipler: "Ekipler"
    case .cari: "Cari hesaplar"
    case .genelGider: "Masraf merkezleri (cari)"
    case .puantaj: "Puantaj"
    case .imalat: "İmalat (metraj)"
    case .taseronSozlesmeleri: "Taşeron sözleşmeleri"
    case .hakedis: "Hakediş"
    case .giderler: "Giderler"
    case .borclar: "Bekleyen borçlar"
    case .gelirler: "Gelir ve tahsilat"
    case .daireler: "Daireler ve satış"
    case .raporlar: "Gider ve gelir raporları"
    case .kullanicilar: "Kullanıcılar ve yetkiler"
    }
  }

  /// SF Symbols adı.
  public var symbol: String {
    switch self {
    case .projeler: "building.2"
    case .isTakibi: "checklist"
    case .taseronlar: "person.2.badge.gearshape"
    case .personel: "person.crop.rectangle.stack"
    case .ekipler: "person.3"
    case .cari: "person.2.crop.square.stack"
    case .genelGider: "building.columns"
    case .puantaj: "calendar.badge.clock"
    case .imalat: "ruler"
    case .taseronSozlesmeleri: "doc.text"
    case .hakedis: "doc.badge.gearshape"
    case .giderler: "cart"
    case .borclar: "calendar.badge.exclamationmark"
    case .gelirler: "arrow.down.circle"
    case .daireler: "house"
    case .raporlar: "chart.bar.doc.horizontal"
    case .kullanicilar: "person.badge.key"
    }
  }

  public var isAvailable: Bool {
    switch self {
    case .projeler, .isTakibi, .taseronlar, .personel, .ekipler, .puantaj, .cari, .genelGider,
         .imalat, .taseronSozlesmeleri, .hakedis, .giderler, .borclar, .gelirler, .raporlar: true
    default: false
    }
  }

  /// Modül girişinin görünmesi için gereken izin.
  public var requiredPermission: PermissionKey {
    switch self {
    case .projeler: .projeRead
    case .isTakibi: .isRead
    case .taseronlar: .taseronRead
    case .personel, .ekipler: .personelRead
    case .cari: .cariRead
    case .taseronSozlesmeleri: .sozlesmeRead
    case .hakedis: .hakedisRead
    case .imalat: .imalatRead
    case .genelGider: .cariHareketRead
    case .giderler: .giderWrite
    case .borclar: .giderRead
    case .gelirler: .gelirRead
    case .puantaj: .puantajRead
    case .daireler: .projeRead
    case .raporlar: .finansRaporRead
    case .kullanicilar: .kullaniciManage
    }
  }

  public func isVisible(for access: AccessControl) -> Bool {
    switch self {
    case .genelGider, .kullanicilar: access.can(requiredPermission)  // proje dışı: genel izin gerekir
    // Gider girişi: yazma (şantiye hızlı giriş) veya okuma izni yeter.
    case .giderler: access.canAnywhere(.giderWrite) || access.canAnywhere(.giderRead)
    case .gelirler: access.canAnywhere(.gelirRead) || access.canAnywhere(.gelirWrite)
    default: access.canAnywhere(requiredPermission)
    }
  }
}
