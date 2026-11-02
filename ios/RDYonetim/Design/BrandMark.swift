import RDDesign
import SwiftUI
import UIKit

/// RD Projeler marka alanı: orijinal RD logosu (kırmızı R, siyah D).
///
/// Görsel setleri (`Assets.xcassets`):
/// - `RDLogo`: "PROJELER" ve "Geleceğe Değer" sloganıyla tam logo (giriş, açılış, rapor başlığı)
/// - `RDLogoWordmark`: sloganı olmayan yatay logo (ana sayfa üst bandı)
/// - `RDLogoMark`: yalnızca RD harfleri (küçük alanlar)
///
/// Logonun D harfi siyahtır; koyu temada görünmesi için logo beyaz bir zemin
/// üzerinde gösterilir (renkleri değiştirilmez). Ayrıntı: docs/brand-assets.md.
struct RDBrandMark: View {
  enum Size { case large, compact }

  var size: Size = .large

  static let appName = "RD Projeler"
  static var hasLogo: Bool { UIImage(named: "RDLogo") != nil }

  var body: some View {
    Group {
      if Self.hasLogo {
        RDLogoImage(kind: size == .large ? .full : .wordmark, height: size == .large ? 120 : 28)
      } else {
        Text(Self.appName)
          .font(size == .large ? RDFont.screenTitle : RDFont.rowTitle)
          .foregroundStyle(RDColor.textPrimary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("RD Projeler")
  }
}

/// Logo görseli; koyu temada beyaz zemin üzerinde.
struct RDLogoImage: View {
  enum Kind {
    case full, wordmark, mark

    var assetName: String {
      switch self {
      case .full: "RDLogo"
      case .wordmark: "RDLogoWordmark"
      case .mark: "RDLogoMark"
      }
    }
  }

  let kind: Kind
  var height: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Image(kind.assetName)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(height: height)
      .padding(colorScheme == .dark ? height * 0.12 : 0)
      .background {
        if colorScheme == .dark {
          RoundedRectangle(cornerRadius: CGFloat(Radius.medium)).fill(Color.white)
        }
      }
      .accessibilityLabel(kind == .full ? "RD Projeler, Geleceğe Değer" : "RD Projeler")
  }
}
