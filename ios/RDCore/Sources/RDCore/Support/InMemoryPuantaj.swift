import Foundation

/// Puantajın bellek içi uygulaması. Veritabanı kurallarını (tek kayıt, tarihli
/// bağlantı, sürüm denetimi, atlama, ay kilidi, izinler) basitçe taklit eder;
/// asıl kurallar veritabanındadır ve pgTAP 080_puantaj ile test edilir.
extension InMemoryBackend {
  public func seedPuantaj(entries: [PuantajEntry] = [], periods: [PuantajPeriod] = []) {
    puantajEntries += entries
    puantajPeriods += periods
  }

  public func set(today: CalendarDate) { self.today = today }

  // MARK: Tarihli bağlantı

  func rosterLinks(projectId: UUID, month: PuantajMonth) -> [PuantajRosterLink] {
    var links: [PuantajRosterLink] = []
    let monthPeriod = DatePeriod(start: month.firstDay, end: month.lastDay)
    func clip(_ period: DatePeriod) -> (CalendarDate, CalendarDate)? {
      let start = max(period.start, month.firstDay)
      let end = min(period.end ?? month.lastDay, month.lastDay)
      return start <= end ? (start, end) : nil
    }
    for assignment in assignmentList where assignment.projectId == projectId && assignment.period.overlaps(monthPeriod) {
      if let personId = assignment.personnelId, let person = personnelList.first(where: { $0.id == personId }),
         let (start, end) = clip(assignment.period) {
        links.append(link(person, via: .dogrudan, crew: nil, assignment: assignment.id, membership: nil, start, end))
      } else if let crewId = assignment.crewId {
        let crew = crewList.first { $0.id == crewId }
        for membership in membershipList where membership.crewId == crewId && membership.period.overlaps(assignment.period) {
          guard let person = personnelList.first(where: { $0.id == membership.personnelId }) else { continue }
          let both = DatePeriod(start: max(assignment.startDate, membership.startDate),
                                end: [assignment.endDate, membership.endDate].compactMap { $0 }.min())
          guard let (start, end) = clip(both) else { continue }
          links.append(link(person, via: .ekip, crew: crew, assignment: assignment.id, membership: membership.id, start, end))
        }
      }
    }
    return links.sorted { ($0.crewName ?? "", $0.fullName, $0.startDate) < ($1.crewName ?? "", $1.fullName, $1.startDate) }
  }

  private func link(_ person: Personnel, via: WorkforceEntry.Via, crew: Crew?, assignment: UUID, membership: UUID?,
                    _ start: CalendarDate, _ end: CalendarDate) -> PuantajRosterLink {
    PuantajRosterLink(personnelId: person.id, fullName: person.fullName, jobTitle: person.jobTitle,
                      employmentType: person.employmentType, subcontractorId: person.subcontractorId,
                      subcontractorName: subcontractorList.first { $0.id == person.subcontractorId }?.name,
                      via: via, crewId: crew?.id, crewName: crew?.name, assignmentId: assignment,
                      membershipId: membership, startDate: start, endDate: end)
  }

  /// O gün geçerli bağlantı: önce doğrudan görevlendirme.
  private func activeLink(projectId: UUID, personnelId: UUID, day: CalendarDate) -> PuantajRosterLink? {
    let links = rosterLinks(projectId: projectId, month: PuantajMonth(containing: day))
      .filter { $0.personnelId == personnelId && $0.covers(day) }
    return links.first { $0.via == .dogrudan } ?? links.first
  }

  private func periodIndex(projectId: UUID, month: PuantajMonth) -> Int {
    if let index = puantajPeriods.firstIndex(where: { $0.projectId == projectId && $0.month == month.firstDay }) {
      return index
    }
    puantajPeriods.append(PuantajPeriod(projectId: projectId, month: month))
    return puantajPeriods.count - 1
  }

  // MARK: Okuma

  func puantajRoster(projectId: UUID, month: PuantajMonth) throws -> [PuantajRosterLink] {
    try failIfNeeded()
    guard access.can(.puantajRead, in: projectId) else { throw RepositoryError.forbidden("Bu projenin puantajını görme yetkiniz yok") }
    return rosterLinks(projectId: projectId, month: month)
  }

  func puantajEntries(projectId: UUID, month: PuantajMonth) throws -> [PuantajEntry] {
    try failIfNeeded()
    guard access.can(.puantajRead, in: projectId) else { return [] }
    return puantajEntries.filter { $0.projectId == projectId && month.contains($0.workDate) }
  }

  func puantajPeriod(projectId: UUID, month: PuantajMonth) throws -> PuantajPeriod? {
    try failIfNeeded()
    guard access.can(.puantajRead, in: projectId) else { return nil }
    return puantajPeriods.first { $0.projectId == projectId && $0.month == month.firstDay }
  }

  func puantajEvents(periodId: UUID) throws -> [PuantajPeriodEvent] {
    try failIfNeeded()
    return puantajEvents[periodId] ?? []
  }

  // MARK: Yazma

  func savePuantaj(projectId: UUID, items: [PuantajCellInput], overwrite: Bool) throws -> [PuantajSaveOutcome] {
    try failIfNeeded()
    saveCallCount += 1
    guard access.can(.puantajWrite, in: projectId) || access.can(.puantajReview, in: projectId) else {
      throw RepositoryError.forbidden("Bu projede puantaj girme yetkiniz yok")
    }
    guard !items.isEmpty else { throw RepositoryError.validation("Kaydedilecek hücre yok") }
    let keys = items.map { "\($0.personnelId)|\($0.workDate)" }
    guard Set(keys).count == keys.count else { throw RepositoryError.validation("Aynı kişi ve gün listede iki kez var") }
    let project = projects.first { $0.id == projectId }

    // Tek işlem: önce kopyada uygula, hata olursa hiçbirini yazma.
    var working = puantajEntries
    var outcomes: [PuantajSaveOutcome] = []
    for item in items.sorted(by: { ($0.personnelId.uuidString, $0.workDate) < ($1.personnelId.uuidString, $1.workDate) }) {
      let month = PuantajMonth(containing: item.workDate)
      let period = puantajPeriods[periodIndex(projectId: projectId, month: month)]
      guard let permission = period.status.editPermission else {
        throw RepositoryError.validation("\(month.title) puantajı \(period.status.title.lowercased(with: Money.locale)); değişiklik için ayın yeniden açılması gerekir")
      }
      guard access.can(permission, in: projectId) else {
        throw RepositoryError.forbidden(period.status == .incelemede
          ? "Ay incelemede; yalnızca inceleme yetkisi olan kişi değiştirebilir" : "Bu projede puantaj girme yetkiniz yok")
      }
      if let status = item.status {
        if item.overtimeHours > 0 && !status.allowsOvertime {
          throw RepositoryError.validation("Fazla mesai yalnızca tam veya yarım gün çalışılan güne yazılabilir")
        }
        if status.isWork && item.workDate > today {
          throw RepositoryError.validation("İleri bir tarihe çalışma girilemez (\(item.workDate.dotted))")
        }
      }

      let index = working.firstIndex { $0.projectId == projectId && $0.personnelId == item.personnelId && $0.workDate == item.workDate }
      func outcome(_ result: PuantajSaveResult, _ entry: PuantajEntry?) {
        outcomes.append(PuantajSaveOutcome(personnelId: item.personnelId, workDate: item.workDate, result: result,
                                           entryId: entry?.id, version: entry?.version))
      }
      guard let index else {
        guard let status = item.status else { outcome(.bos, nil); continue }
        guard let person = personnelList.first(where: { $0.id == item.personnelId }) else { throw RepositoryError.notFound }
        if person.isDemo != (project?.isDemo ?? false) {
          throw RepositoryError.validation("Demo kayıtlar gerçek kayıtlarla ilişkilendirilemez")
        }
        guard let link = activeLink(projectId: projectId, personnelId: item.personnelId, day: item.workDate) else {
          throw RepositoryError.validation("\(person.fullName) bu tarihte (\(item.workDate.dotted)) projede görevli değil; önce görevlendirme veya ekip üyeliği ekleyin")
        }
        let entry = PuantajEntry(projectId: projectId, personnelId: person.id, workDate: item.workDate, status: status,
                                 overtimeHours: item.overtimeHours, overtimeNote: item.overtimeNote, note: item.note,
                                 assignmentId: link.assignmentId, membershipId: link.membershipId, crewId: link.crewId,
                                 subcontractorId: person.subcontractorId, employmentType: person.employmentType,
                                 personnelName: person.fullName, crewName: link.crewName, isDemo: person.isDemo)
        working.append(entry)
        outcome(.eklendi, entry)
        continue
      }
      var entry = working[index]
      if entry.status == item.status && entry.overtimeHours == item.overtimeHours
        && entry.overtimeNote == item.overtimeNote && entry.note == item.note {
        outcome(.degismedi, entry)
        continue
      }
      if let expected = item.expectedVersion, expected != entry.version {
        throw RepositoryError.conflict("\(entry.personnelName) için \(entry.workDate.dotted) tarihli kayıt siz düzenlerken başka biri tarafından değiştirildi. Tabloyu yenileyip tekrar deneyin.")
      }
      if item.expectedVersion == nil && !overwrite { outcome(.atlandi, entry); continue }
      guard let status = item.status else {
        working.remove(at: index)
        outcome(.silindi, entry)
        continue
      }
      if entry.status != status || entry.overtimeHours != item.overtimeHours { entry.overtimeApprovedAt = nil }
      entry.status = status
      entry.overtimeHours = item.overtimeHours
      entry.overtimeNote = item.overtimeNote
      entry.note = item.note
      entry.version += 1
      working[index] = entry
      outcome(.guncellendi, entry)
    }
    puantajEntries = working
    return outcomes
  }

  func puantajTransition(projectId: UUID, month: PuantajMonth, action: PuantajAction, reason: String?,
                         expectedVersion: Int?) throws -> PuantajPeriod {
    try failIfNeeded()
    guard access.can(.puantajRead, in: projectId) else { throw RepositoryError.forbidden(nil) }
    let index = periodIndex(projectId: projectId, month: month)
    var period = puantajPeriods[index]
    if let expectedVersion, expectedVersion != period.version {
      throw RepositoryError.conflict("Ayın durumu siz bakarken değişti. Ekranı yenileyip tekrar deneyin.")
    }
    guard action.allowedFrom.contains(period.status) else {
      throw RepositoryError.validation("Bu işlem \(period.status.title.lowercased(with: Money.locale)) durumundaki ay için yapılamaz")
    }
    guard access.can(action.requiredPermission(from: period.status), in: projectId) else {
      throw RepositoryError.forbidden(nil)
    }
    if action.requiresReason && (reason.nilIfBlank?.count ?? 0) < PuantajAction.minimumReasonLength {
      throw RepositoryError.validation("Yeniden açma gerekçesi en az \(PuantajAction.minimumReasonLength) karakter olmalı")
    }
    let from = period.status
    switch action {
    case .gonder:
      period.status = .incelemede
      period.submittedAt = Date()
    case .iade:
      period.status = .taslak
      period.submittedAt = nil
    case .onayla:
      guard puantajEntries.contains(where: { $0.projectId == projectId && month.contains($0.workDate) }) else {
        throw RepositoryError.validation("Hiç kayıt olmayan ay onaylanamaz")
      }
      period.status = .onaylandi
      period.approvedAt = Date()
      period.approvedBy = profile.id
      period.firstApprovedAt = period.firstApprovedAt ?? Date()
      period.firstApprovedBy = period.firstApprovedBy ?? profile.id
    case .kilitle:
      period.status = .kilitli
      period.lockedAt = Date()
    case .yenidenAc:
      period.status = .taslak
      period.revision += 1
      period.submittedAt = nil
      period.approvedAt = nil
      period.approvedBy = nil
      period.lockedAt = nil
    }
    period.version += 1
    puantajPeriods[index] = period
    puantajEvents[period.id, default: []].append(
      PuantajPeriodEvent(action: action, fromStatus: from, toStatus: period.status, revision: period.revision,
                         reason: reason.nilIfBlank, actorId: profile.id))
    return period
  }

  func approvePuantajOvertime(entryIds: [UUID]) throws -> Int {
    try failIfNeeded()
    let targets = puantajEntries.filter { entryIds.contains($0.id) }
    for entry in targets {
      guard access.can(.puantajApprove, in: entry.projectId) else {
        throw RepositoryError.forbidden("Fazla mesai onaylama yetkiniz yok")
      }
    }
    // Sunucudaki gibi: onaylanmış veya kilitli aydaki fazla mesai onaylanamaz
    // (hiçbir kayıt değişmeden reddedilir).
    for entry in targets {
      let month = PuantajMonth(containing: entry.workDate)
      if let period = puantajPeriods.first(where: { $0.projectId == entry.projectId && $0.month == month.firstDay }),
         period.status == .onaylandi || period.status == .kilitli {
        throw RepositoryError.validation("\(month.title) puantajı \(period.status.title.lowercased(with: Money.locale)); fazla mesai onayı için ayın yeniden açılması gerekir")
      }
    }
    var count = 0
    for index in puantajEntries.indices where entryIds.contains(puantajEntries[index].id) {
      if puantajEntries[index].hasOvertime && !puantajEntries[index].isOvertimeApproved {
        puantajEntries[index].overtimeApprovedAt = Date()
        puantajEntries[index].version += 1
        count += 1
      }
    }
    return count
  }

  func puantajSummary(projectId: UUID, month: PuantajMonth) throws -> [PuantajServerSummary] {
    try failIfNeeded()
    guard access.can(.puantajRead, in: projectId) else { throw RepositoryError.forbidden(nil) }
    let entries = puantajEntries.filter { $0.projectId == projectId && month.contains($0.workDate) }
    return Dictionary(grouping: entries, by: \.personnelId).map { id, items in
      let summary = PuantajSummary(entries: items)
      return PuantajServerSummary(personnelId: id, personnelName: items[0].personnelName, summary: summary)
    }.sorted { $0.personnelName < $1.personnelName }
  }
}

extension PuantajServerSummary {
  init(personnelId: UUID, personnelName: String, summary: PuantajSummary) {
    self.personnelId = personnelId
    self.personnelName = personnelName
    kayitliGun = summary.recordedDays
    tamGun = summary.fullDays
    yarimGun = summary.halfDays
    fiiliCalisma = summary.workEquivalent
    calismadi = summary.absentDays
    ucretliIzin = summary.paidLeaveDays
    ucretsizIzin = summary.unpaidLeaveDays
    raporlu = summary.sickDays
    resmiTatil = summary.publicHolidayDays
    fazlaMesaiSaat = summary.overtimeHours
    onayliFazlaMesai = summary.approvedOvertimeHours
  }
}

struct InMemoryPuantaj: PuantajRepository {
  let backend: InMemoryBackend

  func roster(projectId: UUID, month: PuantajMonth) async throws -> [PuantajRosterLink] {
    try await backend.puantajRoster(projectId: projectId, month: month)
  }
  func entries(projectId: UUID, month: PuantajMonth) async throws -> [PuantajEntry] {
    try await backend.puantajEntries(projectId: projectId, month: month)
  }
  func period(projectId: UUID, month: PuantajMonth) async throws -> PuantajPeriod? {
    try await backend.puantajPeriod(projectId: projectId, month: month)
  }
  func events(periodId: UUID) async throws -> [PuantajPeriodEvent] { try await backend.puantajEvents(periodId: periodId) }
  func save(projectId: UUID, items: [PuantajCellInput], overwrite: Bool) async throws -> [PuantajSaveOutcome] {
    try await backend.savePuantaj(projectId: projectId, items: items, overwrite: overwrite)
  }
  func transition(projectId: UUID, month: PuantajMonth, action: PuantajAction, reason: String?,
                  expectedVersion: Int?) async throws -> PuantajPeriod {
    try await backend.puantajTransition(projectId: projectId, month: month, action: action, reason: reason,
                                        expectedVersion: expectedVersion)
  }
  func approveOvertime(entryIds: [UUID]) async throws -> Int { try await backend.approvePuantajOvertime(entryIds: entryIds) }
  func summary(projectId: UUID, month: PuantajMonth) async throws -> [PuantajServerSummary] {
    try await backend.puantajSummary(projectId: projectId, month: month)
  }
}
