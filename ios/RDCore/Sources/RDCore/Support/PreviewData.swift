import Foundation

/// Önizleme ve demo için örnek veri. Tamamen hayalidir; gerçek kayıt içermez.
public enum PreviewData {
  public static let sivas = Project(code: "DEMO-SVS", name: "Sivas 30 Daire Projesi", city: "Sivas",
                                    startDate: CalendarDate(year: 2026, month: 3, day: 1), status: .devam,
                                    notes: "Örnek proje: 2 blok, 30 daire.", isDemo: true)
  public static let office = CostCenter(code: "GENEL-OFIS", name: "Merkez ofis", isDemo: true)
  public static let taseron = CariAccount(code: "DEMO-C01", title: "Örnek Kaba İnşaat Taşeronu", type: .taseron,
                                          taxNumber: "1111111111", isDemo: true)
  public static let tedarikci = CariAccount(code: "DEMO-C02", title: "Örnek Hazır Beton Tedarikçisi",
                                            type: .tedarikci, isDemo: true)

  // Taşeron, personel ve ekip (Aşama 2). Adlar hayalidir.
  public static let kabaTaseron = Subcontractor(name: "Örnek Kaba İnşaat Taşeronu", trade: .kalip,
                                                cariAccountId: taseron.id, contactName: "Deneme Ekip Başı",
                                                phone: "0000 000 00 11", isDemo: true)
  public static let kalipUstasi = Personnel(fullName: "Deneme Kalıp Ustası", jobTitle: "Kalıp ustası", trade: .kalip,
                                            employmentType: .taseron, subcontractorId: kabaTaseron.id, isDemo: true)
  public static let kalipKalfasi = Personnel(fullName: "Deneme Kalıp Kalfası", jobTitle: "Kalfa", trade: .kalip,
                                             employmentType: .taseron, subcontractorId: kabaTaseron.id, isDemo: true)
  public static let tekniker = Personnel(fullName: "Deneme Şantiye Teknikeri", jobTitle: "Tekniker", trade: .genel,
                                         isDemo: true)
  public static let kalipEkibi = Crew(name: "Kalıp Ekibi", subcontractorId: kabaTaseron.id, trade: .kalip,
                                      leaderId: kalipUstasi.id, isDemo: true)

  /// Önizlemeler için dolu, oturum açık bir bellek içi sunucu.
  public static func backend() async -> InMemoryBackend {
    let backend = InMemoryBackend()
    await backend.seed(projects: [sivas], costCenters: [office], accounts: [taseron, tedarikci],
                       tasks: [TaskItem(projectId: sivas.id, title: "B Blok 3. kat döşeme betonu",
                                        dueDate: .today().adding(days: 2), priority: .yuksek)])
    let start = CalendarDate(year: 2026, month: 3, day: 1)
    await backend.seedWorkforce(
      subcontractors: [kabaTaseron], personnel: [kalipUstasi, kalipKalfasi, tekniker],
      contacts: [kalipUstasi.id: "0000 000 00 21", tekniker.id: "0000 000 00 22"], crews: [kalipEkibi],
      memberships: [CrewMembership(crewId: kalipEkibi.id, personnelId: kalipUstasi.id, startDate: start, roleTitle: "Usta"),
                    CrewMembership(crewId: kalipEkibi.id, personnelId: kalipKalfasi.id, startDate: start, roleTitle: "Kalfa")],
      assignments: [ProjectAssignment(projectId: sivas.id, target: .crew(kalipEkibi.id), startDate: start,
                                      description: "Temel ve bodrum kalıbı"),
                    ProjectAssignment(projectId: sivas.id, target: .personnel(tekniker.id), startDate: start)],
      subcontractorProjects: [SubcontractorProject(subcontractorId: kabaTaseron.id, projectId: sivas.id, startDate: start,
                                                   scope: "Kaba inşaat (örnek)")],
      documents: [SubcontractorDocument(subcontractorId: kabaTaseron.id, title: "Vergi levhası (örnek)",
                                        validUntil: CalendarDate(year: 2026, month: 12, day: 31))])
    let profile = await backend.profile
    await backend.set(session: AuthSession(userId: profile.id, email: profile.email))
    await seedPuantaj(backend)
    await seedInventory(backend)
    try? await backend.post(CariEntryDraft(cariAccountId: taseron.id, scope: .project(sivas.id),
                                           entryDate: CalendarDate(year: 2026, month: 9, day: 30), direction: .alacak,
                                           kind: .manuel, amount: 450_000, description: "1 nolu hakediş (örnek)"))
    try? await backend.post(CariEntryDraft(cariAccountId: taseron.id, scope: .project(sivas.id),
                                           entryDate: CalendarDate(year: 2026, month: 10, day: 10), direction: .borc,
                                           kind: .odeme, amount: 200_000, description: "Kısmi ödeme (örnek)"))
    return backend
  }

  /// Malzeme, stok ve satın alma (Aşama 7): plywood ve direk teslimi, kullanım
  /// ve kısmen teslim alınmış demir siparişi. Tutarlar hayalidir.
  static func seedInventory(_ backend: InMemoryBackend) async {
    guard let adet = await backend.inventoryUnit(code: "adet"), let kg = await backend.inventoryUnit(code: "kg"),
          let ton = await backend.inventoryUnit(code: "ton"),
          let kalip = await backend.inventoryCategory(name: "Kalıp ve iskele"),
          let demirCat = await backend.inventoryCategory(name: "Demir") else { return }
    let plywood = Material(code: "MLZ-0001", name: "Plywood", categoryId: kalip.id, baseUnitId: adet.id)
    let direk = Material(code: "MLZ-0002", name: "Demir direk", categoryId: kalip.id, baseUnitId: adet.id)
    let demir = Material(code: "MLZ-0004", name: "İnşaat demiri", categoryId: demirCat.id, baseUnitId: kg.id)
    await backend.seedInventory(materials: [plywood, direk, demir],
                                conversions: [MaterialUnitConversion(materialId: demir.id, unitId: ton.id, factor: 1000,
                                                                     note: "1 ton = 1000 kg")])
    guard let depot = await backend.defaultWarehouse(projectId: sivas.id) else { return }
    let line1 = PurchaseOrderLineDraft(materialId: plywood.id, quantity: 160, unitPrice: 850)
    let line2 = PurchaseOrderLineDraft(materialId: direk.id, quantity: 200, unitPrice: 320)
    let line3 = PurchaseOrderLineDraft(materialId: demir.id, quantity: 12, unitId: ton.id, unitPrice: 20_000)
    let day = CalendarDate(year: 2026, month: 10, day: 5)
    do {
      let kalipOrder = try await backend.saveInventoryPurchaseOrder(
        id: UUID(), draft: PurchaseOrderDraft(cariAccountId: tedarikci.id, warehouseId: depot.id, lines: [line1, line2],
                                              orderDate: day, description: "Kalıp malzemesi (örnek)"), expectedVersion: nil)
      _ = try await backend.inventoryTransition(orderId: kalipOrder.id, action: .onayla, reason: nil, expectedVersion: nil)
      _ = try await backend.inventoryReceive(PurchaseReceiptDraft(
        orderId: kalipOrder.id, lines: [PurchaseReceiptLineInput(orderLineId: line1.id, quantity: 100),
                                        PurchaseReceiptLineInput(orderLineId: line2.id, quantity: 200)],
        receiptDate: day.adding(days: 2), waybillNo: "IRS-0001"))
      let demirOrder = try await backend.saveInventoryPurchaseOrder(
        id: UUID(), draft: PurchaseOrderDraft(cariAccountId: tedarikci.id, warehouseId: depot.id, lines: [line3],
                                              orderDate: day, description: "Temel demiri (örnek)"), expectedVersion: nil)
      _ = try await backend.inventoryTransition(orderId: demirOrder.id, action: .onayla, reason: nil, expectedVersion: nil)
      _ = try await backend.inventoryReceive(PurchaseReceiptDraft(
        orderId: demirOrder.id, lines: [PurchaseReceiptLineInput(orderLineId: line3.id, quantity: 5)],
        receiptDate: day.adding(days: 3), waybillNo: "IRS-0002"))
      _ = try await backend.createInventoryMovement(StockMovementDraft(
        kind: .kullanim, materialId: plywood.id, warehouseId: depot.id, quantity: 40, movementDate: day.adding(days: 5),
        description: "B Blok 2. kat kalıbı", performedBy: "Deneme Kalıp Ustası"))
    } catch {
      return  // önizleme verisi; hata önizlemeyi engellemez
    }
  }

  /// Sözleşme ve hakediş önizlemeleri: örnek sözleşme, onaylı ve kısmen
  /// ödenmiş Eylül hakedişi, onay bekleyen Ekim imalatı.
  public static func contractsBackend() async -> InMemoryBackend {
    let backend = await backend()
    await seedContracts(backend)
    return backend
  }

  // Sözleşme ve hakediş (Aşama 4). Tutarlar hayalidir; vergi kuralı örnek
  // olarak "doğrulanmış" işaretlidir, gerçek oran değildir.
  public static let sozlesme = Contract(contractNo: "DEMO-S-001", projectId: sivas.id, subcontractorId: kabaTaseron.id,
                                        cariAccountId: taseron.id, title: "Kaba inşaat kalıp ve beton işçiliği",
                                        signedDate: CalendarDate(year: 2026, month: 8, day: 1), isDemo: true)
  public static let odemeKaynagi = PaymentSource(name: "Şirket ödemesi (örnek)", kind: .sirket)

  static func seedContracts(_ backend: InMemoryBackend) async {
    let version = ContractVersion(contractId: sozlesme.id, startDate: CalendarDate(year: 2026, month: 8, day: 1),
                                  totalAmount: 1_332_000, retentionRate: 10, paymentTerms: "Onaydan sonra 15 gün (örnek)")
    let kalip = ContractItem(versionId: version.id, contractId: sozlesme.id, lineNo: 1, method: .birimFiyat,
                             description: "Temel ve perde kalıbı", unit: "m2", quantity: 2400, unitPrice: 450)
    let beton = ContractItem(versionId: version.id, contractId: sozlesme.id, lineNo: 2, method: .birimFiyat,
                             description: "Beton döküm işçiliği", unit: "m3", quantity: 900, unitPrice: 280)
    let iskele = ContractItem(versionId: version.id, contractId: sozlesme.id, lineNo: 3, method: .goturu,
                              description: "İskele kurulumu", unit: "goturu", unitPrice: 60_000)
    var contract = sozlesme
    contract.status = .taslak
    await backend.seedContracts(contracts: [contract], versions: [version], items: [kalip, beton, iskele],
                                paymentSources: [odemeKaynagi])
    _ = try? await backend.transitionContract(id: sozlesme.id, action: .onayla, reason: nil, expectedVersion: nil)
    let september = CalendarDate(year: 2026, month: 9, day: 20)
    let w1 = WorkQuantity(contractId: sozlesme.id, projectId: sivas.id, itemKey: kalip.itemKey, workDate: september,
                          quantity: 600, location: "A blok temel")
    let w2 = WorkQuantity(contractId: sozlesme.id, projectId: sivas.id, itemKey: beton.itemKey, workDate: september,
                          quantity: 150, location: "A blok temel")
    _ = try? await backend.saveWorkQuantity(w1)
    _ = try? await backend.saveWorkQuantity(w2)
    _ = try? await backend.approveWorkQuantities(ids: [w1.id, w2.id])
    let first = UUID()
    _ = try? await backend.createHakedis(id: first, contractId: sozlesme.id, periodStart: CalendarDate(year: 2026, month: 9, day: 1),
                                         periodEnd: CalendarDate(year: 2026, month: 9, day: 30), note: nil)
    _ = try? await backend.transitionHakedis(id: first, action: .gonder, reason: nil, expectedVersion: nil)
    _ = try? await backend.transitionHakedis(id: first, action: .onayla, reason: nil, expectedVersion: nil)
    _ = try? await backend.postHakedis(id: first, entryDate: CalendarDate(year: 2026, month: 10, day: 5))
    _ = try? await backend.recordPayment(FinancePaymentDraft(contractId: sozlesme.id, target: .hakedis(first), amount: 150_000,
                                                             paymentSourceId: odemeKaynagi.id,
                                                             paymentDate: CalendarDate(year: 2026, month: 10, day: 15)))
    let w3 = WorkQuantity(contractId: sozlesme.id, projectId: sivas.id, itemKey: kalip.itemKey,
                          workDate: CalendarDate(year: 2026, month: 10, day: 20), quantity: 400, location: "A blok perde")
    _ = try? await backend.saveWorkQuantity(w3)
  }

  // Gider, gelir ve borç (Aşama 5). Kategoriler sunucuda veridir; buradakiler
  // yalnızca önizleme örneğidir. Tutarlar hayalidir.
  public static let demirKategori = FinanceCategory(kind: .gider, name: "Demir", sortOrder: 10)
  public static let akaryakitKategori = FinanceCategory(kind: .gider, name: "Akaryakıt", sortOrder: 70)
  public static let nakliyeKategori = FinanceCategory(kind: .gider, name: "Nakliye", sortOrder: 60)
  public static let ofisKategori = FinanceCategory(kind: .gider, name: "Ofis gideri", sortOrder: 100)
  public static let satisKategori = FinanceCategory(kind: .gelir, name: "Satış geliri", sortOrder: 10)
  public static let kartKaynagi = PaymentSource(name: "Kürşat kartı (örnek)", kind: .kart)
  public static let musteri = CariAccount(code: "DEMO-C03", title: "Örnek Daire Alıcısı", type: .musteri, isDemo: true)

  /// Gider/gelir önizlemesi: kısmen ödenmiş cari bağlantılı fatura, peşin
  /// kartla ödenmiş akaryakıt, onay bekleyen ofis gideri, vadesi yaklaşan
  /// nakliye ve kısmen tahsil edilmiş satış geliri.
  public static func financeBackend() async -> InMemoryBackend {
    let backend = await contractsBackend()
    await backend.seed(accounts: [musteri])
    await seedFinance(backend)
    return backend
  }

  static func seedFinance(_ backend: InMemoryBackend) async {
    await backend.seedFinance(categories: [demirKategori, akaryakitKategori, nakliyeKategori, ofisKategori, satisKategori],
                              paymentSources: [odemeKaynagi, kartKaynagi])
    let today = CalendarDate.today()
    let demir = UUID()
    _ = try? await backend.saveFinanceDocument(id: demir, draft: FinanceDocumentDraft(
      kind: .gider, scope: .project(sivas.id), categoryId: demirKategori.id, description: "Ø12 demir 18 ton (örnek)",
      amount: 342_000, documentDate: today.adding(days: -25), dueDate: today.adding(days: -5),
      cariAccountId: tedarikci.id, invoiceNo: "DMR-0001"), expectedVersion: nil)
    _ = try? await backend.approveFinanceDocument(id: demir, expectedVersion: nil, settlementId: nil)
    _ = try? await backend.recordFinanceSettlement(FinanceSettlementDraft(
      documentId: demir, amount: 100_000, paymentSourceId: odemeKaynagi.id, settlementDate: today.adding(days: -10)))
    let yakit = UUID()
    _ = try? await backend.saveFinanceDocument(id: yakit, draft: FinanceDocumentDraft(
      kind: .gider, scope: .project(sivas.id), categoryId: akaryakitKategori.id, description: "İş makinesi motorin (örnek)",
      amount: 4_250.50, documentDate: today.adding(days: -3), reportedSettled: true, reportedSourceId: kartKaynagi.id,
      reportedBy: "Kürşat (örnek)"), expectedVersion: nil)
    _ = try? await backend.approveFinanceDocument(id: yakit, expectedVersion: nil, settlementId: nil)
    _ = try? await backend.saveFinanceDocument(id: UUID(), draft: FinanceDocumentDraft(
      kind: .gider, scope: .costCenter(office.id), categoryId: ofisKategori.id, description: "Kırtasiye (örnek)",
      amount: 1_830, documentDate: today.adding(days: -1)), expectedVersion: nil)
    let nakliye = UUID()
    _ = try? await backend.saveFinanceDocument(id: nakliye, draft: FinanceDocumentDraft(
      kind: .gider, scope: .project(sivas.id), categoryId: nakliyeKategori.id, description: "Kalıp malzemesi nakliyesi (örnek)",
      amount: 12_500, documentDate: today.adding(days: -2), dueDate: today.adding(days: 5)), expectedVersion: nil)
    _ = try? await backend.approveFinanceDocument(id: nakliye, expectedVersion: nil, settlementId: nil)
    let satis = UUID()
    _ = try? await backend.saveFinanceDocument(id: satis, draft: FinanceDocumentDraft(
      kind: .gelir, scope: .project(sivas.id), categoryId: satisKategori.id, description: "A blok 5 nolu daire peşinatı (örnek)",
      amount: 750_000, documentDate: today.adding(days: -20), dueDate: today.adding(days: 10), cariAccountId: musteri.id,
      invoiceNo: "SAT-0001"), expectedVersion: nil)
    _ = try? await backend.approveFinanceDocument(id: satis, expectedVersion: nil, settlementId: nil)
    _ = try? await backend.recordFinanceSettlement(FinanceSettlementDraft(
      documentId: satis, amount: 250_000, paymentSourceId: odemeKaynagi.id, settlementDate: today.adding(days: -15)))
  }

  /// Bu ayın dünkü güne kadarki iş günleri (Pazar boş). Örnek: rapor, yarım
  /// gün ve fazla mesai; bir gün bilerek boş (henüz işlenmedi).
  static func seedPuantaj(_ backend: InMemoryBackend) async {
    let today = CalendarDate.today()
    let month = PuantajMonth(containing: today)
    var items: [PuantajCellInput] = []
    for day in month.days where day < today && day.isoWeekday != 7 && day.day != 3 {
      items.append(PuantajCellInput(personnelId: tekniker.id, workDate: day, status: .tamGun))
      items.append(PuantajCellInput(personnelId: kalipUstasi.id, workDate: day, status: .tamGun,
                                    overtimeHours: day.day == 9 ? 2 : 0, overtimeNote: day.day == 9 ? "Döşeme betonu" : nil))
      let kalfa: PuantajStatus = day.day == 6 || day.day == 7 ? .raporlu : day.day == 13 ? .yarimGun : .tamGun
      items.append(PuantajCellInput(personnelId: kalipKalfasi.id, workDate: day, status: kalfa))
    }
    guard !items.isEmpty else { return }
    _ = try? await backend.savePuantaj(projectId: sivas.id, items: items, overwrite: false)
  }
}
