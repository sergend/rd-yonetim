import Foundation

/// TL tutar biçimlendirme ve kullanıcı girdisini Decimal'e çevirme.
/// Tutarlar her yerde Decimal'dir; Double kullanılmaz.
public enum Money {
  public static let locale = Locale(identifier: "tr_TR")

  public static func format(_ amount: Decimal, currency: String = "TRY") -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    let number = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    return currency == "TRY" ? "\(number) ₺" : "\(number) \(currency)"
  }

  /// "1.250,50", "1250.5", "1 250,50" gibi girdileri kabul eder.
  /// En fazla 2 ondalık; geçersizse nil.
  public static func parse(_ raw: String) -> Decimal? {
    var text = raw.filter { !$0.isWhitespace && $0 != "₺" }
    guard !text.isEmpty else { return nil }
    if text.contains(",") {
      text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
    } else if text.filter({ $0 == "." }).count > 1 {
      text = text.replacingOccurrences(of: ".", with: "")
    } else if let dot = text.firstIndex(of: "."), text[text.index(after: dot)...].count == 3 {
      text = text.replacingOccurrences(of: ".", with: "")  // "1.250" binlik ayraç
    }
    guard text.allSatisfy({ $0.isASCIIDigit || $0 == "." }),
          let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
    if let dot = text.firstIndex(of: "."), text[text.index(after: dot)...].count > 2 { return nil }
    return value
  }
}
