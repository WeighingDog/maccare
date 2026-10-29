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
        case .determinedByTool: "Stima di pnpm"
        case .none: "—"
        }
    }

    /// Sottotitolo di una riga: il problema più rilevante, altrimenti cosa succede pulendo.
    func statusLine(for category: CleanupCategory) -> (text: String, color: Color) {
        let blockers = knownBlockers(for: category)
        if !blockers.isEmpty {
            return ("In uso: \(blockers.joined(separator: ", "))", Palette.warning)
        }
        if case .denied = measurements[category.locations.first?.path ?? ""]?.state {
            return ("Accesso negato da macOS", Palette.warning)
        }
        switch availability(for: category) {
        case .unavailable(let reason), .notApplicable(let reason):
            let trimmed = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
            return (trimmed, .secondary)
        case .available:
            return (shortConsequence(for: category), .secondary)
        }
    }

    /// Conseguenza della pulizia in poche parole.
    func shortConsequence(for category: CleanupCategory) -> String {
        switch category.id {
        case .appCaches: "Le app ricreano la cache al prossimo avvio"
        case .xcodeDerivedData: "La prossima build sarà completa"
        case .gradleCaches: "Le prossime build Gradle saranno più lente"
        case .pnpmStore: "Rimuove solo i pacchetti non usati"
        case .simulators: "Elimina i simulatori senza runtime"
        default: category.safety.title
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
