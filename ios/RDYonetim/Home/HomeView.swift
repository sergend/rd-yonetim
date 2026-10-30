import RDCore
import SwiftUI

enum AppRoute: Hashable {
  case projects
  case project(Project)
  case cariList(projectId: UUID?)
  case cari(CariAccount)
  case generalExpenses
  case tasks(projectId: UUID?)
  case placeholder(AppModule)
}

/// Ana ekran: projeler, iş takibi ve modül girişleri. Tutar gösterilmez.
struct HomeView: View {
  @Environment(AppModel.self) private var app
  @State private var model: HomeViewModel
  @State private var path = NavigationPath()

  init(context: SessionContext, repositories: Repositories) {
    _model = State(initialValue: HomeViewModel(context: context, repositories: repositories))
  }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ErrorBanner(message: model.errorMessage)
          projectsSection
          tasksSection
          modulesSection
          upcomingSection
        }
        .padding(16)
      }
      .background(Theme.pageBackground)
      .navigationTitle("Merhaba, \(model.context.profile.displayName.components(separatedBy: " ").first ?? "")")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Text(model.context.profile.email ?? "")
            Button("Çıkış yap", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
              Task { await app.session.signOut() }
            }
          } label: {
            Image(systemName: "person.crop.circle")
          }
          .accessibilityLabel("Hesap")
        }
      }
      .refreshable { await reload() }
      .task { await reload() }
      .navigationDestination(for: AppRoute.self) { route in
        destination(for: route)
      }
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
    case .placeholder(let module): ModulePlaceholderView(module: module)
    }
  }

  // MARK: Bölümler

  private var projectsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(title: "Aktif projeler", actionTitle: "Tümü") { path.append(AppRoute.projects) }
      if model.activeProjects.isEmpty && !model.isLoading {
        Card { Text("Size atanmış aktif proje yok.").foregroundStyle(.secondary) }
      }
      ForEach(model.activeProjects) { project in
        NavigationLink(value: AppRoute.project(project)) {
          Card {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                  Text(project.name).font(.headline)
                  if project.isDemo { DemoBadge() }
                }
                Text([project.code, project.city].compactMap { $0 }.joined(separator: " · "))
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              StatusBadge(text: project.status.title, color: project.status.color)
            }
            let openCount = model.openTaskCount(projectId: project.id)
            if openCount > 0 {
              Label("\(openCount) açık iş", systemImage: "checklist").font(.footnote).foregroundStyle(.secondary)
            }
          }
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var tasksSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(title: "İş takibi", actionTitle: "Tümü") { path.append(AppRoute.tasks(projectId: nil)) }
      Card {
        HStack(spacing: 24) {
          Metric(value: model.openTasks.count, title: "Açık iş")
          Metric(value: model.myTasks.count, title: "Bana atanan")
          Metric(value: model.overdueCount(), title: "Geciken", tint: model.overdueCount() > 0 ? .red : .primary)
        }
        ForEach(model.myTasks.prefix(3)) { task in
          Divider()
          TaskRow(task: task, projectName: app.projectName(task.projectId))
        }
      }
    }
  }

  private var modulesSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(title: "Modüller")
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
        ForEach(model.availableModules) { module in
          NavigationLink(value: route(for: module)) {
            ModuleTile(module: module)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  @ViewBuilder
  private var upcomingSection: some View {
    if !model.upcomingModules.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        SectionHeader(title: "Sonraki aşamalarda")
        Card {
          ForEach(model.upcomingModules) { module in
            NavigationLink(value: AppRoute.placeholder(module)) {
              HStack {
                Label(module.title, systemImage: module.symbol)
                Spacer()
                Text("Hazırlanıyor").font(.caption).foregroundStyle(.secondary)
              }
              .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if module != model.upcomingModules.last { Divider() }
          }
        }
      }
    }
  }

  private func route(for module: AppModule) -> AppRoute {
    switch module {
    case .projeler: .projects
    case .isTakibi: .tasks(projectId: nil)
    case .cari: .cariList(projectId: nil)
    case .genelGider: .generalExpenses
    default: .placeholder(module)
    }
  }
}

struct SectionHeader: View {
  let title: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    HStack {
      Text(title).font(.title3.weight(.semibold))
      Spacer()
      if let actionTitle, let action {
        Button(actionTitle, action: action).font(.subheadline)
      }
    }
  }
}

private struct Metric: View {
  let value: Int
  let title: String
  var tint: Color = .primary

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(value)").font(.title2.weight(.semibold)).foregroundStyle(tint).monospacedDigit()
      Text(title).font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct ModuleTile: View {
  let module: AppModule

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: module.symbol)
        .font(.title2)
        .foregroundStyle(Theme.accent)
      Text(module.title)
        .font(.subheadline.weight(.semibold))
        .multilineTextAlignment(.leading)
        .lineLimit(2, reservesSpace: true)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
  }
}

/// Henüz geliştirilmemiş modül: veri girişi sunmaz, yanıltıcı içerik göstermez.
struct ModulePlaceholderView: View {
  let module: AppModule

  var body: some View {
    ContentUnavailableView {
      Label(module.title, systemImage: module.symbol)
    } description: {
      Text("Bu modül henüz geliştirilmedi. Sonraki aşamalarda eklenecek; şu an bu bölümde kayıt tutulmuyor.")
    }
    .navigationTitle(module.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}
