import RDCore
import RDDesign
import SwiftUI

/// İmalat girilebilecek projeler.
struct ImalatProjectsView: View {
  let app: AppModel

  private var projects: [Project] {
    app.projects.filter { app.access.can(.imalatRead, in: $0.id) && $0.status != .tamamlandi }
  }

  var body: some View {
    List {
      Section {
        ForEach(projects) { project in
          NavigationLink(value: AppRoute.imalat(project)) { ProjectRow(project: project) }
        }
      } footer: {
        Text("İmalat (metraj), birim fiyatlı sözleşme kalemlerinde yapılan iş miktarıdır. Fiyat ve tutar gösterilmez.")
      }
      .rdRowBackground()
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle("İmalat (metraj)")
    .rdContentState(isLoading: false, isEmpty: projects.isEmpty, error: nil,
                    empty: .empty(title: "Proje yok", message: "İmalat girebileceğiniz aktif proje bulunmuyor.",
                                  symbol: "ruler"),
                    retry: {})
  }
}

/// Projenin birim fiyatlı kalemleri ve metraj girişi. Fiyat ve tutar içermez.
struct ImalatView: View {
  @State private var model: ImalatViewModel
  @State private var selected: ImalatItem?
  @State private var cancelling: WorkQuantity?

  init(project: Project, app: AppModel) {
    _model = State(initialValue: ImalatViewModel(project: project, access: app.access, repository: app.repositories.contracts))
  }

  var body: some View {
    List {
      if let notice = model.notice {
        Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(RDColor.tone(.success)) }
          .rdRowBackground()
      }
      if let error = model.errorMessage, !model.items.isEmpty {
        Section { RDErrorBanner(message: error) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
      }
      Section {
        ForEach(model.items) { item in
          Button { if model.canWrite { selected = item } } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(item.description).font(RDFont.rowTitle).foregroundStyle(RDColor.textPrimary)
              Text("\(item.contractNo) · \(item.subcontractorName)").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
              Text(progress(item)).font(RDFont.caption).monospacedDigit().foregroundStyle(RDColor.textSecondary)
            }
          }
          .accessibilityHint(model.canWrite ? "Miktar girmek için dokunun" : "")
        }
      } header: {
        Text("Kalemler")
      } footer: {
        if model.canWrite { Text("Miktar girmek için kaleme dokunun. Girilen miktar onaydan sonra hakedişe kaynak olur.") }
      }
      .rdRowBackground()

      if !model.pending.isEmpty {
        Section {
          ForEach(model.pending) { row in
            VStack(alignment: .leading, spacing: 2) {
              Text(model.item(for: row)?.description ?? "Kalem").font(RDFont.body)
              Text("\(row.workDate.display) · \(DecimalInput.format(row.quantity, maxFractionDigits: 3)) \(ContractUnit.title(model.item(for: row)?.unit ?? ""))\(row.location.map { " · \($0)" } ?? "")")
                .font(RDFont.caption).monospacedDigit().foregroundStyle(RDColor.textSecondary)
            }
            .swipeActions {
              if model.canWrite { Button("İptal", role: .destructive) { cancelling = row } }
            }
          }
          if model.canApprove {
            Button { Task { await model.approvePending() } } label: {
              Label("Tümünü onayla (\(model.pending.count))", systemImage: "checkmark.seal")
            }
            .disabled(model.isSaving)
          }
        } header: {
          Text("Onay bekleyen")
        } footer: {
          Text("Onaylanan imalat değiştirilemez; hatalıysa iptal edilip yeniden girilir. Bir imalat yalnızca bir hakedişte kullanılır.")
        }
        .rdRowBackground()
      }
    }
    .listStyle(.insetGrouped)
    .rdScreen()
    .navigationTitle("İmalat · \(model.project.code)")
    .navigationBarTitleDisplayMode(.inline)
    .rdContentState(isLoading: model.isLoading, isEmpty: model.items.isEmpty, error: model.errorMessage,
                    empty: .empty(title: "Kalem yok", message: "Bu projede onaylı, birim fiyatlı sözleşme kalemi bulunmuyor.",
                                  symbol: "ruler"),
                    retry: { Task { await model.load() } })
    .refreshable { await model.load() }
    .task { await model.load() }
    .sheet(item: $selected) { item in ImalatEntrySheet(item: item, model: model) }
    .sheet(item: $cancelling) { row in
      ReasonSheet(title: "İmalatı iptal et", message: "Kayıt silinmez, iptal olarak işaretlenir.", actionTitle: "İptal et",
                  minimumLength: 3, destructive: true) { await model.cancel(row, reason: $0) }
    }
  }

  private func progress(_ item: ImalatItem) -> String {
    let unit = ContractUnit.title(item.unit)
    var text = "Onaylı \(DecimalInput.format(item.approvedQuantity, maxFractionDigits: 3)) \(unit)"
    if let total = item.contractQuantity { text += " / sözleşme \(DecimalInput.format(total, maxFractionDigits: 3)) \(unit)" }
    if item.pendingQuantity > 0 { text += " · bekleyen \(DecimalInput.format(item.pendingQuantity, maxFractionDigits: 3))" }
    return text
  }
}

struct ImalatEntrySheet: View {
  let item: ImalatItem
  let model: ImalatViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var quantityText = ""
  @State private var date = Date()
  @State private var location = ""
  @State private var note = ""
  @State private var entryId = UUID()

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Miktar (\(ContractUnit.title(item.unit)))", text: $quantityText)
            .keyboardType(.decimalPad)
            .font(RDFont.metric)
            .monospacedDigit()
          DatePicker("Tarih", selection: $date, in: ...Date(), displayedComponents: .date)
          TextField("Yer (ör. A blok 3. kat)", text: $location)
          TextField("Not (isteğe bağlı)", text: $note)
        } header: {
          Text(item.description)
        } footer: {
          Text("\(item.contractNo) · \(item.subcontractorName). Fiyat bu ekranda yoktur.")
        }
        .rdRowBackground()
        RDFormMessage(message: model.errorMessage)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle("İmalat gir")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            Task {
              if await model.save(item: item, quantityText: quantityText, date: CalendarDate(date), location: location,
                                  note: note, id: entryId) {
                dismiss()
              }
            }
          }
          .fontWeight(.semibold)
          .disabled(quantityText.isEmpty || model.isSaving)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}
