import RDCore
import RDDesign
import SwiftUI

// Malzeme, stok ve satın alma ekranlarının ortak parçaları (Aşama 7).
// Stok ekranları tutar göstermez; fiyat yalnızca satın alma detayında ve
// fiyat görme izni olana gösterilir. Ana sayfaya para bilgisi eklenmez.

extension StockMovementKind {
  /// Stok etkisinin yönü (liste ikonu rengi için; anlam metinle de verilir).
  var tint: Color {
    switch self {
    case .giris, .iadeDepo: RDColor.tone(.success)
    case .kullanim, .iadeTedarikci: RDColor.tone(.warning)
    case .transfer, .sayim: RDColor.brandText
    case .tersKayit: RDColor.textSecondary
    }
  }
}

/// CalendarDate ↔ DatePicker köprüsü.
func calendarBinding(_ get: @escaping () -> CalendarDate, _ set: @escaping (CalendarDate) -> Void) -> Binding<Date> {
  Binding(get: { get().date() }, set: { set(CalendarDate($0)) })
}

struct WarehouseLabel: View {
  let warehouse: Warehouse
  let projectName: String?

  var body: some View {
    RDRow(symbol: warehouse.kind == .genel ? "building.columns" : "archivebox", symbolTint: RDColor.brandText,
          title: warehouse.name, subtitle: projectName ?? warehouse.kind.title) {
      if warehouse.isDemo { RDDemoBadge() }
    } trailing: {
      EmptyView()
    }
  }
}

/// Stok satırı: malzeme, mevcut miktar ve onay bekleyen etki.
struct StockRow: View {
  let row: StockOverviewViewModel.Row
  let lookup: InventoryLookup

  var body: some View {
    let material = lookup.materials[row.materialId]
    RDRow(symbol: "shippingbox", symbolTint: RDColor.brandText, title: material?.name ?? "Malzeme",
          subtitle: subtitle) {
      if material?.isActive == false { RDStatusBadge(text: "Pasif") }
    } trailing: {
      Text(lookup.formatBase(row.quantity, material: row.materialId))
        .font(RDFont.rowTitle)
        .monospacedDigit()
        .foregroundStyle(row.quantity == 0 ? RDColor.textSecondary : RDColor.textPrimary)
    }
    .accessibilityElement(children: .combine)
  }

  private var subtitle: String? {
    var parts: [String] = []
    if let code = lookup.materials[row.materialId]?.code { parts.append(code) }
    if row.pendingOut > 0 { parts.append("onayda çıkış \(lookup.formatBase(row.pendingOut, material: row.materialId))") }
    if row.pendingIn > 0 { parts.append("onayda giriş \(lookup.formatBase(row.pendingIn, material: row.materialId))") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

/// Hareket satırı. `warehouseId` verilirse işaret o depoya göre gösterilir.
struct StockMovementRow: View {
  let movement: StockMovement
  let lookup: InventoryLookup
  var warehouseId: UUID?

  var body: some View {
    RDRow(symbol: movement.kind.symbol, symbolTint: movement.kind.tint,
          title: "\(movement.kind.title) · \(lookup.materialName(movement.materialId))", subtitle: subtitle) {
      if movement.isDemo { RDDemoBadge() }
      if movement.isReversed { RDStatusBadge(text: "İptal edildi") }
    } trailing: {
      VStack(alignment: .trailing, spacing: 2) {
        Text(quantityText).font(RDFont.rowTitle).monospacedDigit().foregroundStyle(RDColor.textPrimary)
        if movement.status != .onaylandi {
          RDStatusBadge(text: movement.status.title, tone: movement.status.tone)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var quantityText: String {
    if movement.kind == .sayim {
      guard let adjustment = movement.adjustment else { return "Sayılan \(lookup.format(movement.quantity, unit: movement.unitId))" }
      let sign = adjustment > 0 ? "+" : ""
      return sign + lookup.formatBase(adjustment, material: movement.materialId)
    }
    let base = lookup.format(movement.quantity, unit: movement.unitId)
    guard let warehouseId, movement.kind != .tersKayit else { return base }
    let incoming = movement.kind == .giris || movement.kind == .iadeDepo
      || (movement.kind == .transfer && movement.targetWarehouseId == warehouseId)
    return (incoming ? "+" : "−") + base
  }

  private var subtitle: String {
    var parts = [movement.movementNo, movement.movementDate.display]
    if movement.kind == .transfer {
      parts.append("\(lookup.warehouseName(movement.warehouseId)) → \(lookup.warehouseName(movement.targetWarehouseId))")
    } else if warehouseId == nil {
      parts.append(lookup.warehouseName(movement.warehouseId))
    }
    if let by = movement.performedBy { parts.append(by) }
    return parts.joined(separator: " · ")
  }
}

/// Sipariş satırı (liste). Tutar göstermez.
struct PurchaseOrderRow: View {
  let order: PurchaseOrder
  let supplierName: String
  let warehouseName: String

  var body: some View {
    RDRow(symbol: AppModule.satinAlma.symbol, symbolTint: RDColor.brandText, title: supplierName, subtitle: subtitle) {
      if order.isDemo { RDDemoBadge() }
    } trailing: {
      RDStatusBadge(text: order.status.title, tone: order.status.tone)
    }
  }

  private var subtitle: String {
    var parts = [order.orderNo, order.orderDate.display, warehouseName]
    if let expected = order.expectedDate, order.status.canReceive { parts.append("beklenen \(expected.display)") }
    return parts.joined(separator: " · ")
  }
}
