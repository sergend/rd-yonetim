import Foundation
import RDCore
import Supabase

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Supabase/PostgREST hatalarını uygulamanın RepositoryError türüne çevirir.
/// Veritabanı fonksiyonlarımızın mesajları Türkçedir ve doğrudan gösterilir;
/// Postgres'in İngilizce kısıt mesajları genel Türkçe metinle değiştirilir.
enum ErrorMapper {
  static func map(_ error: Error) -> RepositoryError {
    if let mapped = error as? RepositoryError { return mapped }
    if error is URLError { return .network }
    if let error = error as? PostgrestError { return map(postgrest: error) }
    if let error = error as? AuthError {
      switch error {
      case .sessionMissing: return .notAuthenticated
      case .api(_, let code, _, let response):
        if code == .invalidCredentials { return .invalidCredentials }
        if response.statusCode == 401 { return .notAuthenticated }
        return .server("Giriş yapılamadı. Lütfen tekrar deneyin.")
      default: return .notAuthenticated
      }
    }
    if error is DecodingError { return .server("Sunucudan beklenmeyen yanıt alındı.") }
    return .server("Beklenmeyen bir hata oluştu. Lütfen tekrar deneyin.")
  }

  static func map(postgrest error: PostgrestError) -> RepositoryError {
    let ours = isOwnMessage(error.message) ? error.message : nil
    switch error.code {
    case "42501": return .forbidden(ours)
    case "23505": return .conflict(ours ?? "Bu kayıt zaten var (kod veya belge tekrarı).")
    case "23514", "22023", "23502", "22P02": return .validation(ours ?? "Girilen bilgiler kurallara uymuyor.")
    case "23503": return .validation(ours ?? "Bağlı kayıt bulunamadı veya pasif.")
    case "P0002", "PGRST116": return .notFound
    case "PGRST301", "PGRST302": return .notAuthenticated
    default: return .server(ours ?? "Sunucu hatası. Lütfen tekrar deneyin.")
    }
  }

  /// Postgres'in kendi (İngilizce) mesajlarını ayıklar.
  private static func isOwnMessage(_ message: String) -> Bool {
    let english = ["violates", "permission denied", "duplicate key", "invalid input", "null value", "new row"]
    return !english.contains { message.lowercased().contains($0) }
  }
}

/// Repository çağrılarını ortak hata çevirisiyle sarar.
func mapped<T>(_ operation: () async throws -> T) async throws -> T {
  do {
    return try await operation()
  } catch {
    throw ErrorMapper.map(error)
  }
}
