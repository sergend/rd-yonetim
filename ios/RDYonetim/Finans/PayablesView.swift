import RDCore
import RDDesign
import SwiftUI

/// Bekleyen borçlar (gider) veya alacaklar (gelir): onaylı ve kalanı olan
/// belgeler vadeye göre gruplanır. Toplamlar yalnızca kalan tutarların TL
/// karşılığıdır; kasa veya banka bakiyesi değildir.
struct PayablesView: View {
  @State private var model: PayablesViewModel
  private let app: AppModel

  init(kind: FinanceDocKind, app: AppModel) {
    self.app = app
    _model = State(initialValue: PayablesViewModel(kind: kind, access: app.access, repositories: app.repositories))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.items.isEmpty {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      ForEach(PayablesViewModel.Bucket.allCases) { bucket in
        let items = model.items(in: bucket)
        if !items.isEmpty {
          Section {
            ForEach(items) { item in
              NavigationLink(value: AppRoute.financeDocument(item.document)) { row(item) }
            }
          } header: {
            HStack {
              Text(bucket.title)
              Spacer()
              Text(Money.format(model.remainingTry(in: bucket))).monospacedDigit()
            }
            .foregroundStyle(bucket == .gecikmis ? RDColor.tone(.danger) : RDColor.textSecondary)
            .accessibilityElement(children: .combine)
          }
          .rdRowBackground()
        }
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .searchable(text: $model.searchText, prompt: "Açıklama, belge no, cari")
    .navigationTitle(model.title)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Proje", selection: $model.projectId) {
            Text("Tüm projeler ve genel").tag(UUID?.none)
            ForEach(app.projects) { Text($0.name).tag(Optional($0.id)) }
          }
        } label: {
          Image(systemName: model.projectId == nil ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Proje filtresi")
      }
    }
    .rdContentState(isLoading: model.isLoading, isEmpty: model.visible.isEmpty, error: model.errorMessage,
                    empty: .empty(title: model.kind == .gider ? "Bekleyen borç yok" : "Bekleyen alacak yok",
                                  message: "Onaylı ve kalanı olan kayıtlar burada vadeye göre listelenir.",
                                  symbol: "calendar.badge.checkmark"),
                    retry: { Task { await model.load() } })
    .refreshable { await model.load() }
    .task { await model.load() }
  }

  private func row(_ item: PayablesViewModel.Item) -> some View {
    let document = item.document
    var parts = [document.documentNo, "Vade \(item.status.dueDate.display)"]
    if let cari = model.cariName(document.cariAccountId) { parts.append(cari) }
    if let scope = app.projectName(document.projectId) ?? app.costCenterName(document.costCenterId) { parts.append(scope) }
    if item.status.isOverdue { parts.append("\(item.status.daysOverdue) gün gecikti") }
    return RDRow(title: document.description, subtitle: parts.joined(separator: " · ")) {
      if document.isDemo { RDDemoBadge() }
    } trailing: {
      VStack(alignment: .trailing, spacing: 2) {
        Text(Money.format(item.status.remainingAmount, currency: document.currency))
          .font(RDFont.secondary.weight(.semibold))
          .monospacedDigit()
        if item.status.settlementState == .kismi {
          Text("/ \(Money.format(document.amount, currency: document.currency))")
            .font(RDFont.caption).foregroundStyle(RDColor.textSecondary).monospacedDigit()
        }
      }
      .accessibilityLabel("Kalan \(Money.format(item.status.remainingAmount, currency: document.currency))")
    }
  }
}
