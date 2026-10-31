import RDCore
import RDDesign
import SwiftUI

/// Belge detayı: tutar, ödenen ve kalan ayrı satırlar; ödeme/tahsilat
/// geçmişi; onay, kısmi ödeme, iptal ve düzeltme işlemleri.
struct FinanceDocumentDetailView: View {
  @State private var model: FinanceDocumentDetailViewModel
  @State private var sheet: Sheet?
  @State private var confirmApprove = false
  @State private var opened: FinanceDocument?
  private let app: AppModel

  enum Sheet: Identifiable {
    case edit, settle, cancel, revise, cancelSettlement(FinanceSettlement)

    var id: String {
      switch self {
      case .edit: "edit"
      case .settle: "settle"
      case .cancel: "cancel"
      case .revise: "revise"
      case .cancelSettlement(let s): "cs-\(s.id)"
      }
    }
  }

  init(document: FinanceDocument, app: AppModel) {
    self.app = app
    _model = State(initialValue: FinanceDocumentDetailViewModel(document: document, access: app.access,
                                                                repositories: app.repositories))
  }

  private var document: FinanceDocument { model.document }

  /// Belge bölümü: belge okuma yetkisi ve bu gider/geliri görebilmek (son karar sunucuda).
  private var canSeeDocuments: Bool {
    document.projectId.map { app.access.can(.belgeRead, in: $0) } ?? app.access.can(.belgeRead)
  }
  private var kind: FinanceDocKind { document.kind }

  var body: some View {
    List {
      if let error = model.errorMessage {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      headerSection
      amountSection
      actionsSection
      settlementsSection
      infoSection
      if canSeeDocuments {
        LinkedDocumentsSection(link: .financeDocument(document.id), linkTitle: document.documentNo,
                               projectId: document.projectId, app: app)
      }
      historySection
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(document.documentNo)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.canEdit {
        Button("Düzenle") { sheet = .edit }
      }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
    .disabled(model.isWorking)
    .confirmationDialog(approveTitle, isPresented: $confirmApprove, titleVisibility: .visible) {
      Button("Onayla") { Task { _ = await model.approve() } }
      Button("Vazgeç", role: .cancel) {}
    } message: {
      Text(approveMessage)
    }
    .sheet(item: $sheet) { sheetView($0) }
    .navigationDestination(item: $opened) { FinanceDocumentDetailView(document: $0, app: app) }
  }

  // MARK: Bölümler

  private var headerSection: some View {
    Section {
      RDRow(title: document.description, subtitle: model.categoryName.map { "\(kind.title) · \($0)" } ?? kind.title) {
        if document.isDemo { RDDemoBadge() }
      } trailing: {
        RDStatusBadge(text: document.status.title, tone: document.status.tone)
      }
      RDInfoRow(label: "Bağlı olduğu yer",
                value: app.projectName(document.projectId)
                  ?? app.costCenterName(document.costCenterId).map { "Şirket geneli · \($0)" } ?? "—")
      RDInfoRow(label: "Tarih", value: document.documentDate.display)
      if document.dueDate != document.documentDate {
        RDInfoRow(label: "Vade", value: document.dueDate.display)
      }
      if let status = model.status, status.isOverdue {
        Label("Vadesi \(status.daysOverdue) gün geçti", systemImage: "exclamationmark.triangle")
          .foregroundStyle(RDColor.tone(.danger))
      }
      if let replacesId = document.replacesId {
        RDInfoRow(label: "Düzelttiği belge", value: replacesId.uuidString.prefix(8).uppercased())
      }
    }
    .rdRowBackground()
  }

  private var amountSection: some View {
    Section {
      MoneyRow(label: kind == .gider ? "Gider tutarı" : "Gelir tutarı", amount: document.amount,
               currency: document.currency,
               detail: document.currency == "TRY" ? nil
                 : "Kur \(DecimalInput.format(document.exchangeRate, maxFractionDigits: 6)) · \(Money.format(document.amountTry))",
               emphasized: true)
      if document.status == .onaylandi {
        MoneyRow(label: kind == .gider ? "Ödenen" : "Tahsil edilen", amount: model.status?.settledAmount ?? 0,
                 currency: document.currency, sign: .minus)
        MoneyRow(label: kind == .gider ? "Kalan borç" : "Kalan alacak", amount: model.remaining,
                 currency: document.currency, sign: .total, emphasized: true)
      }
      HStack {
        Text("Durum").foregroundStyle(RDColor.textSecondary)
        Spacer()
        FinanceStateBadge(document: document, status: model.status)
      }
    } footer: {
      Text(amountFooter)
    }
    .rdRowBackground()
  }

  private var amountFooter: String {
    switch document.status {
    case .taslak:
      "Onay bekliyor: henüz \(kind == .gider ? "borç" : "alacak") doğmadı. Onaylandığında \(kind.settlementTitle.lowercased(with: Money.locale)) kaydedilebilir."
    case .onaylandi:
      document.currency == "TRY" ? "Ödeme kaynağı yalnızca bilgidir; kasa veya banka bakiyesi tutulmaz."
        : "TL karşılığı belge kuruyla gösterilir; kur farkı hesaplanmaz."
    case .iptal:
      "İptal edildi: \(document.cancelReason ?? "")"
    }
  }

  @ViewBuilder private var actionsSection: some View {
    if model.canApprove || model.canSettle || model.canCancel || model.canRevise || model.approveNeedsSettlePermission
      || model.replacement != nil {
      Section {
        if model.canApprove {
          Button {
            confirmApprove = true
          } label: {
            Label("Onayla", systemImage: "checkmark.seal")
          }
        }
        if model.approveNeedsSettlePermission {
          Text("Peşin ödendi bildirilen belgeyi onaylamak için ödeme yetkisi de gerekir.")
            .font(RDFont.secondary).foregroundStyle(RDColor.textSecondary)
        }
        if model.canSettle {
          Button {
            sheet = .settle
          } label: {
            Label(kind == .gider ? "Ödeme kaydet" : "Tahsilat kaydet", systemImage: "banknote")
          }
        }
        if model.canRevise {
          Button {
            sheet = .revise
          } label: {
            Label("Düzelt (iptal et ve yenisini aç)", systemImage: "arrow.uturn.backward")
          }
        }
        if model.canCancel {
          Button(role: .destructive) {
            sheet = .cancel
          } label: {
            Label("Belgeyi iptal et", systemImage: "xmark.circle")
          }
        }
        if let replacement = model.replacement {
          Button {
            opened = replacement
          } label: {
            Label("Yerine açılan belge: \(replacement.documentNo)", systemImage: "doc.on.doc")
          }
        }
      } footer: {
        if document.status == .onaylandi && !model.activeSettlements.isEmpty {
          Text("\(kind.settlementTitle) kaydı olan belge iptal veya düzeltme için önce \(kind.settlementTitle.lowercased(with: Money.locale)) iptal edilmelidir.")
        }
      }
      .rdRowBackground()
    }
  }

  @ViewBuilder private var settlementsSection: some View {
    if document.status != .taslak || !model.settlements.isEmpty {
      Section(kind == .gider ? "Ödemeler" : "Tahsilatlar") {
        if model.settlements.isEmpty {
          Text("Henüz kayıt yok.").foregroundStyle(RDColor.textSecondary)
        }
        ForEach(model.settlements) { settlement in
          RDRow(title: Money.format(settlement.amount, currency: document.currency), subtitle: subtitle(settlement)) {
            if settlement.status == .iptal { RDStatusBadge(text: "İptal") }
          } trailing: {
            EmptyView()
          }
          .swipeActions {
            if settlement.status == .aktif && model.canCancelSettlement {
              Button("İptal") { sheet = .cancelSettlement(settlement) }.tint(RDColor.tone(.danger))
            }
          }
          .contextMenu {
            if settlement.status == .aktif && model.canCancelSettlement {
              Button("İptal et", role: .destructive) { sheet = .cancelSettlement(settlement) }
            }
          }
        }
      }
      .rdRowBackground()
    }
  }

  private func subtitle(_ settlement: FinanceSettlement) -> String {
    var parts = [settlement.settlementDate.display, model.sourceName(settlement.paymentSourceId) ?? "Kaynak"]
    if let by = settlement.settledBy { parts.append(by) }
    if document.currency != "TRY" { parts.append("kur \(DecimalInput.format(settlement.exchangeRate, maxFractionDigits: 6))") }
    if let reason = settlement.cancelReason { parts.append("İptal: \(reason)") }
    return parts.joined(separator: " · ")
  }

  private var infoSection: some View {
    Section("Belge bilgisi") {
      if let cari = model.cariAccount {
        NavigationLink(value: AppRoute.cari(cari)) {
          RDInfoRow(label: kind.counterpartyTitle, value: cari.title)
        }
      } else if document.cariAccountId != nil {
        RDInfoRow(label: kind.counterpartyTitle, value: "Cari bağlı")
      } else {
        RDInfoRow(label: kind.counterpartyTitle, value: "Cari bağlantısız")
      }
      if let invoice = document.invoiceNo { RDInfoRow(label: "Fatura no", value: invoice, selectable: true) }
      if let ref = document.documentRef { RDInfoRow(label: "Belge referansı", value: ref, selectable: true) }
      if document.reportedSettled {
        RDInfoRow(label: kind == .gider ? "Peşin ödendi" : "Peşin tahsil edildi",
                  value: [model.sourceName(document.reportedSourceId), document.reportedBy].compactMap { $0 }
                    .joined(separator: " · "))
      }
      if let notes = document.notes { RDInfoRow(label: "Not", value: notes) }
    }
    .rdRowBackground()
  }

  private var historySection: some View {
    Section("Geçmiş") {
      if model.events.isEmpty {
        Text("Kayıt yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.events) { event in
        VStack(alignment: .leading, spacing: 2) {
          Text(event.title).font(RDFont.body).foregroundStyle(RDColor.textPrimary)
          Text(event.occurredAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Money.locale)))
            .font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          if let reason = event.reason {
            Text("Gerekçe: \(reason)").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
    .rdRowBackground()
  }

  // MARK: Onay ve sayfalar

  private var approveTitle: String { "\(document.documentNo) onaylansın mı?" }

  private var approveMessage: String {
    var text = "\(Money.format(document.amount, currency: document.currency)) \(kind == .gider ? "borç" : "alacak") olarak kaydedilir."
    if document.cariAccountId != nil { text += " Carinin defterine bir kez işlenir." }
    if document.reportedSettled { text += " Peşin \(kind == .gider ? "ödeme" : "tahsilat") kaydı da oluşur." }
    return text
  }

  @ViewBuilder private func sheetView(_ sheet: Sheet) -> some View {
    switch sheet {
    case .edit:
      FinanceDocumentFormView(kind: kind, editing: document, preselectedProject: nil, app: app) { saved in
        Task { await model.didSave(saved) }
      }
    case .settle:
      FinanceSettlementSheet(kind: kind, remaining: model.remaining, currency: document.currency,
                             sources: model.paymentSources) { amount, source, date, by, note, rate in
        await model.recordSettlement(amount: amount, sourceId: source, date: date, settledBy: by, description: note,
                                     exchangeRate: rate)
      }
    case .cancel:
      ReasonSheet(title: "Belgeyi iptal et",
                  message: document.status == .taslak ? "Taslak belge iptal edilir; kayıt silinmez."
                    : "Onaylı belge ters kayıtla kapatılır; geçmiş korunur.",
                  actionTitle: "İptal et", minimumLength: model.cancelReasonMinimum, destructive: true) { reason in
        await model.cancel(reason: reason)
      }
    case .revise:
      ReasonSheet(title: "Belgeyi düzelt",
                  message: "Bu belge iptal edilir (ters kayıtla) ve aynı bilgilerle yeni bir taslak açılır; taslağı düzeltip onaya gönderin.",
                  actionTitle: "Düzelt") { reason in
        if let created = await model.revise(reason: reason) {
          opened = created
          return true
        }
        return false
      }
    case .cancelSettlement(let settlement):
      ReasonSheet(title: "\(kind.settlementTitle) iptali",
                  message: "\(Money.format(settlement.amount, currency: document.currency)) tutarlı kayıt ters kayıtla iptal edilir; geçmişte kalır.",
                  actionTitle: "İptal et", destructive: true) { reason in
        await model.cancelSettlement(settlement, reason: reason)
      }
    }
  }
}

/// Kısmi veya tam ödeme/tahsilat formu. Kalanı aşan tutar kabul edilmez.
struct FinanceSettlementSheet: View {
  let kind: FinanceDocKind
  let remaining: Decimal
  let currency: String
  let sources: [PaymentSource]
  let action: (Decimal, UUID, CalendarDate, String?, String?, Decimal?) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var amountText = ""
  @State private var rateText = ""
  @State private var sourceId: UUID?
  @State private var date = Date()
  @State private var settledBy = ""
  @State private var note = ""
  @State private var isWorking = false

  private var amount: Decimal? { Money.parse(amountText) }
  private var problem: String? {
    guard let amount, amount > 0 else { return amountText.isEmpty ? nil : "Tutar geçersiz." }
    if amount > remaining { return "Tutar kalan \(Money.format(remaining, currency: currency)) üstünde." }
    if sourceId == nil { return kind == .gider ? "Ödeme kaynağını seçin." : "Tahsilat kaynağını seçin." }
    return ExchangeRateField.problem(currency: currency, text: rateText)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(currency == "TRY" ? "Tutar (₺)" : "Tutar (\(currency))", text: $amountText)
            .keyboardType(.decimalPad)
            .font(RDFont.metric)
            .monospacedDigit()
          Button("Kalanın tamamı: \(Money.format(remaining, currency: currency))") {
            amountText = DecimalInput.format(remaining, maxFractionDigits: 2)
          }
          .font(RDFont.secondary)
          Picker(kind == .gider ? "Ödeme kaynağı" : "Tahsilat kaynağı", selection: $sourceId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(sources) { Text($0.name).tag(Optional($0.id)) }
          }
          DatePicker("Tarih", selection: $date, in: ...Date(), displayedComponents: .date)
          ExchangeRateField(currency: currency, text: $rateText)
        } footer: {
          Text("Kaynak (şirket, kart, kişi) bilgi amaçlıdır; kasa veya banka bakiyesi tutulmaz. Kişisel kartla ödeme kart sahibine otomatik borç yazmaz.")
        }
        .rdRowBackground()
        Section {
          TextField(kind == .gider ? "Ödeyen kişi (isteğe bağlı)" : "Tahsil eden (isteğe bağlı)", text: $settledBy)
          TextField("Açıklama (isteğe bağlı)", text: $note)
        }
        .rdRowBackground()
        RDFormMessage(message: problem)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle(kind == .gider ? "Ödeme kaydet" : "Tahsilat kaydet")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            guard let amount, let sourceId else { return }
            Task {
              isWorking = true
              if await action(amount, sourceId, CalendarDate(date), settledBy.nilIfBlank, note.nilIfBlank,
                              ExchangeRateField.rate(currency: currency, text: rateText)) { dismiss() }
              isWorking = false
            }
          }
          .fontWeight(.semibold)
          .disabled(problem != nil || amount == nil || isWorking)
        }
      }
      .onAppear { if sources.count == 1 { sourceId = sources[0].id } }
      .interactiveDismissDisabled(isWorking)
    }
  }
}
