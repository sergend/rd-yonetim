import RDCore
import RDDesign
import SwiftUI

// Ana sayfa özet bölümleri: bu ayın maliyeti, bekleyen ödemeler, açık hakedişler,
// yaklaşan ödemeler. Tutarlar onaylı gider ve hakediş kayıtlarından gelir; kasa
// veya banka bakiyesi yoktur.

/// Ana sayfada kuruşsuz kısa tutar: "1.284.500 ₺".
func rdWholeMoney(_ amount: Decimal) -> String {
  let formatter = NumberFormatter()
  formatter.locale = Money.locale
  formatter.numberStyle = .decimal
  formatter.maximumFractionDigits = 0
  formatter.roundingMode = .halfUp
  return "\(formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)") ₺"
}

/// Kırmızı "Bu ayın maliyeti" kartı: ay seçimi, toplam, değişim ve kategori dağılımı.
struct MonthlyCostCard: View {
  let model: HomeDashboardViewModel

  private let shades: [Double] = [1, 0.72, 0.48, 0.28]

  var body: some View {
    VStack(alignment: .leading, spacing: .rdM) {
      HStack {
        Button { Task { await model.showPreviousMonth() } } label: {
          Image(systemName: "chevron.left").frame(width: 32, height: 32)
        }
        .accessibilityLabel("Önceki ay")
        Text(model.month.title)
          .font(RDFont.secondary.weight(.semibold))
          .frame(maxWidth: .infinity)
        Button { Task { await model.showNextMonth() } } label: {
          Image(systemName: "chevron.right").frame(width: 32, height: 32)
        }
        .disabled(model.isCurrentMonth)
        .opacity(model.isCurrentMonth ? 0.4 : 1)
        .accessibilityLabel("Sonraki ay")
      }
      .buttonStyle(.plain)

      VStack(alignment: .leading, spacing: .rdXS) {
        HStack {
          Text(model.isCurrentMonth ? "Bu ayın maliyeti" : "Ayın maliyeti")
            .font(RDFont.secondary.weight(.semibold))
            .opacity(0.9)
          Spacer()
          if let change = model.changePercent {
            Text("Önceki aya göre \(change >= 0 ? "+" : "")%\(change)")
              .font(RDFont.badge)
              .padding(.horizontal, .rdS)
              .padding(.vertical, .rdXS)
              .background(Capsule().fill(Color.white.opacity(0.18)))
          }
        }
        Text(model.monthCost.map(rdWholeMoney) ?? "—")
          .font(.system(.largeTitle, design: .default).weight(.bold))
          .monospacedDigit()
          .minimumScaleFactor(0.6)
          .lineLimit(1)
      }

      let top = Array(model.categories.prefix(4))
      let total = model.categories.reduce(Decimal(0)) { $0 + $1.amount }
      if !top.isEmpty, total > 0 {
        GeometryReader { proxy in
          HStack(spacing: 2) {
            ForEach(Array(top.enumerated()), id: \.element.id) { index, category in
              Rectangle()
                .fill(Color.white.opacity(shades[index]))
                .frame(width: max(proxy.size.width * share(category.amount, of: total) - 2, 2))
            }
          }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityHidden(true)

        LazyVGrid(columns: [GridItem(.flexible(), spacing: .rdM), GridItem(.flexible())], alignment: .leading,
                  spacing: .rdS) {
          ForEach(top) { category in
            HStack(spacing: .rdXS) {
              Text(category.label).lineLimit(1).opacity(0.9)
              Spacer(minLength: .rdXS)
              Text(rdWholeMoney(category.amount)).fontWeight(.semibold).monospacedDigit()
            }
            .font(RDFont.caption)
          }
        }
      } else if model.monthCost != nil {
        Text("Bu ay onaylı gider yok.").font(RDFont.caption).opacity(0.9)
      }
    }
    .foregroundStyle(RDColor.onBrand)
    .padding(.vertical, .rdS)
    .accessibilityElement(children: .contain)
  }

  private func share(_ amount: Decimal, of total: Decimal) -> CGFloat {
    CGFloat((amount / total as NSDecimalNumber).doubleValue)
  }
}

/// İki küçük özet kutusu: bekleyen ödemeler ve açık hakedişler.
struct DashboardTiles: View {
  let model: HomeDashboardViewModel
  let open: (AppRoute) -> Void

  var body: some View {
    HStack(spacing: .rdM) {
      if let pending = model.pending {
        tile(symbol: "clock", tone: .warning, title: "Bekleyen ödemeler", value: rdWholeMoney(pending.total),
             detail: pending.overdueCount > 0 ? "\(pending.count) kayıt · \(pending.overdueCount) gecikmiş"
               : "\(pending.count) kayıt",
             detailTone: pending.overdueCount > 0 ? .danger : nil) { open(.payables(.gider)) }
      }
      if let count = model.openHakedisCount {
        tile(symbol: "doc.text", tone: .info, title: "Açık hakedişler", value: "\(count) adet",
             detail: "Toplam \(rdWholeMoney(model.openHakedisTotal))", detailTone: nil) { open(.hakedisList) }
      }
    }
  }

  private func tile(symbol: String, tone: StatusTone, title: String, value: String, detail: String,
                    detailTone: StatusTone?, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: .rdXS) {
        Label(title, systemImage: symbol)
          .font(RDFont.caption.weight(.semibold))
          .foregroundStyle(RDColor.textSecondary)
          .labelStyle(TintedIconLabelStyle(tint: RDColor.tone(tone)))
        Text(value)
          .font(RDFont.metric)
          .monospacedDigit()
          .foregroundStyle(RDColor.textPrimary)
          .minimumScaleFactor(0.7)
          .lineLimit(1)
        Text(detail)
          .font(RDFont.caption)
          .foregroundStyle(detailTone.map(RDColor.tone) ?? RDColor.textSecondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(CGFloat.rdL)
      .background(RoundedRectangle(cornerRadius: CGFloat(Radius.large)).fill(RDColor.surface))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct TintedIconLabelStyle: LabelStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.foregroundStyle(tint)
      configuration.title
    }
  }
}

/// Yaklaşan (ve geciken) ödeme satırı.
struct UpcomingPaymentRow: View {
  let item: HomeDashboardViewModel.UpcomingPayment
  let projectName: String?

  private static let monthShort = ["OCA", "ŞUB", "MAR", "NİS", "MAY", "HAZ", "TEM", "AĞU", "EYL", "EKİ", "KAS", "ARA"]

  var body: some View {
    HStack(spacing: .rdM) {
      VStack(spacing: 0) {
        Text("\(item.dueDate.day)").font(.subheadline.weight(.bold))
        Text(Self.monthShort[item.dueDate.month - 1]).font(.caption2.weight(.bold))
      }
      .foregroundStyle(item.isOverdue ? RDColor.tone(.danger) : RDColor.textPrimary)
      .frame(width: 44, height: 44)
      .background(RoundedRectangle(cornerRadius: 10)
        .fill((item.isOverdue ? RDColor.tone(.danger) : RDColor.textSecondary).opacity(0.12)))
      .accessibilityLabel("Vade \(item.dueDate.display)")

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).font(RDFont.rowTitle).foregroundStyle(RDColor.textPrimary).lineLimit(1)
        Text(subtitle)
          .font(RDFont.caption)
          .foregroundStyle(item.isOverdue ? RDColor.tone(.danger) : RDColor.textSecondary)
          .lineLimit(1)
      }
      Spacer(minLength: .rdS)
      Text(rdWholeMoney(item.remaining))
        .font(RDFont.rowTitle)
        .monospacedDigit()
        .foregroundStyle(RDColor.textPrimary)
    }
    .accessibilityElement(children: .combine)
  }

  private var subtitle: String {
    var parts: [String] = []
    if item.isOverdue {
      parts.append("\(item.daysOverdue) gün gecikti")
    } else {
      parts.append(item.state.title(for: .gider))
    }
    if let projectName { parts.append(projectName) }
    return parts.joined(separator: " · ")
  }
}

/// Ana sayfadaki proje satırı: durum ve proje maliyeti (gider ve hakediş ayrı).
struct HomeProjectRow: View {
  let project: Project
  let costs: ProjectCostRow?
  let openTaskCount: Int

  var body: some View {
    RDRow(symbol: "building.2", symbolTint: RDColor.brandText, title: project.name, subtitle: subtitle) {
      if project.isDemo { RDDemoBadge() }
    } trailing: {
      RDStatusBadge(text: project.status.title, tone: project.status.tone)
    }
  }

  private var subtitle: String {
    var parts: [String] = []
    if let expense = costs?.expenseAccruedTry { parts.append("Gider \(rdWholeMoney(expense))") }
    if let hakedis = costs?.hakedisAccruedTry, hakedis != 0 { parts.append("Hakediş \(rdWholeMoney(hakedis))") }
    if parts.isEmpty {
      parts.append(project.code)
      if let city = project.city { parts.append(city) }
    }
    if openTaskCount > 0 { parts.append("\(openTaskCount) açık iş") }
    return parts.joined(separator: " · ")
  }
}
