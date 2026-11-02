import Foundation

// Ay sonu hakediş raporu: taşeron özeti, her personelin aylık puantaj takvimi
// ve toplamlar. Rapor yalnızca okunur; tutarlar sunucunun hesapladığı hakediş
// alanlarından gelir. Kişi bazındaki tutar, hakedişe bağlanan puantaj günleri ile
// sözleşmedeki günlük birim fiyatın çarpımıdır (bilgi amaçlı; hakediş toplamının
// yerine geçmez, fazla mesai ayrıca gösterilir).

/// Raporda bir günün durumu.
public struct HakedisReportDay: Hashable, Sendable {
  public let date: CalendarDate
  public let status: PuantajStatus
  /// Hakedişe giren gün karşılığı (tam 1, yarım 0,5; düzeltmeler dahil net).
  public let dayValue: Decimal
  public let overtimeHours: Decimal

  public init(date: CalendarDate, status: PuantajStatus, dayValue: Decimal, overtimeHours: Decimal = 0) {
    self.date = date
    self.status = status
    self.dayValue = dayValue
    self.overtimeHours = overtimeHours
  }
}

/// Bir personelin dönem içi puantajı ve tutarı.
public struct HakedisReportPerson: Identifiable, Hashable, Sendable {
  public let personnelId: UUID
  public let name: String
  public let days: [CalendarDate: HakedisReportDay]
  /// Sözleşmedeki günlük birim fiyat (bilinmiyorsa nil).
  public let unitPrice: Decimal?

  public var id: UUID { personnelId }

  public init(personnelId: UUID, name: String, days: [CalendarDate: HakedisReportDay], unitPrice: Decimal?) {
    self.personnelId = personnelId
    self.name = name
    self.days = days
    self.unitPrice = unitPrice
  }

  public func day(_ date: CalendarDate) -> HakedisReportDay? { days[date] }

  public var fullDays: Int { days.values.filter { $0.status == .tamGun }.count }
  public var halfDays: Int { days.values.filter { $0.status == .yarimGun }.count }
  public var absentDays: Int { days.values.filter { $0.status == .calismadi || $0.status == .ucretsizIzin }.count }
  /// Ücretli izin, rapor ve resmî tatil günleri.
  public var otherDays: Int {
    days.values.filter { [.ucretliIzin, .raporlu, .resmiTatil].contains($0.status) }.count
  }
  public var dayTotal: Decimal { days.values.reduce(Decimal(0)) { $0 + $1.dayValue } }
  public var overtimeHours: Decimal { days.values.reduce(Decimal(0)) { $0 + $1.overtimeHours } }

  /// Gün toplamı × günlük birim fiyat (2 hane). Birim fiyat yoksa nil.
  public var amount: Decimal? { unitPrice.map { HakedisMath.amount(dayTotal, $0) } }

  /// Baş harfler ("Mehmet Kaya" → "MK").
  public var initials: String {
    name.split(separator: " ").prefix(2).compactMap { word in word.first.map { letter in String(letter).uppercased() } }
      .joined()
  }
}

/// Takvim hücresi: Pazartesi ile başlayan haftalarda boş hücreler `date == nil`.
public struct HakedisCalendarCell: Identifiable, Hashable, Sendable {
  public let id: Int
  public let date: CalendarDate?

  public init(id: Int, date: CalendarDate?) {
    self.id = id
    self.date = date
  }
}

public struct HakedisMonthReport: Sendable {
  public let hakedis: Hakedis
  public let people: [HakedisReportPerson]
  public let adjustments: [HakedisAdjustment]
  /// Dönemin kapsadığı aylar (genellikle bir ay).
  public let months: [PuantajMonth]

  /// - Parameters:
  ///   - links: Hakedişe bağlanan puantaj günleri (düzeltmeler dahil).
  ///   - items: Hakedişin sözleşme revizyonundaki kalemler (günlük birim fiyat için).
  public init(hakedis: Hakedis, links: [HakedisPuantajLink], items: [ContractItem],
              adjustments: [HakedisAdjustment] = []) {
    self.hakedis = hakedis
    self.adjustments = adjustments
    self.months = Self.months(from: hakedis.periodStart, to: hakedis.periodEnd)

    let daily = items.filter { $0.method == .gunluk }
    let shared = daily.filter { $0.personnelId == nil }
    let grouped = Dictionary(grouping: links.filter { $0.hakedisId == hakedis.id }, by: \.personnelId)
    self.people = grouped.map { personnelId, personLinks in
      var days: [CalendarDate: HakedisReportDay] = [:]
      for (date, dayLinks) in Dictionary(grouping: personLinks, by: \.workDate) {
        // Son durum: en yüksek revizyon/sürüm. Gün değeri düzeltmelerle net toplanır.
        let latest = dayLinks.max { ($0.periodRevision, $0.entryVersion) < ($1.periodRevision, $1.entryVersion) }!
        days[date] = HakedisReportDay(
          date: date, status: latest.status,
          dayValue: dayLinks.reduce(Decimal(0)) { $0 + $1.dayDelta },
          overtimeHours: dayLinks.reduce(Decimal(0)) { $0 + $1.overtimeDelta })
      }
      let price = daily.first { $0.personnelId == personnelId }?.unitPrice ?? (shared.count == 1 ? shared[0].unitPrice : nil)
      let name = personLinks.max { ($0.periodRevision, $0.entryVersion) < ($1.periodRevision, $1.entryVersion) }!.personnelName
      return HakedisReportPerson(personnelId: personnelId, name: name, days: days, unitPrice: price)
    }
    .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
  }

  public var totalDays: Decimal { people.reduce(Decimal(0)) { $0 + $1.dayTotal } }

  /// Kişi tutarlarının toplamı (birim fiyatı bilinen kişiler).
  public var peopleAmountTotal: Decimal { people.compactMap(\.amount).reduce(Decimal(0), +) }

  /// Kesinti toplamı (KDV hariç): stopaj, teminat, avans mahsubu ve diğer.
  public var deductionTotal: Decimal {
    hakedis.taxDeductionAmount + hakedis.otherDeductionAmount + hakedis.retentionAmount + hakedis.advanceAmount
  }

  public static func months(from start: CalendarDate, to end: CalendarDate) -> [PuantajMonth] {
    guard start <= end else { return [PuantajMonth(containing: start)] }
    var result: [PuantajMonth] = []
    var month = PuantajMonth(containing: start)
    let last = PuantajMonth(containing: end)
    while month <= last {
      result.append(month)
      month = month.next
    }
    return result
  }

  /// Pazartesi ile başlayan, 7'nin katı uzunlukta takvim hücreleri.
  public static func calendarCells(for month: PuantajMonth) -> [HakedisCalendarCell] {
    let leading = month.firstDay.isoWeekday - 1
    var dates: [CalendarDate?] = Array(repeating: nil, count: leading)
    dates.append(contentsOf: month.days.map { Optional($0) })
    while dates.count % 7 != 0 { dates.append(nil) }
    return dates.enumerated().map { HakedisCalendarCell(id: $0.offset, date: $0.element) }
  }
}
