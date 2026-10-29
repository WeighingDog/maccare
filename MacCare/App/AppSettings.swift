import Foundation
import Observation

/// Preferenze persistenti. La modalità di pulizia NON è qui: ogni avvio parte in sola analisi.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let removalMethod = "removalMethod"
        static let allowSimulatorMaintenance = "allowSimulatorMaintenance"
        static let includeOtherAppContainers = "includeOtherAppContainers"
        static let useLoginShellPath = "useLoginShellPath"
        static let largeDirectoryThresholdMB = "largeDirectoryThresholdMB"
    }

    private let defaults: UserDefaults

    var removalMethod: RemovalMethod {
        didSet { defaults.set(removalMethod.rawValue, forKey: Key.removalMethod) }
    }

    /// Abilita il solo comando `xcrun simctl delete unavailable`.
    var allowSimulatorMaintenance: Bool {
        didSet { defaults.set(allowSimulatorMaintenance, forKey: Key.allowSimulatorMaintenance) }
    }

    /// Misura `~/Library/Containers` e `~/Library/Group Containers` (macOS può chiedere il permesso per ogni app).
    var includeOtherAppContainers: Bool {
        didSet { defaults.set(includeOtherAppContainers, forKey: Key.includeOtherAppContainers) }
    }

    /// Usa il PATH della shell di login per trovare pnpm e node.
    var useLoginShellPath: Bool {
        didSet { defaults.set(useLoginShellPath, forKey: Key.useLoginShellPath) }
    }

    var largeDirectoryThresholdMB: Int {
        didSet { defaults.set(largeDirectoryThresholdMB, forKey: Key.largeDirectoryThresholdMB) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        removalMethod = RemovalMethod(rawValue: defaults.string(forKey: Key.removalMethod) ?? "") ?? .moveToTrash
        allowSimulatorMaintenance = defaults.bool(forKey: Key.allowSimulatorMaintenance)
        includeOtherAppContainers = defaults.bool(forKey: Key.includeOtherAppContainers)
        useLoginShellPath = defaults.object(forKey: Key.useLoginShellPath) as? Bool ?? true
        let threshold = defaults.integer(forKey: Key.largeDirectoryThresholdMB)
        largeDirectoryThresholdMB = threshold > 0 ? threshold : 500
    }
}
