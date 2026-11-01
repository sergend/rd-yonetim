import Foundation

// MARK: - Bekleyen yüklemeler (dosya kaybolmasın)
//
// Seçilen veya taranan dosya, sunucuya gönderilmeden önce cihazda kalıcı
// olarak saklanır (uygulama kapansa, ağ kesilse de kaybolmaz). Yükleme
// tamamlanınca yerel kopya silinir. Her adım aynı kimlikle güvenle tekrarlanır.

public struct PendingUpload: Identifiable, Hashable, Codable, Sendable {
  public enum Stage: String, Codable, Sendable {
    /// Cihazda saklandı, sunucuya henüz bildirilmedi.
    case hazir
    /// Sunucu yer ayırdı (yol belli).
    case yerAyrildi
    /// Dosya gönderildi, doğrulama bekleniyor.
    case dosyaGonderildi
  }

  public var request: DocumentUploadRequest
  public var linkTitle: String
  public var storagePath: String?
  public var stage: Stage
  public var lastError: String?
  /// Sunucu bu kimliği artık kabul etmiyor (iptal / süresi doldu / farklı içerik):
  /// yeniden denemek yeni kimlikle başlar.
  public var needsNewId: Bool
  public var createdAt: Date

  public var id: UUID { request.id }

  public init(request: DocumentUploadRequest, linkTitle: String, createdAt: Date = Date()) {
    self.request = request
    self.linkTitle = linkTitle
    self.stage = .hazir
    self.needsNewId = false
    self.createdAt = createdAt
  }
}

/// Bekleyen yüklemelerin cihazdaki deposu.
public protocol PendingUploadStore: Sendable {
  func all() async -> [PendingUpload]
  func save(_ upload: PendingUpload) async throws
  func saveData(_ data: Data, for id: UUID) async throws
  func data(for id: UUID) async throws -> Data
  func remove(id: UUID) async
}

/// Klasör tabanlı depo: her yükleme için `<kimlik>.json` ve `<kimlik>.bin`.
/// Uygulama Application Support altında bir klasör verir; testler geçici klasör.
public actor FilePendingUploadStore: PendingUploadStore {
  private let directory: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(directory: URL) {
    self.directory = directory
  }

  private func ensureDirectory() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private func metaURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
  private func dataURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).bin") }

  private var writeOptions: Data.WritingOptions {
    #if os(iOS)
      [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
      [.atomic]
    #endif
  }

  public func all() async -> [PendingUpload] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }
      .compactMap { try? decoder.decode(PendingUpload.self, from: Data(contentsOf: $0)) }
      .filter { FileManager.default.fileExists(atPath: dataURL($0.id).path) }
      .sorted { $0.createdAt < $1.createdAt }
  }

  public func save(_ upload: PendingUpload) async throws {
    try ensureDirectory()
    try encoder.encode(upload).write(to: metaURL(upload.id), options: writeOptions)
  }

  public func saveData(_ data: Data, for id: UUID) async throws {
    try ensureDirectory()
    try data.write(to: dataURL(id), options: writeOptions)
  }

  public func data(for id: UUID) async throws -> Data {
    do {
      return try Data(contentsOf: dataURL(id))
    } catch {
      throw RepositoryError.validation("Cihazdaki dosya bulunamadı; belgeyi yeniden seçin.")
    }
  }

  public func remove(id: UUID) async {
    try? FileManager.default.removeItem(at: metaURL(id))
    try? FileManager.default.removeItem(at: dataURL(id))
  }
}

/// Önizleme ve testler için bellek içi depo.
public actor InMemoryPendingUploadStore: PendingUploadStore {
  private var uploads: [UUID: PendingUpload] = [:]
  private var files: [UUID: Data] = [:]

  public init() {}

  public func all() async -> [PendingUpload] {
    uploads.values.filter { files[$0.id] != nil }.sorted { $0.createdAt < $1.createdAt }
  }
  public func save(_ upload: PendingUpload) async throws { uploads[upload.id] = upload }
  public func saveData(_ data: Data, for id: UUID) async throws { files[id] = data }
  public func data(for id: UUID) async throws -> Data {
    guard let data = files[id] else { throw RepositoryError.validation("Cihazdaki dosya bulunamadı; belgeyi yeniden seçin.") }
    return data
  }
  public func remove(id: UUID) async {
    uploads[id] = nil
    files[id] = nil
  }
}

// MARK: - Yükleme adımları

public enum DocumentUploadStep: Int, Comparable, Sendable {
  case saving, reserving, uploading, verifying, done

  public var title: String {
    switch self {
    case .saving: "Cihazda saklanıyor"
    case .reserving: "Sunucuya bildiriliyor"
    case .uploading: "Dosya gönderiliyor"
    case .verifying: "Doğrulanıyor"
    case .done: "Yüklendi"
    }
  }

  /// Adım bazlı ilerleme (bayt bazlı değil).
  public var fraction: Double { Double(rawValue) / Double(DocumentUploadStep.done.rawValue) }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Yükleme akışı: cihazda sakla → yer ayır → dosyayı gönder → doğrula.
/// Ağ hatasında aynı kimlikle yeniden denenir; ikinci belge oluşmaz.
public struct DocumentUploader: Sendable {
  public let repository: DocumentRepository
  public let store: PendingUploadStore

  public init(repository: DocumentRepository, store: PendingUploadStore) {
    self.repository = repository
    self.store = store
  }

  /// Dosyayı doğrular, özetini hesaplar ve cihazda saklar.
  public func stage(data: Data, kind: ArchiveDocumentKind, title: String, description: String?,
                    documentDate: CalendarDate, link: DocumentLink, linkTitle: String,
                    replacesId: UUID? = nil, declaredType: DocumentMimeType? = nil) async throws -> PendingUpload {
    let mimeType = try DocumentFileValidator.validate(data, declared: declaredType)
    let request = DocumentUploadRequest(kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                        description: description?.nilIfBlank, documentDate: documentDate, link: link,
                                        mimeType: mimeType, byteSize: data.count, sha256: SHA256Digest.hex(data),
                                        replacesId: replacesId)
    let upload = PendingUpload(request: request, linkTitle: linkTitle)
    try await store.saveData(data, for: upload.id)
    try await store.save(upload)
    return upload
  }

  /// Kalan adımları çalıştırır. Hata olursa yükleme cihazda kalır (yeniden denenebilir).
  @discardableResult
  public func run(_ pending: PendingUpload,
                  progress: @escaping @Sendable (DocumentUploadStep) async -> Void = { _ in }) async throws -> ArchiveDocument {
    var upload = pending
    let data = try await store.data(for: upload.id)
    guard SHA256Digest.hex(data) == upload.request.sha256 else {
      throw RepositoryError.validation("Cihazdaki dosya değişmiş veya bozulmuş; belgeyi yeniden seçin.")
    }
    do {
      await progress(.reserving)
      var document = try await repository.reserveUpload(upload.request)
      if document.status == .yuklendi || document.status == .arsivlendi {
        await store.remove(id: upload.id)
        await progress(.done)
        return document
      }
      upload.storagePath = document.storagePath
      upload.stage = .yerAyrildi
      upload.lastError = nil
      try await store.save(upload)

      await progress(.uploading)
      try await repository.uploadFile(path: document.storagePath, data: data, mimeType: upload.request.mimeType)
      upload.stage = .dosyaGonderildi
      try await store.save(upload)

      await progress(.verifying)
      do {
        document = try await repository.completeUpload(id: upload.id)
      } catch RepositoryError.notFound {
        // Sunucu dosyayı görmüyor: bir kez daha gönder ve doğrula.
        try await repository.uploadFile(path: document.storagePath, data: data, mimeType: upload.request.mimeType)
        document = try await repository.completeUpload(id: upload.id)
      }
      await store.remove(id: upload.id)
      await progress(.done)
      return document
    } catch {
      upload.lastError = message(for: error)
      if case RepositoryError.conflict = error { upload.needsNewId = true }
      try? await store.save(upload)
      throw error
    }
  }

  /// Sunucu kimliği reddettiyse (iptal edilmiş / süresi dolmuş) aynı dosyayı yeni
  /// kimlikle yeniden hazırlar; eski yerel kayıt kaldırılır.
  public func renew(_ upload: PendingUpload) async throws -> PendingUpload {
    let data = try await store.data(for: upload.id)
    var request = upload.request
    request.id = UUID()
    var renewed = PendingUpload(request: request, linkTitle: upload.linkTitle, createdAt: upload.createdAt)
    renewed.lastError = nil
    try await store.saveData(data, for: renewed.id)
    try await store.save(renewed)
    await store.remove(id: upload.id)
    return renewed
  }

  /// Yüklemeden vazgeç: sunucuda ayrılan yer varsa iptal edilir, yerel kopya silinir.
  public func discard(_ upload: PendingUpload) async {
    if upload.stage != .hazir {
      _ = try? await repository.cancel(id: upload.id, reason: nil)
    }
    await store.remove(id: upload.id)
  }
}
