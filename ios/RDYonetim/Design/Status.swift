import RDCore
import RDDesign
import SwiftUI

/// Durum etiketi. Renk tek başına anlam taşımaz; metin her zaman yazılır.
struct RDStatusBadge: View {
  let text: String
  var tone: StatusTone = .neutral

  var body: some View {
    Text(text)
      .font(RDFont.badge)
      .lineLimit(1)
      .padding(.horizontal, .rdS)
      .padding(.vertical, 3)
      .foregroundStyle(RDColor.tone(tone))
      .background(RDColor.tone(tone).opacity(0.12), in: Capsule())
  }
}

/// Demo kayıt işareti: demo veri gerçek veri gibi görünmez.
struct RDDemoBadge: View {
  var body: some View {
    RDStatusBadge(text: "DEMO", tone: .warning)
      .accessibilityLabel("Demo kayıt, gerçek veri değil")
  }
}

/// Yükleniyor, boş ve hata durumları için tek bileşen.
struct RDStateView: View {
  enum Kind {
    case loading
    case empty(title: String, message: String, symbol: String)
    case error(String, retry: (() -> Void)?)
  }

  let kind: Kind

  var body: some View {
    switch kind {
    case .loading:
      ProgressView("Yükleniyor…")
        .font(RDFont.secondary)
        .foregroundStyle(RDColor.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .empty(let title, let message, let symbol):
      ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    case .error(let message, let retry):
      ContentUnavailableView {
        Label("Yüklenemedi", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        if let retry {
          Button("Tekrar dene", action: retry)
            .buttonStyle(.rdSecondary)
            .frame(maxWidth: 220)
        }
      }
    }
  }
}

/// İçerik varken oluşan hata (ör. yenileme başarısız).
struct RDErrorBanner: View {
  let message: String?

  var body: some View {
    if let message {
      Label(message, systemImage: "exclamationmark.circle")
        .font(RDFont.secondary)
        .foregroundStyle(RDColor.tone(.danger))
        .padding(.rdM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RDColor.tone(.danger).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }
  }
}

extension View {
  /// Liste ekranları için ortak durum katmanı: içerik yokken ilk yüklemede
  /// gösterge, hata varsa "Tekrar dene", yoksa boş durum. İçerik varken hata
  /// listenin üstünde `RDErrorBanner` ile gösterilir.
  func rdContentState(isLoading: Bool, isEmpty: Bool, error: String?,
                      empty: RDStateView.Kind, retry: @escaping () -> Void) -> some View {
    overlay {
      if isEmpty {
        if isLoading {
          RDStateView(kind: .loading)
        } else if let error {
          RDStateView(kind: .error(error, retry: retry))
        } else {
          RDStateView(kind: empty)
        }
      }
    }
  }
}

/// TL tutar. Yalnızca finans ekranlarında kullanılır; ana ekranda kullanılmaz.
struct RDAmount: View {
  let amount: Decimal
  var currency = "TRY"
  /// Bakiye yönünü renkle ve erişilebilirlik metniyle belirtir.
  var showsSide = false

  var body: some View {
    let text = Money.format(amount, currency: currency)
    Text(text)
      .monospacedDigit()
      .foregroundStyle(showsSide ? RDColor.tone(BalanceSide(amount).tone) : RDColor.textPrimary)
      .accessibilityLabel(showsSide ? "\(text), \(BalanceSide(amount).title)" : text)
  }
}

extension CalendarDate {
  /// "5 Eki 2026"
  var display: String {
    date().formatted(.dateTime.day().month(.abbreviated).year().locale(Money.locale))
  }
}
