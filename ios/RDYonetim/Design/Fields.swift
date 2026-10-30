import RDDesign
import SwiftUI

/// Etiketli giriş alanı (form dışı ekranlar için, ör. giriş). Etiket alanın
/// üstündedir, yer tutucu etiketin yerine geçmez; hata alanın altında görünür.
struct RDTextField: View {
  let label: String
  @Binding var text: String
  var prompt: String?
  var isSecure = false
  var error: String?
  /// Klavye odağı (ör. "İleri" ile sonraki alana geçmek için).
  var focus: FocusState<Bool>.Binding?

  var body: some View {
    VStack(alignment: .leading, spacing: .rdXS) {
      Text(label)
        .font(RDFont.secondary.weight(.medium))
        .foregroundStyle(RDColor.textSecondary)
        .accessibilityHidden(true)
      Group {
        if isSecure {
          SecureField(label, text: $text, prompt: prompt.map { Text($0) })
        } else {
          TextField(label, text: $text, prompt: prompt.map { Text($0) })
        }
      }
      .font(RDFont.body)
      .foregroundStyle(RDColor.textPrimary)
      .modifier(OptionalFocus(focus: focus))
      .padding(.horizontal, .rdM)
      .frame(minHeight: Metrics.buttonHeight)
      .background(RDColor.surface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .stroke(error == nil ? RDColor.separator : RDColor.tone(.danger), lineWidth: 1)
      )
      if let error {
        Text(error)
          .font(RDFont.caption)
          .foregroundStyle(RDColor.tone(.danger))
      }
    }
  }
}

private struct OptionalFocus: ViewModifier {
  let focus: FocusState<Bool>.Binding?

  func body(content: Content) -> some View {
    if let focus { content.focused(focus) } else { content }
  }
}

/// Form içinde kaydetmeyi engelleyen sorun ya da sunucu hatası.
struct RDFormMessage: View {
  let message: String?

  var body: some View {
    if let message {
      Section {
        Label(message, systemImage: "exclamationmark.circle")
          .font(RDFont.secondary)
          .foregroundStyle(RDColor.tone(.danger))
      }
      .rdRowBackground()
    }
  }
}
