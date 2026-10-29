import Darwin
import Foundation

/// Runtime dei simulatori registrato da CoreSimulator (`xcrun simctl runtime list -j`).
struct SimulatorRuntime: Sendable, Hashable, Identifiable {
    let id: String
    let platformIdentifier: String
    let version: String
    let build: String
    let state: String
    let sizeBytes: Int64
    let lastUsedAt: Date?
    let deletable: Bool
    let kind: String

    var platformName: String {
        switch platformIdentifier {
        case "com.apple.platform.iphonesimulator": "iOS"
        case "com.apple.platform.appletvsimulator": "tvOS"
        case "com.apple.platform.watchsimulator": "watchOS"
        case "com.apple.platform.xrsimulator": "visionOS"
        default: "Simulatore"
        }
    }

    var name: String { "\(platformName) \(version)" }
    var isReady: Bool { state == "Ready" }
    /// Eliminazione richiesta ma non completata: lo spazio resta occupato.
    var isStuckDeleting: Bool { state == "Deleting" }

    var stateTitle: String {
        switch state {
        case "Ready": "Pronto"
        case "Deleting": "In eliminazione"
        case "Unusable": "Non utilizzabile"
        default: state
        }
    }
}

/// Spazio occupato da un volume APFS del contenitore principale.
struct APFSVolumeUsage: Sendable, Hashable, Identifiable {
    let name: String
    let roles: [String]
    let bytesInUse: Int64

    var id: String { name + roles.joined() }

    var title: String {
        switch roles.first {
        case "System": "Sistema macOS (sigillato)"
        case "Data": "Dati"
        case "Preboot": "Preboot"
        case "Recovery": "Recovery"
        case "VM": "Memoria virtuale (VM)"
        case "Update": "Aggiornamenti"
        default: name
        }
    }
}

/// Fotografia delle componenti dei "Dati di sistema" non misurabili come semplici cartelle.
struct SystemDataSnapshot: Sendable, Equatable {
    var runtimes: [SimulatorRuntime] = []
    var runtimesAvailable = false
    var volumes: [APFSVolumeUsage] = []
    var localSnapshotCount: Int?
    var swapUsedBytes: Int64?
    var swapTotalBytes: Int64?

    var runtimeBytes: Int64 { runtimes.reduce(0) { $0 + $1.sizeBytes } }
    var stuckRuntimes: [SimulatorRuntime] { runtimes.filter(\.isStuckDeleting) }
    var stuckRuntimeBytes: Int64 { stuckRuntimes.reduce(0) { $0 + $1.sizeBytes } }

    /// Volumi di sistema da mostrare (il volume Dati è già misurato cartella per cartella).
    var systemVolumes: [APFSVolumeUsage] { volumes.filter { !$0.roles.contains("Data") } }
}

/// Raccolta in sola lettura con comandi di sistema dalla allowlist e `sysctl`.
enum SystemDataInspector {
    static let diskutil = URL(fileURLWithPath: "/usr/sbin/diskutil")
    static let tmutil = URL(fileURLWithPath: "/usr/bin/tmutil")

    /// Swap oltre questa soglia viene segnalato.
    static let swapWarningBytes: Int64 = 8_000_000_000

    static func inspect() async -> SystemDataSnapshot {
        var snapshot = SystemDataSnapshot()
        async let runtimes = runCommand(.simctlRuntimeList, DevToolsInspector.xcrun)
        async let apfs = runCommand(.diskutilAPFSList, diskutil)
        async let snapshots = runCommand(.tmutilLocalSnapshots, tmutil)

        if let result = await runtimes, result.succeeded, let parsed = parseRuntimes(Data(result.stdout.utf8)) {
            snapshot.runtimes = parsed
            snapshot.runtimesAvailable = true
        }
        if let result = await apfs, result.succeeded, let parsed = parseAPFSList(Data(result.stdout.utf8)) {
            snapshot.volumes = parsed
        }
        if let result = await snapshots, result.succeeded {
            snapshot.localSnapshotCount = parseLocalSnapshots(result.stdout)
        }
        if let swap = swapUsage() {
            snapshot.swapUsedBytes = swap.used
            snapshot.swapTotalBytes = swap.total
        }
        return snapshot
    }

    private static func runCommand(_ command: AllowedCommand, _ executable: URL) async -> CommandResult? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return try? await CommandRunner.run(command, executable: executable, timeout: .seconds(30))
    }

    // MARK: Parser

    /// Decodifica `xcrun simctl runtime list -j` (dizionario indicizzato per identificatore).
    static func parseRuntimes(_ data: Data) -> [SimulatorRuntime]? {
        struct Entry: Decodable {
            let identifier: String
            let platformIdentifier: String?
            let version: String?
            let build: String?
            let state: String?
            let sizeBytes: Int64?
            let lastUsedAt: String?
            let deletable: Bool?
            let kind: String?
        }
        guard let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return nil }
        let iso = ISO8601DateFormatter()
        return entries.values
            .map {
                SimulatorRuntime(
                    id: $0.identifier,
                    platformIdentifier: $0.platformIdentifier ?? "",
                    version: $0.version ?? "?",
                    build: $0.build ?? "",
                    state: $0.state ?? "Unknown",
                    sizeBytes: $0.sizeBytes ?? 0,
                    lastUsedAt: $0.lastUsedAt.flatMap { iso.date(from: $0) },
                    deletable: $0.deletable ?? false,
                    kind: $0.kind ?? ""
                )
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Decodifica `diskutil apfs list -plist` e restituisce i volumi del contenitore
    /// che ospita il volume Dati (il disco di avvio).
    static func parseAPFSList(_ data: Data) -> [APFSVolumeUsage]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return nil }
        let main = containers.first { container in
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            let roles = volumes.flatMap { $0["Roles"] as? [String] ?? [] }
            return roles.contains("Data") && roles.contains("System")
        }
        guard let volumes = main?["Volumes"] as? [[String: Any]] else { return [] }
        return volumes.compactMap { volume in
            guard let name = volume["Name"] as? String else { return nil }
            let bytes = (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
            return APFSVolumeUsage(name: name, roles: volume["Roles"] as? [String] ?? [], bytesInUse: bytes)
        }
        .sorted { $0.bytesInUse > $1.bytesInUse }
    }

    /// Conta le istantanee in `tmutil listlocalsnapshots /`.
    static func parseLocalSnapshots(_ output: String) -> Int {
        output.split(whereSeparator: \.isNewline)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("com.apple.") }
            .count
    }

    /// Uso dello swap tramite `sysctl vm.swapusage` (nessun processo esterno).
    static func swapUsage() -> (used: Int64, total: Int64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }

    // MARK: Nomi leggibili

    /// "com_apple_MobileAsset_UAF_Siri_Understanding" → "Siri Understanding".
    static func friendlyAssetName(_ name: String) -> String {
        let known: [String: String] = [
            "com_apple_MobileAsset_iOSSimulatorRuntime": "Runtime simulatori iOS",
            "com_apple_MobileAsset_AppleDeveloperDocumentation": "Documentazione per sviluppatori",
            "com_apple_MobileAsset_MetalToolchain": "Metal Toolchain",
            "PreinstalledAssetsV2": "Risorse preinstallate",
        ]
        if let match = known[name] { return match }
        var trimmed = name.replacingOccurrences(of: "com_apple_MobileAsset_", with: "")
        if trimmed.hasPrefix("UAF_") { trimmed = String(trimmed.dropFirst(4)) }
        return trimmed.replacingOccurrences(of: "_", with: " ")
    }
}
