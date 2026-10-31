import RDCore
import RDDesign
import SwiftUI

// MARK: - Liste

/// Gider veya gelir listesi: arama, durum/kategori/dönem filtresi ve hızlı
/// giriş. Her satır ödeme/tahsilat durumunu metinle gösterir.
struct FinanceDocumentListView: View {
  @State private var model: FinanceDocumentListViewModel
  @State private var showingForm = false
  private let app: AppModel

  init(kind: FinanceDocKind, projectId: UUID?, app: AppModel) {
    self.app = app
    _model = State(initialValue: FinanceDocumentListViewModel(kind: kind, projectId: projectId, access: app.access,
                                                              repositories: app.repositories))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.documents.isEmpty {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      filterSection
      Section {
        ForEach(model.filtered) { document in
          NavigationLink(value: AppRoute.financeDocument(document)) {
            FinanceDocumentRow(document: document, status: model.status(document),
                               categoryName: model.categoryName(document.categoryId),
                               scopeName: scopeName(document), cariName: model.cariName(document.cariAccountId))
          }
        }
      } footer: {
        if !model.filtered.isEmpty {
          Text("Onaylanan belge \(model.kind == .gider ? "borç" : "alacak") doğurur; \(model.kind.settlementTitle.lowercased(with: Money.locale)) ayrıca kaydedilir.")
        }
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .searchable(text: $model.searchText, prompt: "Açıklama, belge no, fatura no, cari")
    .navigationTitle(model.kind == .gider ? "Giderler" : "Gelir ve tahsilat")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) { filterMenu }
      if model.canCreate {
        ToolbarItem(placement: .primaryAction) {
          Button { showingForm = true } label: { Image(systemName: "plus") }
            .accessibilityLabel(model.kind == .gider ? "Yeni gider" : "Yeni gelir")
        }
      }
    }
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: model.kind == .gider ? "Gider yok" : "Gelir yok",
                                  message: emptyMessage, symbol: model.kind == .gider ? "cart" : "arrow.down.circle"),
                    retry: { Task { await model.load() } })
    .refreshable { await model.load() }
    .task { await model.load() }
    .onChange(of: model.period) { _, _ in Task { await model.load() } }
    .sheet(isPresented: $showingForm) {
      FinanceDocumentFormView(kind: model.kind, editing: nil, preselectedProject: model.projectId, app: app) { saved in
        Task { await model.upsert(saved) }
      }
    }
  }

  private var emptyMessage: String {
    if model.searchText.nilIfBlank != nil || model.stateFilter != .tumu || model.categoryId != nil {
      return "Filtreye uyan kayıt yok."
    }
    return model.canCreate ? "Yeni kayıt için + düğmesini kullanın." : "Görebileceğiniz kayıt yok."
  }

  /// Yatay kaydırılabilir hızlı durum filtresi.
  private var filterSection: some View {
    Section {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: .rdS) {
          ForEach(FinanceDocumentListViewModel.StateFilter.allCases) { filter in
            let selected = model.stateFilter == filter
            Button {
              model.stateFilter = filter
            } label: {
              Text(chipTitle(filter))
                .font(RDFont.secondary.weight(selected ? .semibold : .regular))
                .padding(.horizontal, .rdM)
                .frame(minHeight: Metrics.minTouchTarget)
                .foregroundStyle(selected ? RDColor.brandText : RDColor.textPrimary)
                .background(selected ? RDColor.brandText.opacity(0.12) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(RDColor.textSecondary.opacity(0.3)))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
          }
        }
      }
      .listRowInsets(EdgeInsets(top: .rdXS, leading: .rdM, bottom: .rdXS, trailing: .rdM))
    }
    .listRowBackground(Color.clear)
  }

  private func chipTitle(_ filter: FinanceDocumentListViewModel.StateFilter) -> String {
    let title = filter.title(for: model.kind)
    switch filter {
    case .onayBekleyen where model.pendingApprovalCount > 0: return "\(title) (\(model.pendingApprovalCount))"
    case .gecikmis where model.overdueCount > 0: return "\(title) (\(model.overdueCount))"
    default: return title
    }
  }

  private var filterMenu: some View {
    Menu {
      Picker("Dönem", selection: $model.period) {
        ForEach(FinanceDocumentListViewModel.Period.allCases) { Text($0.title).tag($0) }
      }
      Picker("Kategori", selection: $model.categoryId) {
        Text("Tüm kategoriler").tag(UUID?.none)
        ForEach(model.categories) { Text($0.name).tag(Optional($0.id)) }
      }
      Divider()
      if model.access.canAnywhere(model.kind.readPermission) {
        NavigationLink(value: AppRoute.payables(model.kind)) {
          Label(model.kind == .gider ? "Bekleyen borçlar" : "Bekleyen alacaklar", systemImage: "calendar.badge.exclamationmark")
        }
      }
      NavigationLink(value: AppRoute.financeCategories) {
        Label("Kategorileri yönet", systemImage: "tag")
      }
    } label: {
      Image(systemName: model.categoryId == nil && model.period == .tumu
            ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
    }
    .accessibilityLabel("Filtre")
  }

  private func scopeName(_ document: FinanceDocument) -> String? {
    app.projectName(document.projectId) ?? app.costCenterName(document.costCenterId).map { "Genel · \($0)" }
  }
}

/// Belge satırı: açıklama, kategori ve kapsam; sağda tutar ve ödeme durumu.
struct FinanceDocumentRow: View {
  let document: FinanceDocument
  let status: FinanceDocumentStatus?
  let categoryName: String
  let scopeName: String?
  var cariName: String?

  var body: some View {
    RDRow(title: document.description, subtitle: subtitle) {
      if document.isDemo { RDDemoBadge() }
    } trailing: {
      VStack(alignment: .trailing, spacing: 2) {
        Text(Money.format(document.amount, currency: document.currency))
          .font(RDFont.secondary.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(document.status == .iptal ? RDColor.textSecondary : RDColor.textPrimary)
          .strikethrough(document.status == .iptal)
        FinanceStateBadge(document: document, status: status)
      }
    }
  }

  private var subtitle: String {
    var parts = [document.documentDate.display, categoryName]
    if let cariName { parts.append(cariName) }
    if let scopeName { parts.append(scopeName) }
    if let status, status.settlementState == .kismi {
      parts.append("Kalan \(Money.format(status.remainingAmount, currency: document.currency))")
    }
    return parts.joined(separator: " · ")
  }
}

/// Ödeme durumu etiketi; vadesi geçmişse ayrıca "Vadesi geçti" yazar.
struct FinanceStateBadge: View {
  let document: FinanceDocument
  let status: FinanceDocumentStatus?

  var body: some View {
    let state = status?.settlementState ?? (document.status == .iptal ? .iptal : .taslak)
    if status?.isOverdue == true {
      RDStatusBadge(text: "Vadesi geçti · \(state.title(for: document.kind))", tone: .danger)
    } else {
      RDStatusBadge(text: state.title(for: document.kind), tone: state.tone)
    }
  }
}
