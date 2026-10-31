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
