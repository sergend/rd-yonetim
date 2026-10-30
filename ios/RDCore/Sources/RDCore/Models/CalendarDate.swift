import Foundation

/// Saat dilimi taşımayan takvim günü (Postgres `date`). JSON'da "yyyy-MM-dd".
/// Şantiye tarihleri gün bazındadır; Date kullanmak saat dilimi kaymasına yol açar.
public struct CalendarDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
  public let year: Int
  public let month: Int
  public let day: Int

  public init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  /// Verilen anın İstanbul saatine göre günü.
  public init(_ date: Date, timeZone: TimeZone = .istanbul) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    self.init(year: parts.year!, month: parts.month!, day: parts.day!)
  }

  public init?(iso: String) {
    let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
    self.init(year: parts[0], month: parts[1], day: parts[2])
  }

  public static func today(timeZone: TimeZone = .istanbul) -> CalendarDate { CalendarDate(Date(), timeZone: timeZone) }

  public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
  public var description: String { iso }

  /// Takvim seçicide kullanmak için gün ortası (öğlen) anı.
  public func date(timeZone: TimeZone = .istanbul) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
  }

  public func adding(days: Int) -> CalendarDate {
    CalendarDate(date().addingTimeInterval(TimeInterval(days * 86_400)))
  }

  public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let value = CalendarDate(iso: raw) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Geçersiz tarih: \(raw)")
    }
    self = value
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(iso)
  }
}

public extension TimeZone {
  static let istanbul = TimeZone(identifier: "Europe/Istanbul")!
}
