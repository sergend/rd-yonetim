import RDCore
import SwiftUI

/// Uygulama içi gezinme hedefleri. Her sekmenin NavigationStack'i aynı hedefleri kullanır.
enum AppRoute: Hashable {
  case projects
  case project(Project)
  case cariList(projectId: UUID?)
  case cari(CariAccount)
  case generalExpenses
  case tasks(projectId: UUID?)
  case subcontractors
  case subcontractor(Subcontractor)
  case personnelList
  case personnel(Personnel)
  case crews
  case crew(Crew)
  case projectWorkforce(Project)
  case puantajProjects
  case puantaj(Project)
  case contracts(projectId: UUID?)
  case contract(Contract)
  case hakedisList
  case hakedis(Hakedis, Contract)
  case hakedisReport(Hakedis, Contract)
  case imalatProjects
  case imalat(Project)
  case financeList(FinanceDocKind, projectId: UUID?)
  case financeDocument(FinanceDocument)
  case payables(FinanceDocKind)
  case financeReports
  case financeCategories
  case documents(link: DocumentLink?, title: String?, projectId: UUID?)
  case archiveDocument(ArchiveDocument)
  case materials
  case material(RDCore.Material)
  case stock(projectId: UUID?)
  case stockMovements(warehouseId: UUID?, materialId: UUID?)
  case stockMovement(StockMovement)
  case purchaseOrders(projectId: UUID?)
  case purchaseOrder(PurchaseOrder)
  case placeholder(AppModule)

  /// Modül girişinin hedefi.
  static func module(_ module: AppModule) -> AppRoute {
    switch module {
    case .projeler: .projects
    case .isTakibi: .tasks(projectId: nil)
    case .taseronlar: .subcontractors
    case .personel: .personnelList
    case .ekipler: .crews
    case .cari: .cariList(projectId: nil)
    case .genelGider: .generalExpenses
    case .puantaj: .puantajProjects
    case .imalat: .imalatProjects
    case .taseronSozlesmeleri: .contracts(projectId: nil)
    case .hakedis: .hakedisList
    case .giderler: .financeList(.gider, projectId: nil)
    case .borclar: .payables(.gider)
    case .gelirler: .financeList(.gelir, projectId: nil)
    case .raporlar: .financeReports
    case .belgeler: .documents(link: nil, title: nil, projectId: nil)
    case .malzemeler: .materials
    case .stoklar: .stock(projectId: nil)
    case .satinAlma: .purchaseOrders(projectId: nil)
    default: .placeholder(module)
    }
  }
}

extension View {
  /// Bir NavigationStack içindeki tüm `AppRoute` hedeflerini tanımlar.
  func rdAppDestinations(app: AppModel) -> some View {
    navigationDestination(for: AppRoute.self) { AppRouteDestination(route: $0, app: app) }
  }
}

struct AppRouteDestination: View {
  let route: AppRoute
  let app: AppModel

  var body: some View {
    switch route {
    case .projects: ProjectListView(app: app)
    case .project(let project): ProjectDetailView(project: project, app: app)
    case .cariList(let projectId): CariListView(projectId: projectId, app: app)
    case .cari(let account): CariDetailView(account: account, app: app)
    case .generalExpenses: GeneralExpensesView(app: app)
    case .tasks(let projectId): TaskListView(projectId: projectId, app: app)
    case .subcontractors: SubcontractorListView(app: app)
    case .subcontractor(let item): SubcontractorDetailView(subcontractor: item, app: app)
    case .personnelList: PersonnelListView(app: app)
    case .personnel(let person): PersonnelDetailView(person: person, app: app)
    case .crews: CrewListView(app: app)
    case .crew(let crew): CrewDetailView(crew: crew, app: app)
    case .projectWorkforce(let project): ProjectWorkforceView(project: project, app: app)
    case .puantajProjects: PuantajProjectsView(app: app)
    case .puantaj(let project): PuantajView(project: project, app: app)
    case .contracts(let projectId): ContractListView(projectId: projectId, app: app)
    case .contract(let contract): ContractDetailView(contract: contract, app: app)
    case .hakedisList: HakedisListView(app: app)
    case .hakedis(let hakedis, let contract): HakedisDetailView(hakedis: hakedis, contract: contract, app: app)
    case .hakedisReport(let hakedis, let contract): HakedisReportView(hakedis: hakedis, contract: contract, app: app)
    case .imalatProjects: ImalatProjectsView(app: app)
    case .imalat(let project): ImalatView(project: project, app: app)
    case .financeList(let kind, let projectId): FinanceDocumentListView(kind: kind, projectId: projectId, app: app)
    case .financeDocument(let document): FinanceDocumentDetailView(document: document, app: app)
    case .payables(let kind): PayablesView(kind: kind, app: app)
    case .financeReports: FinanceReportView(app: app)
    case .financeCategories: FinanceCategoryListView(app: app)
    case .documents(let link, let title, let projectId):
      DocumentListView(link: link, linkTitle: title, projectId: projectId, app: app)
    case .archiveDocument(let document): DocumentDetailView(document: document, app: app)
    case .materials: MaterialCatalogView(app: app)
    case .material(let material): MaterialDetailView(material: material, app: app)
    case .stock(let projectId): StockOverviewView(projectId: projectId, app: app)
    case .stockMovements(let warehouseId, let materialId):
      StockMovementListView(warehouseId: warehouseId, materialId: materialId, app: app)
    case .stockMovement(let movement): StockMovementDetailView(movement: movement, app: app)
    case .purchaseOrders(let projectId): PurchaseOrderListView(projectId: projectId, app: app)
    case .purchaseOrder(let order): PurchaseOrderDetailView(order: order, app: app)
    case .placeholder(let module): ModulePlaceholderView(module: module)
    }
  }
}
