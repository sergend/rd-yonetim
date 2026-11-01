import Foundation

// Evrak arşivi için bellek içi uygulama (önizleme ve birim testleri). Asıl
// kurallar veritabanındadır (20261106000000_evrak_arsivi.sql, pgTAP 110);
// burada yetki, yükleme adımları, tekrar gönderim ve geçmiş taklit edilir.

extension InMemoryBackend {
  private struct Target {
    var projectId: UUID?
    var costCenterId: UUID?
    var financeDocumentId: UUID?
    var contractId: UUID?
    var cariAccountId: UUID?
    var subcontractorId: UUID?
    var isDemo: Bool
  }

  private func has(_ key: PermissionKey, _ project: UUID?) -> Bool {
    project.map { access.can(key, in: $0) } ?? access.can(key)
  }

  private func target(_ link: DocumentLink) -> Target? {
    switch link {
    case .project(let id):
      return projects.first { $0.id == id }.map { Target(projectId: $0.id, isDemo: $0.isDemo) }
    case .costCenter(let id):
      return costCenters.first { $0.id == id }.map { Target(costCenterId: $0.id, isDemo: $0.isDemo) }
    case .financeDocument(let id):
      return financeDocumentList.first { $0.id == id }.map { d in
        Target(projectId: d.projectId, costCenterId: d.costCenterId, financeDocumentId: d.id,
               cariAccountId: d.cariAccountId, isDemo: d.isDemo)
      }
    case .contract(let id):
      return contractList.first { $0.id == id }.map { c in
        Target(projectId: c.projectId, contractId: c.id, cariAccountId: c.cariAccountId,
               subcontractorId: c.subcontractorId, isDemo: c.isDemo)
      }
    }
  }

  /// private.document_link_access ile aynı kural.
  private func linkAccess(attach: Bool, _ link: DocumentLink, _ kind: ArchiveDocumentKind, project: UUID?) -> Bool {
    guard has(attach ? .belgeWrite : .belgeRead, project), has(.belgeRead, project) else { return false }
    switch link {
    case .project, .costCenter:
      return !kind.isFinancial || has(.belgeFinansRead, project)
    case .financeDocument(let id):
      guard let d = financeDocumentList.first(where: { $0.id == id }) else { return false }
      let scope = d.projectId
      let canRead = has(d.kind.readPermission, scope) || (d.createdBy == profile.id && has(d.kind.writePermission, scope))
      guard canRead else { return false }
      return !attach || (d.status != .iptal && has(d.kind.writePermission, scope))
    case .contract(let id):
      guard let c = contractList.first(where: { $0.id == id }) else { return false }
      return has(attach ? .sozlesmeWrite : .sozlesmeRead, c.projectId)
    }
  }

  private func canRead(_ d: ArchiveDocument) -> Bool {
    if d.status == .bekliyor, d.createdBy != profile.id { return false }
    return linkAccess(attach: false, d.link, d.kind, project: d.projectId)
  }

  private func canManage(_ d: ArchiveDocument) -> Bool {
    guard canRead(d) else { return false }
    if has(.belgeManage, d.projectId) { return true }
    guard d.createdBy == profile.id, linkAccess(attach: true, d.link, d.kind, project: d.projectId) else { return false }
    if case .financeDocument(let id) = d.link {
      return financeDocumentList.first { $0.id == id }?.status == .taslak
    }
    return true
  }

  private func documentEvent(_ id: UUID, _ action: String, from: ArchiveDocumentStatus?, to: ArchiveDocumentStatus?,
                             reason: String? = nil) {
    documentEvents.append(DocumentEvent(documentId: id, action: action, fromStatus: from?.rawValue,
                                        toStatus: to?.rawValue, reason: reason?.nilIfBlank, actorId: profile.id))
  }

  private func archiveIndex(_ id: UUID) throws -> Int {
    guard let index = archiveDocuments.firstIndex(where: { $0.id == id }), canRead(archiveDocuments[index]) else {
      throw RepositoryError.notFound
    }
    return index
  }

  private func linkKey(_ d: ArchiveDocument) -> DocumentLink { d.link }

  func listArchiveDocuments(filter: DocumentFilter) throws -> [ArchiveDocument] {
    try failIfNeeded()
    return archiveDocuments.filter { canRead($0) && filter.matches($0) }
      .sorted { ($0.documentDate, $0.createdAt ?? .distantPast) > ($1.documentDate, $1.createdAt ?? .distantPast) }
  }

  func archiveDocument(id: UUID) throws -> ArchiveDocument {
    try failIfNeeded()
    return archiveDocuments[try archiveIndex(id)]
  }

  func archiveEvents(documentId: UUID) throws -> [DocumentEvent] {
    try failIfNeeded()
    _ = try archiveIndex(documentId)
    return documentEvents.filter { $0.documentId == documentId }
  }

  func reserveUpload(_ r: DocumentUploadRequest) throws -> ArchiveDocument {
    try failIfNeeded()
    let title = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.count <= DocumentLimits.maxTitleLength else {
      throw RepositoryError.validation("Belge adı zorunlu (en çok 200 karakter)")
    }
    guard r.byteSize > 0, r.byteSize <= DocumentLimits.maxBytes else {
      throw RepositoryError.validation("Dosya boyutu 1 bayt ile 25 MB arasında olmalı")
    }
    let sha = r.sha256.lowercased()
    guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw RepositoryError.validation("SHA-256 özeti geçersiz") }
    guard let t = target(r.link), linkAccess(attach: false, r.link, .diger, project: t.projectId) else {
      throw RepositoryError.notFound
    }
    let description = r.description?.nilIfBlank

    if let existing = archiveDocuments.first(where: { $0.id == r.id }) {
      guard existing.createdBy == profile.id, canRead(existing) else {
        throw RepositoryError.conflict("Bu kimlikle başka bir belge var")
      }
      guard existing.status != .iptal else {
        throw RepositoryError.conflict("Bu kimlikli yükleme iptal edilmiş; yeni yükleme başlatın")
      }
      let same = existing.kind == r.kind && existing.title == title && existing.link == r.link
        && existing.mimeType == r.mimeType && existing.byteSize == r.byteSize && existing.sha256 == sha
        && existing.documentDate == r.documentDate && existing.description == description
        && existing.replacesId == r.replacesId
      guard same else { throw RepositoryError.conflict("Bu kimlikle farklı bir dosya veya bilgi gönderildi") }
      return existing
    }

    guard linkAccess(attach: true, r.link, r.kind, project: t.projectId) else {
      throw RepositoryError.forbidden("Bu kayda belge ekleme yetkiniz yok")
    }
    if let replaces = r.replacesId {
      guard let old = archiveDocuments.first(where: { $0.id == replaces }), canRead(old) else {
        throw RepositoryError.notFound
      }
      guard old.status == .yuklendi else {
        throw RepositoryError.validation("Yalnızca yüklenmiş etkin belge değiştirilebilir")
      }
      guard old.link == r.link else { throw RepositoryError.validation("Yeni dosya aynı kayda bağlanmalı") }
      guard canManage(old) else { throw RepositoryError.forbidden("Bu belgeyi değiştirme yetkiniz yok") }
    }
    if archiveDocuments.contains(where: { $0.status == .yuklendi && $0.sha256 == sha && $0.link == r.link }) {
      throw RepositoryError.conflict("Bu dosya bu kayda zaten eklenmiş")
    }
    let document = ArchiveDocument(
      id: r.id, kind: r.kind, title: title, description: description, documentDate: r.documentDate,
      linkType: r.linkType, projectId: t.projectId, costCenterId: t.costCenterId,
      financeDocumentId: t.financeDocumentId, contractId: t.contractId, cariAccountId: t.cariAccountId,
      subcontractorId: t.subcontractorId, mimeType: r.mimeType, byteSize: r.byteSize, sha256: sha,
      storagePath: "\(UUID().uuidString.lowercased())/\(UUID().uuidString.lowercased()).\(r.mimeType.fileExtension)",
      status: .bekliyor, replacesId: r.replacesId, createdBy: profile.id, createdAt: Date(), isDemo: t.isDemo)
    archiveDocuments.append(document)
    documentEvent(document.id, "rezerve", from: nil, to: .bekliyor)
    return document
  }

  func uploadObject(path: String, data: Data, mimeType: DocumentMimeType) throws {
    try failIfNeeded()
    uploadCallCount += 1
    guard let d = archiveDocuments.first(where: { $0.storagePath == path }) else {
      throw RepositoryError.forbidden("Bu yola dosya yükleme yetkiniz yok")
    }
    if storageObjects[path] != nil {
      return  // önceki deneme yüklemiş: başarılı sayılır
    }
    guard d.status == .bekliyor, d.createdBy == profile.id,
          linkAccess(attach: true, d.link, d.kind, project: d.projectId) else {
      throw RepositoryError.forbidden("Bu yola dosya yükleme yetkiniz yok")
    }
    var stored = data
    if corruptNextUpload, !stored.isEmpty {
      corruptNextUpload = false
      stored[stored.count - 1] ^= 0xFF
    }
    storageObjects[path] = (stored, mimeType)
    if dropNextUploadResponse {
      dropNextUploadResponse = false
      throw RepositoryError.network  // dosya sunucuya ulaştı, yanıt kayboldu
    }
  }

  func completeUpload(id: UUID) throws -> ArchiveDocument {
    try failIfNeeded()
    guard let index = archiveDocuments.firstIndex(where: { $0.id == id }),
          archiveDocuments[index].createdBy == profile.id, canRead(archiveDocuments[index]) else {
      throw RepositoryError.notFound
    }
    var d = archiveDocuments[index]
    switch d.status {
    case .yuklendi, .arsivlendi: return d
    case .iptal:
      if d.cancelReason == "Sunucuda hesaplanan özet beyan edilen dosyayla uyuşmuyor" {
        throw RepositoryError.conflict("Sunucuya ulaşan dosya cihazdakiyle aynı değil; yeniden yükleyin")
      }
      throw RepositoryError.conflict("Bu yükleme iptal edilmiş veya süresi dolmuş; yeniden başlatın")
    case .bekliyor: break
    }
    guard let object = storageObjects[d.storagePath] else { throw RepositoryError.notFound }
    guard object.data.count == d.byteSize else {
      throw RepositoryError.validation("Yüklenen dosyanın boyutu beklenenden farklı")
    }
    guard object.mimeType == d.mimeType else { throw RepositoryError.validation("Yüklenen dosyanın türü beklenenden farklı") }
    // Sunucu doğrulaması (belge-dogrula): gerçek baytların özeti beyan edilenle aynı olmalı.
    guard SHA256Digest.hex(object.data) == d.sha256 else {
      d.status = .iptal
      d.cancelReason = "Sunucuda hesaplanan özet beyan edilen dosyayla uyuşmuyor"
      d.cancelledAt = Date()
      d.version += 1
      archiveDocuments[index] = d
      documentEvent(id, "ozet_uyusmadi", from: .bekliyor, to: .iptal, reason: d.cancelReason)
      throw RepositoryError.conflict("Sunucuya ulaşan dosya cihazdakiyle aynı değil; yeniden yükleyin")
    }
    if let replaces = d.replacesId, let old = archiveDocuments.firstIndex(where: { $0.id == replaces }) {
      archiveDocuments[old].status = .iptal
      archiveDocuments[old].cancelReason = "Yeni dosyayla değiştirildi"
      archiveDocuments[old].cancelledAt = Date()
      archiveDocuments[old].version += 1
      documentEvent(replaces, "degistirildi", from: .yuklendi, to: .iptal, reason: "Yeni dosyayla değiştirildi")
      endPurchaseDocumentLinks(documentId: replaces, reason: "Yeni dosyayla değiştirildi", replacement: d)
    }
    d.status = .yuklendi
    d.uploadedAt = Date()
    d.version += 1
    archiveDocuments[index] = d
    documentEvent(id, "yuklendi", from: .bekliyor, to: .yuklendi)
    return d
  }

  func downloadObject(path: String) throws -> Data {
    try failIfNeeded()
    guard let d = archiveDocuments.first(where: { $0.storagePath == path }), canRead(d),
          let object = storageObjects[path] else {
      throw RepositoryError.notFound
    }
    return object.data
  }

  func archiveDocument(id: UUID, reason: String) throws -> ArchiveDocument {
    try failIfNeeded()
    let index = try archiveIndex(id)
    var d = archiveDocuments[index]
    if d.status == .arsivlendi { return d }
    guard d.status == .yuklendi else { throw RepositoryError.validation("Yalnızca yüklenmiş belge arşivlenebilir") }
    guard reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
      throw RepositoryError.validation("Arşivleme gerekçesi zorunlu")
    }
    guard canManage(d) else { throw RepositoryError.forbidden("Bu belgeyi arşivleme yetkiniz yok") }
    d.status = .arsivlendi
    d.archivedAt = Date()
    d.archiveReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    d.version += 1
    archiveDocuments[index] = d
    documentEvent(id, "arsivlendi", from: .yuklendi, to: .arsivlendi, reason: reason)
    return d
  }

  func cancelDocument(id: UUID, reason: String?) throws -> ArchiveDocument {
    try failIfNeeded()
    let index = try archiveIndex(id)
    var d = archiveDocuments[index]
    if d.status == .iptal { return d }
    let from = d.status
    if d.status == .bekliyor {
      guard d.createdBy == profile.id else { throw RepositoryError.notFound }
    } else {
      guard (reason?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) >= 10 else {
        throw RepositoryError.validation("İptal gerekçesi en az 10 karakter olmalı")
      }
      guard canManage(d) else { throw RepositoryError.forbidden("Bu belgeyi iptal etme yetkiniz yok") }
    }
    d.status = .iptal
    d.cancelledAt = Date()
    d.cancelReason = reason?.nilIfBlank ?? "Yükleme vazgeçildi"
    d.version += 1
    archiveDocuments[index] = d
    endPurchaseDocumentLinks(documentId: id, reason: d.cancelReason ?? "", replacement: nil)
    documentEvent(id, "iptal", from: from, to: .iptal, reason: d.cancelReason)
    return d
  }

  func relinkDocument(id: UUID, to link: DocumentLink, reason: String, expectedVersion: Int) throws -> ArchiveDocument {
    try failIfNeeded()
    let index = try archiveIndex(id)
    var d = archiveDocuments[index]
    guard has(.belgeManage, d.projectId) else { throw RepositoryError.forbidden("Belge bağlantısını değiştirme yetkiniz yok") }
    guard d.version == expectedVersion else { throw RepositoryError.conflict(nil) }
    guard d.status == .yuklendi || d.status == .arsivlendi else {
      throw RepositoryError.validation("Yalnızca yüklenmiş belgenin bağlantısı değiştirilebilir")
    }
    guard reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 else {
      throw RepositoryError.validation("Bağlantı değişikliği gerekçesi en az 10 karakter olmalı")
    }
    guard let t = target(link), linkAccess(attach: false, link, .diger, project: t.projectId) else {
      throw RepositoryError.notFound
    }
    guard linkAccess(attach: true, link, d.kind, project: t.projectId), has(.belgeManage, t.projectId) else {
      throw RepositoryError.forbidden("Hedef kayda belge ekleme yetkiniz yok")
    }
    guard t.isDemo == d.isDemo else {
      throw RepositoryError.validation("Deneme (DEMO) belgesi gerçek kayda, gerçek belge deneme kaydına taşınamaz")
    }
    if d.link == link { return d }
    try guardStockDocumentScope(documentId: id, projectId: t.projectId, isDemo: d.isDemo)
    documentEvent(id, "baglanti_degisti", from: d.status, to: d.status, reason: reason)
    d.linkType = link.type
    d.projectId = t.projectId
    d.costCenterId = t.costCenterId
    d.financeDocumentId = t.financeDocumentId
    d.contractId = t.contractId
    d.cariAccountId = t.cariAccountId
    d.subcontractorId = t.subcontractorId
    d.version += 1
    archiveDocuments[index] = d
    return d
  }
}

struct InMemoryDocuments: DocumentRepository {
  let backend: InMemoryBackend
  func documents(filter: DocumentFilter) async throws -> [ArchiveDocument] {
    try await backend.listArchiveDocuments(filter: filter)
  }
  func document(id: UUID) async throws -> ArchiveDocument { try await backend.archiveDocument(id: id) }
  func events(documentId: UUID) async throws -> [DocumentEvent] { try await backend.archiveEvents(documentId: documentId) }
  func reserveUpload(_ request: DocumentUploadRequest) async throws -> ArchiveDocument {
    try await backend.reserveUpload(request)
  }
  func uploadFile(path: String, data: Data, mimeType: DocumentMimeType) async throws {
    try await backend.uploadObject(path: path, data: data, mimeType: mimeType)
  }
  func completeUpload(id: UUID) async throws -> ArchiveDocument { try await backend.completeUpload(id: id) }
  func downloadFile(path: String) async throws -> Data { try await backend.downloadObject(path: path) }
  func archive(id: UUID, reason: String) async throws -> ArchiveDocument {
    try await backend.archiveDocument(id: id, reason: reason)
  }
  func cancel(id: UUID, reason: String?) async throws -> ArchiveDocument {
    try await backend.cancelDocument(id: id, reason: reason)
  }
  func relink(id: UUID, to link: DocumentLink, reason: String, expectedVersion: Int) async throws -> ArchiveDocument {
    try await backend.relinkDocument(id: id, to: link, reason: reason, expectedVersion: expectedVersion)
  }
}
