import RDCore
import RDDesign
import SwiftUI

// MARK: - Liste

struct PersonnelListView: View {
  let app: AppModel
  @State private var model: PersonnelListViewModel
  @State private var showingForm = false

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: PersonnelListViewModel(access: app.access, repository: app.repositories.workforce))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.people.isEmpty {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ForEach(model.filtered) { person in
          NavigationLink(value: AppRoute.personnel(person)) {
            PersonnelRow(person: person, subcontractorName: model.subcontractorName(person.subcontractorId))
          }
        }
      } header: {
        Text(model.employmentFilter?.title ?? "Tüm personel")
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Personel yok",
                                  message: model.canCreate ? "Sağ üstteki + ile personel ekleyin."
                                                           : "Görevli olduğunuz projelerde kayıtlı personel yok.",
                                  symbol: AppModule.personel.symbol),
                    retry: { Task { await model.load() } })
    .searchable(text: $model.searchText, prompt: "Ad, görev veya taşeron")
    .navigationTitle("Personel")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) { filterMenu }
      if model.canCreate {
        ToolbarItem(placement: .primaryAction) {
          Button("Yeni personel", systemImage: "plus") { showingForm = true }
        }
      }
    }
    .sheet(isPresented: $showingForm) {
      PersonnelFormView(model: PersonnelFormViewModel(repository: app.repositories.workforce), showsPhone: true) {
        model.upsert($0)
      }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
  }

  private var filterMenu: some View {
    Menu {
      Picker("Çalışma ilişkisi", selection: $model.employmentFilter) {
        Text("Tüm personel").tag(EmploymentType?.none)
        ForEach(EmploymentType.allCases) { Text($0.title).tag(Optional($0)) }
      }
      Toggle("Pasif kayıtları göster", isOn: $model.showInactive)
    } label: {
      Label("Filtre", systemImage: "line.3.horizontal.decrease.circle")
    }
  }
}

struct PersonnelRow: View {
  let person: Personnel
  var subcontractorName: String?

  var body: some View {
    RDRow(symbol: "person.crop.circle", title: person.fullName, subtitle: subtitle) {
      RecordBadges(isActive: person.isActive, isDemo: person.isDemo)
    } trailing: {
      EmptyView()
    }
  }

  private var subtitle: String {
    var parts = [person.jobTitle ?? person.trade?.title].compactMap { $0 }
    parts.append(subcontractorName ?? person.employmentType.title)
    return parts.joined(separator: " · ")
  }
}

// MARK: - Detay

struct PersonnelDetailView: View {
  let app: AppModel
  @State private var model: PersonnelDetailViewModel
  @State private var editing = false

  init(person: Personnel, app: AppModel) {
    self.app = app
    _model = State(initialValue: PersonnelDetailViewModel(person: person, access: app.access,
                                                          repository: app.repositories.workforce))
  }

  var body: some View {
    let person = model.person
    List {
      if let error = model.errorMessage {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        RecordHeader(title: person.fullName, subtitle: person.jobTitle) {
          RDStatusBadge(text: person.employmentType.title, tone: person.employmentType.tone)
          RecordBadges(isActive: person.isActive, isDemo: person.isDemo)
        }
      }
      .rdRowBackground()

      if model.canSeeContact {
        Section("İletişim") {
          if let phone = model.phone {
            PhoneRow(phone: phone)
          } else {
            Text("Telefon kayıtlı değil.").foregroundStyle(RDColor.textSecondary)
          }
        }
        .rdRowBackground()
      }

      Section("Çalışma") {
        RDInfoRow(label: "Çalışma ilişkisi", value: person.employmentType.title)
        if let sub = model.subcontractor {
          NavigationLink(value: AppRoute.subcontractor(sub)) {
            RDInfoRow(label: "Taşeron", value: sub.name)
          }
        }
        if let trade = person.trade { RDInfoRow(label: "İş kolu", value: trade.title) }
        if let notes = person.notes { RDInfoRow(label: "Not", value: notes) }
      }
      .rdRowBackground()

      Section {
        if model.memberships.isEmpty {
          Text("Ekip üyeliği yok.").foregroundStyle(RDColor.textSecondary)
        }
        ForEach(model.memberships) { membership in
          RDRow(symbol: AppModule.ekipler.symbol, title: model.crewName(membership.crewId),
                subtitle: [membership.roleTitle, membership.period.display].compactMap { $0 }
                  .joined(separator: " · ")) {
            PeriodBadge(period: membership.period)
          }
        }
      } header: {
        Text("Ekip geçmişi")
      } footer: {
        Text("Kişi aynı anda yalnızca bir ekipte olabilir; eski üyelikler silinmez.")
      }
      .rdRowBackground()

      if model.canSeeAssignments {
        Section("Proje görevlendirmeleri") {
          if model.assignments.isEmpty {
            Text("Görebildiğiniz projelerde doğrudan görevlendirme yok.").foregroundStyle(RDColor.textSecondary)
          }
          ForEach(model.assignments) { assignment in
            RDRow(symbol: AppModule.projeler.symbol, title: app.projectName(assignment.projectId) ?? "Proje",
                  subtitle: [assignment.period.display, assignment.description].compactMap { $0 }
                    .joined(separator: " · ")) {
              PeriodBadge(period: assignment.period)
            }
          }
        }
        .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(person.fullName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.canEdit { Button("Düzenle") { editing = true } }
    }
    .sheet(isPresented: $editing) {
      PersonnelFormView(model: PersonnelFormViewModel(editing: person, phone: model.phone,
                                                      repository: app.repositories.workforce),
                        showsPhone: model.canSeeContact) { saved in
        model.didSave(saved)
        Task { await model.load() }
      }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
  }
}

// MARK: - Form

struct PersonnelFormView: View {
  @State var model: PersonnelFormViewModel
  /// İletişim izni olmayan düzenleyici telefonu görmez ve değiştiremez.
  let showsPhone: Bool
  let onSaved: (Personnel) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Ad soyad", text: $model.fullName)
            .textContentType(.name)
          TextField("Görevi (ör. kalıp ustası)", text: $model.jobTitle)
          TradePicker(selection: $model.trade)
        }
        .rdRowBackground()

        Section {
          Picker("Çalışma ilişkisi", selection: $model.employmentType) {
            ForEach(EmploymentType.allCases) { Text($0.title).tag($0) }
          }
          if model.employmentType == .taseron {
            Picker("Taşeron", selection: $model.subcontractorId) {
              Text("Seçin").tag(UUID?.none)
              ForEach(model.subcontractorOptions) { Text($0.name).tag(Optional($0.id)) }
            }
          }
        } header: {
          Text("Çalışma ilişkisi")
        } footer: {
          Text("Taşeron personeli yalnızca kendi taşeronunun ekiplerine katılabilir.")
        }
        .rdRowBackground()

        if showsPhone {
          Section {
            TextField("Telefon", text: $model.phone)
              .keyboardType(.phonePad)
              .textContentType(.telephoneNumber)
          } header: {
            Text("İletişim")
          } footer: {
            Text("Telefon yalnızca iletişim yetkisi olan kullanıcılara görünür. TC kimlik, banka ve adres bilgisi tutulmaz.")
          }
          .rdRowBackground()
        }

        Section {
          TextField("Not", text: $model.notes, axis: .vertical).lineLimit(2...5)
          Toggle("Aktif", isOn: $model.isActive)
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
