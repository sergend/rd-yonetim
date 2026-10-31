import RDCore
import RDDesign
import SwiftUI

/// Hızlı gider/gelir girişi. Üstte zorunlu alanlar (tutar, kategori, açıklama,
/// kapsam); ayrıntılar (vade, cari, fatura, döviz, not) altta ve isteğe bağlıdır.
/// Fatura fotoğrafı/PDF yükleme Aşama 6'dadır; burada yalnızca belge referansı yazılır.
struct FinanceDocumentFormView: View {
  @State private var model: FinanceDocumentFormViewModel
  @State private var showDetails: Bool
  @State private var savedCount = 0
  @FocusState private var amountFocused: Bool
  @Environment(\.dismiss) private var dismiss
  private let onSave: (FinanceDocument) -> Void

  init(kind: FinanceDocKind, editing: FinanceDocument?, preselectedProject: UUID?, app: AppModel,
       onSave: @escaping (FinanceDocument) -> Void) {
    _model = State(initialValue: FinanceDocumentFormViewModel(
      kind: kind, editing: editing, access: app.access, projects: app.projects, costCenters: app.costCenters,
      preselectedProject: preselectedProject, repositories: app.repositories))
    _showDetails = State(initialValue: editing.map {
      $0.cariAccountId != nil || $0.invoiceNo != nil || $0.currency != "TRY" || $0.dueDate != $0.documentDate
        || $0.notes != nil || $0.documentRef != nil
    } ?? false)
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        if savedCount > 0 {
          Section {
            Label("\(savedCount) kayıt onaya gönderildi.", systemImage: "checkmark.circle")
              .foregroundStyle(RDColor.tone(.success))
          }
          .rdRowBackground()
        }
        essentials
        scopeSection
        settledSection
        Section {
          DisclosureGroup("Vade, cari, fatura ve döviz", isExpanded: $showDetails) { details }
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage ?? (model.amountText.isEmpty ? nil : model.validationMessage))
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle(model.formTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") { Task { await save(next: false) } }
            .fontWeight(.semibold)
            .disabled(!model.canSave)
        }
        if model.editing == nil {
          ToolbarItem(placement: .bottomBar) {
            Button("Kaydet ve yeni") { Task { await save(next: true) } }
              .disabled(!model.canSave)
          }
        }
      }
      .task {
        await model.loadLookups()
        if model.editing == nil { amountFocused = true }
      }
      .interactiveDismissDisabled(model.isSaving)
    }
  }

  private func save(next: Bool) async {
    guard let saved = await model.save() else { return }
    onSave(saved)
    if next {
      savedCount += 1
      model.resetForNext()
      amountFocused = true
    } else {
      dismiss()
    }
  }

  // MARK: Bölümler

  private var essentials: some View {
    Section {
      TextField(model.currency == "TRY" ? "Tutar (₺)" : "Tutar (\(model.currency))", text: $model.amountText)
        .keyboardType(.decimalPad)
        .font(RDFont.metric)
        .monospacedDigit()
        .focused($amountFocused)
      Picker("Kategori", selection: $model.categoryId) {
        Text("Seçin").tag(UUID?.none)
        ForEach(model.activeCategories) { Text($0.name).tag(Optional($0.id)) }
      }
      TextField(model.kind == .gider ? "Ne alındı / ne için ödendi?" : "Gelirin açıklaması",
                text: $model.descriptionText, axis: .vertical)
        .lineLimit(1...3)
      DatePicker("Tarih", selection: $model.documentDate, in: ...Date(), displayedComponents: .date)
    } footer: {
      if model.activeCategories.isEmpty {
        Text("Tanımlı kategori yok. Kategori yönetimi yetkisi olan bir kullanıcı kategori eklemeli.")
      }
    }
    .rdRowBackground()
  }

  @ViewBuilder private var scopeSection: some View {
    Section {
      if !model.projects.isEmpty && !model.costCenters.isEmpty {
        Picker("Bağlı olduğu yer", selection: $model.scopeChoice) {
          Text("Proje").tag(FinanceDocumentFormViewModel.ScopeChoice.project)
          Text("Şirket geneli").tag(FinanceDocumentFormViewModel.ScopeChoice.costCenter)
        }
        .pickerStyle(.segmented)
      }
      switch model.scopeChoice {
      case .project:
        Picker("Proje", selection: $model.projectId) {
          Text("Seçin").tag(UUID?.none)
          ForEach(model.projects) { project in
            Text(project.isDemo ? "\(project.name) (DEMO)" : project.name).tag(Optional(project.id))
          }
        }
      case .costCenter:
        Picker("Masraf merkezi", selection: $model.costCenterId) {
          Text("Seçin").tag(UUID?.none)
          ForEach(model.costCenters) { center in
            Text(center.isDemo ? "\(center.name) (DEMO)" : center.name).tag(Optional(center.id))
          }
        }
      }
    } footer: {
      if model.projects.isEmpty && model.costCenters.isEmpty {
        Text("Kayıt girebileceğiniz proje veya masraf merkezi yok.")
      }
    }
    .rdRowBackground()
  }

  private var settledSection: some View {
    Section {
      Toggle(model.settledLabel, isOn: $model.reportedSettled)
      if model.reportedSettled {
        Picker(model.kind == .gider ? "Ödeme kaynağı" : "Tahsilat kaynağı", selection: $model.reportedSourceId) {
          Text("Seçin").tag(UUID?.none)
          ForEach(model.paymentSources) { Text($0.name).tag(Optional($0.id)) }
        }
        TextField(model.kind == .gider ? "Ödeyen kişi (isteğe bağlı)" : "Tahsil eden (isteğe bağlı)",
                  text: $model.reportedBy)
      }
    } footer: {
      Text(model.kind == .gider
           ? "Peşin ödenmişse işaretleyin; onaylandığında ödeme kaydı oluşur. Kişisel kartla ödeme gösterilir ama kart sahibine otomatik borç yazılmaz."
           : "Peşin tahsil edildiyse işaretleyin; onaylandığında tahsilat kaydı oluşur.")
    }
    .rdRowBackground()
  }

  @ViewBuilder private var details: some View {
    Toggle("Vadeli", isOn: $model.hasDueDate)
    if model.hasDueDate {
      DatePicker("Vade tarihi", selection: $model.dueDate, in: model.documentDate..., displayedComponents: .date)
    }
    if model.canPickCari {
      Picker(model.kind.counterpartyTitle, selection: $model.cariAccountId) {
        Text("Cari bağlantısız").tag(UUID?.none)
        ForEach(model.selectableAccounts) { Text($0.title).tag(Optional($0.id)) }
      }
    }
    TextField("Fatura no", text: $model.invoiceNo)
      .textInputAutocapitalization(.characters)
    TextField("Belge referansı (fiş no, dosya adı)", text: $model.documentRef)
    Picker("Para birimi", selection: $model.currency) {
      ForEach(FinanceDocumentFormViewModel.currencies, id: \.self) { Text($0).tag($0) }
    }
    ExchangeRateField(currency: model.currency, text: $model.rateText)
    TextField("Not", text: $model.notes, axis: .vertical)
      .lineLimit(1...4)
    if model.cariAccountId != nil {
      Text("Cari bağlantılı belge onaylandığında carinin defterine bir kez işlenir.")
        .font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
    }
  }
}
