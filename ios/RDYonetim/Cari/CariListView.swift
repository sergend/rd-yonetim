import RDCore
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
      if let error = model.errorMessage {
        ErrorBanner(message: error).listRowBackground(Color.clear)
      }
      Section {
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
      }
      .onChange(of: model.typeFilter) { _, _ in Task { await model.load() } }
      .onChange(of: model.filter) { _, _ in Task { await model.load() } }

      Section {
        ForEach(model.filtered) { account in
          NavigationLink(value: AppRoute.cari(account)) {
            CariRow(account: account, balance: model.balance(for: account), showBalance: model.canSeeBalances)
          }
        }
      } footer: {
        if model.canSeeBalances {
          Text("Bakiye = borç − alacak. Eksi bakiye, karşı tarafa borçlu olduğumuzu gösterir.")
        }
      }
    }
    .overlay {
      if model.filtered.isEmpty && !model.isLoading {
        ContentUnavailableView("Cari yok", systemImage: AppModule.cari.symbol,
                               description: Text("Filtreye uyan cari hesap bulunamadı."))
      }
    }
    .searchable(text: $model.searchText, prompt: "Unvan veya kod")
    .navigationTitle(app.projectName(model.filter.projectId) ?? "Cari hesaplar")
    .toolbar {
      if model.canCreate {
        Button("Yeni cari", systemImage: "plus") { showingForm = true }
      }
    }
    .sheet(isPresented: $showingForm) {
      CariFormView(model: CariFormViewModel(repository: app.repositories.cari)) { model.upsert($0) }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
  }
}

private struct CariRow: View {
  let account: CariAccount
  let balance: CariBalance?
  let showBalance: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(account.title).font(.body.weight(.medium)).lineLimit(1)
          if account.isDemo { DemoBadge() }
        }
        HStack(spacing: 6) {
          Text(account.code)
          Text("·")
          Text(account.type.title)
          if !account.isActive { StatusBadge(text: "Pasif") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      if showBalance {
        AmountText(amount: balance?.balanceTry ?? 0, colored: true).font(.callout)
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
        Section("Vergi") {
          TextField("VKN / TCKN", text: $model.taxNumber).keyboardType(.numberPad)
          TextField("Vergi dairesi", text: $model.taxOffice)
        }
        Section("İletişim") {
          TextField("Telefon", text: $model.phone).keyboardType(.phonePad)
          TextField("E-posta", text: $model.email)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
          TextField("Adres", text: $model.address, axis: .vertical)
          TextField("IBAN", text: $model.iban)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        }
        Section {
          TextField("Not", text: $model.notes, axis: .vertical).lineLimit(2...5)
        } footer: {
          Text("Bakiye bu formda düzenlenmez; yalnızca cari hareketlerden hesaplanır.")
        }
        if let message = model.errorMessage ?? model.validationMessage {
          Section { Text(message).foregroundStyle(.red).font(.callout) }
        }
      }
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
          .disabled(!model.canSave)
        }
      }
      .interactiveDismissDisabled(model.isSaving)
    }
  }
}
