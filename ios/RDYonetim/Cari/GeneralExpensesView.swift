import RDCore
import RDDesign
import SwiftUI

/// Projeye bağlı olmayan şirket genel giderleri (merkez ofis, araçlar...).
struct GeneralExpensesView: View {
  let app: AppModel
  @State private var model: GeneralExpensesViewModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: GeneralExpensesViewModel(repositories: app.repositories))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.costCenters.isEmpty {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      ForEach(model.costCenters) { center in
        Section {
          let balances = model.balances(for: center)
          if balances.isEmpty {
            Text("Bu merkezde henüz hareket yok.").foregroundStyle(RDColor.textSecondary)
          }
          ForEach(balances, id: \.cariAccountId) { balance in
            if let account = model.accounts[balance.cariAccountId] {
              NavigationLink(value: AppRoute.cari(account)) {
                RDRow(title: account.title, subtitle: account.type.title) {
                  RDAmount(amount: balance.balanceTry, showsSide: true).font(RDFont.secondary.weight(.semibold))
                }
              }
            }
          }
        } header: {
          HStack(spacing: .rdS) {
            Text(center.name)
            if center.isDemo { RDDemoBadge() }
            if !center.isActive { RDStatusBadge(text: "Pasif") }
          }
        } footer: {
          Text("Bu merkeze yazılan toplam: \(Money.format(model.totalAlacak(for: center)))")
        }
        .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .rdContentState(isLoading: model.isLoading, isEmpty: model.costCenters.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Masraf merkezi yok", message: "Genel gider merkezlerini yönetici tanımlar.",
                                  symbol: AppModule.genelGider.symbol),
                    retry: { Task { await model.load() } })
    .navigationTitle("Genel giderler")
    .refreshable { await model.load() }
    .task { await model.load() }
  }
}
