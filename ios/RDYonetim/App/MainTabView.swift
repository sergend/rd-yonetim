import RDCore
import RDDesign
import SwiftUI

/// Oturum açıkken ana yapı: alt sekme çubuğu (Ana Sayfa, Projeler, +, Cari,
/// Raporlar) ve her sekmenin kendi gezinme yığını. Sekmeler yetkiye göre görünür;
/// ortadaki "+" hızlı ekle menüsünü açar.
struct MainTabView: View {
  enum Tab: Hashable, CaseIterable {
    case home, projects, cari, reports

    var title: String {
      switch self {
      case .home: "Ana Sayfa"
      case .projects: "Projeler"
      case .cari: "Cari"
      case .reports: "Raporlar"
      }
    }

    var symbol: String {
      switch self {
      case .home: "house"
      case .projects: "building.2"
      case .cari: "person.2"
      case .reports: "chart.bar"
      }
    }
  }

  enum Sheet: Identifiable {
    case quickAdd, expense

    var id: Self { self }
  }

  @Environment(AppModel.self) private var app
  let context: SessionContext

  @State private var tab: Tab = .home
  @State private var visited: Set<Tab> = [.home]
  @State private var homePath = NavigationPath()
  @State private var projectsPath = NavigationPath()
  @State private var cariPath = NavigationPath()
  @State private var reportsPath = NavigationPath()
  @State private var sheet: Sheet?

  private var tabs: [Tab] {
    Tab.allCases.filter { tab in
      switch tab {
      case .home: true
      case .projects: AppModule.projeler.isVisible(for: app.access)
      case .cari: AppModule.cari.isVisible(for: app.access)
      case .reports: AppModule.raporlar.isVisible(for: app.access)
      }
    }
  }

  private var quickActions: [QuickAddAction] { QuickAddAction.allCases.filter { $0.isVisible(for: app.access) } }

  var body: some View {
    ZStack {
      ForEach(tabs, id: \.self) { item in
        if visited.contains(item) {
          stack(for: item)
            .opacity(tab == item ? 1 : 0)
            .allowsHitTesting(tab == item)
            .accessibilityHidden(tab != item)
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      RDTabBar(tabs: tabs, selection: tab, showsAdd: !quickActions.isEmpty, select: select, add: { sheet = .quickAdd })
    }
    .sheet(item: $sheet) { item in
      switch item {
      case .quickAdd:
        QuickAddSheet(actions: quickActions) { action in perform(action) }
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
      case .expense:
        FinanceDocumentFormView(kind: .gider, editing: nil, preselectedProject: nil, app: app) { _ in }
      }
    }
  }

  @ViewBuilder
  private func stack(for tab: Tab) -> some View {
    switch tab {
    case .home:
      NavigationStack(path: $homePath) {
        HomeView(context: context, repositories: app.repositories, path: $homePath)
          .rdAppDestinations(app: app)
      }
    case .projects:
      NavigationStack(path: $projectsPath) {
        ProjectListView(app: app).rdAppDestinations(app: app)
      }
    case .cari:
      NavigationStack(path: $cariPath) {
        CariListView(projectId: nil, app: app).rdAppDestinations(app: app)
      }
    case .reports:
      NavigationStack(path: $reportsPath) {
        FinanceReportView(app: app).rdAppDestinations(app: app)
      }
    }
  }

  /// Seçili sekmeye tekrar dokunmak o sekmenin başına döner.
  private func select(_ item: Tab) {
    if item == tab {
      switch item {
      case .home: homePath = NavigationPath()
      case .projects: projectsPath = NavigationPath()
      case .cari: cariPath = NavigationPath()
      case .reports: reportsPath = NavigationPath()
      }
    }
    visited.insert(item)
    tab = item
  }

  private func perform(_ action: QuickAddAction) {
    if let route = action.route {
      sheet = nil
      tab = .home
      homePath = NavigationPath()
      homePath.append(route)
    } else {
      sheet = .expense
    }
  }
}

/// Alt sekme çubuğu; ortada marka kırmızısı "+" düğmesi.
struct RDTabBar: View {
  let tabs: [MainTabView.Tab]
  let selection: MainTabView.Tab
  let showsAdd: Bool
  let select: (MainTabView.Tab) -> Void
  let add: () -> Void

  var body: some View {
    let leading = Array(tabs.prefix((tabs.count + 1) / 2))
    let trailing = Array(tabs.dropFirst((tabs.count + 1) / 2))
    HStack(alignment: .top, spacing: 0) {
      ForEach(leading, id: \.self) { item(for: $0) }
      if showsAdd {
        Button(action: add) {
          Image(systemName: "plus")
            .font(.title2.weight(.bold))
            .foregroundStyle(RDColor.onBrand)
            .frame(width: 56, height: 56)
            .background(Circle().fill(RDColor.brand))
            .shadow(color: RDColor.brand.opacity(0.35), radius: 8, y: 4)
        }
        .offset(y: -18)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Hızlı ekle")
      }
      ForEach(trailing, id: \.self) { item(for: $0) }
    }
    .padding(.top, .rdS)
    .frame(maxWidth: .infinity)
    .background {
      Rectangle().fill(.bar)
        .overlay(alignment: .top) { Rectangle().fill(RDColor.separator).frame(height: 0.5) }
        .ignoresSafeArea(edges: .bottom)
    }
  }

  private func item(for tab: MainTabView.Tab) -> some View {
    let isSelected = tab == selection
    return Button { select(tab) } label: {
      VStack(spacing: 3) {
        Image(systemName: isSelected ? "\(tab.symbol).fill" : tab.symbol)
          .font(.system(size: 20, weight: .semibold))
          .frame(height: 24)
        Text(tab.title).font(.caption2.weight(.semibold))
      }
      .foregroundStyle(isSelected ? RDColor.brandText : RDColor.textSecondary)
      .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
