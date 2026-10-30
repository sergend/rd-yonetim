import Foundation
import Observation

/// Cari listesi. Bakiyeler yalnızca hareket okuma izni olan kullanıcıya
/// gösterilir; izni olmayan kullanıcı yalnızca kartları görür.
@MainActor
@Observable
public final class CariListViewModel {
  public private(set) var accounts: [CariAccount] = []
  public private(set) var balances: [UUID: CariBalance] = [:]
  public var typeFilter: CariType?
  public var searchText = ""
  public var filter = CariFilter()
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let access: AccessControl
  private let repository: CariRepository

  public init(access: AccessControl, repository: CariRepository) {
    self.access = access
    self.repository = repository
  }

  public var canCreate: Bool { access.canAnywhere(.cariWrite) }
  public var canSeeBalances: Bool { access.canAnywhere(.cariHareketRead) }

  public var filtered: [CariAccount] {
    guard let query = searchText.nilIfBlank?.lowercased(with: Money.locale) else { return accounts }
    return accounts.filter {
      $0.title.lowercased(with: Money.locale).contains(query) || $0.code.lowercased(with: Money.locale).contains(query)
    }
  }

  public func balance(for account: CariAccount) -> CariBalance? { balances[account.id] }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      accounts = try await repository.listAccounts(type: typeFilter, search: nil)
      if canSeeBalances {
        let rows = try await repository.balances(filter: filter)
        balances = Dictionary(uniqueKeysWithValues: rows.map { ($0.cariAccountId, $0) })
      } else {
        balances = [:]
      }
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func upsert(_ account: CariAccount) {
    if let index = accounts.firstIndex(where: { $0.id == account.id }) {
      accounts[index] = account
    } else {
      accounts.append(account)
      accounts.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
    }
  }
}

/// Cari kart oluşturma/düzenleme. Bakiye alanı yoktur.
@MainActor
@Observable
public final class CariFormViewModel {
  public var code: String
  public var title: String
  public var type: CariType
  public var taxNumber: String
  public var taxOffice: String
  public var phone: String
  public var email: String
  public var address: String
  public var iban: String
  public var notes: String
  public var isActive: Bool

  public private(set) var isSaving = false
  public private(set) var errorMessage: String?

  public let editing: CariAccount?
  private let repository: CariRepository

  public init(editing: CariAccount? = nil, repository: CariRepository) {
    self.editing = editing
    self.repository = repository
    let draft = editing.map(CariAccountDraft.init) ?? CariAccountDraft()
    code = draft.code ?? ""
    title = draft.title
    type = draft.type
    taxNumber = draft.taxNumber ?? ""
    taxOffice = draft.taxOffice ?? ""
    phone = draft.phone ?? ""
    email = draft.email ?? ""
    address = draft.address ?? ""
    iban = draft.iban ?? ""
    notes = draft.notes ?? ""
    isActive = draft.isActive
  }

  public var formTitle: String { editing == nil ? "Yeni cari" : "Cariyi düzenle" }

  public var draft: CariAccountDraft {
    CariAccountDraft(code: code.nilIfBlank?.uppercased(), title: title.trimmingCharacters(in: .whitespaces),
                     type: type, taxNumber: Validation.normalizedTaxNumber(taxNumber),
                     taxOffice: taxOffice.nilIfBlank, phone: phone.nilIfBlank,
                     email: email.nilIfBlank?.lowercased(), address: address.nilIfBlank,
                     iban: Validation.normalizedIBAN(iban), notes: notes.nilIfBlank, isActive: isActive)
  }

  public var validationMessage: String? {
    let draft = draft
    if draft.title.isEmpty { return "Cari unvanı zorunlu." }
    if let tax = draft.taxNumber, !Validation.isValidTaxNumber(tax) {
      return "Vergi numarası 10 haneli VKN veya 11 haneli TCKN olmalı."
    }
    if let iban = draft.iban, !Validation.isValidIBAN(iban) { return "IBAN geçersiz." }
    if let email = draft.email, !Validation.isValidEmail(email) { return "E-posta adresi geçersiz." }
    return nil
  }

  public var canSave: Bool { validationMessage == nil && !isSaving }

  public func save() async -> CariAccount? {
    if let validationMessage {
      errorMessage = validationMessage
      return nil
    }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      if let editing {
        return try await repository.updateAccount(id: editing.id, expectedVersion: editing.version, with: draft)
      }
      return try await repository.createAccount(draft)
    } catch {
      errorMessage = message(for: error)
      return nil
    }
  }
}

/// Cari detay: kart bilgisi ve filtreli ekstre (hareket geçmişi).
@MainActor
@Observable
public final class CariDetailViewModel {
  public private(set) var account: CariAccount
  public private(set) var lines: [CariStatementLine] = []
  public var filter = CariFilter()
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let access: AccessControl
  private let repository: CariRepository

  public init(account: CariAccount, access: AccessControl, repository: CariRepository) {
    self.account = account
    self.access = access
    self.repository = repository
  }

  public var canEditAccount: Bool { access.canAnywhere(.cariWrite) }
  public var canSeeEntries: Bool { access.canAnywhere(.cariHareketRead) }
  public var canPostEntries: Bool { access.canAnywhere(.cariHareketWrite) }

  public func canReverse(_ line: CariStatementLine) -> Bool {
    guard line.isReversible else { return false }
    if let project = line.projectId { return access.can(.cariHareketReverse, in: project) }
    return access.can(.cariHareketReverse)
  }

  /// Ekstre özeti: dönem başı devir, dönem hareketleri ve dönem sonu bakiye.
  public struct Summary: Equatable, Sendable {
    public let opening: Decimal
    public let periodBorc: Decimal
    public let periodAlacak: Decimal
    public var closing: Decimal { opening + periodBorc - periodAlacak }
    public var side: BalanceSide { BalanceSide(closing) }
  }

  public var summary: Summary {
    let borc = lines.reduce(Decimal.zero) { $0 + $1.borcTry }
    let alacak = lines.reduce(Decimal.zero) { $0 + $1.alacakTry }
    let opening = lines.first.map { $0.runningBalanceTry - $0.borcTry + $0.alacakTry } ?? 0
    return Summary(opening: opening, periodBorc: borc, periodAlacak: alacak)
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      account = try await repository.getAccount(id: account.id)
      lines = canSeeEntries ? try await repository.statement(accountId: account.id, filter: filter) : []
    } catch {
      errorMessage = message(for: error)
    }
  }

  public func didSave(_ account: CariAccount) { self.account = account }

  /// Hareketi ters kayıtla iptal eder. `reversalId` tekrar denemede aynı kalmalıdır.
  public func reverse(_ line: CariStatementLine, reason: String, reversalId: UUID = UUID()) async -> Bool {
    guard let reason = reason.nilIfBlank else {
      errorMessage = "İptal gerekçesi zorunlu."
      return false
    }
    do {
      try await repository.reverse(entryId: line.id, reason: reason, reversalId: reversalId)
      await load()
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }
}

/// Elle cari hareket girişi (ödeme, avans, tahsilat, açılış, manuel).
@MainActor
@Observable
public final class CariEntryFormViewModel {
  public enum ScopeChoice: Hashable { case project, costCenter }

  public var kind: CariEntryKind = .odeme {
    didSet { if let fixed = kind.fixedDirection { direction = fixed } }
  }
  public var direction: CariDirection = .borc
  public var amountText = ""
  public var date = Date()
  public var scopeChoice: ScopeChoice
  public var projectId: UUID?
  public var costCenterId: UUID?
  public var descriptionText = ""
  public var documentNo = ""

  public private(set) var isSaving = false
  public private(set) var errorMessage: String?

  public let account: CariAccount
  public let projects: [Project]
  public let costCenters: [CostCenter]
  /// Tekrar gönderimde aynı kimlik kullanılır; sunucu ikinci kaydı açmaz.
  public let entryId = UUID()

  private let repository: CariRepository

  public init(account: CariAccount, access: AccessControl, projects: [Project], costCenters: [CostCenter],
              preselectedProject: UUID? = nil, preselectedCostCenter: UUID? = nil, repository: CariRepository) {
    self.account = account
    self.repository = repository
    // Demo cari yalnızca demo projelere, gerçek cari gerçek projelere işlenir.
    self.projects = projects.filter { access.can(.cariHareketWrite, in: $0.id) && $0.isDemo == account.isDemo }
    self.costCenters = access.can(.cariHareketWrite)
      ? costCenters.filter { $0.isActive && $0.isDemo == account.isDemo } : []
    if let preselectedCostCenter, self.costCenters.contains(where: { $0.id == preselectedCostCenter }) {
      scopeChoice = .costCenter
      costCenterId = preselectedCostCenter
    } else {
      scopeChoice = self.projects.isEmpty && !self.costCenters.isEmpty ? .costCenter : .project
      projectId = preselectedProject.flatMap { id in self.projects.first { $0.id == id }?.id } ?? self.projects.first?.id
      costCenterId = self.costCenters.first?.id
    }
  }

  public var isDirectionFixed: Bool { kind.fixedDirection != nil }
  public var amount: Decimal? { Money.parse(amountText) }

  public var scope: CariEntryDraft.Scope? {
    switch scopeChoice {
    case .project: projectId.map(CariEntryDraft.Scope.project)
    case .costCenter: costCenterId.map(CariEntryDraft.Scope.costCenter)
    }
  }

  public var validationMessage: String? {
    guard let amount, amount > 0 else { return "Geçerli bir tutar girin (en fazla 2 ondalık)." }
    if amount >= 1_000_000_000_000 { return "Tutar çok büyük." }
    if scope == nil { return "Proje veya genel gider merkezi seçin." }
    if descriptionText.nilIfBlank == nil { return "Açıklama zorunlu." }
    if CalendarDate(date) > .today() { return "İleri tarihli hareket girilemez." }
    return nil
  }

  public var canSave: Bool { validationMessage == nil && !isSaving }

  public var draft: CariEntryDraft? {
    guard let amount, let scope, let description = descriptionText.nilIfBlank else { return nil }
    return CariEntryDraft(id: entryId, cariAccountId: account.id, scope: scope, entryDate: CalendarDate(date),
                          direction: kind.fixedDirection ?? direction, kind: kind, amount: amount,
                          description: description, documentNo: documentNo.nilIfBlank)
  }

  public func save() async -> Bool {
    if let validationMessage {
      errorMessage = validationMessage
      return false
    }
    guard let draft else { return false }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      try await repository.post(draft)
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }
}

/// Projeye bağlı olmayan şirket genel giderleri: masraf merkezleri ve
/// her merkezdeki cari bakiyeler.
@MainActor
@Observable
public final class GeneralExpensesViewModel {
  public private(set) var costCenters: [CostCenter] = []
  public private(set) var accounts: [UUID: CariAccount] = [:]
  public private(set) var balancesByCenter: [UUID: [CariBalance]] = [:]
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?

  private let repositories: Repositories

  public init(repositories: Repositories) {
    self.repositories = repositories
  }

  public func balances(for center: CostCenter) -> [CariBalance] { balancesByCenter[center.id] ?? [] }

  /// Merkezdeki toplam alacak (bu merkeze yazılan gider/borçlanma).
  public func totalAlacak(for center: CostCenter) -> Decimal {
    balances(for: center).reduce(Decimal.zero) { $0 + $1.totalAlacakTry }
  }

  public func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      costCenters = try await repositories.costCenters.list()
      let list = try await repositories.cari.listAccounts(type: nil, search: nil)
      accounts = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
      var result: [UUID: [CariBalance]] = [:]
      for center in costCenters {
        result[center.id] = try await repositories.cari.balances(filter: CariFilter(costCenterId: center.id))
      }
      balancesByCenter = result
    } catch {
      errorMessage = message(for: error)
    }
  }
}
