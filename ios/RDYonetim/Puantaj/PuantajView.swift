import RDCore
import RDDesign
import SwiftUI

/// Ana ekrandaki Puantaj modülü: puantajını görebildiği projeler.
struct PuantajProjectsView: View {
  let app: AppModel

  private var projects: [Project] {
    app.projects.filter { app.access.can(.puantajRead, in: $0.id) }
      .sorted { ($0.status == .tamamlandi ? 1 : 0, $0.name) < ($1.status == .tamamlandi ? 1 : 0, $1.name) }
  }

  var body: some View {
    List {
      Section {
        ForEach(projects) { project in
          NavigationLink(value: AppRoute.puantaj(project)) { ProjectRow(project: project) }
        }
      } footer: {
        Text("Puantaj çalışma bilgisidir; maaş, hakediş veya borç oluşturmaz.")
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .rdContentState(isLoading: false, isEmpty: projects.isEmpty, error: nil,
                    empty: .empty(title: "Proje yok", message: "Puantajını görebildiğiniz proje bulunmuyor.",
                                  symbol: AppModule.puantaj.symbol),
                    retry: {})
    .navigationTitle("Puantaj")
    .refreshable { await app.reloadLookups() }
  }
}

/// Bir projenin aylık puantajı. Ay tablosu (Excel benzeri) ve daha okunaklı
/// gün listesi aynı veriyi gösterir; ay verisi tek seferde yüklenir.
struct PuantajView: View {
  enum Mode: String, CaseIterable, Identifiable {
    case gun = "Gün", ay = "Ay tablosu"
    var id: String { rawValue }
  }

  enum Sheet: Identifiable {
    case bulk, summary, period, overtime
    var id: Self { self }
  }

  let app: AppModel
  @State private var model: PuantajViewModel
  @State private var mode: Mode = .ay
  @State private var selectedDay: CalendarDate
  @State private var editing: PuantajCellSelection?
  @State private var sheet: Sheet?

  init(project: Project, app: AppModel) {
    self.app = app
    let model = PuantajViewModel(project: project, access: app.access, repository: app.repositories.puantaj)
    _model = State(initialValue: model)
    _selectedDay = State(initialValue: .today())
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      content
    }
    .background(RDColor.background.ignoresSafeArea())
    .safeAreaInset(edge: .bottom) { footer }
    .navigationTitle("Puantaj")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { toolbar }
    .sheet(item: $editing) { selection in
      PuantajCellSheet(model: model, selection: selection)
    }
    .sheet(item: $sheet) { sheet in
      switch sheet {
      case .bulk: PuantajBulkSheet(model: model, day: selectedDay)
      case .summary: PuantajSummaryView(model: model)
      case .period: PuantajPeriodSheet(model: model)
      case .overtime: PuantajOvertimeSheet(model: model)
      }
    }
    .task { await model.load() }
    .refreshable { await model.load() }
    .onChange(of: model.month) { _, month in
      if !month.contains(selectedDay) {
        selectedDay = month.contains(.today()) ? .today() : month.firstDay
      }
    }
  }

  // MARK: Parçalar

  private var header: some View {
    VStack(spacing: .rdS) {
      PuantajMonthBar(month: model.month, status: model.status, revision: model.period?.revision ?? 0,
                      onPrevious: { Task { await model.showPreviousMonth() } },
                      onNext: { Task { await model.showNextMonth() } })
      Picker("Görünüm", selection: $mode) {
        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      if model.hasFilter || !model.crewOptions.isEmpty {
        filterBar
      }
    }
    .padding(.horizontal, .rdScreen)
    .padding(.bottom, .rdS)
    .background(RDColor.background)
  }

  private var filterBar: some View {
    HStack(spacing: .rdS) {
      Menu {
        Picker("Ekip", selection: $model.crewFilter) {
          Text("Tüm ekipler").tag(UUID?.none)
          ForEach(model.crewOptions, id: \.id) { Text($0.name).tag(Optional($0.id)) }
        }
        if !model.subcontractorOptions.isEmpty {
          Picker("Taşeron", selection: $model.subcontractorFilter) {
            Text("Tüm taşeronlar").tag(UUID?.none)
            ForEach(model.subcontractorOptions, id: \.id) { Text($0.name).tag(Optional($0.id)) }
          }
        }
      } label: {
        Label(filterTitle, systemImage: "line.3.horizontal.decrease.circle")
          .font(RDFont.secondary)
          .frame(minHeight: Metrics.minTouchTarget)
      }
      if model.hasFilter {
        Button("Temizle") { model.clearFilters() }.font(RDFont.secondary)
      }
      Spacer()
      Text("\(model.visibleRows.count) kişi").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
    }
    .foregroundStyle(RDColor.brandText)
  }

  private var filterTitle: String {
    let crew = model.crewFilter.flatMap { id in model.crewOptions.first { $0.id == id }?.name }
    let sub = model.subcontractorFilter.flatMap { id in model.subcontractorOptions.first { $0.id == id }?.name }
    return [crew, sub].compactMap { $0 }.joined(separator: " · ").nilIfBlank ?? "Filtre"
  }

  @ViewBuilder private var content: some View {
    if model.grid.rows.isEmpty {
      Group {
        if model.isLoading {
          RDStateView(kind: .loading)
        } else if let error = model.errorMessage {
          RDStateView(kind: .error(error, retry: { Task { await model.load() } }))
        } else {
          RDStateView(kind: .empty(
            title: "Bu ay görevli kimse yok",
            message: "Puantaj, projeye görevlendirilen kişiler ve ekipler için girilir. Önce projenin Ekip ve personel bölümünden görevlendirme ekleyin.",
            symbol: AppModule.puantaj.symbol))
        }
      }
      .frame(maxHeight: .infinity)
    } else {
      switch mode {
      case .ay:
        PuantajGridView(model: model, rows: model.visibleRows) { row, day in
          selectedDay = day
          editing = PuantajCellSelection(personnelId: row.personnelId, day: day)
        }
      case .gun:
        PuantajDayView(model: model, day: $selectedDay) { row in
          editing = PuantajCellSelection(personnelId: row.personnelId, day: selectedDay)
        } onBulk: {
          sheet = .bulk
        }
      }
    }
  }

  @ViewBuilder private var footer: some View {
    VStack(spacing: .rdS) {
      if let error = model.errorMessage, !model.grid.rows.isEmpty {
        RDErrorBanner(message: error)
      }
      if let notice = model.notice {
        PuantajNotice(text: notice) { model.dismissNotice() }
      }
      if let reason = model.editBlockedReason, !model.grid.rows.isEmpty {
        Label(reason, systemImage: model.status == .kilitli ? "lock.fill" : "info.circle")
          .font(RDFont.caption)
          .foregroundStyle(RDColor.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, .rdScreen)
    .padding(.vertical, model.errorMessage == nil && model.notice == nil && model.editBlockedReason == nil ? 0 : .rdS)
    .background(RDColor.background.opacity(0.96))
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Menu {
        if model.canEdit {
          Button("Toplu işle veya kopyala", systemImage: "square.grid.3x3.square") { sheet = .bulk }
        }
        Button("Aylık özet", systemImage: "chart.bar.doc.horizontal") { sheet = .summary }
        Button("Ay durumu ve onay", systemImage: "checkmark.seal") { sheet = .period }
        if model.canApproveOvertime && !model.pendingOvertime.isEmpty {
          Button("Fazla mesai onayı (\(model.pendingOvertime.count))", systemImage: "clock.badge.checkmark") {
            sheet = .overtime
          }
        }
        if !model.isCurrentMonth {
          Button("Bu aya dön", systemImage: "calendar") {
            Task { await model.show(month: .current()) }
          }
        }
      } label: {
        Label("İşlemler", systemImage: "ellipsis.circle")
      }
    }
  }
}
