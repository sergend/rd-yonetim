import RDCore
import SwiftUI

/// Kurumsal, sade görünüm için ortak bileşenler. Renkler sistem renkleridir;
/// açık ve koyu mod otomatik desteklenir.
enum Theme {
  static let accent = Color.accentColor
  static let cardBackground = Color(.secondarySystemGroupedBackground)
  static let pageBackground = Color(.systemGroupedBackground)
  static let corner: CGFloat = 14
}

struct Card<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) { content }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
  }
}

struct DemoBadge: View {
  var body: some View {
    Text("DEMO")
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundStyle(.orange)
      .background(.orange.opacity(0.15), in: Capsule())
      .accessibilityLabel("Demo kayıt")
  }
}

struct StatusBadge: View {
  let text: String
  var color: Color = .secondary

  var body: some View {
    Text(text)
      .font(.caption.weight(.medium))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .foregroundStyle(color)
      .background(color.opacity(0.12), in: Capsule())
  }
}

extension ProjectStatus {
  var color: Color {
    switch self {
    case .planlama: .blue
    case .devam: .green
    case .durdu: .orange
    case .tamamlandi: .secondary
    }
  }
}

extension TaskPriority {
  var color: Color {
    switch self {
    case .dusuk: .secondary
    case .normal: .blue
    case .yuksek: .red
    }
  }
}

/// TL tutar; bakiye yönüne göre renklenir (yalnızca finans ekranlarında).
struct AmountText: View {
  let amount: Decimal
  var colored = false

  var body: some View {
    Text(Money.format(amount))
      .monospacedDigit()
      .foregroundStyle(colored ? color : .primary)
  }

  private var color: Color {
    switch BalanceSide(amount) {
    case .theyOwe: .green
    case .weOwe: .red
    case .settled: .secondary
    }
  }
}

struct ErrorBanner: View {
  let message: String?

  var body: some View {
    if let message {
      Label(message, systemImage: "exclamationmark.circle")
        .font(.callout)
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

extension CalendarDate {
  /// "5 Eki 2026"
  var display: String {
    date().formatted(.dateTime.day().month(.abbreviated).year().locale(Money.locale))
  }
}
