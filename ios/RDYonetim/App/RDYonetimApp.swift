import RDCore
import RDSupabase
import SwiftUI

@main
struct RDYonetimApp: App {
  @State private var app: AppModel? = SupabaseConfig.fromBundle().map {
    AppModel(repositories: SupabaseEnvironment.makeRepositories(config: $0))
  }

  var body: some Scene {
    WindowGroup {
      if let app {
        AppRootView()
          .environment(app)
      } else {
        ConfigMissingView()
      }
    }
  }
}

/// Uygulama genelinde paylaşılan durum: oturum ve seçim listeleri.
@MainActor
@Observable
final class AppModel {
  let repositories: Repositories
  let session: SessionViewModel
  /// Formlardaki proje ve masraf merkezi seçicileri için önbellek.
  private(set) var projects: [Project] = []
  private(set) var costCenters: [CostCenter] = []

  init(repositories: Repositories) {
    self.repositories = repositories
    self.session = SessionViewModel(repositories: repositories)
  }

  var access: AccessControl { session.context?.access ?? .none }

  func reloadLookups() async {
    if access.canAnywhere(.projeRead) {
      projects = (try? await repositories.projects.list(includeCompleted: true)) ?? projects
    }
    costCenters = (try? await repositories.costCenters.list()) ?? costCenters
  }

  func projectName(_ id: UUID?) -> String? {
    guard let id else { return nil }
    return projects.first { $0.id == id }?.name
  }

  func costCenterName(_ id: UUID?) -> String? {
    guard let id else { return nil }
    return costCenters.first { $0.id == id }?.name
  }
}

struct AppRootView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      switch app.session.state {
      case .loading:
        ProgressView("Oturum kontrol ediliyor…")
      case .signedOut:
        LoginView(session: app.session)
      case .signedIn(let context):
        HomeView(context: context, repositories: app.repositories)
          .id(context.session.userId)
      }
    }
    .task { await app.session.start() }
    .onChange(of: scenePhase) { _, phase in
      // Uygulamaya dönüldüğünde yetki değişiklikleri (yeni proje ataması vb.) yansır.
      if phase == .active { Task { await app.session.refreshAccess() } }
    }
  }
}

/// Supabase ayarları eksikse (Secrets.xcconfig yok) açıklayıcı ekran.
struct ConfigMissingView: View {
  var body: some View {
    ContentUnavailableView(
      "Sunucu ayarı eksik",
      systemImage: "exclamationmark.triangle",
      description: Text("ios/Config/Secrets.xcconfig dosyasını Secrets.example.xcconfig'ten oluşturup SUPABASE_URL ve SUPABASE_ANON_KEY değerlerini girin.")
    )
  }
}
