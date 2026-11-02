import Foundation
import Observation

/// Ana sayfa özeti: seçili ayın gider maliyeti (kategori dağılımıyla), bekleyen
/// ödemeler, açık hakedişler ve proje maliyetleri. Kasa veya banka bakiyesi
/// hesaplanmaz; tutarlar tahakkuk (onaylı belge) ve kalan borçtur.
/// Her bölüm kendi iznine bağlıdır; izin yoksa veya veri alınamazsa o bölüm boş kalır.
@MainActor
@Observable
public final class HomeDashboardViewModel {
  public struct CategoryCost: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let amount: Decimal

    public init(id: String, label: String, amount: Decimal) {
      self.id = id
      self.label = label
      self.amount = amount
    }
  }

  public struct UpcomingPayment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let projectId: UUID?
    public let dueDate: CalendarDate
    public let remaining: Decimal
    public let isOverdue: Bool
    public let daysOverdue: Int
    public let state: FinanceSettlementState

    public init(id: UUID, title: String, projectId: UUID?, dueDate: CalendarDate, remaining: Decimal,
                isOverdue: Bool, daysOverdue: Int, state: FinanceSettlementState) {
      self.id = id
      self.title = title
      self.projectId = projectId
      self.dueDate = dueDate
      self.remaining = remaining
      self.isOverdue = isOverdue
      self.daysOverdue = daysOverdue
      self.state = state
    }
  }

  public struct PendingSummary: Equatable, Sendable {
    public let total: Decimal
    public let count: Int
    public let overdueCount: Int

    public init(total: Decimal, count: Int, overdueCount: Int) {
      self.total = total
      self.count = count
      self.overdueCount = overdueCount
    }
  }

  public private(set) var month: PuantajMonth
  public private(set) var monthCost: Decimal?
  public private(set) var previousMonthCost: Decimal?
  public private(set) var categories: [CategoryCost] = []
  public private(set) var pending: PendingSummary?
  public private(set) var upcoming: [UpcomingPayment] = []
  public private(set) var openHakedisCount: Int?
  public private(set) var openHakedisTotal: Decimal = 0
  public private(set) var projectCosts: [UUID: ProjectCostRow] = [:]
  public private(set) var isLoading = false

  private let access: AccessControl
  private let repositories: Repositories
  private let today: CalendarDate
  private let upcomingLimit: Int

  public init(access: AccessControl, repositories: Repositories, today: CalendarDate = .today(), upcomingLimit: Int = 3) {
    self.access = access
    self.repositories = repositories
    self.today = today
    self.upcomingLimit = upcomingLimit
    self.month = PuantajMonth(containing: today)
  }

  public var canSeeExpenses: Bool { access.canAnywhere(.giderRead) }
  public var canSeeHakedis: Bool { access.canAnywhere(.hakedisRead) }
  public var isCurrentMonth: Bool { month == PuantajMonth(containing: today) }

  /// Önceki aya göre değişim yüzdesi (önceki ay 0 ise nil).
  public var changePercent: Int? { Self.changePercent(current: monthCost, previous: previousMonthCost) }

  public func showPreviousMonth() async {
    month = month.previous
    await loadCosts()
  }

  public func showNextMonth() async {
    guard !isCurrentMonth else { return }
    month = month.next
    await loadCosts()
  }

  public func load() async {
    isLoading = true
    defer { isLoading = false }
    await loadCosts()
    await loadPayables()
    await loadHakedis()
    await loadProjectCosts()
  }

  private func loadCosts() async {
    guard canSeeExpenses else { return }
    let finance = repositories.finance
    let month = self.month
    let rows = try? await finance.report(kind: .gider, group: .kategori, from: month.firstDay, to: month.lastDay,
                                         projectId: nil, costCenterId: nil)
    let previous = try? await finance.report(kind: .gider, group: .kategori, from: month.previous.firstDay,
                                             to: month.previous.lastDay, projectId: nil, costCenterId: nil)
    guard month == self.month else { return }  // bu arada ay değiştiyse eski sonucu yazma
    categories = Self.categories(from: rows ?? [])
    monthCost = rows.map { $0.reduce(Decimal(0)) { $0 + $1.accruedTry } }
    previousMonthCost = previous.map { $0.reduce(Decimal(0)) { $0 + $1.accruedTry } }
  }

  private func loadPayables() async {
    guard canSeeExpenses, let statuses = try? await repositories.finance.openStatuses(kind: .gider) else { return }
    pending = Self.pendingSummary(statuses)
    let next = Self.upcomingStatuses(statuses, limit: upcomingLimit)
    let documents = next.isEmpty ? [] : ((try? await repositories.finance.documents(ids: next.map(\.documentId))) ?? [])
    let byId = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
    upcoming = next.map { status in
      let document = byId[status.documentId]
      return UpcomingPayment(id: status.documentId, title: document?.description ?? document?.documentNo ?? "Gider",
                             projectId: document?.projectId, dueDate: status.dueDate, remaining: status.remainingTry,
                             isOverdue: status.isOverdue, daysOverdue: status.daysOverdue,
                             state: status.settlementState)
    }
  }

  private func loadHakedis() async {
    guard canSeeHakedis, let list = try? await repositories.contracts.hakedisList(contractId: nil) else { return }
    let open = list.filter { $0.status.isOpen }
    openHakedisCount = open.count
    openHakedisTotal = open.reduce(Decimal(0)) { $0 + $1.payableAmount }
  }

  private func loadProjectCosts() async {
    guard canSeeExpenses, let rows = try? await repositories.finance.projectCosts(projectId: nil) else { return }
    projectCosts = Dictionary(rows.map { ($0.projectId, $0) }, uniquingKeysWith: { first, _ in first })
  }

  // MARK: Hesaplar (test edilebilir)

  /// Tutarı olan kategoriler, büyükten küçüğe.
  public static func categories(from rows: [FinanceReportRow]) -> [CategoryCost] {
    rows.filter { $0.accruedTry != 0 }
      .sorted { $0.accruedTry > $1.accruedTry }
      .map { CategoryCost(id: $0.groupKey, label: $0.label, amount: $0.accruedTry) }
  }

  public static func pendingSummary(_ statuses: [FinanceDocumentStatus]) -> PendingSummary {
    let open = statuses.filter { $0.settlementState.isOpen && $0.remainingTry > 0 }
    return PendingSummary(total: open.reduce(Decimal(0)) { $0 + $1.remainingTry }, count: open.count,
                          overdueCount: open.filter(\.isOverdue).count)
  }

  /// Önce gecikenler (en çok geciken başta), sonra vadesi en yakın olanlar.
  public static func upcomingStatuses(_ statuses: [FinanceDocumentStatus], limit: Int) -> [FinanceDocumentStatus] {
    Array(statuses.filter { $0.settlementState.isOpen && $0.remainingTry > 0 }
      .sorted { lhs, rhs in
        if lhs.isOverdue != rhs.isOverdue { return lhs.isOverdue }
        if lhs.dueDate != rhs.dueDate { return lhs.dueDate < rhs.dueDate }
        return lhs.remainingTry > rhs.remainingTry
      }
      .prefix(limit))
  }

  public static func changePercent(current: Decimal?, previous: Decimal?) -> Int? {
    guard let current, let previous, previous != 0 else { return nil }
    let ratio = ((current - previous) / previous * 100) as NSDecimalNumber
    return Int(ratio.doubleValue.rounded())
  }
}
