import RDCore
import RDDesign
import SwiftUI

// MARK: - Liste

struct ContractListView: View {
  @State private var model: ContractListViewModel
  @State private var showingForm = false
  private let app: AppModel

  init(projectId: UUID?, app: AppModel) {
    self.app = app
    _model = State(initialValue: ContractListViewModel(projectId: projectId, access: app.access,
                                                       repository: app.repositories.contracts))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.contracts.isEmpty {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ForEach(model.filtered) { contract in
          NavigationLink(value: AppRoute.contract(contract)) {
            ContractRow(contract: contract, projectName: app.projectName(contract.projectId),
                        latest: model.latestHakedis[contract.id])
          }
        }
      } footer: {
        if !model.filtered.isEmpty {
          Text("Sözleşme tutarları ve hakediş ayrıntıları sözleşmenin içindedir.")
        }
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .searchable(text: $model.searchText, prompt: "Sözleşme no veya başlık")
    .navigationTitle("Taşeron sözleşmeleri")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Toggle("Kapanan ve iptalleri göster", isOn: $model.showClosed)
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filtre")
      }
      if model.canCreate {
        ToolbarItem(placement: .primaryAction) {
          Button { showingForm = true } label: { Image(systemName: "plus") }
            .accessibilityLabel("Yeni sözleşme")
        }
      }
    }
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Sözleşme yok",
                                  message: "Taşeron sözleşmesi eklemek için + düğmesini kullanın. Taşeronun cari kartı bağlı olmalı.",
                                  symbol: "doc.text"),
                    retry: { Task { await model.load() } })
    .refreshable { await model.load() }
    .task { await model.load() }
    .sheet(isPresented: $showingForm) {
      ContractFormLoader(app: app, projectId: model.projectId) { contract in model.upsert(contract) }
    }
  }
}

struct ContractRow: View {
  let contract: Contract
  let projectName: String?
  let latest: Hakedis?

  var body: some View {
    RDRow(symbol: "doc.text", symbolTint: RDColor.brandText, title: contract.title, subtitle: subtitle) {
      if contract.isDemo { RDDemoBadge() }
    } trailing: {
      RDStatusBadge(text: contract.status.title, tone: contract.status.tone)
    }
  }

  private var subtitle: String {
    var parts = [contract.contractNo]
    if let projectName { parts.append(projectName) }
    if let latest { parts.append("\(latest.hakedisNo). hakediş: \(latest.status.title.lowercased(with: Money.locale))") }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Form yükleyici (seçim listeleri)

/// Formu açmadan önce taşeron ve vergi kuralı listelerini yükler.
struct ContractFormLoader: View {
  let app: AppModel
  var projectId: UUID?
  var editing: Contract?
  var version: ContractVersion?
  var items: [ContractItem] = []
  var taxCodes: [String] = []
  var usedItemKeys: Set<UUID> = []
  let onSaved: (Contract) -> Void
  @State private var model: ContractFormViewModel?
  @State private var error: String?

  var body: some View {
    Group {
      if let model {
        ContractFormView(model: model, onSaved: onSaved)
      } else if let error {
        RDStateView(kind: .error(error, retry: { Task { await load() } }))
      } else {
        ProgressView()
      }
    }
    .task { await load() }
  }

  private func load() async {
    do {
      let subs = try await app.repositories.workforce.subcontractors()
      let rules = (try? await app.repositories.contracts.taxRules()) ?? []
      model = ContractFormViewModel(editing: editing, version: version, items: items, taxCodes: taxCodes,
                                    usedItemKeys: usedItemKeys, projectId: projectId,
                                    projects: app.projects.filter { app.access.can(.sozlesmeWrite, in: $0.id) },
                                    subcontractors: subs, taxRules: rules, repository: app.repositories.contracts)
    } catch {
      self.error = message(for: error)
    }
  }
}

// MARK: - Form

struct ContractFormView: View {
  @State var model: ContractFormViewModel
  let onSaved: (Contract) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var signedDate = Date()
  @State private var hasSignedDate = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Proje", selection: $model.projectId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(model.projects) { Text($0.name).tag(Optional($0.id)) }
          }
          .disabled(model.identityLocked)
          Picker("Taşeron", selection: $model.subcontractorId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(model.subcontractors) { Text($0.name).tag(Optional($0.id)) }
          }
          .disabled(model.identityLocked)
          TextField("Sözleşme no", text: $model.contractNo)
            .textInputAutocapitalization(.characters)
            .disabled(model.identityLocked)
          TextField("Başlık (ör. kaba inşaat işçiliği)", text: $model.title)
        } footer: {
          Text("Sözleşme taşeronun mevcut cari kartına bağlanır; yeni cari açılmaz. Listede yalnızca cari kartı bağlı taşeronlar var.")
        }
        .rdRowBackground()

        ForEach($model.items) { $item in
          Section {
            ContractItemEditor(item: $item)
          } header: {
            HStack {
              Text(item.method.title)
              Spacer()
              if !item.isUsed && model.items.count > 1 {
                Button("Kaldır", role: .destructive) { model.removeItem(item.id) }
                  .font(RDFont.caption)
                  .textCase(nil)
              }
            }
          } footer: {
            if item.isUsed { Text("Bu kalem onaylı hakedişte kullanıldı; kaldırılamaz, miktarı kullanılanın altına inemez.") }
          }
          .rdRowBackground()
        }

        Section {
          Menu {
            ForEach(ContractItemMethod.allCases) { method in
              Button(method.title) { model.addItem(method) }
            }
          } label: {
            Label("Kalem ekle", systemImage: "plus.circle")
          }
          if model.itemsTotal > 0 {
            MoneyRow(label: "Kalemlerin toplamı", amount: model.itemsTotal, currency: model.currency,
                     detail: "Günlük kalemler miktar girilmişse dahildir")
          }
        } footer: {
          Text("Karma sözleşmede farklı yöntemli kalemler birlikte olabilir. Günlük kalemler onaylı puantajdan, birim fiyatlılar onaylı imalattan, götürüler ilerleme yüzdesinden hesaplanır.")
        }
        .rdRowBackground()

        Section {
          Picker("Teminat oranı", selection: $model.retentionRateText) {
            ForEach(ContractFormViewModel.retentionPresets, id: \.self) { rate in
              Text("%" + DecimalInput.format(rate)).tag(DecimalInput.format(rate))
            }
            if !ContractFormViewModel.retentionPresets.map({ DecimalInput.format($0) }).contains(model.retentionRateText) {
              Text("%" + model.retentionRateText).tag(model.retentionRateText)
            }
          }
          TextField("Başka oran (%)", text: $model.retentionRateText)
            .keyboardType(.decimalPad)
          TextField("Sözleşme bedeli üst sınırı (isteğe bağlı)", text: $model.totalAmountText)
            .keyboardType(.decimalPad)
            .monospacedDigit()
        } header: {
          Text("Teminat ve sınır")
        } footer: {
          Text("Teminat her hakedişin brütünden kesilir ve sözleşmede birikir. Kalem miktarı veya sözleşme bedeli aşılırsa onay için açık izin gerekir.")
        }
        .rdRowBackground()

        if !model.selectableTaxCodes.isEmpty {
          Section {
            ForEach(model.selectableTaxCodes) { rule in
              Toggle(isOn: Binding(get: { model.taxCodes.contains(rule.code) },
                                   set: { if $0 { model.taxCodes.insert(rule.code) } else { model.taxCodes.remove(rule.code) } })) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(rule.name)
                  Text("\(rule.kind.title) · %\(DecimalInput.format(rule.rate))" + (rule.isVerified ? "" : " · doğrulanmadı"))
                    .font(RDFont.caption)
                    .foregroundStyle(rule.isVerified ? RDColor.textSecondary : RDColor.tone(.warning))
                }
              }
            }
          } header: {
            Text("Vergi ve kesintiler")
          } footer: {
            Text("Oranlar uygulamada sabit değildir; muhasebenin tanımlayıp doğruladığı, hakediş tarihinde geçerli kural uygulanır.")
          }
          .rdRowBackground()
        }

        Section("Diğer bilgiler (isteğe bağlı)") {
          Toggle("İmza tarihi", isOn: $hasSignedDate)
          if hasSignedDate {
            DatePicker("İmza tarihi", selection: $signedDate, displayedComponents: .date)
          }
          TextField("Kapsam", text: $model.scope, axis: .vertical)
          TextField("Ödeme şartları", text: $model.paymentTerms, axis: .vertical)
          TextField("Avans kesinti oranı (%)", text: $model.advanceRateText)
            .keyboardType(.decimalPad)
          TextField("Notlar", text: $model.notes, axis: .vertical)
        }
        .rdRowBackground()

        RDFormMessage(message: model.errorMessage ?? model.validationMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle(model.formTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            model.signedDate = hasSignedDate ? CalendarDate(signedDate) : nil
            Task {
              if let contract = await model.save() {
                onSaved(contract)
                dismiss()
              }
            }
          }
          .fontWeight(.semibold)
          .disabled(!model.canSave)
        }
      }
      .onAppear {
        if let date = model.signedDate {
          signedDate = date.date()
          hasSignedDate = true
        }
      }
      .interactiveDismissDisabled(model.isSaving)
    }
  }
}

/// Tek kalemin alanları; yönteme göre gereksiz alanlar gizlenir.
struct ContractItemEditor: View {
  @Binding var item: ContractItemForm

  var body: some View {
    Picker("Yöntem", selection: $item.method) {
      ForEach(ContractItemMethod.allCases) { Text($0.title).tag($0) }
    }
    .disabled(item.isUsed)
    .onChange(of: item.method) { _, method in
      if method == .goturu { item.unit = .goturu }
      if method == .gunluk { item.unit = .adamGun }
      if method == .birimFiyat, !ContractUnit.measured.contains(item.unit) { item.unit = .m2 }
    }
    TextField("Açıklama", text: $item.description)
    if item.method == .birimFiyat {
      Picker("Birim", selection: $item.unit) {
        ForEach(ContractUnit.measured) { Text($0.title).tag($0) }
      }
      .disabled(item.isUsed)
    }
    if item.method != .goturu {
      TextField(item.method == .gunluk ? "Tahmini adam-gün (isteğe bağlı)" : "Sözleşme miktarı", text: $item.quantityText)
        .keyboardType(.decimalPad)
        .monospacedDigit()
    }
    TextField("\(item.priceLabel) (₺)", text: $item.priceText)
      .keyboardType(.decimalPad)
      .monospacedDigit()
    if item.method == .gunluk {
      TextField("Fazla mesai saat ücreti (boşsa ödenmez)", text: $item.overtimeText)
        .keyboardType(.decimalPad)
        .monospacedDigit()
      ForEach(PaidBasis.allCases.filter { $0 != .calisilanGun }) { basis in
        Toggle("\(basis.title) ücretli", isOn: Binding(
          get: { item.paidBases.contains(basis) },
          set: { if $0 { item.paidBases.insert(basis) } else { item.paidBases.remove(basis) } }))
      }
    }
    if let message = item.validationMessage, !item.priceText.isEmpty || !item.description.isEmpty {
      Text(message).font(RDFont.caption).foregroundStyle(RDColor.tone(.danger))
    } else if let amount = item.amountPreview, amount > 0 {
      MoneyRow(label: "Kalem tutarı", amount: amount)
    }
  }
}

// MARK: - Detay

struct ContractDetailView: View {
  @State private var model: ContractDetailViewModel
  @State private var sheet: Sheet?
  private let app: AppModel

  enum Sheet: Identifiable {
    case edit, revision, close, newHakedis, release, cancelRelease(TeminatRelease), payRelease(TeminatRelease)
    case advance, cancelPayment(FinancePayment)

    var id: String {
      switch self {
      case .edit: "edit"
      case .revision: "revision"
      case .close: "close"
      case .newHakedis: "new"
      case .release: "release"
      case .cancelRelease(let r): "cr-\(r.id)"
      case .payRelease(let r): "pr-\(r.id)"
      case .advance: "advance"
      case .cancelPayment(let p): "cp-\(p.id)"
      }
    }
  }

  init(contract: Contract, app: AppModel) {
    self.app = app
    _model = State(initialValue: ContractDetailViewModel(contract: contract, access: app.access,
                                                         repository: app.repositories.contracts))
  }

  var body: some View {
    List {
      if let notice = model.notice {
        Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(RDColor.tone(.success)) }
          .rdRowBackground()
      }
      if let error = model.errorMessage {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      headerSection
      actionsSection
      if model.canSeeFinance, let summary = model.summary { summarySection(summary) }
      if model.canSeeFinance { hakedisSection }
      itemsSection(model.items, title: "Geçerli kalemler")
      if model.draftVersion != nil && !model.draftItems.isEmpty {
        itemsSection(model.draftItems, title: "Taslak revizyon (onay bekliyor)")
      }
      if model.canSeeFinance { teminatSection; paymentsSection }
      versionsSection
      FinanceEventsSection(events: model.events.prefix(20).map { $0 })
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(model.contract.contractNo)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await model.load() }
    .task { await model.load() }
    .overlay { if model.isLoading && model.versions.isEmpty { RDStateView(kind: .loading) } }
    .disabled(model.isWorking)
    .sheet(item: $sheet) { sheet in sheetView(sheet) }
  }

  // MARK: Bölümler

  private var headerSection: some View {
    Section {
      RDRow(symbol: "doc.text", symbolTint: RDColor.brandText, title: model.contract.title,
            subtitle: app.projectName(model.contract.projectId)) {
        if model.contract.isDemo { RDDemoBadge() }
      } trailing: {
        RDStatusBadge(text: model.contract.status.title, tone: model.contract.status.tone)
      }
      if let version = model.currentVersion ?? model.draftVersion {
        RDInfoRow(label: "Revizyon", value: "\(version.revision) · \(version.status.title)")
        RDInfoRow(label: "Teminat oranı", value: "%" + DecimalInput.format(version.retentionRate))
        if let total = version.totalAmount { RDInfoRow(label: "Sözleşme bedeli", value: Money.format(total)) }
        if let terms = version.paymentTerms { RDInfoRow(label: "Ödeme şartları", value: terms) }
        if let scope = version.scope { RDInfoRow(label: "Kapsam", value: scope) }
      }
      if let date = model.contract.signedDate { RDInfoRow(label: "İmza tarihi", value: date.display) }
      if !model.taxCodes.isEmpty { RDInfoRow(label: "Vergi kuralları", value: model.taxCodes.joined(separator: ", ")) }
    }
    .rdRowBackground()
  }

  @ViewBuilder private var actionsSection: some View {
    let any = model.canCreateHakedis || model.canEdit || model.canApprove || model.canStartRevision || model.canClose
    if any {
      Section {
        if model.canCreateHakedis {
          Button { sheet = .newHakedis } label: { Label("Yeni hakediş", systemImage: "plus.circle") }
        }
        if model.canEdit {
          Button { sheet = .edit } label: { Label("Taslağı düzenle", systemImage: "pencil") }
        }
        if model.canApprove {
          Button { Task { await model.transition(.onayla) } } label: {
            Label(model.currentVersion == nil ? "Sözleşmeyi onayla" : "Revizyonu onayla", systemImage: "checkmark.seal")
          }
        }
        if model.canStartRevision {
          Button { sheet = .revision } label: { Label("Revizyon aç (fiyat/miktar değişikliği)", systemImage: "arrow.triangle.branch") }
        }
        if model.canClose {
          Button(role: .destructive) { sheet = .close } label: { Label("Sözleşmeyi kapat", systemImage: "archivebox") }
        }
      } footer: {
        if model.canStartRevision {
          Text("Onaylı sözleşme doğrudan değiştirilmez. Revizyon onaylanınca yalnızca sonraki hakedişler yeni fiyatla hesaplanır.")
        }
      }
      .rdRowBackground()
    }
  }

  private func summarySection(_ summary: ContractFinanceSummary) -> some View {
    Section {
      if let amount = summary.contractAmount { MoneyRow(label: "Sözleşme bedeli", amount: amount) }
      MoneyRow(label: "Onaylı brüt hakediş", amount: summary.grossTotal, detail: "\(summary.hakedisCount) hakediş")
      if summary.kdvTotal > 0 { MoneyRow(label: "KDV", amount: summary.kdvTotal, sign: .plus) }
      if summary.taxDeductionTotal > 0 { MoneyRow(label: "Stopaj", amount: summary.taxDeductionTotal, sign: .minus) }
      if summary.otherDeductionTotal > 0 { MoneyRow(label: "Diğer kesinti", amount: summary.otherDeductionTotal, sign: .minus) }
      MoneyRow(label: "Kesilen teminat", amount: summary.retentionWithheld, sign: .minus)
      if summary.advanceDeductedTotal > 0 {
        MoneyRow(label: "Avans mahsubu", amount: summary.advanceDeductedTotal, sign: .minus)
      }
      MoneyRow(label: "Ödemeye uygun", amount: summary.payableTotal, sign: .total, emphasized: true)
      if summary.unpostedPayable > 0 {
        MoneyRow(label: "Henüz deftere işlenmemiş", amount: summary.unpostedPayable, detail: "Onaylı, cariye yansımadı")
      }
      MoneyRow(label: "Serbest bırakılan teminat", amount: summary.retentionReleased, sign: .plus)
      MoneyRow(label: "Gerçekleşen ödeme", amount: summary.paidTotal, sign: .minus)
      MoneyRow(label: "Kalan borcumuz", amount: summary.remainingTotal, emphasized: true)
      if summary.advancePaidTotal > 0 {
        MoneyRow(label: "Verilen avans (ayrı)", amount: summary.advancePaidTotal, detail: "Hakedişlerden mahsup edilir")
      }
    } header: {
      Text("Finans özeti")
    } footer: {
      Text("Kalan = ödemeye uygun + serbest bırakılan teminat − gerçekleşen ödeme. Biriken teminat (\(Money.format(summary.retentionBalance))) serbest bırakılana kadar ödenecek tutara eklenmez.")
    }
    .rdRowBackground()
  }

  private var hakedisSection: some View {
    Section {
      if model.hakedisList.isEmpty {
        Text("Henüz hakediş yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.hakedisList) { item in
        NavigationLink(value: AppRoute.hakedis(item, model.contract)) {
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Text(item.title).font(RDFont.rowTitle).foregroundStyle(RDColor.textPrimary)
              Spacer()
              RDStatusBadge(text: item.status.title, tone: item.status.tone)
            }
            Text(item.periodText).font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
            if item.status == .onaylandi {
              Text("Ödemeye uygun \(Money.format(item.payableAmount, currency: item.currency)) · ödenen \(Money.format(model.paidAmount(item), currency: item.currency))")
                .font(RDFont.caption).monospacedDigit().foregroundStyle(RDColor.textSecondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
    } header: {
      Text("Hakedişler")
    }
    .rdRowBackground()
  }

  private func itemsSection(_ items: [ContractItem], title: String) -> some View {
    Section(title) {
      if items.isEmpty { Text("Kalem yok.").foregroundStyle(RDColor.textSecondary) }
      ForEach(items) { item in
        VStack(alignment: .leading, spacing: 2) {
          Text(item.description).font(RDFont.body).foregroundStyle(RDColor.textPrimary)
          Text(itemDetail(item)).font(RDFont.caption).monospacedDigit().foregroundStyle(RDColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .rdRowBackground()
  }

  private func itemDetail(_ item: ContractItem) -> String {
    switch item.method {
    case .goturu:
      return "Götürü · \(Money.format(item.unitPrice))"
    case .birimFiyat:
      let quantity = item.quantity.map { DecimalInput.format($0, maxFractionDigits: 3) } ?? "-"
      return "\(quantity) \(ContractUnit.title(item.unit)) × \(Money.format(item.unitPrice))"
    case .gunluk:
      var text = "Adam-gün \(Money.format(item.unitPrice))"
      if let overtime = item.overtimeUnitPrice { text += " · FM saat \(Money.format(overtime))" } else { text += " · fazla mesai ödenmez" }
      let extra = item.paidBases.compactMap(PaidBasis.init(rawValue:)).filter { $0 != .calisilanGun }
      if !extra.isEmpty { text += " · ücretli: " + extra.map(\.title).joined(separator: ", ").lowercased(with: Money.locale) }
      return text
    }
  }

  private var teminatSection: some View {
    Section {
      MoneyRow(label: "Biriken teminat", amount: model.summary?.retentionBalance ?? 0, emphasized: true)
      ForEach(model.releases) { release in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text("Serbest bırakma · \(release.releaseDate.display)").font(RDFont.body)
            Spacer()
            if release.status == .iptal { RDStatusBadge(text: "İptal", tone: .danger) }
          }
          Text("\(Money.format(release.amount)) · \(release.reason)").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          if release.status == .aktif {
            let unpaid = model.unpaidRelease(release)
            Text(unpaid > 0 ? "Ödenmedi: \(Money.format(unpaid))" : "Ödendi")
              .font(RDFont.caption).foregroundStyle(unpaid > 0 ? RDColor.tone(.warning) : RDColor.tone(.success))
          }
        }
        .accessibilityElement(children: .combine)
        .swipeActions {
          if release.status == .aktif && model.canPay && model.unpaidRelease(release) > 0 {
            Button("Öde") { sheet = .payRelease(release) }.tint(RDColor.brandText)
          }
          if release.status == .aktif && app.access.can(.teminatRelease, in: model.contract.projectId) {
            Button("İptal", role: .destructive) { sheet = .cancelRelease(release) }
          }
        }
      }
      if model.canReleaseTeminat {
        Button { sheet = .release } label: { Label("Teminat serbest bırak", systemImage: "lock.open") }
      }
    } header: {
      Text("Teminat")
    } footer: {
      Text("Serbest bırakma teminatı taşerona borç olarak geri yazar; hakedişi yeniden borçlandırmaz. Nakit ödemesi ayrıca kaydedilir (satırı sola kaydırın).")
    }
    .rdRowBackground()
  }

  private var paymentsSection: some View {
    Section {
      if model.payments.isEmpty { Text("Ödeme yok.").foregroundStyle(RDColor.textSecondary) }
      ForEach(model.payments) { payment in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text("\(payment.kind.title) · \(payment.paymentDate.display)").font(RDFont.body)
            Spacer()
            Text(Money.format(payment.amount)).monospacedDigit().strikethrough(payment.status == .iptal)
          }
          Text(paymentDetail(payment)).font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .swipeActions {
          if payment.status == .aktif && model.canPay {
            Button("İptal", role: .destructive) { sheet = .cancelPayment(payment) }
          }
        }
      }
      if model.canPay && !model.paymentSources.isEmpty {
        if let reason = model.advanceBlockedReason {
          Label(reason, systemImage: "exclamationmark.circle")
            .font(RDFont.secondary)
            .foregroundStyle(RDColor.textSecondary)
        } else {
          Button { sheet = .advance } label: { Label("Avans ver", systemImage: "arrow.up.right.circle") }
        }
      }
    } header: {
      Text("Ödemeler ve avanslar")
    } footer: {
      Text("Hakediş ödemesi hakedişin içinden kaydedilir. Avans ödeme değildir; sonraki hakedişlerden mahsup edilir.")
    }
    .rdRowBackground()
  }

  private func paymentDetail(_ payment: FinancePayment) -> String {
    var parts: [String] = []
    if let source = model.paymentSources.first(where: { $0.id == payment.paymentSourceId }) { parts.append(source.name) }
    if let id = payment.hakedisId, let h = model.hakedisList.first(where: { $0.id == id }) { parts.append(h.title) }
    if payment.teminatReleaseId != nil { parts.append("Teminat iadesi") }
    if payment.status == .iptal { parts.append("İptal: \(payment.cancelReason ?? "")") }
    return parts.joined(separator: " · ")
  }

  private var versionsSection: some View {
    Section("Revizyonlar") {
      ForEach(model.versions) { version in
        VStack(alignment: .leading, spacing: 2) {
          Text("Revizyon \(version.revision) · \(version.status.title)").font(RDFont.body)
          if let reason = version.reason {
            Text(reason).font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          }
        }
      }
    }
    .rdRowBackground()
  }

  // MARK: Sayfalar

  @ViewBuilder
  private func sheetView(_ sheet: Sheet) -> some View {
    switch sheet {
    case .edit:
      ContractFormLoader(app: app, editing: model.contract, version: model.draftVersion, items: model.draftItems,
                         taxCodes: model.taxCodes, usedItemKeys: model.usedItemKeys) { contract in
        Task { await model.didSave(contract) }
      }
    case .revision:
      ReasonSheet(title: "Revizyon aç", message: "Mevcut kalemler taslağa kopyalanır; onaylanana kadar eski fiyatlar geçerlidir.",
                  actionTitle: "Aç") { await model.transition(.revizyon, reason: $0) }
    case .close:
      ReasonSheet(title: "Sözleşmeyi kapat", message: "Kapanan sözleşmeye yeni hakediş açılmaz; teminat ve ödemeler sürer.",
                  actionTitle: "Kapat", destructive: true) { await model.transition(.kapat, reason: $0) }
    case .newHakedis:
      NewHakedisSheet(model: model, app: app)
    case .release:
      TeminatReleaseSheet(balance: model.summary?.retentionBalance ?? 0, currency: model.contract.currency) {
        amount, reason, date, rate in
        await model.releaseTeminat(amount: amount, reason: reason, date: date, exchangeRate: rate)
      }
    case .cancelRelease(let release):
      ReasonSheet(title: "Teminat iadesini iptal et", message: "İade ters kayıtla geri alınır.", actionTitle: "İptal et",
                  destructive: true) { await model.cancelRelease(release, reason: $0) }
    case .payRelease(let release):
      PaymentSheet(title: "Teminat iadesi ödemesi", remaining: model.unpaidRelease(release), currency: model.contract.currency,
                   sources: model.paymentSources) { amount, source, date, note, rate in
        await model.recordPayment(FinancePaymentDraft(contractId: model.contract.id, target: .teminatRelease(release.id),
                                                      amount: amount, paymentSourceId: source, paymentDate: date,
                                                      description: note, exchangeRate: rate))
      }
    case .advance:
      PaymentSheet(title: "Avans ver", remaining: model.advanceRoom ?? 0, currency: model.contract.currency,
                   sources: model.paymentSources) {
        amount, source, date, note, rate in
        await model.recordPayment(FinancePaymentDraft(contractId: model.contract.id, target: .advance, amount: amount,
                                                      paymentSourceId: source, paymentDate: date, description: note,
                                                      exchangeRate: rate))
      }
    case .cancelPayment(let payment):
      ReasonSheet(title: "Ödemeyi iptal et", message: "Ödeme ters kayıtla geri alınır; hakedişin kalanı yeniden açılır.",
                  actionTitle: "İptal et", destructive: true) { await model.cancelPayment(payment, reason: $0) }
    }
  }
}

/// Yeni hakediş: yalnızca dönem seçilir; satırlar sunucuda hesaplanır.
struct NewHakedisSheet: View {
  let model: ContractDetailViewModel
  let app: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var start = Date()
  @State private var end = Date()
  @State private var note = ""
  @State private var isWorking = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          DatePicker("Dönem başı", selection: $start, displayedComponents: .date)
          DatePicker("Dönem sonu", selection: $end, in: start..., displayedComponents: .date)
          TextField("Not (isteğe bağlı)", text: $note)
        } footer: {
          Text("Birim fiyatlı kalemler dönem sonuna kadar onaylanmış ve kullanılmamış imalattan, günlük kalemler onaylı veya kilitli puantajdan gelir. Götürü ilerleme hakediş içinde girilir.")
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle("Yeni hakediş")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Oluştur") {
            Task {
              isWorking = true
              if await model.createHakedis(start: CalendarDate(start), end: CalendarDate(end), note: note) != nil {
                dismiss()
              }
              isWorking = false
            }
          }
          .fontWeight(.semibold)
          .disabled(isWorking)
        }
      }
      .onAppear {
        let (s, e) = model.suggestedPeriod()
        start = s.date()
        end = e.date()
      }
    }
    .presentationDetents([.medium, .large])
  }
}

struct TeminatReleaseSheet: View {
  let balance: Decimal
  var currency = "TRY"
  let action: (Decimal, String, CalendarDate, Decimal?) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var amountText = ""
  @State private var rateText = ""
  @State private var reason = ""
  @State private var date = Date()
  @State private var isWorking = false

  private var amount: Decimal? { Money.parse(amountText) }
  private var problem: String? {
    guard let amount, amount > 0 else { return amountText.isEmpty ? nil : "Tutar geçersiz." }
    if amount > balance { return "Biriken teminat \(Money.format(balance, currency: currency)) üstünde." }
    if reason.trimmingCharacters(in: .whitespaces).count < 10 { return "Gerekçe en az 10 karakter." }
    return ExchangeRateField.problem(currency: currency, text: rateText)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          MoneyRow(label: "Biriken teminat", amount: balance, currency: currency)
          TextField("Serbest bırakılacak tutar", text: $amountText)
            .keyboardType(.decimalPad)
            .font(RDFont.metric)
            .monospacedDigit()
          Button("Tamamı") { amountText = Money.format(balance, currency: "").trimmingCharacters(in: .whitespaces) }
            .font(RDFont.secondary)
          DatePicker("Tarih", selection: $date, in: ...Date(), displayedComponents: .date)
          ExchangeRateField(currency: currency, text: $rateText)
          TextField("Gerekçe (ör. kesin kabul yapıldı)", text: $reason, axis: .vertical)
        } footer: {
          Text("Kısmi veya tam serbest bırakılabilir. Bu işlem ödeme değildir; ödeme ayrıca kaydedilir.")
        }
        .rdRowBackground()
        RDFormMessage(message: problem)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle("Teminat serbest bırak")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Serbest bırak") {
            guard let amount else { return }
            Task {
              isWorking = true
              if await action(amount, reason.trimmingCharacters(in: .whitespaces), CalendarDate(date),
                              ExchangeRateField.rate(currency: currency, text: rateText)) { dismiss() }
              isWorking = false
            }
          }
          .fontWeight(.semibold)
          .disabled(problem != nil || amount == nil || isWorking)
        }
      }
    }
  }
}
