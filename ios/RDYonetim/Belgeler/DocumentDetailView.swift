import RDCore
import RDDesign
import SwiftUI

/// Belge ayrıntısı: önizleme (PDF/fotoğraf, yakınlaştırma), bütünlük
/// doğrulaması (SHA-256), bilgiler, geçmiş; arşiv, iptal, dosya değiştirme
/// ve bağlantı düzeltme. Hiçbir işlem kaydı silmez; geçmiş korunur.
struct DocumentDetailView: View {
  let app: AppModel
  @State private var model: DocumentDetailViewModel
  @State private var sheet: Sheet?
  @State private var fullScreen = false

  enum Sheet: String, Identifiable {
    case archive, cancel, replace, relink
    var id: String { rawValue }
  }

  init(document: ArchiveDocument, app: AppModel) {
    self.app = app
    _model = State(initialValue: DocumentDetailViewModel(document: document, access: app.access,
                                                         repositories: app.repositories, userId: app.userId))
  }

  private var document: ArchiveDocument { model.document }

  var body: some View {
    List {
      if let error = model.errorMessage {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      previewSection
      infoSection
      actionsSection
      historySection
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(document.kind.title)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await model.load() }
    .task {
      await model.load()
      if model.fileData == nil { await model.loadFile() }
    }
    .disabled(model.isWorking)
    .sheet(item: $sheet) { sheetView($0) }
    .fullScreenCover(isPresented: $fullScreen) { fullScreenViewer }
  }

  // MARK: Önizleme

  private var previewSection: some View {
    Section {
      if !document.hasFile {
        Text(document.status == .iptal ? "İptal edilen yüklemenin dosyası yok." : "Dosya henüz yüklenmedi.")
          .foregroundStyle(RDColor.textSecondary)
      } else if let data = model.fileData {
        Button { fullScreen = true } label: {
          DocumentFilePreview(data: data, mimeType: document.mimeType)
            .frame(height: 340)
            .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Belgeyi tam ekran aç")
        .listRowInsets(EdgeInsets())
        integrityRow
      } else if model.isLoadingFile {
        ProgressView("Dosya indiriliyor…").frame(maxWidth: .infinity, minHeight: 120)
      } else if let error = model.fileError {
        VStack(alignment: .leading, spacing: .rdS) {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(RDColor.tone(.danger))
          Button("Tekrar dene") { Task { await model.loadFile() } }
        }
      }
    }
    .rdRowBackground()
  }

  @ViewBuilder private var integrityRow: some View {
    switch model.integrity {
    case .verified:
      Label("Dosya doğrulandı (SHA-256 eşleşti)", systemImage: "checkmark.shield")
        .font(RDFont.secondary).foregroundStyle(RDColor.tone(.success))
    case .mismatch:
      Label("Dosya kayıtla eşleşmiyor; bozulmuş olabilir. Yöneticiye bildirin.", systemImage: "exclamationmark.shield")
        .font(RDFont.secondary).foregroundStyle(RDColor.tone(.danger))
    case .unknown:
      EmptyView()
    }
  }

  private var fullScreenViewer: some View {
    NavigationStack {
      Group {
        if let data = model.fileData {
          DocumentFilePreview(data: data, mimeType: document.mimeType)
        }
      }
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle(document.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Kapat") { fullScreen = false } }
      }
    }
  }

  // MARK: Bilgiler

  private var infoSection: some View {
    Section {
      RDRow(symbol: document.kind.symbol, symbolTint: RDColor.brandText, title: document.title,
            subtitle: document.kind.title) {
        if document.isDemo { RDDemoBadge() }
      } trailing: {
        RDStatusBadge(text: document.status.title, tone: document.status.tone)
      }
      RDInfoRow(label: "Bağlantı", value: linkText)
      RDInfoRow(label: "Belge tarihi", value: document.documentDate.display)
      if let description = document.description { RDInfoRow(label: "Açıklama", value: description) }
      RDInfoRow(label: "Dosya", value: "\(document.mimeType.title) · \(document.byteSize.fileSizeText)")
      if let uploadedAt = document.uploadedAt {
        RDInfoRow(label: "Yüklenme", value: uploadedAt.formatted(dateTimeStyle))
      }
      if let reason = document.archiveReason { RDInfoRow(label: "Arşiv gerekçesi", value: reason) }
      if let reason = document.cancelReason { RDInfoRow(label: "İptal gerekçesi", value: reason) }
      RDInfoRow(label: "SHA-256", value: String(document.sha256.prefix(16)) + "…", selectable: true)
    }
    .rdRowBackground()
  }

  private var dateTimeStyle: Date.FormatStyle {
    .dateTime.day().month(.abbreviated).year().hour().minute().locale(Money.locale)
  }

  private var linkText: String {
    let place = app.projectName(document.projectId)
      ?? app.costCenterName(document.costCenterId).map { "Şirket geneli · \($0)" }
    switch document.linkType {
    case .proje, .masrafMerkezi: return place ?? document.linkType.displayTitle
    case .finansBelgesi, .sozlesme: return [document.linkType.displayTitle, place].compactMap { $0 }.joined(separator: " · ")
    }
  }

  // MARK: İşlemler

  @ViewBuilder private var actionsSection: some View {
    if model.canManage || model.canRelink {
      Section {
        if model.canReplace {
          Button { sheet = .replace } label: { Label("Dosyayı değiştir (yanlış yükleme)", systemImage: "arrow.triangle.2.circlepath") }
        }
        if model.canRelink && (document.linkType == .proje || document.linkType == .masrafMerkezi) {
          Button { sheet = .relink } label: { Label("Bağlantıyı düzelt", systemImage: "link") }
        }
        if model.canManage && document.status == .yuklendi {
          Button { sheet = .archive } label: { Label("Arşivle", systemImage: "archivebox") }
        }
        if model.canManage {
          Button(role: .destructive) { sheet = .cancel } label: { Label("İptal et", systemImage: "xmark.circle") }
        }
      } footer: {
        Text("Hiçbir işlem belgeyi silmez; eski dosya ve geçmiş saklanır. Onaylı gider/gelirin belgesini yalnızca belge yöneticisi değiştirebilir.")
      }
      .rdRowBackground()
    }
  }

  private var historySection: some View {
    Section("Geçmiş") {
      if model.events.isEmpty {
        Text("Kayıt yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.events) { event in
        VStack(alignment: .leading, spacing: 2) {
          Text(event.title).font(RDFont.body).foregroundStyle(RDColor.textPrimary)
          Text(event.occurredAt.formatted(dateTimeStyle)).font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          if let reason = event.reason {
            Text("Gerekçe: \(reason)").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
    .rdRowBackground()
  }

  @ViewBuilder private func sheetView(_ sheet: Sheet) -> some View {
    switch sheet {
    case .archive:
      ReasonSheet(title: "Belgeyi arşivle", message: "Belge etkin listeden kalkar, Arşiv sekmesinde görünür.",
                  actionTitle: "Arşivle", minimumLength: 3) { reason in
        await model.archive(reason: reason)
      }
    case .cancel:
      ReasonSheet(title: "Belgeyi iptal et",
                  message: "Belge iptal olarak işaretlenir; dosya ve geçmiş silinmez.",
                  actionTitle: "İptal et", destructive: true) { reason in
        await model.cancel(reason: reason)
      }
    case .replace:
      DocumentAddView(link: document.link, linkTitle: linkText, projectId: document.projectId, app: app,
                      replacing: document) { _ in
        Task { await model.load() }
      }
    case .relink:
      DocumentRelinkSheet(document: document, app: app) { link, reason in
        await model.relink(to: link, reason: reason)
      }
    }
  }
}

extension DocumentLinkType {
  var displayTitle: String {
    switch self {
    case .proje: "Proje"
    case .masrafMerkezi: "Şirket geneli"
    case .finansBelgesi: "Gider / gelir kaydı"
    case .sozlesme: "Taşeron sözleşmesi"
    }
  }
}

/// Yanlış projeye eklenen belgeyi doğru proje veya masraf merkezine taşır
/// (gerekçe zorunlu, geçmişe yazılır). Demo ve gerçek kayıtlar arasında taşınmaz.
struct DocumentRelinkSheet: View {
  let document: ArchiveDocument
  let app: AppModel
  let action: (DocumentLink, String) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var useProject = true
  @State private var projectId: UUID?
  @State private var costCenterId: UUID?
  @State private var reason = ""
  @State private var isWorking = false

  private var target: DocumentLink? {
    if useProject { return projectId.map(DocumentLink.project) }
    return costCenterId.map(DocumentLink.costCenter)
  }

  private var canConfirm: Bool {
    guard let target, target != document.link else { return false }
    return reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 && !isWorking
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Yeni yer", selection: $useProject) {
            Text("Proje").tag(true)
            Text("Şirket geneli").tag(false)
          }
          .pickerStyle(.segmented)
          if useProject {
            Picker("Proje", selection: $projectId) {
              Text("Seçin").tag(UUID?.none)
              ForEach(app.projects.filter { $0.isDemo == document.isDemo && app.access.can(.belgeWrite, in: $0.id) }) {
                Text($0.name).tag(Optional($0.id))
              }
            }
          } else {
            Picker("Masraf merkezi", selection: $costCenterId) {
              Text("Seçin").tag(UUID?.none)
              ForEach(app.costCenters) { Text($0.name).tag(Optional($0.id)) }
            }
          }
        }
        .rdRowBackground()
        Section {
          TextField("Gerekçe", text: $reason, axis: .vertical).lineLimit(3...6)
        } footer: {
          Text("Eski ve yeni bağlantı geçmişe yazılır. En az 10 karakter.")
        }
        .rdRowBackground()
      }
      .rdScreen()
      .navigationTitle("Bağlantıyı düzelt")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetToolbar(confirmTitle: "Taşı", canConfirm: canConfirm, onCancel: { dismiss() }) {
          guard let target else { return }
          isWorking = true
          Task {
            let ok = await action(target, reason.trimmingCharacters(in: .whitespacesAndNewlines))
            isWorking = false
            if ok { dismiss() }
          }
        }
      }
    }
  }
}
