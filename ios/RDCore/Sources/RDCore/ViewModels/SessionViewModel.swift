import Foundation
import Observation

/// Kullanıcının oturum bağlamı: kimlik, profil ve etkin izinler.
public struct SessionContext: Equatable, Sendable {
  public let session: AuthSession
  public let profile: UserProfile
  public let access: AccessControl

  public init(session: AuthSession, profile: UserProfile, access: AccessControl) {
    self.session = session
    self.profile = profile
    self.access = access
  }
}

@MainActor
@Observable
public final class SessionViewModel {
  public enum State: Equatable {
    case loading
    case signedOut
    case signedIn(SessionContext)
  }

  public private(set) var state: State = .loading
  public var email = ""
  public var password = ""
  public private(set) var isWorking = false
  public private(set) var errorMessage: String?
  public private(set) var infoMessage: String?

  private let repositories: Repositories

  public init(repositories: Repositories) {
    self.repositories = repositories
  }

  public var context: SessionContext? {
    if case .signedIn(let context) = state { return context }
    return nil
  }

  public var canSubmit: Bool {
    !isWorking && Validation.isValidEmail(email.trimmingCharacters(in: .whitespaces)) && password.count >= 10
  }

  /// Uygulama açılışında saklı oturumu geri yükler.
  public func start() async {
    guard let session = await repositories.auth.restoreSession() else {
      state = .signedOut
      return
    }
    do {
      state = .signedIn(try await loadContext(for: session))
    } catch {
      // Profil/izin okunamazsa oturumu kapatmak, yetkisiz ekran göstermekten iyidir.
      try? await repositories.auth.signOut()
      errorMessage = message(for: error)
      state = .signedOut
    }
  }

  public func signIn() async {
    guard canSubmit else {
      errorMessage = "Geçerli bir e-posta ve en az 10 karakterli şifre girin."
      return
    }
    isWorking = true
    errorMessage = nil
    infoMessage = nil
    defer { isWorking = false }
    do {
      let session = try await repositories.auth.signIn(
        email: email.trimmingCharacters(in: .whitespaces).lowercased(), password: password)
      let context = try await loadContext(for: session)
      guard context.profile.isActive else {
        try? await repositories.auth.signOut()
        errorMessage = "Hesabınız pasif. Yöneticinize başvurun."
        return
      }
      password = ""
      state = .signedIn(context)
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func sendPasswordReset() async {
    let address = email.trimmingCharacters(in: .whitespaces).lowercased()
    guard Validation.isValidEmail(address) else {
      errorMessage = "Şifre sıfırlama için e-posta adresinizi yazın."
      return
    }
    isWorking = true
    defer { isWorking = false }
    do {
      try await repositories.auth.sendPasswordReset(email: address)
      errorMessage = nil
      infoMessage = "Hesap varsa şifre sıfırlama bağlantısı e-posta ile gönderildi."
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Yetki değişikliklerini (yeni proje ataması vb.) oturumu kapatmadan yansıtır.
  public func refreshAccess() async {
    guard let context else { return }
    do {
      state = .signedIn(try await loadContext(for: context.session))
    } catch RepositoryError.notAuthenticated {
      state = .signedOut
    } catch {
      // Ağ hatasında mevcut izinlerle devam edilir; sunucu yine RLS ile korur.
    }
  }

  public func signOut() async {
    try? await repositories.auth.signOut()
    password = ""
    errorMessage = nil
    state = .signedOut
  }

  private func loadContext(for session: AuthSession) async throws -> SessionContext {
    async let profile = repositories.access.myProfile()
    async let grants = repositories.access.myPermissions()
    return SessionContext(session: session, profile: try await profile, access: AccessControl(grants: try await grants))
  }
}

/// Hataları kullanıcıya gösterilecek Türkçe mesaja çevirir.
public func message(for error: Error) -> String {
  (error as? RepositoryError)?.errorDescription ?? "Beklenmeyen bir hata oluştu. Lütfen tekrar deneyin."
}
