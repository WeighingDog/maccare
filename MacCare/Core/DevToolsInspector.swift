import Foundation

struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Accetta stringhe come "10.12.1", "v9.0.0" o "11.0.0-rc.1".
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let core = cleaned.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? cleaned
        let parts = core.split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        self.patch = parts.count > 2 ? (parts[2] ?? 0) : 0
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

struct PnpmTool: Sendable, Hashable {
    let executable: URL
    let version: SemanticVersion
    let storePath: URL?
    /// PATH usato per eseguire pnpm (serve anche a trovare `node`).
    let pathEnvironment: String

    /// Versione minima per cui MacCare abilita `pnpm store prune`. Soglia conservativa:
    /// `store path` e `store prune` sono documentati per queste versioni.
    static let minimumSupportedVersion = SemanticVersion(major: 7, minor: 0, patch: 0)

    var isSupported: Bool { version >= Self.minimumSupportedVersion }

    var environment: [String: String] {
        [
            "PATH": pathEnvironment,
            "HOME": PathTools.userHomeDirectory().path,
            "LANG": "en_US.UTF-8",
            "NO_COLOR": "1",
            "CI": "1",
        ]
    }
}

enum PnpmStatus: Sendable, Hashable {
    case unknown
    case notFound
    case unsupported(version: String, executable: String)
    case failed(String)
    case available(PnpmTool)

    var tool: PnpmTool? {
        if case .available(let tool) = self { tool } else { nil }
    }

    var message: String {
        switch self {
        case .unknown: "Non ancora verificato. Avvia una scansione."
        case .notFound: "pnpm non trovato nel PATH della shell né nei percorsi comuni."
        case .unsupported(let version, _):
            "pnpm \(version) non è supportato da MacCare (minimo \(PnpmTool.minimumSupportedVersion)). Nessuna pulizia verrà improvvisata."
        case .failed(let message): "Verifica di pnpm non riuscita: \(message)"
        case .available(let tool): "pnpm \(tool.version) disponibile."
        }
    }
}

struct SimulatorDevice: Sendable, Hashable, Identifiable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
    let runtimeIdentifier: String
    let availabilityError: String?

    var id: String { udid }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-2" → "iOS 18.2"
    var runtimeName: String {
        let last = runtimeIdentifier.split(separator: ".").last.map(String.init) ?? runtimeIdentifier
        let parts = last.split(separator: "-").map(String.init)
        guard let platform = parts.first else { return last }
        return ([platform] + [parts.dropFirst().joined(separator: ".")]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

struct SimulatorInventory: Sendable, Hashable {
    let devices: [SimulatorDevice]

    var unavailableDevices: [SimulatorDevice] { devices.filter { !$0.isAvailable } }

    func device(udid: String) -> SimulatorDevice? {
        devices.first { $0.udid == udid }
    }

    /// Decodifica l'output di `xcrun simctl list devices --json`.
    static func parse(_ data: Data) -> SimulatorInventory? {
        struct Root: Decodable { let devices: [String: [Device]] }
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String?
            let isAvailable: Bool?
            let availabilityError: String?
        }
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else { return nil }
        let devices = root.devices.flatMap { runtime, list in
            list.map {
                SimulatorDevice(
                    udid: $0.udid,
                    name: $0.name,
                    state: $0.state ?? "Unknown",
                    isAvailable: $0.isAvailable ?? false,
                    runtimeIdentifier: runtime,
                    availabilityError: $0.availabilityError
                )
            }
        }
        return SimulatorInventory(devices: devices.sorted { ($0.runtimeIdentifier, $0.name) < ($1.runtimeIdentifier, $1.name) })
    }
}

enum DevToolsInspector {
    static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    // MARK: PATH

    /// Restituisce il PATH della shell di login dell'utente (zsh/bash), con un timeout.
    /// Le app avviate dal Finder non ereditano il PATH del terminale, che serve a trovare pnpm e node.
    static func loginShellPath() async -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard ["/bin/zsh", "/bin/bash"].contains(shell) else { return [] }
        guard let result = try? await CommandRunner.run(
            .loginShellPath,
            executable: URL(fileURLWithPath: shell),
            environment: ["HOME": PathTools.userHomeDirectory().path, "TERM": "dumb"],
            timeout: .seconds(6)
        ) else { return [] }
        let output = result.stdout
        guard let start = output.range(of: AllowedCommand.pathMarkerStart),
              let end = output.range(of: AllowedCommand.pathMarkerEnd, range: start.upperBound..<output.endIndex)
        else { return [] }
        return output[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    static func fallbackPathDirectories(home: URL) -> [String] {
        var dirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home.appendingPathComponent("Library/pnpm").path,
            home.appendingPathComponent(".local/share/pnpm").path,
            home.appendingPathComponent(".volta/bin").path,
            home.appendingPathComponent(".local/bin").path,
        ]
        // Versioni di Node gestite da nvm (la più recente per prima).
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            let sorted = versions.compactMap { name in SemanticVersion(name).map { (name, $0) } }.sorted { $0.1 > $1.1 }
            dirs.append(contentsOf: sorted.map { nvm.appendingPathComponent($0.0).appendingPathComponent("bin").path })
        }
        dirs.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        return dirs
    }

    static func findExecutable(named name: String, in directories: [String]) -> URL? {
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: pnpm

    static func inspectPnpm(home: URL, useLoginShell: Bool) async -> PnpmStatus {
        var directories: [String] = []
        if useLoginShell { directories = await loginShellPath() }
        for dir in fallbackPathDirectories(home: home) where !directories.contains(dir) {
            directories.append(dir)
        }
        guard let executable = findExecutable(named: "pnpm", in: directories) else { return .notFound }
        let path = directories.joined(separator: ":")
        let probe = PnpmTool(executable: executable, version: .init(major: 0, minor: 0, patch: 0), storePath: nil, pathEnvironment: path)

        do {
            let versionResult = try await CommandRunner.run(.pnpmVersion, executable: executable, environment: probe.environment, currentDirectory: home, timeout: .seconds(20))
            guard versionResult.succeeded else {
                return .failed(versionResult.timedOut ? "timeout di `pnpm --version`" : versionResult.tail(2))
            }
            let rawVersion = versionResult.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            guard let version = SemanticVersion(rawVersion) else {
                return .failed("versione non riconosciuta (\(rawVersion))")
            }
            guard version >= PnpmTool.minimumSupportedVersion else {
                return .unsupported(version: version.description, executable: executable.path)
            }
            let storeResult = try await CommandRunner.run(.pnpmStorePath, executable: executable, environment: probe.environment, currentDirectory: home, timeout: .seconds(20))
            var storePath: URL?
            if storeResult.succeeded, let line = storeResult.stdout.split(whereSeparator: \.isNewline).last {
                let candidate = String(line).trimmingCharacters(in: .whitespaces)
                if candidate.hasPrefix("/"), !candidate.split(separator: "/").contains("..") {
                    storePath = URL(fileURLWithPath: candidate, isDirectory: true)
                }
            }
            return .available(PnpmTool(executable: executable, version: version, storePath: storePath, pathEnvironment: path))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Simulatori

    static func inspectSimulators() async -> SimulatorInventory? {
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else { return nil }
        guard let result = try? await CommandRunner.run(.simctlListDevices, executable: xcrun, timeout: .seconds(30)),
              result.succeeded else { return nil }
        return SimulatorInventory.parse(Data(result.stdout.utf8))
    }

    // MARK: Xcode

    /// Posizione personalizzata di DerivedData impostata in Xcode, se presente.
    static func xcodeCustomDerivedDataLocation() -> String? {
        let value = CFPreferencesCopyAppValue("IDECustomDerivedDataLocation" as CFString, "com.apple.dt.Xcode" as CFString)
        return value as? String
    }

    // MARK: Home

    /// Cartelle nascoste di primo livello nella home (es. `~/.npm`, `~/.cargo`), solo per diagnostica.
    static func homeDotDirectories(home: URL, excluding: Set<String>) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.path) else { return [] }
        return names
            .filter { $0.hasPrefix(".") && !excluding.contains($0) }
            .sorted()
            .compactMap { name in
                let url = home.appendingPathComponent(name, isDirectory: true)
                guard let info = FileStat.lstat(url.path), info.isDirectory else { return nil }
                return url
            }
    }
}
