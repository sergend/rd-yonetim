import RDCore
import RDDesign
import SwiftUI

// MARK: - Liste

struct CrewListView: View {
  let app: AppModel
  @State private var model: CrewListViewModel
  @State private var showingForm = false

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: CrewListViewModel(access: app.access, repository: app.repositories.workforce))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.crews.isEmpty {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ForEach(model.filtered) { crew in
          NavigationLink(value: AppRoute.crew(crew)) {
            RDRow(symbol: AppModule.ekipler.symbol, symbolTint: RDColor.brandText, title: crew.name,
                  subtitle: subtitle(crew)) {
              RecordBadges(isActive: crew.isActive, isDemo: crew.isDemo)
            } trailing: {
              EmptyView()
            }
          }
        }
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .rdContentState(isLoading: model.isLoading, isEmpty: model.filtered.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Ekip yok",
                                  message: model.canCreate ? "Sağ üstteki + ile kalıp, demir, elektrik gibi ekipleri tanımlayın."
                                                           : "Görevli olduğunuz projelerde ekip yok.",
                                  symbol: AppModule.ekipler.symbol),
                    retry: { Task { await model.load() } })
    .searchable(text: $model.searchText, prompt: "Ekip, iş kolu veya taşeron")
    .navigationTitle("Ekipler")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) { InactiveFilterMenu(showInactive: $model.showInactive) }
      if model.canCreate {
        ToolbarItem(placement: .primaryAction) {
          Button("Yeni ekip", systemImage: "plus") { showingForm = true }
        }
      }
    }
    .sheet(isPresented: $showingForm) {
      CrewFormView(model: CrewFormViewModel(repository: app.repositories.workforce)) { model.upsert($0) }
    }
    .refreshable { await model.load() }
    .task { await model.load() }
  }

  private func subtitle(_ crew: Crew) -> String {
    var parts = [model.ownerName(crew)]
    if let trade = crew.trade { parts.append(trade.title) }
    if let count = model.memberCounts[crew.id] { parts.append("\(count) kişi") }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Detay

struct CrewDetailView: View {
  let app: AppModel
  @State private var model: CrewDetailViewModel
  @State private var editing = false
  @State private var addingMember = false

  init(crew: Crew, app: AppModel) {
    self.app = app
    _model = State(initialValue: CrewDetailViewModel(crew: crew, access: app.access, repository: app.repositories.workforce))
  }

  var body: some View {
    let crew = model.crew
    List {
      if let error = model.errorMessage {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        RecordHeader(title: crew.name, subtitle: headerSubtitle) {
          RDStatusBadge(text: crew.subcontractorId == nil ? "Şirket ekibi" : "Taşeron ekibi",
                        tone: crew.subcontractorId == nil ? .info : .neutral)
          RecordBadges(isActive: crew.isActive, isDemo: crew.isDemo)
        }
        if let sub = model.subcontractor {
          NavigationLink(value: AppRoute.subcontractor(sub)) {
            RDInfoRow(label: "Taşeron", value: sub.name)
          }
        }
      }
      .rdRowBackground()

      Section {
        if model.currentMembers.isEmpty {
          Text("Ekipte şu an kimse yok.").foregroundStyle(RDColor.textSecondary)
        }
        ForEach(model.currentMembers) { membership in
          memberRow(membership)
            .swipeActions(edge: .trailing) {
              if model.canManage {
                Button("Bugün ayrıldı") { Task { await model.end(membership) } }.tint(RDColor.tone(.warning))
              }
            }
        }
        if model.canManage {
          Button("Üye ekle", systemImage: "person.badge.plus") { addingMember = true }
            .foregroundStyle(RDColor.brandText)
            .frame(minHeight: Metrics.minTouchTarget)
        }
      } header: {
        Text("Ekipte şu an (\(model.currentMembers.count))")
      } footer: {
        if model.canManage {
          Text("Ayrılan kişiyi sola kaydırın; üyelik silinmez, bitiş tarihiyle geçmişe taşınır.")
        }
      }
      .rdRowBackground()

      if !model.pastMembers.isEmpty {
        Section("Üyelik geçmişi") {
          ForEach(model.pastMembers) { memberRow($0) }
        }
        .rdRowBackground()
      }

      if model.canSeeAssignments {
        Section("Görevli olduğu projeler") {
          if model.assignments.isEmpty {
            Text("Görebildiğiniz projelerde görevlendirme yok.").foregroundStyle(RDColor.textSecondary)
          }
          ForEach(model.assignments) { assignment in
            RDRow(symbol: AppModule.projeler.symbol, title: app.projectName(assignment.projectId) ?? "Proje",
                  subtitle: assignment.period.display) {
              PeriodBadge(period: assignment.period)
            }
          }
        }
        .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle(crew.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.canManage { Button("Düzenle") { editing = true } }
    }
    .sheet(isPresented: $editing) {
      CrewFormView(model: CrewFormViewModel(editing: crew, repository: app.repositories.workforce)) { saved in
        model.didSave(saved)
        Task { await model.load() }
      }
    }
    .sheet(isPresented: $addingMember) { AddMemberSheet(model: model) }
    .refreshable { await model.load() }
    .task { await model.load() }
  }

  private var headerSubtitle: String {
    [model.crew.trade?.title, model.leaderName.map { "Sorumlu: \($0)" }].compactMap { $0 }.joined(separator: " · ")
  }

  private func memberRow(_ membership: CrewMembership) -> some View {
    NavigationLink(value: personRoute(membership.personnelId)) {
      RDRow(symbol: "person.crop.circle", title: model.name(membership.personnelId),
            subtitle: [membership.roleTitle, membership.period.display].compactMap { $0 }.joined(separator: " · "))
    }
    .disabled(model.people[membership.personnelId] == nil)
  }

  private func personRoute(_ id: UUID) -> AppRoute? {
    model.people[id].map(AppRoute.personnel)
  }
}

private struct AddMemberSheet: View {
  let model: CrewDetailViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var personId: UUID?
  @State private var start = Date()
  @State private var roleTitle = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Kişi", selection: $personId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(model.eligiblePeople) { Text($0.fullName).tag(Optional($0.id)) }
          }
          DatePicker("Başlangıç", selection: $start, displayedComponents: .date)
          TextField("Ekipteki görevi (usta, kalfa...)", text: $roleTitle)
        } footer: {
          Text(model.crew.subcontractorId == nil
               ? "Şirket ekibine yalnızca şirket personeli katılabilir."
               : "Bu ekibe yalnızca taşeronun kendi personeli katılabilir.")
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle("Üye ekle")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetToolbar(confirmTitle: "Ekle", canConfirm: personId != nil, onCancel: { dismiss() }) {
          guard let personId else { return }
          Task {
            if await model.addMember(personId, start: CalendarDate(start), roleTitle: roleTitle) { dismiss() }
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

// MARK: - Form

struct CrewFormView: View {
  @State var model: CrewFormViewModel
  let onSaved: (Crew) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Ekip adı (ör. Kalıp Ekibi)", text: $model.name)
          TradePicker(selection: $model.trade)
          Toggle("Aktif", isOn: $model.isActive)
        }
        .rdRowBackground()

        Section {
          Picker("Bağlı olduğu", selection: $model.subcontractorId) {
            Text("Şirket ekibi").tag(UUID?.none)
            ForEach(model.subcontractorOptions) { Text($0.name).tag(Optional($0.id)) }
          }
          .disabled(model.editing != nil)
          Picker("Sorumlu", selection: $model.leaderId) {
            Text("Belirtilmedi").tag(UUID?.none)
            ForEach(model.leaderOptions) { Text($0.fullName).tag(Optional($0.id)) }
          }
        } header: {
          Text("Sahibi ve sorumlusu")
        } footer: {
          Text("Sorumlu, ekibin bağlı olduğu taşeronun (şirket ekibinde şirketin) personelinden seçilir. Ekibin sahibi sonradan değiştirilmez; gerekirse yeni ekip açın.")
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
