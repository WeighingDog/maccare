import Foundation
import Observation
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case smartClean, space, development, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartClean: "Pulizia intelligente"
        case .space: "Spazio"
        case .development: "Sviluppo"
        case .activity: "Attività"
        }
    }

    var symbol: String {
        switch self {
        case .smartClean: "sparkles"
        case .space: "chart.bar.xaxis"
        case .development: "hammer"
        case .activity: "clock"
        }
    }
}

enum ScanPhase: Equatable {
    case idle
    case preparing
    case scanning
    case completed
    case cancelled
    case failed(String)

    var isRunning: Bool { self == .preparing || self == .scanning }
}

enum CleanupPhase: Equatable {
    case idle
    case running(CleanupProgress)
}

enum RecoverableEstimate: Equatable {
    case bytes(Int64)
    case determinedByTool(String)
    case none

    var bytes: Int64? {
        if case .bytes(let value) = self { value } else { nil }
    }
}

enum ActionAvailability: Equatable {
    case available
    case unavailable(String)
    case notApplicable(String)

    var isAvailable: Bool { self == .available }

    var message: String? {
        switch self {
        case .available: nil
        case .unavailable(let reason), .notApplicable(let reason): reason
        }
    }
}

struct LargeDirectory: Identifiable, Hashable {
    let path: String
    let name: String
    let parentTitle: String
    let allocatedBytes: Int64
    let classification: PathClassification

    var id: String { path }
}

@MainActor
@Observable
final class AppModel {
    let policy: SafetyPolicy
    let settings: AppSettings
    private let logger: OperationLogger
    private let scanner = StorageScanner()
    private let probe: any RunningSoftwareProbe = SystemRunningSoftwareProbe()

    // Navigazione
    var selection: SidebarItem? = .smartClean {
        didSet { if selection != oldValue { detailPath = NavigationPath() } }
    }
    /// Percorso di navigazione del dettaglio (categorie aperte).
    var detailPath = NavigationPath()

    func openCategory(_ id: CategoryID) {
        detailPath.append(id)
    }

    // Scansione
    private(set) var categories: [CleanupCategory] = []
    private(set) var measurements: [String: DirectoryMeasurement] = [:]
    private(set) var scanPhase: ScanPhase = .idle
    private(set) var scanProgress = ScanProgress()
    private(set) var lastScanDate: Date?
    private(set) var lastScanDuration: TimeInterval?
    private(set) var volume: VolumeSnapshot?
    private(set) var pnpmStatus: PnpmStatus = .unknown
    private(set) var simulatorInventory: SimulatorInventory?
    private(set) var xcodeCustomDerivedDataLocation: String?
    private(set) var runningSnapshot: RunningSoftwareSnapshot?
    private var scanTask: Task<Void, Never>?

    // Pulizia. Nessuna categoria è mai preselezionata: spuntarla è la conferma esplicita
    // della categoria, e la pulizia parte solo dopo la conferma finale (`confirmsCleaning`).
    var selectedForCleanup: Set<CategoryID> = []
    /// Richiesta di conferma finale in corso.
    var confirmsCleaning = false
    /// Esito mostrato nella home finché l'utente non lo chiude.
    var presentedSummary: CleanupSummary?
    private(set) var lastSummary: CleanupSummary?
    private(set) var cleanupPhase: CleanupPhase = .idle
    private(set) var sessionFreedBytes: Int64 = 0
    private(set) var sessionTrashedBytes: Int64 = 0
    private var cleanupTask: Task<Void, Never>?

    // Registro
    private(set) var activity: [ActivityEntry] = []

    init(policy: SafetyPolicy = .standard(), settings: AppSettings = AppSettings(), logger: OperationLogger = OperationLogger()) {
        self.policy = policy
        self.settings = settings
        self.logger = logger
        self.categories = CategoryCatalog.categories(CatalogContext(policy: policy))
        self.volume = VolumeSnapshot.current(for: policy.home)
        Task { await refreshActivity() }
    }

    // MARK: - Stato derivato

    var hasScanned: Bool { lastScanDate != nil }
    var isScanning: Bool { scanPhase.isRunning }
    var isCleaning: Bool { if case .running = cleanupPhase { true } else { false } }

    func category(_ id: CategoryID) -> CleanupCategory? {
        categories.first { $0.id == id }
    }

    func categories(in section: CategorySection) -> [CleanupCategory] {
        categories.filter { $0.section == section }
    }

    func measurement(for location: LocationSpec) -> DirectoryMeasurement? {
        measurements[location.path]
    }

    /// Dimensione della categoria senza doppi conteggi fra percorsi annidati.
    func size(of category: CleanupCategory) -> Int64 {
        StorageMath.unionAllocatedBytes(of: category.locations.map(\.path), in: measurements)
    }

    func isPartiallyMeasured(_ category: CleanupCategory) -> Bool {
        category.locations.contains { measurements[$0.path]?.isPartial == true }
    }

    func unanalyzableLocations(in category: CleanupCategory) -> [LocationSpec] {
        category.locations.filter {
            guard let state = measurements[$0.path]?.state else { return false }
            if case .denied = state { return true }
            return measurements[$0.path]?.isPartial == true
        }
    }

    /// Totale analizzato (unione dei percorsi misurati, senza annidamenti).
    var analyzedBytes: Int64 {
        StorageMath.unionAllocatedBytes(of: categories.flatMap { $0.locations.map(\.path) }, in: measurements)
    }

    var protectedBytes: Int64 {
        let protectedPaths = categories.flatMap { category in
            category.locations.filter { $0.kind.isProtected || category.safety == .protected }.map(\.path)
        }
        return StorageMath.unionAllocatedBytes(of: protectedPaths, in: measurements)
    }

    /// Somma delle stime delle sole categorie con azione; le radici consentite sono disgiunte.
    var recoverableBytes: Int64 {
        categories.compactMap { estimate(for: $0).bytes }.reduce(0, +)
    }

    var unanalyzableCount: Int {
        Set(categories.flatMap { unanalyzableLocations(in: $0).map(\.path) }).count
    }

    /// Categorie selezionate ma non ancora pulite (in attesa della conferma finale).
    var pendingConfirmationCount: Int { selectedForCleanup.count }

    var allTimeFreedBytes: Int64 {
        activity.filter { $0.kind == .cleanup }.compactMap(\.freedBytes).reduce(0, +)
    }

    // MARK: - Stime e disponibilità delle azioni

    func plannedRemovals(for category: CleanupCategory) -> [PlannedRemoval] {
        guard case .removeContents = category.action else { return [] }
        var items: [PlannedRemoval] = []
        for location in category.cleanableLocations {
            guard let ruleID = location.kind.ruleID,
                  let measurement = measurements[location.path], measurement.state.isMeasured else { continue }
            for child in measurement.children where !child.isSymbolicLink {
                let url = location.url.appendingPathComponent(child.name, isDirectory: child.isDirectory)
                guard policy.classify(url) == .cleanableItem(ruleID: ruleID) else { continue }
                items.append(PlannedRemoval(ruleID: ruleID, url: url, estimatedBytes: child.allocatedBytes))
            }
        }
        return items.sorted { $0.estimatedBytes > $1.estimatedBytes }
    }

    func estimate(for category: CleanupCategory) -> RecoverableEstimate {
        switch category.action {
        case .none:
            return .none
        case .removeContents:
            guard hasScanned else { return .none }
            return .bytes(plannedRemovals(for: category).reduce(0) { $0 + $1.estimatedBytes })
        case .pnpmStorePrune:
            return pnpmStatus.tool == nil ? .none : .determinedByTool("Calcolato da pnpm al termine")
        case .simctlDeleteUnavailable:
            guard settings.allowSimulatorMaintenance, let count = simulatorInventory?.unavailableDevices.count, count > 0 else { return .none }
            return .determinedByTool("\(count) dispositivi non disponibili")
        }
    }

    /// Blocchi noti al momento della scansione (ricontrollati comunque prima di eseguire).
    func knownBlockers(for category: CleanupCategory) -> [String] {
        guard let snapshot = runningSnapshot else { return [] }
        let rules = policy.rules(for: category.id)
        var result: [String] = []
        for rule in rules {
            result.append(contentsOf: snapshot.blockers(bundleIDs: rule.blockingBundleIDs, processes: rule.blockingProcesses))
        }
        if category.action == .pnpmStorePrune {
            result.append(contentsOf: snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.pnpmProcesses))
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    func availability(for category: CleanupCategory) -> ActionAvailability {
        switch category.action {
        case .none(let reason):
            return .notApplicable(reason)
        case .removeContents:
            guard hasScanned else { return .unavailable("Esegui prima un'analisi") }
            guard !plannedRemovals(for: category).isEmpty else { return .unavailable("Niente da pulire") }
        case .pnpmStorePrune:
            guard hasScanned else { return .unavailable("Esegui prima un'analisi") }
            guard pnpmStatus.tool != nil else { return .unavailable(pnpmStatus.message) }
        case .simctlDeleteUnavailable:
            guard settings.allowSimulatorMaintenance else {
                return .notApplicable("Solo analisi · attivabile nelle Impostazioni")
            }
            guard hasScanned else { return .unavailable("Esegui prima un'analisi") }
            guard let inventory = simulatorInventory else { return .unavailable("simctl non disponibile su questo Mac") }
            guard !inventory.unavailableDevices.isEmpty else { return .unavailable("Nessun simulatore da eliminare") }
        }
        return .available
    }

    func isSelectable(_ category: CleanupCategory) -> Bool {
        availability(for: category) == .available
    }

    var actionableCategories: [CleanupCategory] {
        categories.filter { $0.action.isDestructive }
    }

    // MARK: - Diagnostica

    func largeDirectories(limit: Int = 40) -> [LargeDirectory] {
        let threshold = Int64(settings.largeDirectoryThresholdMB) * 1_000_000
        var seen = Set<String>()
        var result: [LargeDirectory] = []
        for category in categories {
            for location in category.locations where location.wantsBreakdown {
                guard let measurement = measurements[location.path] else { continue }
                for child in measurement.children where child.isDirectory && child.allocatedBytes >= threshold {
                    let path = location.url.appendingPathComponent(child.name).path
                    guard seen.insert(path).inserted else { continue }
                    result.append(LargeDirectory(
                        path: path,
                        name: displayName(forChild: child.name, of: location),
                        parentTitle: location.title,
                        allocatedBytes: child.allocatedBytes,
                        classification: policy.classify(URL(fileURLWithPath: path))
                    ))
                }
            }
        }
        return Array(result.sorted { $0.allocatedBytes > $1.allocatedBytes }.prefix(limit))
    }

    /// Nome leggibile di un figlio (es. UDID di un simulatore → nome del dispositivo).
    func displayName(forChild name: String, of location: LocationSpec) -> String {
        if location.id == "sim.devices", let device = simulatorInventory?.device(udid: name) {
            return "\(device.name) · \(device.runtimeName)"
        }
        return name
    }

    // MARK: - Scansione

    func startScan() {
        guard !isScanning, !isCleaning else { return }
        scanTask = Task { await performScan() }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func performScan() async {
        let start = Date()
        scanPhase = .preparing
        scanProgress = ScanProgress()
        volume = VolumeSnapshot.current(for: policy.home)

        async let pnpm = DevToolsInspector.inspectPnpm(home: policy.home, useLoginShell: settings.useLoginShellPath)
        async let simulators = DevToolsInspector.inspectSimulators()
        async let running = probe.snapshot()
        let dotDirectories = DevToolsInspector.homeDotDirectories(home: policy.home, excluding: CategoryCatalog.dotDirectoriesExcludedFromDiagnostics)
        let customDerivedData = DevToolsInspector.xcodeCustomDerivedDataLocation()

        let pnpmResult = await pnpm
        let simulatorResult = await simulators
        let runningResult = await running
        if Task.isCancelled { return finishCancelled() }

        pnpmStatus = pnpmResult
        simulatorInventory = simulatorResult
        runningSnapshot = runningResult
        xcodeCustomDerivedDataLocation = customDerivedData

        let context = CatalogContext(
            policy: policy,
            pnpmStorePath: pnpmResult.tool?.storePath,
            homeDotDirectories: dotDirectories,
            includeOtherAppContainers: settings.includeOtherAppContainers
        )
        let newCategories = CategoryCatalog.categories(context)
        let requests = newCategories.flatMap { $0.locations.map { MeasurementRequest(url: $0.url, wantsBreakdown: $0.wantsBreakdown) } }

        scanPhase = .scanning
        do {
            let result = try await scanner.measure(requests) { [weak self] progress in
                Task { @MainActor in self?.scanProgress = progress }
            }
            categories = newCategories
            measurements = result
            lastScanDate = .now
            lastScanDuration = Date().timeIntervalSince(start)
            scanPhase = .completed
            selectedForCleanup = selectedForCleanup.filter { id in category(id).map(isSelectable) ?? false }
            let denied = unanalyzableCount
            await logger.record(ActivityEntry(
                kind: .scan,
                outcome: denied > 0 ? .partial : .success,
                title: "Scansione completata",
                detail: "\(scanProgress.itemsVisited.formatted()) elementi in \(Duration.seconds(lastScanDuration ?? 0).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))"
                    + (denied > 0 ? " · \(denied) percorsi non analizzabili" : ""),
                bytes: analyzedBytes
            ))
        } catch is CancellationError {
            return finishCancelled()
        } catch {
            scanPhase = .failed(error.localizedDescription)
            await logger.record(ActivityEntry(kind: .scan, outcome: .failed, title: "Scansione non riuscita", detail: error.localizedDescription))
        }
        await refreshActivity()
    }

    private func finishCancelled() {
        scanPhase = .cancelled
        Task {
            await logger.record(ActivityEntry(kind: .scan, outcome: .cancelled, title: "Scansione annullata", detail: "Interrotta dall'utente. I risultati precedenti, se presenti, restano visibili."))
            await refreshActivity()
        }
    }

    // MARK: - Pulizia

    func toggleSelection(_ id: CategoryID) {
        if selectedForCleanup.contains(id) { selectedForCleanup.remove(id) } else { selectedForCleanup.insert(id) }
    }

    var selectedCategories: [CleanupCategory] {
        actionableCategories.filter { selectedForCleanup.contains($0.id) && isSelectable($0) }
    }

    var selectedEstimateBytes: Int64 {
        selectedCategories.compactMap { estimate(for: $0).bytes }.reduce(0, +)
    }

    /// Piano delle sole categorie spuntate e disponibili. Nessuna operazione viene eseguita qui.
    func makePlan() -> CleanupPlan? {
        var plans: [CategoryPlan] = []
        for category in selectedCategories {
            let operation: PlannedOperation
            switch category.action {
            case .removeContents:
                let items = plannedRemovals(for: category)
                guard !items.isEmpty else { continue }
                operation = .removeItems(items)
            case .pnpmStorePrune:
                guard let tool = pnpmStatus.tool else { continue }
                operation = .pnpmStorePrune(tool)
            case .simctlDeleteUnavailable:
                operation = .simctlDeleteUnavailable(deviceCount: simulatorInventory?.unavailableDevices.count ?? 0)
            case .none:
                continue
            }
            // La spunta della categoria è la sua conferma esplicita.
            plans.append(CategoryPlan(category: category.id, title: category.title, operation: operation,
                                      estimatedBytes: estimate(for: category).bytes, risks: category.risks, isConfirmed: true))
        }
        return plans.isEmpty ? nil : CleanupPlan(method: settings.removalMethod, categories: plans)
    }

    /// Mostra la conferma finale (elenco delle categorie e totale).
    func requestCleaning() {
        guard !isCleaning, !isScanning, !selectedCategories.isEmpty else { return }
        confirmsCleaning = true
    }

    /// Esegue la pulizia dopo la conferma finale.
    func cleanSelected() {
        confirmsCleaning = false
        guard let plan = makePlan(), !isCleaning, !isScanning else { return }
        presentedSummary = nil
        let allowSimulators = settings.allowSimulatorMaintenance
        let manager = CleanupManager(policy: policy, logger: logger, allowSimulatorMaintenance: { allowSimulators })
        cleanupPhase = .running(CleanupProgress(categoryTitle: "", categoryIndex: 0, categoryCount: plan.categories.count, itemIndex: 0, itemCount: 0, currentItem: ""))
        cleanupTask = Task {
            await logger.record(ActivityEntry(
                kind: .policy, outcome: .info, title: "Pulizia confermata",
                detail: plan.categories.map(\.title).joined(separator: ", ") + " · \(plan.method.title)"
            ))
            let summary = await manager.execute(plan) { [self] progress in
                Task { @MainActor in
                    // Gli aggiornamenti arrivati dopo la fine vengono ignorati.
                    guard self.isCleaning else { return }
                    self.cleanupPhase = .running(progress)
                }
            }
            cleanupPhase = .idle
            sessionFreedBytes += summary.freedBytes
            sessionTrashedBytes += summary.trashedBytes
            selectedForCleanup.subtract(summary.outcomes.map(\.category))
            lastSummary = summary
            presentedSummary = summary
            await refreshActivity()
            // Le misure sono cambiate: aggiorna i dati reali.
            startScan()
        }
    }

    func dismissSummary() {
        presentedSummary = nil
    }

    func cancelCleanup() {
        cleanupTask?.cancel()
    }

    // MARK: - Registro

    func refreshActivity() async {
        activity = await logger.all()
    }

    func clearActivity() {
        Task {
            await logger.clear()
            await refreshActivity()
        }
    }
}
