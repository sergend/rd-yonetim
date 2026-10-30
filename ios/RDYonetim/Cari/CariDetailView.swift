import RDCore
import SwiftUI

/// Cari kart, filtreli ekstre (hareket geçmişi) ve ters kayıtla iptal.
struct CariDetailView: View {
  let app: AppModel
  @State private var model: CariDetailViewModel
  @State private var editing = false
  @State private var newEntry = false
  @State private var reversing: CariStatementLine?
  @State private var reversalReason = ""
  @State private var reversalId = UUID()
  @State private var useFrom = false
  @State private var useTo = false
  @State private var fromDate = CalendarDate.today().adding(days: -30).date()
  @State private var toDate = Date()

  init(account: CariAccount, app: AppModel) {
    self.app = app
    _model = State(initialValue: CariDetailViewModel(account: account, access: app.access, repository: app.repositories.cari))
  }

  var body: some View {
    let account = model.account
    List {
      if let error = model.errorMessage {
        ErrorBanner(message: error).listRowBackground(Color.clear)
      }
      Section {
        LabeledContent("Kod", value: account.code)
        LabeledContent("Tür", value: account.type.title)
        if let tax = account.taxNumber { LabeledContent("VKN/TCKN", value: tax) }
        if let phone = account.phone { LabeledContent("Telefon", value: phone) }
        if let iban = account.iban { LabeledContent("IBAN", value: iban).textSelection(.enabled) }
        if account.isDemo {
          Label("Demo cari; yalnızca demo projelerle kullanılabilir.", systemImage: "info.circle")
            .font(.footnote).foregroundStyle(.orange)
        }
      }

      if model.canSeeEntries {
        filterSection
        summarySection
        Section("Hareketler") {
          if model.lines.isEmpty {
            Text("Seçili aralıkta hareket yok.").foregroundStyle(.secondary)
          }
          ForEach(model.lines.reversed()) { line in
            StatementRow(line: line, scopeName: app.projectName(line.projectId) ?? app.costCenterName(line.costCenterId))
              .swipeActions(edge: .trailing) {
                if model.canReverse(line) {
                  Button("İptal et") {
                    reversalReason = ""
                    reversalId = UUID()
                    reversing = line
                  }
                  .tint(.red)
                }
              }
          }
        }
      } else {
        Section {
          Text("Bu carinin hareketlerini görüntüleme yetkiniz yok.").foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle(account.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if model.canPostEntries && account.isActive {
          Button("Hareket ekle", systemImage: "plus.circle") { newEntry = true }
        }
        if model.canEditAccount {
          Button("Düzenle") { editing = true }
        }
      }
    }
    .sheet(isPresented: $editing) {
      CariFormView(model: CariFormViewModel(editing: account, repository: app.repositories.cari)) { model.didSave($0) }
    }
    .sheet(isPresented: $newEntry) {
      CariEntryFormView(model: CariEntryFormViewModel(
        account: account, access: app.access, projects: app.projects, costCenters: app.costCenters,
        preselectedProject: model.filter.projectId, repository: app.repositories.cari)) {
        Task { await model.load() }
      }
    }
    .alert("Hareketi iptal et", isPresented: Binding(get: { reversing != nil }, set: { if !$0 { reversing = nil } }),
           presenting: reversing) { line in
      TextField("İptal gerekçesi", text: $reversalReason)
      Button("Vazgeç", role: .cancel) {}
      Button("Ters kayıt oluştur", role: .destructive) {
        Task { _ = await model.reverse(line, reason: reversalReason, reversalId: reversalId) }
      }
    } message: { line in
      Text("\(Money.format(line.amount)) tutarındaki hareket silinmez; zıt yönlü bir ters kayıt eklenir.")
    }
    .refreshable { await model.load() }
    .task { await model.load() }
  }

  private var filterSection: some View {
    Section("Filtre") {
      Picker("Proje", selection: $model.filter.projectId) {
        Text("Tümü").tag(UUID?.none)
        ForEach(app.projects) { Text($0.name).tag(Optional($0.id)) }
      }
      Toggle("Başlangıç tarihi", isOn: $useFrom)
      if useFrom { DatePicker("Başlangıç", selection: $fromDate, displayedComponents: .date) }
      Toggle("Bitiş tarihi", isOn: $useTo)
      if useTo { DatePicker("Bitiş", selection: $toDate, displayedComponents: .date) }
    }
    .environment(\.locale, Money.locale)
    .onChange(of: [useFrom, useTo]) { _, _ in applyDates() }
    .onChange(of: fromDate) { _, _ in applyDates() }
    .onChange(of: toDate) { _, _ in applyDates() }
    .onChange(of: model.filter.projectId) { _, _ in Task { await model.load() } }
  }

  private func applyDates() {
    model.filter.from = useFrom ? CalendarDate(fromDate) : nil
    model.filter.to = useTo ? CalendarDate(toDate) : nil
    Task { await model.load() }
  }

  private var summarySection: some View {
    let summary = model.summary
    return Section {
      if model.filter.from != nil {
        LabeledContent("Devir") { AmountText(amount: summary.opening, colored: true) }
      }
      LabeledContent("Toplam borç") { AmountText(amount: summary.periodBorc) }
      LabeledContent("Toplam alacak") { AmountText(amount: summary.periodAlacak) }
      LabeledContent("Bakiye") { AmountText(amount: summary.closing, colored: true).fontWeight(.semibold) }
    } header: {
      Text("Özet")
    } footer: {
      Text(summary.side.title)
    }
  }
}

private struct StatementRow: View {
  let line: CariStatementLine
  let scopeName: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(line.kind.title).font(.subheadline.weight(.medium))
        if line.isReversed { StatusBadge(text: "İptal edildi", color: .red) }
        Spacer()
        Text((line.direction == .borc ? "+" : "−") + Money.format(line.amount, currency: line.currency))
          .monospacedDigit()
          .foregroundStyle(line.isReversed || line.kind == .tersKayit ? .secondary : .primary)
          .strikethrough(line.isReversed)
      }
      Text(line.description).font(.callout).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        Text(line.entryDate.display)
        if let scopeName { Text("· \(scopeName)") }
        if let doc = line.documentNo { Text("· \(doc)") }
        Spacer()
        Text("Bakiye \(Money.format(line.runningBalanceTry))").monospacedDigit()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }
}

struct CariEntryFormView: View {
  @State var model: CariEntryFormViewModel
  let onSaved: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Tür", selection: $model.kind) {
            ForEach(CariEntryKind.manualKinds) { Text($0.title).tag($0) }
          }
          Picker("Yön", selection: $model.direction) {
            ForEach(CariDirection.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          .disabled(model.isDirectionFixed)
          TextField("Tutar (₺)", text: $model.amountText).keyboardType(.decimalPad)
          DatePicker("Tarih", selection: $model.date, in: ...Date(), displayedComponents: .date)
        } footer: {
          Text("Borç: ödeme ve avans gibi karşı tarafı borçlandıran kayıtlar. Alacak: fatura, tahsilat gibi karşı tarafı alacaklandıran kayıtlar.")
        }
        Section("Kapsam") {
          Picker("Bağlı olduğu yer", selection: $model.scopeChoice) {
            Text("Proje").tag(CariEntryFormViewModel.ScopeChoice.project)
            Text("Genel gider").tag(CariEntryFormViewModel.ScopeChoice.costCenter)
          }
          .pickerStyle(.segmented)
          if model.scopeChoice == .project {
            Picker("Proje", selection: $model.projectId) {
              ForEach(model.projects) { Text($0.name).tag(Optional($0.id)) }
            }
          } else {
            Picker("Masraf merkezi", selection: $model.costCenterId) {
              ForEach(model.costCenters) { Text($0.name).tag(Optional($0.id)) }
            }
          }
        }
        Section {
          TextField("Açıklama", text: $model.descriptionText, axis: .vertical)
          TextField("Belge no (isteğe bağlı)", text: $model.documentNo)
        }
        if let message = model.errorMessage ?? model.validationMessage {
          Section { Text(message).foregroundStyle(.red).font(.callout) }
        }
      }
      .environment(\.locale, Money.locale)
      .navigationTitle(model.account.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            Task {
              if await model.save() {
                onSaved()
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
