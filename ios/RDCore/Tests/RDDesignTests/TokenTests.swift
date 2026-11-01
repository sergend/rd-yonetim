import Foundation
import RDCore
import XCTest
@testable import RDDesign

/// Token değişikliklerinin erişilebilirliği bozmadığını denetler (WCAG 2.1 AA).
final class TokenTests: XCTestCase {
  private let textMinimum = 4.5      // normal metin
  private let nonTextMinimum = 3.0   // buton dolgusu, ikon, kontrol sınırı

  private func both(_ color: ThemedColor) -> [(String, RGB)] { [("açık", color.light), ("koyu", color.dark)] }

  func testTextColorsAreReadableOnBackgroundAndSurface() {
    let pairs: [(String, ThemedColor)] = [
      ("textPrimary", Palette.textPrimary), ("textSecondary", Palette.textSecondary),
      ("brandText", Palette.brandText), ("success", Palette.success), ("warning", Palette.warning),
      ("danger", Palette.danger), ("info", Palette.info), ("neutral", Palette.neutral),
    ]
    for (name, color) in pairs {
      for (bg, isDark) in [(Palette.background, false), (Palette.surface, false), (Palette.background, true), (Palette.surface, true)] {
        let fg = isDark ? color.dark : color.light
        let back = isDark ? bg.dark : bg.light
        XCTAssertGreaterThanOrEqual(fg.contrast(with: back), textMinimum,
                                    "\(name) \(fg) / \(back) (\(isDark ? "koyu" : "açık"))")
      }
    }
  }

  func testPrimaryButtonTextIsReadable() {
    XCTAssertGreaterThanOrEqual(Palette.onBrand.light.contrast(with: Palette.brand.light), textMinimum)
    XCTAssertGreaterThanOrEqual(Palette.onBrand.dark.contrast(with: Palette.brand.dark), textMinimum)
  }

  func testBrandFillIsDistinguishableFromPage() {
    XCTAssertGreaterThanOrEqual(Palette.brand.light.contrast(with: Palette.background.light), nonTextMinimum)
    XCTAssertGreaterThanOrEqual(Palette.brand.dark.contrast(with: Palette.background.dark), nonTextMinimum)
  }

  func testPrimaryTextIsStrong() {
    // "Güçlü ve okunaklı koyu tipografi": ana metin AAA düzeyinde.
    XCTAssertGreaterThanOrEqual(Palette.textPrimary.light.contrast(with: Palette.surface.light), 7)
    XCTAssertGreaterThanOrEqual(Palette.textPrimary.dark.contrast(with: Palette.surface.dark), 7)
  }

  func testContrastFormulaMatchesKnownValues() {
    XCTAssertEqual(RGB(0x000000).contrast(with: RGB(0xFFFFFF)), 21, accuracy: 0.01)
    XCTAssertEqual(RGB(0x777777).contrast(with: RGB(0xFFFFFF)), 4.48, accuracy: 0.01)
  }

  func testSpacingScaleAndTouchTarget() {
    let scale = [Spacing.xs, Spacing.s, Spacing.m, Spacing.l, Spacing.xl, Spacing.xxl]
    XCTAssertEqual(scale, scale.sorted())
    XCTAssertTrue(scale.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
    XCTAssertGreaterThanOrEqual(Metrics.buttonHeight, Metrics.minTouchTarget)
  }

  func testEveryStatusHasATone() {
    for status in ProjectStatus.allCases { _ = status.tone }
    XCTAssertEqual(TaskPriority.yuksek.tone, .danger)
    XCTAssertEqual(BalanceSide.weOwe.tone, .danger)
    for status in PuantajPeriodStatus.allCases { _ = status.tone }
    for status in StockMovementStatus.allCases { _ = status.tone }
    for status in PurchaseOrderStatus.allCases { _ = status.tone }
    // Puantaj hücresinde renk tek başına anlam taşımaz: her durumun ayrı kısa harfi var.
    XCTAssertEqual(Set(PuantajStatus.allCases.map(\.shortLabel)).count, PuantajStatus.allCases.count)
    XCTAssertNotEqual(PuantajStatus.tamGun.tone, PuantajStatus.calismadi.tone)
  }

  /// Xcode'un global vurgu rengi (AccentColor) token ile aynı olmalı.
  func testAccentColorAssetMatchesBrandToken() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("RDYonetim/Assets.xcassets/AccentColor.colorset/Contents.json")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let colors = json["colors"] as! [[String: Any]]
    func hex(_ entry: [String: Any]) -> UInt32 {
      let c = (entry["color"] as! [String: Any])["components"] as! [String: String]
      func v(_ k: String) -> UInt32 {
        let raw = c[k]!
        return raw.hasPrefix("0x") ? UInt32(raw.dropFirst(2), radix: 16)! : UInt32((Double(raw)! * 255).rounded())
      }
      return v("red") << 16 | v("green") << 8 | v("blue")
    }
    let light = colors.first { $0["appearances"] == nil }!
    let dark = colors.first { $0["appearances"] != nil }!
    XCTAssertEqual(RGB(hex(light)), Palette.brandText.light)
    XCTAssertEqual(RGB(hex(dark)), Palette.brandText.dark)
  }
}

/// Ürün kuralı: ana sayfada para tutarı, kasa veya banka bakiyesi gösterilmez.
final class HomeScreenRuleTests: XCTestCase {
  func testHomeScreenShowsNoMoney() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("RDYonetim/Home/HomeView.swift")
    // Yorum satırları hariç kod.
    let code = try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    for forbidden in ["RDAmount", "Money.format", "balance", "Balance", "cari_balances", "kasa", "banka"] {
      XCTAssertFalse(code.contains(forbidden), "Ana sayfa kodunda yasaklı ifade: \(forbidden)")
    }
  }
}
