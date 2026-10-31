import Foundation

/// Repository hataları; arayüz bu mesajları doğrudan gösterir.
public enum RepositoryError: Error, Equatable, LocalizedError, Sendable {
  case notAuthenticated
  case invalidCredentials
  case forbidden(String?)
  case conflict(String?)
  case validation(String)
  case notFound
  case network
  case server(String)

  public var errorDescription: String? {
    switch self {
    case .notAuthenticated: "Oturum sona erdi. Lütfen yeniden giriş yapın."
    case .invalidCredentials: "E-posta veya şifre hatalı."
    case .forbidden(let message): message ?? "Bu işlem için yetkiniz yok."
    case .conflict(let message): message ?? "Kayıt başka biri tarafından değiştirilmiş veya zaten var."
    case .validation(let message): message
    case .notFound: "Kayıt bulunamadı."
    case .network: "Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin."
    case .server(let message): message
    }
  }
}

public struct AuthSession: Equatable, Sendable {
  public let userId: UUID
  public let email: String?

  public init(userId: UUID, email: String?) {
    self.userId = userId
    self.email = email
  }
}

public protocol AuthRepository: Sendable {
  /// Cihazda saklı geçerli oturum (yoksa nil). Gerekirse yeniler.
  func restoreSession() async -> AuthSession?
  func signIn(email: String, password: String) async throws -> AuthSession
  func signOut() async throws
  func sendPasswordReset(email: String) async throws
}

public protocol AccessRepository: Sendable {
  func myPermissions() async throws -> [PermissionGrant]
  func myProfile() async throws -> UserProfile
}

public protocol ProjectRepository: Sendable {
  func list(includeCompleted: Bool) async throws -> [Project]
  func get(id: UUID) async throws -> Project
  func create(_ draft: ProjectDraft) async throws -> Project
  /// İyimser kilit: `expectedVersion` sunucudakiyle aynı değilse `.conflict`.
  func update(id: UUID, expectedVersion: Int, with draft: ProjectDraft) async throws -> Project
}

public protocol CostCenterRepository: Sendable {
  func list() async throws -> [CostCenter]
}

public protocol CariRepository: Sendable {
  func listAccounts(type: CariType?, search: String?) async throws -> [CariAccount]
  func getAccount(id: UUID) async throws -> CariAccount
  func createAccount(_ draft: CariAccountDraft) async throws -> CariAccount
  func updateAccount(id: UUID, expectedVersion: Int, with draft: CariAccountDraft) async throws -> CariAccount
  /// Kullanıcının görebildiği hareketlerden hesaplanan bakiyeler.
  func balances(filter: CariFilter) async throws -> [CariBalance]
  func statement(accountId: UUID, filter: CariFilter) async throws -> [CariStatementLine]
  func post(_ entry: CariEntryDraft) async throws
  func reverse(entryId: UUID, reason: String, reversalId: UUID) async throws
}

public protocol TaskRepository: Sendable {
  /// projectId nil ise görülebilen tüm işler.
  func list(projectId: UUID?, openOnly: Bool) async throws -> [TaskItem]
  func create(_ task: TaskItem) async throws -> TaskItem
  func setStatus(id: UUID, status: TaskStatus) async throws
}

/// Taşeron, personel, ekip ve proje görevlendirmeleri. Kartlar şirket geneli
/// kayıtlardır; görevlendirmeler projeye aittir. Üyelik ve görevlendirmeler
/// silinmez, `end...` çağrılarıyla bitiş tarihi yazılır.
public protocol WorkforceRepository: Sendable {
  // Taşeron
  func subcontractors() async throws -> [Subcontractor]
  func createSubcontractor(_ draft: SubcontractorDraft) async throws -> Subcontractor
  func updateSubcontractor(id: UUID, expectedVersion: Int, with draft: SubcontractorDraft) async throws -> Subcontractor
  func documents(subcontractorId: UUID) async throws -> [SubcontractorDocument]
  func addDocument(_ document: SubcontractorDocument) async throws -> SubcontractorDocument
  func subcontractorProjects(subcontractorId: UUID?, projectId: UUID?) async throws -> [SubcontractorProject]
  func addSubcontractorProject(_ link: SubcontractorProject) async throws -> SubcontractorProject
  func endSubcontractorProject(id: UUID, on endDate: CalendarDate) async throws

  // Personel
  func personnel() async throws -> [Personnel]
  func createPersonnel(_ draft: PersonnelDraft) async throws -> Personnel
  func updatePersonnel(id: UUID, expectedVersion: Int, with draft: PersonnelDraft) async throws -> Personnel
  /// Yetki yoksa veya kayıt yoksa nil (iletişim bilgisi ayrı izinlidir).
  func contact(personnelId: UUID) async throws -> PersonnelContact?
  func setPhone(_ phone: String?, personnelId: UUID) async throws

  // Ekip
  func crews() async throws -> [Crew]
  func createCrew(_ draft: CrewDraft) async throws -> Crew
  func updateCrew(id: UUID, expectedVersion: Int, with draft: CrewDraft) async throws -> Crew
  func memberships(crewId: UUID?, personnelId: UUID?) async throws -> [CrewMembership]
  func addMembership(_ membership: CrewMembership) async throws -> CrewMembership
  func endMembership(id: UUID, on endDate: CalendarDate) async throws

  // Görevlendirme
  func assignments(projectId: UUID?, personnelId: UUID?, crewId: UUID?) async throws -> [ProjectAssignment]
  func assign(_ assignment: ProjectAssignment) async throws -> ProjectAssignment
  func endAssignment(id: UUID, on endDate: CalendarDate) async throws
  /// Projeye görevlendirilebilecek etkin personel ve ekipler (yalnızca ad ve görev).
  func candidates(projectId: UUID) async throws -> [AssignmentCandidate]
  /// Belirtilen günde projede çalışanlar (doğrudan ya da ekip üzerinden).
  func workforce(projectId: UUID, on day: CalendarDate) async throws -> [WorkforceEntry]
}

/// Puantaj (günlük çalışma kayıtları). Aylık veri tek seferde alınır; yazma
/// yalnızca `save` (toplu, tek işlem) ve ay durum işlemleriyle yapılır.
/// Hiçbir çağrı finansal kayıt oluşturmaz.
public protocol PuantajRepository: Sendable {
  /// Ay içinde projede görevli kişiler ve görev aralıkları.
  func roster(projectId: UUID, month: PuantajMonth) async throws -> [PuantajRosterLink]
  func entries(projectId: UUID, month: PuantajMonth) async throws -> [PuantajEntry]
  /// Ay için henüz kayıt yoksa nil (taslak).
  func period(projectId: UUID, month: PuantajMonth) async throws -> PuantajPeriod?
  func events(periodId: UUID) async throws -> [PuantajPeriodEvent]
  /// Tek işlem: bir öğe reddedilirse hiçbiri kaydedilmez. overwrite false ise
  /// sürümü bilinmeyen var olan kayıtlar atlanır.
  func save(projectId: UUID, items: [PuantajCellInput], overwrite: Bool) async throws -> [PuantajSaveOutcome]
  func transition(projectId: UUID, month: PuantajMonth, action: PuantajAction, reason: String?,
                  expectedVersion: Int?) async throws -> PuantajPeriod
  func approveOvertime(entryIds: [UUID]) async throws -> Int
  /// Sunucunun hesapladığı kişi bazında özet (Swift hesabıyla aynı kurallar).
  func summary(projectId: UUID, month: PuantajMonth) async throws -> [PuantajServerSummary]
}

/// Taşeron sözleşmesi, imalat (metraj), hakediş, teminat ve ödeme. Bütün
/// yazmalar sunucudaki RPC'lerle yapılır; tutarlar sunucuda hesaplanır.
/// Onaylı kayıtlar değişmez: düzeltme, iptal ve ters kayıtla yapılır.
public protocol ContractRepository: Sendable {
  // Sözleşme
  func contracts(projectId: UUID?) async throws -> [Contract]
  func versions(contractId: UUID) async throws -> [ContractVersion]
  func items(versionId: UUID) async throws -> [ContractItem]
  func taxCodes(versionId: UUID) async throws -> [String]
  /// Yeni sözleşme (revizyon 0) veya açık taslak revizyonun güncellenmesi.
  func saveContract(id: UUID, draft: ContractDraft, expectedVersion: Int?) async throws -> Contract
  func transition(contractId: UUID, action: ContractAction, reason: String?, expectedVersion: Int?) async throws -> Contract
  func taxRules() async throws -> [TaxRule]
  func paymentSources() async throws -> [PaymentSource]

  // İmalat (metraj; fiyatsız)
  func imalatItems(projectId: UUID) async throws -> [ImalatItem]
  func workQuantities(contractId: UUID) async throws -> [WorkQuantity]
  func saveWorkQuantity(_ quantity: WorkQuantity) async throws -> WorkQuantity
  func approveWorkQuantities(ids: [UUID]) async throws -> Int
  func cancelWorkQuantity(id: UUID, reason: String) async throws -> WorkQuantity

  // Hakediş
  /// contractId nil ise görülebilen tüm hakedişler.
  func hakedisList(contractId: UUID?) async throws -> [Hakedis]
  func hakedis(id: UUID) async throws -> Hakedis
  func lines(hakedisId: UUID) async throws -> [HakedisLine]
  func adjustments(hakedisId: UUID) async throws -> [HakedisAdjustment]
  func puantajLinks(hakedisId: UUID) async throws -> [HakedisPuantajLink]
  func createHakedis(id: UUID, contractId: UUID, periodStart: CalendarDate, periodEnd: CalendarDate,
                     note: String?) async throws -> Hakedis
  func refreshHakedis(id: UUID) async throws -> Hakedis
  func setProgress(hakedisId: UUID, itemKey: UUID, percent: Decimal) async throws -> Hakedis
  func setDeduction(hakedisId: UUID, kind: HakedisAdjustmentKind, amount: Decimal,
                    description: String?) async throws -> Hakedis
  func overrideLimit(hakedisId: UUID, reason: String) async throws -> Hakedis
  func transition(hakedisId: UUID, action: HakedisAction, reason: String?, expectedVersion: Int?) async throws -> Hakedis
  /// Onaylı hakedişi iptal eder ve yerine düzeltme taslağı açar.
  func revise(hakedisId: UUID, newId: UUID, reason: String) async throws -> Hakedis
  /// Onaylı hakedişi cari deftere işler (tekrar çağrı ikinci kayıt açmaz).
  /// TRY dışı sözleşmede `exchangeRate` zorunludur; TRY'de nil (1).
  func post(hakedisId: UUID, entryDate: CalendarDate?, exchangeRate: Decimal?) async throws -> Hakedis

  // Teminat ve ödeme
  func teminatReleases(contractId: UUID) async throws -> [TeminatRelease]
  func releaseTeminat(id: UUID, contractId: UUID, amount: Decimal, reason: String,
                      date: CalendarDate?, exchangeRate: Decimal?) async throws -> TeminatRelease
  func cancelTeminatRelease(id: UUID, reason: String) async throws -> TeminatRelease
  func payments(contractId: UUID) async throws -> [FinancePayment]
  func recordPayment(_ draft: FinancePaymentDraft) async throws -> FinancePayment
  func cancelPayment(id: UUID, reason: String) async throws -> FinancePayment
  func financeSummary(contractId: UUID) async throws -> ContractFinanceSummary
  func paymentStatus(hakedisIds: [UUID]) async throws -> [HakedisPaymentStatus]
  func events(contractId: UUID) async throws -> [FinanceEvent]
}

public extension ContractRepository {
  /// TL sözleşmeler için kısayol (kur 1).
  func post(hakedisId: UUID, entryDate: CalendarDate?) async throws -> Hakedis {
    try await post(hakedisId: hakedisId, entryDate: entryDate, exchangeRate: nil)
  }

  /// TL sözleşmeler için kısayol (kur 1).
  func releaseTeminat(id: UUID, contractId: UUID, amount: Decimal, reason: String,
                      date: CalendarDate?) async throws -> TeminatRelease {
    try await releaseTeminat(id: id, contractId: contractId, amount: amount, reason: reason, date: date, exchangeRate: nil)
  }
}

/// Şirket gider ve gelir belgeleri, onay, ödeme/tahsilat ve raporlar.
/// Yazmalar yalnızca RPC'lerle yapılır. Kimlikler istemcide üretilir:
/// aynı kimlikle tekrar gönderim ikinci belge veya ödeme açmaz.
/// Onaylı belge değişmez: düzeltme iptal + yeni belgeyle yapılır.
public protocol FinanceRepository: Sendable {
  /// includeInactive false ise yalnızca etkin kategoriler.
  func categories(kind: FinanceDocKind?, includeInactive: Bool) async throws -> [FinanceCategory]
  func saveCategory(_ category: FinanceCategory) async throws -> FinanceCategory

  func documents(filter: FinanceDocumentFilter) async throws -> [FinanceDocument]
  func document(id: UUID) async throws -> FinanceDocument
  func documents(ids: [UUID]) async throws -> [FinanceDocument]
  func statuses(documentIds: [UUID]) async throws -> [FinanceDocumentStatus]
  /// Onaylı ve kalanı olan belgeler (bekleyen borç / alacak), vadeye göre.
  func openStatuses(kind: FinanceDocKind) async throws -> [FinanceDocumentStatus]
  /// expectedVersion nil: yeni belge (tekrar gönderim aynı belgeyi döner).
  /// Dolu: taslak güncellemesi (sürüm eşleşmeli).
  func saveDocument(id: UUID, draft: FinanceDocumentDraft, expectedVersion: Int?) async throws -> FinanceDocument
  /// Onay yükümlülüğü/alacağı doğurur; cari bağlantılıysa deftere bir kez yazar.
  /// Peşin bildirilmiş belgede `settlementId` ile tam tutarlı ödeme açılır.
  func approve(id: UUID, expectedVersion: Int?, settlementId: UUID?) async throws -> FinanceDocument
  func cancel(id: UUID, reason: String) async throws -> FinanceDocument
  /// Onaylı belgeyi iptal eder ve yerine düzeltme taslağı açar.
  func revise(id: UUID, newId: UUID, reason: String) async throws -> FinanceDocument
  func events(documentId: UUID) async throws -> [FinanceDocumentEvent]

  func settlements(documentId: UUID) async throws -> [FinanceSettlement]
  func recordSettlement(_ draft: FinanceSettlementDraft) async throws -> FinanceSettlement
  func cancelSettlement(id: UUID, reason: String) async throws -> FinanceSettlement

  func report(kind: FinanceDocKind, group: FinanceReportGroup, from: CalendarDate?, to: CalendarDate?,
              projectId: UUID?, costCenterId: UUID?) async throws -> [FinanceReportRow]
  func projectCosts(projectId: UUID?) async throws -> [ProjectCostRow]
}

/// Evrak arşivi. Dosyalar özel Storage bucket'ında durur; yükleme üç adımdır:
/// yer ayırma (sunucu yolu üretir) → dosyayı o yola yükleme → tamamlama
/// (sunucu nesnenin boyutunu ve türünü doğrular). Her adım güvenle tekrarlanır.
public protocol DocumentRepository: Sendable {
  func documents(filter: DocumentFilter) async throws -> [ArchiveDocument]
  func document(id: UUID) async throws -> ArchiveDocument
  func events(documentId: UUID) async throws -> [DocumentEvent]

  /// Aynı kimlik + aynı istek aynı belgeyi (ve yolu) döner; farklı içerikle `.conflict`.
  func reserveUpload(_ request: DocumentUploadRequest) async throws -> ArchiveDocument
  /// Dosyayı ayrılan yola yükler. Nesne bu yolda zaten varsa (önceki deneme
  /// yüklemiş, yanıt kaybolmuşsa) başarılı sayılır; doğrulamayı tamamlama yapar.
  func uploadFile(path: String, data: Data, mimeType: DocumentMimeType) async throws
  /// Dosya henüz yoksa `.notFound`; boyut veya tür farklıysa `.validation`.
  func completeUpload(id: UUID) async throws -> ArchiveDocument
  func downloadFile(path: String) async throws -> Data

  func archive(id: UUID, reason: String) async throws -> ArchiveDocument
  /// Bekleyen yüklemeden vazgeçme (gerekçesiz) veya yanlış dosyanın iptali (gerekçe ≥ 10).
  func cancel(id: UUID, reason: String?) async throws -> ArchiveDocument
  func relink(id: UUID, to link: DocumentLink, reason: String, expectedVersion: Int) async throws -> ArchiveDocument
}

/// Uygulamanın kullandığı tüm repository'ler (bağımlılık enjeksiyonu için).
public struct Repositories: Sendable {
  public let auth: AuthRepository
  public let access: AccessRepository
  public let projects: ProjectRepository
  public let costCenters: CostCenterRepository
  public let cari: CariRepository
  public let tasks: TaskRepository
  public let workforce: WorkforceRepository
  public let puantaj: PuantajRepository
  public let contracts: ContractRepository
  public let finance: FinanceRepository
  public let documents: DocumentRepository

  public init(auth: AuthRepository, access: AccessRepository, projects: ProjectRepository,
              costCenters: CostCenterRepository, cari: CariRepository, tasks: TaskRepository,
              workforce: WorkforceRepository, puantaj: PuantajRepository, contracts: ContractRepository,
              finance: FinanceRepository, documents: DocumentRepository) {
    self.auth = auth
    self.access = access
    self.projects = projects
    self.costCenters = costCenters
    self.cari = cari
    self.tasks = tasks
    self.workforce = workforce
    self.puantaj = puantaj
    self.contracts = contracts
    self.finance = finance
    self.documents = documents
  }
}
