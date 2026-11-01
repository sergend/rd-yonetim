import RDCore
import RDDesign
import SwiftUI

// MARK: - Stok durumu

/// Depo seçimi, mevcut miktarlar ve onay bekleyen hareketler. Tutar göstermez.
struct StockOverviewView: View {
  @State private var model: StockOverviewViewModel
  @State private var form: StockMovementKind?
  private let app: AppModel

  init(projectId: UUID?, app: AppModel) {
    self.app = app
    _model = State(initialValue: StockOverviewViewModel(projectId: projectId, access: app.access,
                                                        repositories: app.repositories))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.warehouses.isEmpty {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      if !model.warehouses.isEmpty {
        Section {
          Picker("Depo", selection: warehouseSelection) {
            ForEach(model.warehouses) { w in
              Text(warehouseTitle(w)).tag(Optional(w.id))
            }
          }
          if let w = model.selectedWarehouse, w.isDemo {
            Label("DEMO depo: kayıtları gerçek stoka karışmaz.", systemImage: "info.circle")
              .font(RDFont.caption)
              .foregroundStyle(RDColor.tone(.warning))
          }
        }
        .rdRowBackground()
      }

      if model.canWrite {
        Section("Hızlı hareket") {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: .rdS) {
              ForEach(StockMovementKind.manual) { kind in
                Button { form = kind } label: {
                  Label(kind.title, systemImage: kind.symbol)
                }
                .buttonStyle(.rdSecondary)
                .fixedSize()
              }
            }
            .padding(.vertical, .rdXS)
          }
        }
        .rdRowBackground()
      }

      if !model.pendingMovements.isEmpty {
        Section {
          ForEach(model.pendingMovements) { movement in
            NavigationLink(value: AppRoute.stockMovement(movement)) {
              StockMovementRow(movement: movement, lookup: model.lookup, warehouseId: model.selectedWarehouseId)
            }
          }
        } header: {
          Text("Onay bekleyen (\(model.pendingMovements.count))")
        } footer: {
          Text(model.canApprove ? "Onaylanan hareket stoka işlenir." : "Onaylandığında stoka işlenir; şu an miktara yansımaz.")
        }
        .rdRowBackground()
      }

      Section {
        ForEach(model.filteredRows) { row in
          NavigationLink(value: AppRoute.stockMovements(warehouseId: model.selectedWarehouseId, materialId: row.materialId)) {
            StockRow(row: row, lookup: model.lookup)
          }
        }
        if let id = model.selectedWarehouseId {
          NavigationLink(value: AppRoute.stockMovements(warehouseId: id, materialId: nil)) {
            Text("Deponun tüm hareketleri").foregroundStyle(RDColor.brandText)
          }
        }
      } header: {
        Text("Mevcut stok")
      } footer: {
        Text("Miktarlar hareket defterinden hesaplanır; elle değiştirilmez. Düzeltme sayım hareketiyle yapılır.")
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .searchable(text: $model.searchText, prompt: "Malzeme ara")
    .navigationTitle(model.projectId.flatMap { app.projectName($0) }.map { "\($0) stoku" } ?? "Stoklar")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Toggle(isOn: $model.showEmpty) { Label("Stoksuzları göster", systemImage: "eye") }
          .toggleStyle(.button)
          .accessibilityLabel("Stoğu olmayan malzemeleri göster")
      }
    }
    .rdContentState(isLoading: model.isLoading, isEmpty: model.warehouses.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Depo yok", message: "Görebileceğiniz bir depo yok.", symbol: "archivebox"),
                    retry: { Task { await model.load() } })
    .refreshable { await model.load() }
    .task { await model.load() }
    .onChange(of: model.showEmpty) { _, _ in Task { await model.load() } }
    .sheet(item: $form) { kind in
      StockMovementFormView(kind: kind, warehouseId: model.selectedWarehouseId, materialId: nil,
                            projectId: model.projectId, app: app) { _ in Task { await model.load() } }
    }
  }

  private var warehouseSelection: Binding<UUID?> {
    Binding(get: { model.selectedWarehouseId }, set: { id in
      guard let id else { return }
      Task { await model.select(id) }
    })
  }

  private func warehouseTitle(_ w: Warehouse) -> String {
    let scope = w.projectId.flatMap { app.projectName($0) } ?? "Genel"
    return w.isDemo ? "\(scope) · \(w.name) (DEMO)" : "\(scope) · \(w.name)"
  }
}

// MARK: - Hareket geçmişi

struct StockMovementListView: View {
  @State private var model: StockMovementListViewModel
  private let app: AppModel

  init(warehouseId: UUID?, materialId: UUID?, app: AppModel) {
    self.app = app
    _model = State(initialValue: StockMovementListViewModel(warehouseId: warehouseId, materialId: materialId,
                                                            access: app.access, repositories: app.repositories))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.movements.isEmpty {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ForEach(model.filtered) { movement in
          NavigationLink(value: AppRoute.stockMovement(movement)) {
            StockMovementRow(movement: movement, lookup: model.lookup, warehouseId: model.warehouseId)
          }
        }
      } footer: {
        if !model.filtered.isEmpty {
          Text("Hareketler silinmez; yanlış kayıt ters kayıtla iptal edilir.")
        }
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Durum", selection: $model.statusFilter) {
            Text("Tüm durumlar").tag(StockMovementStatus?.none)
            ForEach(StockMovementStatus.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
          }
          Picker("Tür", selection: $model.kindFilter) {
            Text("Tüm türler").tag(StockMovementKind?.none)
            ForEach(StockMovementKind.allCases) { Text($0.title).tag(Optional($0)) }
          }
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filtre")
      }
    }
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Hareket yok", message: "Bu seçim için kayıtlı hareket yok.",
                                  symbol: "arrow.left.arrow.right"),
                    retry: { Task { await model.load() } })
    .refreshable { await model.load() }
    .task { await model.load() }
  }

  private var title: String {
    if let m = model.materialId { return model.lookup.materialName(m) }
    if let w = model.warehouseId { return model.lookup.warehouseName(w) }
    return "Stok hareketleri"
  }
}

// MARK: - Hareket detayı

struct StockMovementDetailView: View {
  @State private var model: StockMovementDetailViewModel
  @State private var sheet: Sheet?
  @State private var confirmApprove = false
  private let app: AppModel

  enum Sheet: String, Identifiable {
    case reject, reverse
    var id: String { rawValue }
  }

  init(movement: StockMovement, app: AppModel) {
    self.app = app
    let model = StockMovementDetailViewModel(movement: movement, access: app.access, repositories: app.repositories)
    model.currentUserId = app.userId
    _model = State(initialValue: model)
  }

  var body: some View {
    let m = model.movement
    let lookup = model.lookup
    List {
      if let error = model.errorMessage {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        RDRow(symbol: m.kind.symbol, symbolTint: m.kind.tint, title: m.kind.title, subtitle: m.movementNo) {
          if m.isDemo { RDDemoBadge() }
        } trailing: {
          RDStatusBadge(text: m.status.title, tone: m.status.tone)
        }
        RDInfoRow(label: "Malzeme", value: lookup.materialName(m.materialId))
        RDInfoRow(label: m.kind == .transfer ? "Çıkan depo" : "Depo", value: lookup.warehouseName(m.warehouseId))
        if let target = m.targetWarehouseId { RDInfoRow(label: "Alan depo", value: lookup.warehouseName(target)) }
        RDInfoRow(label: m.kind == .sayim ? "Sayılan miktar" : "Miktar", value: lookup.format(m.quantity, unit: m.unitId))
        if m.unitFactor != 1 {
          RDInfoRow(label: "Temel birimde", value: lookup.formatBase(m.baseQuantity, material: m.materialId))
        }
        if let adjustment = m.adjustment {
          RDInfoRow(label: "Sayım farkı", value: (adjustment > 0 ? "+" : "") + lookup.formatBase(adjustment, material: m.materialId))
        }
        RDInfoRow(label: "Tarih", value: m.movementDate.display)
        if let by = m.performedBy { RDInfoRow(label: "Teslim alan / kullanan", value: by) }
        if let d = m.description { RDInfoRow(label: "Açıklama", value: d) }
        if let r = m.reason { RDInfoRow(label: "Gerekçe", value: r) }
        if let r = m.rejectReason { RDInfoRow(label: "Red gerekçesi", value: r) }
      } footer: {
        Text("Stok hareketi tutar içermez; maliyet, ödeme veya cari kayıt oluşturmaz.")
      }
      .rdRowBackground()

      if m.purchaseOrderId != nil || m.documentId != nil || model.reversal != nil || model.original != nil {
        Section("Bağlantılar") {
          if let orderId = m.purchaseOrderId {
            RDInfoRow(label: "Satın alma teslimi", value: m.isFromReceipt ? "Sipariş teslimiyle oluştu" : orderId.uuidString.prefix(8).uppercased())
          }
          if m.documentId != nil {
            RDInfoRow(label: "Belge", value: "Arşivdeki belgeye bağlı")
          }
          if let reversal = model.reversal {
            NavigationLink(value: AppRoute.stockMovement(reversal)) {
              RDRow(symbol: "arrow.counterclockwise", title: "Ters kayıt \(reversal.movementNo)", subtitle: reversal.reason)
            }
          }
          if let original = model.original {
            NavigationLink(value: AppRoute.stockMovement(original)) {
              RDRow(symbol: original.kind.symbol, title: "İptal edilen: \(original.movementNo)", subtitle: original.kind.title)
            }
          }
        }
        .rdRowBackground()
      }

      if model.canApprove || model.canReject || model.canReverse {
        Section {
          if model.canApprove {
            Button("Onayla ve stoka işle") { confirmApprove = true }
          }
          if model.canReject {
            Button(m.createdBy == app.userId ? "Geri çek" : "Reddet", role: .destructive) { sheet = .reject }
          }
          if model.canReverse {
            Button("Ters kayıtla iptal et", role: .destructive) { sheet = .reverse }
          }
        } footer: {
          if m.isFromReceipt {
            Text("Satın alma teslimiyle oluşan giriş, siparişteki teslim kaydı iptal edilerek geri alınır.")
          }
        }
        .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(m.movementNo)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await model.load() }
    .task { await model.load() }
    .disabled(model.isWorking)
    .confirmationDialog("Hareket onaylansın mı?", isPresented: $confirmApprove, titleVisibility: .visible) {
      Button("Onayla") { Task { await model.approve() } }
      Button("Vazgeç", role: .cancel) {}
    } message: {
      Text("Onaylanan hareket stoka işlenir. Sonradan yalnızca ters kayıtla iptal edilebilir.")
    }
    .sheet(item: $sheet) { which in
      switch which {
      case .reject:
        ReasonSheet(title: "Hareketi reddet", message: "Hareket stoka işlenmeden kapatılır; kayıt silinmez.",
                    actionTitle: "Reddet", minimumLength: 3, destructive: true) { reason in
          model.reason = reason
          await model.reject()
          return model.errorMessage == nil
        }
      case .reverse:
        ReasonSheet(title: "Ters kayıtla iptal", message: "Aynı miktarda ters hareket açılır; asıl kayıt ve geçmiş korunur.",
                    actionTitle: "İptal et", destructive: true) { reason in
          model.reason = reason
          await model.reverse()
          return model.errorMessage == nil
        }
      }
    }
  }
}

// MARK: - Hareket formu

/// Sahada hızlı giriş: tür, depo, malzeme, miktar. Ayrıntılar isteğe bağlı.
/// Kaydeden onay yetkisine sahip değilse hareket onaya gönderilir.
struct StockMovementFormView: View {
  @State private var model: StockMovementFormViewModel
  @State private var showDetails = false
  @State private var savedCount = 0
  @FocusState private var quantityFocused: Bool
  @Environment(\.dismiss) private var dismiss
  private let onSave: (StockMovement) -> Void

  init(kind: StockMovementKind, warehouseId: UUID?, materialId: UUID?, projectId: UUID?, app: AppModel,
       onSave: @escaping (StockMovement) -> Void) {
    _model = State(initialValue: StockMovementFormViewModel(kind: kind, warehouseId: warehouseId, materialId: materialId,
                                                            projectId: projectId, access: app.access,
                                                            repositories: app.repositories))
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        if savedCount > 0, let saved = model.saved {
          Section {
            Label(saved.status == .onaylandi ? "\(saved.movementNo) stoka işlendi." : "\(saved.movementNo) onaya gönderildi.",
                  systemImage: "checkmark.circle")
              .foregroundStyle(RDColor.tone(.success))
          }
          .rdRowBackground()
        }
        Section {
          Picker("Tür", selection: $model.kind) {
            ForEach(StockMovementKind.manual) { Text($0.title).tag($0) }
          }
          Picker(model.kind == .transfer ? "Çıkan depo" : "Depo", selection: $model.warehouseId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(model.sourceWarehouses) { Text($0.isDemo ? "\($0.name) (DEMO)" : $0.name).tag(Optional($0.id)) }
          }
          if model.kind == .transfer {
            Picker("Alan depo", selection: $model.targetWarehouseId) {
              Text("Seçin").tag(UUID?.none)
              ForEach(model.targetWarehouses) { Text($0.name).tag(Optional($0.id)) }
            }
          }
          Picker("Malzeme", selection: $model.materialId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(model.materials) { Text($0.name).tag(Optional($0.id)) }
          }
          .pickerStyle(.navigationLink)
          HStack {
            TextField(model.kind == .sayim ? "Sayılan miktar" : "Miktar", text: $model.quantityText)
              .keyboardType(.decimalPad)
              .font(RDFont.metric)
              .monospacedDigit()
              .focused($quantityFocused)
            if model.allowedUnits.count > 1 {
              Picker("Birim", selection: $model.unitId) {
                ForEach(model.allowedUnits) { unit in
                  Text(unit.symbol).tag(unit.id == model.allowedUnits.first?.id ? UUID?.none : Optional(unit.id))
                }
              }
              .labelsHidden()
            } else if let unit = model.selectedUnit {
              Text(unit.symbol).foregroundStyle(RDColor.textSecondary)
            }
          }
          if model.kind.requiresReason {
            TextField("Gerekçe (zorunlu, en az 10 karakter)", text: $model.reason, axis: .vertical).lineLimit(1...3)
          }
        } footer: {
          Text(footer)
        }
        .rdRowBackground()

        Section {
          DisclosureGroup("Tarih, açıklama ve teslim alan", isExpanded: $showDetails) {
            DatePicker("Tarih", selection: calendarBinding({ model.movementDate }, { model.movementDate = $0 }),
                       in: ...Date(), displayedComponents: .date)
            TextField("Teslim alan / kullanan", text: $model.performedBy)
            TextField("Açıklama", text: $model.description, axis: .vertical).lineLimit(1...3)
            if model.kind != .sayim {
              TextField("Gerekçe", text: $model.reason, axis: .vertical).lineLimit(1...3)
            }
          }
        }
        .rdRowBackground()

        RDFormMessage(message: model.errorMessage ?? (model.quantityText.isEmpty ? nil : model.validationMessage))
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle(model.kind.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") { Task { await save(next: false) } }
            .fontWeight(.semibold)
            .disabled(model.isSaving || model.validationMessage != nil)
        }
        ToolbarItem(placement: .bottomBar) {
          Button("Kaydet ve yeni") { Task { await save(next: true) } }
            .disabled(model.isSaving || model.validationMessage != nil)
        }
      }
      .task { await model.load() }
      .onChange(of: model.materialId) { _, _ in Task { await model.refreshStock() } }
      .onChange(of: model.warehouseId) { _, _ in Task { await model.refreshStock() } }
      .interactiveDismissDisabled(model.isSaving)
    }
  }

  private var footer: String {
    var parts: [String] = []
    if let stock = model.currentStock, let materialId = model.materialId {
      parts.append("Depoda \(model.lookup.formatBase(stock, material: materialId)).")
    }
    if let base = model.baseQuantity, let unit = model.selectedUnit, let materialId = model.materialId,
       unit.id != model.lookup.baseUnit(of: materialId)?.id {
      parts.append("Temel birimde \(model.lookup.formatBase(base, material: materialId)).")
    }
    parts.append(model.postsImmediately ? "Kaydedince stoka işlenir." : "Kaydedince onaya gönderilir; onaylanınca stoka işlenir.")
    if model.kind == .sayim { parts.append("Sayım: depoda sayılan miktarı yazın; fark otomatik düzeltilir.") }
    return parts.joined(separator: " ")
  }

  private func save(next: Bool) async {
    guard let saved = await model.submit() else { return }
    onSave(saved)
    if next {
      savedCount += 1
      quantityFocused = true
      await model.refreshStock()
    } else {
      dismiss()
    }
  }
}

