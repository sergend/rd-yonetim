import RDCore
import RDDesign
import SwiftUI

/// Gider ve gelir kategorileri. Kategoriler veridir: yetkili kullanıcı ekler,
/// yeniden adlandırır veya pasifleştirir (silinmez; eski kayıtlar korunur).
struct FinanceCategoryListView: View {
  @State private var model: FinanceCategoryListViewModel
  @State private var editing: FinanceCategory?

  init(app: AppModel) {
    _model = State(initialValue: FinanceCategoryListViewModel(access: app.access, repository: app.repositories.finance))
  }

  var body: some View {
    List {
      Section {
        Picker("Tür", selection: $model.kind) {
          ForEach(FinanceDocKind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
      }
      .rdRowBackground()
      if let error = model.errorMessage {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ForEach(model.visible) { category in
          Button {
            if model.canManage { editing = category }
          } label: {
            RDRow(title: category.name) {
              if !category.isActive { RDStatusBadge(text: "Pasif") }
            } trailing: {
              EmptyView()
            }
          }
          .buttonStyle(.plain)
          .disabled(!model.canManage)
        }
      } footer: {
        Text(model.canManage ? "Düzenlemek için dokunun. Kullanılmayan kategori pasif yapılır; geçmiş kayıtlar etkilenmez."
                             : "Kategori eklemek için yetki gerekir.")
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle("Kategoriler")
    .toolbar {
      if model.canManage {
        ToolbarItem(placement: .primaryAction) {
          Button { editing = FinanceCategory(kind: model.kind, name: "") } label: { Image(systemName: "plus") }
            .accessibilityLabel("Yeni kategori")
        }
      }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
    .sheet(item: $editing) { category in
      FinanceCategorySheet(category: category) { await model.save($0) }
    }
  }
}

private struct FinanceCategorySheet: View {
  @State var category: FinanceCategory
  let save: (FinanceCategory) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var isWorking = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Kategori adı", text: $category.name)
          Stepper("Sıra: \(category.sortOrder)", value: $category.sortOrder, in: 0...999, step: 10)
          Toggle("Etkin", isOn: $category.isActive)
        } footer: {
          Text("Pasif kategori yeni kayıtlarda seçilemez.")
        }
        .rdRowBackground()
      }
      .rdScreen()
      .navigationTitle(category.name.isEmpty ? "Yeni kategori" : category.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            Task {
              isWorking = true
              if await save(category) { dismiss() }
              isWorking = false
            }
          }
          .fontWeight(.semibold)
          .disabled(category.name.nilIfBlank == nil || isWorking)
        }
      }
    }
    .presentationDetents([.medium])
  }
}
