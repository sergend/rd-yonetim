import RDCore
import RDDesign
import SwiftUI

/// Tutar satırı: etiket solda, tutar sağda. İşaret (+ / −) ayrıca yazılır,
/// renk tek başına anlam taşımaz.
struct MoneyRow: View {
  enum Sign { case none, plus, minus, total }

  let label: String
  let amount: Decimal
  var currency = "TRY"
  var sign: Sign = .none
  var detail: String?
  var emphasized = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: .rdS) {
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(emphasized ? RDFont.rowTitle : RDFont.body)
          .foregroundStyle(RDColor.textPrimary)
        if let detail {
          Text(detail).font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
        }
      }
      Spacer(minLength: .rdS)
      Text(prefix + Money.format(amount, currency: currency))
        .font(emphasized ? RDFont.rowTitle : RDFont.body)
        .monospacedDigit()
        .foregroundStyle(sign == .minus ? RDColor.textSecondary : RDColor.textPrimary)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label), \(accessibilitySign)\(Money.format(amount, currency: currency))")
  }

  private var prefix: String {
    switch sign {
    case .plus: "+ "
    case .minus: "− "
    case .total, .none: ""
    }
  }

  private var accessibilitySign: String {
    switch sign {
    case .plus: "eklenir "
    case .minus: "düşülür "
    case .total, .none: ""
    }
  }
}

/// Hakedişin hesap özeti: hak edilen, kesilen, ödemeye uygun, ödenen ve kalan
/// ayrı satırlardır. Ödemeye uygun tutar ödendi anlamına gelmez.
struct HakedisBreakdownSections: View {
  let hakedis: Hakedis
  let breakdown: HakedisBreakdown
  let paymentState: String

  var body: some View {
    Section {
      MoneyRow(label: "Brüt hakediş", amount: breakdown.gross, currency: hakedis.currency,
               detail: "Bu dönem yapılan işin bedeli")
      if breakdown.kdv > 0 { MoneyRow(label: "KDV", amount: breakdown.kdv, currency: hakedis.currency, sign: .plus) }
      if breakdown.kdv > 0 {
        MoneyRow(label: "Hak edilen toplam", amount: breakdown.earned, currency: hakedis.currency, sign: .total)
      }
    } header: {
      Text("Hak edilen")
    }
    .rdRowBackground()

    Section {
      if breakdown.stopaj > 0 { MoneyRow(label: "Stopaj", amount: breakdown.stopaj, currency: hakedis.currency, sign: .minus) }
      if breakdown.other > 0 {
        MoneyRow(label: "Diğer kesinti", amount: breakdown.other, currency: hakedis.currency, sign: .minus)
      }
      MoneyRow(label: "Teminat kesintisi", amount: breakdown.retention, currency: hakedis.currency, sign: .minus,
               detail: "Sözleşmede birikir; ödenmiş sayılmaz")
      if breakdown.advance > 0 {
        MoneyRow(label: "Avans mahsubu", amount: breakdown.advance, currency: hakedis.currency, sign: .minus,
                 detail: "Daha önce verilen avanstan düşülür")
      }
    } header: {
      Text("Kesilen")
    }
    .rdRowBackground()

    Section {
      MoneyRow(label: "Ödemeye uygun", amount: breakdown.payable, currency: hakedis.currency, sign: .total, emphasized: true)
      MoneyRow(label: "Gerçekleşen ödeme", amount: breakdown.paid, currency: hakedis.currency)
      MoneyRow(label: "Kalan", amount: breakdown.remaining, currency: hakedis.currency, emphasized: true)
      HStack {
        Text("Ödeme durumu").foregroundStyle(RDColor.textSecondary)
        Spacer()
        RDStatusBadge(text: paymentState, tone: paymentTone)
      }
    } header: {
      Text("Ödeme")
    } footer: {
      Text("Ödemeye uygun tutar, kesintilerden sonra ödenebilecek tutardır; ödendiği anlamına gelmez. Ödeme ayrıca kaydedilir.")
    }
    .rdRowBackground()
  }

  private var paymentTone: StatusTone {
    switch paymentState {
    case "Ödendi": .success
    case "Kısmen ödendi": .warning
    case "Ödenmedi": .danger
    default: .neutral
    }
  }
}

/// Gerekçe isteyen işlemler için kısa sayfa (iptal, revizyon, limit izni).
struct ReasonSheet: View {
  let title: String
  let message: String
  let actionTitle: String
  var minimumLength = 10
  var destructive = false
  let action: (String) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var reason = ""
  @State private var isWorking = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Gerekçe", text: $reason, axis: .vertical)
            .lineLimit(3...6)
        } footer: {
          Text(message + " En az \(minimumLength) karakter.")
        }
        .rdRowBackground()
      }
      .rdScreen()
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(actionTitle, role: destructive ? .destructive : nil) {
            Task {
              isWorking = true
              if await action(reason.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
              isWorking = false
            }
          }
          .fontWeight(.semibold)
          .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).count < minimumLength || isWorking)
        }
      }
    }
    .presentationDetents([.medium])
  }
}

/// Ödeme formu: tutar, kaynak ve tarih. Ödeme kaynağı yalnızca bilgidir;
/// kaynak bakiyesi tutulmaz.
struct PaymentSheet: View {
  let title: String
  let remaining: Decimal
  let currency: String
  let sources: [PaymentSource]
  let action: (Decimal, UUID, CalendarDate, String?, Decimal?) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var amountText = ""
  @State private var rateText = ""
  @State private var sourceId: UUID?
  @State private var date = Date()
  @State private var note = ""
  @State private var isWorking = false

  private var amount: Decimal? { Money.parse(amountText) }
  private var problem: String? {
    guard let amount, amount > 0 else { return amountText.isEmpty ? nil : "Tutar geçersiz." }
    if remaining > 0, amount > remaining { return "Tutar kalan \(Money.format(remaining, currency: currency)) üstünde." }
    if sourceId == nil { return "Ödeme kaynağını seçin." }
    return ExchangeRateField.problem(currency: currency, text: rateText)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(currency == "TRY" ? "Tutar (₺)" : "Tutar (\(currency))", text: $amountText)
            .keyboardType(.decimalPad)
            .font(RDFont.metric)
            .monospacedDigit()
          if remaining > 0 {
            Button("Kalanın tamamı: \(Money.format(remaining, currency: currency))") {
              amountText = Money.format(remaining, currency: "").trimmingCharacters(in: .whitespaces)
            }
            .font(RDFont.secondary)
          }
          Picker("Ödeme kaynağı", selection: $sourceId) {
            Text("Seçin").tag(UUID?.none)
            ForEach(sources) { Text($0.name).tag(Optional($0.id)) }
          }
          DatePicker("Ödeme tarihi", selection: $date, in: ...Date(), displayedComponents: .date)
          ExchangeRateField(currency: currency, text: $rateText)
        } footer: {
          Text("Ödeme kaynağı (ör. şirket ödemesi, kart) bilgi amaçlıdır; kasa veya banka bakiyesi tutulmaz.")
        }
        .rdRowBackground()
        Section { TextField("Açıklama (isteğe bağlı)", text: $note) }.rdRowBackground()
        RDFormMessage(message: problem)
      }
      .rdScreen()
      .environment(\.locale, Money.locale)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kaydet") {
            guard let amount, let sourceId else { return }
            Task {
              isWorking = true
              if await action(amount, sourceId, CalendarDate(date), note.nilIfBlank,
                              ExchangeRateField.rate(currency: currency, text: rateText)) { dismiss() }
              isWorking = false
            }
          }
          .fontWeight(.semibold)
          .disabled(problem != nil || amount == nil || isWorking)
        }
      }
      .onAppear { if sources.count == 1 { sourceId = sources[0].id } }
      .interactiveDismissDisabled(isWorking)
    }
  }
}

/// TRY dışı işlemde kur girişi (1 birim = ? ₺). Kur tahmin edilmez ve
/// varsayılan değer yoktur; TL işlemde alan görünmez (kur 1).
struct ExchangeRateField: View {
  let currency: String
  @Binding var text: String

  var body: some View {
    if currency != "TRY" {
      TextField("Kur (1 \(currency) = ? ₺)", text: $text)
        .keyboardType(.decimalPad)
        .monospacedDigit()
        .accessibilityHint("İşlem tarihindeki kuru girin")
    }
  }

  static func rate(currency: String, text: String) -> Decimal? {
    currency == "TRY" ? nil : HakedisMath.parseExchangeRate(text)
  }

  static func problem(currency: String, text: String) -> String? {
    guard currency != "TRY" else { return nil }
    guard let rate = HakedisMath.parseExchangeRate(text) else {
      return text.isEmpty ? "\(currency) işlemde kur zorunlu." : "Kur geçersiz."
    }
    return HakedisMath.scale(rate) > 6 ? "Kur en çok 6 ondalıklı olmalı." : nil
  }
}

/// Değişmez işlem geçmişi.
struct FinanceEventsSection: View {
  let events: [FinanceEvent]
  var title = "Onay ve değişiklik geçmişi"

  var body: some View {
    Section(title) {
      if events.isEmpty {
        Text("Kayıt yok.").foregroundStyle(RDColor.textSecondary)
      }
      ForEach(events) { event in
        VStack(alignment: .leading, spacing: 2) {
          Text(event.title).font(RDFont.body).foregroundStyle(RDColor.textPrimary)
          Text(event.occurredAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Money.locale)))
            .font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          if let reason = event.reason {
            Text("Gerekçe: \(reason)").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
    .rdRowBackground()
  }
}

extension Hakedis {
  var statusSubtitle: String { "\(periodText) · \(status.title)" }
}
