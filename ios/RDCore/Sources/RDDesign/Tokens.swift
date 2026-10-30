import Foundation

/// sRGB renk değeri (0xRRGGBB). SwiftUI rengine uygulamada çevrilir.
public struct RGB: Hashable, Sendable, CustomStringConvertible {
  public let hex: UInt32

  public init(_ hex: UInt32) { self.hex = hex }

  public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
  public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
  public var blue: Double { Double(hex & 0xFF) / 255 }
  public var description: String { String(format: "#%06X", hex) }

  /// WCAG 2.x göreli parlaklık.
  public var luminance: Double {
    func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
  }

  /// WCAG kontrast oranı (1...21).
  public func contrast(with other: RGB) -> Double {
    let (a, b) = (luminance, other.luminance)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
}

/// Açık ve koyu tema için bir renk çifti.
public struct ThemedColor: Hashable, Sendable {
  public let light: RGB
  public let dark: RGB

  public init(light: RGB, dark: RGB) {
    self.light = light
    self.dark = dark
  }
}

/// RD Projeler renk token'ları.
///
/// Marka kırmızısı GEÇİCİDİR: kesin değer orijinal RD logosundan alınacak ve
/// yalnızca `brandRedLight` / `brandRedDark` değiştirilecek. Değiştirince
/// `swift test` kontrast testlerini çalıştırır; geçmeyen değer kullanılamaz.
/// Kırmızı yalnızca marka vurgusu ve birincil etkileşimlerde kullanılır;
/// gövde metni ve yüzeyler nötrdür.
public enum Palette {
  /// Birincil buton dolgusu ve marka vurgusu (beyaz metinle kullanılır).
  public static let brand = ThemedColor(light: RGB(0xC8102E), dark: RGB(0xC8102E))
  /// Kırmızının metin/ikon olarak kullanıldığı yerler (bağlantı, seçili durum).
  /// Koyu temada okunurluk için daha açık ton.
  public static let brandText = ThemedColor(light: RGB(0xC8102E), dark: RGB(0xF0565C))
  /// Marka dolgusu üzerindeki metin.
  public static let onBrand = ThemedColor(light: RGB(0xFFFFFF), dark: RGB(0xFFFFFF))

  /// Sayfa arka planı (iOS gruplu arka plan ile aynı).
  public static let background = ThemedColor(light: RGB(0xF2F2F7), dark: RGB(0x000000))
  /// Bölüm/satır yüzeyi.
  public static let surface = ThemedColor(light: RGB(0xFFFFFF), dark: RGB(0x1C1C1E))
  /// Ana metin: güçlü, siyaha yakın.
  public static let textPrimary = ThemedColor(light: RGB(0x111114), dark: RGB(0xF5F5F7))
  /// İkincil metin.
  public static let textSecondary = ThemedColor(light: RGB(0x5C5C66), dark: RGB(0xA1A1AA))
  public static let separator = ThemedColor(light: RGB(0xD9D9DE), dark: RGB(0x38383A))

  // Durum renkleri (etiketler, bakiye yönü). Metin olarak yüzey üzerinde okunur olmalı.
  public static let success = ThemedColor(light: RGB(0x1A7F37), dark: RGB(0x4ADE80))
  public static let warning = ThemedColor(light: RGB(0x9A5B00), dark: RGB(0xFBBF24))
  public static let danger = ThemedColor(light: RGB(0xB42318), dark: RGB(0xFF7B72))
  public static let info = ThemedColor(light: RGB(0x1F5FAD), dark: RGB(0x7CB4FF))
  public static let neutral = ThemedColor(light: RGB(0x5C5C66), dark: RGB(0xA1A1AA))
}

/// 4 pt tabanlı boşluk ölçeği.
public enum Spacing {
  public static let xxs: Double = 2
  public static let xs: Double = 4
  public static let s: Double = 8
  public static let m: Double = 12
  public static let l: Double = 16
  public static let xl: Double = 24
  public static let xxl: Double = 32
  /// Ekran kenar boşluğu (iPhone).
  public static let screen: Double = 16
}

public enum Radius {
  public static let small: Double = 8     // etiket, küçük kontrol
  public static let medium: Double = 12   // giriş alanı, buton
  public static let large: Double = 16    // bölüm yüzeyi
}

public enum Metrics {
  /// Apple İnsan Arayüzü Yönergeleri asgari dokunma alanı.
  public static let minTouchTarget: Double = 44
  /// Birincil buton yüksekliği.
  public static let buttonHeight: Double = 50
}

/// Durum etiketlerinin anlam tonu. Ekranlar renk değil ton seçer.
public enum StatusTone: Sendable, CaseIterable {
  case neutral, info, success, warning, danger, brand

  public var color: ThemedColor {
    switch self {
    case .neutral: Palette.neutral
    case .info: Palette.info
    case .success: Palette.success
    case .warning: Palette.warning
    case .danger: Palette.danger
    case .brand: Palette.brandText
    }
  }
}
