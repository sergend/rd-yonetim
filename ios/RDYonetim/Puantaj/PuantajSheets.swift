import RDCore
import RDDesign
import SwiftUI

// MARK: - Hücre

/// Hızlı durum seçimi: duruma dokunmak kaydeder ve kapatır. Fazla mesai ve
/// not için ayrıca "Kaydet" kullanılır.
struct PuantajCellSheet: View {
  let model: PuantajViewModel
  let selection: PuantajCellSelection
  @Environment(\.dismiss) private var dismiss
  @State private var overtime = ""
  @State private var overtimeNote = ""
  @State private var note = ""
  @State private var showsDetails = false
  @State private var saved = 0

  private var entry: PuantajEntry? { model.grid.entry(selection.personnelId, selection.day) }
  private var row: PuantajRow? { model.grid.row(selection.personnelId) }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 2) {
            Text(row?.name ?? entry?.personnelName ?? "Personel").font(RDFont.rowTitle)
            Text(subtitle).font(RDFont.secondary).foregroundStyle(RDColor.textSecondary)
          }
          .accessibilityElement(children: .combine)
        }
        .rdRowBackground()

        if model.canEdit {
          Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: .rdS)], spacing: .rdS) {
              ForEach(PuantajStatus.allCases) { status in statusButton(status) }
            }
            .padding(.vertical, .rdXS)
            if entry != nil {
              Button("Hücreyi temizle (henüz işlenmedi)", role: .destructive) { save(nil) }
                .frame(minHeight: Metrics.minTouchTarget)
            }
          } header: {
            Text("Durum")
          } footer: {
            Text("Duruma dokununca kaydedilir. Girilmeyen gün devamsızlık sayılmaz.")
          }
          .rdRowBackground()

          Section {
            DisclosureGroup("Fazla mesai ve not", isExpanded: $showsDetails) {
              if entry?.status.allowsOvertime == true {
                TextField("Fazla mesai (saat, ör. 2,5)", text: $overtime)
                  .keyboardType(.decimalPad)
                TextField("Fazla mesai açıklaması", text: $overtimeNote)
              } else {
                Text("Fazla mesai yalnızca tam veya yarım gün çalışılan güne yazılır.")
                  .font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
              }
              TextField("Not", text: $note, axis: .vertical).lineLimit(1...3)
              Button("Kaydet") { saveDetails() }
                .buttonStyle(.rdPrimary)
                .disabled(entry == nil || model.isSaving)
                .listRowInsets(EdgeInsets(top: .rdS, leading: .rdM, bottom: .rdS, trailing: .rdM))
            }
          } footer: {
            if let entry, entry.hasOvertime {
              Text(entry.isOvertimeApproved ? "Fazla mesai onaylı. Saat değişirse onay düşer."
                                            : "Fazla mesai onay bekliyor. Para hesabı yapılmaz.")
            }
          }
          .rdRowBackground()
        } else {
          Section {
            if let entry {
              RDInfoRow(label: "Durum", value: entry.status.title)
              if entry.hasOvertime {
                RDInfoRow(label: "Fazla mesai", value: "\(OvertimeInput.format(entry.overtimeHours)) saat")
              }
              if let note = entry.note { RDInfoRow(label: "Not", value: note) }
            } else {
              Text("Henüz işlenmedi.").foregroundStyle(RDColor.textSecondary)
            }
            if let reason = model.editBlockedReason {
              Label(reason, systemImage: "lock").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
            }
          }
          .rdRowBackground()
        }

        if entry?.crewName != nil || entry != nil {
          Section("Kayıt anındaki bağlantı") {
            RDInfoRow(label: "Ekip", value: entry?.crewName ?? "Doğrudan görevli")
            if let version = entry?.version { RDInfoRow(label: "Sürüm", value: "\(version)") }
          }
          .rdRowBackground()
        }
        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .navigationTitle(selection.day.display)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
      }
      .sensoryFeedback(.success, trigger: saved)
      .onAppear(perform: fill)
    }
    .presentationDetents([.medium, .large])
  }

  private var subtitle: String {
    var parts = [selection.day.longDisplay]
    if let crew = row?.link(on: selection.day)?.crewName { parts.append(crew) }
    return parts.joined(separator: " · ")
  }

  private func statusButton(_ status: PuantajStatus) -> some View {
    let selected = entry?.status == status
    return Button {
      save(status)
    } label: {
      HStack(spacing: .rdS) {
        Text(status.shortLabel)
          .font(.caption.weight(.bold))
          .frame(minWidth: 28)
          .foregroundStyle(RDColor.tone(status.tone))
        Text(status.title)
          .font(RDFont.secondary)
          .foregroundStyle(RDColor.textPrimary)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
        if selected { Image(systemName: "checkmark").foregroundStyle(RDColor.brandText) }
      }
      .padding(.horizontal, .rdS)
      .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget)
      .background(RDColor.tone(status.tone).opacity(selected ? 0.22 : 0.1),
                  in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(model.isSaving)
    .accessibilityLabel(status.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func fill() {
    guard let entry else { return }
    overtime = entry.hasOvertime ? OvertimeInput.format(entry.overtimeHours) : ""
    overtimeNote = entry.overtimeNote ?? ""
    note = entry.note ?? ""
    showsDetails = entry.hasOvertime || entry.note != nil
  }

  /// Hızlı seçim: mevcut fazla mesai ve not korunur (çalışılmayan güne geçilirse
  /// fazla mesai düşer).
  private func save(_ status: PuantajStatus?) {
    Task {
      let ok = await model.setCell(personnelId: selection.personnelId, day: selection.day, status: status,
                                   overtimeHours: entry?.overtimeHours ?? 0, overtimeNote: entry?.overtimeNote,
                                   note: entry?.note)
      if ok {
        saved += 1
        dismiss()
      }
    }
  }

  private func saveDetails() {
    guard let entry else { return }
    guard let hours = OvertimeInput.parse(overtime) else {
      model.dismissNotice()
      return
    }
    Task {
      if await model.setCell(personnelId: selection.personnelId, day: selection.day, status: entry.status,
                             overtimeHours: hours, overtimeNote: overtimeNote, note: note) {
        saved += 1
        dismiss()
      }
    }
  }
}

// MARK: - Toplu işlem

/// Bir günü birden fazla kişiye işler ya da önceki günü kopyalar. Kaydetmeden
/// önce kime, hangi güne ne uygulanacağı ve hangi dolu hücrelerin korunacağı
/// gösterilir.
struct PuantajBulkSheet: View {
  enum Kind: String, CaseIterable, Identifiable {
    case fill = "Aynı durumu uygula", copy = "Önceki günü kopyala"
    var id: String { rawValue }
  }

  let model: PuantajViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var kind: Kind = .fill
  @State private var day: Date
  @State private var status: PuantajStatus = .tamGun
  @State private var crew: UUID?
  @State private var excluded: Set<UUID> = []
  @State private var overwrite = false
  @State private var plan: PuantajPlan?
  @State private var confirming = false

  init(model: PuantajViewModel, day: CalendarDate) {
    self.model = model
    let start = model.grid.month.contains(day) ? day : model.grid.month.firstDay
    _day = State(initialValue: start.date())
  }

  private var target: CalendarDate { CalendarDate(day) }
  private var source: CalendarDate { target.adding(days: -1) }

  /// O gün görevli kişiler (ekip seçiliyse o ekip).
  private var candidates: [PuantajRow] {
    model.visibleRows.filter { row in
      guard let link = row.link(on: target) else { return false }
      return crew == nil || link.crewId == crew
    }
  }

  private var people: [UUID] { candidates.map(\.personnelId).filter { !excluded.contains($0) } }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("İşlem", selection: $kind) {
            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }

        Section {
          DatePicker("Gün", selection: $day, in: model.grid.month.firstDay.date()...model.grid.month.lastDay.date(),
                     displayedComponents: .date)
          if kind == .fill {
            Picker("Durum", selection: $status) {
              ForEach(PuantajStatus.allCases) { Text($0.title).tag($0) }
            }
          } else {
            RDInfoRow(label: "Kaynak gün", value: source.longDisplay)
          }
          Picker("Ekip", selection: $crew) {
            Text("Herkes").tag(UUID?.none)
            ForEach(model.crewOptions, id: \.id) { Text($0.name).tag(Optional($0.id)) }
          }
          Toggle("Dolu hücrelerin üzerine yaz", isOn: $overwrite)
        } footer: {
          Text(overwrite ? "Dolu hücreler değiştirilecek; önizlemede ayrıca gösterilir."
                         : "Dolu hücreler korunur; yalnızca boş hücreler doldurulur.")
        }
        .rdRowBackground()

        Section {
          if candidates.isEmpty {
            Text("Bu gün görevli kişi yok.").foregroundStyle(RDColor.textSecondary)
          }
          ForEach(candidates) { row in
            Toggle(isOn: Binding(get: { !excluded.contains(row.personnelId) },
                                 set: { on in if on { excluded.remove(row.personnelId) } else { excluded.insert(row.personnelId) } })) {
              VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(RDFont.body)
                if let current = model.grid.entry(row.personnelId, target) {
                  Text("Şu an: \(current.status.title)").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
                }
              }
            }
          }
        } header: {
          Text("Kişiler (\(people.count)/\(candidates.count))")
        }
        .rdRowBackground()

        if let plan {
          Section {
            ForEach(plan.lines) { line in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(line.name).font(RDFont.body)
                  Text(change(line)).font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
                }
                Spacer()
                RDStatusBadge(text: line.kind.title, tone: tone(line.kind))
              }
              .accessibilityElement(children: .combine)
            }
          } header: {
            Text("Önizleme · \(target.longDisplay)")
          } footer: {
            Text(planFooter(plan))
          }
          .rdRowBackground()
        }
        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle("Toplu işlem")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(plan.map { "\($0.saveCount) hücreyi kaydet" } ?? "Kaydet") { confirming = true }
            .fontWeight(.semibold)
            .disabled(plan?.isEmpty ?? true || model.isSaving)
        }
      }
      .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
        Button("Kaydet") {
          guard let plan else { return }
          Task { if await model.commit(plan) { dismiss() } }
        }
      }
      .task(id: planKey) { await rebuild() }
    }
  }

  private var planKey: String {
    "\(kind.rawValue)|\(target)|\(status.rawValue)|\(crew?.uuidString ?? "-")|\(overwrite)|\(people.count)|\(excluded.count)"
  }

  private var confirmTitle: String {
    guard let plan else { return "" }
    return plan.overwriteCount > 0
      ? "\(plan.saveCount) hücre kaydedilecek; \(plan.overwriteCount) dolu hücrenin üzerine yazılacak."
      : "\(plan.saveCount) boş hücre doldurulacak."
  }

  private func rebuild() async {
    switch kind {
    case .fill: plan = model.planFill(day: target, people: people, status: status, overwrite: overwrite)
    case .copy: plan = await model.planCopy(from: source, to: target, people: people, overwrite: overwrite)
    }
  }

  private func change(_ line: PuantajPlan.Line) -> String {
    let from = line.current?.title ?? "İşlenmedi"
    let to = line.new?.title ?? "—"
    return line.kind.willSave ? "\(from) → \(to)" : from
  }

  private func tone(_ kind: PuantajPlan.Kind) -> StatusTone {
    switch kind {
    case .ekle: .success
    case .uzerineYaz: .warning
    case .korunacak, .ayni: .neutral
    case .gorevliDegil, .kaynakYok: .info
    }
  }

  private func planFooter(_ plan: PuantajPlan) -> String {
    var parts = ["\(plan.saveCount) hücre kaydedilecek"]
    if plan.overwriteCount > 0 { parts.append("\(plan.overwriteCount) üzerine yazılacak") }
    if plan.keptCount > 0 { parts.append("\(plan.keptCount) dolu hücre korunacak") }
    return parts.joined(separator: " · ") + ". Fazla mesai kopyalanmaz."
  }
}

// MARK: - Ay durumu

struct PuantajPeriodSheet: View {
  let model: PuantajViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var pending: PuantajAction?
  @State private var reason = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          RDInfoRow(label: "Ay", value: model.month.title)
          HStack {
            Text("Durum").font(RDFont.secondary).foregroundStyle(RDColor.textSecondary)
            Spacer()
            RDStatusBadge(text: model.status.title, tone: model.status.tone)
          }
          if let period = model.period {
            if period.revision > 0 { RDInfoRow(label: "Revizyon", value: "\(period.revision)") }
            if let first = period.firstApprovedAt {
              RDInfoRow(label: "İlk onay", value: first.formatted(date: .abbreviated, time: .shortened))
            }
          }
        } footer: {
          Text("Onaylı veya kilitli ayda kimse değişiklik yapamaz. Düzeltme için ay gerekçeyle yeniden açılır; önceki onaylı hâli geçmişte saklanır.")
        }
        .rdRowBackground()

        if !model.availableActions.isEmpty {
          Section("İşlemler") {
            ForEach(model.availableActions) { action in
              Button {
                reason = ""
                pending = action
              } label: {
                Label(action.title, systemImage: action.symbol)
              }
              .foregroundStyle(action == .yenidenAc ? RDColor.tone(.warning) : RDColor.brandText)
              .frame(minHeight: Metrics.minTouchTarget)
            }
          }
          .rdRowBackground()
        }

        if pending == .yenidenAc {
          Section {
            TextField("Gerekçe (en az \(PuantajAction.minimumReasonLength) karakter)", text: $reason, axis: .vertical)
              .lineLimit(2...4)
            Button("Ayı yeniden aç") { run(.yenidenAc) }
              .buttonStyle(.rdPrimary)
              .disabled((reason.nilIfBlank?.count ?? 0) < PuantajAction.minimumReasonLength || model.isSaving)
          } header: {
            Text("Yeniden açma gerekçesi")
          }
          .rdRowBackground()
        }

        Section("Geçmiş") {
          if model.events.isEmpty {
            Text("Bu ay için henüz onay işlemi yok.").foregroundStyle(RDColor.textSecondary)
          }
          ForEach(model.events.reversed()) { event in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(event.action.title) · \(event.fromStatus.title) → \(event.toStatus.title)")
                .font(RDFont.body)
              Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened)
                   + (event.revision > 0 ? " · revizyon \(event.revision)" : ""))
                .font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
              if let reason = event.reason {
                Text(reason).font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
              }
            }
            .accessibilityElement(children: .combine)
          }
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .navigationTitle("Ay durumu")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
      }
      .confirmationDialog(confirmText, isPresented: Binding(get: { pending != nil && pending != .yenidenAc },
                                                             set: { if !$0 { pending = nil } }),
                          titleVisibility: .visible) {
        if let pending, pending != .yenidenAc {
          Button(pending.title) { run(pending) }
        }
      }
    }
  }

  private var confirmText: String {
    switch pending {
    case .onayla: "Ay onaylanınca kimse değişiklik yapamaz. Onaylanan puantaj ileride hakediş için kaynak olur; şimdi hiçbir ödeme veya borç oluşmaz."
    case .kilitle: "Kilitli ayı yalnızca kilit açma yetkisi olan kişi gerekçeyle açabilir."
    case .gonder: "Ay incelemeye gönderilince düzeltmeyi inceleme yetkisi olan kişi yapar."
    case .iade: "Ay taslağa döner ve yeniden düzenlenebilir."
    default: ""
    }
  }

  private func run(_ action: PuantajAction) {
    Task {
      if await model.perform(action, reason: action.requiresReason ? reason : nil) {
        pending = nil
        reason = ""
      }
    }
  }
}

// MARK: - Fazla mesai onayı

struct PuantajOvertimeSheet: View {
  let model: PuantajViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var selected: Set<UUID> = []

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(model.pendingOvertime) { entry in
            Toggle(isOn: Binding(get: { selected.contains(entry.id) },
                                 set: { on in if on { selected.insert(entry.id) } else { selected.remove(entry.id) } })) {
              VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.personnelName) · \(OvertimeInput.format(entry.overtimeHours)) saat").font(RDFont.body)
                Text([entry.workDate.display, entry.overtimeNote].compactMap { $0 }.joined(separator: " · "))
                  .font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
              }
            }
          }
        } footer: {
          Text("Onay yalnızca saati doğrular; ücret veya ödeme hesaplanmaz. Saat sonradan değişirse onay düşer.")
        }
        .rdRowBackground()
      }
      .listStyle(.insetGrouped)
      .rdScreen()
      .overlay {
        if model.pendingOvertime.isEmpty {
          RDStateView(kind: .empty(title: "Onay bekleyen yok", message: "Bu aydaki fazla mesailer onaylı.",
                                   symbol: "clock.badge.checkmark"))
        }
      }
      .navigationTitle("Fazla mesai onayı")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Onayla (\(selected.count))") {
            Task {
              await model.approveOvertime(model.pendingOvertime.filter { selected.contains($0.id) })
              selected = []
            }
          }
          .disabled(selected.isEmpty || model.isSaving)
        }
      }
      .onAppear { selected = Set(model.pendingOvertime.map(\.id)) }
    }
  }
}
