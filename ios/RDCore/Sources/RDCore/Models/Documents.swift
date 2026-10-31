import Foundation

// MARK: - Evrak arşivi (Aşama 6)
//
// Belge dosyaları özel Supabase Storage bucket'ında ("belgeler") durur.
// Belgenin projesi, carisi ve DEMO işareti bağlandığı kayıttan sunucuda
// türetilir; istemci yalnızca bağlantıyı (DocumentLink) gönderir.

/// Belge türü. Fatura, fiş ve sözleşme finansal türlerdir: proje düzeyinde
/// görmek için ayrıca `belge.finans_read` gerekir.
public enum ArchiveDocumentKind: String, Codable, CaseIterable, Sendable, Identifiable {
  case fatura, fis, irsaliye, sozlesme, tutanak, ruhsat, diger

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .fatura: "Fatura"
    case .fis: "Fiş"
    case .irsaliye: "İrsaliye"
    case .sozlesme: "Sözleşme"
    case .tutanak: "Tutanak"
    case .ruhsat: "Ruhsat"
    case .diger: "Diğer"
    }
  }

  public var symbol: String {
    switch self {
    case .fatura: "doc.text"
    case .fis: "receipt"
    case .irsaliye: "shippingbox"
    case .sozlesme: "signature"
    case .tutanak: "doc.plaintext"
    case .ruhsat: "checkmark.seal"
    case .diger: "doc"
    }
  }

  public var isFinancial: Bool { self == .fatura || self == .fis || self == .sozlesme }
}

public enum DocumentLinkType: String, Codable, Sendable {
  case proje
  case masrafMerkezi = "masraf_merkezi"
  case finansBelgesi = "finans_belgesi"
  case sozlesme
}

/// Belgenin bağlandığı tek ana kayıt.
public enum DocumentLink: Hashable, Sendable {
  case project(UUID)
  case costCenter(UUID)
  case financeDocument(UUID)
  case contract(UUID)

  public var type: DocumentLinkType {
    switch self {
    case .project: .proje
    case .costCenter: .masrafMerkezi
    case .financeDocument: .finansBelgesi
    case .contract: .sozlesme
    }
  }

  public var id: UUID {
    switch self {
    case .project(let id), .costCenter(let id), .financeDocument(let id), .contract(let id): id
    }
  }

  public var title: String {
    switch self {
    case .project: "Proje belgesi"
    case .costCenter: "Genel masraf belgesi"
    case .financeDocument: "Gider / gelir belgesi"
    case .contract: "Sözleşme dosyası"
    }
  }
}

public enum ArchiveDocumentStatus: String, Codable, CaseIterable, Sendable, Identifiable {
  case bekliyor, yuklendi, arsivlendi, iptal

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .bekliyor: "Yükleme bekliyor"
    case .yuklendi: "Yüklendi"
    case .arsivlendi: "Arşivde"
    case .iptal: "İptal"
    }
  }
}

/// İzin verilen dosya türleri. Tür, uzantıdan değil içeriğin ilk
/// baytlarından belirlenir (DocumentFileValidator).
public enum DocumentMimeType: String, Codable, CaseIterable, Sendable {
  case pdf = "application/pdf"
  case jpeg = "image/jpeg"
  case png = "image/png"

  public var fileExtension: String {
    switch self {
    case .pdf: "pdf"
    case .jpeg: "jpg"
    case .png: "png"
    }
  }

  public var title: String {
    switch self {
    case .pdf: "PDF"
    case .jpeg: "JPEG fotoğraf"
    case .png: "PNG görsel"
    }
  }

  public var isImage: Bool { self != .pdf }
}

public struct ArchiveDocument: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var kind: ArchiveDocumentKind
  public var title: String
  public var description: String?
  public var documentDate: CalendarDate
  public var linkType: DocumentLinkType
  public var projectId: UUID?
  public var costCenterId: UUID?
  public var financeDocumentId: UUID?
  public var contractId: UUID?
  public var cariAccountId: UUID?
  public var subcontractorId: UUID?
  public var mimeType: DocumentMimeType
  public var byteSize: Int
  public var sha256: String
  public var storagePath: String
  public var status: ArchiveDocumentStatus
  public var uploadedAt: Date?
  public var archivedAt: Date?
  public var archiveReason: String?
  public var cancelledAt: Date?
  public var cancelReason: String?
  public var replacesId: UUID?
  public var createdBy: UUID?
  public var createdAt: Date?
  public var isDemo: Bool
  public var version: Int

  public init(id: UUID, kind: ArchiveDocumentKind, title: String, description: String? = nil,
              documentDate: CalendarDate, linkType: DocumentLinkType, projectId: UUID? = nil, costCenterId: UUID? = nil,
              financeDocumentId: UUID? = nil, contractId: UUID? = nil, cariAccountId: UUID? = nil,
              subcontractorId: UUID? = nil, mimeType: DocumentMimeType, byteSize: Int, sha256: String,
              storagePath: String, status: ArchiveDocumentStatus = .bekliyor, uploadedAt: Date? = nil,
              archivedAt: Date? = nil, archiveReason: String? = nil, cancelledAt: Date? = nil,
              cancelReason: String? = nil, replacesId: UUID? = nil, createdBy: UUID? = nil, createdAt: Date? = nil,
              isDemo: Bool = false, version: Int = 1) {
    self.id = id
    self.kind = kind
    self.title = title
    self.description = description
    self.documentDate = documentDate
    self.linkType = linkType
    self.projectId = projectId
    self.costCenterId = costCenterId
    self.financeDocumentId = financeDocumentId
    self.contractId = contractId
    self.cariAccountId = cariAccountId
    self.subcontractorId = subcontractorId
    self.mimeType = mimeType
    self.byteSize = byteSize
    self.sha256 = sha256
    self.storagePath = storagePath
    self.status = status
    self.uploadedAt = uploadedAt
    self.archivedAt = archivedAt
    self.archiveReason = archiveReason
    self.cancelledAt = cancelledAt
    self.cancelReason = cancelReason
    self.replacesId = replacesId
    self.createdBy = createdBy
    self.createdAt = createdAt
    self.isDemo = isDemo
    self.version = version
  }

  /// Bağlı ana kayıt.
  public var link: DocumentLink {
    switch linkType {
    case .proje: .project(projectId ?? id)
    case .masrafMerkezi: .costCenter(costCenterId ?? id)
    case .finansBelgesi: .financeDocument(financeDocumentId ?? id)
    case .sozlesme: .contract(contractId ?? id)
    }
  }

  /// Dosyası okunabilir mi (yüklemesi tamamlanmış; iptal edilse de dosya saklanır).
  public var hasFile: Bool { uploadedAt != nil }

  enum CodingKeys: String, CodingKey {
    case id, kind, title, description, status, version
    case documentDate = "document_date", linkType = "link_type", projectId = "project_id"
    case costCenterId = "cost_center_id", financeDocumentId = "finance_document_id", contractId = "contract_id"
    case cariAccountId = "cari_account_id", subcontractorId = "subcontractor_id", mimeType = "mime_type"
    case byteSize = "byte_size", sha256, storagePath = "storage_path", uploadedAt = "uploaded_at"
    case archivedAt = "archived_at", archiveReason = "archive_reason", cancelledAt = "cancelled_at"
    case cancelReason = "cancel_reason", replacesId = "replaces_id", createdBy = "created_by"
    case createdAt = "created_at", isDemo = "is_demo"
  }
}

/// Yükleme yeri ayırma isteği. Kimlik istemcide üretilir; aynı kimlikle
/// aynı istek tekrar gönderilirse aynı belge döner.
public struct DocumentUploadRequest: Hashable, Codable, Sendable {
  public var id: UUID
  public var kind: ArchiveDocumentKind
  public var title: String
  public var description: String?
  public var documentDate: CalendarDate
  public var linkType: DocumentLinkType
  public var linkId: UUID
  public var mimeType: DocumentMimeType
  public var byteSize: Int
  public var sha256: String
  public var replacesId: UUID?

  public init(id: UUID = UUID(), kind: ArchiveDocumentKind, title: String, description: String? = nil,
              documentDate: CalendarDate, link: DocumentLink, mimeType: DocumentMimeType, byteSize: Int,
              sha256: String, replacesId: UUID? = nil) {
    self.id = id
    self.kind = kind
    self.title = title
    self.description = description
    self.documentDate = documentDate
    self.linkType = link.type
    self.linkId = link.id
    self.mimeType = mimeType
    self.byteSize = byteSize
    self.sha256 = sha256
    self.replacesId = replacesId
  }

  public var link: DocumentLink {
    switch linkType {
    case .proje: .project(linkId)
    case .masrafMerkezi: .costCenter(linkId)
    case .finansBelgesi: .financeDocument(linkId)
    case .sozlesme: .contract(linkId)
    }
  }
}

public struct DocumentEvent: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public var documentId: UUID
  public var action: String
  public var fromStatus: String?
  public var toStatus: String?
  public var reason: String?
  public var actorId: UUID?
  public var occurredAt: Date

  public init(id: UUID = UUID(), documentId: UUID, action: String, fromStatus: String? = nil, toStatus: String? = nil,
              reason: String? = nil, actorId: UUID? = nil, occurredAt: Date = Date()) {
    self.id = id
    self.documentId = documentId
    self.action = action
    self.fromStatus = fromStatus
    self.toStatus = toStatus
    self.reason = reason
    self.actorId = actorId
    self.occurredAt = occurredAt
  }

  public var title: String {
    switch action {
    case "rezerve": "Yükleme başlatıldı"
    case "yuklendi": "Dosya yüklendi ve doğrulandı"
    case "arsivlendi": "Arşivlendi"
    case "iptal": "İptal edildi"
    case "degistirildi": "Yeni dosyayla değiştirildi"
    case "baglanti_degisti": "Bağlantısı değiştirildi"
    case "suresi_doldu": "Yükleme süresi doldu"
    default: action.replacingOccurrences(of: "_", with: " ")
    }
  }

  enum CodingKeys: String, CodingKey {
    case id, action, reason
    case documentId = "document_id", fromStatus = "from_status", toStatus = "to_status"
    case actorId = "actor_id", occurredAt = "occurred_at"
  }
}

/// Belge listesi süzgeci. Boş alanlar süzmez.
public struct DocumentFilter: Hashable, Sendable {
  public var link: DocumentLink?
  public var projectId: UUID?
  public var kind: ArchiveDocumentKind?
  public var statuses: Set<ArchiveDocumentStatus>
  public var from: CalendarDate?
  public var to: CalendarDate?

  public init(link: DocumentLink? = nil, projectId: UUID? = nil, kind: ArchiveDocumentKind? = nil,
              statuses: Set<ArchiveDocumentStatus> = [.yuklendi], from: CalendarDate? = nil, to: CalendarDate? = nil) {
    self.link = link
    self.projectId = projectId
    self.kind = kind
    self.statuses = statuses
    self.from = from
    self.to = to
  }

  public func matches(_ document: ArchiveDocument) -> Bool {
    if let link, document.link != link { return false }
    if let projectId, document.projectId != projectId { return false }
    if let kind, document.kind != kind { return false }
    if !statuses.isEmpty, !statuses.contains(document.status) { return false }
    if let from, document.documentDate < from { return false }
    if let to, document.documentDate > to { return false }
    return true
  }
}

/// Sunucudaki sınırlarla aynı (migration 20261106000000).
public enum DocumentLimits {
  public static let maxBytes = 25 * 1024 * 1024
  public static let maxTitleLength = 200
}

extension Int {
  /// "1,2 MB" biçiminde dosya boyutu.
  public var fileSizeText: String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB]
    return formatter.string(fromByteCount: Int64(self))
  }
}
