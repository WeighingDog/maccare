import Foundation
import Synchronization

struct MeasurementRequest: Hashable, Sendable {
    let url: URL
    let wantsBreakdown: Bool
}

/// Calcola le dimensioni delle cartelle richieste con `FileManager`, in sola lettura.
///
/// Comportamento e limiti:
/// - **Collegamenti simbolici**: mai seguiti. Un percorso richiesto che è esso stesso un symlink
///   viene riportato come `.symbolicLink` e non misurato.
/// - **Hard link**: un file con più link viene contato una sola volta per radice di scansione
///   (identificato tramite `fileIdentifier`). Hard link fra radici diverse possono essere contati due volte.
/// - **Spazio allocato vs apparente**: si riportano entrambi. I cloni APFS condividono blocchi
///   che non è possibile attribuire: lo spazio allocato può quindi sovrastimare lo spazio liberabile.
/// - **Volumi**: i punti di mount interni non vengono attraversati.
/// - **Accesso**: elementi non leggibili (permessi o protezioni privacy di macOS) vengono contati
///   in `unreadableCount` e la misura è marcata come parziale.
/// - **Annidamento**: richieste annidate vengono misurate con un'unica visita della radice più esterna.
struct StorageScanner: Sendable {
    var maxConcurrentRoots = 4
    /// Ogni quanti elementi controllare la cancellazione e notificare l'avanzamento.
    var reportInterval = 2_000

    func measure(
        _ requests: [MeasurementRequest],
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> [String: DirectoryMeasurement] {
        // 1. Normalizza e unisce le richieste duplicate.
        var breakdownByPath: [String: Bool] = [:]
        for request in requests {
            let path = request.url.path
            breakdownByPath[path] = (breakdownByPath[path] ?? false) || request.wantsBreakdown
        }

        var results: [String: DirectoryMeasurement] = [:]
        // percorso canonico -> percorsi richiesti originali
        var canonicalToOriginal: [String: [String]] = [:]
        var canonicalBreakdown: [String: Bool] = [:]
        var singleFiles: [String: FileStat] = [:]

        // 2. Controllo preliminare con lstat.
        for (path, breakdown) in breakdownByPath {
            guard let info = FileStat.lstat(path) else {
                results[path] = .unavailable(path, FileManager.default.fileExists(atPath: path) ? .denied("Accesso negato") : .notFound)
                continue
            }
            if info.isSymbolicLink {
                results[path] = .unavailable(path, .symbolicLink)
                continue
            }
            if info.isRegularFile {
                singleFiles[path] = info
                continue
            }
            guard info.isDirectory else {
                results[path] = .unavailable(path, .unsupported)
                continue
            }
            let canonical = PathTools.realPath(path) ?? path
            canonicalToOriginal[canonical, default: []].append(path)
            canonicalBreakdown[canonical] = (canonicalBreakdown[canonical] ?? false) || breakdown
        }

        for (path, info) in singleFiles {
            var measurement = DirectoryMeasurement(path: path, state: .measured)
            measurement.allocatedBytes = info.allocatedBytes
            measurement.logicalBytes = info.logicalBytes
            measurement.fileCount = 1
            results[path] = measurement
        }

        // 3. Raggruppa per radici massimali.
        let roots = StorageMath.maximalPaths(Array(canonicalBreakdown.keys))
        var jobs: [ScanJob] = []
        for root in roots {
            var nested: [String: Bool] = [:]
            for (path, breakdown) in canonicalBreakdown where path != root && StorageMath.isPath(path, insideOrEqualTo: root) {
                nested[path] = breakdown
            }
            jobs.append(ScanJob(root: root, rootBreakdown: canonicalBreakdown[root] ?? false, nested: nested))
        }

        let tracker = ProgressTracker(totalRoots: jobs.count)
        progress(tracker.snapshot(currentRoot: ""))

        // 4. Visita le radici in parallelo (con concorrenza limitata).
        let interval = reportInterval
        let canonicalResults = try await withThrowingTaskGroup(of: [String: DirectoryMeasurement].self) { group in
            var iterator = jobs.makeIterator()
            var collected: [String: DirectoryMeasurement] = [:]
            func addNext() -> Bool {
                guard let job = iterator.next() else { return false }
                group.addTask {
                    try Self.traverse(job, reportInterval: interval, tracker: tracker, progress: progress)
                }
                return true
            }
            for _ in 0..<max(1, maxConcurrentRoots) where !addNext() { break }
            while let partial = try await group.next() {
                collected.merge(partial) { $1 }
                tracker.completeRoot()
                progress(tracker.snapshot(currentRoot: ""))
                _ = addNext()
            }
            return collected
        }

        // 5. Riporta i risultati sui percorsi richiesti originali.
        for (canonical, measurement) in canonicalResults {
            for original in canonicalToOriginal[canonical] ?? [canonical] {
                var copy = measurement
                copy.path = original
                results[original] = copy
            }
        }
        return results
    }

    /// Misura un singolo percorso (comodo per misurazioni prima/dopo una pulizia).
    func measureSingle(_ url: URL) async throws -> DirectoryMeasurement {
        let result = try await measure([MeasurementRequest(url: url, wantsBreakdown: false)])
        return result[url.path] ?? .unavailable(url.path, .notFound)
    }

    // MARK: - Visita

    private struct ScanJob: Sendable {
        let root: String
        let rootBreakdown: Bool
        let nested: [String: Bool]
    }

    private final class Accumulator {
        let path: String
        let level: Int
        let wantsBreakdown: Bool
        var measurement: DirectoryMeasurement
        var currentChild: String?
        var children: [String: ChildMeasurement] = [:]

        init(path: String, level: Int, wantsBreakdown: Bool) {
            self.path = path
            self.level = level
            self.wantsBreakdown = wantsBreakdown
            self.measurement = DirectoryMeasurement(path: path, state: .measured)
        }

        func finish() -> DirectoryMeasurement {
            var result = measurement
            result.children = children.values.sorted { $0.allocatedBytes > $1.allocatedBytes }
            return result
        }
    }

    /// Raccoglie i percorsi non leggibili segnalati dall'enumeratore, per attribuirli alle misure aperte.
    private final class ErrorCollector {
        var pending: [String] = []
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isRegularFileKey,
        .isVolumeKey,
        .totalFileAllocatedSizeKey,
        .totalFileSizeKey,
        .linkCountKey,
        .fileIdentifierKey,
    ]

    private static func traverse(
        _ job: ScanJob,
        reportInterval: Int,
        tracker: ProgressTracker,
        progress: @Sendable (ScanProgress) -> Void
    ) throws -> [String: DirectoryMeasurement] {
        let fileManager = FileManager()
        let rootURL = URL(fileURLWithPath: job.root, isDirectory: true)

        // Verifica di leggibilità della radice (può attivare una richiesta privacy di macOS).
        do {
            _ = try fileManager.contentsOfDirectory(atPath: job.root)
        } catch {
            var output: [String: DirectoryMeasurement] = [:]
            let reason = (error as NSError).localizedDescription
            output[job.root] = .unavailable(job.root, .denied(reason))
            for path in job.nested.keys { output[path] = .unavailable(path, .denied(reason)) }
            return output
        }

        let errors = ErrorCollector()
        let keySet = Set(resourceKeys)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { url, _ in
                errors.pending.append(url.path)
                return true
            }
        ) else {
            return [job.root: .unavailable(job.root, .denied("Impossibile enumerare la cartella"))]
        }

        let root = Accumulator(path: job.root, level: 0, wantsBreakdown: job.rootBreakdown)
        var stack: [Accumulator] = [root]
        var finished: [String: DirectoryMeasurement] = [:]
        var seenHardLinks = Set<UInt64>()
        var visited = 0
        var bytesSinceReport: Int64 = 0

        func absorbErrors() {
            guard !errors.pending.isEmpty else { return }
            for path in errors.pending {
                for acc in stack where StorageMath.isPath(path, insideOrEqualTo: acc.path) {
                    acc.measurement.unreadableCount += 1
                    if acc.measurement.unreadableSamples.count < 20 {
                        acc.measurement.unreadableSamples.append(path)
                    }
                }
            }
            errors.pending.removeAll(keepingCapacity: true)
        }

        while let object = enumerator.nextObject() {
            absorbErrors()
            guard let url = object as? URL else { continue }
            visited += 1
            if visited % reportInterval == 0 {
                if Task.isCancelled { throw CancellationError() }
                tracker.add(items: reportInterval, bytes: bytesSinceReport)
                bytesSinceReport = 0
                progress(tracker.snapshot(currentRoot: job.root))
            }

            let level = enumerator.level
            while stack.count > 1, let last = stack.last, last.level >= level {
                finished[last.path] = last.finish()
                stack.removeLast()
            }

            guard let values = try? url.resourceValues(forKeys: keySet) else {
                for acc in stack { acc.measurement.unreadableCount += 1 }
                continue
            }

            let name = url.lastPathComponent
            let isSymlink = values.isSymbolicLink ?? false
            let isDirectory = (values.isDirectory ?? false) && !isSymlink

            for acc in stack where acc.wantsBreakdown && level == acc.level + 1 {
                acc.currentChild = name
                acc.children[name] = ChildMeasurement(name: name, isDirectory: isDirectory, isSymbolicLink: isSymlink)
            }

            if isSymlink {
                for acc in stack { acc.measurement.symbolicLinkCount += 1 }
                continue
            }

            if isDirectory {
                if values.isVolume == true {
                    enumerator.skipDescendants()
                    for acc in stack { acc.measurement.skippedMountPoints += 1 }
                    continue
                }
                for acc in stack { acc.measurement.directoryCount += 1 }
                if let breakdown = job.nested[url.path] {
                    stack.append(Accumulator(path: url.path, level: level, wantsBreakdown: breakdown))
                }
                continue
            }

            var allocated = Int64(values.totalFileAllocatedSize ?? 0)
            var logical = Int64(values.totalFileSize ?? 0)
            var duplicate = false
            if let links = values.linkCount, links > 1, let identifier = values.fileIdentifier {
                if !seenHardLinks.insert(identifier).inserted {
                    duplicate = true
                    allocated = 0
                    logical = 0
                }
            }
            bytesSinceReport += allocated

            for acc in stack {
                acc.measurement.fileCount += 1
                acc.measurement.allocatedBytes += allocated
                acc.measurement.logicalBytes += logical
                if duplicate { acc.measurement.hardLinkDuplicates += 1 }
                if acc.wantsBreakdown, let child = acc.currentChild {
                    acc.children[child]?.allocatedBytes += allocated
                    acc.children[child]?.logicalBytes += logical
                    acc.children[child]?.fileCount += 1
                }
            }
        }
        absorbErrors()
        tracker.add(items: visited % reportInterval, bytes: bytesSinceReport)

        while let last = stack.popLast() {
            finished[last.path] = last.finish()
        }
        // Richieste annidate mai incontrate (ad esempio dentro cartelle non leggibili).
        for path in job.nested.keys where finished[path] == nil {
            finished[path] = .unavailable(path, FileStat.lstat(path) == nil ? .notFound : .denied("Non raggiungibile durante la scansione"))
        }
        return finished
    }
}

private final class ProgressTracker: Sendable {
    private let state: Mutex<ScanProgress>

    init(totalRoots: Int) {
        state = Mutex(ScanProgress(totalRoots: totalRoots))
    }

    func add(items: Int, bytes: Int64) {
        state.withLock {
            $0.itemsVisited += items
            $0.bytesCounted += bytes
        }
    }

    func completeRoot() {
        state.withLock { $0.completedRoots += 1 }
    }

    func snapshot(currentRoot: String) -> ScanProgress {
        state.withLock {
            var copy = $0
            if !currentRoot.isEmpty { copy.currentRoot = currentRoot }
            return copy
        }
    }
}
