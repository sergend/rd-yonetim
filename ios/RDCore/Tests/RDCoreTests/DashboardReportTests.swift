import Foundation
import XCTest
@testable import RDCore

private func day(_ month: Int, _ day: Int) -> CalendarDate { CalendarDate(year: 2026, month: month, day: day) }

private func status(due: CalendarDate, remaining: Decimal, state: FinanceSettlementState = .acik,
                    overdue: Bool = false, days: Int = 0) -> FinanceDocumentStatus {
  FinanceDocumentStatus(documentId: UUID(), kind: .gider, status: .onaylandi, amount: remaining, currency: "TRY",
                        settledAmount: 0, settledTry: 0, remainingAmount: remaining, remainingTry: remaining,
                        settlementState: state, dueDate: due, isOverdue: overdue, daysOverdue: days)
}

final class HomeDashboardMathTests: XCTestCase {
  func testCategoriesSortedAndEmptyOnesDropped() {
    let rows = [
      FinanceReportRow(groupKey: "a", label: "Genel gider", documentCount: 2, accruedTry: 115_600, settledTry: 0,
                       openTry: 0, overdueTry: 0),
      FinanceReportRow(groupKey: "b", label: "Malzeme", documentCount: 5, accruedTry: 398_200, settledTry: 0,
                       openTry: 0, overdueTry: 0),
      FinanceReportRow(groupKey: "c", label: "Boş", documentCount: 0, accruedTry: 0, settledTry: 0,
                       openTry: 0, overdueTry: 0),
    ]
    let categories = HomeDashboardViewModel.categories(from: rows)
    XCTAssertEqual(categories.map(\.label), ["Malzeme", "Genel gider"])
  }

  func testPendingSummaryCountsOnlyOpenRemaining() {
    let statuses = [
      status(due: day(10, 28), remaining: 96_400, overdue: true, days: 5),
      status(due: day(11, 5), remaining: 50_000, state: .kismi),
      status(due: day(11, 10), remaining: 0, state: .kapandi),
    ]
    let summary = HomeDashboardViewModel.pendingSummary(statuses)
    XCTAssertEqual(summary, .init(total: 146_400, count: 2, overdueCount: 1))
  }

  func testUpcomingPutsOverdueFirstThenNearestDue() {
    let late = status(due: day(10, 28), remaining: 10, overdue: true, days: 5)
    let soon = status(due: day(11, 5), remaining: 20)
    let later = status(due: day(11, 10), remaining: 30)
    let result = HomeDashboardViewModel.upcomingStatuses([later, soon, late], limit: 2)
    XCTAssertEqual(result.map(\.documentId), [late.documentId, soon.documentId])
  }

  func testChangePercent() {
    XCTAssertEqual(HomeDashboardViewModel.changePercent(current: 108, previous: 100), 8)
    XCTAssertEqual(HomeDashboardViewModel.changePercent(current: 90, previous: 100), -10)
    XCTAssertNil(HomeDashboardViewModel.changePercent(current: 90, previous: 0))
    XCTAssertNil(HomeDashboardViewModel.changePercent(current: nil, previous: 100))
  }
}

final class HakedisMonthReportTests: XCTestCase {
  private let mehmet = UUID()
  private let ali = UUID()

  private func hakedis() -> Hakedis {
    Hakedis(contractId: UUID(), versionId: UUID(), projectId: UUID(), subcontractorId: UUID(), cariAccountId: UUID(),
            hakedisNo: 7, periodStart: day(10, 1), periodEnd: day(10, 31), grossAmount: 87_300,
            advanceAmount: 40_000, payableAmount: 47_300)
  }

  private func link(_ h: Hakedis, _ person: UUID, _ name: String, _ date: CalendarDate, _ status: PuantajStatus,
                    _ delta: Decimal, revision: Int = 0, correction: Bool = false) -> HakedisPuantajLink {
    HakedisPuantajLink(hakedisId: h.id, personnelId: person, personnelName: name, workDate: date, status: status,
                       payBasis: "calisilan_gun", dayDelta: delta, periodRevision: revision, isCorrection: correction)
  }

  func testCalendarStartsOnMondayAndFillsWeeks() {
    // 1 Ekim 2026 Perşembe: önünde 3 boş hücre, toplam 35 hücre.
    let cells = HakedisMonthReport.calendarCells(for: PuantajMonth(year: 2026, month: 10))
    XCTAssertEqual(cells.count, 35)
    XCTAssertEqual(cells.prefix(3).map(\.date), [nil, nil, nil])
    XCTAssertEqual(cells[3].date, day(10, 1))
    XCTAssertEqual(cells[33].date, day(10, 31))
    XCTAssertNil(cells[34].date)
  }

  func testPeopleDaysAndAmountsFromLinksAndDailyPrices() {
    let h = hakedis()
    let items = [
      ContractItem(versionId: h.versionId, contractId: h.contractId, lineNo: 1, method: .gunluk, description: "Usta",
                   unit: "adam_gun", unitPrice: 1_800, personnelId: mehmet),
      ContractItem(versionId: h.versionId, contractId: h.contractId, lineNo: 2, method: .gunluk, description: "Usta 2",
                   unit: "adam_gun", unitPrice: 1_500, personnelId: ali),
    ]
    let links = [
      link(h, mehmet, "Mehmet Kaya", day(10, 1), .tamGun, 1),
      link(h, mehmet, "Mehmet Kaya", day(10, 2), .yarimGun, Decimal(string: "0.5")!),
      link(h, ali, "Ali Demir", day(10, 1), .tamGun, 1),
      link(h, ali, "Ali Demir", day(10, 2), .calismadi, 0),
      // Düzeltme: 1 Ekim tam günden yarım güne indi (net 0,5).
      link(h, ali, "Ali Demir", day(10, 1), .yarimGun, Decimal(string: "-0.5")!, revision: 1, correction: true),
    ]
    let report = HakedisMonthReport(hakedis: h, links: links, items: items)
    XCTAssertEqual(report.people.map(\.name), ["Ali Demir", "Mehmet Kaya"])

    let aliRow = report.people[0]
    XCTAssertEqual(aliRow.day(day(10, 1))?.status, .yarimGun, "son revizyondaki durum gösterilir")
    XCTAssertEqual(aliRow.dayTotal, Decimal(string: "0.5"))
    XCTAssertEqual(aliRow.absentDays, 1)
    XCTAssertEqual(aliRow.amount, 750)

    let mehmetRow = report.people[1]
    XCTAssertEqual(mehmetRow.fullDays, 1)
    XCTAssertEqual(mehmetRow.halfDays, 1)
    XCTAssertEqual(mehmetRow.dayTotal, Decimal(string: "1.5"))
    XCTAssertEqual(mehmetRow.amount, 2_700)
    XCTAssertEqual(mehmetRow.initials, "MK")

    XCTAssertEqual(report.totalDays, 2)
    XCTAssertEqual(report.peopleAmountTotal, 3_450)
    XCTAssertEqual(report.months, [PuantajMonth(year: 2026, month: 10)])
  }

  func testSharedDailyPriceIsUsedWhenPersonHasNoOwnItem() {
    let h = hakedis()
    let items = [ContractItem(versionId: h.versionId, contractId: h.contractId, lineNo: 1, method: .gunluk,
                              description: "Düz işçi", unit: "adam_gun", unitPrice: 1_100)]
    let report = HakedisMonthReport(hakedis: h, links: [link(h, mehmet, "Mehmet Kaya", day(10, 1), .tamGun, 1)],
                                    items: items)
    XCTAssertEqual(report.people.first?.amount, 1_100)
  }

  func testUnknownPriceLeavesAmountEmpty() {
    let h = hakedis()
    let report = HakedisMonthReport(hakedis: h, links: [link(h, mehmet, "Mehmet Kaya", day(10, 1), .tamGun, 1)],
                                    items: [])
    XCTAssertNil(report.people.first?.amount)
    XCTAssertEqual(report.peopleAmountTotal, 0)
  }

  func testPeriodAcrossMonthsListsEachMonth() {
    XCTAssertEqual(HakedisMonthReport.months(from: day(10, 15), to: day(11, 14)),
                   [PuantajMonth(year: 2026, month: 10), PuantajMonth(year: 2026, month: 11)])
  }
}
