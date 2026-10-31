import RDCore
import RDDesign
import SwiftUI

/// Bir projenin "Ekip ve personel" ekranı: bugün sahada olanlar, projedeki
/// taşeronlar ve görevlendirmeler. Görevlendirme borç veya ödeme oluşturmaz.
struct ProjectWorkforceView: View {
  let app: AppModel
  @State private var model: ProjectWorkforceViewModel
  @State private var assigning = false

  init(project: Project, app: AppModel) {
    self.app = app
    _model = State(initialValue: ProjectWorkforceViewModel(project: project, access: app.access,
                                                           repository: app.repositories.workforce))
  }

  var body: some View {
    List {
      if let error = model.errorMessage, !model.assignments.isEmpty {
        RDErrorBanner(message: error).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      todaySection
      if !model.subcontractorLinks.isEmpty { subcontractorSection }
      assignmentsSection(title: "Devam eden görevlendirmeler", items: model.current, canEnd: true)
      if !model.past.isEmpty {
        assignmentsSection(title: "Geçmiş görevlendirmeler", items: model.past, canEnd: false)
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .rdContentState(isLoading: model.isLoading, isEmpty: model.assignments.isEmpty && model.subcontractorLinks.isEmpty,
                    error: model.errorMessage,
                    empty: .empty(title: "Görevlendirme yok",
                                  message: model.canAssign ? "Sağ üstteki + ile projeye ekip veya personel görevlendirin."
                                                           : "Bu projede henüz görevli ekip veya personel yok.",
                                  symbol: AppModule.ekipler.symbol),
                    retry: { Task { await model.load() } })
    .navigationTitle("Ekip ve personel")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.canAssign {
        ToolbarItem(placement: .primaryAction) {
          Button("Görevlendir", systemImage: "plus") { assigning = true }
        }
      }
    }
    .sheet(isPresented: $assigning) { AssignSheet(model: model) }
    .refreshable { await model.load() }
    .task { await model.load() }
  }

  private var todaySection: some View {
    Section {
      if model.today.isEmpty {
        Text("Bugün için görevli kişi yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(model.today) { entry in
        NavigationLink(value: model.people[entry.personnelId].map(AppRoute.personnel)) {
          RDRow(symbol: "person.crop.circle", title: entry.fullName,
                subtitle: [entry.jobTitle, entry.via == .ekip ? entry.crewName : "Doğrudan görevli"]
                  .compactMap { $0 }.joined(separator: " · "))
        }
      }
    } header: {
      Text("Bugün sahada (\(model.today.count))")
    } footer: {
      Text("Doğrudan görevliler ile projeye görevli ekiplerin bugünkü üyeleri. Puantaj bu listeye bağlanacak.")
    }
    .rdRowBackground()
  }

  private var subcontractorSection: some View {
    Section("Projedeki taşeronlar") {
      ForEach(model.subcontractorLinks) { link in
        let sub = model.subcontractors[link.subcontractorId]
        NavigationLink(value: sub.map(AppRoute.subcontractor)) {
          RDRow(symbol: AppModule.taseronlar.symbol, title: sub?.name ?? "Taşeron",
                subtitle: [link.scope, link.period.display].compactMap { $0 }.joined(separator: " · "))
        }
      }
    }
    .rdRowBackground()
  }

  private func assignmentsSection(title: String, items: [ProjectAssignment], canEnd: Bool) -> some View {
    Section(title) {
      if items.isEmpty {
        Text("Kayıt yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(items) { assignment in
        NavigationLink(value: route(for: assignment)) {
          RDRow(symbol: model.isCrew(assignment) ? AppModule.ekipler.symbol : "person.crop.circle",
                symbolTint: model.isCrew(assignment) ? RDColor.brandText : RDColor.textSecondary,
                title: model.title(assignment),
                subtitle: [assignment.period.display, assignment.description].compactMap { $0 }
                  .joined(separator: " · ")) {
            PeriodBadge(period: assignment.period)
          }
        }
        .swipeActions(edge: .trailing) {
          if canEnd && model.canAssign && assignment.endDate == nil {
            Button("Bugün bitir") { Task { await model.end(assignment) } }.tint(RDColor.tone(.warning))
          }
        }
      }
    }
    .rdRowBackground()
  }

  private func route(for assignment: ProjectAssignment) -> AppRoute? {
    switch assignment.target {
    case .personnel(let id): model.people[id].map(AppRoute.personnel)
    case .crew(let id): model.crews[id].map(AppRoute.crew)
    }
  }
}

/// Görevlendirme: kişi veya ekip seç, başlangıç bugün; tek dokunuşla kaydet.
private struct AssignSheet: View {
  let model: ProjectWorkforceViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var selected: AssignmentCandidate?
  @State private var kind: AssignmentCandidate.Kind = .ekip
  @State private var search = ""
  @State private var start = Date()
  @State private var hasEnd = false
  @State private var end = Date()
  @State private var note = ""

  private var filtered: [AssignmentCandidate] {
    let query = search.nilIfBlank?.lowercased(with: Money.locale)
    return model.candidates.filter { candidate in
      candidate.kind == kind && (query.map {
        candidate.name.lowercased(with: Money.locale).contains($0)
          || (candidate.subcontractorName?.lowercased(with: Money.locale).contains($0) ?? false)
      } ?? true)
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Tür", selection: $kind) {
            Text("Ekip").tag(AssignmentCandidate.Kind.ekip)
            Text("Kişi").tag(AssignmentCandidate.Kind.personel)
          }
          .pickerStyle(.segmented)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }

        Section {
          if filtered.isEmpty {
            Text(kind == .ekip ? "Görevlendirilebilecek ekip yok." : "Görevlendirilebilecek kişi yok.")
              .foregroundStyle(RDColor.textSecondary)
          }
          ForEach(filtered) { candidate in
            Button {
              selected = candidate
            } label: {
              RDRow(title: candidate.name,
                    subtitle: [candidate.detail, candidate.subcontractorName ?? "Şirket"].compactMap { $0 }
                      .joined(separator: " · ")) {
                if selected?.id == candidate.id {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(RDColor.brandText)
                    .accessibilityLabel("Seçili")
                }
              }
            }
            .buttonStyle(.plain)
          }
        } header: {
          Text(kind == .ekip ? "Ekip seçin" : "Kişi seçin")
        }
        .rdRowBackground()

        Section {
          DatePicker("Başlangıç", selection: $start, displayedComponents: .date)
          Toggle("Bitiş tarihi belli", isOn: $hasEnd)
          if hasEnd {
            DatePicker("Bitiş", selection: $end, in: start..., displayedComponents: .date)
          }
          TextField("Açıklama (isteğe bağlı)", text: $note)
        } footer: {
          Text("Aynı kişi başka projelerde de görevli olabilir. Görevlendirme borç veya ödeme oluşturmaz.")
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .searchable(text: $search, prompt: "Ad veya taşeron")
      .navigationTitle("Görevlendir")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetToolbar(confirmTitle: "Görevlendir", canConfirm: selected != nil, onCancel: { dismiss() }) {
          guard let selected else { return }
          Task {
            if await model.assign(selected, start: CalendarDate(start), end: hasEnd ? CalendarDate(end) : nil,
                                  description: note) {
              dismiss()
            }
          }
        }
      }
      .task { await model.loadCandidates() }
      .onChange(of: kind) { _, _ in selected = nil }
    }
  }
}
