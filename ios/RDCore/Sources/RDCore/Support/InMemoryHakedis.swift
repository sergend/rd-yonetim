import Foundation

/// Sözleşme ve hakedişin bellek içi uygulaması (önizleme ve birim testleri).
/// Veritabanındaki kuralları basitçe taklit eder: tek açık hakediş, imalatın
/// bir kez kullanılması, onaylı kaydın değişmemesi, teminat bakiyesi, deftere
/// tek kez işleme ve ödemenin ödemeye uygun tutarı aşmaması. Günlük kalemler
/// burada puantajdan beslenmez (sıfır gelir); puantaj bağlantısı ve asıl
/// kurallar veritabanındadır ve pgTAP 090/091 ile test edilir.
extension InMemoryBackend {
  public func seedContracts(contracts: [Contract] = [], versions: [ContractVersion] = [], items: [ContractItem] = [],
                            taxCodes: [UUID: [String]] = [:], taxRules: [TaxRule] = [],
                            paymentSources: [PaymentSource] = [], workQuantities: [WorkQuantity] = []) {
    contractList += contracts
    contractVersions += versions
    contractItems += items
    contractTaxCodes.merge(taxCodes) { $1 }
    taxRuleList += taxRules
    paymentSourceList += paymentSources
    workQuantityList += workQuantities
  }

  private func require(_ key: PermissionKey, _ projectId: UUID, _ message: String) throws {
    guard access.can(key, in: projectId) else { throw RepositoryError.forbidden(message) }
  }

  private func event(_ entity: String, _ id: UUID, _ action: String, from: String? = nil, to: String? = nil,
                     reason: String? = nil) {
    financeEventList.append(FinanceEvent(entity: entity, entityId: id, action: action, fromStatus: from,
                                         toStatus: to, reason: reason, actorId: profile.id))
  }

  private func eventContract(_ entity: String, _ entityId: UUID) -> UUID? {
    switch entity {
    case "sozlesme": entityId
    case "imalat": workQuantityList.first { $0.id == entityId }?.contractId
    case "hakedis": hakedisRecords.first { $0.id == entityId }?.contractId
    case "teminat": teminatReleaseList.first { $0.id == entityId }?.contractId
    case "odeme": financePaymentList.first { $0.id == entityId }?.contractId
    default: nil
    }
  }

  private func contractIndex(_ id: UUID) throws -> Int {
    guard let index = contractList.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    return index
  }

  func approvedVersion(contractId: UUID) -> ContractVersion? {
    contractVersions.first { $0.contractId == contractId && $0.status == .onaylandi }
  }

  // MARK: Sözleşme

  func listContracts(projectId: UUID?) throws -> [Contract] {
    try failIfNeeded()
    return contractList.filter { (projectId == nil || $0.projectId == projectId) && access.can(.sozlesmeRead, in: $0.projectId) }
      .sorted { $0.contractNo < $1.contractNo }
  }

  func listVersions(contractId: UUID) throws -> [ContractVersion] {
    try failIfNeeded()
    let contract = try contractList[contractIndex(contractId)]
    guard access.can(.sozlesmeRead, in: contract.projectId) else { return [] }
    return contractVersions.filter { $0.contractId == contractId }.sorted { $0.revision > $1.revision }
  }

  func listItems(versionId: UUID) throws -> [ContractItem] {
    try failIfNeeded()
    guard let version = contractVersions.first(where: { $0.id == versionId }),
          let contract = contractList.first(where: { $0.id == version.contractId }),
          access.can(.sozlesmeRead, in: contract.projectId) else { return [] }
    return contractItems.filter { $0.versionId == versionId }.sorted { $0.lineNo < $1.lineNo }
  }

  func saveContract(id: UUID, draft: ContractDraft, expectedVersion: Int?) throws -> Contract {
    try failIfNeeded()
    try require(.sozlesmeWrite, draft.projectId, "Sözleşme düzenleme yetkiniz yok")
    guard let sub = subcontractorList.first(where: { $0.id == draft.subcontractorId }) else { throw RepositoryError.notFound }
    guard let cari = sub.cariAccountId else {
      throw RepositoryError.validation("Taşeronun cari kartı yok. Önce taşeron kartına mevcut cariyi bağlayın.")
    }
    guard !draft.items.isEmpty else { throw RepositoryError.validation("Sözleşmede en az bir kalem olmalı.") }
    if let message = draft.items.compactMap(\.validationMessage).first { throw RepositoryError.validation(message) }
    let number = draft.contractNo.trimmingCharacters(in: .whitespaces).uppercased()
    if contractList.contains(where: { $0.contractNo == number && $0.id != id }) {
      throw RepositoryError.conflict("Bu sözleşme numarası zaten kullanılıyor.")
    }

    var contract: Contract
    var version: ContractVersion
    if let index = contractList.firstIndex(where: { $0.id == id }) {
      contract = contractList[index]
      if let expectedVersion, expectedVersion != contract.version { throw RepositoryError.conflict(nil) }
      guard let draftIndex = contractVersions.firstIndex(where: { $0.contractId == id && $0.status == .taslak }) else {
        throw RepositoryError.validation("Onaylı sözleşme değiştirilemez; önce revizyon açın.")
      }
      version = contractVersions[draftIndex]
      contract.title = draft.title
      contract.signedDate = draft.signedDate
      if contract.status == .taslak {
        contract.contractNo = number
        contract.subcontractorId = draft.subcontractorId
        contract.cariAccountId = cari
      }
      contract.version += 1
      contractList[index] = contract
      contractVersions.remove(at: draftIndex)
    } else {
      contract = Contract(id: id, contractNo: number, projectId: draft.projectId, subcontractorId: draft.subcontractorId,
                          cariAccountId: cari, title: draft.title, signedDate: draft.signedDate,
                          currency: draft.currency, isDemo: sub.isDemo)
      contractList.append(contract)
      version = ContractVersion(contractId: id)
      event("sozlesme", id, "olustur", to: "taslak")
    }
    version.scope = draft.scope
    version.startDate = draft.startDate
    version.endDate = draft.endDate
    version.totalAmount = draft.totalAmount
    version.retentionRate = draft.retentionRate
    version.advanceDeductionRate = draft.advanceDeductionRate
    version.paymentTerms = draft.paymentTerms
    version.notes = draft.notes
    contractVersions.append(version)
    contractItems.removeAll { $0.versionId == version.id }
    for (index, item) in draft.items.enumerated() {
      contractItems.append(ContractItem(versionId: version.id, contractId: id, itemKey: item.itemKey, lineNo: index + 1,
                                        method: item.method, description: item.description, unit: item.unit.rawValue,
                                        quantity: item.quantity, unitPrice: item.unitPrice,
                                        overtimeUnitPrice: item.overtimeUnitPrice,
                                        paidBases: item.paidBases.map(\.rawValue), personnelId: item.personnelId))
    }
    contractTaxCodes[version.id] = draft.taxCodes
    return contract
  }

  func transitionContract(id: UUID, action: ContractAction, reason: String?, expectedVersion: Int?) throws -> Contract {
    try failIfNeeded()
    let index = try contractIndex(id)
    var contract = contractList[index]
    if let expectedVersion, expectedVersion != contract.version { throw RepositoryError.conflict(nil) }
    switch action {
    case .onayla:
      try require(.sozlesmeApprove, contract.projectId, "Sözleşme onaylama yetkiniz yok")
      guard let draftIndex = contractVersions.firstIndex(where: { $0.contractId == id && $0.status == .taslak }) else {
        throw RepositoryError.validation("Onaylanacak taslak revizyon yok.")
      }
      for item in contractItems where item.versionId == contractVersions[draftIndex].id {
        let used = usage(contractId: id, itemKey: item.itemKey, except: nil).quantity
        if let quantity = item.quantity, item.method != .goturu, quantity < used {
          throw RepositoryError.validation("\(item.description): miktar kullanılan \(used) altına inemez.")
        }
      }
      if let old = contractVersions.firstIndex(where: { $0.contractId == id && $0.status == .onaylandi }) {
        contractVersions[old].status = .yerineGecildi
      }
      contractVersions[draftIndex].status = .onaylandi
      contractVersions[draftIndex].approvedAt = Date()
      contract.status = .aktif
    case .revizyon:
      try require(.sozlesmeWrite, contract.projectId, "Sözleşme düzenleme yetkiniz yok")
      guard (reason?.trimmingCharacters(in: .whitespaces).count ?? 0) >= 10 else {
        throw RepositoryError.validation("Revizyon gerekçesi en az 10 karakter olmalı.")
      }
      guard !contractVersions.contains(where: { $0.contractId == id && $0.status == .taslak }),
            let current = approvedVersion(contractId: id) else {
        throw RepositoryError.validation("Açık bir taslak revizyon var veya sözleşme onaylı değil.")
      }
      var next = current
      next = ContractVersion(contractId: id, revision: current.revision + 1, scope: current.scope,
                             startDate: current.startDate, endDate: current.endDate, totalAmount: current.totalAmount,
                             retentionRate: current.retentionRate, advanceDeductionRate: current.advanceDeductionRate,
                             paymentTerms: current.paymentTerms, notes: current.notes, reason: reason)
      contractVersions.append(next)
      for item in contractItems where item.versionId == current.id {
        var copy = item
        copy = ContractItem(versionId: next.id, contractId: id, itemKey: item.itemKey, lineNo: item.lineNo,
                            method: item.method, description: item.description, unit: item.unit,
                            quantity: item.quantity, unitPrice: item.unitPrice,
                            overtimeUnitPrice: item.overtimeUnitPrice, paidBases: item.paidBases,
                            personnelId: item.personnelId)
        contractItems.append(copy)
      }
      contractTaxCodes[next.id] = contractTaxCodes[current.id] ?? []
    case .kapat, .iptal:
      try require(.sozlesmeApprove, contract.projectId, "Sözleşmeyi kapatma yetkiniz yok")
      if hakedisRecords.contains(where: { $0.contractId == id && $0.status.isOpen }) {
        throw RepositoryError.validation("Açık hakediş varken sözleşme kapatılamaz.")
      }
      if action == .iptal, hakedisRecords.contains(where: { $0.contractId == id && $0.status == .onaylandi }) {
        throw RepositoryError.validation("Onaylı hakedişi olan sözleşme iptal edilemez; kapatın.")
      }
      contract.status = action == .kapat ? .kapandi : .iptal
    }
    event("sozlesme", id, action.rawValue, to: contract.status.rawValue, reason: reason)
    contract.version += 1
    contractList[index] = contract
    return contract
  }

  // MARK: İmalat

  func listImalatItems(projectId: UUID) throws -> [ImalatItem] {
    try failIfNeeded()
    try require(.imalatRead, projectId, "İmalat görme yetkiniz yok")
    return contractList.filter { $0.projectId == projectId && $0.status == .aktif }.flatMap { contract in
      let version = approvedVersion(contractId: contract.id)
      let name = subcontractorList.first { $0.id == contract.subcontractorId }?.name ?? ""
      return contractItems.filter { $0.versionId == version?.id && $0.method == .birimFiyat }
        .sorted { $0.lineNo < $1.lineNo }
        .map { item in
          let rows = workQuantityList.filter { $0.contractId == contract.id && $0.itemKey == item.itemKey }
          return ImalatItem(contractId: contract.id, contractNo: contract.contractNo, subcontractorName: name,
                            itemKey: item.itemKey, description: item.description, unit: item.unit,
                            contractQuantity: item.quantity,
                            approvedQuantity: rows.filter { $0.status == .onaylandi }.reduce(0) { $0 + $1.quantity },
                            pendingQuantity: rows.filter { $0.status == .taslak }.reduce(0) { $0 + $1.quantity })
        }
    }
  }

  func listWorkQuantities(contractId: UUID) throws -> [WorkQuantity] {
    try failIfNeeded()
    let contract = try contractList[contractIndex(contractId)]
    guard access.can(.imalatRead, in: contract.projectId) else { return [] }
    return workQuantityList.filter { $0.contractId == contractId }.sorted { $0.workDate > $1.workDate }
  }

  func saveWorkQuantity(_ input: WorkQuantity) throws -> WorkQuantity {
    try failIfNeeded()
    let contract = try contractList[contractIndex(input.contractId)]
    try require(.imalatWrite, contract.projectId, "İmalat girme yetkiniz yok")
    guard input.quantity > 0, HakedisMath.scale(input.quantity) <= 3 else {
      throw RepositoryError.validation("Miktar sıfırdan büyük ve en çok 3 ondalık olmalı.")
    }
    guard input.workDate <= today else { throw RepositoryError.validation("İleri tarihli imalat girilemez.") }
    guard let version = approvedVersion(contractId: contract.id),
          contractItems.contains(where: { $0.versionId == version.id && $0.itemKey == input.itemKey && $0.method == .birimFiyat }) else {
      throw RepositoryError.validation("İmalat yalnızca onaylı sözleşmenin birim fiyatlı kalemine girilir.")
    }
    if let index = workQuantityList.firstIndex(where: { $0.id == input.id }) {
      guard workQuantityList[index].status == .taslak else {
        throw RepositoryError.validation("Onaylı imalat değiştirilemez; iptal edip yeniden girin.")
      }
      var row = input
      row.version = workQuantityList[index].version + 1
      workQuantityList[index] = row
      return row
    }
    var row = input
    row.projectId = contract.projectId
    row.status = .taslak
    row.isDemo = contract.isDemo
    workQuantityList.append(row)
    return row
  }

  func approveWorkQuantities(ids: [UUID]) throws -> Int {
    try failIfNeeded()
    var count = 0
    for index in workQuantityList.indices where ids.contains(workQuantityList[index].id) {
      try require(.imalatApprove, workQuantityList[index].projectId, "İmalat onaylama yetkiniz yok")
      guard workQuantityList[index].status == .taslak else { continue }
      workQuantityList[index].status = .onaylandi
      workQuantityList[index].version += 1
      count += 1
    }
    return count
  }

  func cancelWorkQuantity(id: UUID, reason: String) throws -> WorkQuantity {
    try failIfNeeded()
    guard let index = workQuantityList.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    try require(.imalatWrite, workQuantityList[index].projectId, "İmalat iptal yetkiniz yok")
    if workQuantityList[index].status != .taslak {
      try require(.imalatApprove, workQuantityList[index].projectId, "Onaylı imalatı iptal yetkiniz yok")
    }
    if quantityLinks[id] != nil {
      throw RepositoryError.validation("Hakedişte kullanılan imalat iptal edilemez; önce hakediş düzeltilmeli.")
    }
    workQuantityList[index].status = .iptal
    workQuantityList[index].version += 1
    event("imalat", id, "iptal", reason: reason)
    return workQuantityList[index]
  }

  // MARK: Hakediş

  private func hakedisIndex(_ id: UUID) throws -> Int {
    guard let index = hakedisRecords.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    return index
  }

  func listHakedis(contractId: UUID?) throws -> [Hakedis] {
    try failIfNeeded()
    return hakedisRecords.filter { (contractId == nil || $0.contractId == contractId) && access.can(.hakedisRead, in: $0.projectId) }
      .sorted { ($0.contractId.uuidString, $0.hakedisNo) > ($1.contractId.uuidString, $1.hakedisNo) }
  }

  func getHakedis(id: UUID) throws -> Hakedis {
    try failIfNeeded()
    let hakedis = try hakedisRecords[hakedisIndex(id)]
    guard access.can(.hakedisRead, in: hakedis.projectId) else { throw RepositoryError.notFound }
    return hakedis
  }

  func listLines(hakedisId: UUID) throws -> [HakedisLine] {
    _ = try getHakedis(id: hakedisId)
    return hakedisLineList.filter { $0.hakedisId == hakedisId }
  }

  func listAdjustments(hakedisId: UUID) throws -> [HakedisAdjustment] {
    _ = try getHakedis(id: hakedisId)
    return hakedisAdjustmentList.filter { $0.hakedisId == hakedisId }
  }

  /// Onaylı hakedişlerde kalemin kullanılan miktar ve tutarı.
  private func usage(contractId: UUID, itemKey: UUID, except: UUID?) -> (quantity: Decimal, amount: Decimal) {
    let approved = Set(hakedisRecords.filter { $0.contractId == contractId && $0.status == .onaylandi && $0.id != except }.map(\.id))
    let lines = hakedisLineList.filter { approved.contains($0.hakedisId) && $0.itemKey == itemKey && $0.lineKind == .ana }
    return (lines.reduce(0) { $0 + $1.quantity }, lines.reduce(0) { $0 + $1.amount })
  }

  func createHakedis(id: UUID, contractId: UUID, periodStart: CalendarDate, periodEnd: CalendarDate,
                     note: String?) throws -> Hakedis {
    try failIfNeeded()
    if let existing = hakedisRecords.first(where: { $0.id == id }) { return existing }
    let contract = try contractList[contractIndex(contractId)]
    try require(.hakedisPrepare, contract.projectId, "Hakediş hazırlama yetkiniz yok")
    guard contract.status == .aktif, let version = approvedVersion(contractId: contractId) else {
      throw RepositoryError.validation("Hakediş yalnızca onaylı (aktif) sözleşmeye açılır.")
    }
    guard periodStart <= periodEnd else { throw RepositoryError.validation("Dönem başı bitişten sonra olamaz.") }
    if hakedisRecords.contains(where: { $0.contractId == contractId && $0.status.isOpen }) {
      throw RepositoryError.conflict("Bu sözleşmede açık (taslak veya incelemede) bir hakediş var.")
    }
    let number = (hakedisRecords.filter { $0.contractId == contractId }.map(\.hakedisNo).max() ?? 0) + 1
    hakedisRecords.append(Hakedis(id: id, contractId: contractId, versionId: version.id, projectId: contract.projectId,
                                  subcontractorId: contract.subcontractorId, cariAccountId: contract.cariAccountId,
                                  hakedisNo: number, periodStart: periodStart, periodEnd: periodEnd,
                                  currency: contract.currency, note: note, isDemo: contract.isDemo))
    event("hakedis", id, "olustur", to: "taslak")
    try refresh(id)
    return try hakedisRecords[hakedisIndex(id)]
  }

  /// Satırları, kesintileri ve tutarları yeniden hesaplar.
  private func refresh(_ id: UUID) throws {
    let index = try hakedisIndex(id)
    var h = hakedisRecords[index]
    guard h.status.isOpen, let version = approvedVersion(contractId: h.contractId) else { return }
    h.versionId = version.id
    let oldLines = hakedisLineList.filter { $0.hakedisId == id }
    hakedisLineList.removeAll { $0.hakedisId == id }
    for (key, owner) in quantityLinks where owner == id { quantityLinks[key] = nil }

    var messages: [String] = []
    for item in contractItems.filter({ $0.versionId == version.id }).sorted(by: { $0.lineNo < $1.lineNo }) {
      let previous = usage(contractId: h.contractId, itemKey: item.itemKey, except: id)
      var line = HakedisLine(hakedisId: id, itemKey: item.itemKey, method: item.method, description: item.description,
                             unit: item.unit, unitPrice: item.unitPrice, contractQuantity: item.quantity,
                             previousQuantity: previous.quantity, previousAmount: previous.amount)
      switch item.method {
      case .birimFiyat:
        let rows = workQuantityList.filter {
          $0.contractId == h.contractId && $0.itemKey == item.itemKey && $0.status == .onaylandi
            && $0.workDate <= h.periodEnd && quantityLinks[$0.id] == nil
        }
        for row in rows { quantityLinks[row.id] = id }
        line.quantity = rows.reduce(0) { $0 + $1.quantity }
        line.amount = HakedisMath.amount(line.quantity, item.unitPrice)
      case .goturu:
        let percent = oldLines.first { $0.itemKey == item.itemKey }?.progressPercent ?? previous.quantity
        line.progressPercent = percent
        line.quantity = percent - previous.quantity
        line.amount = HakedisMath.lumpSum(price: item.unitPrice, cumulativePercent: percent, previousAmount: previous.amount)
      case .gunluk:
        line.quantity = 0  // puantaj bağlantısı yalnızca sunucuda
      }
      line.cumulativeQuantity = line.previousQuantity + line.quantity
      line.cumulativeAmount = line.previousAmount + line.amount
      if let limit = item.quantity, item.method != .goturu, line.cumulativeQuantity > limit {
        messages.append("\(item.description): kümülatif \(line.cumulativeQuantity) sözleşme miktarı \(limit) üstünde")
      }
      hakedisLineList.append(line)
    }

    let gross = hakedisLineList.filter { $0.hakedisId == id }.reduce(Decimal.zero) { $0 + $1.amount }
    if let cap = version.totalAmount {
      let cumulative = hakedisRecords.filter { $0.contractId == h.contractId && $0.status == .onaylandi && $0.id != id }
        .reduce(Decimal.zero) { $0 + $1.grossAmount } + gross
      if cumulative > cap { messages.append("Kümülatif brüt \(Money.format(cumulative)) sözleşme bedeli \(Money.format(cap)) üstünde") }
    }

    let manual = hakedisAdjustmentList.filter { $0.hakedisId == id && $0.isManual }
    hakedisAdjustmentList.removeAll { $0.hakedisId == id }
    var adjustments: [HakedisAdjustment] = []
    var kdv: Decimal = 0
    let rules = (contractTaxCodes[version.id] ?? []).compactMap { code in
      taxRuleList.first { $0.code == code && $0.isActive && $0.validFrom <= h.periodEnd && ($0.validTo ?? h.periodEnd) >= h.periodEnd }
    }
    for code in contractTaxCodes[version.id] ?? [] {
      guard let rule = rules.first(where: { $0.code == code }), rule.isVerified else {
        throw RepositoryError.validation("\(code) vergi kuralı dönem için doğrulanmamış veya geçerli değil.")
      }
    }
    for rule in rules where rule.kind == .kdv {
      let amount = HakedisMath.percent(gross, rule.rate)
      kdv += amount
      adjustments.append(HakedisAdjustment(hakedisId: id, kind: .kdv, taxCode: rule.code, baseAmount: gross,
                                           rate: rule.rate, amount: amount, description: rule.name))
    }
    var stopaj: Decimal = 0
    var other: Decimal = 0
    for rule in rules where rule.kind != .kdv {
      let base = rule.base == "kdv" ? kdv : gross
      let amount = HakedisMath.percent(base, rule.rate)
      if rule.kind == .stopaj { stopaj += amount } else { other += amount }
      adjustments.append(HakedisAdjustment(hakedisId: id, kind: rule.kind == .stopaj ? .stopaj : .digerKesinti,
                                           taxCode: rule.code, baseAmount: base, rate: rule.rate, amount: amount,
                                           description: rule.name))
    }
    let retention = HakedisMath.percent(gross, version.retentionRate)
    if retention > 0 {
      adjustments.append(HakedisAdjustment(hakedisId: id, kind: .teminat, baseAmount: gross, rate: version.retentionRate,
                                           amount: retention, description: "Teminat kesintisi"))
    }
    adjustments += manual
    other += manual.filter { $0.kind == .digerKesinti }.reduce(0) { $0 + $1.amount }
    let advance = manual.filter { $0.kind == .avansMahsubu }.reduce(Decimal.zero) { $0 + $1.amount }
    hakedisAdjustmentList += adjustments

    if gross != h.grossAmount { h.limitOverrideReason = nil }
    h.grossAmount = gross
    h.kdvAmount = kdv
    h.taxDeductionAmount = stopaj
    h.otherDeductionAmount = other
    h.retentionAmount = retention
    h.advanceAmount = advance
    h.payableAmount = HakedisMath.payable(gross: gross, kdv: kdv, stopaj: stopaj, other: other,
                                          retention: retention, advance: advance)
    h.limitMessages = messages
    h.limitExceeded = !messages.isEmpty
    h.version += 1
    hakedisRecords[index] = h
  }

  private func editable(_ id: UUID) throws -> Hakedis {
    let h = try hakedisRecords[hakedisIndex(id)]
    try require(.hakedisPrepare, h.projectId, "Hakediş hazırlama yetkiniz yok")
    guard h.status == .taslak else { throw RepositoryError.validation("Yalnızca taslak hakediş düzenlenir.") }
    return h
  }

  func refreshHakedis(id: UUID) throws -> Hakedis {
    try failIfNeeded()
    let h = try hakedisRecords[hakedisIndex(id)]
    try require(.hakedisPrepare, h.projectId, "Hakediş hazırlama yetkiniz yok")
    try refresh(id)
    return try hakedisRecords[hakedisIndex(id)]
  }

  func setProgress(hakedisId: UUID, itemKey: UUID, percent: Decimal) throws -> Hakedis {
    try failIfNeeded()
    let h = try editable(hakedisId)
    let previous = usage(contractId: h.contractId, itemKey: itemKey, except: h.id).quantity
    guard percent >= previous, percent <= 100 else {
      throw RepositoryError.validation("Kümülatif ilerleme \(previous) ile 100 arasında olmalı.")
    }
    guard let index = hakedisLineList.firstIndex(where: { $0.hakedisId == hakedisId && $0.itemKey == itemKey && $0.method == .goturu }) else {
      throw RepositoryError.validation("İlerleme yalnızca götürü kaleme girilir.")
    }
    hakedisLineList[index].progressPercent = percent
    try refresh(hakedisId)
    return try hakedisRecords[hakedisIndex(hakedisId)]
  }

  func openAdvance(cariAccountId: UUID, projectId: UUID) -> Decimal {
    let given = financePaymentList.filter { $0.kind == .avans && $0.status == .aktif }
      .filter { p in contractList.first { $0.id == p.contractId }.map { $0.cariAccountId == cariAccountId && $0.projectId == projectId } ?? false }
      .reduce(Decimal.zero) { $0 + $1.amount }
    let used = hakedisRecords.filter { $0.cariAccountId == cariAccountId && $0.projectId == projectId && $0.status == .onaylandi }
      .reduce(Decimal.zero) { $0 + $1.advanceAmount }
    return given - used
  }

  func setDeduction(hakedisId: UUID, kind: HakedisAdjustmentKind, amount: Decimal, description: String?) throws -> Hakedis {
    try failIfNeeded()
    let h = try editable(hakedisId)
    guard kind == .avansMahsubu || kind == .digerKesinti else {
      throw RepositoryError.validation("Bu kesinti elle girilemez; sözleşme kuralından hesaplanır.")
    }
    guard amount >= 0, HakedisMath.scale(amount) <= 2 else {
      throw RepositoryError.validation("Kesinti tutarı sıfır veya pozitif, en çok iki ondalıklı olmalı.")
    }
    if kind == .avansMahsubu, amount > openAdvance(cariAccountId: h.cariAccountId, projectId: h.projectId) {
      throw RepositoryError.validation("Avans mahsubu açık avans tutarını aşıyor.")
    }
    hakedisAdjustmentList.removeAll { $0.hakedisId == hakedisId && $0.kind == kind && $0.isManual }
    if amount > 0 {
      hakedisAdjustmentList.append(HakedisAdjustment(hakedisId: hakedisId, kind: kind, amount: amount,
                                                     description: description?.nilIfBlank ?? kind.title, isManual: true))
    }
    try refresh(hakedisId)
    return try hakedisRecords[hakedisIndex(hakedisId)]
  }

  func overrideLimit(hakedisId: UUID, reason: String) throws -> Hakedis {
    try failIfNeeded()
    let index = try hakedisIndex(hakedisId)
    try require(.hakedisLimitOverride, hakedisRecords[index].projectId, "Limit aşımı izni verme yetkiniz yok")
    guard hakedisRecords[index].limitExceeded, hakedisRecords[index].status.isOpen else {
      throw RepositoryError.validation("Bu hakedişte izin gerektiren limit aşımı yok.")
    }
    guard reason.trimmingCharacters(in: .whitespaces).count >= 10 else {
      throw RepositoryError.validation("Gerekçe en az 10 karakter olmalı.")
    }
    hakedisRecords[index].limitOverrideReason = reason
    hakedisRecords[index].version += 1
    event("hakedis", hakedisId, "limit_izni", reason: reason)
    return hakedisRecords[index]
  }

  func transitionHakedis(id: UUID, action: HakedisAction, reason: String?, expectedVersion: Int?) throws -> Hakedis {
    try failIfNeeded()
    let index = try hakedisIndex(id)
    var h = hakedisRecords[index]
    if let expectedVersion, expectedVersion != h.version {
      throw RepositoryError.conflict("Hakediş siz incelerken değişti. Yenileyip tekrar deneyin.")
    }
    let from = h.status
    switch (action, h.status) {
    case (.gonder, .taslak):
      try require(.hakedisPrepare, h.projectId, "Hakediş hazırlama yetkiniz yok")
      guard h.grossAmount > 0 else { throw RepositoryError.validation("Brüt tutarı sıfır olan hakediş gönderilemez.") }
      h.status = .incelemede
      h.submittedAt = Date()
    case (.iade, .incelemede):
      try require(.hakedisApprove, h.projectId, "Hakediş onaylama yetkiniz yok")
      h.status = .taslak
    case (.onayla, .incelemede):
      try require(.hakedisApprove, h.projectId, "Hakediş onaylama yetkiniz yok")
      try refresh(id)
      h = hakedisRecords[index]
      guard h.grossAmount > 0, h.payableAmount >= 0 else {
        throw RepositoryError.validation("Brüt sıfırdan büyük, ödemeye uygun tutar eksi olmamalı.")
      }
      guard !h.needsLimitOverride else {
        throw RepositoryError.validation("Limit aşımı var; onay için açık izin gerekir.")
      }
      h.status = .onaylandi
      h.approvedAt = Date()
      h.approvedBy = profile.id
    case (.iptal, .taslak), (.iptal, .incelemede):
      try require(.hakedisPrepare, h.projectId, "Hakediş hazırlama yetkiniz yok")
      for (key, owner) in quantityLinks where owner == id { quantityLinks[key] = nil }
      h.status = .iptal
      h.cancelledAt = Date()
      h.cancelReason = reason
    case (.iptal, .onaylandi):
      try require(.hakedisApprove, h.projectId, "Onaylı hakedişi iptal yetkiniz yok")
      guard (reason?.trimmingCharacters(in: .whitespaces).count ?? 0) >= 10 else {
        throw RepositoryError.validation("İptal gerekçesi en az 10 karakter olmalı.")
      }
      guard !financePaymentList.contains(where: { $0.hakedisId == id && $0.status == .aktif }) else {
        throw RepositoryError.validation("Ödemesi olan hakediş iptal edilemez; önce ödemeyi iptal edin.")
      }
      if h.isPosted, retentionBalance(contractId: h.contractId) < h.retentionAmount {
        throw RepositoryError.validation("Bu hakedişin teminatı serbest bırakılmış; önce iadeyi iptal edin.")
      }
      if h.isPosted { reverseEntries(of: id, reason: reason ?? "") }
      for (key, owner) in quantityLinks where owner == id { quantityLinks[key] = nil }
      h.status = .iptal
      h.cancelledAt = Date()
      h.cancelReason = reason
    default:
      throw RepositoryError.validation("Bu durumda '\(action.title)' yapılamaz.")
    }
    h.version += 1
    hakedisRecords[index] = h
    event("hakedis", id, action.rawValue, from: from.rawValue, to: h.status.rawValue, reason: reason)
    return h
  }

  func reviseHakedis(id: UUID, newId: UUID, reason: String) throws -> Hakedis {
    try failIfNeeded()
    if let existing = hakedisRecords.first(where: { $0.id == newId && $0.replacesId == id }) { return existing }
    let old = try hakedisRecords[hakedisIndex(id)]
    try require(.hakedisPrepare, old.projectId, "Hakediş hazırlama yetkiniz yok")
    let progress = hakedisLineList.filter { $0.hakedisId == id && $0.method == .goturu }
    let manual = hakedisAdjustmentList.filter { $0.hakedisId == id && $0.isManual }
    _ = try transitionHakedis(id: id, action: .iptal, reason: reason, expectedVersion: nil)
    var fresh = try createHakedis(id: newId, contractId: old.contractId, periodStart: old.periodStart,
                                  periodEnd: old.periodEnd, note: old.note)
    let index = try hakedisIndex(newId)
    hakedisRecords[index].replacesId = id
    for line in progress {
      if let target = hakedisLineList.firstIndex(where: { $0.hakedisId == newId && $0.itemKey == line.itemKey }) {
        hakedisLineList[target].progressPercent = line.progressPercent
      }
    }
    hakedisAdjustmentList += manual.map {
      HakedisAdjustment(hakedisId: newId, kind: $0.kind, amount: $0.amount, description: $0.description, isManual: true)
    }
    try refresh(newId)
    fresh = hakedisRecords[index]
    event("hakedis", id, "duzeltme", reason: reason)
    return fresh
  }

  // MARK: Deftere işleme, teminat, ödeme

  private func appendEntry(_ id: UUID, _ h: Contract, kind: CariEntryKind, direction: CariDirection, amount: Decimal,
                           date: CalendarDate, description: String) {
    entries.append(StoredEntry(draft: CariEntryDraft(id: id, cariAccountId: h.cariAccountId, scope: .project(h.projectId),
                                                     entryDate: date, direction: direction, kind: kind, amount: amount,
                                                     description: description, documentNo: h.contractNo),
                               reversalOf: nil, sequence: entries.count))
  }

  private func reverse(entryId: UUID, reason: String) {
    guard let original = entries.first(where: { $0.draft.id == entryId }),
          !entries.contains(where: { $0.reversalOf == entryId }) else { return }
    var draft = original.draft
    draft.id = UUID()
    draft.kind = .tersKayit
    draft.direction = draft.direction == .borc ? .alacak : .borc
    draft.entryDate = today
    draft.description = "İptal: \(reason)"
    entries.append(StoredEntry(draft: draft, reversalOf: entryId, sequence: entries.count))
  }

  private func reverseEntries(of hakedisId: UUID, reason: String) {
    for entryId in postedEntryIds[hakedisId] ?? [] { reverse(entryId: entryId, reason: reason) }
  }

  func postHakedis(id: UUID, entryDate: CalendarDate?, exchangeRate: Decimal? = nil) throws -> Hakedis {
    try failIfNeeded()
    let index = try hakedisIndex(id)
    var h = hakedisRecords[index]
    try require(.hakedisPost, h.projectId, "Hakedişi deftere işleme yetkiniz yok")
    if h.isPosted { return h }  // tekrar gönderim
    guard h.status == .onaylandi else { throw RepositoryError.validation("Yalnızca onaylı hakediş deftere işlenir.") }
    let contract = try contractList[contractIndex(h.contractId)]
    let rate = try HakedisMath.exchangeRate(currency: contract.currency, rate: exchangeRate)
    let date = entryDate ?? today
    let mainId = UUID()
    exchangeRates[mainId] = rate
    appendEntry(mainId, contract, kind: .hakedis, direction: .alacak, amount: h.grossAmount + h.kdvAmount, date: date,
                description: "\(h.title) · \(contract.title)")
    var ids = [mainId]
    for adjustment in hakedisAdjustmentList where adjustment.hakedisId == id
      && [.stopaj, .teminat, .digerKesinti].contains(adjustment.kind) && adjustment.amount > 0 {
      let entryId = UUID()
      appendEntry(entryId, contract, kind: .kesinti, direction: .borc, amount: adjustment.amount, date: date,
                  description: "\(adjustment.description) · \(h.title)")
      ids.append(entryId)
    }
    postedEntryIds[id] = ids
    h.postedAt = Date()
    h.cariEntryId = mainId
    h.version += 1
    hakedisRecords[index] = h
    event("hakedis", id, "deftere_isle")
    return h
  }

  func retentionBalance(contractId: UUID) -> Decimal {
    let withheld = hakedisRecords.filter { $0.contractId == contractId && $0.status == .onaylandi && $0.isPosted }
      .reduce(Decimal.zero) { $0 + $1.retentionAmount }
    let released = teminatReleaseList.filter { $0.contractId == contractId && $0.status == .aktif }
      .reduce(Decimal.zero) { $0 + $1.amount }
    return withheld - released
  }

  func listReleases(contractId: UUID) throws -> [TeminatRelease] {
    try failIfNeeded()
    let contract = try contractList[contractIndex(contractId)]
    guard access.can(.hakedisRead, in: contract.projectId) else { return [] }
    return teminatReleaseList.filter { $0.contractId == contractId }.sorted { $0.releaseDate > $1.releaseDate }
  }

  func releaseTeminat(id: UUID, contractId: UUID, amount: Decimal, reason: String, date: CalendarDate?,
                      exchangeRate: Decimal? = nil) throws -> TeminatRelease {
    try failIfNeeded()
    let contract = try contractList[contractIndex(contractId)]
    try require(.teminatRelease, contract.projectId, "Teminat serbest bırakma yetkiniz yok")
    let rate = try HakedisMath.exchangeRate(currency: contract.currency, rate: exchangeRate)
    if let existing = teminatReleaseList.first(where: { $0.id == id }) {
      guard existing.amount == amount, existing.contractId == contractId,
            existing.releaseDate == (date ?? existing.releaseDate), exchangeRates[id] == rate else {
        throw RepositoryError.conflict("Bu kimlikle farklı bir serbest bırakma var (tutar, tarih veya kur farklı).")
      }
      return existing
    }
    guard reason.trimmingCharacters(in: .whitespaces).count >= 10 else {
      throw RepositoryError.validation("Gerekçe en az 10 karakter olmalı.")
    }
    guard amount > 0, HakedisMath.scale(amount) <= 2 else { throw RepositoryError.validation("Tutar pozitif olmalı.") }
    let balance = retentionBalance(contractId: contractId)
    guard amount <= balance else {
      throw RepositoryError.validation("Serbest bırakılacak tutar biriken teminatı (\(Money.format(balance))) aşıyor.")
    }
    let release = TeminatRelease(id: id, contractId: contractId, amount: amount, releaseDate: date ?? today, reason: reason)
    teminatReleaseList.append(release)
    exchangeRates[id] = rate
    appendEntry(id, contract, kind: .teminatIadesi, direction: .alacak, amount: amount, date: release.releaseDate,
                description: "Teminat iadesi · \(contract.title)")
    event("teminat", id, "serbest_birak", to: "aktif", reason: reason)
    return release
  }

  func cancelRelease(id: UUID, reason: String) throws -> TeminatRelease {
    try failIfNeeded()
    guard let index = teminatReleaseList.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    let contract = try contractList[contractIndex(teminatReleaseList[index].contractId)]
    try require(.teminatRelease, contract.projectId, "Teminat iadesini iptal yetkiniz yok")
    guard teminatReleaseList[index].status == .aktif else { return teminatReleaseList[index] }
    guard !financePaymentList.contains(where: { $0.teminatReleaseId == id && $0.status == .aktif }) else {
      throw RepositoryError.validation("Ödemesi yapılmış teminat iadesi iptal edilemez; önce ödemeyi iptal edin.")
    }
    teminatReleaseList[index].status = .iptal
    teminatReleaseList[index].cancelReason = reason
    reverse(entryId: id, reason: reason)
    event("teminat", id, "iptal", from: "aktif", to: "iptal", reason: reason)
    return teminatReleaseList[index]
  }

  func listPayments(contractId: UUID) throws -> [FinancePayment] {
    try failIfNeeded()
    let contract = try contractList[contractIndex(contractId)]
    guard access.can(.hakedisRead, in: contract.projectId) else { return [] }
    return financePaymentList.filter { $0.contractId == contractId }.sorted { $0.paymentDate > $1.paymentDate }
  }

  private func paid(hakedisId: UUID) -> Decimal {
    financePaymentList.filter { $0.hakedisId == hakedisId && $0.status == .aktif }.reduce(0) { $0 + $1.amount }
  }

  func recordPayment(_ draft: FinancePaymentDraft) throws -> FinancePayment {
    try failIfNeeded()
    let contract = try contractList[contractIndex(draft.contractId)]
    try require(.odemeWrite, contract.projectId, "Ödeme kaydetme yetkiniz yok")
    var hakedisId: UUID?
    var releaseId: UUID?
    switch draft.target {
    case .hakedis(let id): hakedisId = id
    case .teminatRelease(let id): releaseId = id
    case .advance: break
    }
    let rate = try HakedisMath.exchangeRate(currency: contract.currency, rate: draft.exchangeRate)
    if let existing = financePaymentList.first(where: { $0.id == draft.id }) {
      guard existing.contractId == draft.contractId, existing.kind == draft.kind, existing.amount == draft.amount,
            existing.hakedisId == hakedisId, existing.teminatReleaseId == releaseId,
            existing.paymentSourceId == draft.paymentSourceId, existing.paymentDate == draft.paymentDate,
            exchangeRates[draft.id] == rate else {
        throw RepositoryError.conflict("Bu kimlikle farklı bir ödeme var (tutar, hedef, ödeme kaynağı, tarih veya kur farklı).")
      }
      return existing
    }
    guard draft.amount > 0, HakedisMath.scale(draft.amount) <= 2 else {
      throw RepositoryError.validation("Tutar pozitif ve en çok iki ondalıklı olmalı.")
    }
    guard paymentSourceList.contains(where: { $0.id == draft.paymentSourceId && $0.isActive }) else {
      throw RepositoryError.validation("Ödeme kaynağı bulunamadı veya pasif.")
    }
    if let hakedisId {
      guard let h = hakedisRecords.first(where: { $0.id == hakedisId && $0.contractId == contract.id }),
            h.status == .onaylandi, h.isPosted else {
        throw RepositoryError.validation("Ödeme yalnızca onaylanıp deftere işlenmiş hakedişe eşleştirilir.")
      }
      let remaining = h.payableAmount - paid(hakedisId: hakedisId)
      guard draft.amount <= remaining else {
        throw RepositoryError.validation("Ödeme kalan tutarı (\(Money.format(remaining))) aşıyor.")
      }
    }
    if let releaseId {
      guard let release = teminatReleaseList.first(where: { $0.id == releaseId }), release.status == .aktif else {
        throw RepositoryError.validation("Teminat iadesi bulunamadı veya iptal edilmiş.")
      }
      let paidRelease = financePaymentList.filter { $0.teminatReleaseId == releaseId && $0.status == .aktif }.reduce(Decimal.zero) { $0 + $1.amount }
      guard draft.amount <= release.amount - paidRelease else {
        throw RepositoryError.validation("Ödeme teminat iadesinin kalanını aşıyor.")
      }
    }
    if draft.kind == .avans {
      guard contract.status == .aktif else { throw RepositoryError.validation("Avans yalnızca aktif sözleşmeye verilir.") }
      if let limit = approvedVersion(contractId: contract.id)?.totalAmount {
        let given = financePaymentList.filter { $0.contractId == contract.id && $0.kind == .avans && $0.status == .aktif }
          .reduce(Decimal.zero) { $0 + $1.amount }
        guard given + draft.amount <= limit else {
          throw RepositoryError.validation("Toplam avans sözleşme bedelini (\(Money.format(limit, currency: contract.currency))) aşamaz.")
        }
      }
    }
    let payment = FinancePayment(id: draft.id, contractId: contract.id, kind: draft.kind, amount: draft.amount,
                                 paymentDate: draft.paymentDate, paymentSourceId: draft.paymentSourceId,
                                 hakedisId: hakedisId, teminatReleaseId: releaseId, description: draft.description)
    financePaymentList.append(payment)
    exchangeRates[draft.id] = rate
    appendEntry(draft.id, contract, kind: draft.kind == .avans ? .avans : .odeme, direction: .borc, amount: draft.amount,
                date: draft.paymentDate, description: draft.description ?? "\(draft.kind.title) · \(contract.title)")
    event("odeme", draft.id, "kaydet", to: "aktif")
    return payment
  }

  func cancelPayment(id: UUID, reason: String) throws -> FinancePayment {
    try failIfNeeded()
    guard let index = financePaymentList.firstIndex(where: { $0.id == id }) else { throw RepositoryError.notFound }
    let contract = try contractList[contractIndex(financePaymentList[index].contractId)]
    try require(.odemeWrite, contract.projectId, "Ödeme iptal yetkiniz yok")
    guard financePaymentList[index].status == .aktif else { return financePaymentList[index] }
    guard reason.trimmingCharacters(in: .whitespaces).count >= 10 else {
      throw RepositoryError.validation("Gerekçe en az 10 karakter olmalı.")
    }
    financePaymentList[index].status = .iptal
    financePaymentList[index].cancelReason = reason
    reverse(entryId: id, reason: reason)
    event("odeme", id, "iptal", from: "aktif", to: "iptal", reason: reason)
    return financePaymentList[index]
  }

  func financeSummary(contractId: UUID) throws -> ContractFinanceSummary {
    try failIfNeeded()
    let contract = try contractList[contractIndex(contractId)]
    try require(.hakedisRead, contract.projectId, "Sözleşme finans özetini görme yetkiniz yok")
    let approved = hakedisRecords.filter { $0.contractId == contractId && $0.status == .onaylandi }
    let payments = financePaymentList.filter { $0.contractId == contractId && $0.status == .aktif }
    func sum(_ key: KeyPath<Hakedis, Decimal>, _ rows: [Hakedis] = approved) -> Decimal { rows.reduce(0) { $0 + $1[keyPath: key] } }
    return ContractFinanceSummary(
      contractId: contractId, contractAmount: approvedVersion(contractId: contractId)?.totalAmount,
      grossTotal: sum(\.grossAmount), kdvTotal: sum(\.kdvAmount), taxDeductionTotal: sum(\.taxDeductionAmount),
      otherDeductionTotal: sum(\.otherDeductionAmount), advanceDeductedTotal: sum(\.advanceAmount),
      retentionWithheld: sum(\.retentionAmount),
      retentionReleased: teminatReleaseList.filter { $0.contractId == contractId && $0.status == .aktif }.reduce(0) { $0 + $1.amount },
      payableTotal: sum(\.payableAmount), unpostedPayable: sum(\.payableAmount, approved.filter { !$0.isPosted }),
      paidTotal: payments.filter { $0.kind == .odeme }.reduce(0) { $0 + $1.amount },
      advancePaidTotal: payments.filter { $0.kind == .avans }.reduce(0) { $0 + $1.amount },
      hakedisCount: approved.count)
  }

  func paymentStatus(hakedisIds: [UUID]) throws -> [HakedisPaymentStatus] {
    try failIfNeeded()
    return hakedisRecords.filter { hakedisIds.contains($0.id) && access.can(.hakedisRead, in: $0.projectId) }
      .map { HakedisPaymentStatus(hakedisId: $0.id, payableAmount: $0.payableAmount, paidAmount: paid(hakedisId: $0.id)) }
  }

  func listEvents(contractId: UUID) throws -> [FinanceEvent] {
    try failIfNeeded()
    let contract = try contractList[contractIndex(contractId)]
    guard access.can(.hakedisRead, in: contract.projectId) || access.can(.sozlesmeRead, in: contract.projectId) else { return [] }
    return financeEventList.filter { eventContract($0.entity, $0.entityId) == contractId }.sorted { $0.occurredAt > $1.occurredAt }
  }
}

struct InMemoryContracts: ContractRepository {
  let backend: InMemoryBackend

  func contracts(projectId: UUID?) async throws -> [Contract] { try await backend.listContracts(projectId: projectId) }
  func versions(contractId: UUID) async throws -> [ContractVersion] { try await backend.listVersions(contractId: contractId) }
  func items(versionId: UUID) async throws -> [ContractItem] { try await backend.listItems(versionId: versionId) }
  func taxCodes(versionId: UUID) async throws -> [String] { await backend.contractTaxCodes[versionId] ?? [] }
  func saveContract(id: UUID, draft: ContractDraft, expectedVersion: Int?) async throws -> Contract {
    try await backend.saveContract(id: id, draft: draft, expectedVersion: expectedVersion)
  }
  func transition(contractId: UUID, action: ContractAction, reason: String?, expectedVersion: Int?) async throws -> Contract {
    try await backend.transitionContract(id: contractId, action: action, reason: reason, expectedVersion: expectedVersion)
  }
  func taxRules() async throws -> [TaxRule] { await backend.taxRuleList }
  func paymentSources() async throws -> [PaymentSource] { await backend.paymentSourceList.filter(\.isActive) }

  func imalatItems(projectId: UUID) async throws -> [ImalatItem] { try await backend.listImalatItems(projectId: projectId) }
  func workQuantities(contractId: UUID) async throws -> [WorkQuantity] { try await backend.listWorkQuantities(contractId: contractId) }
  func saveWorkQuantity(_ quantity: WorkQuantity) async throws -> WorkQuantity { try await backend.saveWorkQuantity(quantity) }
  func approveWorkQuantities(ids: [UUID]) async throws -> Int { try await backend.approveWorkQuantities(ids: ids) }
  func cancelWorkQuantity(id: UUID, reason: String) async throws -> WorkQuantity {
    try await backend.cancelWorkQuantity(id: id, reason: reason)
  }

  func hakedisList(contractId: UUID?) async throws -> [Hakedis] { try await backend.listHakedis(contractId: contractId) }
  func hakedis(id: UUID) async throws -> Hakedis { try await backend.getHakedis(id: id) }
  func lines(hakedisId: UUID) async throws -> [HakedisLine] { try await backend.listLines(hakedisId: hakedisId) }
  func adjustments(hakedisId: UUID) async throws -> [HakedisAdjustment] { try await backend.listAdjustments(hakedisId: hakedisId) }
  func puantajLinks(hakedisId: UUID) async throws -> [HakedisPuantajLink] { [] }
  func createHakedis(id: UUID, contractId: UUID, periodStart: CalendarDate, periodEnd: CalendarDate,
                     note: String?) async throws -> Hakedis {
    try await backend.createHakedis(id: id, contractId: contractId, periodStart: periodStart, periodEnd: periodEnd, note: note)
  }
  func refreshHakedis(id: UUID) async throws -> Hakedis { try await backend.refreshHakedis(id: id) }
  func setProgress(hakedisId: UUID, itemKey: UUID, percent: Decimal) async throws -> Hakedis {
    try await backend.setProgress(hakedisId: hakedisId, itemKey: itemKey, percent: percent)
  }
  func setDeduction(hakedisId: UUID, kind: HakedisAdjustmentKind, amount: Decimal, description: String?) async throws -> Hakedis {
    try await backend.setDeduction(hakedisId: hakedisId, kind: kind, amount: amount, description: description)
  }
  func overrideLimit(hakedisId: UUID, reason: String) async throws -> Hakedis {
    try await backend.overrideLimit(hakedisId: hakedisId, reason: reason)
  }
  func transition(hakedisId: UUID, action: HakedisAction, reason: String?, expectedVersion: Int?) async throws -> Hakedis {
    try await backend.transitionHakedis(id: hakedisId, action: action, reason: reason, expectedVersion: expectedVersion)
  }
  func revise(hakedisId: UUID, newId: UUID, reason: String) async throws -> Hakedis {
    try await backend.reviseHakedis(id: hakedisId, newId: newId, reason: reason)
  }
  func post(hakedisId: UUID, entryDate: CalendarDate?, exchangeRate: Decimal?) async throws -> Hakedis {
    try await backend.postHakedis(id: hakedisId, entryDate: entryDate, exchangeRate: exchangeRate)
  }

  func teminatReleases(contractId: UUID) async throws -> [TeminatRelease] { try await backend.listReleases(contractId: contractId) }
  func releaseTeminat(id: UUID, contractId: UUID, amount: Decimal, reason: String,
                      date: CalendarDate?, exchangeRate: Decimal?) async throws -> TeminatRelease {
    try await backend.releaseTeminat(id: id, contractId: contractId, amount: amount, reason: reason, date: date,
                                     exchangeRate: exchangeRate)
  }
  func cancelTeminatRelease(id: UUID, reason: String) async throws -> TeminatRelease {
    try await backend.cancelRelease(id: id, reason: reason)
  }
  func payments(contractId: UUID) async throws -> [FinancePayment] { try await backend.listPayments(contractId: contractId) }
  func recordPayment(_ draft: FinancePaymentDraft) async throws -> FinancePayment { try await backend.recordPayment(draft) }
  func cancelPayment(id: UUID, reason: String) async throws -> FinancePayment {
    try await backend.cancelPayment(id: id, reason: reason)
  }
  func financeSummary(contractId: UUID) async throws -> ContractFinanceSummary {
    try await backend.financeSummary(contractId: contractId)
  }
  func paymentStatus(hakedisIds: [UUID]) async throws -> [HakedisPaymentStatus] {
    try await backend.paymentStatus(hakedisIds: hakedisIds)
  }
  func events(contractId: UUID) async throws -> [FinanceEvent] { try await backend.listEvents(contractId: contractId) }
}
