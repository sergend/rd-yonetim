import Foundation
import XCTest
@testable import RDCore

final class ModelTests: XCTestCase {
  func testCalendarDateRoundTripsAsPlainDay() throws {
    let date = CalendarDate(year: 2026, month: 10, day: 5)
    let data = try JSONEncoder().encode([date])
    XCTAssertEqual(String(data: data, encoding: .utf8), #"["2026-10-05"]"#)
    XCTAssertEqual(try JSONDecoder().decode([CalendarDate].self, from: data), [date])
    XCTAssertNil(CalendarDate(iso: "2026-13-01"))
  }

  func testCalendarDateUsesIstanbulDay() {
    // 2026-10-04 22:30 UTC = 2026-10-05 01:30 İstanbul
    let instant = Date(timeIntervalSince1970: 1_791_153_000)
    XCTAssertEqual(CalendarDate(instant), CalendarDate(year: 2026, month: 10, day: 5))
  }

  func testStatementLineDecodesServerPayload() throws {
    let json = """
      [{"id":"00000000-0000-4000-8000-0000000000d2","entry_date":"2026-10-10","kind":"odeme","direction":"borc",
        "description":"Kısmi ödeme","document_no":null,"project_id":"00000000-0000-4000-8000-000000000010",
        "cost_center_id":null,"amount":200000.00,"currency":"TRY","amount_try":200000.00,"borc_try":200000.00,
        "alacak_try":0,"running_balance_try":-250000.10,"reversal_of_id":null,"is_reversed":false,
        "created_at":"2026-10-30T19:16:03.676303+00:00"}]
      """
    let lines = try JSONDecoder().decode([CariStatementLine].self, from: Data(json.utf8))
    XCTAssertEqual(lines.first?.runningBalanceTry, Decimal(string: "-250000.10"))
    XCTAssertEqual(lines.first?.kind, .odeme)
    XCTAssertTrue(lines.first?.isReversible ?? false)
  }

  func testSourceAndReversalLinesAreNotReversible() {
    let hakedis = CariStatementLine(entryDate: .today(), kind: .hakedis, direction: .alacak, description: "x",
                                    amount: 1, borcTry: 0, alacakTry: 1, runningBalanceTry: -1)
    let reversed = CariStatementLine(entryDate: .today(), kind: .odeme, direction: .borc, description: "x",
                                     amount: 1, borcTry: 1, alacakTry: 0, runningBalanceTry: 0, isReversed: true)
    let reversal = CariStatementLine(entryDate: .today(), kind: .tersKayit, direction: .alacak, description: "x",
                                     amount: 1, borcTry: 0, alacakTry: 1, runningBalanceTry: 0)
    XCTAssertFalse(hakedis.isReversible)
    XCTAssertFalse(reversed.isReversible)
    XCTAssertFalse(reversal.isReversible)
  }

  func testBalanceIsComputedNotStored() {
    let balance = CariBalance(cariAccountId: UUID(), totalBorcTry: 40_000, totalAlacakTry: 100_000)
    XCTAssertEqual(balance.balanceTry, -60_000)
    XCTAssertEqual(balance.side, .weOwe)
    XCTAssertEqual(BalanceSide(0), .settled)
    XCTAssertEqual(BalanceSide(5), .theyOwe)
  }

  func testKindFixesDirectionLikeDatabase() {
    XCTAssertEqual(CariEntryKind.odeme.fixedDirection, .borc)
    XCTAssertEqual(CariEntryKind.avans.fixedDirection, .borc)
    XCTAssertEqual(CariEntryKind.tahsilat.fixedDirection, .alacak)
    XCTAssertNil(CariEntryKind.manuel.fixedDirection)
    XCTAssertFalse(CariEntryKind.manualKinds.contains(.hakedis))
    XCTAssertFalse(CariEntryKind.manualKinds.contains(.tersKayit))
  }

  func testDraftEncodesClearedFieldsAsNull() throws {
    let draft = ProjectDraft(code: "P1", name: "Proje", city: nil)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any]
    XCTAssertTrue(object?["city"] is NSNull)
    let cari = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CariAccountDraft(title: "x"))) as? [String: Any]
    XCTAssertNil(cari?["code"], "kod boşsa gönderilmez; sunucu üretir")
    XCTAssertNil(cari?["balance"], "bakiye alanı gönderilmez")
  }
}

final class ValidationTests: XCTestCase {
  func testTaxNumber() {
    XCTAssertTrue(Validation.isValidTaxNumber("1234567890"))
    XCTAssertTrue(Validation.isValidTaxNumber("12345678901"))
    XCTAssertFalse(Validation.isValidTaxNumber("123456789"))
    XCTAssertFalse(Validation.isValidTaxNumber("12345A7890"))
    XCTAssertEqual(Validation.normalizedTaxNumber(" 123 456 7890 "), "1234567890")
  }

  func testIBAN() {
    // ISO 13616 örnek numarası (gerçek hesap değildir).
    XCTAssertTrue(Validation.isValidIBAN("TR330006100519786457841326"))
    XCTAssertFalse(Validation.isValidIBAN("TR330006100519786457841327"))
    XCTAssertFalse(Validation.isValidIBAN("TR33000610051978645784132"))
    XCTAssertEqual(Validation.normalizedIBAN("tr33 0006 1005 1978 6457 8413 26"), "TR330006100519786457841326")
  }

  func testMoneyParsing() {
    XCTAssertEqual(Money.parse("1.250,50"), Decimal(string: "1250.50"))
    XCTAssertEqual(Money.parse("1250,5"), Decimal(string: "1250.5"))
    XCTAssertEqual(Money.parse("1250.5"), Decimal(string: "1250.5"))
    XCTAssertEqual(Money.parse("1.250"), 1250)
    XCTAssertEqual(Money.parse("1.250.000"), 1_250_000)
    XCTAssertEqual(Money.parse("450 000 ₺"), 450_000)
    XCTAssertNil(Money.parse("12,345"))
    XCTAssertNil(Money.parse("abc"))
    XCTAssertNil(Money.parse(""))
  }

  func testMoneyFormatting() {
    XCTAssertEqual(Money.format(1250.5), "1.250,50 ₺")
    XCTAssertEqual(Money.format(-60000), "-60.000,00 ₺")
  }
}

final class AccessTests: XCTestCase {
  let projectA = UUID()
  let projectB = UUID()

  func testProjectScopedPermissions() {
    let access = AccessControl(grants: [
      PermissionGrant(projectId: projectA, permissionKey: "proje.read"),
      PermissionGrant(projectId: projectA, permissionKey: "is.write"),
    ])
    XCTAssertTrue(access.can(.projeRead, in: projectA))
    XCTAssertFalse(access.can(.projeRead, in: projectB))
    XCTAssertFalse(access.can(.projeRead))
    XCTAssertTrue(access.canAnywhere(.isWrite))
  }

  func testGlobalPermissionAppliesToEveryProject() {
    let access = AccessControl(grants: [PermissionGrant(projectId: nil, permissionKey: "cari_hareket.read")])
    XCTAssertTrue(access.can(.cariHareketRead, in: projectB))
    XCTAssertTrue(access.can(.cariHareketRead))
  }

  func testModulesFollowPermissions() {
    let sef = AccessControl(grants: ["proje.read", "proje.write", "is.read", "is.write"].map {
      PermissionGrant(projectId: projectA, permissionKey: $0)
    })
    let visible = AppModule.allCases.filter { $0.isVisible(for: sef) }
    XCTAssertTrue(visible.contains(.projeler))
    XCTAssertTrue(visible.contains(.isTakibi))
    XCTAssertFalse(visible.contains(.cari), "şantiye şefi finans modülünü görmez")
    XCTAssertFalse(visible.contains(.genelGider))
    XCTAssertFalse(visible.contains(.kullanicilar))

    let projectFinance = AccessControl(grants: [PermissionGrant(projectId: projectA, permissionKey: "cari_hareket.read")])
    XCTAssertFalse(AppModule.genelGider.isVisible(for: projectFinance), "genel gider genel izin ister")
  }

  func testOnlyDevelopedModulesAreAvailable() {
    XCTAssertEqual(Set(AppModule.allCases.filter(\.isAvailable)),
                   [.projeler, .isTakibi, .taseronlar, .personel, .ekipler, .puantaj, .cari, .genelGider])
  }
}
