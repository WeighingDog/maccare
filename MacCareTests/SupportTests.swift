import Foundation
import Testing
@testable import MacCare

@Suite("Comandi consentiti, versioni e registro")
struct SupportTests {
    @Test("I comandi esterni hanno argomenti fissi")
    func commandArgumentsAreFixed() {
        #expect(AllowedCommand.pnpmStorePrune.arguments == ["store", "prune"])
        #expect(AllowedCommand.pnpmStorePath.arguments == ["store", "path"])
        #expect(AllowedCommand.pnpmVersion.arguments == ["--version"])
        #expect(AllowedCommand.simctlDeleteUnavailable.arguments == ["simctl", "delete", "unavailable"])
        #expect(AllowedCommand.simctlListDevices.arguments == ["simctl", "list", "devices", "--json"])
    }

    @Test("Un comando rifiuta un eseguibile non previsto")
    func commandRejectsUnexpectedExecutable() async {
        await #expect(throws: CommandError.self) {
            try await CommandRunner.run(.pnpmStorePrune, executable: URL(fileURLWithPath: "/bin/rm"), timeout: .seconds(1))
        }
    }

    @Test("Esecuzione reale di un comando innocuo (ps) con output catturato")
    func runsProcessList() async throws {
        let result = try await CommandRunner.run(.processList(columns: .executable), executable: URL(fileURLWithPath: "/bin/ps"), timeout: .seconds(10))
        #expect(result.succeeded)
        #expect(!result.stdout.isEmpty)
    }

    @Test("Versioni semantiche", arguments: [
        ("10.12.1", SemanticVersion(major: 10, minor: 12, patch: 1)),
        ("v9.0.0", SemanticVersion(major: 9, minor: 0, patch: 0)),
        ("11.0.0-rc.1", SemanticVersion(major: 11, minor: 0, patch: 0)),
        ("8", SemanticVersion(major: 8, minor: 0, patch: 0)),
    ])
    func parsesVersions(raw: String, expected: SemanticVersion) {
        #expect(SemanticVersion(raw) == expected)
    }

    @Test("Soglia di supporto di pnpm")
    func pnpmSupportThreshold() {
        let old = PnpmTool(executable: URL(fileURLWithPath: "/x/pnpm"), version: SemanticVersion(major: 6, minor: 35, patch: 1), storePath: nil, pathEnvironment: "")
        let current = PnpmTool(executable: URL(fileURLWithPath: "/x/pnpm"), version: SemanticVersion(major: 10, minor: 0, patch: 0), storePath: nil, pathEnvironment: "")
        #expect(!old.isSupported)
        #expect(current.isSupported)
        #expect(SemanticVersion("not-a-version") == nil)
    }

    @Test("Riconoscimento dei processi")
    func processMatchers() {
        let snapshot = RunningSoftwareSnapshot(
            bundleIdentifiers: ["com.jetbrains.WebStorm", "com.google.Chrome"],
            executableNames: ["XCBBuildService"],
            commandLines: [
                "node /opt/homebrew/bin/pnpm install",
                "/usr/bin/java org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.10",
                "node /Users/me/app/node_modules/.pnpm/next@15/node_modules/next/dist/bin/next dev",
            ],
            isReliable: true
        )
        #expect(snapshot.blockers(bundleIDs: ["com.jetbrains.*"], processes: []) == ["IDE JetBrains"])
        #expect(snapshot.blockers(bundleIDs: ["com.google.Chrome"], processes: []) == ["Google Chrome"])
        #expect(!snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.xcodeBuildProcesses).isEmpty)
        #expect(!snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.gradleProcesses).isEmpty)
        #expect(snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.pnpmProcesses) == ["pnpm"])
        // Un server di sviluppo che usa node_modules/.pnpm non è un processo pnpm.
        let devServerOnly = RunningSoftwareSnapshot(bundleIdentifiers: [], executableNames: ["node"], commandLines: ["node /Users/me/app/node_modules/.pnpm/next@15/node_modules/next/dist/bin/next dev"], isReliable: true)
        #expect(devServerOnly.blockers(bundleIDs: [], processes: SafetyPolicy.pnpmProcesses).isEmpty)
    }

    @Test("Parsing dell'elenco simulatori")
    func parsesSimctlJSON() throws {
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-18-2":[{"udid":"AAA","name":"iPhone 16","state":"Shutdown","isAvailable":true}],
          "com.apple.CoreSimulator.SimRuntime.iOS-16-0":[{"udid":"BBB","name":"iPhone 14","state":"Shutdown","isAvailable":false,"availabilityError":"runtime profile not found"}]
        }}
        """
        let inventory = try #require(SimulatorInventory.parse(Data(json.utf8)))
        #expect(inventory.devices.count == 2)
        #expect(inventory.unavailableDevices.map(\.udid) == ["BBB"])
        #expect(inventory.device(udid: "AAA")?.runtimeName == "iOS 18.2")
    }

    @Test("Registro persistente con soli metadati")
    func loggerPersistsMetadata() async throws {
        let home = try TemporaryHome()
        let url = home.path("logs/activity.json")
        let logger = OperationLogger(fileURL: url, maxEntries: 3)
        for index in 0..<5 {
            await logger.record(ActivityEntry(kind: .cleanup, outcome: .success, category: .xcodeDerivedData, title: "Voce \(index)", freedBytes: Int64(index)))
        }
        let reloaded = OperationLogger(fileURL: url, maxEntries: 3)
        let entries = await reloaded.all()
        #expect(entries.count == 3, "Il registro è limitato a maxEntries")
        #expect(entries.first?.title == "Voce 4")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        // Lo schema non prevede campi per contenuti dei file.
        let json = try String(contentsOf: url, encoding: .utf8)
        let allowedKeys: Set<String> = ["id", "date", "kind", "outcome", "category", "title", "detail", "freedBytes", "trashedBytes", "bytes", "path"]
        let objects = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] ?? []
        for object in objects {
            #expect(Set(object.keys).isSubset(of: allowedKeys))
        }
        await reloaded.clear()
        #expect(await reloaded.all().isEmpty)
    }
}
