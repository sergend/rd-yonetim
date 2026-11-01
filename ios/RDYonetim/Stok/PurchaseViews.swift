import RDCore
import RDDesign
import SwiftUI

// MARK: - Liste

/// Satın alma siparişleri. Sipariş borç, gider veya ödeme oluşturmaz;
/// gerçek borç gelen faturanın gider olarak onaylanmasıyla doğar.
struct PurchaseOrderListView: View {
  @State private var model: PurchaseOrderListViewModel
  @State private var showingForm = false
  private let app: AppModel

  init(projectId: UUID?, app: AppModel) {
    self.app = app
    _model = State(initialValue: PurchaseOrderListViewModel(projectId: projectId, access: app.access,
                                                            repositories: app.repositories))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.orders.isEmpty {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: .rdS) {
            filterChip(nil, title: "Tümü")
            filterChip(.onaylandi, title: "Teslim bekleyen")
            filterChip(.kismiTeslim, title: PurchaseOrderStatus.kismiTeslim.title)
            filterChip(.taslak, title: "Onay bekleyen")
            filterChip(.tamamlandi, title: PurchaseOrderStatus.tamamlandi.title)
            filterChip(.iptal, title: PurchaseOrderStatus.iptal.title)
          }
          .padding(.vertical, .rdXS)
        }
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())

      Section {
        ForEach(model.filtered) { order in
          NavigationLink(value: AppRoute.purchaseOrder(order)) {
            PurchaseOrderRow(order: order, supplierName: model.supplierName(order.cariAccountId),
                             warehouseName: warehouseName(order))
          }
        }
      } footer: {
        if !model.filtered.isEmpty {
          Text("Sipariş borç doğurmaz. Fatura gider olarak girilip onaylanınca borç oluşur ve siparişe bağlanabilir.")
        }
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .searchable(text: $model.searchText, prompt: "Sipariş no, tedarikçi, depo")
    .navigationTitle("Satın alma")
    .toolbar {
      if model.canCreate {
        ToolbarItem(placement: .primaryAction) {
          Button { showingForm = true } label: { Image(systemName: "plus") }
            .accessibilityLabel("Yeni sipariş")
        }
      }
    }
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Sipariş yok",
                                  message: model.canCreate ? "Yeni sipariş için + düğmesini kullanın." : "Görebileceğiniz sipariş yok.",
                                  symbol: AppModule.satinAlma.symbol),
                    retry: { Task { await model.load() } })
    .refreshable { await model.load() }
    .task { await model.load() }
    .sheet(isPresented: $showingForm) {
      PurchaseOrderFormView(order: nil, projectId: model.projectId, app: app) { _ in Task { await model.load() } }
    }
  }

  private func warehouseName(_ order: PurchaseOrder) -> String {
    let w = model.lookup.warehouseName(order.warehouseId)
    return order.projectId.flatMap { app.projectName($0) }.map { "\($0) · \(w)" } ?? w
  }

  private func filterChip(_ status: PurchaseOrderStatus?, title: String) -> some View {
    let selected = model.statusFilter == status
    return Button(title) { model.statusFilter = status }
      .font(RDFont.secondary.weight(.semibold))
      .padding(.horizontal, .rdM)
      .frame(minHeight: Metrics.minTouchTarget)
      .foregroundStyle(selected ? RDColor.onBrand : RDColor.textPrimary)
      .background(selected ? RDColor.brand : RDColor.surface, in: Capsule())
      .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

// MARK: - Detay

struct PurchaseOrderDetailView: View {
  @State private var model: PurchaseOrderDetailViewModel
  @State private var sheet: Sheet?
  @State private var confirmApprove = false
  private let app: AppModel

  enum Sheet: Identifiable {
    case edit, receive, cancel, close, cancelReceipt(PurchaseReceipt), linkExpense, linkDocument

    var id: String {
      switch self {
      case .edit: "edit"
      case .receive: "receive"
      case .cancel: "cancel"
      case .close: "close"
      case .cancelReceipt(let r): "cr-\(r.id)"
      case .linkExpense: "expense"
      case .linkDocument: "document"
      }
    }
  }

  init(order: PurchaseOrder, app: AppModel) {
    self.app = app
    _model = State(initialValue: PurchaseOrderDetailViewModel(order: order, access: app.access, repositories: app.repositories))
  }

  var body: some View {
    let order = model.order
    List {
      if let error = model.errorMessage {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      headerSection(order)
      linesSection(order)
      actionsSection
      receiptsSection
      linksSection
      if !model.events.isEmpty {
        Section("Geçmiş") {
          ForEach(model.events) { event in
            RDRow(title: event.title, subtitle: [event.occurredAt?.formatted(date: .abbreviated, time: .shortened), event.reason]
              .compactMap { $0 }.joined(separator: " · "))
          }
        }
        .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(order.orderNo)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.canEdit { Button("Düzenle") { sheet = .edit } }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
    .disabled(model.isWorking)
    .confirmationDialog("Sipariş onaylansın mı?", isPresented: $confirmApprove, titleVisibility: .visible) {
      Button("Onayla") { Task { await model.perform(.onayla) } }
      Button("Vazgeç", role: .cancel) {}
    } message: {
      Text("Onaylı sipariş teslim alınabilir. Onay borç, gider veya ödeme oluşturmaz.")
    }
    .sheet(item: $sheet) { sheetView($0) }
  }

  // MARK: Bölümler

  private func headerSection(_ order: PurchaseOrder) -> some View {
    Section {
      RDRow(title: model.supplier?.title ?? "Tedarikçi", subtitle: order.description) {
        if order.isDemo { RDDemoBadge() }
      } trailing: {
        RDStatusBadge(text: order.status.title, tone: order.status.tone)
      }
      RDInfoRow(label: "Teslim deposu", value: model.lookup.warehouseName(order.warehouseId))
      if let project = app.projectName(order.projectId) { RDInfoRow(label: "Proje", value: project) }
      RDInfoRow(label: "Sipariş tarihi", value: order.orderDate.display)
      if let expected = order.expectedDate { RDInfoRow(label: "Beklenen teslim", value: expected.display) }
      if let notes = order.notes { RDInfoRow(label: "Not", value: notes) }
      if let reason = order.closeReason { RDInfoRow(label: "Kapatma gerekçesi", value: reason) }
      if let reason = order.cancelReason { RDInfoRow(label: "İptal gerekçesi", value: reason) }
    }
    .rdRowBackground()
  }

  private func linesSection(_ order: PurchaseOrder) -> some View {
    Section {
      ForEach(model.lines) { line in
        VStack(alignment: .leading, spacing: .rdXS) {
          HStack(alignment: .firstTextBaseline) {
            Text("\(line.lineNo). \(model.lookup.materialName(line.materialId))").font(RDFont.rowTitle)
            Spacer()
            Text(model.lookup.format(line.quantity, unit: line.unitId)).monospacedDigit()
          }
          Text("Teslim alınan \(model.lookup.format(line.receivedQuantity, unit: line.unitId)) · kalan \(model.lookup.format(line.remainingQuantity, unit: line.unitId))")
            .font(RDFont.secondary)
            .foregroundStyle(line.isFullyReceived ? RDColor.tone(.success) : RDColor.textSecondary)
          if let price = model.prices[line.id], let unitPrice = price.unitPrice {
            Text("Birim fiyat \(Money.format(unitPrice, currency: order.currency)) · satır \(Money.format(price.lineTotal ?? 0, currency: order.currency))")
              .font(RDFont.caption)
              .foregroundStyle(RDColor.textSecondary)
          }
          if let note = line.note { Text(note).font(RDFont.caption).foregroundStyle(RDColor.textSecondary) }
        }
        .padding(.vertical, .rdXS)
        .accessibilityElement(children: .combine)
      }
      if let total = model.informationalTotal {
        RDInfoRow(label: "Sipariş tutarı (bilgi)", value: Money.format(total, currency: order.currency))
      }
    } header: {
      Text("Malzemeler")
    } footer: {
      Text(model.canSeePrices
           ? "Tutar yalnızca bilgidir: borç, gider veya ödeme oluşturmaz ve finans raporlarına girmez."
           : "Fiyatlar satın alma okuma izni olanlara gösterilir.")
    }
    .rdRowBackground()
  }

  @ViewBuilder private var actionsSection: some View {
    if model.canReceive || model.canApprove || model.canClose || model.canCancel {
      Section {
        if model.canReceive {
          Button { sheet = .receive } label: { Label("Teslim al", systemImage: "shippingbox.and.arrow.backward") }
        }
        if model.canApprove {
          Button { confirmApprove = true } label: { Label("Siparişi onayla", systemImage: "checkmark.seal") }
        }
        if model.canClose {
          Button { sheet = .close } label: { Label("Eksik teslimle kapat", systemImage: "checkmark.circle") }
        }
        if model.canCancel {
          Button(role: .destructive) { sheet = .cancel } label: { Label("Siparişi iptal et", systemImage: "xmark.circle") }
        }
      }
      .rdRowBackground()
    }
  }

  @ViewBuilder private var receiptsSection: some View {
    if !model.receipts.isEmpty {
      Section {
        ForEach(model.receipts) { receipt in
          RDRow(symbol: "shippingbox", title: receipt.receiptNo,
                subtitle: [receipt.receiptDate.display, receipt.waybillNo.map { "İrsaliye \($0)" }, receipt.cancelReason]
                  .compactMap { $0 }.joined(separator: " · ")) {
            if receipt.status == .iptal { RDStatusBadge(text: "İptal") }
          } trailing: {
            if receipt.status == .aktif && model.canCancelReceipt {
              Button("İptal") { sheet = .cancelReceipt(receipt) }
                .font(RDFont.secondary)
                .foregroundStyle(RDColor.tone(.danger))
            }
          }
        }
        NavigationLink(value: AppRoute.stockMovements(warehouseId: model.order.warehouseId, materialId: nil)) {
          Text("Teslim deposunun hareketleri").foregroundStyle(RDColor.brandText)
        }
      } header: {
        Text("Teslimler")
      } footer: {
        Text("Her teslim bir kez stok girişi açar; aynı teslimin tekrar gönderimi ikinci giriş açmaz. İptal ters kayıtla yapılır.")
      }
      .rdRowBackground()
    }
  }

  @ViewBuilder private var linksSection: some View {
    Section {
      if model.canSeePrices {
        ForEach(model.activeExpenseLinks) { link in
          if let expense = model.linkedExpenses[link.financeDocumentId] {
            NavigationLink(value: AppRoute.financeDocument(expense)) {
              RDRow(symbol: AppModule.giderler.symbol, title: expense.description,
                    subtitle: "\(expense.documentNo) · \(expense.status.title)")
            }
          } else {
            RDRow(symbol: AppModule.giderler.symbol, title: "Bağlı gider kaydı", subtitle: "Görme yetkiniz yok")
          }
        }
        if model.canLinkExpense {
          Button { sheet = .linkExpense } label: { Label("Gider (fatura) bağla", systemImage: "link") }
        }
      }
      ForEach(model.activeDocumentLinks) { link in
        if let document = model.linkedDocuments[link.documentId] {
          NavigationLink(value: AppRoute.archiveDocument(document)) {
            RDRow(symbol: document.kind.symbol, title: document.title, subtitle: document.kind.title)
          }
        } else {
          RDRow(symbol: "doc", title: "Bağlı belge", subtitle: "Görme yetkiniz yok")
        }
      }
      if model.canLinkDocument {
        Button { sheet = .linkDocument } label: { Label("Arşivden belge bağla", systemImage: "doc.badge.plus") }
      }
    } header: {
      Text("Bağlı fatura ve belgeler")
    } footer: {
      Text("Bağlantı yalnızca bilgidir: yeni gider, cari borç veya ödeme açmaz. Bir gider en fazla bir siparişe bağlanır.")
    }
    .rdRowBackground()
  }

  @ViewBuilder
  private func sheetView(_ sheet: Sheet) -> some View {
    switch sheet {
    case .edit:
      PurchaseOrderFormView(order: model.order, projectId: model.order.projectId, app: app) { _ in Task { await model.load() } }
    case .receive:
      PurchaseReceiptFormView(order: model.order, app: app) { _ in Task { await model.load() } }
    case .cancel:
      ReasonSheet(title: "Siparişi iptal et",
                  message: model.order.status == .taslak ? "Taslak sipariş kapatılır; kayıt silinmez."
                    : "Teslim alınmamış onaylı sipariş iptal edilir; geçmiş korunur.",
                  actionTitle: "İptal et", minimumLength: model.order.status == .taslak ? 3 : 10, destructive: true) { reason in
        model.reason = reason
        await model.perform(.iptal)
        return model.errorMessage == nil
      }
    case .close:
      ReasonSheet(title: "Eksik teslimle kapat", message: "Kalan miktar artık beklenmez; teslim alınanlar stokta kalır.",
                  actionTitle: "Kapat") { reason in
        model.reason = reason
        await model.perform(.kapat)
        return model.errorMessage == nil
      }
    case .cancelReceipt(let receipt):
      ReasonSheet(title: "\(receipt.receiptNo) iptal", message: "Teslimin stok girişleri ters kayıtla geri alınır. Malzeme kullanıldıysa önce o hareketler geri alınmalı.",
                  actionTitle: "Teslimi iptal et", destructive: true) { reason in
        model.reason = reason
        await model.cancelReceipt(receipt)
        return model.errorMessage == nil
      }
    case .linkExpense:
      ExpenseLinkPicker(model: model)
    case .linkDocument:
      DocumentLinkPicker(model: model)
    }
  }
}

/// Siparişe bağlanacak gider kaydını seçme (aynı proje, aynı tedarikçi veya carisiz).
private struct ExpenseLinkPicker: View {
  let model: PurchaseOrderDetailViewModel
  @State private var candidates: [FinanceDocument] = []
  @State private var isLoading = true
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(candidates) { expense in
            Button {
              Task {
                await model.linkExpense(expense)
                if model.errorMessage == nil { dismiss() }
              }
            } label: {
              RDRow(symbol: AppModule.giderler.symbol, title: expense.description,
                    subtitle: "\(expense.documentNo) · \(expense.documentDate.display) · \(expense.status.title)") {
                Text(Money.format(expense.amount, currency: expense.currency)).monospacedDigit()
              }
            }
          }
        } footer: {
          Text("Bağlantı gider kaydını değiştirmez ve ikinci bir finans kaydı açmaz.")
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage)
      }
      .listStyle(.insetGrouped)
      .rdScreen()
      .navigationTitle("Gider bağla")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } } }
      .rdContentState(isLoading: isLoading, isEmpty: candidates.isEmpty, error: nil,
                      empty: .empty(title: "Uygun gider yok",
                                    message: "Aynı projede, iptal edilmemiş ve başka siparişe bağlı olmayan gider kaydı yok.",
                                    symbol: "cart"),
                      retry: {})
      .task {
        candidates = await model.expenseCandidates()
        isLoading = false
      }
    }
  }
}

/// Arşivdeki belgeyi (irsaliye, fatura fotoğrafı) siparişe bağlama.
private struct DocumentLinkPicker: View {
  let model: PurchaseOrderDetailViewModel
  @State private var candidates: [ArchiveDocument] = []
  @State private var isLoading = true
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(candidates) { document in
            Button {
              Task {
                await model.linkDocument(document)
                if model.errorMessage == nil { dismiss() }
              }
            } label: {
              RDRow(symbol: document.kind.symbol, title: document.title,
                    subtitle: "\(document.kind.title) · \(document.documentDate.display)")
            }
          }
        } footer: {
          Text("Belgeyi önce Belgeler bölümünden yükleyin; burada yalnızca bağlantı kurulur.")
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage)
      }
      .listStyle(.insetGrouped)
      .rdScreen()
      .navigationTitle("Belge bağla")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } } }
      .rdContentState(isLoading: isLoading, isEmpty: candidates.isEmpty, error: nil,
                      empty: .empty(title: "Uygun belge yok", message: "Bu projede yüklenmiş belge yok.", symbol: "doc"),
                      retry: {})
      .task {
        candidates = await model.documentCandidates()
        isLoading = false
      }
    }
  }
}

// MARK: - Sipariş formu

struct PurchaseOrderFormView: View {
  @State private var model: PurchaseOrderFormViewModel
  @Environment(\.dismiss) private var dismiss
  private let onSave: (PurchaseOrder) -> Void

  init(order: PurchaseOrder?, projectId: UUID?, app: AppModel, onSave: @escaping (PurchaseOrder) -> Void) {
    _model = State(initialValue: PurchaseOrderFormViewModel(order: order, projectId: projectId, access: app.access,
                                                            repositories: app.repositories))
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Teslim deposu", selection: $model.warehouseId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(model.warehouses) { Text($0.isDemo ? "\($0.name) (DEMO)" : $0.name).tag(Optional($0.id)) }
          }
          Picker("Tedarikçi", selection: $model.cariAccountId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(model.eligibleSuppliers) { Text($0.isDemo ? "\($0.title) (DEMO)" : $0.title).tag(Optional($0.id)) }
          }
          .pickerStyle(.navigationLink)
          DatePicker("Sipariş tarihi", selection: calendarBinding({ model.orderDate }, { model.orderDate = $0 }),
                     displayedComponents: .date)
          Toggle("Beklenen teslim tarihi", isOn: $model.hasExpectedDate)
          if model.hasExpectedDate {
            DatePicker("Beklenen", selection: calendarBinding({ model.expectedDate }, { model.expectedDate = $0 }),
                       displayedComponents: .date)
          }
        } footer: {
          Text("DEMO depoya yalnızca DEMO tedarikçi seçilebilir.")
        }
        .rdRowBackground()

        ForEach($model.lines) { $line in
          Section {
            Picker("Malzeme", selection: $line.materialId) {
              Text("Seçin").tag(UUID?.none)
              ForEach(model.materials) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.navigationLink)
            HStack {
              TextField("Miktar", text: $line.quantityText).keyboardType(.decimalPad).monospacedDigit()
              let units = model.units(for: line)
              if units.count > 1 {
                Picker("Birim", selection: $line.unitId) {
                  ForEach(units) { unit in
                    Text(unit.symbol).tag(unit.id == units.first?.id ? UUID?.none : Optional(unit.id))
                  }
                }
                .labelsHidden()
              } else if let unit = units.first {
                Text(unit.symbol).foregroundStyle(RDColor.textSecondary)
              }
            }
            if model.canSeePrices {
              TextField("Birim fiyat (\(model.currency), isteğe bağlı)", text: $line.unitPriceText).keyboardType(.decimalPad)
            }
            TextField("Satır notu", text: $line.note)
            if model.lines.count > 1 {
              Button("Satırı kaldır", role: .destructive) { model.removeLine(id: line.id) }
            }
          } header: {
            Text("Satır \((model.lines.firstIndex(where: { $0.id == line.id }) ?? 0) + 1)")
          }
          .rdRowBackground()
        }

        Section {
          Button { model.addLine() } label: { Label("Satır ekle", systemImage: "plus.circle") }
        }
        .rdRowBackground()

        Section {
          TextField("Açıklama", text: $model.description, axis: .vertical).lineLimit(1...3)
          TextField("Not", text: $model.notes, axis: .vertical).lineLimit(1...3)
          if model.canSeePrices {
            TextField("Para birimi", text: $model.currency).textInputAutocapitalization(.characters)
          }
        } footer: {
          Text("Sipariş borç, gider veya ödeme oluşturmaz. Fiyat bilgi amaçlıdır.")
        }
        .rdRowBackground()

        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle(model.isNew ? "Yeni sipariş" : "Siparişi düzenle")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            Task {
              if let saved = await model.save() {
                onSave(saved)
                dismiss()
              }
            }
          }
          .fontWeight(.semibold)
          .disabled(model.isSaving)
        }
      }
      .task { await model.load() }
      .interactiveDismissDisabled(model.isSaving)
    }
  }
}

// MARK: - Teslim alma

/// Sahada teslim: her satıra gelen miktar (kalanı aşamaz), irsaliye no.
struct PurchaseReceiptFormView: View {
  @State private var model: PurchaseReceiptFormViewModel
  @Environment(\.dismiss) private var dismiss
  private let onSave: (PurchaseReceipt) -> Void

  init(order: PurchaseOrder, app: AppModel, onSave: @escaping (PurchaseReceipt) -> Void) {
    _model = State(initialValue: PurchaseReceiptFormViewModel(order: order, access: app.access,
                                                              repositories: app.repositories))
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(model.openLines) { line in
            VStack(alignment: .leading, spacing: .rdXS) {
              Text("\(line.lineNo). \(model.lookup.materialName(line.materialId))").font(RDFont.rowTitle)
              HStack {
                TextField("Gelen miktar", text: quantityBinding(line.id))
                  .keyboardType(.decimalPad)
                  .monospacedDigit()
                Text(model.lookup.units[line.unitId]?.symbol ?? "").foregroundStyle(RDColor.textSecondary)
              }
              Text("Kalan \(model.lookup.format(line.remainingQuantity, unit: line.unitId))")
                .font(RDFont.caption)
                .foregroundStyle(RDColor.textSecondary)
            }
          }
          if !model.openLines.isEmpty {
            Button("Kalanın tamamı geldi") { model.fillRemaining() }
          }
        } header: {
          Text("Gelen malzeme")
        } footer: {
          Text("Kalan miktardan fazlası teslim alınamaz. Kaydedince teslim deposuna stok girişi yapılır.")
        }
        .rdRowBackground()

        Section {
          TextField("İrsaliye no", text: $model.waybillNo)
          TextField("Teslim alan", text: $model.performedBy)
          DatePicker("Teslim tarihi", selection: calendarBinding({ model.receiptDate }, { model.receiptDate = $0 }),
                     in: ...Date(), displayedComponents: .date)
          TextField("Not", text: $model.note, axis: .vertical).lineLimit(1...3)
        } footer: {
          Text("İrsaliye fotoğrafını Belgeler bölümünden yükleyip siparişe bağlayabilirsiniz.")
        }
        .rdRowBackground()

        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle("Teslim al · \(model.order.orderNo)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            Task {
              if let saved = await model.submit() {
                onSave(saved)
                dismiss()
              }
            }
          }
          .fontWeight(.semibold)
          .disabled(model.isSaving)
        }
      }
      .task { await model.load() }
      .interactiveDismissDisabled(model.isSaving)
    }
  }

  private func quantityBinding(_ id: UUID) -> Binding<String> {
    Binding(get: { model.quantities[id] ?? "" }, set: { model.quantities[id] = $0 })
  }
}
