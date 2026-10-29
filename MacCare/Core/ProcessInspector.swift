import AppKit
import Foundation

/// Fotografia del software in esecuzione, usata per evitare pulizie su dati in uso.
struct RunningSoftwareSnapshot: Sendable, Equatable {
    var bundleIdentifiers: Set<String>
    var executableNames: Set<String>
    var commandLines: [String]
    /// `false` se l'elenco dei processi non è stato ottenuto: in quel caso ogni verifica è "incerta".
    var isReliable: Bool
    var takenAt: Date = .now

    static let unavailable = RunningSoftwareSnapshot(bundleIdentifiers: [], executableNames: [], commandLines: [], isReliable: false)

    /// Elenco leggibile di ciò che blocca la regola (vuoto se nulla la blocca).
    func blockers(bundleIDs: [String], processes: [ProcessMatcher]) -> [String] {
        var found: [String] = []
        for pattern in bundleIDs {
            let matched: Bool
            if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast())
                matched = bundleIdentifiers.contains { $0.hasPrefix(prefix) }
            } else {
                matched = bundleIdentifiers.contains(pattern)
            }
            if matched { found.append(Self.friendlyName(forBundlePattern: pattern)) }
        }
        for matcher in processes {
            let matched: Bool
            switch matcher {
            case .executable:
                matched = executableNames.contains { matcher.matches(executableName: $0) }
            case .argumentContains, .tokenNamed:
                matched = commandLines.contains { matcher.matches(commandLine: $0) }
            }
            if matched { found.append(matcher.displayName) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    static func friendlyName(forBundlePattern pattern: String) -> String {
        switch pattern {
        case "com.apple.dt.Xcode": "Xcode"
        case "com.google.Chrome": "Google Chrome"
        case "org.mozilla.firefox": "Firefox"
        case "com.spotify.client": "Spotify"
        case "com.microsoft.VSCode": "Visual Studio Code"
        case "com.apple.iphonesimulator": "Simulator"
        case "com.google.android.studio*": "Android Studio"
        case "com.jetbrains.*": "IDE JetBrains"
        default: pattern
        }
    }
}

protocol RunningSoftwareProbe: Sendable {
    func snapshot() async -> RunningSoftwareSnapshot
}

/// Implementazione reale: `NSWorkspace` per le app e `/bin/ps` per i processi dell'utente.
struct SystemRunningSoftwareProbe: RunningSoftwareProbe {
    func snapshot() async -> RunningSoftwareSnapshot {
        let bundles = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        let ps = URL(fileURLWithPath: "/bin/ps")
        do {
            let names = try await CommandRunner.run(.processList(columns: .executable), executable: ps, timeout: .seconds(10))
            let args = try await CommandRunner.run(.processList(columns: .commandLine), executable: ps, timeout: .seconds(10))
            guard names.succeeded, args.succeeded else {
                return RunningSoftwareSnapshot(bundleIdentifiers: bundles, executableNames: [], commandLines: [], isReliable: false)
            }
            let executableNames = Set(names.stdout.split(whereSeparator: \.isNewline).map {
                URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)).lastPathComponent
            })
            let commandLines = args.stdout.split(whereSeparator: \.isNewline).map(String.init)
            return RunningSoftwareSnapshot(bundleIdentifiers: bundles, executableNames: executableNames, commandLines: commandLines, isReliable: true)
        } catch {
            return RunningSoftwareSnapshot(bundleIdentifiers: bundles, executableNames: [], commandLines: [], isReliable: false)
        }
    }
}
