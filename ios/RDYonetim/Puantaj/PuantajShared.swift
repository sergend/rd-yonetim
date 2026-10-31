import RDCore
import RDDesign
import SwiftUI

// Puantaj ekranlarının ortak parçaları. Renk tek başına anlam taşımaz: her
// durumun kısa harfi ve erişilebilirlik metni vardır.

extension CalendarDate {
  /// "5 Ekim Pazartesi" (erişilebilirlik ve sayfa başlıkları için).
  var longDisplay: String {
    date().formatted(.dateTime.day().month(.wide).weekday(.wide).locale(Money.locale))
  }
}

/// Seçili hücre (kişi + gün).
struct PuantajCellSelection: Identifiable, Hashable {
  let personnelId: UUID
  let day: CalendarDate
  var id: PuantajCellKey { PuantajCellKey(personnelId, day) }
}

/// Tablo hücresinin içeriği: durum harfi, fazla mesai işareti, boş/görevsiz gün.
struct PuantajCellLabel: View {
  let entry: PuantajEntry?
  let isAssigned: Bool
  var isToday = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if let entry {
          Text(entry.status.shortLabel)
            .font(.caption.weight(.bold))
            .foregroundStyle(RDColor.tone(entry.status.tone))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RDColor.tone(entry.status.tone).opacity(0.14))
        } else if isAssigned {
          Text("·")
            .font(.caption.weight(.bold))
            .foregroundStyle(RDColor.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          // Görevli olmadığı gün: boş ve soluk.
          Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RDColor.separator.opacity(0.35))
        }
      }
      if let entry, entry.hasOvertime {
        Circle()
          .fill(entry.isOvertimeApproved ? RDColor.tone(.success) : RDColor.tone(.warning))
          .frame(width: 6, height: 6)
          .padding(3)
      }
    }
    .overlay {
      if isToday { Rectangle().stroke(RDColor.brandText, lineWidth: 1.5) }
    }
  }
}

enum PuantajText {
  static func accessibility(name: String, day: CalendarDate, entry: PuantajEntry?, isAssigned: Bool) -> String {
    let date = day.longDisplay
    guard let entry else {
      return isAssigned ? "\(name), \(date): henüz işlenmedi" : "\(name), \(date): projede görevli değil"
    }
    var text = "\(name), \(date): \(entry.status.title)"
    if entry.hasOvertime {
      text += ", fazla mesai \(OvertimeInput.format(entry.overtimeHours)) saat"
      text += entry.isOvertimeApproved ? ", onaylı" : ", onay bekliyor"
    }
    if let note = entry.note { text += ", not: \(note)" }
    return text
  }
}

/// Durum lejantı (tablonun altında ve özet ekranında).
struct PuantajLegend: View {
  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: .rdS) {
      ForEach(PuantajStatus.allCases) { status in
        HStack(spacing: .rdS) {
          Text(status.shortLabel)
            .font(.caption.weight(.bold))
            .foregroundStyle(RDColor.tone(status.tone))
            .frame(minWidth: 28, minHeight: 24)
            .background(RDColor.tone(status.tone).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
          Text(status.title).font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
      }
      HStack(spacing: .rdS) {
        Text("·").font(.caption.weight(.bold)).frame(minWidth: 28, minHeight: 24)
        Text("Henüz işlenmedi (devamsızlık sayılmaz)").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

/// Ay geçişi: ‹ Ekim 2026 › ve ay durumu.
struct PuantajMonthBar: View {
  let month: PuantajMonth
  let status: PuantajPeriodStatus
  var revision = 0
  let onPrevious: () -> Void
  let onNext: () -> Void

  var body: some View {
    HStack(spacing: .rdS) {
      Button(action: onPrevious) {
        Image(systemName: "chevron.left").frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
      }
      .accessibilityLabel("Önceki ay")
      Spacer(minLength: 0)
      VStack(spacing: 2) {
        Text(month.title).font(RDFont.rowTitle).foregroundStyle(RDColor.textPrimary)
        HStack(spacing: .rdXS) {
          RDStatusBadge(text: status.title, tone: status.tone)
          if revision > 0 { RDStatusBadge(text: "Revizyon \(revision)") }
        }
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 0)
      Button(action: onNext) {
        Image(systemName: "chevron.right").frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
      }
      .accessibilityLabel("Sonraki ay")
    }
    .foregroundStyle(RDColor.brandText)
  }
}

/// Kısa bilgi bandı (son işlemin sonucu).
struct PuantajNotice: View {
  let text: String
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: .rdS) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(RDColor.tone(.success))
      Text(text).font(RDFont.secondary).foregroundStyle(RDColor.textPrimary)
      Spacer(minLength: 0)
      Button("Kapat", action: onDismiss).font(RDFont.secondary)
    }
    .padding(.rdM)
    .background(RDColor.surface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).stroke(RDColor.separator))
  }
}
