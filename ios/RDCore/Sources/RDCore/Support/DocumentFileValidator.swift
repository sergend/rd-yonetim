import Foundation

/// Yüklenecek dosyanın doğrulaması. Tür dosya adına veya uzantısına göre
/// değil, içeriğin ilk baytlarına (dosya imzası) göre belirlenir. Sunucu da
/// türü ve boyutu ayrıca denetler (bucket kısıtları ve complete_document_upload).
public enum DocumentFileValidator {
  /// İçerikten tür tespiti; desteklenmeyen içerikte nil.
  public static func detect(_ data: Data) -> DocumentMimeType? {
    let bytes = [UInt8](data.prefix(1024))
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
    // PDF imzası "%PDF-" ilk 1024 bayt içinde olabilir (standart izin verir).
    let pdf: [UInt8] = Array("%PDF-".utf8)
    if bytes.count >= pdf.count {
      for start in 0...(bytes.count - pdf.count) where bytes[start..<start + pdf.count].elementsEqual(pdf) {
        return .pdf
      }
    }
    return nil
  }

  /// Dosyayı doğrular ve içerikten belirlenen türü döner.
  /// - Parameter declared: Seçicinin bildirdiği tür; içerikle uyuşmazsa hata.
  public static func validate(_ data: Data, declared: DocumentMimeType? = nil) throws -> DocumentMimeType {
    guard !data.isEmpty else { throw RepositoryError.validation("Dosya boş.") }
    guard data.count <= DocumentLimits.maxBytes else {
      throw RepositoryError.validation(
        "Dosya çok büyük (\(data.count.fileSizeText)). En fazla \(DocumentLimits.maxBytes.fileSizeText) yüklenebilir.")
    }
    guard let detected = detect(data) else {
      throw RepositoryError.validation("Bu dosya türü desteklenmiyor. Yalnızca PDF, JPEG ve PNG yüklenebilir.")
    }
    if let declared, declared != detected {
      throw RepositoryError.validation(
        "Dosyanın içeriği uzantısıyla uyuşmuyor (\(detected.title) içerik, \(declared.title) olarak seçildi).")
    }
    return detected
  }

  /// Dosya adı uzantısından beklenen tür (yalnızca içerikle karşılaştırmak için).
  public static func declaredType(fileName: String) -> DocumentMimeType? {
    switch (fileName as NSString).pathExtension.lowercased() {
    case "pdf": .pdf
    case "jpg", "jpeg": .jpeg
    case "png": .png
    default: nil
    }
  }
}
