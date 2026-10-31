import RDCore
import RDDesign
import SwiftUI

/// Gün görünümü: seçili günde projede görevli kişiler, ekiplerine göre. Sahada
/// tek elle hızlı giriş için ay tablosunun daha okunaklı alternatifidir.
struct PuantajDayView: View {
  let model: PuantajViewModel
  @Binding var day: CalendarDate
  let onSelect: (PuantajRow) -> Void
  let onBulk: () -> Void

  private var rows: [PuantajRow] {
    model.visibleRows.filter { $0.isAssigned(on: day) || model.grid.entry($0.personnelId, day) != nil }
  }

  private var groups: [(name: String, rows: [PuantajRow])] {
    let grouped = Dictionary(grouping: rows) { $0.link(on: day)?.crewName ?? model.grid.entry($0.personnelId, day)?.crewName ?? "Doğrudan görevli" }
    return grouped.map { (name: $0.key, rows: $0.value) }
      .sorted { ($0.name == "Doğrudan görevli" ? 1 : 0, $0.name) < ($1.name == "Doğrudan görevli" ? 1 : 0, $1.name) }
  }

  var body: some View {
    List {
      Section {
        daySwitcher
        if model.canEdit && !rows.isEmpty {
          Button {
            onBulk()
          } label: {
            Label("Bu günü toplu işle veya önceki günü kopyala", systemImage: "square.grid.3x3.square")
          }
          .foregroundStyle(RDColor.brandText)
          .frame(minHeight: Metrics.minTouchTarget)
        }
      } footer: {
        Text(dayFooter)
      }
      .rdRowBackground()

      if rows.isEmpty {
        Section {
          Text("Bu gün projede görevli kişi yok.").foregroundStyle(RDColor.textSecondary)
        }
        .rdRowBackground()
      }

      ForEach(groups, id: \.name) { group in
        Section(group.name) {
          ForEach(group.rows) { row in
            let entry = model.grid.entry(row.personnelId, day)
            Button {
              onSelect(row)
            } label: {
              RDRow(title: row.name, subtitle: subtitle(row, entry)) {
                if let entry {
                  RDStatusBadge(text: entry.status.title, tone: entry.status.tone)
                } else {
                  RDStatusBadge(text: "İşlenmedi")
                }
              }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PuantajText.accessibility(name: row.name, day: day, entry: entry,
                                                          isAssigned: row.isAssigned(on: day)))
          }
        }
        .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
  }

  private var daySwitcher: some View {
    HStack {
      Button {
        day = day.adding(days: -1)
      } label: {
        Image(systemName: "chevron.left").frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
      }
      .disabled(day.day == 1)
      .accessibilityLabel("Önceki gün")
      Spacer()
      VStack(spacing: 2) {
        Text(day.longDisplay).font(RDFont.rowTitle).foregroundStyle(RDColor.textPrimary)
        if day == model.todayValue { Text("Bugün").font(RDFont.caption).foregroundStyle(RDColor.brandText) }
      }
      .accessibilityElement(children: .combine)
      Spacer()
      Button {
        day = day.adding(days: 1)
      } label: {
        Image(systemName: "chevron.right").frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
      }
      .disabled(day == model.grid.month.lastDay)
      .accessibilityLabel("Sonraki gün")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(RDColor.brandText)
  }

  private var dayFooter: String {
    let entries = rows.compactMap { model.grid.entry($0.personnelId, day) }
    let summary = PuantajSummary(entries: entries)
    let open = rows.count - entries.count
    var parts = ["\(rows.count) kişi", "\(summary.fullDays) tam", "\(summary.halfDays) yarım"]
    if open > 0 { parts.append("\(open) henüz işlenmedi") }
    return parts.joined(separator: " · ")
  }

  private func subtitle(_ row: PuantajRow, _ entry: PuantajEntry?) -> String? {
    var parts = [row.jobTitle].compactMap { $0 }
    if let entry, entry.hasOvertime {
      parts.append("Fazla mesai \(OvertimeInput.format(entry.overtimeHours)) sa" + (entry.isOvertimeApproved ? " (onaylı)" : ""))
    }
    if let note = entry?.note { parts.append(note) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
