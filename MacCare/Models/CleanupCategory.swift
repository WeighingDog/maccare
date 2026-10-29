import Foundation

/// Identificatore stabile di ogni categoria gestita da MacCare.
enum CategoryID: String, CaseIterable, Codable, Sendable, Identifiable {
    // Categorie di pulizia (con azione potenzialmente disponibile)
    case appCaches
    case xcodeDerivedData
    case gradleCaches
    case pnpmStore
    case simulators
    case largeDirectories
    // Categorie di sola analisi / protette
    case whatsappMedia
    case applicationSupport
    case libraryCaches
    case libraryDeveloper
    case xcodeArchives
    case android

    var id: String { rawValue }
}

/// Livello di sicurezza mostrato all'utente per una categoria o un percorso.
enum SafetyLevel: String, Codable, Sendable, CaseIterable {
    /// Contenuto ricreato automaticamente dall'app proprietaria.
    case recreatable
    /// Contenuto ricreabile ma che richiede nuovi download o ricompilazioni.
    case redownload
    /// Solo misurazione: MacCare non offre azioni.
    case analysisOnly
    /// Dati protetti: nessuna modifica, mai.
    case protected

    var title: String {
        switch self {
        case .recreatable: "Ricreabile"
        case .redownload: "Richiede riscaricamento"
        case .analysisOnly: "Solo analisi"
        case .protected: "Protetto"
        }
    }

    var symbol: String {
        switch self {
        case .recreatable: "checkmark.shield"
        case .redownload: "arrow.down.circle"
        case .analysisOnly: "eye"
        case .protected: "lock.shield"
        }
    }

    var explanation: String {
        switch self {
        case .recreatable:
            "Il contenuto viene ricreato automaticamente dall'app che lo usa."
        case .redownload:
            "Il contenuto è ricreabile, ma potrebbe servire riscaricare dipendenze o ricompilare."
        case .analysisOnly:
            "MacCare mostra solo la dimensione: non è prevista alcuna rimozione."
        case .protected:
            "Dati protetti dalla policy di sicurezza: nessuna modifica è consentita."
        }
    }
}

enum CategorySection: String, CaseIterable, Sendable {
    case cleanup
    case development
    case protected
    case diagnostic

    var title: String {
        switch self {
        case .cleanup: "Pulizia"
        case .development: "Sviluppo"
        case .protected: "Dati protetti"
        case .diagnostic: "Diagnostica"
        }
    }
}

/// Ruolo di un percorso all'interno di una categoria.
enum LocationKind: Sendable, Hashable {
    /// Dati da proteggere: misurati, mai toccati.
    case protected
    /// Misurato a scopo informativo.
    case analysisOnly
    /// Radice consentita dalla policy: possono essere rimossi solo i suoi figli diretti.
    case cleanable(ruleID: String)

    var ruleID: String? {
        if case .cleanable(let ruleID) = self { ruleID } else { nil }
    }

    var isProtected: Bool {
        if case .protected = self { true } else { false }
    }
}

struct LocationSpec: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let url: URL
    let kind: LocationKind
    /// Se `true`, lo scanner calcola anche la dimensione dei figli diretti.
    let wantsBreakdown: Bool
    let note: String?

    init(id: String, title: String, url: URL, kind: LocationKind, wantsBreakdown: Bool = false, note: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.kind = kind
        self.wantsBreakdown = wantsBreakdown
        self.note = note
    }

    var path: String { url.path }
}

/// Azione che una categoria può offrire. Le azioni sono un insieme chiuso:
/// non esiste un'azione generica "elimina percorso".
enum CategoryAction: Sendable, Hashable {
    /// Nessuna azione: solo analisi o dati protetti.
    case none(reason: String)
    /// Rimozione dei figli diretti delle radici consentite dalla `SafetyPolicy`.
    case removeContents
    /// Comando ufficiale `pnpm store prune`.
    case pnpmStorePrune
    /// Comando ufficiale `xcrun simctl delete unavailable`.
    case simctlDeleteUnavailable

    var isDestructive: Bool {
        if case .none = self { false } else { true }
    }
}

struct CleanupCategory: Identifiable, Sendable, Hashable {
    let id: CategoryID
    let title: String
    let symbol: String
    let summary: String
    let details: String
    let risks: [String]
    let safety: SafetyLevel
    let section: CategorySection
    let locations: [LocationSpec]
    let action: CategoryAction

    var cleanableLocations: [LocationSpec] {
        locations.filter { $0.kind.ruleID != nil }
    }
}
