import PhotosUI
import RDCore
import RDDesign
import SwiftUI
import UniformTypeIdentifiers

/// Belge ekleme: Tara / Fotoğraf seç / Dosya seç → önizleme → ad ve tür →
/// yükle. Dosya önce cihazda saklanır; ağ hatasında aynı kimlikle yeniden
/// denenir, ikinci belge oluşmaz.
struct DocumentAddView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: DocumentUploadViewModel
  @State private var scanning = false
  @State private var importing = false
  @State private var photoItem: PhotosPickerItem?
  @State private var isPreparing = false
  @State private var confirmDiscard = false
  private let onDone: (ArchiveDocument) -> Void

  init(link: DocumentLink, linkTitle: String, projectId: UUID?, app: AppModel, replacing: ArchiveDocument? = nil,
       onDone: @escaping (ArchiveDocument) -> Void = { _ in }) {
    _model = State(initialValue: DocumentUploadViewModel(link: link, linkTitle: linkTitle, projectId: projectId,
                                                         access: app.access, repositories: app.repositories,
                                                         store: app.documentStore, replacing: replacing))
    self.onDone = onDone
  }

  var body: some View {
    NavigationStack {
      Form {
        switch model.state {
        case .editing:
          if model.fileData == nil { sourceSection } else { previewSection; detailsSection }
        case .working(let step):
          progressSection(step)
        case .failed(let message):
          failedSection(message)
        case .done(let document):
          doneSection(document)
        }
      }
      .rdScreen()
      .navigationTitle(model.replacesId == nil ? "Belge ekle" : "Dosyayı değiştir")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbar }
      .interactiveDismissDisabled(model.isWorking)
      .fullScreenCover(isPresented: $scanning) { scanner }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .jpeg, .png]) { result in
        handleImport(result)
      }
      .onChange(of: photoItem) { _, item in
        guard let item else { return }
        Task { await loadPhoto(item) }
      }
      .confirmationDialog("Yüklemeden vazgeçilsin mi?", isPresented: $confirmDiscard, titleVisibility: .visible) {
        Button("Vazgeç ve cihazdaki kopyayı sil", role: .destructive) {
          Task {
            await model.discard()
            dismiss()
          }
        }
        Button("Sakla, sonra dene", role: .cancel) { dismiss() }
      } message: {
        Text("Saklarsanız dosya cihazda kalır; Belgeler ekranından yeniden deneyebilirsiniz.")
      }
    }
  }

  // MARK: Kaynak seçimi

  private var sourceSection: some View {
    Section {
      if DocumentScanner.isAvailable {
        Button { scanning = true } label: {
          Label("Tara", systemImage: "doc.viewfinder")
        }
        .buttonStyle(.rdPrimary)
        .listRowInsets(EdgeInsets(top: .rdS, leading: .rdM, bottom: .rdS, trailing: .rdM))
      }
      PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
        Label("Fotoğraf seç", systemImage: "photo.on.rectangle")
      }
      .buttonStyle(.rdSecondary)
      .listRowInsets(EdgeInsets(top: .rdS, leading: .rdM, bottom: .rdS, trailing: .rdM))
      Button { importing = true } label: {
        Label("Dosya seç (PDF)", systemImage: "folder")
      }
      .buttonStyle(.rdSecondary)
      .listRowInsets(EdgeInsets(top: .rdS, leading: .rdM, bottom: .rdS, trailing: .rdM))
      if isPreparing {
        ProgressView("Dosya hazırlanıyor…")
      }
      if let error = model.fileError {
        Label(error, systemImage: "exclamationmark.circle")
          .font(RDFont.secondary)
          .foregroundStyle(RDColor.tone(.danger))
      }
    } header: {
      Text(model.linkTitle).textCase(nil)
    } footer: {
      Text(sourceFooter)
    }
    .listRowBackground(Color.clear)
  }

  private var sourceFooter: String {
    let limits = "PDF, JPEG veya PNG; en çok \(DocumentLimits.maxBytes.fileSizeText)."
    return DocumentScanner.isAvailable ? "Çok sayfalı tarama tek PDF olarak kaydedilir. " + limits
      : "Bu cihazda belge tarayıcı yok; fotoğraf veya dosya seçin. " + limits
  }

  private var scanner: some View {
    DocumentScanner { pages in
      scanning = false
      isPreparing = true
      Task {
        let data = await Task.detached(priority: .userInitiated, operation: { DocumentCapture.pdf(from: pages) }).value
        isPreparing = false
        if let data {
          model.setFile(data, fileName: nil)
        } else {
          model.fileFailed(RepositoryError.validation("Taranan sayfalar PDF'e dönüştürülemedi; yeniden tarayın."))
        }
      }
    } onCancel: {
      scanning = false
    } onError: { message in
      scanning = false
      model.fileFailed(RepositoryError.validation(message))
    }
    .ignoresSafeArea()
  }

  private func handleImport(_ result: Result<URL, Error>) {
    switch result {
    case .success(let url):
      do {
        model.setFile(try DocumentCapture.read(url: url), fileName: url.lastPathComponent)
      } catch let error as RepositoryError {
        model.fileFailed(error)
      } catch {
        model.fileFailed(RepositoryError.validation("Dosya okunamadı. Dosyalar uygulamasında indirilmiş olduğundan emin olun."))
      }
    case .failure(let error):
      model.fileFailed(RepositoryError.validation("Dosya seçilemedi: \(error.localizedDescription)"))
    }
  }

  private func loadPhoto(_ item: PhotosPickerItem) async {
    isPreparing = true
    defer {
      isPreparing = false
      photoItem = nil
    }
    guard let raw = try? await item.loadTransferable(type: Data.self) else {
      model.fileFailed(RepositoryError.validation("Fotoğraf alınamadı. iCloud'daysa önce indirilmesini bekleyin."))
      return
    }
    guard let data = await Task.detached(priority: .userInitiated, operation: { DocumentCapture.normalizedImageData(raw) }).value
    else {
      model.fileFailed(RepositoryError.validation("Bu fotoğraf biçimi açılamadı."))
      return
    }
    model.setFile(data, fileName: nil)
  }

  // MARK: Önizleme ve bilgiler

  @ViewBuilder private var previewSection: some View {
    if let data = model.fileData, let type = model.fileType {
      Section {
        DocumentFilePreview(data: data, mimeType: type)
          .frame(height: 320)
          .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
          .listRowInsets(EdgeInsets())
        RDInfoRow(label: "Dosya", value: "\(type.title) · \(data.count.fileSizeText)")
        if model.replacesId == nil {
          Button("Başka dosya seç") { model.clearFile() }
        }
      }
      .rdRowBackground()
    }
  }

  private var detailsSection: some View {
    Group {
      Section {
        TextField("Belge adı", text: $model.title, prompt: Text("ör. Akaryakıt fişi"))
        if let error = model.titleError, !model.title.isEmpty {
          Text(error).font(RDFont.caption).foregroundStyle(RDColor.tone(.danger))
        }
        Picker("Tür", selection: $model.kind) {
          ForEach(model.allowedKinds) { kind in
            Label(kind.title, systemImage: kind.symbol).tag(kind)
          }
        }
        .disabled(model.replacesId != nil)
        DatePicker("Belge tarihi", selection: dateBinding, in: ...Date(), displayedComponents: .date)
        TextField("Açıklama (isteğe bağlı)", text: $model.description, axis: .vertical)
          .lineLimit(1...4)
      } footer: {
        Text("Bağlı olduğu yer: \(model.linkTitle). Belge eklemek tutarları, hakedişi veya ödeme durumunu değiştirmez.")
      }
      .rdRowBackground()
    }
  }

  private var dateBinding: Binding<Date> {
    Binding(get: { model.documentDate.date() }, set: { model.documentDate = CalendarDate($0) })
  }

  // MARK: Durumlar

  private func progressSection(_ step: DocumentUploadStep) -> some View {
    Section {
      VStack(alignment: .leading, spacing: .rdS) {
        ProgressView(value: step.fraction)
          .tint(RDColor.brand)
        Text(step.title).font(RDFont.body).foregroundStyle(RDColor.textPrimary)
        Text("Dosya cihazda saklandı; bağlantı kesilirse kaybolmaz.")
          .font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
      }
      .padding(.vertical, .rdS)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Yükleniyor: \(step.title)")
    }
    .rdRowBackground()
  }

  private func failedSection(_ message: String) -> some View {
    Section {
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(RDColor.tone(.danger))
      Button { Task { await model.retry() } } label: {
        Label("Tekrar dene", systemImage: "arrow.clockwise")
      }
      Button(role: .destructive) { confirmDiscard = true } label: {
        Label("Vazgeç", systemImage: "xmark")
      }
    } footer: {
      Text("Dosya cihazda saklı. Tekrar denemek aynı belgeyi tamamlar; ikinci kayıt oluşmaz.")
    }
    .rdRowBackground()
  }

  private func doneSection(_ document: ArchiveDocument) -> some View {
    Section {
      Label("\(document.title) yüklendi ve doğrulandı", systemImage: "checkmark.circle")
        .foregroundStyle(RDColor.tone(.success))
    }
    .rdRowBackground()
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      switch model.state {
      case .done: EmptyView()
      case .failed: Button("Kapat") { confirmDiscard = true }
      default: Button("Vazgeç") { dismiss() }.disabled(model.isWorking)
      }
    }
    ToolbarItem(placement: .confirmationAction) {
      switch model.state {
      case .editing:
        Button("Yükle") { Task { await submit() } }
          .fontWeight(.semibold)
          .disabled(!model.canSubmit)
      case .done(let document):
        Button("Bitti") {
          onDone(document)
          dismiss()
        }
        .fontWeight(.semibold)
      default:
        EmptyView()
      }
    }
  }

  private func submit() async {
    await model.submit()
    if case .done(let document) = model.state {
      onDone(document)
      dismiss()
    }
  }
}
