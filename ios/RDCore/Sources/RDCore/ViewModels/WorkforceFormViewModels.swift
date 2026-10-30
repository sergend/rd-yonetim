import Foundation
import Observation

/// Telefon biçimi: rakam, boşluk, +, parantez ve tire; 7–20 karakter (veritabanı kuralı).
public func isValidPhone(_ value: String) -> Bool {
  (7...20).contains(value.count) && value.allSatisfy { $0.isASCIIDigit || " +()-".contains($0) }
}

// MARK: - Taşeron

/// Taşeron kartı formu. Zorunlu alan yalnızca ad/unvan. Cari kart seçimi,
/// cari kartları görebilen kullanıcıya sunulur; aynı cari ikinci taşerona bağlanamaz.
@MainActor
@Observable
public final class SubcontractorFormViewModel {
  public var name: String
  public var trade: WorkTrade?
  public var cariAccountId: UUID?
  public var contactName: String
  public var phone: String
  public var email: String
  public var notes: String
  public var isActive: Bool

  public private(set) var cariOptions: [CariAccount] = []
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?

  public let editing: Subcontractor?
  public let canLinkCari: Bool
  private let repositories: Repositories

  public init(editing: Subcontractor? = nil, access: AccessControl, repositories: Repositories) {
    self.editing = editing
    self.repositories = repositories
    canLinkCari = access.can(.cariRead)
    let draft = editing.map(SubcontractorDraft.init) ?? SubcontractorDraft()
    name = draft.name
    trade = draft.trade
    cariAccountId = draft.cariAccountId
    contactName = draft.contactName ?? ""
    phone = draft.phone ?? ""
    email = draft.email ?? ""
    notes = draft.notes ?? ""
    isActive = draft.isActive
  }

  public var formTitle: String { editing == nil ? "Yeni taşeron" : "Taşeronu düzenle" }

  /// Bağlanabilecek cari kartlar: etkin, müşteri olmayan, başka taşerona bağlı olmayan.
  public func loadOptions() async {
    guard canLinkCari else { return }
    do {
      let linked = Set(try await repositories.workforce.subcontractors()
        .filter { $0.id != editing?.id }.compactMap(\.cariAccountId))
      let isDemo = editing?.isDemo ?? false
      cariOptions = try await repositories.cari.listAccounts(type: nil, search: nil).filter {
        $0.isActive && $0.type != .musteri && !linked.contains($0.id) && $0.isDemo == isDemo
      }
    } catch {
      errorMessage = message(for: error)
    }
  }

  public var draft: SubcontractorDraft {
    SubcontractorDraft(name: name.trimmingCharacters(in: .whitespaces), trade: trade, cariAccountId: cariAccountId,
                       contactName: contactName.nilIfBlank, phone: phone.nilIfBlank,
                       email: email.nilIfBlank?.lowercased(), notes: notes.nilIfBlank, isActive: isActive)
  }

  public var validationMessage: String? {
    let draft = draft
    if draft.name.isEmpty { return "Taşeron adı veya unvanı zorunlu." }
    if let email = draft.email, !Validation.isValidEmail(email) { return "E-posta adresi geçersiz." }
    if let phone = draft.phone, !isValidPhone(phone) { return "Telefon numarası geçersiz." }
    return nil
  }

  public var canSave: Bool { validationMessage == nil && !isSaving }

  public func save() async -> Subcontractor? {
    if let validationMessage {
      errorMessage = validationMessage
      return nil
    }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      if let editing {
        return try await repositories.workforce.updateSubcontractor(id: editing.id, expectedVersion: editing.version,
                                                                    with: draft)
      }
      return try await repositories.workforce.createSubcontractor(draft)
    } catch {
      errorMessage = message(for: error)
      return nil
    }
  }
}

// MARK: - Personel

/// Personel formu. Zorunlu alan yalnızca ad soyad; taşeron personelinde taşeron.
/// TCKN, banka ve adres bilgisi bilerek yoktur.
@MainActor
@Observable
public final class PersonnelFormViewModel {
  public var fullName: String
  public var phone: String
  public var jobTitle: String
  public var trade: WorkTrade?
  public var employmentType: EmploymentType
  public var subcontractorId: UUID?
  public var notes: String
  public var isActive: Bool

  public private(set) var subcontractorOptions: [Subcontractor] = []
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?

  public let editing: Personnel?
  private let initialPhone: String
  private let repository: WorkforceRepository

  public init(editing: Personnel? = nil, phone: String? = nil, repository: WorkforceRepository,
              preselectedSubcontractor: UUID? = nil) {
    self.editing = editing
    self.repository = repository
    initialPhone = phone ?? ""
    self.phone = phone ?? ""
    let draft = editing.map(PersonnelDraft.init)
      ?? PersonnelDraft(employmentType: preselectedSubcontractor == nil ? .sirket : .taseron,
                        subcontractorId: preselectedSubcontractor)
    fullName = draft.fullName
    jobTitle = draft.jobTitle ?? ""
    trade = draft.trade
    employmentType = draft.employmentType
    subcontractorId = draft.subcontractorId
    notes = draft.notes ?? ""
    isActive = draft.isActive
  }

  public var formTitle: String { editing == nil ? "Yeni personel" : "Personeli düzenle" }

  public func loadOptions() async {
    do {
      let isDemo = editing?.isDemo ?? false
      subcontractorOptions = try await repository.subcontractors().filter {
        ($0.isActive || $0.id == subcontractorId) && $0.isDemo == isDemo
      }
    } catch {
      errorMessage = message(for: error)
    }
  }

  public var draft: PersonnelDraft {
    PersonnelDraft(fullName: fullName.trimmingCharacters(in: .whitespaces), jobTitle: jobTitle.nilIfBlank, trade: trade,
                   employmentType: employmentType,
                   subcontractorId: employmentType == .taseron ? subcontractorId : nil,
                   notes: notes.nilIfBlank, isActive: isActive)
  }

  public var validationMessage: String? {
    let draft = draft
    if draft.fullName.isEmpty { return "Ad soyad zorunlu." }
    if let problem = WorkforceRules.employmentProblem(type: draft.employmentType, subcontractorId: draft.subcontractorId) {
      return problem
    }
    if let phone = phone.nilIfBlank, !isValidPhone(phone) { return "Telefon numarası geçersiz." }
    return nil
  }

  public var canSave: Bool { validationMessage == nil && !isSaving }

  /// Kartı kaydeder; telefon değiştiyse ayrı (izinli) iletişim kaydına yazar.
  public func save() async -> Personnel? {
    if let validationMessage {
      errorMessage = validationMessage
      return nil
    }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      let saved: Personnel = if let editing {
        try await repository.updatePersonnel(id: editing.id, expectedVersion: editing.version, with: draft)
      } else {
        try await repository.createPersonnel(draft)
      }
      if phone.nilIfBlank != initialPhone.nilIfBlank {
        try await repository.setPhone(phone.nilIfBlank, personnelId: saved.id)
      }
      return saved
    } catch {
      errorMessage = message(for: error)
      return nil
    }
  }
}

// MARK: - Ekip

/// Ekip formu: ad, bağlı olduğu taşeron (boşsa şirket), iş kolu ve sorumlu.
@MainActor
@Observable
public final class CrewFormViewModel {
  public var name: String
  public var subcontractorId: UUID? {
    didSet { if let leaderId, !leaderOptions.contains(where: { $0.id == leaderId }) { self.leaderId = nil } }
  }
  public var trade: WorkTrade?
  public var leaderId: UUID?
  public var notes: String
  public var isActive: Bool

  public private(set) var subcontractorOptions: [Subcontractor] = []
  public private(set) var personnelOptions: [Personnel] = []
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?

  public let editing: Crew?
  private let repository: WorkforceRepository

  public init(editing: Crew? = nil, repository: WorkforceRepository, preselectedSubcontractor: UUID? = nil) {
    self.editing = editing
    self.repository = repository
    let draft = editing.map(CrewDraft.init) ?? CrewDraft(subcontractorId: preselectedSubcontractor)
    name = draft.name
    subcontractorId = draft.subcontractorId
    trade = draft.trade
    leaderId = draft.leaderId
    notes = draft.notes ?? ""
    isActive = draft.isActive
  }

  public var formTitle: String { editing == nil ? "Yeni ekip" : "Ekibi düzenle" }

  /// Sorumlu yalnızca ekibin sahibine (taşeron ya da şirket) bağlı etkin personelden seçilir.
  public var leaderOptions: [Personnel] {
    personnelOptions.filter { $0.subcontractorId == subcontractorId && ($0.isActive || $0.id == leaderId) }
  }

  public func loadOptions() async {
    do {
      let isDemo = editing?.isDemo ?? false
      async let subs = repository.subcontractors()
      async let people = repository.personnel()
      subcontractorOptions = try await subs.filter { ($0.isActive || $0.id == subcontractorId) && $0.isDemo == isDemo }
      personnelOptions = try await people.filter { $0.isDemo == isDemo }
    } catch {
      errorMessage = message(for: error)
    }
  }

  public var draft: CrewDraft {
    CrewDraft(name: name.trimmingCharacters(in: .whitespaces), subcontractorId: subcontractorId, trade: trade,
              leaderId: leaderId, notes: notes.nilIfBlank, isActive: isActive)
  }

  public var validationMessage: String? {
    if draft.name.isEmpty { return "Ekip adı zorunlu." }
    return nil
  }

  public var canSave: Bool { validationMessage == nil && !isSaving }

  public func save() async -> Crew? {
    if let validationMessage {
      errorMessage = validationMessage
      return nil
    }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      if let editing {
        return try await repository.updateCrew(id: editing.id, expectedVersion: editing.version, with: draft)
      }
      return try await repository.createCrew(draft)
    } catch {
      errorMessage = message(for: error)
      return nil
    }
  }
}
