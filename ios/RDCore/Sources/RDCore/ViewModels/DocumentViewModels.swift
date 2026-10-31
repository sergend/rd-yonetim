import Foundation
import Observation

// Evrak arşivi ekranlarının view model'leri (Aşama 6). Yetki ve dosya
// doğrulamasının asıl kuralları sunucudadır; burada arayüz sadeleştirilir.

/// Belge eklenebilecek türler: finansal türler (fatura, fiş, sözleşme) proje
/// veya genel düzeyde ayrıca `belge.finans_read` ister.
public func allowedDocumentKinds(for link: DocumentLink, projectId: UUID?, access: AccessControl) -> [ArchiveDocumentKind] {
  switch link {
  case .project, .costCenter:
    let finance = projectId.map { access.can(.belgeFinansRead, in: $0) } ?? access.can(.belgeFinansRead)
    return ArchiveDocumentKind.allCases.filter { finance || !$0.isFinancial }
  case .financeDocument:
    return [.fatura, .fis, .irsaliye, .diger]
  case .contract:
    return [.sozlesme, .tutanak, .diger]
  }
}

// MARK: - Liste

@MainActor
@Observable
public final class DocumentListViewModel {
  public enum Scope: String, CaseIterable, Identifiable, Sendable {
    case etkin, arsiv, iptal

    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .etkin: "Etkin"
      case .arsiv: "Arşiv"
      case .iptal: "İptal"
      }
    }
    var statuses: Set<ArchiveDocumentStatus> {
      switch self {
      case .etkin: [.yuklendi]
      case .arsiv: [.arsivlendi]
      case .iptal: [.iptal]
      }
    }
  }

  public enum Period: String, CaseIterable, Identifiable, Sendable {
    case tumu, buAy, son3Ay, buYil

    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .tumu: "Tüm tarihler"
      case .buAy: "Bu ay"
      case .son3Ay: "Son 3 ay"
      case .buYil: "Bu yıl"
      }
    }
    func from(today: CalendarDate) -> CalendarDate? {
      switch self {
      case .tumu: nil
      case .buAy: CalendarDate(year: today.year, month: today.month, day: 1)
      case .son3Ay: today.adding(days: -92)
      case .buYil: CalendarDate(year: today.year, month: 1, day: 1)
      }
    }
  }

  public private(set) var documents: [ArchiveDocument] = []
  public private(set) var pending: [PendingUpload] = []
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  public var searchText = ""
  public var kind: ArchiveDocumentKind?
  public var scope: Scope = .etkin
  public var period: Period = .tumu
  /// Proje süzgeci (yalnızca bağlantı sabit değilken).
  public var projectId: UUID?

  /// Sabit bağlantı: gider/gelir, sözleşme veya proje detayından açıldığında.
  public let link: DocumentLink?
  public let access: AccessControl
  private let repositories: Repositories
  private let store: PendingUploadStore
  private let today: CalendarDate

  public init(link: DocumentLink? = nil, projectId: UUID? = nil, access: AccessControl, repositories: Repositories,
              store: PendingUploadStore, today: CalendarDate = .today()) {
    self.link = link
    self.projectId = projectId
    self.access = access
    self.repositories = repositories
    self.store = store
    self.today = today
  }

  public var filter: DocumentFilter {
    DocumentFilter(link: link, projectId: link == nil ? projectId : nil, kind: kind, statuses: scope.statuses,
                   from: period.from(today: today))
  }

  /// Ada, açıklamaya ve türe göre arama (Türkçe büyük/küçük harf duyarsız).
  public var filtered: [ArchiveDocument] {
    guard let query = searchText.nilIfBlank?.lowercased(with: Money.locale) else { return documents }
    return documents.filter { d in
      [d.title, d.description ?? "", d.kind.title].contains { $0.lowercased(with: Money.locale).contains(query) }
    }
  }

  /// Bu ekrandaki bekleyen / başarısız yüklemeler.
  public var visiblePending: [PendingUpload] {
    guard let link else { return pending }
    return pending.filter { $0.request.link == link }
  }

  public var canAdd: Bool {
    switch link {
    case .project(let id): access.can(.belgeWrite, in: id)
    case .costCenter: access.can(.belgeWrite)
    case .financeDocument, .contract: access.canAnywhere(.belgeWrite)
    case nil: access.canAnywhere(.belgeWrite)
    }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    pending = await store.all()
    do {
      documents = try await repositories.documents.documents(filter: filter)
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func refreshPending() async {
    pending = await store.all()
  }
}

// MARK: - Ekleme (tara / fotoğraf / dosya)

@MainActor
@Observable
public final class DocumentUploadViewModel {
  public enum State: Equatable {
    case editing
    case working(DocumentUploadStep)
    case done(ArchiveDocument)
    case failed(String)
  }

  public private(set) var fileData: Data?
  public private(set) var fileType: DocumentMimeType?
  public private(set) var fileError: String?
  public private(set) var state: State = .editing
  public private(set) var pendingUpload: PendingUpload?

  public var title = ""
  public var kind: ArchiveDocumentKind
  public var documentDate: CalendarDate
  public var description = ""

  public let link: DocumentLink
  public let linkTitle: String
  public let replacesId: UUID?
  public let allowedKinds: [ArchiveDocumentKind]
  private let uploader: DocumentUploader

  public init(link: DocumentLink, linkTitle: String, projectId: UUID?, access: AccessControl,
              repositories: Repositories, store: PendingUploadStore, replacing: ArchiveDocument? = nil,
              today: CalendarDate = .today()) {
    self.link = link
    self.linkTitle = linkTitle
    self.replacesId = replacing?.id
    self.uploader = DocumentUploader(repository: repositories.documents, store: store)
    let kinds = replacing.map { [$0.kind] } ?? allowedDocumentKinds(for: link, projectId: projectId, access: access)
    self.allowedKinds = kinds
    let preferred: ArchiveDocumentKind = switch link {
    case .financeDocument: .fis
    case .contract: .sozlesme
    case .project, .costCenter: .irsaliye
    }
    self.kind = replacing?.kind ?? (kinds.contains(preferred) ? preferred : kinds.first ?? .diger)
    self.documentDate = replacing?.documentDate ?? today
    self.title = replacing?.title ?? ""
  }

  /// Seçilen / taranan dosyayı doğrular (tür içerikten, boyut sınırı).
  public func setFile(_ data: Data, fileName: String? = nil) {
    fileError = nil
    let declared = fileName.flatMap(DocumentFileValidator.declaredType(fileName:))
    do {
      fileType = try DocumentFileValidator.validate(data, declared: declared)
      fileData = data
      if title.nilIfBlank == nil, let fileName {
        title = ((fileName as NSString).deletingPathExtension).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    } catch {
      fileData = nil
      fileType = nil
      fileError = message(for: error)
    }
  }

  public func clearFile() {
    fileData = nil
    fileType = nil
    fileError = nil
  }

  /// Dosya okunamadı / tarama veya fotoğraf hazırlanamadı.
  public func fileFailed(_ error: Error) {
    fileData = nil
    fileType = nil
    fileError = message(for: error)
  }

  public var titleError: String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Belge adı zorunlu" }
    if trimmed.count > DocumentLimits.maxTitleLength { return "Belge adı en çok 200 karakter olabilir" }
    return nil
  }

  public var canSubmit: Bool {
    if case .working = state { return false }
    return fileData != nil && titleError == nil && allowedKinds.contains(kind)
  }

  public var isWorking: Bool {
    if case .working = state { return true }
    return false
  }

  /// Dosyayı cihazda saklar ve yüklemeyi başlatır.
  public func submit() async {
    guard canSubmit, let data = fileData else { return }
    state = .working(.saving)
    do {
      pendingUpload = try await uploader.stage(data: data, kind: kind, title: title, description: description,
                                               documentDate: documentDate, link: link, linkTitle: linkTitle,
                                               replacesId: replacesId, declaredType: fileType)
    } catch {
      state = .failed(message(for: error))
      return
    }
    await runPending()
  }

  /// Aynı kimlikle yeniden dener (ağ hatası). Sunucu kimliği reddettiyse yeni kimlikle.
  public func retry() async {
    guard var upload = pendingUpload else { return await submit() }
    if upload.needsNewId {
      do {
        upload = try await uploader.renew(upload)
        pendingUpload = upload
      } catch {
        state = .failed(message(for: error))
        return
      }
    }
    await runPending()
  }

  /// Yüklemeden vazgeç (sunucuda ayrılan yer iptal edilir, cihazdaki kopya silinir).
  public func discard() async {
    if let upload = pendingUpload { await uploader.discard(upload) }
    pendingUpload = nil
    state = .editing
  }

  private func runPending() async {
    guard let upload = pendingUpload else { return }
    state = .working(.reserving)
    do {
      let document = try await uploader.run(upload) { @MainActor [weak self] step in
        self?.state = .working(step)
      }
      pendingUpload = nil
      state = .done(document)
    } catch {
      // Hata bilgisi ve "yeni kimlik gerekli" işareti depoya yazıldı.
      pendingUpload = await uploader.store.all().first { $0.id == upload.id } ?? upload
      state = .failed(message(for: error))
    }
  }
}

// MARK: - Bekleyen yüklemeyi sürdürme (liste ekranından)

@MainActor
@Observable
public final class PendingUploadViewModel {
  public private(set) var upload: PendingUpload
  public private(set) var step: DocumentUploadStep?
  public private(set) var errorMessage: String?
  public private(set) var completed: ArchiveDocument?
  private let uploader: DocumentUploader

  public init(upload: PendingUpload, repositories: Repositories, store: PendingUploadStore) {
    self.upload = upload
    self.errorMessage = upload.lastError
    self.uploader = DocumentUploader(repository: repositories.documents, store: store)
  }

  public func retry() async {
    errorMessage = nil
    do {
      if upload.needsNewId { upload = try await uploader.renew(upload) }
      completed = try await uploader.run(upload) { @MainActor [weak self] step in
        self?.step = step
      }
    } catch {
      errorMessage = message(for: error)
      step = nil
      if let saved = await uploader.store.all().first(where: { $0.id == upload.id }) { upload = saved }
    }
  }

  public func discard() async {
    await uploader.discard(upload)
  }
}

// MARK: - Ayrıntı

@MainActor
@Observable
public final class DocumentDetailViewModel {
  public enum Integrity: Equatable, Sendable {
    case unknown, verified, mismatch
  }

  public private(set) var document: ArchiveDocument
  public private(set) var events: [DocumentEvent] = []
  public private(set) var fileData: Data?
  public private(set) var integrity: Integrity = .unknown
  public private(set) var isLoadingFile = false
  public private(set) var isWorking = false
  public private(set) var errorMessage: String?
  public private(set) var fileError: String?

  public let access: AccessControl
  private let repositories: Repositories
  private let userId: UUID?

  public init(document: ArchiveDocument, access: AccessControl, repositories: Repositories, userId: UUID?) {
    self.document = document
    self.access = access
    self.repositories = repositories
    self.userId = userId
  }

  private var canManageAll: Bool {
    document.projectId.map { access.can(.belgeManage, in: $0) } ?? access.can(.belgeManage)
  }

  /// Arşiv / iptal düğmeleri (son karar sunucuda: onaylı finans belgesinin
  /// dosyasını yalnızca belge yöneticisi değiştirir).
  public var canManage: Bool {
    guard document.status == .yuklendi || document.status == .arsivlendi else { return false }
    return canManageAll || document.createdBy == userId
  }

  public var canRelink: Bool { canManageAll && (document.status == .yuklendi || document.status == .arsivlendi) }
  public var canReplace: Bool { document.status == .yuklendi && canManage }

  public func load() async {
    errorMessage = nil
    do {
      document = try await repositories.documents.document(id: document.id)
      events = try await repositories.documents.events(documentId: document.id)
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Dosyayı indirir ve SHA-256 özetini kayıtla karşılaştırır.
  public func loadFile() async {
    guard document.hasFile else { return }
    isLoadingFile = true
    fileError = nil
    defer { isLoadingFile = false }
    do {
      let data = try await repositories.documents.downloadFile(path: document.storagePath)
      fileData = data
      integrity = SHA256Digest.hex(data) == document.sha256 && data.count == document.byteSize ? .verified : .mismatch
    } catch {
      fileError = message(for: error)
    }
  }

  public func archive(reason: String) async -> Bool {
    await perform { try await self.repositories.documents.archive(id: self.document.id, reason: reason) }
  }

  public func cancel(reason: String) async -> Bool {
    await perform { try await self.repositories.documents.cancel(id: self.document.id, reason: reason) }
  }

  public func relink(to link: DocumentLink, reason: String) async -> Bool {
    await perform {
      try await self.repositories.documents.relink(id: self.document.id, to: link, reason: reason,
                                                   expectedVersion: self.document.version)
    }
  }

  private func perform(_ work: @escaping () async throws -> ArchiveDocument) async -> Bool {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      document = try await work()
      await load()
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }
}
