import Foundation
import RDCore
import RDSupabase
import XCTest

/// Evrak arşivinin yerel Supabase (veritabanı + Storage) üzerinde uçtan uca
/// testi: gerçek dosya yükleme, indirme ve SHA-256 karşılaştırma, yetki,
/// tekrar deneme ve çakışma. Ayar yoksa atlanır. Her çalıştırma rastgele
/// içerikli yeni demo belgeler açar.
final class DocumentRepositoryTests: XCTestCase {
  private let doc101 = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!

  private func signedIn(_ email: String) async throws -> Repositories {
    let env = ProcessInfo.processInfo.environment
    guard let raw = env["RD_SUPABASE_URL"], let url = URL(string: raw), let key = env["RD_SUPABASE_ANON_KEY"] else {
      throw XCTSkip("Yerel Supabase ayarı yok (RD_SUPABASE_URL / RD_SUPABASE_ANON_KEY)")
    }
    guard url.host == "127.0.0.1" || url.host == "localhost" else {
      XCTFail("Entegrasyon testleri yalnızca yerel Supabase'e bağlanır")
      throw XCTSkip("yerel olmayan adres")
    }
    let repos = SupabaseEnvironment.makeRepositories(config: SupabaseConfig(url: url, anonKey: key))
    _ = try await repos.auth.signIn(email: email, password: "yerel-test-1234")
    return repos
  }

  private func sivas(_ repos: Repositories) async throws -> Project {
    let projects = try await repos.projects.list(includeCompleted: true)
    return try XCTUnwrap(projects.first { $0.code == "DEMO-SVS" })
  }

  /// Her çalıştırmada farklı içerik (aynı dosya kuralına takılmamak için).
  private func pdf(_ label: String) -> Data {
    Data("%PDF-1.4\n% RD entegrasyon \(label) \(UUID().uuidString)\n%%EOF\n".utf8)
  }

  private func jpeg() -> Data {
    var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
    data.append(Data(UUID().uuidString.utf8))
    data.append(contentsOf: [0xFF, 0xD9])
    return data
  }

  private func request(_ data: Data, kind: ArchiveDocumentKind, link: DocumentLink, title: String = "Entegrasyon belgesi")
    -> DocumentUploadRequest {
    DocumentUploadRequest(kind: kind, title: title, documentDate: .today(), link: link,
                          mimeType: DocumentFileValidator.detect(data)!, byteSize: data.count,
                          sha256: SHA256Digest.hex(data))
  }

  func testUploadAndDownloadThroughPrivateStorageMatchesDigest() async throws {
    let sef = try await signedIn("sef@example.test")
    let project = try await sivas(sef)
    let store = InMemoryPendingUploadStore()
    let uploader = DocumentUploader(repository: sef.documents, store: store)
    let data = pdf("tutanak")
    let pending = try await uploader.stage(data: data, kind: .tutanak, title: "Beton döküm tutanağı", description: nil,
                                           documentDate: .today(), link: .project(project.id), linkTitle: project.name)
    let doc = try await uploader.run(pending)
    XCTAssertEqual(doc.status, .yuklendi)
    XCTAssertEqual(doc.projectId, project.id)
    XCTAssertTrue(doc.isDemo, "demo projesinin belgesi demo")
    XCTAssertFalse(doc.storagePath.contains(project.id.uuidString.lowercased()))
    let downloaded = try await sef.documents.downloadFile(path: doc.storagePath)
    XCTAssertEqual(SHA256Digest.hex(downloaded), doc.sha256, "indirilen dosya yüklenenle aynı")

    let muhasebe = try await signedIn("muhasebe@example.test")
    let seen = try await muhasebe.documents.documents(filter: DocumentFilter(link: .project(project.id)))
    XCTAssertTrue(seen.contains { $0.id == doc.id })
    let events = try await muhasebe.documents.events(documentId: doc.id)
    XCTAssertEqual(events.map(\.action), ["rezerve", "yuklendi"])
  }

  func testSiteChiefCannotListOrDownloadInvoiceFiles() async throws {
    let muhasebe = try await signedIn("muhasebe@example.test")
    let project = try await sivas(muhasebe)
    let uploader = DocumentUploader(repository: muhasebe.documents, store: InMemoryPendingUploadStore())
    let invoice = try await uploader.run(
      try await uploader.stage(data: pdf("fatura"), kind: .fatura, title: "Proje faturası", description: nil,
                               documentDate: .today(), link: .project(project.id), linkTitle: project.name))

    let sef = try await signedIn("sef@example.test")
    let listed = try await sef.documents.documents(filter: DocumentFilter(projectId: project.id))
    XCTAssertFalse(listed.contains { $0.id == invoice.id }, "şef faturayı listede görmez")
    do {
      _ = try await sef.documents.downloadFile(path: invoice.storagePath)
      XCTFail("şef fatura dosyasını indirememeli")
    } catch let error as RepositoryError {
      XCTAssertTrue(error == .notFound || error == .forbidden("Bu dosyaya erişim yetkiniz yok."), "\(error)")
    }
    do {
      _ = try await sef.documents.reserveUpload(request(pdf("şef fatura"), kind: .fatura, link: .project(project.id)))
      XCTFail("şef projeye fatura ekleyememeli")
    } catch let error as RepositoryError {
      guard case .forbidden = error else { return XCTFail("\(error)") }
    }
  }

  func testLostResponseRetryAndResendDoNotDuplicate() async throws {
    let repos = try await signedIn("muhasebe@example.test")
    let project = try await sivas(repos)
    let data = jpeg()
    let req = request(data, kind: .fis, link: .project(project.id), title: "Akaryakıt fişi")
    let reserved = try await repos.documents.reserveUpload(req)
    XCTAssertEqual(reserved.status, .bekliyor)
    do {
      _ = try await repos.documents.completeUpload(id: req.id)
      XCTFail("dosya yokken tamamlanmamalı")
    } catch let error as RepositoryError {
      XCTAssertEqual(error, .notFound)
    }
    try await repos.documents.uploadFile(path: reserved.storagePath, data: data, mimeType: .jpeg)
    // Yanıt kaybolmuş gibi aynı dosyayı yeniden gönder: Storage 409 → başarılı sayılır.
    try await repos.documents.uploadFile(path: reserved.storagePath, data: data, mimeType: .jpeg)
    let again = try await repos.documents.reserveUpload(req)
    XCTAssertEqual(again.storagePath, reserved.storagePath, "aynı istek aynı yolu döner")
    let done = try await repos.documents.completeUpload(id: req.id)
    let doneAgain = try await repos.documents.completeUpload(id: req.id)
    XCTAssertEqual(done.status, .yuklendi)
    XCTAssertEqual(doneAgain.id, done.id)
    let same = try await repos.documents.documents(filter: DocumentFilter(link: .project(project.id)))
      .filter { $0.sha256 == req.sha256 }
    XCTAssertEqual(same.count, 1, "tek belge")

    var different = req
    different.sha256 = SHA256Digest.hex(jpeg())
    do {
      _ = try await repos.documents.reserveUpload(different)
      XCTFail("aynı kimlikle farklı dosya reddedilmeli")
    } catch let error as RepositoryError {
      guard case .conflict = error else { return XCTFail("\(error)") }
    }
    var newId = req
    newId.id = UUID()
    do {
      _ = try await repos.documents.reserveUpload(newId)
      XCTFail("aynı dosya aynı kayda ikinci kez eklenmemeli")
    } catch let error as RepositoryError {
      XCTAssertEqual(error, .conflict("Bu dosya bu kayda zaten eklenmiş"))
    }
  }

  func testUploadsOnlyToReservedPathAndSizeIsVerified() async throws {
    let repos = try await signedIn("muhasebe@example.test")
    let project = try await sivas(repos)
    do {
      try await repos.documents.uploadFile(path: "\(UUID().uuidString)/uydurma.pdf", data: pdf("x"), mimeType: .pdf)
      XCTFail("ayrılmamış yola yükleme reddedilmeli")
    } catch let error as RepositoryError {
      guard case .forbidden = error else { return XCTFail("\(error)") }
    }
    let data = pdf("eksik")
    let req = request(data, kind: .tutanak, link: .project(project.id))
    let reserved = try await repos.documents.reserveUpload(req)
    try await repos.documents.uploadFile(path: reserved.storagePath, data: data + Data("fazla".utf8), mimeType: .pdf)
    do {
      _ = try await repos.documents.completeUpload(id: req.id)
      XCTFail("boyutu farklı dosya tamamlanmamalı")
    } catch let error as RepositoryError {
      guard case .validation = error else { return XCTFail("\(error)") }
    }
    let cancelled = try await repos.documents.cancel(id: req.id, reason: nil)
    XCTAssertEqual(cancelled.status, .iptal)
    do {
      _ = try await repos.documents.reserveUpload(req)
      XCTFail("iptal edilmiş kimlik yeniden kullanılmamalı")
    } catch let error as RepositoryError {
      guard case .conflict = error else { return XCTFail("\(error)") }
    }
  }

  func testAttachingInvoiceToApprovedExpenseDoesNotChangeIt() async throws {
    let repos = try await signedIn("muhasebe@example.test")
    let before = try await repos.finance.document(id: doc101)
    let statusBefore = try await repos.finance.statuses(documentIds: [doc101])
    let uploader = DocumentUploader(repository: repos.documents, store: InMemoryPendingUploadStore())
    let doc = try await uploader.run(
      try await uploader.stage(data: pdf("demir faturası"), kind: .fatura, title: "Demir faturası", description: nil,
                               documentDate: .today(), link: .financeDocument(doc101), linkTitle: "GD-000001"))
    XCTAssertEqual(doc.financeDocumentId, doc101)
    XCTAssertEqual(doc.projectId, before.projectId, "proje giderden türetilir")
    XCTAssertEqual(doc.cariAccountId, before.cariAccountId)
    let after = try await repos.finance.document(id: doc101)
    XCTAssertEqual(after, before, "gider tutarı, durumu ve sürümü değişmedi")
    let statusAfter = try await repos.finance.statuses(documentIds: [doc101])
    XCTAssertEqual(statusAfter, statusBefore, "ödeme durumu değişmedi")
  }
}
