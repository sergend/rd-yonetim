import RDCore
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
      if let error = model.errorMessage {
        ErrorBanner(message: error).listRowBackground(Color.clear)
      }
      ForEach(model.costCenters) { center in
        Section {
          let balances = model.balances(for: center)
          if balances.isEmpty {
            Text("Bu merkezde henüz hareket yok.").foregroundStyle(.secondary)
          }
          ForEach(balances, id: \.cariAccountId) { balance in
            if let account = model.accounts[balance.cariAccountId] {
              NavigationLink(value: AppRoute.cari(account)) {
                HStack {
                  Text(account.title).lineLimit(1)
                  Spacer()
                  AmountText(amount: balance.balanceTry, colored: true).font(.callout)
                }
              }
            }
          }
        } header: {
          HStack(spacing: 6) {
            Text(center.name)
            if center.isDemo { DemoBadge() }
            if !center.isActive { StatusBadge(text: "Pasif") }
          }
        } footer: {
          Text("Bu merkeze yazılan toplam: \(Money.format(model.totalAlacak(for: center)))")
        }
      }
    }
    .overlay {
      if model.costCenters.isEmpty && !model.isLoading {
        ContentUnavailableView("Masraf merkezi yok", systemImage: AppModule.genelGider.symbol,
                               description: Text("Genel gider merkezlerini yönetici tanımlar."))
      }
    }
    .navigationTitle("Şirket genel giderleri")
    .refreshable { await model.load() }
    .task { await model.load() }
  }
}
