import Foundation
import RDCore
import Supabase

// MARK: - Evrak arşivi

/// Belge bilgileri RLS'li `documents` tablosundan okunur; yazmalar RPC'lerle.
/// Dosyalar özel `belgeler` bucket'ındadır: yükleme yalnızca sunucunun
/// ayırdığı yola yapılır (storage.objects politikası), indirme oturumlu
/// istekle yapılır. Herkese açık veya kalıcı adres üretilmez.
struct SupabaseDocumentRepository: DocumentRepository {
  let client: SupabaseClient
  static let bucket = "belgeler"

  private let columns =
    "id,kind,title,description,document_date,link_type,project_id,cost_center_id,finance_document_id,contract_id," +
    "cari_account_id,subcontractor_id,mime_type,byte_size,sha256,storage_path,status,uploaded_at,archived_at," +
    "archive_reason,cancelled_at,cancel_reason,replaces_id,created_by,created_at,is_demo,version"
  private let eventColumns = "id,document_id,action,from_status,to_status,reason,actor_id,occurred_at"

  /// Boş (nil) değerleri de gönderir: RPC parametre adları eksiksiz eşleşmeli.
  private struct Params: Encodable {
    let values: [String: AnyJSON]
    func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }
  }

  private func rpc(_ name: String, _ values: [String: AnyJSON]) async throws -> ArchiveDocument {
    try await mapped { try await client.rpc(name, params: Params(values: values)).execute().value }
  }

  private static func text(_ value: String?) -> AnyJSON { value.map { .string($0) } ?? .null }
  private static func uuid(_ value: UUID?) -> AnyJSON { value.map { .string($0.uuidString) } ?? .null }

  func documents(filter: DocumentFilter) async throws -> [ArchiveDocument] {
    try await mapped {
      var query = client.from("documents").select(columns)
      if let link = filter.link {
        switch link {
        case .project(let id): query = query.eq("link_type", value: "proje").eq("project_id", value: id)
        case .costCenter(let id): query = query.eq("link_type", value: "masraf_merkezi").eq("cost_center_id", value: id)
        case .financeDocument(let id): query = query.eq("finance_document_id", value: id)
        case .contract(let id): query = query.eq("contract_id", value: id)
        }
      }
      if let id = filter.projectId { query = query.eq("project_id", value: id) }
      if let kind = filter.kind { query = query.eq("kind", value: kind.rawValue) }
      if !filter.statuses.isEmpty { query = query.in("status", values: filter.statuses.map(\.rawValue).sorted()) }
      if let from = filter.from { query = query.gte("document_date", value: from.iso) }
      if let to = filter.to { query = query.lte("document_date", value: to.iso) }
      return try await query.order("document_date", ascending: false).order("created_at", ascending: false)
        .limit(500).execute().value
    }
  }

  func document(id: UUID) async throws -> ArchiveDocument {
    try await mapped { try await client.from("documents").select(columns).eq("id", value: id).single().execute().value }
  }

  func events(documentId: UUID) async throws -> [DocumentEvent] {
    try await mapped {
      try await client.from("document_events").select(eventColumns).eq("document_id", value: documentId)
        .order("occurred_at").execute().value
    }
  }

  func reserveUpload(_ request: DocumentUploadRequest) async throws -> ArchiveDocument {
    try await rpc("reserve_document_upload", [
      "p_id": .string(request.id.uuidString), "p_kind": .string(request.kind.rawValue),
      "p_title": .string(request.title), "p_link_type": .string(request.linkType.rawValue),
      "p_link_id": .string(request.linkId.uuidString), "p_mime_type": .string(request.mimeType.rawValue),
      "p_byte_size": .integer(request.byteSize), "p_sha256": .string(request.sha256),
      "p_document_date": .string(request.documentDate.iso), "p_description": Self.text(request.description),
      "p_replaces_id": Self.uuid(request.replacesId),
    ])
  }

  func uploadFile(path: String, data: Data, mimeType: DocumentMimeType) async throws {
    do {
      try await client.storage.from(Self.bucket)
        .upload(path, data: data, options: FileOptions(cacheControl: "0", contentType: mimeType.rawValue, upsert: false))
    } catch let error as StorageError where error.statusCode == "409" {
      return  // önceki deneme yüklemiş (yanıt kaybolmuştu); doğrulamayı tamamlama yapar
    } catch {
      throw Self.map(storage: error)
    }
  }

  func completeUpload(id: UUID) async throws -> ArchiveDocument {
    try await rpc("complete_document_upload", ["p_id": .string(id.uuidString)])
  }

  func downloadFile(path: String) async throws -> Data {
    do {
      return try await client.storage.from(Self.bucket).download(path: path)
    } catch {
      throw Self.map(storage: error)
    }
  }

  func archive(id: UUID, reason: String) async throws -> ArchiveDocument {
    try await rpc("archive_document", ["p_id": .string(id.uuidString), "p_reason": .string(reason)])
  }

  func cancel(id: UUID, reason: String?) async throws -> ArchiveDocument {
    try await rpc("cancel_document", ["p_id": .string(id.uuidString), "p_reason": Self.text(reason)])
  }

  func relink(id: UUID, to link: DocumentLink, reason: String, expectedVersion: Int) async throws -> ArchiveDocument {
    try await rpc("relink_document", [
      "p_id": .string(id.uuidString), "p_link_type": .string(link.type.rawValue),
      "p_link_id": .string(link.id.uuidString), "p_reason": .string(reason),
      "p_expected_version": .integer(expectedVersion),
    ])
  }

  /// Storage hatalarını uygulama hatalarına çevirir.
  static func map(storage error: Error) -> RepositoryError {
    guard let error = error as? StorageError else { return ErrorMapper.map(error) }
    switch error.statusCode {
    case "401": return .notAuthenticated
    case "403": return .forbidden("Bu dosyaya erişim yetkiniz yok.")
    case "404": return .notFound
    case "409": return .conflict("Dosya zaten yüklenmiş.")
    case "413": return .validation("Dosya çok büyük (en fazla 25 MB).")
    case "415": return .validation("Bu dosya türü desteklenmiyor.")
    default:
      if error.message.lowercased().contains("mime") { return .validation("Bu dosya türü desteklenmiyor.") }
      if error.message.lowercased().contains("size") { return .validation("Dosya çok büyük (en fazla 25 MB).") }
      return .server("Dosya işlemi tamamlanamadı. Lütfen tekrar deneyin.")
    }
  }
}
