import Foundation

enum MeasurementState: Sendable, Hashable {
    /// Misurazione completata (eventualmente con elementi non leggibili: vedi `unreadableCount`).
    case measured
    /// Il percorso non esiste su questo Mac.
    case notFound
    /// Il percorso è un collegamento simbolico: non viene seguito.
    case symbolicLink
    /// Accesso negato (permessi POSIX o protezioni privacy di macOS).
    case denied(String)
    /// Tipo di elemento non supportato (socket, device…).
    case unsupported

    var isMeasured: Bool { self == .measured }
}

struct ChildMeasurement: Sendable, Hashable, Identifiable {
    let name: String
    var allocatedBytes: Int64 = 0
    var logicalBytes: Int64 = 0
    var fileCount: Int = 0
    var isDirectory: Bool
    var isSymbolicLink: Bool

    var id: String { name }
}

/// Risultato della misurazione di una directory.
///
/// - `allocatedBytes`: spazio effettivamente allocato su disco (`totalFileAllocatedSize`).
/// - `logicalBytes`: dimensione apparente (`totalFileSize`).
/// Le due misure possono divergere per file sparsi, compressione APFS/HFS e cloni APFS.
struct DirectoryMeasurement: Sendable, Hashable {
    var path: String
    var state: MeasurementState
    var allocatedBytes: Int64 = 0
    var logicalBytes: Int64 = 0
    var fileCount: Int = 0
    var directoryCount: Int = 0
    var symbolicLinkCount: Int = 0
    /// File con più hard link già conteggiati altrove nella stessa radice.
    var hardLinkDuplicates: Int = 0
    var unreadableCount: Int = 0
    var skippedMountPoints: Int = 0
    /// Alcuni percorsi non leggibili (solo metadati, max 20).
    var unreadableSamples: [String] = []
    /// Figli diretti (solo se richiesto), ordinati per dimensione decrescente.
    var children: [ChildMeasurement] = []

    var isComplete: Bool { state.isMeasured && unreadableCount == 0 }
    var isPartial: Bool { state.isMeasured && unreadableCount > 0 }

    static func unavailable(_ path: String, _ state: MeasurementState) -> DirectoryMeasurement {
        DirectoryMeasurement(path: path, state: state)
    }
}

struct ScanProgress: Sendable, Equatable {
    var itemsVisited: Int = 0
    var bytesCounted: Int64 = 0
    var currentRoot: String = ""
    var completedRoots: Int = 0
    var totalRoots: Int = 0

    var fraction: Double? {
        guard totalRoots > 0 else { return nil }
        return Double(completedRoots) / Double(totalRoots)
    }
}

/// Utility per sommare dimensioni senza contare due volte cartelle annidate.
enum StorageMath {
    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// `true` se `descendant` coincide con `ancestor` o si trova al suo interno
    /// (confronto per componenti, non per prefisso di stringa).
    static func isPath(_ descendant: String, insideOrEqualTo ancestor: String) -> Bool {
        let d = components(descendant)
        let a = components(ancestor)
        guard d.count >= a.count else { return false }
        return Array(d.prefix(a.count)) == a
    }

    /// Restituisce i soli percorsi "massimali": quelli non contenuti in un altro percorso dell'insieme.
    static func maximalPaths(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths)).sorted { components($0).count < components($1).count }
        var result: [String] = []
        for path in unique where !result.contains(where: { isPath(path, insideOrEqualTo: $0) }) {
            result.append(path)
        }
        return result
    }

    /// Somma lo spazio allocato dei percorsi indicati, eliminando le sovrapposizioni.
    static func unionAllocatedBytes(of paths: [String], in measurements: [String: DirectoryMeasurement]) -> Int64 {
        maximalPaths(paths.filter { measurements[$0]?.state.isMeasured == true })
            .reduce(0) { $0 + (measurements[$1]?.allocatedBytes ?? 0) }
    }
}

struct VolumeSnapshot: Sendable, Equatable {
    let name: String
    let totalBytes: Int64
    /// Spazio disponibile per usi importanti (include lo spazio eliminabile da macOS, come nel Finder).
    let availableBytes: Int64
    /// Spazio libero in senso stretto, senza contare lo spazio eliminabile.
    let freeBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var purgeableBytes: Int64 { max(0, availableBytes - freeBytes) }

    static func current(for url: URL) -> VolumeSnapshot? {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? free
        return VolumeSnapshot(
            name: values.volumeLocalizedName ?? "Disco",
            totalBytes: Int64(total),
            availableBytes: important,
            freeBytes: free
        )
    }
}

extension Int64 {
    /// Formato coerente con il Finder (base 1000).
    var formattedBytes: String {
        formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}
