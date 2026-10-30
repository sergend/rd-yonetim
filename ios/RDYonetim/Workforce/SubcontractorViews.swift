import RDCore
import RDDesign
import SwiftUI

// MARK: - Liste

struct SubcontractorListView: View {
  let app: AppModel
  @State private var model: SubcontractorListViewModel
  @State private var showingForm = false

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: SubcontractorListViewModel(access: app.access, repository: app.repositories.workforce))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.items.isEmpty {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ForEach(model.filtered) { item in
          NavigationLink(value: AppRoute.subcontractor(item)) { SubcontractorRow(subcontractor: item) }
        }
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Taşeron yok",
                                  message: model.canCreate ? "Sağ üstteki + ile ilk taşeronu ekleyin."
                                                           : "Görebileceğiniz taşeron kaydı yok.",
                                  symbol: AppModule.taseronlar.symbol),
                    retry: { Task { await model.load() } })
    .searchable(text: $model.searchText, prompt: "Ad, iş kolu veya yetkili")
    .navigationTitle("Taşeronlar")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) { InactiveFilterMenu(showInactive: $model.showInactive) }
      if model.canCreate {
        ToolbarItem(placement: .primaryAction) {
          Button("Yeni taşeron", systemImage: "plus") { showingForm = true }
        }
      }
    }
    .sheet(isPresented: $showingForm) {
      SubcontractorFormView(model: SubcontractorFormViewModel(access: app.access, repositories: app.repositories)) {
        model.upsert($0)
      }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
  }
}

struct SubcontractorRow: View {
  let subcontractor: Subcontractor

  var body: some View {
    RDRow(symbol: AppModule.taseronlar.symbol, symbolTint: RDColor.brandText, title: subcontractor.name,
          subtitle: [subcontractor.trade?.title, subcontractor.contactName].compactMap { $0 }.joined(separator: " · ")) {
      RecordBadges(isActive: subcontractor.isActive, isDemo: subcontractor.isDemo)
    } trailing: {
      if subcontractor.cariAccountId != nil {
        Image(systemName: "link")
          .font(RDFont.caption)
          .foregroundStyle(RDColor.textSecondary)
          .accessibilityLabel("Cari karta bağlı")
      }
    }
  }
}

// MARK: - Detay

struct SubcontractorDetailView: View {
  let app: AppModel
  @State private var model: SubcontractorDetailViewModel
  @State private var editing = false
  @State private var addingDocument = false
  @State private var addingProject = false

  init(subcontractor: Subcontractor, app: AppModel) {
    self.app = app
    _model = State(initialValue: SubcontractorDetailViewModel(subcontractor: subcontractor, access: app.access,
                                                              repositories: app.repositories))
  }

  private var linkableProjects: [Project] { model.linkableProjects(app.projects) }

  var body: some View {
    let item = model.subcontractor
    List {
      if let error = model.errorMessage {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        RecordHeader(title: item.name, subtitle: item.trade.map { "İş kolu: \($0.title)" }) {
          RDStatusBadge(text: "Taşeron", tone: .info)
          RecordBadges(isActive: item.isActive, isDemo: item.isDemo)
        }
      }
      .rdRowBackground()

      if item.contactName != nil || item.phone != nil || item.email != nil {
        Section("İletişim") {
          if let contact = item.contactName { RDInfoRow(label: "Yetkili", value: contact) }
          if let phone = item.phone { PhoneRow(phone: phone) }
          if let email = item.email { RDInfoRow(label: "E-posta", value: email, selectable: true) }
        }
        .rdRowBackground()
      }

      cariSection(item)
      projectsSection
      if !model.crews.isEmpty || model.canManagePeople { crewsSection }
      if !model.people.isEmpty || model.canManagePeople { peopleSection }
      documentsSection

      if let notes = item.notes {
        Section("Not") { Text(notes).font(RDFont.body).foregroundStyle(RDColor.textPrimary) }
          .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(item.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.canEdit { Button("Düzenle") { editing = true } }
    }
    .sheet(isPresented: $editing) {
      SubcontractorFormView(model: SubcontractorFormViewModel(editing: item, access: app.access,
                                                              repositories: app.repositories)) { saved in
        model.didSave(saved)
        Task { await model.load() }
      }
    }
    .sheet(isPresented: $addingDocument) { DocumentFormSheet(model: model) }
    .sheet(isPresented: $addingProject) { SubcontractorProjectSheet(model: model, projects: linkableProjects) }
    .refreshable { await model.load() }
    .task { await model.load() }
  }

  @ViewBuilder
  private func cariSection(_ item: Subcontractor) -> some View {
    Section {
      if let cari = model.cariAccount {
        NavigationLink(value: AppRoute.cari(cari)) {
          RDRow(symbol: AppModule.cari.symbol, symbolTint: RDColor.brandText, title: cari.title,
                subtitle: "\(cari.code) · \(cari.type.title)")
        }
      } else if item.cariAccountId != nil {
        Label("Bir cari karta bağlı. Finans bilgisini görme yetkiniz yok.", systemImage: "lock")
          .font(RDFont.secondary)
          .foregroundStyle(RDColor.textSecondary)
      } else {
        Label("Henüz bir cari karta bağlı değil.", systemImage: "link.badge.plus")
          .font(RDFont.secondary)
          .foregroundStyle(RDColor.textSecondary)
      }
    } header: {
      Text("Cari hesap")
    } footer: {
      Text("Vergi numarası, IBAN ve bakiye cari kartta tutulur; taşeron için ikinci bir finansal kayıt açılmaz.")
    }
    .rdRowBackground()
  }

  private var projectsSection: some View {
    Section {
      if model.projectLinks.isEmpty {
        Text("Kayıtlı proje yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.projectLinks) { link in
        RDRow(symbol: AppModule.projeler.symbol, title: app.projectName(link.projectId) ?? "Proje",
              subtitle: [link.period.display, link.scope].compactMap { $0 }.joined(separator: " · ")) {
          PeriodBadge(period: link.period)
        }
        .swipeActions(edge: .trailing) {
          if model.canEnd(link) {
            Button("Bugün bitir") { Task { await model.end(link) } }.tint(RDColor.tone(.warning))
          }
        }
      }
      if !linkableProjects.isEmpty {
        Button("Projeye kaydet", systemImage: "plus") { addingProject = true }
          .foregroundStyle(RDColor.brandText)
          .frame(minHeight: Metrics.minTouchTarget)
      }
    } header: {
      Text("Çalıştığı projeler")
    }
    .rdRowBackground()
  }

  private var crewsSection: some View {
    Section("Ekipler") {
      if model.crews.isEmpty {
        Text("Bu taşerona bağlı ekip yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.crews) { crew in
        NavigationLink(value: AppRoute.crew(crew)) {
          RDRow(symbol: AppModule.ekipler.symbol, title: crew.name, subtitle: crew.trade?.title) {
            RecordBadges(isActive: crew.isActive, isDemo: crew.isDemo)
          } trailing: {
            EmptyView()
          }
        }
      }
    }
    .rdRowBackground()
  }

  private var peopleSection: some View {
    Section("Personel") {
      if model.people.isEmpty {
        Text("Bu taşerona bağlı personel kaydı yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.people) { person in
        NavigationLink(value: AppRoute.personnel(person)) {
          RDRow(symbol: "person.crop.circle", title: person.fullName, subtitle: person.jobTitle)
        }
      }
    }
    .rdRowBackground()
  }

  private var documentsSection: some View {
    Section {
      if model.documents.isEmpty {
        Text("Belge kaydı yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.documents) { document in
        RDRow(symbol: "doc.text", title: document.title,
              subtitle: [document.documentNo, document.validUntil.map { "Geçerlilik: \($0.display)" }]
                .compactMap { $0 }.joined(separator: " · ")) {
          if document.isExpired() { RDStatusBadge(text: "Süresi doldu", tone: .danger) }
        }
      }
      if model.canEdit {
        Button("Belge ekle", systemImage: "plus") { addingDocument = true }
          .foregroundStyle(RDColor.brandText)
          .frame(minHeight: Metrics.minTouchTarget)
      }
    } header: {
      Text("Belgeler")
    } footer: {
      Text("Şimdilik belge bilgisi ve geçerlilik tarihi tutulur; dosya ekleme sonraki aşamada.")
    }
    .rdRowBackground()
  }
}

// MARK: - Formlar

struct SubcontractorFormView: View {
  @State var model: SubcontractorFormViewModel
  let onSaved: (Subcontractor) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Ad veya firma unvanı", text: $model.name)
          TradePicker(selection: $model.trade)
          Toggle("Aktif", isOn: $model.isActive)
        }
        .rdRowBackground()

        Section {
          if model.canLinkCari {
            Picker("Cari kart", selection: $model.cariAccountId) {
              Text("Bağlı değil").tag(UUID?.none)
              ForEach(model.cariOptions) { Text("\($0.title) (\($0.code))").tag(Optional($0.id)) }
            }
          } else {
            Text("Cari kart bağlantısını cari hesaplara erişimi olan kullanıcı yapar.")
              .font(RDFont.secondary)
              .foregroundStyle(RDColor.textSecondary)
          }
        } header: {
          Text("Cari hesap")
        } footer: {
          Text("Firmanın cari kartı varsa seçin. Aynı cari kart ikinci bir taşerona bağlanamaz.")
        }
        .rdRowBackground()

        Section("İletişim") {
          TextField("Yetkili kişi", text: $model.contactName)
          TextField("Telefon", text: $model.phone).keyboardType(.phonePad)
          TextField("E-posta", text: $model.email)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .rdRowBackground()

        Section("Not") {
          TextField("Not", text: $model.notes, axis: .vertical).lineLimit(2...5)
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage ?? model.validationMessage)
      }
      .rdScreen()
      .navigationTitle(model.formTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetToolbar(confirmTitle: "Kaydet", canConfirm: model.canSave, onCancel: { dismiss() }) {
          Task {
            if let saved = await model.save() {
              onSaved(saved)
              dismiss()
            }
          }
        }
      }
      .interactiveDismissDisabled(model.isSaving)
      .task { await model.loadOptions() }
    }
  }
}

private struct DocumentFormSheet: View {
  let model: SubcontractorDetailViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var documentNo = ""
  @State private var hasValidUntil = false
  @State private var validUntil = Date()

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Belge adı (ör. vergi levhası)", text: $title)
          TextField("Belge numarası", text: $documentNo)
          Toggle("Geçerlilik tarihi", isOn: $hasValidUntil)
          if hasValidUntil {
            DatePicker("Geçerli olduğu son gün", selection: $validUntil, displayedComponents: .date)
          }
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle("Belge ekle")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetToolbar(confirmTitle: "Ekle", canConfirm: title.nilIfBlank != nil, onCancel: { dismiss() }) {
          Task {
            if await model.addDocument(title: title, documentNo: documentNo,
                                       validUntil: hasValidUntil ? CalendarDate(validUntil) : nil) {
              dismiss()
            }
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

private struct SubcontractorProjectSheet: View {
  let model: SubcontractorDetailViewModel
  let projects: [Project]
  @Environment(\.dismiss) private var dismiss
  @State private var projectId: UUID?
  @State private var start = Date()
  @State private var scope = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Proje", selection: $projectId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
          }
          DatePicker("Başlangıç", selection: $start, displayedComponents: .date)
          TextField("İş kapsamı (ör. kaba inşaat)", text: $scope)
        } footer: {
          Text("Kayıt yalnızca taşeronun projede çalıştığını gösterir; borç veya hakediş oluşturmaz.")
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle("Projeye kaydet")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetToolbar(confirmTitle: "Kaydet", canConfirm: projectId != nil, onCancel: { dismiss() }) {
          guard let projectId else { return }
          Task {
            if await model.addProject(projectId, start: CalendarDate(start), scope: scope) { dismiss() }
          }
        }
      }
      .onAppear { if projects.count == 1 { projectId = projects.first?.id } }
    }
    .presentationDetents([.medium, .large])
  }
}
