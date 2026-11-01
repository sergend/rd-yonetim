import RDCore

// Alan durumlarının görsel tonu tek yerde tanımlanır; ekranlar bunları kullanır.

public extension ProjectStatus {
  var tone: StatusTone {
    switch self {
    case .planlama: .info
    case .devam: .success
    case .durdu: .warning
    case .tamamlandi: .neutral
    }
  }
}

public extension TaskPriority {
  var tone: StatusTone {
    switch self {
    case .dusuk: .neutral
    case .normal: .info
    case .yuksek: .danger
    }
  }
}

public extension TaskStatus {
  var tone: StatusTone {
    switch self {
    case .acik: .info
    case .devam: .warning
    case .tamamlandi: .success
    case .iptal: .neutral
    }
  }
}

public extension BalanceSide {
  /// Bakiye yönü rengi yalnızca finans ekranlarında kullanılır.
  var tone: StatusTone {
    switch self {
    case .theyOwe: .success
    case .weOwe: .danger
    case .settled: .neutral
    }
  }
}

public extension EmploymentType {
  var tone: StatusTone {
    switch self {
    case .sirket: .info
    case .taseron, .diger: .neutral
    }
  }
}

public extension PuantajStatus {
  /// Hücre rengi; anlam her zaman kısa harf ve erişilebilirlik metniyle de verilir.
  var tone: StatusTone {
    switch self {
    case .tamGun: .success
    case .yarimGun: .info
    case .calismadi: .danger
    case .ucretliIzin, .raporlu: .warning
    case .ucretsizIzin, .resmiTatil: .neutral
    }
  }
}

public extension PuantajPeriodStatus {
  var tone: StatusTone {
    switch self {
    case .taslak: .neutral
    case .incelemede: .info
    case .onaylandi: .success
    case .kilitli: .warning
    }
  }
}

public extension ContractStatus {
  var tone: StatusTone {
    switch self {
    case .taslak: .info
    case .aktif: .success
    case .kapandi: .neutral
    case .iptal: .danger
    }
  }
}

public extension HakedisStatus {
  var tone: StatusTone {
    switch self {
    case .taslak: .neutral
    case .incelemede: .warning
    case .onaylandi: .success
    case .iptal: .danger
    }
  }
}

public extension WorkQuantityStatus {
  var tone: StatusTone {
    switch self {
    case .taslak: .warning
    case .onaylandi: .success
    case .iptal: .danger
    }
  }
}

public extension FinanceDocStatus {
  var tone: StatusTone {
    switch self {
    case .taslak: .warning
    case .onaylandi: .success
    case .iptal: .neutral
    }
  }
}

/// Ödeme durumu: ödenmedi kırmızı değil turuncudur (vadesi geçmiş ayrıca belirtilir).
public extension FinanceSettlementState {
  var tone: StatusTone {
    switch self {
    case .taslak: .neutral
    case .iptal: .neutral
    case .acik: .warning
    case .kismi: .info
    case .kapandi: .success
    }
  }
}

// MARK: Aşama 7: stok ve satın alma

public extension StockMovementStatus {
  var tone: StatusTone {
    switch self {
    case .bekliyor: .warning
    case .onaylandi: .success
    case .reddedildi: .neutral
    }
  }
}

public extension PurchaseOrderStatus {
  var tone: StatusTone {
    switch self {
    case .taslak: .neutral
    case .onaylandi: .info
    case .kismiTeslim: .warning
    case .tamamlandi: .success
    case .iptal: .neutral
    }
  }
}
