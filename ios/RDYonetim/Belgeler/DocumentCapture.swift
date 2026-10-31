import PDFKit
import RDCore
import RDDesign
import SwiftUI
import UIKit
import VisionKit

// Belge yakalama yardımcıları: VisionKit tarayıcı, taranan sayfalardan tek PDF,
// fotoğrafı JPEG'e çevirme. OCR yapılmaz.

/// VisionKit belge tarayıcısı. Desteklenmeyen cihazda (ör. Simülatör)
/// `DocumentScanner.isAvailable` false döner; ekran "Tara" yerine
/// fotoğraf ve dosya seçeneklerini gösterir.
struct DocumentScanner: UIViewControllerRepresentable {
  static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

  /// Taranan sayfalar (sırasıyla). Vazgeçilirse çağrılmaz.
  let onScan: ([UIImage]) -> Void
  let onCancel: () -> Void
  let onError: (String) -> Void

  func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
    let controller = VNDocumentCameraViewController()
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
    let parent: DocumentScanner

    init(parent: DocumentScanner) {
      self.parent = parent
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                      didFinishWith scan: VNDocumentCameraScan) {
      let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
      parent.onScan(pages)
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
      parent.onCancel()
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
      parent.onError("Tarama tamamlanamadı: \(error.localizedDescription)")
    }
  }
}

enum DocumentCapture {
  /// Bir sayfanın uzun kenarı (piksel). A4 için ~250 dpi; okunaklı ve küçük.
  static let maxPageDimension: CGFloat = 2400
  static let jpegQuality: CGFloat = 0.75

  /// Taranan sayfaları tek PDF'te birleştirir. Her sayfa önce JPEG'e
  /// sıkıştırılır; böylece çok sayfalı tarama boyut sınırının altında kalır.
  static func pdf(from pages: [UIImage]) -> Data? {
    guard !pages.isEmpty else { return nil }
    let document = PDFDocument()
    for (index, page) in pages.enumerated() {
      guard let jpeg = jpegData(page), let compressed = UIImage(data: jpeg),
            let pdfPage = PDFPage(image: compressed) else { return nil }
      document.insert(pdfPage, at: index)
    }
    return document.dataRepresentation()
  }

  /// Fotoğraf arşivinden gelen görseli (HEIC dahil) JPEG'e çevirir. PNG ve
  /// JPEG olduğu gibi kalır (sınırı aşmıyorsa).
  static func normalizedImageData(_ data: Data) -> Data? {
    if let type = DocumentFileValidator.detect(data), data.count <= DocumentLimits.maxBytes, type.isImage {
      return data
    }
    guard let image = UIImage(data: data) else { return nil }
    return jpegData(image)
  }

  static func jpegData(_ image: UIImage) -> Data? {
    let size = image.size
    let longest = max(size.width, size.height) * image.scale
    guard longest > maxPageDimension else { return image.jpegData(compressionQuality: jpegQuality) }
    let ratio = maxPageDimension / longest
    let target = CGSize(width: size.width * image.scale * ratio, height: size.height * image.scale * ratio)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return resized.jpegData(compressionQuality: jpegQuality)
  }

  /// Dosya uygulamasından seçilen dosyayı güvenli erişimle okur.
  static func read(url: URL) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if size > DocumentLimits.maxBytes {
      throw RepositoryError.validation("Dosya çok büyük (\(size.fileSizeText)); en çok \(DocumentLimits.maxBytes.fileSizeText) yüklenebilir.")
    }
    return try Data(contentsOf: url)
  }
}

// MARK: - Görüntüleyiciler

/// PDF görüntüleyici (yakınlaştırma ve sayfa kaydırma PDFKit'ten).
struct PDFDocumentView: UIViewRepresentable {
  let data: Data

  func makeUIView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.document = PDFDocument(data: data)
    view.accessibilityLabel = "PDF belge"
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {
    if view.document?.dataRepresentation()?.count != data.count {
      view.document = PDFDocument(data: data)
    }
  }
}

/// Yakınlaştırılabilir fotoğraf (iki parmakla büyütme, çift dokunuşla sıfırlama).
struct ZoomableImageView: UIViewRepresentable {
  let image: UIImage

  func makeUIView(context: Context) -> UIScrollView {
    let scroll = UIScrollView()
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 6
    scroll.delegate = context.coordinator
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.isAccessibilityElement = true
    imageView.accessibilityLabel = "Belge görseli"
    scroll.addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
      imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
    ])
    let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.reset(_:)))
    doubleTap.numberOfTapsRequired = 2
    scroll.addGestureRecognizer(doubleTap)
    context.coordinator.imageView = imageView
    return scroll
  }

  func updateUIView(_ scroll: UIScrollView, context: Context) {
    context.coordinator.imageView?.image = image
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, UIScrollViewDelegate {
    weak var imageView: UIImageView?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc func reset(_ gesture: UITapGestureRecognizer) {
      guard let scroll = gesture.view as? UIScrollView else { return }
      scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2.5, animated: true)
    }
  }
}

/// Dosya içeriğine göre PDF veya görsel gösterir.
struct DocumentFilePreview: View {
  let data: Data
  let mimeType: DocumentMimeType

  var body: some View {
    switch mimeType {
    case .pdf:
      PDFDocumentView(data: data)
    case .jpeg, .png:
      if let image = UIImage(data: data) {
        ZoomableImageView(image: image)
      } else {
        ContentUnavailableView("Görsel açılamadı", systemImage: "photo",
                               description: Text("Dosya bozuk olabilir."))
      }
    }
  }
}

extension ArchiveDocumentStatus {
  var tone: StatusTone {
    switch self {
    case .bekliyor: .warning
    case .yuklendi: .success
    case .arsivlendi: .neutral
    case .iptal: .danger
    }
  }
}
