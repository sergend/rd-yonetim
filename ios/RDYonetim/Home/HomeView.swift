import RDCore
import RDDesign
import SwiftUI

enum AppRoute: Hashable {
  case projects
  case project(Project)
  case cariList(projectId: UUID?)
  case cari(CariAccount)
  case generalExpenses
  case tasks(projectId: UUID?)
  case subcontractors
  case subcontractor(Subcontractor)
  case personnelList
  case personnel(Personnel)
  case crews
  case crew(Crew)
  case projectWorkforce(Project)
  case puantajProjects
  case puantaj(Project)
  case contracts(projectId: UUID?)
  case contract(Contract)
  case hakedisList
  case hakedis(Hakedis, Contract)
  case imalatProjects
  case imalat(Project)
  case financeList(FinanceDocKind, projectId: UUID?)
  case financeDocument(FinanceDocument)
  case payables(FinanceDocKind)
  case financeReports
  case financeCategories
  case placeholder(AppModule)
}

/// Ana sayfa: özet sayılar, aktif projeler, bana atanan işler ve modüller.
/// Bilerek hiçbir para tutarı, kasa veya banka bakiyesi göstermez.
struct HomeView: View {
  @Environment(AppModel.self) private var app
  @State private var model: HomeViewModel
  @State private var path = NavigationPath()

  private let projectLimit = 5
  private let taskLimit = 3

  init(context: SessionContext, repositories: Repositories) {
    _model = State(initialValue: HomeViewModel(context: context, repositories: repositories))
  }

  var body: some View {
    NavigationStack(path: $path) {
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

        if model.context.access.canAnywhere(.projeRead) { projectsSection }
        tasksSection
        modulesSection
        upcomingSection
      }
      .listStyle(.insetGrouped)
      .rdScreen()
      .navigationTitle(RDBrandMark.appName)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) { accountMenu }
      }
      .refreshable { await reload() }
      .task { await reload() }
      .navigationDestination(for: AppRoute.self) { destination(for: $0) }
    }
  }

  private func reload() async {
    await model.load()
    await app.reloadLookups()
  }

  @ViewBuilder
  private func destination(for route: AppRoute) -> some View {
    switch route {
    case .projects: ProjectListView(app: app)
    case .project(let project): ProjectDetailView(project: project, app: app)
    case .cariList(let projectId): CariListView(projectId: projectId, app: app)
    case .cari(let account): CariDetailView(account: account, app: app)
    case .generalExpenses: GeneralExpensesView(app: app)
    case .tasks(let projectId): TaskListView(projectId: projectId, app: app)
    case .subcontractors: SubcontractorListView(app: app)
    case .subcontractor(let item): SubcontractorDetailView(subcontractor: item, app: app)
    case .personnelList: PersonnelListView(app: app)
    case .personnel(let person): PersonnelDetailView(person: person, app: app)
    case .crews: CrewListView(app: app)
    case .crew(let crew): CrewDetailView(crew: crew, app: app)
    case .projectWorkforce(let project): ProjectWorkforceView(project: project, app: app)
    case .puantajProjects: PuantajProjectsView(app: app)
    case .puantaj(let project): PuantajView(project: project, app: app)
    case .contracts(let projectId): ContractListView(projectId: projectId, app: app)
    case .contract(let contract): ContractDetailView(contract: contract, app: app)
    case .hakedisList: HakedisListView(app: app)
    case .hakedis(let hakedis, let contract): HakedisDetailView(hakedis: hakedis, contract: contract, app: app)
    case .imalatProjects: ImalatProjectsView(app: app)
    case .imalat(let project): ImalatView(project: project, app: app)
    case .financeList(let kind, let projectId): FinanceDocumentListView(kind: kind, projectId: projectId, app: app)
    case .financeDocument(let document): FinanceDocumentDetailView(document: document, app: app)
    case .payables(let kind): PayablesView(kind: kind, app: app)
    case .financeReports: FinanceReportView(app: app)
    case .financeCategories: FinanceCategoryListView(app: app)
    case .placeholder(let module): ModulePlaceholderView(module: module)
    }
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

  /// Yalnızca adet bilgisi; tutar yok.
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
          ProjectRow(project: project, openTaskCount: model.openTaskCount(projectId: project.id))
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
        NavigationLink(value: route(for: module)) {
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

  private func route(for module: AppModule) -> AppRoute {
    switch module {
    case .projeler: .projects
    case .isTakibi: .tasks(projectId: nil)
    case .taseronlar: .subcontractors
    case .personel: .personnelList
    case .ekipler: .crews
    case .cari: .cariList(projectId: nil)
    case .genelGider: .generalExpenses
    case .puantaj: .puantajProjects
    case .imalat: .imalatProjects
    case .taseronSozlesmeleri: .contracts(projectId: nil)
    case .hakedis: .hakedisList
    case .giderler: .financeList(.gider, projectId: nil)
    case .borclar: .payables(.gider)
    case .gelirler: .financeList(.gelir, projectId: nil)
    case .raporlar: .financeReports
    default: .placeholder(module)
    }
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

/// Proje satırı (ana sayfa ve proje listesi). Tutar içermez.
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
