import RDCore
import RDDesign
import SwiftUI

/// Cari detay: bakiye özeti ve hareket ekleme en üstte, ardından filtreli
/// ekstre (hareket geçmişi) ve kart bilgileri. İptal ters kayıtla yapılır.
struct CariDetailView: View {
  let app: AppModel
  @State private var model: CariDetailViewModel
  @State private var editing = false
  @State private var newEntry = false
  @State private var reversing: CariStatementLine?
  @State private var reversalReason = ""
  @State private var reversalId = UUID()
  @State private var showingFilter = false
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
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      header(account)
      if model.canSeeEntries {
        summarySection
        filterSection
        entriesSection
      } else {
        Section {
          Text("Bu carinin hareketlerini görüntüleme yetkiniz yok.").foregroundStyle(RDColor.textSecondary)
        }
        .rdRowBackground()
      }
      infoSection(account)
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(account.code)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.canEditAccount {
        Button("Düzenle") { editing = true }
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

  // MARK: Bölümler

  private func header(_ account: CariAccount) -> some View {
    Section {
      VStack(alignment: .leading, spacing: .rdS) {
        HStack(spacing: .rdS) {
          RDStatusBadge(text: account.type.title, tone: .neutral)
          if account.isDemo { RDDemoBadge() }
          if !account.isActive { RDStatusBadge(text: "Pasif", tone: .warning) }
        }
        Text(account.title)
          .font(RDFont.sectionTitle)
          .foregroundStyle(RDColor.textPrimary)
      }
      .padding(.vertical, .rdXS)
    }
    .rdRowBackground()
  }

  private var summarySection: some View {
    let summary = model.summary
    return Section {
      VStack(alignment: .leading, spacing: .rdXS) {
        Text(model.filter.to == nil ? "Güncel bakiye" : "Dönem sonu bakiye")
          .font(RDFont.secondary)
          .foregroundStyle(RDColor.textSecondary)
        RDAmount(amount: summary.closing, showsSide: true)
          .font(RDFont.metric)
        Text(summary.side.title)
          .font(RDFont.caption)
          .foregroundStyle(RDColor.textSecondary)
      }
      .padding(.vertical, .rdXS)
      if model.filter.from != nil {
        RDInfoRow(label: "Devir", value: Money.format(summary.opening))
      }
      RDInfoRow(label: "Toplam borç", value: Money.format(summary.periodBorc))
      RDInfoRow(label: "Toplam alacak", value: Money.format(summary.periodAlacak))
      if model.canPostEntries && model.account.isActive {
        Button("Hareket ekle") { newEntry = true }
          .buttonStyle(.rdPrimary)
          .listRowInsets(EdgeInsets(top: .rdM, leading: .rdL, bottom: .rdM, trailing: .rdL))
      }
    }
    .rdRowBackground()
  }

  private var filterSection: some View {
    Section {
      DisclosureGroup(isExpanded: $showingFilter) {
        Picker("Proje", selection: $model.filter.projectId) {
          Text("Tümü").tag(UUID?.none)
          ForEach(app.projects) { Text($0.name).tag(Optional($0.id)) }
        }
        Toggle("Başlangıç tarihi", isOn: $useFrom)
        if useFrom { DatePicker("Başlangıç", selection: $fromDate, displayedComponents: .date) }
        Toggle("Bitiş tarihi", isOn: $useTo)
        if useTo { DatePicker("Bitiş", selection: $toDate, displayedComponents: .date) }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text("Filtre").font(RDFont.rowTitle).foregroundStyle(RDColor.textPrimary)
          Text(filterSummary).font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
        }
      }
    }
    .rdRowBackground()
    .environment(\.locale, Money.locale)
    .onChange(of: [useFrom, useTo]) { _, _ in applyDates() }
    .onChange(of: fromDate) { _, _ in applyDates() }
    .onChange(of: toDate) { _, _ in applyDates() }
    .onChange(of: model.filter.projectId) { _, _ in Task { await model.load() } }
  }

  private var filterSummary: String {
    var parts = [app.projectName(model.filter.projectId) ?? "Tüm projeler"]
    if let from = model.filter.from { parts.append("\(from.display) sonrası") }
    if let to = model.filter.to { parts.append("\(to.display) öncesi") }
    return parts.joined(separator: " · ")
  }

  private func applyDates() {
    model.filter.from = useFrom ? CalendarDate(fromDate) : nil
    model.filter.to = useTo ? CalendarDate(toDate) : nil
    Task { await model.load() }
  }

  private var entriesSection: some View {
    Section {
      if model.lines.isEmpty && !model.isLoading {
        Text("Seçili aralıkta hareket yok.").foregroundStyle(RDColor.textSecondary)
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
              .tint(RDColor.tone(.danger))
            }
          }
      }
    } header: {
      Text("Hareketler (\(model.lines.count))")
    } footer: {
      if model.lines.contains(where: model.canReverse) {
        Text("Hatalı bir hareketi iptal etmek için satırı sola kaydırın.")
      }
    }
    .rdRowBackground()
  }

  private func infoSection(_ account: CariAccount) -> some View {
    Section("Kart bilgileri") {
      if let tax = account.taxNumber { RDInfoRow(label: "VKN/TCKN", value: tax, selectable: true) }
      if let office = account.taxOffice { RDInfoRow(label: "Vergi dairesi", value: office) }
      if let phone = account.phone { RDInfoRow(label: "Telefon", value: phone, selectable: true) }
      if let email = account.email { RDInfoRow(label: "E-posta", value: email, selectable: true) }
      if let iban = account.iban { RDInfoRow(label: "IBAN", value: iban, selectable: true) }
      if let address = account.address { RDInfoRow(label: "Adres", value: address) }
      if account.isDemo {
        Label("Demo cari; yalnızca demo projelerle kullanılabilir.", systemImage: "info.circle")
          .font(RDFont.caption)
          .foregroundStyle(RDColor.tone(.warning))
      }
    }
    .rdRowBackground()
  }
}

private struct StatementRow: View {
  let line: CariStatementLine
  let scopeName: String?

  var body: some View {
    VStack(alignment: .leading, spacing: .rdXS) {
      HStack(alignment: .firstTextBaseline) {
        Text(line.kind.title).font(RDFont.rowTitle).foregroundStyle(RDColor.textPrimary)
        if line.isReversed { RDStatusBadge(text: "İptal edildi", tone: .danger) }
        Spacer(minLength: .rdS)
        Text((line.direction == .borc ? "Borç " : "Alacak ") + Money.format(line.amount, currency: line.currency))
          .font(RDFont.body.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(muted ? RDColor.textSecondary : RDColor.textPrimary)
          .strikethrough(line.isReversed)
      }
      Text(line.description).font(RDFont.secondary).foregroundStyle(RDColor.textSecondary)
      ViewThatFits(in: .horizontal) {
        HStack { meta; Spacer(); running }
        VStack(alignment: .leading, spacing: 2) { meta; running }
      }
      .font(RDFont.caption)
      .foregroundStyle(RDColor.textSecondary)
    }
    .padding(.vertical, .rdXS)
    .accessibilityElement(children: .combine)
  }

  private var muted: Bool { line.isReversed || line.kind == .tersKayit }

  private var meta: some View {
    Text(([line.entryDate.display, scopeName, line.documentNo].compactMap { $0 }).joined(separator: " · "))
  }

  private var running: some View {
    Text("Bakiye \(Money.format(line.runningBalanceTry))").monospacedDigit()
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
          TextField("Tutar (₺)", text: $model.amountText)
            .keyboardType(.decimalPad)
            .font(RDFont.metric)
            .monospacedDigit()
          DatePicker("Tarih", selection: $model.date, in: ...Date(), displayedComponents: .date)
        } footer: {
          Text("Borç: ödeme ve avans gibi karşı tarafı borçlandıran kayıtlar. Alacak: fatura, tahsilat gibi karşı tarafı alacaklandıran kayıtlar.")
        }
        .rdRowBackground()
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
        .rdRowBackground()
        Section {
          TextField("Açıklama", text: $model.descriptionText, axis: .vertical)
          TextField("Belge no (isteğe bağlı)", text: $model.documentNo)
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage ?? model.validationMessage)
      }
      .rdScreen()
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
          .fontWeight(.semibold)
          .disabled(!model.canSave)
        }
      }
      .interactiveDismissDisabled(model.isSaving)
    }
  }
}
