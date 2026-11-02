import RDCore
import RDDesign
import SwiftUI

/// Ay sonu hakediş raporu: en üstte taşeron özeti, altında her personelin aylık
/// puantaj takvimi, en altta toplamlar. Yalnızca okur; PDF olarak paylaşılabilir.
struct HakedisReportView: View {
  @State private var model: HakedisReportViewModel
  @State private var pdfURL: URL?
  private let app: AppModel

  init(hakedis: Hakedis, contract: Contract, app: AppModel) {
    self.app = app
    _model = State(initialValue: HakedisReportViewModel(hakedis: hakedis, contract: contract,
                                                        repositories: app.repositories))
  }

  var body: some View {
    ScrollView {
      VStack(spacing: .rdM) {
        if let error = model.errorMessage { RDErrorBanner(message: error) }
        HakedisReportContent(model: model, projectName: app.projectName(model.hakedis.projectId))
      }
      .padding(CGFloat.rdScreen)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .background(RDColor.background.ignoresSafeArea())
    .overlay { if model.isLoading && model.report.people.isEmpty { ProgressView() } }
    .navigationTitle("Ay sonu raporu")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let pdfURL {
        ToolbarItem(placement: .primaryAction) {
          ShareLink(item: pdfURL) { Label("PDF paylaş", systemImage: "square.and.arrow.up") }
        }
      }
    }
    .refreshable { await reload() }
    .task { await reload() }
  }

  @MainActor
  private func reload() async {
    await model.load()
    pdfURL = renderPDF()
  }

  /// Raporu tek sayfalık PDF olarak geçici klasöre yazar (açık tema, A4 genişliği).
  @MainActor
  private func renderPDF() -> URL? {
    let content = HakedisReportContent(model: model, projectName: app.projectName(model.hakedis.projectId))
      .padding(24)
      .frame(width: 595)
      .background(Color.white)
      .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: content)
    renderer.proposedSize = ProposedViewSize(width: 595, height: nil)
    let name = "Hakedis-\(model.contract.contractNo)-\(model.hakedis.hakedisNo)"
      .replacingOccurrences(of: "/", with: "-")
    let url = FileManager.default.temporaryDirectory.appending(path: "\(name).pdf")
    var created = false
    renderer.render { size, draw in
      var box = CGRect(origin: .zero, size: size)
      guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
      context.beginPDFPage(nil)
      draw(context)
      context.endPDFPage()
      context.closePDF()
      created = true
    }
    return created ? url : nil
  }
}

/// Raporun içeriği (ekran ve PDF aynı görünümü kullanır).
struct HakedisReportContent: View {
  let model: HakedisReportViewModel
  let projectName: String?

  private var report: HakedisMonthReport { model.report }
  private var hakedis: Hakedis { model.hakedis }
  private var currency: String { hakedis.currency }

  var body: some View {
    VStack(spacing: .rdM) {
      letterhead
      titleBlock
      summaryCard
      HakedisReportLegend()
      ForEach(report.people) { person in
        HakedisPersonCard(person: person, months: report.months, currency: currency)
      }
      if report.people.isEmpty && !model.isLoading {
        Text("Bu hakedişe bağlı puantaj günü yok. Birim fiyatlı veya götürü kalemlerde takvim gösterilmez.")
          .font(RDFont.caption)
          .foregroundStyle(RDColor.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(CGFloat.rdL)
          .reportCard()
      }
      totalsCard
    }
  }

  private var letterhead: some View {
    HStack(alignment: .center, spacing: .rdM) {
      RDLogoImage(kind: .full, height: 56)
      Spacer(minLength: .rdS)
      VStack(alignment: .trailing, spacing: 2) {
        Text("HAKEDİŞ RAPORU").font(RDFont.badge).foregroundStyle(RDColor.textPrimary)
        Text("Düzenleme: \(CalendarDate.today().dotted)").font(.caption2).foregroundStyle(RDColor.textSecondary)
      }
    }
    .padding(CGFloat.rdL)
    .reportCard()
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: .rdXS) {
      Text([projectName, hakedis.periodText].compactMap { $0 }.joined(separator: " · "))
        .font(RDFont.caption.weight(.semibold))
        .foregroundStyle(RDColor.textSecondary)
      Text("\(report.months.map(\.title).joined(separator: " – ")) Hakedişi")
        .font(.title2.weight(.bold))
        .foregroundStyle(RDColor.textPrimary)
      HStack(spacing: .rdS) {
        RDStatusBadge(text: hakedis.status.title, tone: hakedis.status.tone)
        Text("Hakediş no. \(hakedis.hakedisNo)").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, .rdXS)
  }

  private var summaryCard: some View {
    let breakdown = model.breakdown
    return VStack(spacing: 0) {
      HStack(spacing: .rdM) {
        Text(initials(model.subcontractorName ?? model.contract.title))
          .font(RDFont.rowTitle)
          .foregroundStyle(RDColor.onBrand)
          .frame(width: 44, height: 44)
          .background(RoundedRectangle(cornerRadius: 12).fill(RDColor.brand))
        VStack(alignment: .leading, spacing: 2) {
          Text(model.subcontractorName ?? model.contract.title).font(RDFont.rowTitle)
          Text("\(model.contract.contractNo) · \(model.contract.title)")
            .font(RDFont.caption).foregroundStyle(RDColor.textSecondary).lineLimit(2)
        }
        Spacer(minLength: 0)
      }
      .padding(CGFloat.rdL)
      Divider()
      HStack(spacing: 0) {
        metric("Personel", "\(report.people.count)")
        Divider()
        metric("Toplam gün", DecimalText.days(report.totalDays))
        Divider()
        metric("Fazla mesai", "\(DecimalText.days(report.people.reduce(Decimal(0)) { $0 + $1.overtimeHours })) sa")
      }
      .fixedSize(horizontal: false, vertical: true)
      Divider()
      VStack(spacing: .rdS) {
        MoneyRow(label: "Brüt hakediş", amount: breakdown.gross, currency: currency)
        if breakdown.kdv != 0 { MoneyRow(label: "KDV", amount: breakdown.kdv, currency: currency, sign: .plus) }
        if breakdown.stopaj != 0 { MoneyRow(label: "Stopaj", amount: breakdown.stopaj, currency: currency, sign: .minus) }
        if breakdown.retention != 0 {
          MoneyRow(label: "Teminat kesintisi", amount: breakdown.retention, currency: currency, sign: .minus)
        }
        if breakdown.advance != 0 { MoneyRow(label: "Avans mahsubu", amount: breakdown.advance, currency: currency, sign: .minus) }
        if breakdown.other != 0 { MoneyRow(label: "Diğer kesinti", amount: breakdown.other, currency: currency, sign: .minus) }
        Divider()
        HStack(alignment: .firstTextBaseline) {
          Text("Ödemeye uygun").font(RDFont.rowTitle)
          Spacer()
          Text(Money.format(breakdown.payable, currency: currency))
            .font(.title3.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(RDColor.brandText)
        }
        if breakdown.paid != 0 {
          MoneyRow(label: "Ödenen", amount: breakdown.paid, currency: currency)
          MoneyRow(label: "Kalan", amount: breakdown.remaining, currency: currency, emphasized: true)
        }
      }
      .padding(CGFloat.rdL)
    }
    .reportCard()
  }

  private var totalsCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Toplamlar").font(RDFont.sectionTitle).padding(CGFloat.rdL)
      if !report.people.isEmpty {
        totalsRow("Personel", "Gün", "Tutar", header: true)
        ForEach(report.people) { person in
          Divider()
          totalsRow(person.name, DecimalText.days(person.dayTotal),
                    person.amount.map { Money.format($0, currency: currency) } ?? "—")
        }
        Divider()
        totalsRow("Puantaj toplamı", DecimalText.days(report.totalDays),
                  Money.format(report.peopleAmountTotal, currency: currency), emphasized: true)
          .background(RDColor.background.opacity(0.6))
      }
      Divider()
      VStack(spacing: .rdS) {
        MoneyRow(label: "Brüt hakediş", amount: hakedis.grossAmount, currency: currency, emphasized: true)
        MoneyRow(label: "Toplam kesinti", amount: model.breakdown.deducted, currency: currency, sign: .minus)
        MoneyRow(label: "Ödemeye uygun", amount: hakedis.payableAmount, currency: currency, emphasized: true)
      }
      .padding(CGFloat.rdL)
      Text("Kişi tutarları, hakedişe bağlanan puantaj günleri ile sözleşmedeki günlük birim fiyattan hesaplanır; fazla mesai ve diğer kalemler brüt hakedişe ayrıca dahildir. \"Ödemeye uygun\" ödendiği anlamına gelmez.")
        .font(.caption2)
        .foregroundStyle(RDColor.textSecondary)
        .padding([.horizontal, .bottom], CGFloat.rdL)
    }
    .reportCard()
  }

  private func metric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(RDFont.caption.weight(.semibold)).foregroundStyle(RDColor.textSecondary)
      Text(value).font(RDFont.metric).monospacedDigit().foregroundStyle(RDColor.textPrimary)
        .lineLimit(1).minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, .rdL)
    .padding(.vertical, .rdM)
  }

  private func totalsRow(_ name: String, _ days: String, _ amount: String, header: Bool = false,
                         emphasized: Bool = false) -> some View {
    HStack(spacing: .rdS) {
      Text(name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
      Text(days).frame(width: 56, alignment: .trailing).monospacedDigit()
      Text(amount).frame(width: 120, alignment: .trailing).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
    }
    .font(header ? RDFont.caption.weight(.semibold) : (emphasized ? RDFont.rowTitle : RDFont.secondary))
    .foregroundStyle(header ? RDColor.textSecondary : RDColor.textPrimary)
    .padding(.horizontal, .rdL)
    .padding(.vertical, header ? .rdXS : .rdS)
  }

  private func initials(_ name: String) -> String {
    name.split(separator: " ").prefix(2).compactMap { word in word.first.map { letter in String(letter).uppercased() } }
      .joined()
  }
}

/// Bir personelin kartı: ad, gün ve tutar, aylık takvim ve sayım.
struct HakedisPersonCard: View {
  let person: HakedisReportPerson
  let months: [PuantajMonth]
  let currency: String

  private static let weekdays = ["Pzt", "Sal", "Çar", "Per", "Cum", "Cmt", "Paz"]

  private static func weeks(of month: PuantajMonth) -> [[HakedisCalendarCell]] {
    let cells = HakedisMonthReport.calendarCells(for: month)
    return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: .rdS) {
      HStack(spacing: .rdS) {
        Text(person.initials)
          .font(RDFont.caption.weight(.bold))
          .foregroundStyle(RDColor.textPrimary)
          .frame(width: 38, height: 38)
          .background(Circle().fill(RDColor.background))
        VStack(alignment: .leading, spacing: 1) {
          Text(person.name).font(RDFont.rowTitle).lineLimit(1)
          if let price = person.unitPrice {
            Text("\(Money.format(price, currency: currency))/gün").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
          }
        }
        Spacer(minLength: .rdS)
        VStack(alignment: .trailing, spacing: 1) {
          Text(person.amount.map { Money.format($0, currency: currency) } ?? "—")
            .font(RDFont.rowTitle).monospacedDigit()
          Text("\(DecimalText.days(person.dayTotal)) gün").font(RDFont.caption).foregroundStyle(RDColor.textSecondary)
        }
      }

      ForEach(months, id: \.self) { month in
        if months.count > 1 {
          Text(month.title).font(RDFont.caption.weight(.semibold)).foregroundStyle(RDColor.textSecondary)
        }
        // PDF çıktısında da çizilsin diye tembel (lazy) ızgara yerine satırlar.
        VStack(spacing: 4) {
          HStack(spacing: 4) {
            ForEach(Self.weekdays, id: \.self) { name in
              Text(name).font(.caption2.weight(.semibold)).foregroundStyle(RDColor.textSecondary)
                .frame(maxWidth: .infinity)
            }
          }
          ForEach(Self.weeks(of: month), id: \.first!.id) { week in
            HStack(spacing: 4) {
              ForEach(week) { cell in
                HakedisDayCell(date: cell.date, day: cell.date.flatMap { person.day($0) })
              }
            }
          }
        }
      }

      Divider()
      HStack {
        Text("Tam \(person.fullDays) · Yarım \(person.halfDays) · Gelmedi \(person.absentDays)"
             + (person.otherDays > 0 ? " · İzin/tatil \(person.otherDays)" : ""))
        Spacer(minLength: .rdS)
        if let price = person.unitPrice {
          Text("\(DecimalText.days(person.dayTotal)) × \(Money.format(price, currency: currency))").fontWeight(.semibold)
        }
      }
      .font(.caption2)
      .foregroundStyle(RDColor.textPrimary)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
    }
    .padding(CGFloat.rdM)
    .reportCard()
  }
}

/// Takvim hücresi: gün numarası ve gün karşılığı (1, ½, 0, –). Renk tek başına anlam taşımaz.
struct HakedisDayCell: View {
  let date: CalendarDate?
  let day: HakedisReportDay?

  var body: some View {
    VStack(spacing: 0) {
      Text(date.map { "\($0.day)" } ?? " ").font(.caption2.weight(.semibold))
      Text(mark).font(.caption2.weight(.bold))
    }
    .foregroundStyle(date == nil ? Color.clear : RDColor.tone(tone))
    .frame(maxWidth: .infinity, minHeight: 36)
    .background(RoundedRectangle(cornerRadius: 7).fill(date == nil ? Color.clear : fill))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
  }

  private var tone: StatusTone {
    guard let day else { return .neutral }
    switch day.status {
    case .tamGun: return .success
    case .yarimGun: return .warning
    case .calismadi, .ucretsizIzin: return .danger
    case .ucretliIzin, .raporlu, .resmiTatil: return .neutral
    }
  }

  private var fill: Color {
    day == nil ? RDColor.background : RDColor.tone(tone).opacity(0.13)
  }

  private var mark: String {
    guard let day else { return "·" }
    switch day.status {
    case .tamGun: return "1"
    case .yarimGun: return "½"
    case .calismadi, .ucretsizIzin: return "0"
    case .ucretliIzin, .raporlu, .resmiTatil: return "–"
    }
  }

  private var accessibilityText: String {
    guard let date else { return "" }
    return "\(date.day): \(day?.status.title ?? "Kayıt yok")"
  }
}

struct HakedisReportLegend: View {
  var body: some View {
    HStack(spacing: .rdM) {
      item("1", .success, "Tam gün")
      item("½", .warning, "Yarım gün")
      item("0", .danger, "Gelmedi")
      item("–", .neutral, "İzin / tatil")
    }
    .font(.caption2)
    .foregroundStyle(RDColor.textSecondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, .rdXS)
  }

  private func item(_ mark: String, _ tone: StatusTone, _ title: String) -> some View {
    HStack(spacing: 4) {
      Text(mark)
        .font(.caption2.weight(.bold))
        .foregroundStyle(RDColor.tone(tone))
        .frame(width: 18, height: 18)
        .background(RoundedRectangle(cornerRadius: 5).fill(RDColor.tone(tone).opacity(0.13)))
      Text(title)
    }
  }
}

/// Gün ve saat gösterimi: "25,5".
enum DecimalText {
  static func days(_ value: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Money.locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
  }
}

private extension View {
  func reportCard() -> some View {
    background(RoundedRectangle(cornerRadius: CGFloat(Radius.large)).fill(RDColor.surface))
  }
}
