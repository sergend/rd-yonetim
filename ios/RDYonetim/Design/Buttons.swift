import RDDesign
import SwiftUI

/// Birincil eylem: kırmızı dolgu, beyaz metin. Bir ekranda tek birincil eylem olur.
struct RDPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(RDFont.button)
      .foregroundStyle(RDColor.onBrand)
      .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight)
      .padding(.horizontal, .rdL)
      .background(RDColor.brand.opacity(isEnabled ? 1 : 0.4),
                  in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
      .opacity(configuration.isPressed ? 0.85 : 1)
      .contentShape(Rectangle())
  }
}

/// İkincil eylem: nötr yüzey, koyu metin, ince çerçeve.
struct RDSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(RDFont.button)
      .foregroundStyle(RDColor.textPrimary)
      .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight)
      .padding(.horizontal, .rdL)
      .background(RDColor.surface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).stroke(RDColor.separator))
      .opacity(configuration.isPressed ? 0.7 : 1)
      .contentShape(Rectangle())
  }
}

extension ButtonStyle where Self == RDPrimaryButtonStyle {
  static var rdPrimary: RDPrimaryButtonStyle { RDPrimaryButtonStyle() }
}

extension ButtonStyle where Self == RDSecondaryButtonStyle {
  static var rdSecondary: RDSecondaryButtonStyle { RDSecondaryButtonStyle() }
}

/// İşlem sürerken gösterge taşıyan birincil buton.
struct RDPrimaryButton: View {
  let title: String
  var isLoading = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Text(title).opacity(isLoading ? 0 : 1)
        if isLoading { ProgressView().tint(RDColor.onBrand) }
      }
    }
    .buttonStyle(.rdPrimary)
    .accessibilityLabel(isLoading ? "\(title), işleniyor" : title)
  }
}
