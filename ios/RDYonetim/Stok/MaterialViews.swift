import RDCore
import RDDesign
import SwiftUI

// MARK: - Katalog

/// Malzeme kataloğu: kategoriye göre gruplu liste, arama ve kategori filtresi.
struct MaterialCatalogView: View {
  @State private var model: MaterialCatalogViewModel
  @State private var showingForm = false
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: MaterialCatalogViewModel(access: app.access, repositories: app.repositories))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.materials.isEmpty {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      ForEach(model.grouped) { group in
        Section(group.category?.name ?? "Kategorisiz") {
          ForEach(group.materials) { material in
            NavigationLink(value: AppRoute.material(material)) {
              RDRow(symbol: "shippingbox", symbolTint: RDColor.brandText, title: material.name,
                    subtitle: "\(material.code) · \(model.lookup.units[material.baseUnitId]?.name ?? "")") {
                if !material.isActive { RDStatusBadge(text: "Pasif") }
              } trailing: {
                EmptyView()
              }
            }
          }
        }
        .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .searchable(text: $model.searchText, prompt: "Malzeme adı veya kodu")
    .navigationTitle("Malzeme kataloğu")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Kategori", selection: $model.categoryId) {
            Text("Tüm kategoriler").tag(UUID?.none)
            ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
          }
          Toggle("Pasifleri göster", isOn: $model.showInactive)
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filtre")
      }
      if model.canManage {
        ToolbarItem(placement: .primaryAction) {
          Button { showingForm = true } label: { Image(systemName: "plus") }
            .accessibilityLabel("Yeni malzeme")
        }
      }
    }
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Malzeme yok",
                                  message: model.searchText.isEmpty ? "Katalogda kayıtlı malzeme yok." : "Aramaya uyan malzeme yok.",
                                  symbol: "shippingbox"),
                    retry: { Task { await model.load() } })
    .refreshable { await model.load() }
    .task { await model.load() }
    .sheet(isPresented: $showingForm) {
      MaterialFormView(material: nil, app: app) { _ in Task { await model.load() } }
    }
  }
}

// MARK: - Detay

/// Malzeme detayı: temel birim, dönüşüm oranları, depolardaki miktarlar ve son hareketler.
struct MaterialDetailView: View {
  @State private var model: MaterialDetailViewModel
  @State private var editing = false
  private let app: AppModel

  init(material: RDCore.Material, app: AppModel) {
    self.app = app
    _model = State(initialValue: MaterialDetailViewModel(material: material, access: app.access,
                                                         repositories: app.repositories))
  }

  var body: some View {
    let material = model.material
    List {
      if let error = model.errorMessage {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        RDRow(symbol: "shippingbox", symbolTint: RDColor.brandText, title: material.name, subtitle: material.code) {
          if !material.isActive { RDStatusBadge(text: "Pasif") }
        } trailing: {
          EmptyView()
        }
        RDInfoRow(label: "Kategori", value: model.lookup.categories[material.categoryId]?.name ?? "—")
        RDInfoRow(label: "Temel birim", value: model.lookup.units[material.baseUnitId]?.name ?? "—")
        if let description = material.description { RDInfoRow(label: "Açıklama", value: description) }
      } footer: {
        Text("Stok her zaman temel birimle tutulur. Hareket veya sipariş varken temel birim değiştirilemez.")
      }
      .rdRowBackground()

      Section("Birim dönüşümleri") {
        if model.conversions.isEmpty {
          Text("Tanımlı dönüşüm yok; yalnızca temel birim kullanılır.").foregroundStyle(RDColor.textSecondary)
        }
        ForEach(model.conversions) { conversion in
          RDRow(title: "1 \(model.lookup.units[conversion.unitId]?.symbol ?? "") = \(model.lookup.format(conversion.factor, unit: material.baseUnitId))",
                subtitle: conversion.note) {
            if !conversion.isActive { RDStatusBadge(text: "Pasif") }
          } trailing: {
            EmptyView()
          }
        }
      }
      .rdRowBackground()

      Section("Depolardaki miktar") {
        if model.balances.isEmpty {
          Text("Hiçbir depoda stok yok.").foregroundStyle(RDColor.textSecondary)
        }
        ForEach(model.balances, id: \.warehouseId) { balance in
          RDRow(symbol: "archivebox", title: model.lookup.warehouseName(balance.warehouseId),
                subtitle: app.projectName(model.lookup.warehouses[balance.warehouseId]?.projectId) ?? "Genel depo") {
            Text(model.lookup.formatBase(balance.quantity, material: material.id)).monospacedDigit()
          }
        }
      }
      .rdRowBackground()

      if !model.movements.isEmpty {
        Section("Son hareketler") {
          ForEach(model.movements) { movement in
            NavigationLink(value: AppRoute.stockMovement(movement)) {
              StockMovementRow(movement: movement, lookup: model.lookup)
            }
          }
        }
        .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(material.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.canManage { Button("Düzenle") { editing = true } }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
    .sheet(isPresented: $editing) {
      MaterialFormView(material: material, app: app) { _ in Task { await model.load() } }
    }
  }
}

// MARK: - Form

/// Malzeme kartı ve açık dönüşüm oranları. Oran tahmin edilmez; kullanıcı
/// "1 ton = 1000 kg" gibi açıkça yazar. Tanımlı oran değişmez, pasifleştirilir.
struct MaterialFormView: View {
  @State private var model: MaterialFormViewModel
  @Environment(\.dismiss) private var dismiss
  private let onSave: (RDCore.Material) -> Void

  init(material: RDCore.Material?, app: AppModel, onSave: @escaping (RDCore.Material) -> Void) {
    _model = State(initialValue: MaterialFormViewModel(material: material, access: app.access,
                                                       repositories: app.repositories))
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Malzeme adı", text: $model.name)
          Picker("Kategori", selection: $model.categoryId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
          }
          Picker("Temel birim", selection: $model.baseUnitId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(model.units) { Text($0.name).tag(Optional($0.id)) }
          }
        } footer: {
          Text("Stok bu birimle tutulur. Hareket, sipariş veya dönüşüm oranı varken değiştirilemez.")
        }
        .rdRowBackground()

        Section {
          TextField("Kod (boşsa otomatik)", text: $model.code)
            .textInputAutocapitalization(.characters)
          TextField("Açıklama", text: $model.description, axis: .vertical).lineLimit(1...4)
          Toggle("Etkin", isOn: $model.isActive)
        }
        .rdRowBackground()

        if !model.isNew {
          conversionSection
        }

        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle(model.isNew ? "Yeni malzeme" : "Malzemeyi düzenle")
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
          .disabled(model.isSaving || model.validationMessage != nil)
        }
      }
      .task { await model.load() }
      .interactiveDismissDisabled(model.isSaving)
    }
  }

  private var conversionSection: some View {
    Section {
      ForEach(model.conversions) { conversion in
        HStack {
          Text("1 \(model.unitSymbol(conversion.unitId)) = \(DecimalInput.format(conversion.factor, maxFractionDigits: 6)) \(model.unitSymbol(model.baseUnitId))")
            .foregroundStyle(conversion.isActive ? RDColor.textPrimary : RDColor.textSecondary)
          Spacer()
          if conversion.isActive {
            Button("Pasifleştir") { Task { await model.deactivate(conversion) } }
              .font(RDFont.secondary)
          } else {
            RDStatusBadge(text: "Pasif")
          }
        }
      }
      if !model.conversionCandidates.isEmpty {
        Picker("Birim", selection: $model.conversionUnitId) {
          Text("Seçin").tag(UUID?.none)
          ForEach(model.conversionCandidates) { Text($0.name).tag(Optional($0.id)) }
        }
        HStack {
          Text("1 \(model.unitSymbol(model.conversionUnitId)) =")
          TextField("oran", text: $model.conversionFactorText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
          Text(model.unitSymbol(model.baseUnitId))
        }
        TextField("Not (ör. tedarikçi çeki)", text: $model.conversionNote)
        Button("Oranı ekle") { Task { await model.addConversion() } }
          .disabled(model.conversionUnitId == nil || model.conversionFactorText.isEmpty)
      }
    } header: {
      Text("Birim dönüşümleri")
    } footer: {
      Text("Yalnızca burada açıkça yazılan oranlar kullanılır; sistem oran tahmin etmez.")
    }
    .rdRowBackground()
  }
}
