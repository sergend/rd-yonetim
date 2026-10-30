import RDDesign
import SwiftUI
import UIKit

/// RD Projeler marka alanı.
///
/// Orijinal RD logosu (kırmızı R, siyah D) depoda henüz YOK. Logo
/// `Assets.xcassets/RDLogo.imageset` içine eklendiğinde burada otomatik
/// gösterilir; o zamana kadar logo taklit edilmez, yalnızca uygulama adı
/// sistem yazı tipiyle yazılır. Ayrıntı: docs/brand-assets.md.
struct RDBrandMark: View {
  enum Size { case large, compact }

  var size: Size = .large

  static let appName = "RD Projeler"
  static var hasLogo: Bool { UIImage(named: "RDLogo") != nil }

  var body: some View {
    VStack(spacing: size == .large ? .rdM : .rdXS) {
      if Self.hasLogo {
        Image("RDLogo")
          .resizable()
          .scaledToFit()
          .frame(height: size == .large ? 72 : 28)
          .accessibilityLabel("RD İnşaat logosu")
      }
      Text(Self.appName)
        .font(size == .large ? RDFont.screenTitle : RDFont.rowTitle)
        .foregroundStyle(RDColor.textPrimary)
    }
    .accessibilityElement(children: .combine)
  }
}
