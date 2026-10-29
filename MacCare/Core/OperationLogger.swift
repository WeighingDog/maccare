import Foundation

/// Voce del registro. Contiene solo metadati operativi (date, percorsi, dimensioni, esiti):
/// mai contenuti dei file.
struct ActivityEntry: Codable, Identifiable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case scan, cleanup, command, policy, info

        var title: String {
            switch self {
            case .scan: "Scansione"
            case .cleanup: "Pulizia"
            case .command: "Comando"
            case .policy: "Sicurezza"
            case .info: "Info"
            }
        }

        var symbol: String {
            switch self {
            case .scan: "magnifyingglass"
            case .cleanup: "sparkles"
            case .command: "terminal"
            case .policy: "lock.shield"
            case .info: "info.circle"
            }
        }
    }

    enum Outcome: String, Codable, Sendable, CaseIterable {
        case success, partial, skipped, failed, cancelled, info

        var title: String {
            switch self {
            case .success: "Completata"
            case .partial: "Parziale"
            case .skipped: "Saltata"
            case .failed: "Errore"
            case .cancelled: "Annullata"
            case .info: "Info"
            }
        }
    }

    var id = UUID()
    var date = Date()
    let kind: Kind
    let outcome: Outcome
    var category: CategoryID?
    let title: String
    var detail: String = ""
    /// Spazio liberato realmente (solo per le pulizie).
    var freedBytes: Int64?
    /// Spazio spostato nel Cestino (non ancora liberato).
    var trashedBytes: Int64?
    /// Altri valori dimensionali (es. totale analizzato).
    var bytes: Int64?
    var path: String?
}

actor OperationLogger {
    let fileURL: URL
    let maxEntries: Int
    private var entries: [ActivityEntry] = []
    private var loaded = false

    init(fileURL: URL = OperationLogger.defaultFileURL(), maxEntries: Int = 5_000) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? PathTools.userHomeDirectory().appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MacCare", isDirectory: true).appendingPathComponent("activity-log.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? Self.decoder.decode([ActivityEntry].self, from: data)) ?? []
    }

    func all() -> [ActivityEntry] {
        ensureLoaded()
        // Ordine di inserimento invertito: stabile anche con date identiche al secondo.
        return entries.reversed()
    }

    func record(_ entry: ActivityEntry) {
        record(contentsOf: [entry])
    }

    func record(contentsOf newEntries: [ActivityEntry]) {
        guard !newEntries.isEmpty else { return }
        ensureLoaded()
        entries.append(contentsOf: newEntries)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        persist()
    }

    func clear() {
        ensureLoaded()
        entries.removeAll()
        persist()
    }

    private func persist() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try Self.encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Il registro non deve mai bloccare un'operazione: in caso di errore resta in memoria.
        }
    }
}
