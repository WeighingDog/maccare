import SwiftUI

/// Testi brevi e coerenti per descrivere lo stato di una categoria in una riga.
extension AppModel {
    /// Dimensione leggibile, o "—" se nessun percorso della categoria è stato misurato.
    func sizeText(for category: CleanupCategory) -> String {
        let measured = category.locations.contains { measurements[$0.path]?.state.isMeasured == true }
        return hasScanned && measured ? size(of: category).formattedBytes : "—"
    }

    func estimateText(for category: CleanupCategory) -> String {
        switch estimate(for: category) {
        case .bytes(let bytes): bytes.formattedBytes
        case .determinedByTool: "Calcolato da pnpm"
        case .none: "—"
        }
    }

    /// Sottotitolo di una riga: il problema più rilevante, altrimenti il livello di sicurezza.
    func statusLine(for category: CleanupCategory) -> (text: String, color: Color) {
        let blockers = knownBlockers(for: category)
        if !blockers.isEmpty {
            return ("In uso: \(blockers.joined(separator: ", "))", .orange)
        }
        if case .denied = measurements[category.locations.first?.path ?? ""]?.state {
            return ("Accesso negato da macOS", .orange)
        }
        switch availability(for: category) {
        case .unavailable(let reason):
            return (reason, .secondary)
        case .notApplicable:
            return (category.safety.title, .secondary)
        case .available, .analysisMode:
            let count = plannedRemovals(for: category).count
            return (count > 0 ? "\(category.safety.title) · \(count) elementi" : category.safety.title, .secondary)
        }
    }

    func measurementStateText(for category: CleanupCategory) -> String {
        guard hasScanned else { return "—" }
        let states = category.locations.compactMap { measurements[$0.path] }
        if states.contains(where: { if case .denied = $0.state { true } else { false } }) { return "Accesso negato" }
        if states.contains(where: \.isPartial) { return "Parziale" }
        if !states.isEmpty, states.allSatisfy({ $0.state == .notFound }) { return "Non presente" }
        return "Completa"
    }
}
