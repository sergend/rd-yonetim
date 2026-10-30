import Foundation

public extension String {
  /// Baştaki/sondaki boşluklar atılmış hali; boşsa nil.
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

public extension Optional where Wrapped == String {
  var nilIfBlank: String? { self?.nilIfBlank }
}
