import RDDesign
import SwiftUI
import UIKit

// RD Projeler tasarım sistemi: SwiftUI tarafı. Değerler RDDesign token'larından
// gelir; ekranlar sabit renk veya boşluk yazmaz, bu adları kullanır.

extension Color {
  /// Açık/koyu temaya göre değişen token rengi.
  init(_ themed: ThemedColor) {
    self.init(uiColor: UIColor { traits in
      let rgb = traits.userInterfaceStyle == .dark ? themed.dark : themed.light
      return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    })
  }
}

enum RDColor {
  static let brand = Color(Palette.brand)
  static let brandText = Color(Palette.brandText)
  static let onBrand = Color(Palette.onBrand)
  static let background = Color(Palette.background)
  static let surface = Color(Palette.surface)
  static let textPrimary = Color(Palette.textPrimary)
  static let textSecondary = Color(Palette.textSecondary)
  static let separator = Color(Palette.separator)

  static func tone(_ tone: StatusTone) -> Color { Color(tone.color) }
}

/// Tipografi: yalnızca Dynamic Type metin stilleri (kullanıcının yazı boyutunu izler).
enum RDFont {
  static let screenTitle = Font.largeTitle.weight(.bold)
  static let sectionTitle = Font.title3.weight(.semibold)
  static let rowTitle = Font.body.weight(.semibold)
  static let body = Font.body
  static let secondary = Font.subheadline
  static let caption = Font.footnote
  static let badge = Font.caption.weight(.semibold)
  static let metric = Font.title2.weight(.bold)
  static let button = Font.headline
}

extension CGFloat {
  static let rdXS = CGFloat(Spacing.xs)
  static let rdS = CGFloat(Spacing.s)
  static let rdM = CGFloat(Spacing.m)
  static let rdL = CGFloat(Spacing.l)
  static let rdXL = CGFloat(Spacing.xl)
  static let rdXXL = CGFloat(Spacing.xxl)
  static let rdScreen = CGFloat(Spacing.screen)
}

extension View {
  /// Tüm liste ekranlarında ortak sayfa zemini.
  func rdScreen() -> some View {
    scrollContentBackground(.hidden)
      .background(RDColor.background.ignoresSafeArea())
  }

  /// Liste bölümü satırı yüzeyi.
  func rdRowBackground() -> some View {
    listRowBackground(RDColor.surface)
  }
}
