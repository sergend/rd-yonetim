import RDCore
import RDDesign
import SwiftUI

/// Ana sayfa: bu ayın maliyeti, bekleyen ödemeler, açık hakedişler, yaklaşan
/// ödemeler, aktif projeler (maliyetleriyle), bana atanan işler ve modüller.
/// Kasa veya banka bakiyesi göstermez.
struct HomeView: View {
  @Environment(AppModel.self) private var app
  @State private var model: HomeViewModel
  @State private var dashboard: HomeDashboardViewModel
  @Binding private var path: NavigationPath

  private let projectLimit = 5
  private let taskLimit = 3

  init(context: SessionContext, repositories: Repositories, path: Binding<NavigationPath>) {
    _model = State(initialValue: HomeViewModel(context: context, repositories: repositories))
    _dashboard = State(initialValue: HomeDashboardViewModel(access: context.access, repositories: repositories))
    _path = path
  }

  var body: some View {
    List {
      Section {
        summary
      } header: {
        greeting
      }
      .rdRowBackground()

      if let error = model.errorMessage {
        Section { RDErrorBanner(message: error) }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
      }

      if dashboard.canSeeExpenses {
        Section { MonthlyCostCard(model: dashboard) }
          .listRowBackground(RDColor.brand)
      }

      if dashboard.pending != nil || dashboard.openHakedisCount != nil {
        Section { DashboardTiles(model: dashboard) { path.append($0) } }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
      }

      if !dashboard.upcoming.isEmpty { upcomingPaymentsSection }
      if model.context.access.canAnywhere(.projeRead) { projectsSection }
      tasksSection
      modulesSection
      upcomingSection
    }
    .listStyle(.insetGrouped)
    .listSectionSpacing(.compact)
    .rdScreen()
    .navigationTitle("Genel Bakış")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        RDLogoImage(kind: .wordmark, height: 22)
      }
      ToolbarItem(placement: .topBarTrailing) { accountMenu }
    }
    .refreshable { await reload() }
    .task { await reload() }
  }

  private func reload() async {
    await model.load()
    await dashboard.load()
    await app.reloadLookups()
  }

  private var upcomingPaymentsSection: some View {
    Section {
      ForEach(dashboard.upcoming) { item in
        NavigationLink(value: AppRoute.payables(.gider)) {
          UpcomingPaymentRow(item: item, projectName: app.projectName(item.projectId))
        }
      }
    } header: {
      RDSectionHeader(title: "Yaklaşan ödemeler", actionTitle: "Tümü") { path.append(AppRoute.payables(.gider)) }
    }
    .rdRowBackground()
  }

  // MARK: Bölümler

  private var greeting: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Merhaba, \(model.context.profile.displayName.components(separatedBy: " ").first ?? "")")
        .font(RDFont.sectionTitle)
        .foregroundStyle(RDColor.textPrimary)
      Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Money.locale)))
        .font(RDFont.secondary)
        .foregroundStyle(RDColor.textSecondary)
    }
    .textCase(nil)
    .padding(.bottom, .rdS)
    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
  }

  /// Adet bilgileri (tutarlar aşağıdaki kartlardadır).
  private var summary: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: .rdL) { metrics }
      VStack(alignment: .leading, spacing: .rdM) { metrics }
    }
    .padding(.vertical, .rdXS)
  }

  @ViewBuilder private var metrics: some View {
    if model.context.access.canAnywhere(.projeRead) {
      Metric(value: model.activeProjects.count, title: "Aktif proje")
    }
    Metric(value: model.openTasks.count, title: "Açık iş")
    Metric(value: model.myTasks.count, title: "Bana atanan")
    let overdue = model.overdueCount()
    Metric(value: overdue, title: "Geciken", tone: overdue > 0 ? .danger : nil)
  }

  private var projectsSection: some View {
    Section {
      if model.activeProjects.isEmpty && !model.isLoading {
        Text("Size atanmış aktif proje yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.activeProjects.prefix(projectLimit)) { project in
        NavigationLink(value: AppRoute.project(project)) {
          HomeProjectRow(project: project, costs: dashboard.projectCosts[project.id],
                         openTaskCount: model.openTaskCount(projectId: project.id))
        }
      }
    } header: {
      RDSectionHeader(title: "Aktif projeler", actionTitle: "Tümü") { path.append(AppRoute.projects) }
    }
    .rdRowBackground()
  }

  private var tasksSection: some View {
    Section {
      if model.myTasks.isEmpty && !model.isLoading {
        Text("Size atanmış açık iş yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.myTasks.prefix(taskLimit)) { task in
        NavigationLink(value: AppRoute.tasks(projectId: task.projectId)) {
          TaskRow(task: task, projectName: app.projectName(task.projectId))
        }
      }
    } header: {
      RDSectionHeader(title: "Bana atanan işler", actionTitle: "Tüm işler") { path.append(AppRoute.tasks(projectId: nil)) }
    }
    .rdRowBackground()
  }

  private var modulesSection: some View {
    Section {
      ForEach(model.availableModules) { module in
        NavigationLink(value: AppRoute.module(module)) {
          RDRow(symbol: module.symbol, symbolTint: RDColor.brandText, title: module.title)
        }
      }
    } header: {
      RDSectionHeader(title: "Modüller")
    }
    .rdRowBackground()
  }

  @ViewBuilder
  private var upcomingSection: some View {
    if !model.upcomingModules.isEmpty {
      Section {
        ForEach(model.upcomingModules) { module in
          NavigationLink(value: AppRoute.placeholder(module)) {
            RDRow(symbol: module.symbol, title: module.title) {
              RDStatusBadge(text: "Hazırlanıyor")
            }
          }
        }
      } header: {
        RDSectionHeader(title: "Sonraki aşamalarda")
      } footer: {
        Text("Bu modüller henüz kullanıma açık değil; kayıt tutulmaz.")
      }
      .rdRowBackground()
    }
  }

  private var accountMenu: some View {
    Menu {
      Section(model.context.profile.email ?? "") {
        Button("Çıkış yap", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
          Task { await app.session.signOut() }
        }
      }
    } label: {
      Image(systemName: "person.crop.circle")
        .font(.title3)
        .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
    }
    .accessibilityLabel("Hesap: \(model.context.profile.displayName)")
  }
}

private struct Metric: View {
  let value: Int
  let title: String
  var tone: StatusTone?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(value)")
        .font(RDFont.metric)
        .monospacedDigit()
        .foregroundStyle(tone.map(RDColor.tone) ?? RDColor.textPrimary)
      Text(title)
        .font(RDFont.caption)
        .foregroundStyle(RDColor.textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// Proje satırı (proje listesi). Tutar içermez.
struct ProjectRow: View {
  let project: Project
  var openTaskCount: Int?

  var body: some View {
    RDRow(symbol: "building.2", symbolTint: RDColor.brandText, title: project.name, subtitle: subtitle) {
      if project.isDemo { RDDemoBadge() }
    } trailing: {
      RDStatusBadge(text: project.status.title, tone: project.status.tone)
    }
  }

  private var subtitle: String {
    var parts = [project.code]
    if let city = project.city { parts.append(city) }
    if let count = openTaskCount, count > 0 { parts.append("\(count) açık iş") }
    return parts.joined(separator: " · ")
  }
}

/// Henüz geliştirilmemiş modül: veri girişi sunmaz, yanıltıcı içerik göstermez.
struct ModulePlaceholderView: View {
  let module: AppModule

  var body: some View {
    RDStateView(kind: .empty(
      title: module.title,
      message: "Bu modül henüz geliştirilmedi. Sonraki aşamalarda eklenecek; şu an bu bölümde kayıt tutulmuyor.",
      symbol: module.symbol))
      .background(RDColor.background.ignoresSafeArea())
      .navigationTitle(module.title)
      .navigationBarTitleDisplayMode(.inline)
  }
}
