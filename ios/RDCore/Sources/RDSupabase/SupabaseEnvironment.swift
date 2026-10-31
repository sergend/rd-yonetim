import Foundation
import RDCore
import Supabase

/// Supabase bağlantı ayarları. Değerler koda yazılmaz: iOS'ta Info.plist'e
/// git'e girmeyen Secrets.xcconfig üzerinden gelir, testlerde ortam değişkeninden.
public struct SupabaseConfig: Sendable {
  public let url: URL
  public let anonKey: String

  public init(url: URL, anonKey: String) {
    self.url = url
    self.anonKey = anonKey
  }

  /// Info.plist'teki SUPABASE_URL ve SUPABASE_ANON_KEY değerleri.
  public static func fromBundle(_ bundle: Bundle = .main) -> SupabaseConfig? {
    guard let rawURL = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
          let url = URL(string: rawURL), url.host != nil,
          let key = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
          !key.isEmpty, !key.hasPrefix("$(") else { return nil }
    return SupabaseConfig(url: url, anonKey: key)
  }
}

public enum SupabaseEnvironment {
  /// Uygulamanın tüm repository'lerini tek bir Supabase istemcisiyle kurar.
  public static func makeRepositories(config: SupabaseConfig) -> Repositories {
    let client = makeClient(config: config)
    return Repositories(
      auth: SupabaseAuthRepository(client: client),
      access: SupabaseAccessRepository(client: client),
      projects: SupabaseProjectRepository(client: client),
      costCenters: SupabaseCostCenterRepository(client: client),
      cari: SupabaseCariRepository(client: client),
      tasks: SupabaseTaskRepository(client: client),
      workforce: SupabaseWorkforceRepository(client: client),
      puantaj: SupabasePuantajRepository(client: client)
    )
  }

  public static func makeClient(config: SupabaseConfig) -> SupabaseClient {
    #if os(Linux)
      // Linux yalnızca CI testleri içindir; oturum bellekte tutulur.
      let auth = SupabaseClientOptions.AuthOptions(storage: InMemoryAuthStorage(),
                                                   emitLocalSessionAsInitialSession: true)
    #else
      // iOS'ta oturum Keychain'de saklanır (kütüphanenin varsayılanı).
      let auth = SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession: true)
    #endif
    return SupabaseClient(supabaseURL: config.url, supabaseKey: config.anonKey,
                          options: SupabaseClientOptions(auth: auth))
  }
}

#if os(Linux)
  final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
  }
#endif
