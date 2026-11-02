import RDCore
import RDDesign
import SwiftUI

/// Ortadaki "+" ile açılan hızlı ekle seçenekleri. Her seçenek ilgili izne bağlıdır.
enum QuickAddAction: CaseIterable, Identifiable {
  case gider, odeme, puantaj, hakedis, cariHareket, belge

  var id: Self { self }

  var title: String {
    switch self {
    case .gider: "Gider"
    case .odeme: "Ödeme"
    case .puantaj: "Puantaj"
    case .hakedis: "Hakediş"
    case .cariHareket: "Cari hareket"
    case .belge: "Fiş / belge"
    }
  }

  var subtitle: String {
    switch self {
    case .gider: "Fiş, fatura, harcama"
    case .odeme: "Bekleyen borca ödeme"
    case .puantaj: "Günlük çalışma"
    case .hakedis: "Taşeron hakedişi"
    case .cariHareket: "Borç / alacak kaydı"
    case .belge: "Fotoğraf veya dosya"
    }
  }

  var symbol: String {
    switch self {
    case .gider: "receipt"
    case .odeme: "creditcard"
    case .puantaj: "calendar.badge.checkmark"
    case .hakedis: "doc.text"
    case .cariHareket: "arrow.left.arrow.right"
    case .belge: "camera"
    }
  }

  var tone: StatusTone {
    switch self {
    case .gider: .brand
    case .odeme: .success
    case .puantaj: .info
    case .hakedis: .warning
    case .cariHareket: .neutral
    case .belge: .neutral
    }
  }

  func isVisible(for access: AccessControl) -> Bool {
    switch self {
    case .gider: access.canAnywhere(.giderWrite)
    case .odeme: access.canAnywhere(.giderPay)
    case .puantaj: access.canAnywhere(.puantajWrite)
    case .hakedis: access.canAnywhere(.hakedisPrepare) || access.canAnywhere(.hakedisRead)
    case .cariHareket: access.canAnywhere(.cariHareketWrite)
    case .belge: access.canAnywhere(.belgeWrite)
    }
  }

  /// Gider doğrudan form olarak açılır (nil); diğerleri ilgili ekrana gider.
  var route: AppRoute? {
    switch self {
    case .gider: nil
    case .odeme: .payables(.gider)
    case .puantaj: .puantajProjects
    case .hakedis: .hakedisList
    case .cariHareket: .cariList(projectId: nil)
    case .belge: .documents(link: nil, title: nil, projectId: nil)
    }
  }
}

struct QuickAddSheet: View {
  let actions: [QuickAddAction]
  let perform: (QuickAddAction) -> Void
  @Environment(\.dismiss) private var dismiss

  private let columns = Array(repeating: GridItem(.flexible(), spacing: .rdM), count: 3)

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: columns, spacing: .rdM) {
          ForEach(actions) { action in
            Button { perform(action) } label: {
              VStack(spacing: .rdS) {
                Image(systemName: action.symbol)
                  .font(.title2.weight(.semibold))
                  .foregroundStyle(RDColor.tone(action.tone))
                  .frame(width: 52, height: 52)
                  .background(RoundedRectangle(cornerRadius: 14).fill(RDColor.tone(action.tone).opacity(0.12)))
                Text(action.title)
                  .font(RDFont.secondary.weight(.semibold))
                  .foregroundStyle(RDColor.textPrimary)
                  .multilineTextAlignment(.center)
                  .lineLimit(2)
              }
              .frame(maxWidth: .infinity, minHeight: 112)
              .background(RoundedRectangle(cornerRadius: CGFloat(Radius.large)).fill(RDColor.surface))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(action.subtitle)
          }
        }
        .padding(CGFloat.rdScreen)
      }
      .background(RDColor.background.ignoresSafeArea())
      .navigationTitle("Hızlı ekle")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
      }
    }
  }
}
