import RDCore
import RDDesign
import SwiftUI

/// Gider/gelir raporları ve proje maliyeti. Tahakkuk, ödenen ve kalan ayrı
/// sütunlardır. Proje maliyetinde gider, hakediş ve avans ayrı satırlarda
/// gösterilir ve birbirine eklenmez (hakediş iki kez sayılmaz).
struct FinanceReportView: View {
  @State private var model: FinanceReportViewModel
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: FinanceReportViewModel(access: app.access, repositories: app.repositories))
  }

  var body: some View {
    List {
      controls
      if let error = model.errorMessage {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      if model.mode == .projeMaliyeti {
        ForEach(model.projectCosts) { costSection($0) }
      } else {
        totalsSection
        rowsSection
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle("Raporlar")
    .rdContentState(isLoading: model.isLoading, isEmpty: isEmpty, error: nil,
                    empty: .empty(title: "Veri yok", message: "Seçilen dönem ve filtrede onaylı kayıt yok.",
                                  symbol: "chart.bar.doc.horizontal"),
                    retry: { Task { await model.load() } })
    .refreshable { await model.load() }
    .task { await model.load() }
    .onChange(of: model.mode) { _, _ in Task { await model.load() } }
    .onChange(of: model.group) { _, _ in Task { await model.load() } }
    .onChange(of: model.period) { _, _ in Task { await model.load() } }
    .onChange(of: model.projectId) { _, _ in Task { await model.load() } }
  }

  private var isEmpty: Bool {
    model.mode == .projeMaliyeti ? model.projectCosts.isEmpty : model.rows.isEmpty
  }

  private var controls: some View {
    Section {
      Picker("Rapor", selection: $model.mode) {
        ForEach(model.availableModes) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      if model.mode != .projeMaliyeti {
        Picker("Grupla", selection: $model.group) {
          ForEach(FinanceReportGroup.allCases) { group in
            Text(group == .kaynak && model.kind == .gelir ? "Tahsilat kaynağı" : group.title).tag(group)
          }
        }
        Picker("Dönem", selection: $model.period) {
          ForEach(FinanceDocumentListViewModel.Period.allCases) { Text($0.title).tag($0) }
        }
      }
      Picker("Proje", selection: $model.projectId) {
        Text("Tümü").tag(UUID?.none)
        ForEach(app.projects) { Text($0.name).tag(Optional($0.id)) }
      }
    }
    .rdRowBackground()
  }

  @ViewBuilder private var totalsSection: some View {
    if !model.rows.isEmpty {
      Section {
        if model.isSourceGroup {
          MoneyRow(label: model.settledTitle, amount: model.totalSettled, emphasized: true)
        } else {
          MoneyRow(label: "Tahakkuk (onaylı)", amount: model.totalAccrued, emphasized: true)
          MoneyRow(label: model.settledTitle, amount: model.totalSettled, sign: .minus)
          MoneyRow(label: model.kind == .gider ? "Bekleyen borç" : "Bekleyen alacak", amount: model.totalOpen, sign: .total)
          if model.totalOverdue > 0 {
            MoneyRow(label: "Vadesi geçmiş", amount: model.totalOverdue, detail: "Bekleyen tutarın içindedir")
          }
        }
      } header: {
        Text("Toplam (TL karşılığı)")
      } footer: {
        Text(model.isSourceGroup
             ? "Dönem içindeki \(model.settledTitle.lowercased(with: Money.locale)) kayıtları; kaynak bakiyesi değildir."
             : "Dövizli kayıtlarda kalan, belge kuruyla TL'ye çevrilir; kur farkı hesaplanmaz.")
      }
      .rdRowBackground()
    }
  }

  private var rowsSection: some View {
    Section(model.group.title) {
      ForEach(model.rows) { row in
        VStack(alignment: .leading, spacing: .rdXS) {
          HStack(alignment: .firstTextBaseline) {
            Text(row.label).font(RDFont.rowTitle).foregroundStyle(RDColor.textPrimary)
            Spacer()
            Text("\(row.documentCount) kayıt").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          }
          if model.isSourceGroup {
            MoneyRow(label: model.settledTitle, amount: row.settledTry)
          } else {
            MoneyRow(label: "Tahakkuk", amount: row.accruedTry)
            MoneyRow(label: model.settledTitle, amount: row.settledTry, sign: .minus)
            MoneyRow(label: "Kalan", amount: row.openTry, sign: .total, emphasized: true)
            if row.overdueTry > 0 {
              Text("Vadesi geçmiş: \(Money.format(row.overdueTry))")
                .font(RDFont.caption).foregroundStyle(RDColor.tone(.danger))
            }
          }
        }
        .padding(.vertical, .rdXS)
      }
    }
    .rdRowBackground()
  }

  private func costSection(_ row: ProjectCostRow) -> some View {
    Section {
      if let accrued = row.expenseAccruedTry {
        MoneyRow(label: "Gider tahakkuku", amount: accrued, detail: "Onaylı giderler (hakediş hariç)")
        MoneyRow(label: "Gider ödemesi", amount: row.expensePaidTry ?? 0, sign: .minus)
        MoneyRow(label: "Bekleyen gider borcu", amount: row.expenseOpenTry ?? 0, sign: .total)
      }
      if let hakedis = row.hakedisAccruedTry {
        MoneyRow(label: "Hakediş tahakkuku", amount: hakedis, detail: "Deftere işlenmiş hakedişler (brüt + KDV)")
        if let unposted = row.hakedisUnpostedTry, unposted > 0 {
          MoneyRow(label: "Deftere işlenmemiş onaylı hakediş", amount: unposted, detail: "Tahakkuka dahil değil")
        }
        MoneyRow(label: "Hakediş ödemesi", amount: row.hakedisPaidTry ?? 0, sign: .minus)
        MoneyRow(label: "Avanstan mahsup", amount: row.advanceDeductedTry ?? 0, sign: .minus)
        MoneyRow(label: "Verilen avans", amount: row.advancePaidTry ?? 0,
                 detail: "Ödeme değildir; hakedişlerden mahsup edilir")
      }
      if let income = row.incomeAccruedTry {
        MoneyRow(label: "Gelir tahakkuku", amount: income)
        MoneyRow(label: "Tahsil edilen", amount: row.incomeCollectedTry ?? 0, sign: .minus)
      }
      if row.expenseAccruedTry == nil && row.hakedisAccruedTry == nil && row.incomeAccruedTry == nil {
        Text("Bu projede gider, hakediş veya gelir görme yetkiniz yok.").foregroundStyle(RDColor.textSecondary)
      }
    } header: {
      Text(row.projectLabel)
    } footer: {
      Text("Gider, hakediş ve gelir ayrı gösterilir ve toplanmaz. Avans ödemesi hakediş ödemesi sayılmaz.")
    }
    .rdRowBackground()
  }
}
