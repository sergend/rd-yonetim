import RDCore
import RDDesign
import SwiftUI

struct CariListView: View {
  let app: AppModel
  @State private var model: CariListViewModel
  @State private var showingForm = false

  init(projectId: UUID?, app: AppModel) {
    self.app = app
    let model = CariListViewModel(access: app.access, repository: app.repositories.cari)
    model.filter.projectId = projectId
    _model = State(initialValue: model)
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.accounts.isEmpty {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ForEach(model.filtered) { account in
          NavigationLink(value: AppRoute.cari(account)) {
            CariRow(account: account, balance: model.balance(for: account), showBalance: model.canSeeBalances)
          }
        }
      } header: {
        Text(filterSummary)
      } footer: {
        if model.canSeeBalances {
          Text("Bakiye = borç − alacak. Eksi bakiye, karşı tarafa borçlu olduğumuzu gösterir.")
        }
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Cari yok", message: "Filtreye uyan cari hesap bulunamadı.",
                                  symbol: AppModule.cari.symbol),
                    retry: { Task { await model.load() } })
    .onChange(of: model.typeFilter) { _, _ in Task { await model.load() } }
    .onChange(of: model.filter) { _, _ in Task { await model.load() } }
    .searchable(text: $model.searchText, prompt: "Unvan veya kod")
    .navigationTitle(app.projectName(model.filter.projectId) ?? "Cari hesaplar")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) { filterMenu }
      if model.canCreate {
        ToolbarItem(placement: .primaryAction) {
          Button("Yeni cari", systemImage: "plus") { showingForm = true }
        }
      }
    }
    .sheet(isPresented: $showingForm) {
      CariFormView(model: CariFormViewModel(repository: app.repositories.cari)) { model.upsert($0) }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
  }

  private var filterSummary: String {
    let type = model.typeFilter?.title ?? "Tüm türler"
    guard model.canSeeBalances else { return type }
    return "\(type) · \(app.projectName(model.filter.projectId) ?? "tüm projeler ve genel")"
  }

  private var filterMenu: some View {
    Menu {
      Picker("Tür", selection: $model.typeFilter) {
        Text("Tüm türler").tag(CariType?.none)
        ForEach(CariType.allCases) { Text($0.title).tag(Optional($0)) }
      }
      if model.canSeeBalances {
        Picker("Bakiye kapsamı", selection: $model.filter.projectId) {
          Text("Tüm projeler ve genel").tag(UUID?.none)
          ForEach(app.projects) { Text($0.name).tag(Optional($0.id)) }
        }
      }
    } label: {
      Label("Filtre", systemImage: "line.3.horizontal.decrease.circle")
    }
  }
}

private struct CariRow: View {
  let account: CariAccount
  let balance: CariBalance?
  let showBalance: Bool

  var body: some View {
    RDRow(title: account.title, subtitle: "\(account.code) · \(account.type.title)") {
      if account.isDemo { RDDemoBadge() }
      if !account.isActive { RDStatusBadge(text: "Pasif") }
    } trailing: {
      if showBalance {
        RDAmount(amount: balance?.balanceTry ?? 0, showsSide: true).font(RDFont.secondary.weight(.semibold))
      }
    }
  }
}

struct CariFormView: View {
  @State var model: CariFormViewModel
  let onSaved: (CariAccount) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Unvan", text: $model.title)
          Picker("Tür", selection: $model.type) {
            ForEach(CariType.allCases) { Text($0.title).tag($0) }
          }
          TextField("Kod (boş bırakılırsa otomatik)", text: $model.code)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
          Toggle("Aktif", isOn: $model.isActive)
        }
        .rdRowBackground()
        Section("Vergi") {
          TextField("VKN / TCKN", text: $model.taxNumber).keyboardType(.numberPad)
          TextField("Vergi dairesi", text: $model.taxOffice)
        }
        .rdRowBackground()
        Section("İletişim ve banka") {
          TextField("Telefon", text: $model.phone).keyboardType(.phonePad)
          TextField("E-posta", text: $model.email)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
          TextField("Adres", text: $model.address, axis: .vertical)
          TextField("IBAN", text: $model.iban)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        }
        .rdRowBackground()
        Section {
          TextField("Not", text: $model.notes, axis: .vertical).lineLimit(2...5)
        } footer: {
          Text("Bakiye bu formda düzenlenmez; yalnızca cari hareketlerden hesaplanır.")
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage ?? model.validationMessage)
      }
      .rdScreen()
      .navigationTitle(model.formTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            Task {
              if let saved = await model.save() {
                onSaved(saved)
                dismiss()
              }
            }
          }
          .fontWeight(.semibold)
          .disabled(!model.canSave)
        }
      }
      .interactiveDismissDisabled(model.isSaving)
    }
  }
}
