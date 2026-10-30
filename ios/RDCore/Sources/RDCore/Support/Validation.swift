import Foundation

/// Form doğrulamaları. Kurallar veritabanı kısıtlarıyla aynıdır; burada
/// kullanıcıya erken ve anlaşılır mesaj vermek için tekrarlanır.
public enum Validation {
  /// VKN (10 hane) veya TCKN (11 hane); boşluklar yok sayılır.
  public static func normalizedTaxNumber(_ raw: String?) -> String? {
    raw?.filter { !$0.isWhitespace }.nilIfBlank
  }

  public static func isValidTaxNumber(_ value: String) -> Bool {
    (value.count == 10 || value.count == 11) && value.allSatisfy(\.isASCIIDigit)
  }

  /// Boşluksuz, büyük harfli IBAN.
  public static func normalizedIBAN(_ raw: String?) -> String? {
    raw?.filter { !$0.isWhitespace }.uppercased().nilIfBlank
  }

  /// Biçim ve ISO 13616 mod-97 kontrolü.
  public static func isValidIBAN(_ value: String) -> Bool {
    let chars = Array(value)
    guard (15...34).contains(chars.count),
          chars[0].isASCIIUppercaseLetter, chars[1].isASCIIUppercaseLetter,
          chars[2].isASCIIDigit, chars[3].isASCIIDigit,
          chars.allSatisfy({ $0.isASCIIDigit || $0.isASCIIUppercaseLetter }) else { return false }
    if value.hasPrefix("TR") && chars.count != 26 { return false }
    let rearranged = chars[4...] + chars[..<4]
    var remainder = 0
    for ch in rearranged {
      let digits = ch.isASCIIDigit ? String(ch) : String(Int(ch.asciiValue! - 55))
      for d in digits { remainder = (remainder * 10 + Int(String(d))!) % 97 }
    }
    return remainder == 1
  }

  public static func isValidEmail(_ value: String) -> Bool {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !value.contains(" ")
  }
}

extension Character {
  var isASCIIDigit: Bool { ("0"..."9").contains(self) }
  var isASCIIUppercaseLetter: Bool { ("A"..."Z").contains(self) }
}
