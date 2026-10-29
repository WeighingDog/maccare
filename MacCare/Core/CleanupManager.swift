import Foundation

// MARK: - Piano

struct PlannedRemoval: Sendable, Hashable, Identifiable {
    let ruleID: String
    let url: URL
    let estimatedBytes: Int64

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    /// Nome con la cartella di appartenenza (es. "Chrome/Default").
    var displayName: String { "\(url.deletingLastPathComponent().lastPathComponent)/\(name)" }
}

enum PlannedOperation: Sendable, Hashable {
    case removeItems([PlannedRemoval])
    case pnpmStorePrune(PnpmTool)
    case simctlDeleteUnavailable(deviceCount: Int)
}

struct CategoryPlan: Sendable, Hashable, Identifiable {
    let category: CategoryID
    let title: String
    let operation: PlannedOperation
    /// Stima mostrata all'utente (`nil` se non stimabile in anticipo).
    let estimatedBytes: Int64?
    let risks: [String]
    /// Conferma esplicita per questa categoria.
    var isConfirmed = false

    var id: CategoryID { category }

    var itemCount: Int {
        switch operation {
        case .removeItems(let items): items.count
        case .pnpmStorePrune: 1
        case .simctlDeleteUnavailable(let count): count
        }
    }
}

struct CleanupPlan: Sendable, Hashable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var method: RemovalMethod
    var categories: [CategoryPlan]

    var confirmedCategories: [CategoryPlan] { categories.filter(\.isConfirmed) }
    var allConfirmed: Bool { !categories.isEmpty && categories.allSatisfy(\.isConfirmed) }
    var estimatedBytes: Int64 { categories.compactMap(\.estimatedBytes).reduce(0, +) }
}

// MARK: - Risultato

struct SkippedItem: Sendable, Hashable, Identifiable {
    var id = UUID()
    let name: String
    let reason: String
}

struct CategoryOutcome: Sendable, Hashable, Identifiable {
    enum Status: String, Sendable {
        case completed, partial, skipped, failed, cancelled

        var title: String {
            switch self {
            case .completed: "Completata"
            case .partial: "Parziale"
            case .skipped: "Saltata"
            case .failed: "Non riuscita"
            case .cancelled: "Annullata"
            }
        }

        var logOutcome: ActivityEntry.Outcome {
            switch self {
            case .completed: .success
            case .partial: .partial
            case .skipped: .skipped
            case .failed: .failed
            case .cancelled: .cancelled
            }
        }
    }

    let category: CategoryID
    let title: String
    var status: Status = .completed
    var freedBytes: Int64 = 0
    var trashedBytes: Int64 = 0
    var processedItems = 0
    var skipped: [SkippedItem] = []
    var errors: [String] = []
    var note: String?

    var id: CategoryID { category }
}

struct CleanupSummary: Sendable, Hashable, Identifiable {
    var id = UUID()
    let startedAt: Date
    var finishedAt: Date
    let method: RemovalMethod
    var outcomes: [CategoryOutcome]

    var freedBytes: Int64 { outcomes.reduce(0) { $0 + $1.freedBytes } }
    var trashedBytes: Int64 { outcomes.reduce(0) { $0 + $1.trashedBytes } }
    var processedCategories: [CategoryOutcome] { outcomes.filter { $0.status == .completed || $0.status == .partial } }
    var errorCount: Int { outcomes.reduce(0) { $0 + $1.errors.count } }
    var skippedCount: Int { outcomes.reduce(0) { $0 + $1.skipped.count + ($1.status == .skipped ? 1 : 0) } }
}

struct CleanupProgress: Sendable, Equatable {
    var categoryTitle: String
    var categoryIndex: Int
    var categoryCount: Int
    var itemIndex: Int
    var itemCount: Int
    var currentItem: String
}

// MARK: - Manager

/// Esegue un `CleanupPlan` confermato. Ogni elemento viene ri-validato dalla policy subito
/// prima della rimozione; qualsiasi dubbio comporta il salto dell'elemento.
actor CleanupManager {
    private let policy: SafetyPolicy
    private let remover: SafeRemover
    private let probe: any RunningSoftwareProbe
    private let logger: OperationLogger
    private let scanner: StorageScanner
    private let commandRunner: @Sendable (AllowedCommand, URL, [String: String]?, URL?, Duration) async throws -> CommandResult
    private let allowSimulatorMaintenance: @Sendable () -> Bool
    /// Percorso del bundle di MacCare in esecuzione: mai rimosso (es. build avviata da Xcode in DerivedData).
    private let runningAppBundlePath: String

    /// Numero massimo di voci di dettaglio (salti/errori) registrate per categoria.
    private let maxDetailEntries = 25

    init(
        policy: SafetyPolicy,
        remover: SafeRemover = SafeRemover(),
        probe: any RunningSoftwareProbe = SystemRunningSoftwareProbe(),
        logger: OperationLogger,
        scanner: StorageScanner = StorageScanner(),
        commandRunner: @escaping @Sendable (AllowedCommand, URL, [String: String]?, URL?, Duration) async throws -> CommandResult = { command, executable, env, cwd, timeout in
            try await CommandRunner.run(command, executable: executable, environment: env, currentDirectory: cwd, timeout: timeout)
        },
        allowSimulatorMaintenance: @escaping @Sendable () -> Bool = { false },
        runningAppBundlePath: String = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    ) {
        self.policy = policy
        self.remover = remover
        self.probe = probe
        self.logger = logger
        self.scanner = scanner
        self.commandRunner = commandRunner
        self.allowSimulatorMaintenance = allowSimulatorMaintenance
        self.runningAppBundlePath = PathTools.realPath(runningAppBundlePath) ?? runningAppBundlePath
    }

    func execute(_ plan: CleanupPlan, progress: @escaping @Sendable (CleanupProgress) -> Void = { _ in }) async -> CleanupSummary {
        var summary = CleanupSummary(startedAt: .now, finishedAt: .now, method: plan.method, outcomes: [])
        for (index, categoryPlan) in plan.categories.enumerated() {
            var outcome = CategoryOutcome(category: categoryPlan.category, title: categoryPlan.title)

            if Task.isCancelled {
                outcome.status = .cancelled
                outcome.note = "Pulizia interrotta prima di questa categoria."
            } else if !categoryPlan.isConfirmed {
                outcome.status = .skipped
                outcome.note = "Categoria non confermata esplicitamente."
            } else {
                progress(CleanupProgress(categoryTitle: categoryPlan.title, categoryIndex: index, categoryCount: plan.categories.count, itemIndex: 0, itemCount: categoryPlan.itemCount, currentItem: ""))
                switch categoryPlan.operation {
                case .removeItems(let items):
                    outcome = await removeItems(items, plan: categoryPlan, method: plan.method, index: index, total: plan.categories.count, progress: progress)
                case .pnpmStorePrune(let tool):
                    outcome = await pnpmPrune(tool, plan: categoryPlan)
                case .simctlDeleteUnavailable:
                    outcome = await simctlDeleteUnavailable(plan: categoryPlan)
                }
            }
            await log(outcome, method: plan.method)
            summary.outcomes.append(outcome)
        }
        summary.finishedAt = .now
        return summary
    }

    // MARK: Rimozione file

    private func removeItems(
        _ items: [PlannedRemoval],
        plan: CategoryPlan,
        method: RemovalMethod,
        index: Int,
        total: Int,
        progress: @Sendable (CleanupProgress) -> Void
    ) async -> CategoryOutcome {
        var outcome = CategoryOutcome(category: plan.category, title: plan.title)
        guard plan.category != .whatsappMedia else {
            outcome.status = .skipped
            outcome.note = "WhatsApp è protetto: nessuna modifica consentita."
            return outcome
        }

        // Verifica "in uso" subito prima di iniziare.
        let snapshot = await probe.snapshot()
        var blockedRules: [String: String] = [:]
        for ruleID in Set(items.map(\.ruleID)) {
            guard let rule = policy.rule(id: ruleID) else { continue }
            let needsProcessCheck = !rule.blockingBundleIDs.isEmpty || !rule.blockingProcesses.isEmpty
            if needsProcessCheck, !snapshot.isReliable {
                blockedRules[ruleID] = "Impossibile verificare i processi in esecuzione"
                continue
            }
            let blockers = snapshot.blockers(bundleIDs: rule.blockingBundleIDs, processes: rule.blockingProcesses)
            if !blockers.isEmpty {
                blockedRules[ruleID] = "In uso da: \(blockers.joined(separator: ", "))"
            }
        }

        for (itemIndex, item) in items.enumerated() {
            if Task.isCancelled {
                outcome.status = .cancelled
                outcome.note = "Interrotta dall'utente."
                break
            }
            progress(CleanupProgress(categoryTitle: plan.title, categoryIndex: index, categoryCount: total, itemIndex: itemIndex, itemCount: items.count, currentItem: item.displayName))

            if let reason = blockedRules[item.ruleID] {
                outcome.skipped.append(SkippedItem(name: item.displayName, reason: reason))
                continue
            }

            // 1. Nuova verifica di percorso, regola e categoria sul filesystem attuale.
            let target: ValidatedTarget
            switch policy.validateRemoval(of: item.url, ruleID: item.ruleID, category: plan.category) {
            case .success(let validated): target = validated
            case .failure(let denial):
                outcome.skipped.append(SkippedItem(name: item.displayName, reason: denial.description))
                continue
            }

            // 2. L'elemento non deve contenere MacCare stessa (es. build di Debug dentro DerivedData).
            let targetPath = PathTools.realPath(target.url.path) ?? target.url.path
            if StorageMath.isPath(runningAppBundlePath, insideOrEqualTo: targetPath) {
                outcome.skipped.append(SkippedItem(name: item.displayName, reason: "Contiene MacCare in esecuzione"))
                continue
            }

            // 3. Ispezione del contenuto: repository Git, archivi, credenziali, elementi non leggibili.
            let inspection = remover.inspect(target)
            if let reason = inspection.uncertaintyReason {
                outcome.skipped.append(SkippedItem(name: item.displayName, reason: reason))
                continue
            }

            // 4. Rimozione.
            switch method {
            case .moveToTrash:
                do {
                    _ = try remover.moveToTrash(target)
                    outcome.trashedBytes += inspection.reclaimableBytes
                    outcome.processedItems += 1
                } catch {
                    outcome.errors.append("\(item.displayName): \(error.localizedDescription)")
                }
            case .deletePermanently:
                let removal = remover.removePermanently(target)
                outcome.freedBytes += removal.freedBytes
                if removal.succeeded {
                    outcome.processedItems += 1
                } else {
                    outcome.errors.append(contentsOf: removal.failures.prefix(5).map { "\(item.displayName): \($0)" })
                }
            }
        }

        if outcome.status != .cancelled {
            outcome.status = Self.status(processed: outcome.processedItems, skipped: outcome.skipped.count, errors: outcome.errors.count)
        }
        return outcome
    }

    static func status(processed: Int, skipped: Int, errors: Int) -> CategoryOutcome.Status {
        if processed == 0 { return errors > 0 ? .failed : .skipped }
        return (skipped > 0 || errors > 0) ? .partial : .completed
    }

    // MARK: pnpm

    private func pnpmPrune(_ tool: PnpmTool, plan: CategoryPlan) async -> CategoryOutcome {
        var outcome = CategoryOutcome(category: plan.category, title: plan.title)
        let home = policy.home

        // Verifica che l'eseguibile e la versione siano quelli mostrati nel riepilogo.
        guard FileManager.default.isExecutableFile(atPath: tool.executable.path), tool.isSupported else {
            return skipped(outcome, "pnpm non più disponibile o versione non supportata.")
        }
        do {
            let version = try await commandRunner(.pnpmVersion, tool.executable, tool.environment, home, .seconds(20))
            let current = version.stdout.split(whereSeparator: \.isNewline).last.flatMap { SemanticVersion(String($0)) }
            guard version.succeeded, current == tool.version else {
                return skipped(outcome, "La versione di pnpm è cambiata dopo la scansione: ripeti l'analisi.")
            }
        } catch {
            return skipped(outcome, "Verifica di pnpm non riuscita: \(error.localizedDescription)")
        }

        let snapshot = await probe.snapshot()
        guard snapshot.isReliable else {
            return skipped(outcome, "Impossibile verificare se pnpm è in esecuzione.")
        }
        let blockers = snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.pnpmProcesses)
        guard blockers.isEmpty else {
            return skipped(outcome, "Un processo pnpm è in esecuzione (es. un'installazione): riprova al termine.")
        }

        let before = await allocatedSize(tool.storePath)
        do {
            let result = try await commandRunner(.pnpmStorePrune, tool.executable, tool.environment, home, .seconds(20 * 60))
            let after = await allocatedSize(tool.storePath)
            if let before, let after { outcome.freedBytes = max(0, before - after) }
            outcome.note = result.tail()
            if result.succeeded {
                outcome.processedItems = 1
                outcome.status = .completed
            } else {
                outcome.status = .failed
                outcome.errors.append(result.timedOut ? "Timeout di `pnpm store prune`." : "`pnpm store prune` è terminato con codice \(result.exitCode).")
            }
        } catch {
            outcome.status = .failed
            outcome.errors.append(error.localizedDescription)
        }
        return outcome
    }

    // MARK: Simulatori

    private func simctlDeleteUnavailable(plan: CategoryPlan) async -> CategoryOutcome {
        var outcome = CategoryOutcome(category: plan.category, title: plan.title)
        guard allowSimulatorMaintenance() else {
            return skipped(outcome, "Manutenzione simulatori non abilitata nelle Impostazioni.")
        }
        let xcrun = DevToolsInspector.xcrun
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else {
            return skipped(outcome, "xcrun non disponibile: installa Xcode o i Command Line Tools.")
        }
        let snapshot = await probe.snapshot()
        guard snapshot.isReliable else {
            return skipped(outcome, "Impossibile verificare i processi in esecuzione.")
        }
        let blockers = snapshot.blockers(bundleIDs: ["com.apple.iphonesimulator"], processes: SafetyPolicy.xcodeBuildProcesses)
        guard blockers.isEmpty else {
            return skipped(outcome, "In uso da: \(blockers.joined(separator: ", ")).")
        }

        let devices = policy.url(relative: "Library/Developer/CoreSimulator/Devices")
        let before = await allocatedSize(devices)
        do {
            let result = try await commandRunner(.simctlDeleteUnavailable, xcrun, nil, nil, .seconds(10 * 60))
            let after = await allocatedSize(devices)
            if let before, let after { outcome.freedBytes = max(0, before - after) }
            outcome.note = result.tail()
            if result.succeeded {
                outcome.processedItems = 1
                outcome.status = .completed
            } else {
                outcome.status = .failed
                outcome.errors.append(result.timedOut ? "Timeout di simctl." : "simctl è terminato con codice \(result.exitCode).")
            }
        } catch {
            outcome.status = .failed
            outcome.errors.append(error.localizedDescription)
        }
        return outcome
    }

    // MARK: Helpers

    private func skipped(_ outcome: CategoryOutcome, _ reason: String) -> CategoryOutcome {
        var copy = outcome
        copy.status = .skipped
        copy.note = reason
        return copy
    }

    private func allocatedSize(_ url: URL?) async -> Int64? {
        guard let url, let measurement = try? await scanner.measureSingle(url), measurement.state.isMeasured else { return nil }
        return measurement.allocatedBytes
    }

    private func log(_ outcome: CategoryOutcome, method: RemovalMethod) async {
        var entries: [ActivityEntry] = []
        var detailParts: [String] = []
        if outcome.processedItems > 0 { detailParts.append("\(outcome.processedItems) elementi elaborati") }
        if !outcome.skipped.isEmpty { detailParts.append("\(outcome.skipped.count) saltati") }
        if !outcome.errors.isEmpty { detailParts.append("\(outcome.errors.count) errori") }
        if let note = outcome.note { detailParts.append(note) }
        detailParts.append("Metodo: \(method.title)")

        entries.append(ActivityEntry(
            kind: .cleanup,
            outcome: outcome.status.logOutcome,
            category: outcome.category,
            title: "\(outcome.title): \(outcome.status.title.lowercased())",
            detail: detailParts.joined(separator: " · "),
            freedBytes: outcome.freedBytes,
            trashedBytes: outcome.trashedBytes
        ))
        for item in outcome.skipped.prefix(maxDetailEntries) {
            entries.append(ActivityEntry(kind: .policy, outcome: .skipped, category: outcome.category, title: "Saltato: \(item.name)", detail: item.reason))
        }
        for error in outcome.errors.prefix(maxDetailEntries) {
            entries.append(ActivityEntry(kind: .cleanup, outcome: .failed, category: outcome.category, title: "Errore", detail: error))
        }
        await logger.record(contentsOf: entries)
    }
}
