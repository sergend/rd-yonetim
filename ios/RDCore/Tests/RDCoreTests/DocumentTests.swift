import Foundation
import XCTest
@testable import RDCore

private func grants(_ keys: [PermissionKey], project: UUID? = nil) -> [PermissionGrant] {
  keys.map { PermissionGrant(projectId: project, permissionKey: $0.rawValue) }
}

/// Geçerli imzalı küçük deneme dosyaları.
enum SampleFiles {
  static func pdf(_ text: String = "RD deneme tutanağı") -> Data { Data("%PDF-1.4\n% \(text)\n%%EOF\n".utf8) }
  static func jpeg(_ seed: UInt8 = 1) -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0, seed, 0x10, 0x4A, 0x46, 0xFF, 0xD9]) }
  static func png() -> Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]) }
}

/// Bellek içi sunucu: iki proje, genel ofis, bir taşeron sözleşmesi ve
/// muhasebenin onaylı gideri. Kullanıcı değiştirilerek yetki denenir.
private struct DocFixture {
  let backend: InMemoryBackend
  let repositories: Repositories
  let store = InMemoryPendingUploadStore()
  let project = Project(code: "T-1", name: "Test projesi", status: .devam)
  let other = Project(code: "T-2", name: "Diğer proje", status: .devam)
  let demo = Project(code: "DEMO-1", name: "Demo proje", status: .devam, isDemo: true)
  let office = CostCenter(code: "OFIS", name: "Merkez ofis")
  let cari = CariAccount(code: "C-1", title: "Test Taşeron", type: .taseron)
  let demir = FinanceCategory(kind: .gider, name: "Demir", sortOrder: 10)
  let admin = UserProfile(id: UUID(), email: "admin@example.test", fullName: "Yönetici")
  let sef = UserProfile(id: UUID(), email: "sef@example.test", fullName: "Şef")
  let sefB = UserProfile(id: UUID(), email: "sef-b@example.test", fullName: "Başka şef")
  let contract: Contract
  let today = CalendarDate(year: 2026, month: 10, day: 31)

  init() async {
    contract = Contract(contractNo: "S-1", projectId: project.id, subcontractorId: UUID(), cariAccountId: cari.id,
                        title: "Kaba yapı")
    backend = InMemoryBackend(profile: admin)
    repositories = backend.repositories
    await backend.seed(projects: [project, other, demo], costCenters: [office], accounts: [cari])
    await backend.seedFinance(categories: [demir])
    await backend.seedContracts(contracts: [contract])
  }

  func asAdmin() async {
    await backend.set(profile: admin)
    await backend.set(grants: PermissionKey.allCases.map { PermissionGrant(projectId: nil, permissionKey: $0.rawValue) })
  }

  /// Şantiye şefi şablonu: projede belge görür/ekler, gider girer; finansal belge görmez.
  func asSef(_ profile: UserProfile? = nil, project: UUID? = nil) async {
    await backend.set(profile: profile ?? sef)
    await backend.set(grants: grants([.projeRead, .belgeRead, .belgeWrite, .giderWrite], project: project ?? self.project.id))
  }

  func expense(_ amount: Decimal = 1_000) -> FinanceDocumentDraft {
    FinanceDocumentDraft(kind: .gider, scope: .project(project.id), categoryId: demir.id, description: "Demir alımı",
                         amount: amount, documentDate: today, cariAccountId: cari.id)
  }

  var uploader: DocumentUploader { DocumentUploader(repository: repositories.documents, store: store) }

  func upload(_ data: Data, kind: ArchiveDocumentKind = .tutanak, title: String = "Belge",
              link: DocumentLink? = nil, replacing: UUID? = nil) async throws -> ArchiveDocument {
    let pending = try await uploader.stage(data: data, kind: kind, title: title, description: nil, documentDate: today,
                                           link: link ?? .project(project.id), linkTitle: "Test", replacesId: replacing)
    return try await uploader.run(pending)
  }
}

// MARK: - Dosya özeti ve doğrulama

final class DocumentFileTests: XCTestCase {
  func testSHA256MatchesStandardVectors() {
    let vectors: [(String, String)] = [
      ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
      ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
      ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
    ]
    for (input, expected) in vectors {
      XCTAssertEqual(SHA256Digest.portableHex(Data(input.utf8)), expected)
      XCTAssertEqual(SHA256Digest.hex(Data(input.utf8)), expected)
    }
    // Blok sınırları ve uzun girdi (1 milyon "a").
    XCTAssertEqual(SHA256Digest.portableHex(Data(repeating: UInt8(ascii: "a"), count: 1_000_000)),
                   "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    for length in [55, 56, 63, 64, 65, 119, 120] {
      let data = Data((0..<length).map { UInt8($0 & 0xff) })
      XCTAssertEqual(SHA256Digest.portableHex(data), SHA256Digest.hex(data), "uzunluk \(length)")
    }
  }

  func testTypeComesFromContentNotExtension() throws {
    XCTAssertEqual(try DocumentFileValidator.validate(SampleFiles.pdf()), .pdf)
    XCTAssertEqual(try DocumentFileValidator.validate(SampleFiles.jpeg()), .jpeg)
    XCTAssertEqual(try DocumentFileValidator.validate(SampleFiles.png()), .png)
    // PDF imzası ilk 1024 bayt içinde olabilir.
    XCTAssertEqual(DocumentFileValidator.detect(Data("\n\n%PDF-1.7".utf8)), .pdf)

    // Uzantısı .pdf olan ama içeriği PDF olmayan dosya.
    XCTAssertThrowsError(try DocumentFileValidator.validate(Data("<html>fatura</html>".utf8), declared: .pdf))
    XCTAssertNil(DocumentFileValidator.detect(Data("GIF89a".utf8)), "GIF desteklenmez")
    // İçerik JPEG, uzantı PDF: uyuşmazlık açıkça bildirilir.
    XCTAssertThrowsError(try DocumentFileValidator.validate(SampleFiles.jpeg(), declared: .pdf)) { error in
      XCTAssertTrue(message(for: error).contains("uyuşmuyor"))
    }
    XCTAssertEqual(DocumentFileValidator.declaredType(fileName: "Fiş.JPEG"), .jpeg)
  }

  func testEmptyAndOversizedFilesAreRejectedWithClearMessage() {
    XCTAssertThrowsError(try DocumentFileValidator.validate(Data())) { error in
      XCTAssertEqual(message(for: error), "Dosya boş.")
    }
    var big = SampleFiles.pdf()
    big.append(Data(count: DocumentLimits.maxBytes))
    XCTAssertThrowsError(try DocumentFileValidator.validate(big)) { error in
      XCTAssertTrue(message(for: error).contains("çok büyük"))
    }
  }
}

// MARK: - Yükleme, yetki ve geçmiş

final class DocumentRepositoryRuleTests: XCTestCase {
  func testUploadFlowStoresFileAndDerivesScopeFromLinkedRecord() async throws {
    let f = await DocFixture()
    await f.asAdmin()
    let data = SampleFiles.pdf()
    let doc = try await f.upload(data, kind: .tutanak, title: " Beton döküm tutanağı ")
    XCTAssertEqual(doc.status, .yuklendi)
    XCTAssertEqual(doc.title, "Beton döküm tutanağı")
    XCTAssertEqual(doc.projectId, f.project.id)
    XCTAssertEqual(doc.byteSize, data.count)
    XCTAssertEqual(doc.sha256, SHA256Digest.hex(data))
    XCTAssertFalse(doc.storagePath.contains(f.project.id.uuidString.lowercased()), "yol proje içermez")
    XCTAssertFalse(doc.storagePath.contains("Beton"), "yol dosya adı içermez")
    let downloaded = try await f.repositories.documents.downloadFile(path: doc.storagePath)
    XCTAssertEqual(SHA256Digest.hex(downloaded), doc.sha256)
    let pending = await f.store.all()
    XCTAssertTrue(pending.isEmpty, "tamamlanan yüklemenin yerel kopyası silinir")

    let expense = try await f.repositories.finance.saveDocument(id: UUID(), draft: f.expense(), expectedVersion: nil)
    let invoice = try await f.upload(SampleFiles.pdf("fatura"), kind: .fatura, link: .financeDocument(expense.id))
    XCTAssertEqual(invoice.projectId, f.project.id)
    XCTAssertEqual(invoice.cariAccountId, f.cari.id, "cari giderden türetilir")
    let contractFile = try await f.upload(SampleFiles.pdf("sözleşme"), kind: .sozlesme, link: .contract(f.contract.id))
    XCTAssertEqual(contractFile.subcontractorId, f.contract.subcontractorId)
    let demoDoc = try await f.upload(SampleFiles.png(), kind: .ruhsat, link: .project(f.demo.id))
    XCTAssertTrue(demoDoc.isDemo, "DEMO işareti projeden gelir")
  }

  func testFileAttachmentDoesNotTouchFinanceAmounts() async throws {
    let f = await DocFixture()
    await f.asAdmin()
    let expense = try await f.repositories.finance.saveDocument(id: UUID(), draft: f.expense(2_500), expectedVersion: nil)
    let approved = try await f.repositories.finance.approve(id: expense.id, expectedVersion: nil, settlementId: nil)
    let entriesBefore = await f.backend.entries.count
    _ = try await f.upload(SampleFiles.pdf("fatura"), kind: .fatura, link: .financeDocument(expense.id))
    let after = try await f.repositories.finance.document(id: expense.id)
    XCTAssertEqual(after, approved, "gider tutarı, durumu ve sürümü değişmez")
    let entriesAfter = await f.backend.entries.count
    XCTAssertEqual(entriesAfter, entriesBefore, "cari deftere hareket yazılmaz")
    let statuses = try await f.repositories.finance.statuses(documentIds: [expense.id])
    XCTAssertEqual(statuses.first?.remainingAmount, 2_500)
  }

  func testSiteChiefSeesProjectDocsButNotFinancialOnesOrOtherProjects() async throws {
    let f = await DocFixture()
    await f.asAdmin()
    let tutanak = try await f.upload(SampleFiles.pdf("tutanak"), kind: .tutanak)
    let fatura = try await f.upload(SampleFiles.pdf("fatura"), kind: .fatura)
    let sozlesme = try await f.upload(SampleFiles.pdf("sozlesme"), kind: .sozlesme, link: .contract(f.contract.id))
    let otherDoc = try await f.upload(SampleFiles.pdf("diger"), kind: .irsaliye, link: .project(f.other.id))

    await f.asSef()
    let visible = try await f.repositories.documents.documents(filter: DocumentFilter()).map(\.id)
    XCTAssertEqual(visible, [tutanak.id], "şef yalnızca kendi projesindeki finansal olmayan belgeyi görür")
    for hidden in [fatura, sozlesme, otherDoc] {
      do {
        _ = try await f.repositories.documents.downloadFile(path: hidden.storagePath)
        XCTFail("şef \(hidden.kind.title) dosyasını indirmemeli")
      } catch {
        XCTAssertEqual(error as? RepositoryError, .notFound)
      }
    }
    // Finansal türü proje düzeyinde ekleyemez; seçicide de sunulmaz.
    let access = AccessControl(grants: await f.backend.grants)
    XCTAssertFalse(allowedDocumentKinds(for: .project(f.project.id), projectId: f.project.id, access: access).contains(.fatura))
    do {
      _ = try await f.upload(SampleFiles.pdf("şef fatura"), kind: .fatura)
      XCTFail("şef proje faturası ekleyememeli")
    } catch {
      guard case RepositoryError.forbidden = error else { return XCTFail("\(error)") }
    }
    // Sözleşmeye dosya ekleyemez (sözleşmeyi göremez).
    do {
      _ = try await f.upload(SampleFiles.pdf("şef sözleşme"), kind: .sozlesme, link: .contract(f.contract.id))
      XCTFail("şef sözleşmeye dosya ekleyememeli")
    } catch {
      XCTAssertEqual(error as? RepositoryError, .notFound)
    }
  }

  func testOtherProjectsChiefCannotWriteIntoReservedPath() async throws {
    let f = await DocFixture()
    await f.asSef()
    let pending = try await f.uploader.stage(data: SampleFiles.pdf(), kind: .tutanak, title: "Tutanak", description: nil,
                                             documentDate: f.today, link: .project(f.project.id), linkTitle: "Test")
    let reserved = try await f.repositories.documents.reserveUpload(pending.request)
    await f.asSef(f.sefB, project: f.other.id)
    do {
      try await f.repositories.documents.uploadFile(path: reserved.storagePath, data: SampleFiles.pdf("sahte"), mimeType: .pdf)
      XCTFail("başka projedeki şef bu yola yükleyememeli")
    } catch {
      guard case RepositoryError.forbidden = error else { return XCTFail("\(error)") }
    }
    var ownProject = pending.request
    ownProject.linkId = f.other.id
    do {
      _ = try await f.repositories.documents.reserveUpload(ownProject)
      XCTFail("başkasının kimliği içerik sızdırmamalı")
    } catch {
      guard case RepositoryError.conflict = error else { return XCTFail("\(error)") }
    }
  }

  func testSameRequestIsIdempotentAndDifferentContentConflicts() async throws {
    let f = await DocFixture()
    await f.asAdmin()
    let pending = try await f.uploader.stage(data: SampleFiles.pdf(), kind: .tutanak, title: "Tutanak", description: nil,
                                             documentDate: f.today, link: .project(f.project.id), linkTitle: "Test")
    let first = try await f.repositories.documents.reserveUpload(pending.request)
    let again = try await f.repositories.documents.reserveUpload(pending.request)
    XCTAssertEqual(first.storagePath, again.storagePath, "aynı istek aynı yolu döner")

    var otherFile = pending.request
    otherFile.sha256 = SHA256Digest.hex(SampleFiles.pdf("başka"))
    var otherTitle = pending.request
    otherTitle.title = "Başka ad"
    var otherSize = pending.request
    otherSize.byteSize += 1
    for changed in [otherFile, otherTitle, otherSize] {
      do {
        _ = try await f.repositories.documents.reserveUpload(changed)
        XCTFail("aynı kimlikle farklı istek reddedilmeli")
      } catch {
        guard case RepositoryError.conflict = error else { return XCTFail("\(error)") }
      }
    }
    _ = try await f.uploader.run(pending)
    let count = await f.backend.archiveDocuments.count
    XCTAssertEqual(count, 1)

    // Aynı dosya aynı kayda yeni kimlikle: açık çakışma.
    do {
      _ = try await f.upload(SampleFiles.pdf(), kind: .tutanak, title: "Tutanak")
      XCTFail("aynı dosya aynı kayda ikinci kez eklenmemeli")
    } catch {
      XCTAssertEqual(error as? RepositoryError, .conflict("Bu dosya bu kayda zaten eklenmiş"))
    }
    let other = try await f.upload(SampleFiles.pdf(), kind: .tutanak, title: "Tutanak", link: .project(f.other.id))
    XCTAssertNotEqual(other.storagePath, first.storagePath, "başka kayıttaki kopya ayrı nesnedir")
  }

  func testNetworkErrorsAreRetriedWithSameIdWithoutDuplicates() async throws {
    let f = await DocFixture()
    await f.asAdmin()
    let pending = try await f.uploader.stage(data: SampleFiles.jpeg(), kind: .fis, title: "Akaryakıt fişi",
                                             description: nil, documentDate: f.today, link: .project(f.project.id),
                                             linkTitle: "Test")
    // 1) Yer ayırma sırasında ağ kesildi.
    await f.backend.set(nextError: .network)
    do { _ = try await f.uploader.run(pending); XCTFail() } catch { XCTAssertEqual(error as? RepositoryError, .network) }
    var stored = await f.store.all()
    XCTAssertEqual(stored.map(\.id), [pending.id], "dosya cihazda kalır")
    XCTAssertEqual(stored.first?.lastError, RepositoryError.network.errorDescription)
    XCTAssertEqual(stored.first?.needsNewId, false)

    // 2) Dosya sunucuya ulaştı ama yanıt kayboldu.
    await f.backend.set(dropNextUploadResponse: true)
    do { _ = try await f.uploader.run(stored[0]); XCTFail() } catch { XCTAssertEqual(error as? RepositoryError, .network) }
    stored = await f.store.all()
    XCTAssertEqual(stored.first?.stage, .yerAyrildi)

    // 3) Aynı kimlikle yeniden deneme: nesne zaten var sayılır, doğrulanır, tek belge.
    let doc = try await f.uploader.run(stored[0])
    XCTAssertEqual(doc.id, pending.id)
    XCTAssertEqual(doc.status, .yuklendi)
    let documents = await f.backend.archiveDocuments
    XCTAssertEqual(documents.count, 1, "ikinci belge oluşmaz")
    let objects = await f.backend.storageObjects.count
    XCTAssertEqual(objects, 1, "ikinci nesne oluşmaz")
    let left = await f.store.all()
    XCTAssertTrue(left.isEmpty)
    // 4) Tamamlanmış yüklemenin tekrar çalıştırılması da aynı belgeyi döner.
    try await f.store.saveData(SampleFiles.jpeg(), for: pending.id)
    try await f.store.save(pending)
    let again = try await f.uploader.run(pending)
    XCTAssertEqual(again.id, doc.id)
  }

  @MainActor
  func testCancelledReservationNeedsNewIdOnRetry() async throws {
    let f = await DocFixture()
    await f.asSef()
    let model = DocumentUploadViewModel(link: .project(f.project.id), linkTitle: "Test", projectId: f.project.id,
                                        access: AccessControl(grants: await f.backend.grants),
                                        repositories: f.repositories, store: f.store, today: f.today)
    model.setFile(SampleFiles.pdf(), fileName: "tutanak.pdf")
    XCTAssertEqual(model.title, "tutanak")
    await f.backend.set(dropNextUploadResponse: true)
    await model.submit()
    guard case .failed = model.state else { return XCTFail("\(model.state)") }
    let firstId = try XCTUnwrap(model.pendingUpload?.id)
    // Sunucuda süre doldu: bekleyen yükleme iptal edildi.
    _ = try await f.repositories.documents.cancel(id: firstId, reason: nil)
    await model.retry()
    guard case .failed = model.state else { return XCTFail("iptal edilmiş kimlik kabul edilmemeli: \(model.state)") }
    XCTAssertEqual(model.pendingUpload?.needsNewId, true)
    await model.retry()
    guard case .done(let doc) = model.state else { return XCTFail("\(model.state)") }
    XCTAssertNotEqual(doc.id, firstId, "yeni kimlikle yüklendi")
    let active = await f.backend.archiveDocuments.filter { $0.status == .yuklendi }
    XCTAssertEqual(active.count, 1)
    let pending = await f.store.all()
    XCTAssertTrue(pending.isEmpty)
  }

  func testCompleteFailsForMissingOrMismatchedObject() async throws {
    let f = await DocFixture()
    await f.asAdmin()
    let pending = try await f.uploader.stage(data: SampleFiles.pdf(), kind: .tutanak, title: "Tutanak", description: nil,
                                             documentDate: f.today, link: .project(f.project.id), linkTitle: "Test")
    let reserved = try await f.repositories.documents.reserveUpload(pending.request)
    do {
      _ = try await f.repositories.documents.completeUpload(id: reserved.id)
      XCTFail("dosya yokken tamamlanmamalı")
    } catch {
      XCTAssertEqual(error as? RepositoryError, .notFound)
    }
    try await f.repositories.documents.uploadFile(path: reserved.storagePath, data: SampleFiles.pdf("eksik"), mimeType: .pdf)
    do {
      _ = try await f.repositories.documents.completeUpload(id: reserved.id)
      XCTFail("boyutu farklı dosya tamamlanmamalı")
    } catch {
      guard case RepositoryError.validation = error else { return XCTFail("\(error)") }
    }
    // Cihazdaki kopya bozulduysa yükleme başlamaz.
    try await f.store.saveData(SampleFiles.pdf("bozuk"), for: pending.id)
    do {
      _ = try await f.uploader.run(pending)
      XCTFail("bozuk yerel kopya yüklenmemeli")
    } catch {
      XCTAssertTrue(message(for: error).contains("bozulmuş"))
    }
  }

  func testArchiveCancelReplaceAndRelinkKeepHistory() async throws {
    let f = await DocFixture()
    await f.asAdmin()
    let wrong = try await f.upload(SampleFiles.pdf("yanlış"), kind: .irsaliye, title: "İrsaliye")
    let fixed = try await f.upload(SampleFiles.pdf("doğru"), kind: .irsaliye, title: "İrsaliye", replacing: wrong.id)
    XCTAssertEqual(fixed.replacesId, wrong.id)
    let old = try await f.repositories.documents.document(id: wrong.id)
    XCTAssertEqual(old.status, .iptal)
    XCTAssertEqual(old.cancelReason, "Yeni dosyayla değiştirildi")
    let oldFile = try await f.repositories.documents.downloadFile(path: old.storagePath)
    XCTAssertEqual(SHA256Digest.hex(oldFile), old.sha256, "eski dosya silinmez")

    do {
      _ = try await f.repositories.documents.cancel(id: fixed.id, reason: "kısa")
      XCTFail("kısa gerekçe kabul edilmemeli")
    } catch {
      guard case RepositoryError.validation = error else { return XCTFail("\(error)") }
    }
    let archived = try await f.repositories.documents.archive(id: fixed.id, reason: "Eski irsaliye")
    XCTAssertEqual(archived.status, .arsivlendi)
    let moved = try await f.repositories.documents.relink(id: fixed.id, to: .project(f.other.id),
                                                          reason: "Yanlış projeye eklenmişti", expectedVersion: archived.version)
    XCTAssertEqual(moved.projectId, f.other.id)
    do {
      _ = try await f.repositories.documents.relink(id: fixed.id, to: .project(f.demo.id),
                                                    reason: "Demo projeye taşıma denemesi", expectedVersion: moved.version)
      XCTFail("gerçek belge demo projeye taşınmamalı")
    } catch {
      guard case RepositoryError.validation = error else { return XCTFail("\(error)") }
    }
    let actions = try await f.repositories.documents.events(documentId: fixed.id).map(\.action)
    XCTAssertEqual(actions, ["rezerve", "yuklendi", "arsivlendi", "baglanti_degisti"])
    let oldActions = try await f.repositories.documents.events(documentId: wrong.id).map(\.action)
    XCTAssertEqual(oldActions, ["rezerve", "yuklendi", "degistirildi"])
  }

  func testChiefCannotChangeReceiptHistoryAfterExpenseApproval() async throws {
    let f = await DocFixture()
    await f.asSef()
    let expense = try await f.repositories.finance.saveDocument(id: UUID(), draft: f.expense(), expectedVersion: nil)
    let receipt = try await f.upload(SampleFiles.jpeg(), kind: .fis, title: "Fiş", link: .financeDocument(expense.id))
    let visible = try await f.repositories.documents.documents(filter: DocumentFilter(link: .financeDocument(expense.id)))
    XCTAssertEqual(visible.map(\.id), [receipt.id], "şef kendi giderinin fişini görür")
    await f.asAdmin()
    _ = try await f.repositories.finance.approve(id: expense.id, expectedVersion: nil, settlementId: nil)
    await f.asSef()
    do {
      _ = try await f.repositories.documents.cancel(id: receipt.id, reason: "Yanlış fiş yüklendi")
      XCTFail("onaylı giderin fişini şef iptal edememeli")
    } catch {
      guard case RepositoryError.forbidden = error else { return XCTFail("\(error)") }
    }
  }
}

// MARK: - View model'ler

@MainActor
final class DocumentViewModelTests: XCTestCase {
  func testUploadFormValidatesFileTitleAndKind() async throws {
    let f = await DocFixture()
    await f.asSef()
    let access = AccessControl(grants: await f.backend.grants)
    let model = DocumentUploadViewModel(link: .project(f.project.id), linkTitle: "Test", projectId: f.project.id,
                                        access: access, repositories: f.repositories, store: f.store, today: f.today)
    XCTAssertFalse(model.allowedKinds.contains(.fatura))
    XCTAssertEqual(model.kind, .irsaliye)
    XCTAssertFalse(model.canSubmit)
    model.setFile(Data("not a pdf".utf8), fileName: "fatura.pdf")
    XCTAssertNotNil(model.fileError)
    XCTAssertFalse(model.canSubmit)
    model.setFile(SampleFiles.png(), fileName: "irsaliye.png")
    XCTAssertNil(model.fileError)
    XCTAssertEqual(model.title, "irsaliye")
    model.title = "   "
    XCTAssertEqual(model.titleError, "Belge adı zorunlu")
    XCTAssertFalse(model.canSubmit)
    model.title = "Beton irsaliyesi"
    XCTAssertTrue(model.canSubmit)
    await model.submit()
    guard case .done(let doc) = model.state else { return XCTFail("\(model.state)") }
    XCTAssertEqual(doc.kind, .irsaliye)
    XCTAssertEqual(doc.mimeType, .png)

    let expenseModel = DocumentUploadViewModel(link: .financeDocument(UUID()), linkTitle: "Gider", projectId: f.project.id,
                                               access: access, repositories: f.repositories, store: f.store)
    XCTAssertEqual(expenseModel.kind, .fis, "giderde varsayılan tür fiş (birkaç dokunuşla yükleme)")
  }

  func testListFiltersAndSearchesAndShowsPendingUploads() async throws {
    let f = await DocFixture()
    await f.asAdmin()
    _ = try await f.upload(SampleFiles.pdf("1"), kind: .tutanak, title: "Beton döküm tutanağı")
    let ruhsat = try await f.upload(SampleFiles.pdf("2"), kind: .ruhsat, title: "Yapı ruhsatı")
    _ = try await f.upload(SampleFiles.pdf("3"), kind: .irsaliye, title: "Demir irsaliyesi", link: .project(f.other.id))
    _ = try await f.repositories.documents.archive(id: ruhsat.id, reason: "Süresi doldu")
    // Ağ yokken bekleyen bir yükleme.
    let pending = try await f.uploader.stage(data: SampleFiles.jpeg(), kind: .fis, title: "Fiş", description: nil,
                                             documentDate: f.today, link: .project(f.project.id), linkTitle: "Test")

    let access = AccessControl(grants: await f.backend.grants)
    let model = DocumentListViewModel(projectId: f.project.id, access: access, repositories: f.repositories,
                                      store: f.store, today: f.today)
    await model.load()
    XCTAssertEqual(model.documents.map(\.title), ["Beton döküm tutanağı"], "proje süzgeci ve etkin belgeler")
    XCTAssertEqual(model.visiblePending.map(\.id), [pending.id])
    model.scope = .arsiv
    await model.load()
    XCTAssertEqual(model.documents.map(\.title), ["Yapı ruhsatı"])
    model.scope = .etkin
    model.projectId = nil
    await model.load()
    model.searchText = "İRSALİYE"
    XCTAssertEqual(model.filtered.map(\.title), ["Demir irsaliyesi"], "Türkçe büyük/küçük harf duyarsız arama")
    model.searchText = ""
    model.kind = .tutanak
    await model.load()
    XCTAssertEqual(model.documents.count, 1)
  }

  func testDetailVerifiesDownloadedFileAgainstStoredDigest() async throws {
    let f = await DocFixture()
    await f.asAdmin()
    let doc = try await f.upload(SampleFiles.pdf(), kind: .tutanak, title: "Tutanak")
    let access = AccessControl(grants: await f.backend.grants)
    let model = DocumentDetailViewModel(document: doc, access: access, repositories: f.repositories, userId: f.admin.id)
    await model.load()
    await model.loadFile()
    XCTAssertEqual(model.integrity, .verified)
    XCTAssertEqual(model.events.map(\.action), ["rezerve", "yuklendi"])
    XCTAssertTrue(model.canManage)
    XCTAssertTrue(model.canRelink)

    // Depodaki içerik bozulursa kullanıcıya açıkça gösterilir.
    await f.backend.corrupt(path: doc.storagePath)
    await model.loadFile()
    XCTAssertEqual(model.integrity, .mismatch)
  }
}

extension InMemoryBackend {
  /// Test: depodaki nesneyi aynı boyutta bozar.
  func corrupt(path: String) {
    guard var object = storageObjects[path] else { return }
    object.data[object.data.count - 1] ^= 0xFF
    storageObjects[path] = object
  }
}
