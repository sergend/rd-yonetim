import RDCore
import RDDesign
import SwiftUI

/// Excel benzeri aylık tablo: satırlarda personel, sütunlarda ayın günleri.
/// Ad sütunu sabit kalır; günler yatay kaydırılır ve gün başlığı gövdeyle
/// birlikte kayar (iki yatay kaydırma aynı gün sütununa bağlıdır).
/// Hücre başına ağ isteği yoktur: tüm ay önceden yüklenmiştir.
struct PuantajGridView: View {
  let model: PuantajViewModel
  let rows: [PuantajRow]
  let onSelect: (PuantajRow, CalendarDate) -> Void

  @ScaledMetric(relativeTo: .caption) private var cellWidth: CGFloat = 44
  @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 48
  @ScaledMetric(relativeTo: .body) private var nameWidth: CGFloat = 128
  @ScaledMetric(relativeTo: .caption) private var headerHeight: CGFloat = 44
  @State private var leadingDay: Int?

  private var days: [CalendarDate] { model.grid.month.days }
  private var today: CalendarDate { model.todayValue }

  var body: some View {
    GeometryReader { proxy in
      // Çok büyük yazı boyutunda ad sütunu ekranın yarısını geçmez.
      let names = min(nameWidth, proxy.size.width * 0.45)
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          Text("Personel")
            .font(RDFont.caption.weight(.semibold))
            .foregroundStyle(RDColor.textSecondary)
            .frame(width: names, height: headerHeight, alignment: .leading)
            .padding(.leading, .rdS)
          ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
              ForEach(days, id: \.day) { day in
                dayHeader(day).frame(width: cellWidth, height: headerHeight).id(day.day)
              }
            }
            .scrollTargetLayout()
          }
          .scrollPosition(id: $leadingDay, anchor: .leading)
          .scrollDisabled(true)
          .accessibilityHidden(true)
        }
        .background(RDColor.surface)
        Divider()

        ScrollView(.vertical) {
          HStack(alignment: .top, spacing: 0) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(rows) { row in nameCell(row).frame(width: names, height: rowHeight, alignment: .leading) }
            }
            .frame(width: names)
            .background(RDColor.surface)
            ScrollView(.horizontal, showsIndicators: true) {
              LazyHStack(alignment: .top, spacing: 0) {
                ForEach(days, id: \.day) { day in
                  VStack(spacing: 0) {
                    ForEach(rows) { row in cell(row, day).frame(width: cellWidth, height: rowHeight) }
                  }
                  .background(day.isoWeekday == 7 ? RDColor.separator.opacity(0.18) : Color.clear)
                  .id(day.day)
                }
              }
              .scrollTargetLayout()
            }
            .scrollPosition(id: $leadingDay, anchor: .leading)
            .scrollTargetBehavior(.viewAligned)
          }
          PuantajLegend()
            .padding(.rdScreen)
        }
      }
    }
    .onAppear { scrollToToday() }
    .onChange(of: model.month) { _, _ in scrollToToday() }
  }

  private func scrollToToday() {
    leadingDay = model.grid.month.contains(today) ? max(1, today.day - 2) : 1
  }

  private func dayHeader(_ day: CalendarDate) -> some View {
    VStack(spacing: 0) {
      Text("\(day.day)").font(.caption.weight(.bold)).monospacedDigit()
      Text(day.weekdayShort).font(.caption2)
    }
    .foregroundStyle(day == today ? RDColor.brandText : day.isoWeekday == 7 ? RDColor.textSecondary : RDColor.textPrimary)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      if day == today { Rectangle().fill(RDColor.brandText).frame(height: 2) }
    }
  }

  private func nameCell(_ row: PuantajRow) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(row.name)
        .font(RDFont.secondary.weight(.semibold))
        .foregroundStyle(RDColor.textPrimary)
        .lineLimit(1)
      Text(row.changedCrewInMonth ? "\(row.groupName) · ekip değişti" : row.groupName)
        .font(.caption2)
        .foregroundStyle(RDColor.textSecondary)
        .lineLimit(1)
    }
    .padding(.horizontal, .rdS)
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityElement(children: .combine)
  }

  private func cell(_ row: PuantajRow, _ day: CalendarDate) -> some View {
    let entry = model.grid.entry(row.personnelId, day)
    let assigned = row.isAssigned(on: day)
    return Button {
      onSelect(row, day)
    } label: {
      PuantajCellLabel(entry: entry, isAssigned: assigned, isToday: day == today)
        .overlay(alignment: .bottom) { Divider() }
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(entry == nil && !assigned)
    .accessibilityLabel(PuantajText.accessibility(name: row.name, day: day, entry: entry, isAssigned: assigned))
    .accessibilityHint(model.canEdit ? "Durum seçmek için iki kez dokunun" : "")
  }
}
