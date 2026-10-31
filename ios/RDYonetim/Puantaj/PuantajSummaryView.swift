import RDCore
import RDDesign
import SwiftUI

/// Aylık puantaj özeti: kişi, ekip ve proje bazında gün sayımları.
/// Hiçbir para tutarı göstermez; kategoriler ayrı ayrı sayılır ve tek bir
/// toplamda birleştirilmez.
struct PuantajSummaryView: View {
  enum Scope: String, CaseIterable, Identifiable {
    case kisi = "Kişi", ekip = "Ekip", proje = "Proje"
    var id: String { rawValue }
  }

  let model: PuantajViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var scope: Scope = .kisi

  var body: some View {
    NavigationStack {
      List {
        Section {
          Picker("Özet", selection: $scope) {
            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
        } footer: {
          Text("\(model.grid.month.title) · \(model.status.title). Puantaj çalışma bilgisidir; ücret veya borç hesaplanmaz.")
        }
        .rdRowBackground()

        switch scope {
        case .kisi: peopleSection
        case .ekip: crewsSection
        case .proje: projectSection
        }

        Section("Sayım tanımları") {
          definitions
        }
        .rdRowBackground()

        Section("Durumlar") {
          PuantajLegend().padding(.vertical, .rdXS)
        }
        .rdRowBackground()
      }
      .listStyle(.insetGrouped)
      .rdScreen()
      .navigationTitle("Aylık özet")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: UUID.self) { id in
        if let row = model.grid.row(id) {
          PuantajPersonSummaryView(row: row, summary: model.grid.summary(for: id),
                                   unprocessed: model.grid.unprocessedDays(for: row, today: model.todayValue))
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
      }
    }
  }

  // MARK: Bölümler

  @ViewBuilder private var peopleSection: some View {
    Section {
      if model.visibleRows.isEmpty {
        Text("Bu ay görevli kişi yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.visibleRows) { row in
        let summary = model.grid.summary(for: row.personnelId)
        NavigationLink(value: row.personnelId) {
          RDRow(title: row.name, subtitle: PuantajSummaryText.short(summary)) {
            Text(PuantajSummaryText.days(summary.workEquivalent))
              .font(RDFont.rowTitle)
              .monospacedDigit()
              .foregroundStyle(RDColor.textPrimary)
          }
        }
        .accessibilityLabel("\(row.name), \(PuantajSummaryText.long(summary))")
      }
    } header: {
      Text(model.hasFilter ? "Kişiler (filtreli)" : "Kişiler")
    } footer: {
      Text("Sağdaki sayı fiilî çalışma günü eşdeğeridir (tam × 1 + yarım × 0,5).")
    }
    .rdRowBackground()
  }

  @ViewBuilder private var crewsSection: some View {
    let groups = model.grid.crewSummaries
    if groups.isEmpty {
      Section { Text("Bu ay kayıt yok.").foregroundStyle(RDColor.textSecondary) }.rdRowBackground()
    }
    ForEach(groups) { group in
      Section {
        PuantajMetricRows(summary: group.summary)
      } header: {
        Text("\(group.name) · \(group.people) kişi")
      }
      .rdRowBackground()
    }
    if !groups.isEmpty {
      Section {
        EmptyView()
      } footer: {
        Text("Kayıt, girildiği gün kişinin bağlı olduğu ekibe sayılır. Ay içinde ekip değiştiren kişi iki ekipte de görünebilir.")
      }
    }
  }

  @ViewBuilder private var projectSection: some View {
    Section {
      PuantajMetricRows(summary: model.grid.projectSummary)
    } header: {
      Text("\(model.grid.rows.count) kişi")
    } footer: {
      Text("Proje özeti filtreden bağımsızdır ve ayın tüm kayıtlarını içerir.")
    }
    .rdRowBackground()
  }

  private var definitions: some View {
    VStack(alignment: .leading, spacing: .rdS) {
      definition("Fiilî çalışma", "Tam gün 1, yarım gün 0,5 sayılır. İzin, rapor ve resmî tatil eklenmez.")
      definition("Devamsız", "Yalnızca \"Çalışmadı\" işaretlenen günler. Girilmemiş gün devamsızlık değildir.")
      definition("İzin, rapor, tatil", "Ayrı ayrı sayılır; çalışılan güne veya birbirine eklenmez.")
      definition("Fazla mesai", "Saat olarak toplanır; onaylı saatler ayrıca gösterilir. Ücret hesaplanmaz.")
      definition("Onay", "Hakedişe yalnızca onaylanmış veya kilitlenmiş ayın kayıtları kaynak olacaktır.")
    }
    .padding(.vertical, .rdXS)
  }

  private func definition(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(RDFont.secondary.weight(.semibold)).foregroundStyle(RDColor.textPrimary)
      Text(text).font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Bir kişinin aylık sayımları.
struct PuantajPersonSummaryView: View {
  let row: PuantajRow
  let summary: PuantajSummary
  let unprocessed: Int

  var body: some View {
    List {
      Section {
        PuantajMetricRows(summary: summary)
      } header: {
        Text(row.groupName)
      } footer: {
        if unprocessed > 0 {
          Text("Görevli olduğu \(unprocessed) gün henüz işlenmedi. Bu günler hiçbir sayıma girmez.")
        }
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(row.name)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Özet sayımlarının satırları. Her satır tek bir kategoridir.
struct PuantajMetricRows: View {
  let summary: PuantajSummary

  var body: some View {
    RDInfoRow(label: "Tam gün", value: "\(summary.fullDays)")
    RDInfoRow(label: "Yarım gün", value: "\(summary.halfDays)")
    RDInfoRow(label: "Fiilî çalışma eşdeğeri", value: PuantajSummaryText.days(summary.workEquivalent) + " gün")
    RDInfoRow(label: "Devamsız (çalışmadı)", value: "\(summary.absentDays)")
    RDInfoRow(label: "Ücretli izin", value: "\(summary.paidLeaveDays)")
    RDInfoRow(label: "Ücretsiz izin", value: "\(summary.unpaidLeaveDays)")
    RDInfoRow(label: "Raporlu", value: "\(summary.sickDays)")
    RDInfoRow(label: "Resmî tatil", value: "\(summary.publicHolidayDays)")
    RDInfoRow(label: "Fazla mesai", value: "\(OvertimeInput.format(summary.overtimeHours)) saat")
    RDInfoRow(label: "Onaylı fazla mesai", value: "\(OvertimeInput.format(summary.approvedOvertimeHours)) saat")
    RDInfoRow(label: "Kayıtlı gün", value: "\(summary.recordedDays)")
  }
}

enum PuantajSummaryText {
  static func days(_ value: Decimal) -> String { OvertimeInput.format(value) }

  static func short(_ summary: PuantajSummary) -> String {
    var parts = ["\(summary.fullDays) tam", "\(summary.halfDays) yarım"]
    if summary.absentDays > 0 { parts.append("\(summary.absentDays) devamsız") }
    if summary.paidLeaveDays > 0 { parts.append("\(summary.paidLeaveDays) ücretli izin") }
    if summary.unpaidLeaveDays > 0 { parts.append("\(summary.unpaidLeaveDays) ücretsiz izin") }
    if summary.sickDays > 0 { parts.append("\(summary.sickDays) rapor") }
    if summary.overtimeHours > 0 { parts.append("FM \(OvertimeInput.format(summary.overtimeHours)) sa") }
    return parts.joined(separator: " · ")
  }

  static func long(_ summary: PuantajSummary) -> String {
    "fiilî çalışma \(days(summary.workEquivalent)) gün, \(summary.fullDays) tam, \(summary.halfDays) yarım, "
      + "\(summary.absentDays) devamsız, \(summary.paidLeaveDays) ücretli izin, \(summary.unpaidLeaveDays) ücretsiz izin, "
      + "\(summary.sickDays) raporlu, \(summary.publicHolidayDays) resmî tatil, fazla mesai \(OvertimeInput.format(summary.overtimeHours)) saat"
  }
}
