import RDCore
import RDDesign
import SwiftUI

// Taşeron, personel, ekip ve görevlendirme ekranlarının ortak küçük parçaları.

extension DatePeriod {
  /// "1 Mar 2026 – devam ediyor" biçiminde dönem.
  var display: String { "\(start.display) – \(end?.display ?? "devam ediyor")" }
}

/// Dönemin durumu: devam ediyor, başlayacak ya da bitti.
struct PeriodBadge: View {
  let period: DatePeriod

  var body: some View {
    let today = CalendarDate.today()
    if period.start > today {
      RDStatusBadge(text: "Başlayacak", tone: .info)
    } else if period.isOngoing(today: today) {
      RDStatusBadge(text: "Devam ediyor", tone: .success)
    } else {
      RDStatusBadge(text: "Bitti")
    }
  }
}

/// Aktif değilse "Pasif", demo ise "DEMO" etiketi.
struct RecordBadges: View {
  let isActive: Bool
  let isDemo: Bool

  var body: some View {
    if isDemo { RDDemoBadge() }
    if !isActive { RDStatusBadge(text: "Pasif") }
  }
}

/// Telefon numarası: dokununca arama açılır.
struct PhoneRow: View {
  let phone: String

  var body: some View {
    if let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
      Link(destination: url) {
        RDRow(symbol: "phone", symbolTint: RDColor.brandText, title: phone, subtitle: "Ara")
      }
      .accessibilityLabel("Ara: \(phone)")
    } else {
      RDInfoRow(label: "Telefon", value: phone, selectable: true)
    }
  }
}

/// Kart ekranlarının başlık bloğu (ad, etiketler ve alt satır).
struct RecordHeader<Badges: View>: View {
  let title: String
  var subtitle: String?
  @ViewBuilder var badges: Badges

  var body: some View {
    VStack(alignment: .leading, spacing: .rdS) {
      HStack(spacing: .rdS) { badges }
      Text(title)
        .font(RDFont.sectionTitle)
        .foregroundStyle(RDColor.textPrimary)
      if let subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(RDFont.secondary)
          .foregroundStyle(RDColor.textSecondary)
      }
    }
    .padding(.vertical, .rdXS)
  }
}

/// İş kolu seçici (boş seçenekli).
struct TradePicker: View {
  @Binding var selection: WorkTrade?

  var body: some View {
    Picker("İş kolu", selection: $selection) {
      Text("Belirtilmedi").tag(WorkTrade?.none)
      ForEach(WorkTrade.allCases) { Text($0.title).tag(Optional($0)) }
    }
  }
}

/// Liste ekranlarının "Pasifleri göster" filtresi.
struct InactiveFilterMenu: View {
  @Binding var showInactive: Bool

  var body: some View {
    Menu {
      Toggle("Pasif kayıtları göster", isOn: $showInactive)
    } label: {
      Label("Filtre", systemImage: "line.3.horizontal.decrease.circle")
    }
  }
}

/// Basit kaydet/vazgeç araç çubuğu (form sayfaları için).
struct SheetToolbar: ToolbarContent {
  let confirmTitle: String
  let canConfirm: Bool
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) { Button("Vazgeç", action: onCancel) }
    ToolbarItem(placement: .confirmationAction) {
      Button(confirmTitle, action: onConfirm)
        .fontWeight(.semibold)
        .disabled(!canConfirm)
    }
  }
}
