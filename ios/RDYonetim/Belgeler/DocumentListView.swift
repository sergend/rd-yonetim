import RDCore
import RDDesign
import SwiftUI

/// Belgeler ana listesi. Bağlantı verilirse (gider/gelir, sözleşme, proje)
/// yalnızca o kaydın belgeleri; verilmezse yetkili olunan tüm belgeler
/// proje, tür, tarih ve ada göre süzülür.
struct DocumentListView: View {
  let app: AppModel
  let linkTitle: String?
  @State private var model: DocumentListViewModel
  @State private var adding = false

  init(link: DocumentLink?, linkTitle: String?, projectId: UUID?, app: AppModel) {
    self.app = app
    self.linkTitle = linkTitle
    _model = State(initialValue: DocumentListViewModel(link: link, projectId: projectId, access: app.access,
                                                       repositories: app.repositories, store: app.documentStore))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.documents.isEmpty {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      filterSection
      if !model.visiblePending.isEmpty { pendingSection }
      Section {
        ForEach(model.filtered) { document in
          NavigationLink(value: AppRoute.archiveDocument(document)) {
            DocumentRow(document: document, place: place(of: document))
          }
        }
      } header: {
        if !model.filtered.isEmpty { Text("\(model.filtered.count) belge").textCase(nil) }
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(linkTitle ?? "Belgeler")
    .navigationBarTitleDisplayMode(model.link == nil ? .large : .inline)
    .searchable(text: $model.searchText, prompt: "Belge adı veya açıklama")
    .toolbar {
      if model.canAdd, let target = addTarget {
        Button { adding = true } label: { Label("Belge ekle", systemImage: "plus") }
          .accessibilityLabel("Belge ekle: \(target.title)")
      }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
    .onChange(of: model.filter) { _, _ in Task { await model.load() } }
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty && model.visiblePending.isEmpty,
                    error: model.errorMessage,
                    empty: .empty(title: model.searchText.isEmpty ? "Belge yok" : "Sonuç yok",
                                  message: emptyMessage, symbol: "doc.on.doc"),
                    retry: { Task { await model.load() } })
    .sheet(isPresented: $adding, onDismiss: { Task { await model.load() } }) {
      if let target = addTarget {
        DocumentAddView(link: target.link, linkTitle: target.title, projectId: target.projectId, app: app)
      }
    }
  }

  private var emptyMessage: String {
    if !model.searchText.isEmpty { return "Aramaya uyan belge bulunamadı." }
    return model.canAdd && addTarget != nil ? "Sağ üstteki + ile tarayın, fotoğraf veya PDF ekleyin." : "Bu seçimde belge yok."
  }

  /// Ekleme hedefi: sabit bağlantı ya da süzgeçte seçili proje.
  private var addTarget: (link: DocumentLink, title: String, projectId: UUID?)? {
    if let link = model.link { return (link, linkTitle ?? link.title, projectIdForLink) }
    if let projectId = model.projectId {
      return (.project(projectId), app.projectName(projectId) ?? "Proje", projectId)
    }
    return nil
  }

  private var projectIdForLink: UUID? {
    if case .project(let id) = model.link { return id }
    return model.projectId
  }

  private func place(of document: ArchiveDocument) -> String? {
    guard model.link == nil else { return nil }
    return app.projectName(document.projectId) ?? app.costCenterName(document.costCenterId).map { "Şirket geneli · \($0)" }
  }

  // MARK: Süzgeçler

  private var filterSection: some View {
    Section {
      Picker("Durum", selection: $model.scope) {
        ForEach(DocumentListViewModel.Scope.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
      Menu {
        if model.link == nil {
          Picker("Proje", selection: $model.projectId) {
            Text("Tüm projeler").tag(UUID?.none)
            ForEach(app.projects.filter { app.access.can(.belgeRead, in: $0.id) }) { project in
              Text(project.name).tag(Optional(project.id))
            }
          }
        }
        Picker("Tür", selection: $model.kind) {
          Text("Tüm türler").tag(ArchiveDocumentKind?.none)
          ForEach(ArchiveDocumentKind.allCases) { Label($0.title, systemImage: $0.symbol).tag(Optional($0)) }
        }
        Picker("Tarih", selection: $model.period) {
          ForEach(DocumentListViewModel.Period.allCases) { Text($0.title).tag($0) }
        }
      } label: {
        Label(filterSummary, systemImage: "line.3.horizontal.decrease.circle")
          .font(RDFont.secondary)
          .frame(minHeight: Metrics.minTouchTarget)
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
    }
  }

  private var filterSummary: String {
    var parts: [String] = []
    if model.link == nil { parts.append(app.projectName(model.projectId) ?? "Tüm projeler") }
    parts.append(model.kind?.title ?? "Tüm türler")
    parts.append(model.period.title)
    return parts.joined(separator: " · ")
  }

  // MARK: Bekleyen yüklemeler

  private var pendingSection: some View {
    Section {
      ForEach(model.visiblePending) { upload in
        PendingUploadRow(upload: upload, app: app) { await model.load() }
      }
    } header: {
      Text("Gönderilmeyi bekleyenler").textCase(nil)
    } footer: {
      Text("Bu dosyalar cihazda saklı. Tekrar denemek aynı belgeyi tamamlar; ikinci kayıt oluşmaz.")
    }
    .rdRowBackground()
  }
}

/// Liste satırı: tür simgesi, ad, tarih ve yer, durum.
struct DocumentRow: View {
  let document: ArchiveDocument
  var place: String?

  var body: some View {
    RDRow(symbol: document.kind.symbol, symbolTint: RDColor.brandText, title: document.title,
          subtitle: subtitle) {
      if document.isDemo { RDDemoBadge() }
    } trailing: {
      if document.status != .yuklendi {
        RDStatusBadge(text: document.status.title, tone: document.status.tone)
      }
    }
  }

  private var subtitle: String {
    [document.kind.title, document.documentDate.display, place].compactMap { $0 }.joined(separator: " · ")
  }
}

/// Gönderilemeyen yükleme: tekrar dene veya vazgeç.
struct PendingUploadRow: View {
  @State private var model: PendingUploadViewModel
  @State private var working = false
  @State private var confirmDiscard = false
  private let onChange: () async -> Void

  init(upload: PendingUpload, app: AppModel, onChange: @escaping () async -> Void) {
    _model = State(initialValue: PendingUploadViewModel(upload: upload, repositories: app.repositories,
                                                        store: app.documentStore))
    self.onChange = onChange
  }

  var body: some View {
    VStack(alignment: .leading, spacing: .rdS) {
      RDRow(symbol: model.upload.request.kind.symbol, symbolTint: RDColor.tone(.warning),
            title: model.upload.request.title,
            subtitle: "\(model.upload.linkTitle) · \(model.upload.request.byteSize.fileSizeText)") {
        RDStatusBadge(text: "Gönderilmedi", tone: .warning)
      } trailing: {
        EmptyView()
      }
      if let step = model.step {
        ProgressView(value: step.fraction) { Text(step.title).font(RDFont.caption) }
          .tint(RDColor.brand)
      } else if let error = model.errorMessage {
        Text(error).font(RDFont.caption).foregroundStyle(RDColor.tone(.danger))
      }
      HStack(spacing: .rdM) {
        Button {
          Task {
            working = true
            await model.retry()
            working = false
            if model.completed != nil { await onChange() }
          }
        } label: {
          Label("Tekrar dene", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        Spacer()
        Button(role: .destructive) { confirmDiscard = true } label: {
          Label("Vazgeç", systemImage: "trash")
        }
        .buttonStyle(.borderless)
      }
      .font(RDFont.secondary.weight(.semibold))
      .disabled(working)
    }
    .confirmationDialog("Bu dosya gönderilmeden silinsin mi?", isPresented: $confirmDiscard, titleVisibility: .visible) {
      Button("Cihazdaki kopyayı sil", role: .destructive) {
        Task {
          await model.discard()
          await onChange()
        }
      }
    } message: {
      Text("Sunucuda yarım kalan kayıt iptal edilir. Dosyanın başka kopyası yoksa geri alınamaz.")
    }
  }
}

/// Gider/gelir, sözleşme ve proje detaylarında belge bölümü: son belgeler,
/// "Tümü" ve "Belge ekle".
struct LinkedDocumentsSection: View {
  let link: DocumentLink
  let linkTitle: String
  let projectId: UUID?
  let app: AppModel
  @State private var documents: [ArchiveDocument] = []
  @State private var pendingCount = 0
  @State private var errorMessage: String?
  @State private var adding = false
  private let limit = 3

  private var canAdd: Bool {
    projectId.map { app.access.can(.belgeWrite, in: $0) } ?? app.access.canAnywhere(.belgeWrite)
  }

  var body: some View {
    Section {
      if let errorMessage {
        Text(errorMessage).font(RDFont.secondary).foregroundStyle(RDColor.tone(.danger))
      } else if documents.isEmpty && pendingCount == 0 {
        Text("Bağlı belge yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(documents.prefix(limit)) { document in
        NavigationLink(value: AppRoute.archiveDocument(document)) { DocumentRow(document: document) }
      }
      if documents.count > limit || pendingCount > 0 {
        NavigationLink(value: AppRoute.documents(link: link, title: linkTitle, projectId: projectId)) {
          Text(pendingCount > 0 ? "Tüm belgeler · \(pendingCount) gönderilmedi" : "Tüm belgeler (\(documents.count))")
        }
      }
      if canAdd {
        Button { adding = true } label: { Label("Belge ekle", systemImage: "doc.badge.plus") }
      }
    } header: {
      RDSectionHeader(title: "Belgeler")
    } footer: {
      Text("Belge eklemek tutarı, hakedişi veya ödeme durumunu değiştirmez.")
    }
    .rdRowBackground()
    .task { await load() }
    .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) {
      DocumentAddView(link: link, linkTitle: linkTitle, projectId: projectId, app: app)
    }
  }

  private func load() async {
    do {
      documents = try await app.repositories.documents.documents(filter: DocumentFilter(link: link))
      errorMessage = nil
    } catch {
      errorMessage = message(for: error)
    }
    pendingCount = await app.documentStore.all().filter { $0.request.link == link }.count
  }
}
