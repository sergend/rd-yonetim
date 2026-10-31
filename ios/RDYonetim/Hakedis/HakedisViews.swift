import RDCore
import RDDesign
import SwiftUI

// MARK: - Liste (modül girişi)

struct HakedisListView: View {
  @State private var model: HakedisListViewModel
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: HakedisListViewModel(repository: app.repositories.contracts))
  }

  var body: some View {
    List {
      Section {
        Picker("Durum", selection: $model.statusFilter) {
          Text("Tümü").tag(HakedisStatus?.none)
          ForEach(HakedisStatus.allCases) { Text($0.title).tag(Optional($0)) }
        }
      }
      .rdRowBackground()
      Section {
        ForEach(model.filtered) { item in
          if let contract = model.contracts[item.contractId] {
            NavigationLink(value: AppRoute.hakedis(item, contract)) {
              RDRow(symbol: "doc.badge.gearshape", symbolTint: RDColor.brandText,
                    title: "\(contract.contractNo) · \(item.title)",
                    subtitle: [contract.title, app.projectName(item.projectId), item.periodText].compactMap { $0 }
                      .joined(separator: " · ")) {
                if item.isDemo { RDDemoBadge() }
              } trailing: {
                RDStatusBadge(text: item.status.title, tone: item.status.tone)
              }
            }
          }
        }
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle("Hakediş")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        NavigationLink(value: AppRoute.contracts(projectId: nil)) { Label("Sözleşmeler", systemImage: "doc.text") }
      }
    }
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Hakediş yok", message: "Hakediş, sözleşmenin içinden açılır.",
                                  symbol: "doc.badge.gearshape"),
                    retry: { Task { await model.load() } })
    .refreshable { await model.load() }
    .task { await model.load() }
  }
}

// MARK: - Detay

struct HakedisDetailView: View {
  @State private var model: HakedisDetailViewModel
  @State private var sheet: Sheet?
  @State private var confirmPost = false
  @State private var confirmApprove = false
  private let app: AppModel

  enum Sheet: Identifiable {
    case progress(HakedisLine), deduction(HakedisAdjustmentKind), override, returnBack, cancel, revise, pay, postWithRate
    case cancelPayment(FinancePayment)

    var id: String {
      switch self {
      case .progress(let line): "p-\(line.id)"
      case .deduction(let kind): "d-\(kind.rawValue)"
      case .override: "o"
      case .returnBack: "r"
      case .cancel: "c"
      case .revise: "v"
      case .pay: "pay"
      case .postWithRate: "post"
      case .cancelPayment(let p): "cp-\(p.id)"
      }
    }
  }

  init(hakedis: Hakedis, contract: Contract, app: AppModel) {
    self.app = app
    _model = State(initialValue: HakedisDetailViewModel(hakedis: hakedis, contract: contract, access: app.access,
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
      if model.hakedis.limitExceeded { limitSection }
      actionsSection
      HakedisBreakdownSections(hakedis: model.hakedis, breakdown: model.breakdown, paymentState: model.paymentStateTitle)
      linesSection
      adjustmentsSection
      if !model.puantajLinks.isEmpty { puantajSection }
      if !model.payments.isEmpty { paymentsSection }
      FinanceEventsSection(events: model.events)
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(model.hakedis.title)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await model.load() }
    .task { await model.load() }
    .disabled(model.isWorking)
    .overlay { if model.isWorking { ProgressView() } }
    .sheet(item: $sheet) { sheetView($0) }
    .confirmationDialog("Cari deftere işlensin mi?", isPresented: $confirmPost, titleVisibility: .visible) {
      Button("Deftere işle") { Task { await model.post() } }
    } message: {
      Text("Brüt + KDV alacak, stopaj ve teminat kesintisi borç olarak yazılır; avans mahsup edilir. Bu işlem ödeme değildir ve tekrar edilirse ikinci kayıt açılmaz.")
    }
    .confirmationDialog("Hakediş onaylansın mı?", isPresented: $confirmApprove, titleVisibility: .visible) {
      Button("Onayla") { Task { await model.transition(.onayla) } }
    } message: {
      Text("Onaylanan hakediş değiştirilemez; düzeltme iptal ve yeni hakedişle yapılır. Ödemeye uygun: \(Money.format(model.hakedis.payableAmount, currency: model.hakedis.currency)).")
    }
  }

  // MARK: Bölümler

  private var headerSection: some View {
    Section {
      RDRow(symbol: "doc.badge.gearshape", symbolTint: RDColor.brandText,
            title: "\(model.contract.contractNo) · \(model.contract.title)", subtitle: model.hakedis.periodText) {
        if model.hakedis.isDemo { RDDemoBadge() }
      } trailing: {
        RDStatusBadge(text: model.hakedis.status.title, tone: model.hakedis.status.tone)
      }
      if model.hakedis.replacesId != nil {
        Label("Bu hakediş, iptal edilen bir hakedişin düzeltmesidir.", systemImage: "arrow.uturn.backward")
          .font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
      }
      if let reason = model.hakedis.cancelReason, model.hakedis.status == .iptal {
        RDInfoRow(label: "İptal gerekçesi", value: reason)
      }
      if let note = model.hakedis.note { RDInfoRow(label: "Not", value: note) }
    }
    .rdRowBackground()
  }

  private var limitSection: some View {
    Section {
      ForEach(model.hakedis.limitMessages, id: \.self) { message in
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(RDColor.tone(.warning))
      }
      if let reason = model.hakedis.limitOverrideReason {
        RDInfoRow(label: "Verilen izin", value: reason)
      } else if model.canOverrideLimit {
        Button { sheet = .override } label: { Label("Limit aşımına izin ver", systemImage: "checkmark.shield") }
      }
    } header: {
      Text("Sözleşme sınırı aşıldı")
    } footer: {
      Text("Aşım için onaylı bir revizyon ya da gerekçeli açık izin gerekir; izin olmadan onaylanamaz.")
    }
    .rdRowBackground()
  }

  @ViewBuilder private var actionsSection: some View {
    let any = model.isEditable || model.canSubmit || model.canReturn || model.canApprove || model.canPost || model.canPay
      || model.canCancelDraft || model.canRevise
    if any {
      Section {
        if model.isEditable {
          Button { Task { await model.recalculate() } } label: { Label("Yeniden hesapla", systemImage: "arrow.clockwise") }
        }
        if model.canSubmit {
          Button { Task { await model.transition(.gonder) } } label: { Label("İncelemeye gönder", systemImage: "paperplane") }
        }
        if model.canApprove {
          Button { confirmApprove = true } label: { Label("Onayla", systemImage: "checkmark.seal") }
        }
        if model.canReturn {
          Button { sheet = .returnBack } label: { Label("Düzeltmeye iade et", systemImage: "arrow.uturn.backward") }
        }
        if model.canPost {
          Button {
            if model.needsExchangeRate { sheet = .postWithRate } else { confirmPost = true }
          } label: { Label("Cari deftere işle", systemImage: "book.closed") }
        }
        if model.canPay && !model.paymentSources.isEmpty {
          Button { sheet = .pay } label: { Label("Ödeme kaydet", systemImage: "creditcard") }
        }
        if model.canCancelDraft {
          Button(role: .destructive) { sheet = .cancel } label: { Label("Hakedişi iptal et", systemImage: "xmark.circle") }
        }
        if model.canRevise {
          Button(role: .destructive) { sheet = .revise } label: {
            Label("İptal et ve düzeltme hakedişi aç", systemImage: "arrow.triangle.2.circlepath")
          }
        }
      } footer: {
        if model.hakedis.status == .onaylandi && !model.hakedis.isPosted {
          Text("Onaylı hakediş cariye ancak \"Cari deftere işle\" ile yansır; ödeme bundan sonra kaydedilir.")
        } else if model.canRevise {
          Text("Onaylı hakediş değiştirilemez. Düzeltme, bunu ters kayıtla iptal edip aynı dönem için yeni taslak açar.")
        }
      }
      .rdRowBackground()
    }
  }

  private var linesSection: some View {
    Section {
      ForEach(model.mainLines) { line in
        VStack(alignment: .leading, spacing: .rdXS) {
          HStack(alignment: .firstTextBaseline) {
            Text(line.displayTitle).font(RDFont.rowTitle).foregroundStyle(RDColor.textPrimary)
            Spacer(minLength: .rdS)
            Text(Money.format(line.amount, currency: model.hakedis.currency)).monospacedDigit().font(RDFont.body.weight(.semibold))
          }
          Text(lineDetail(line)).font(RDFont.caption).monospacedDigit().foregroundStyle(RDColor.textSecondary)
          Text("Önceki \(quantity(line.previousQuantity, line)) · \(Money.format(line.previousAmount)) | Kümülatif \(quantity(line.cumulativeQuantity, line)) · \(Money.format(line.cumulativeAmount))")
            .font(RDFont.caption).monospacedDigit().foregroundStyle(RDColor.textSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .swipeActions {
          if model.isEditable && line.method == .goturu && line.lineKind == .ana {
            Button("İlerleme") { sheet = .progress(line) }.tint(RDColor.brandText)
          }
        }
      }
    } header: {
      Text("Kalemler · bu dönem")
    } footer: {
      if model.isEditable && model.lines.contains(where: { $0.method == .goturu }) {
        Text("Götürü kalemde ilerleme yüzdesini girmek için satırı sola kaydırın.")
      }
    }
    .rdRowBackground()
  }

  private func quantity(_ value: Decimal, _ line: HakedisLine) -> String {
    line.method == .goturu && line.lineKind == .ana ? "%" + DecimalInput.format(value, maxFractionDigits: 2)
      : "\(DecimalInput.format(value, maxFractionDigits: 3)) \(line.unitTitle)"
  }

  private func lineDetail(_ line: HakedisLine) -> String {
    switch line.method {
    case .goturu where line.lineKind == .ana:
      return "Götürü \(Money.format(line.unitPrice)) · kümülatif ilerleme %\(DecimalInput.format(line.progressPercent ?? 0, maxFractionDigits: 2))"
    default:
      var text = "\(quantity(line.quantity, line)) × \(Money.format(line.unitPrice))"
      if let limit = line.contractQuantity, line.lineKind == .ana {
        text += " · sözleşme \(DecimalInput.format(limit, maxFractionDigits: 3)) \(line.unitTitle)"
      }
      return text
    }
  }

  private var adjustmentsSection: some View {
    Section {
      if model.adjustments.isEmpty { Text("Kesinti yok.").foregroundStyle(RDColor.textSecondary) }
      ForEach(model.adjustments) { adjustment in
        MoneyRow(label: adjustment.description, amount: adjustment.amount, currency: model.hakedis.currency,
                 sign: adjustment.kind.isAddition ? .plus : .minus, detail: adjustmentDetail(adjustment))
      }
      if model.isEditable {
        Button { sheet = .deduction(.avansMahsubu) } label: { Label("Avans mahsubu", systemImage: "arrow.down.left.circle") }
        Button { sheet = .deduction(.digerKesinti) } label: { Label("Diğer kesinti", systemImage: "minus.circle") }
      }
    } header: {
      Text("Vergi ve kesintiler")
    } footer: {
      Text("KDV, stopaj ve teminat sözleşme kuralından hesaplanır; her biri matrah ve oranıyla ayrı satırdır.")
    }
    .rdRowBackground()
  }

  private func adjustmentDetail(_ adjustment: HakedisAdjustment) -> String {
    var parts = [adjustment.kind.title]
    if let rate = adjustment.rate, let base = adjustment.baseAmount {
      parts.append("%\(DecimalInput.format(rate)) × \(Money.format(base))")
    }
    if adjustment.isManual { parts.append("elle girildi") }
    return parts.joined(separator: " · ")
  }

  private var puantajSection: some View {
    Section {
      ForEach(model.puantajLinks) { link in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(link.personnelName).font(RDFont.body)
            Text("\(link.workDate.display) · \(link.status.title)\(link.isCorrection ? " · düzeltme farkı" : "")")
              .font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 2) {
            Text("\(link.dayDelta > 0 ? "+" : "")\(DecimalInput.format(link.dayDelta, maxFractionDigits: 2)) gün").monospacedDigit()
            if link.overtimeDelta != 0 {
              Text("FM \(DecimalInput.format(link.overtimeDelta, maxFractionDigits: 2)) sa").font(RDFont.caption).monospacedDigit()
            }
          }
        }
        .accessibilityElement(children: .combine)
      }
    } header: {
      Text("Puantaj kaynakları (\(model.puantajLinks.count))")
    } footer: {
      Text("Yalnızca onaylı veya kilitli ayların kayıtları; ay revizyonu: \(Set(model.puantajLinks.map(\.periodRevision)).sorted().map(String.init).joined(separator: ", ")). Sonradan düzeltilen gün eski hakedişi değiştirmez, fark sonraki hakedişe gelir.")
    }
    .rdRowBackground()
  }

  private var paymentsSection: some View {
    Section("Ödemeler") {
      ForEach(model.payments) { payment in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(payment.paymentDate.display)
            Text([model.paymentSources.first { $0.id == payment.paymentSourceId }?.name,
                  payment.status == .iptal ? "İptal" : nil].compactMap { $0 }.joined(separator: " · "))
              .font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          }
          Spacer()
          Text(Money.format(payment.amount, currency: model.hakedis.currency)).monospacedDigit()
            .strikethrough(payment.status == .iptal)
        }
        .accessibilityElement(children: .combine)
        .swipeActions {
          if payment.status == .aktif && app.access.can(.odemeWrite, in: model.hakedis.projectId) {
            Button("İptal", role: .destructive) { sheet = .cancelPayment(payment) }
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
    case .progress(let line):
      ValueSheet(title: "Götürü ilerleme", label: "Kümülatif ilerleme (%)",
                 message: "Önceki onaylı düzey %\(DecimalInput.format(line.previousQuantity, maxFractionDigits: 2)). Bu dönem tutarı = bedel × yüzde − önceki tutar.",
                 initial: DecimalInput.format(line.progressPercent ?? line.previousQuantity, maxFractionDigits: 2)) {
        await model.setProgress(line, percentText: $0)
      }
    case .deduction(let kind):
      ValueSheet(title: kind.title, label: "Tutar (₺, 0 kaldırır)",
                 message: kind == .avansMahsubu ? "Açık avanstan fazlası mahsup edilemez." : "Sözleşmede tanımlı başka bir kesinti.",
                 initial: DecimalInput.format(model.adjustments.first { $0.kind == kind && $0.isManual }?.amount, maxFractionDigits: 2)) {
        await model.setDeduction(kind, amountText: $0, description: nil)
      }
    case .override:
      ReasonSheet(title: "Limit aşımı izni", message: "Gerekçe kayda geçer. Tutar değişirse izin düşer.",
                  actionTitle: "İzin ver") { await model.overrideLimit(reason: $0) }
    case .returnBack:
      ReasonSheet(title: "Düzeltmeye iade", message: "Hakediş taslağa döner.", actionTitle: "İade et", minimumLength: 3) {
        await model.transition(.iade, reason: $0)
      }
    case .cancel:
      ReasonSheet(title: "Hakedişi iptal et", message: "Kullanılan imalat ve puantaj serbest kalır.", actionTitle: "İptal et",
                  minimumLength: 3, destructive: true) { await model.transition(.iptal, reason: $0) }
    case .revise:
      ReasonSheet(title: "Düzeltme hakedişi", message: "Bu hakediş ters kayıtla iptal edilir, aynı dönem için yeni taslak açılır.",
                  actionTitle: "Devam", destructive: true) { await model.revise(reason: $0) }
    case .pay:
      PaymentSheet(title: "Hakediş ödemesi", remaining: model.breakdown.remaining, currency: model.hakedis.currency,
                   sources: model.paymentSources) { amount, source, date, note, rate in
        await model.recordPayment(amount: amount, sourceId: source, date: date, description: note, exchangeRate: rate)
      }
    case .postWithRate:
      ValueSheet(title: "Cari deftere işle", label: "Kur (1 \(model.hakedis.currency) = ? ₺)",
                 message: "Bu işlemin tarihindeki kuru girin; kur tahmin edilmez. Brüt + KDV alacak, kesintiler borç olarak bu kurla TL'ye çevrilir. Bu işlem ödeme değildir.",
                 initial: "") { text in
        guard let rate = HakedisMath.parseExchangeRate(text) else { return false }
        return await model.post(exchangeRate: rate)
      }
    case .cancelPayment(let payment):
      ReasonSheet(title: "Ödemeyi iptal et", message: "Ödeme ters kayıtla geri alınır.", actionTitle: "İptal et",
                  destructive: true) { await model.cancelPayment(payment, reason: $0) }
    }
  }
}

/// Tek değer girişi (ilerleme yüzdesi, kesinti tutarı).
struct ValueSheet: View {
  let title: String
  let label: String
  let message: String
  let initial: String
  let action: (String) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var isWorking = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(label, text: $text)
            .keyboardType(.decimalPad)
            .font(RDFont.metric)
            .monospacedDigit()
        } footer: {
          Text(message)
        }
        .rdRowBackground()
      }
      .rdScreen()
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            Task {
              isWorking = true
              if await action(text) { dismiss() }
              isWorking = false
            }
          }
          .fontWeight(.semibold)
          .disabled(isWorking)
        }
      }
      .onAppear { text = initial }
    }
    .presentationDetents([.medium])
  }
}
