import Foundation
import Testing
@testable import MacCare

@Suite("CleanupManager — orchestrazione con verifiche ripetute")
struct CleanupManagerTests {
    let home: TemporaryHome
    let policy: SafetyPolicy
    let logURL: URL

    init() throws {
        home = try TemporaryHome()
        policy = home.policy
        logURL = home.path("log/activity.json")
    }

    private func plan(_ items: [PlannedRemoval], category: CategoryID = .xcodeDerivedData, confirmed: Bool = true) -> CleanupPlan {
        CleanupPlan(method: .deletePermanently, categories: [
            CategoryPlan(category: category, title: "Test", operation: .removeItems(items), estimatedBytes: nil, risks: [], isConfirmed: confirmed),
        ])
    }

    private func item(_ relative: String, rule: String = "xcode.derivedData") -> PlannedRemoval {
        PlannedRemoval(ruleID: rule, url: home.path(relative), estimatedBytes: 0)
    }

    private func manager(probe: StubProbe = .idle, logger: OperationLogger) -> CleanupManager {
        CleanupManager(policy: policy, probe: probe, logger: logger)
    }

    @Test("Elimina gli elementi confermati e registra l'esito")
    func removesConfirmedItems() async throws {
        try home.write("Library/Developer/Xcode/DerivedData/App-1/a.o", bytes: 4096)
        try home.write("Library/Developer/Xcode/DerivedData/App-2/b.o", bytes: 4096)
        let logger = OperationLogger(fileURL: logURL)

        let summary = await manager(logger: logger).execute(plan([
            item("Library/Developer/Xcode/DerivedData/App-1"),
            item("Library/Developer/Xcode/DerivedData/App-2"),
        ]))

        #expect(summary.outcomes.first?.status == .completed)
        #expect(summary.outcomes.first?.processedItems == 2)
        #expect(summary.freedBytes >= 8192)
        #expect(!home.exists("Library/Developer/Xcode/DerivedData/App-1"))
        #expect(home.exists("Library/Developer/Xcode/DerivedData"))
        let entries = await logger.all()
        #expect(entries.contains { $0.kind == .cleanup && $0.outcome == .success && $0.category == .xcodeDerivedData })
    }

    @Test("Categoria non confermata: nessuna modifica")
    func unconfirmedCategoryIsSkipped() async throws {
        try home.write("Library/Developer/Xcode/DerivedData/App-1/a.o")
        let summary = await manager(logger: OperationLogger(fileURL: logURL)).execute(plan([item("Library/Developer/Xcode/DerivedData/App-1")], confirmed: false))
        #expect(summary.outcomes.first?.status == .skipped)
        #expect(home.exists("Library/Developer/Xcode/DerivedData/App-1/a.o"))
    }

    @Test("Xcode in esecuzione: DerivedData viene saltato")
    func skipsWhenOwnerIsRunning() async throws {
        try home.write("Library/Developer/Xcode/DerivedData/App-1/a.o")
        let probe = StubProbe(result: RunningSoftwareSnapshot(bundleIdentifiers: ["com.apple.dt.Xcode"], executableNames: [], commandLines: [], isReliable: true))
        let summary = await manager(probe: probe, logger: OperationLogger(fileURL: logURL)).execute(plan([item("Library/Developer/Xcode/DerivedData/App-1")]))
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.status == .skipped)
        #expect(outcome.skipped.first?.reason.contains("Xcode") == true)
        #expect(home.exists("Library/Developer/Xcode/DerivedData/App-1/a.o"))
    }

    @Test("Build in corso (SWBBuildService): DerivedData viene saltato")
    func skipsDuringBuild() async throws {
        try home.write("Library/Developer/Xcode/DerivedData/App-1/a.o")
        let probe = StubProbe(result: RunningSoftwareSnapshot(bundleIdentifiers: [], executableNames: ["SWBBuildService"], commandLines: [], isReliable: true))
        let summary = await manager(probe: probe, logger: OperationLogger(fileURL: logURL)).execute(plan([item("Library/Developer/Xcode/DerivedData/App-1")]))
        #expect(summary.outcomes.first?.status == .skipped)
        #expect(home.exists("Library/Developer/Xcode/DerivedData/App-1/a.o"))
    }

    @Test("Daemon Gradle attivo: la build cache viene saltata")
    func skipsWhenGradleDaemonRuns() async throws {
        try home.write(".gradle/caches/build-cache-1/abc123", bytes: 100)
        let probe = StubProbe(result: RunningSoftwareSnapshot(bundleIdentifiers: [], executableNames: ["java"], commandLines: ["/usr/bin/java -cp gradle.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.10"], isReliable: true))
        let summary = await manager(probe: probe, logger: OperationLogger(fileURL: logURL)).execute(plan([item(".gradle/caches/build-cache-1/abc123", rule: "gradle.buildCache")], category: .gradleCaches))
        #expect(summary.outcomes.first?.status == .skipped)
        #expect(home.exists(".gradle/caches/build-cache-1/abc123"))
    }

    @Test("Elenco processi non affidabile: operazione incerta, quindi saltata")
    func skipsWhenProcessListUnavailable() async throws {
        try home.write("Library/Developer/Xcode/DerivedData/App-1/a.o")
        let summary = await manager(probe: StubProbe(result: .unavailable), logger: OperationLogger(fileURL: logURL)).execute(plan([item("Library/Developer/Xcode/DerivedData/App-1")]))
        #expect(summary.outcomes.first?.status == .skipped)
        #expect(home.exists("Library/Developer/Xcode/DerivedData/App-1/a.o"))
    }

    @Test("Un elemento sostituito da un symlink dopo la scansione viene saltato")
    func revalidatesBeforeRemoval() async throws {
        try home.write("Documents/tesi.pages", bytes: 100)
        try home.mkdir("Library/Developer/Xcode/DerivedData")
        try home.symlink("Library/Developer/Xcode/DerivedData/App-1", to: home.path("Documents"))
        let summary = await manager(logger: OperationLogger(fileURL: logURL)).execute(plan([item("Library/Developer/Xcode/DerivedData/App-1")]))
        #expect(summary.outcomes.first?.status == .skipped)
        #expect(home.exists("Documents/tesi.pages"))
    }

    @Test("Un percorso fuori allowlist inserito nel piano viene rifiutato")
    func rejectsForgedPlanItems() async throws {
        try home.write("Library/Application Support/App/db.sqlite")
        try home.write(SafetyPolicy.whatsappMediaRelativePath + "/foto.jpg")
        let forged = [
            item("Library/Application Support/App", rule: "xcode.derivedData"),
            item(SafetyPolicy.whatsappMediaRelativePath, rule: "cache.xcode"),
            item("Library/Caches", rule: "cache.xcode"),
        ]
        let summary = await manager(logger: OperationLogger(fileURL: logURL)).execute(plan(forged))
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.processedItems == 0)
        #expect(outcome.skipped.count == 3)
        #expect(home.exists("Library/Application Support/App/db.sqlite"))
        #expect(home.exists(SafetyPolicy.whatsappMediaRelativePath + "/foto.jpg"))
    }

    @Test("Simulatori: senza autorizzazione nelle Impostazioni nessun comando viene eseguito")
    func simulatorMaintenanceRequiresOptIn() async throws {
        let manager = CleanupManager(
            policy: policy,
            probe: StubProbe.idle,
            logger: OperationLogger(fileURL: logURL),
            commandRunner: { _, _, _, _, _ in
                Issue.record("Nessun comando deve essere eseguito")
                return CommandResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
            },
            allowSimulatorMaintenance: { false }
        )
        let plan = CleanupPlan(method: .deletePermanently, categories: [
            CategoryPlan(category: .simulators, title: "Simulatori", operation: .simctlDeleteUnavailable(deviceCount: 2), estimatedBytes: nil, risks: [], isConfirmed: true),
        ])
        let summary = await manager.execute(plan)
        #expect(summary.outcomes.first?.status == .skipped)
    }

    @Test("pnpm: versione cambiata dopo la scansione, prune non eseguito")
    func pnpmVersionMismatchSkipsPrune() async throws {
        let fakePnpm = try home.write("bin/pnpm", bytes: 10)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePnpm.path)
        let tool = PnpmTool(executable: fakePnpm, version: SemanticVersion(major: 10, minor: 0, patch: 0), storePath: nil, pathEnvironment: "/usr/bin")
        let manager = CleanupManager(
            policy: policy,
            probe: StubProbe.idle,
            logger: OperationLogger(fileURL: logURL),
            commandRunner: { command, _, _, _, _ in
                #expect(command == .pnpmVersion, "Solo la verifica di versione può essere eseguita")
                return CommandResult(exitCode: 0, stdout: "11.2.0\n", stderr: "", timedOut: false)
            }
        )
        let plan = CleanupPlan(method: .deletePermanently, categories: [
            CategoryPlan(category: .pnpmStore, title: "pnpm", operation: .pnpmStorePrune(tool), estimatedBytes: nil, risks: [], isConfirmed: true),
        ])
        let summary = await manager.execute(plan)
        #expect(summary.outcomes.first?.status == .skipped)
    }

    @Test("Un elemento che contiene MacCare in esecuzione viene saltato")
    func skipsItemContainingRunningApp() async throws {
        try home.write("Library/Developer/Xcode/DerivedData/MacCare-abc/Build/Products/Debug/MacCare.app/Contents/MacOS/MacCare")
        try home.write("Library/Developer/Xcode/DerivedData/Other-def/a.o")
        let runningApp = home.path("Library/Developer/Xcode/DerivedData/MacCare-abc/Build/Products/Debug/MacCare.app").path
        let manager = CleanupManager(policy: policy, probe: StubProbe.idle, logger: OperationLogger(fileURL: logURL), runningAppBundlePath: runningApp)
        let summary = await manager.execute(plan([
            item("Library/Developer/Xcode/DerivedData/MacCare-abc"),
            item("Library/Developer/Xcode/DerivedData/Other-def"),
        ]))
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.status == .partial)
        #expect(outcome.skipped.first?.reason == "Contiene MacCare in esecuzione")
        #expect(home.exists("Library/Developer/Xcode/DerivedData/MacCare-abc/Build/Products/Debug/MacCare.app/Contents/MacOS/MacCare"))
        #expect(!home.exists("Library/Developer/Xcode/DerivedData/Other-def"))
    }

    @Test("Stato aggregato della categoria")
    func statusAggregation() {
        #expect(CleanupManager.status(processed: 3, skipped: 0, errors: 0) == .completed)
        #expect(CleanupManager.status(processed: 3, skipped: 1, errors: 0) == .partial)
        #expect(CleanupManager.status(processed: 0, skipped: 2, errors: 0) == .skipped)
        #expect(CleanupManager.status(processed: 0, skipped: 0, errors: 1) == .failed)
    }
}
