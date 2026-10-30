import RDCore
import SwiftUI

#if DEBUG
  /// Önizlemeler bellek içi örnek veriyle çalışır; sunucuya bağlanmaz.
  @MainActor
  enum PreviewSupport {
    static func app() async -> AppModel {
      let backend = await PreviewData.backend()
      let app = AppModel(repositories: backend.repositories)
      await app.session.start()
      await app.reloadLookups()
      return app
    }
  }

  private struct PreviewHost<Content: View>: View {
    @State private var app: AppModel?
    @ViewBuilder let content: (AppModel) -> Content

    var body: some View {
      Group {
        if let app { content(app).environment(app) } else { ProgressView() }
      }
      .task { app = await PreviewSupport.app() }
    }
  }

  #Preview("Giriş") {
    LoginView(session: SessionViewModel(repositories: InMemoryBackend().repositories))
  }

  #Preview("Ana ekran") {
    PreviewHost { app in AppRootView() }
  }

  #Preview("Ana ekran · koyu") {
    PreviewHost { app in AppRootView() }.preferredColorScheme(.dark)
  }

  #Preview("Cari detay") {
    PreviewHost { app in
      NavigationStack { CariDetailView(account: PreviewData.taseron, app: app) }
    }
  }
#endif
