import RDDesign
import SwiftUI

/// Bölüm başlığı; isteğe bağlı "Tümü" bağlantısı. Liste bölüm başlığı olarak kullanılır.
struct RDSectionHeader: View {
  let title: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(RDFont.sectionTitle)
        .foregroundStyle(RDColor.textPrimary)
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .font(RDFont.secondary.weight(.semibold))
          .foregroundStyle(RDColor.brandText)
          .textCase(nil)
          .frame(minHeight: Metrics.minTouchTarget)
      }
    }
    .listRowInsets(EdgeInsets(top: .rdS, leading: 0, bottom: .rdXS, trailing: 0))
  }
}

/// Standart liste satırı: ikon (isteğe bağlı), başlık ve etiketler, alt bilgi, sağda içerik.
struct RDRow<Badges: View, Trailing: View>: View {
  var symbol: String?
  var symbolTint: Color = RDColor.textSecondary
  let title: String
  var subtitle: String?
  @ViewBuilder var badges: Badges
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: .rdM) {
      if let symbol {
        Image(systemName: symbol)
          .font(.body.weight(.semibold))
          .foregroundStyle(symbolTint)
          .frame(minWidth: 28)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        // Büyük yazı boyutlarında etiketler başlığın altına iner.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: .rdS) { titleText; badges }
          VStack(alignment: .leading, spacing: .rdXS) { titleText; HStack(spacing: .rdS) { badges } }
        }
        if let subtitle {
          Text(subtitle)
            .font(RDFont.secondary)
            .foregroundStyle(RDColor.textSecondary)
        }
      }
      Spacer(minLength: .rdS)
      trailing
    }
    .frame(minHeight: Metrics.minTouchTarget)
    .contentShape(Rectangle())
  }

  private var titleText: some View {
    Text(title)
      .font(RDFont.rowTitle)
      .foregroundStyle(RDColor.textPrimary)
  }
}

extension RDRow where Badges == EmptyView {
  init(symbol: String? = nil, symbolTint: Color = RDColor.textSecondary, title: String, subtitle: String? = nil,
       @ViewBuilder trailing: () -> Trailing) {
    self.init(symbol: symbol, symbolTint: symbolTint, title: title, subtitle: subtitle,
              badges: { EmptyView() }, trailing: trailing)
  }
}

extension RDRow where Badges == EmptyView, Trailing == EmptyView {
  init(symbol: String? = nil, symbolTint: Color = RDColor.textSecondary, title: String, subtitle: String? = nil) {
    self.init(symbol: symbol, symbolTint: symbolTint, title: title, subtitle: subtitle,
              badges: { EmptyView() }, trailing: { EmptyView() })
  }
}

/// Bilgi satırı (etiket–değer). Uzun değerler ve büyük yazı boyutunda alt alta dizilir.
struct RDInfoRow: View {
  let label: String
  let value: String
  var selectable = false

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline) {
        labelText
        Spacer(minLength: .rdM)
        valueText.multilineTextAlignment(.trailing)
      }
      VStack(alignment: .leading, spacing: 2) { labelText; valueText }
    }
    .accessibilityElement(children: .combine)
  }

  private var labelText: some View {
    Text(label).font(RDFont.secondary).foregroundStyle(RDColor.textSecondary)
  }

  @ViewBuilder private var valueText: some View {
    if selectable {
      Text(value).font(RDFont.body).foregroundStyle(RDColor.textPrimary).textSelection(.enabled)
    } else {
      Text(value).font(RDFont.body).foregroundStyle(RDColor.textPrimary)
    }
  }
}
