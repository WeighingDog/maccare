import Darwin
import Foundation

enum RemovalMethod: String, CaseIterable, Codable, Sendable, Identifiable {
    case moveToTrash
    case deletePermanently

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveToTrash: "Sposta nel Cestino"
        case .deletePermanently: "Elimina definitivamente"
        }
    }

    var explanation: String {
        switch self {
        case .moveToTrash:
            "Reversibile: gli elementi restano nel Cestino finché non lo svuoti. Lo spazio viene liberato solo allo svuotamento."
        case .deletePermanently:
            "Irreversibile: lo spazio viene liberato subito e gli elementi non sono recuperabili."
        }
    }
}

struct ContentInspection: Sendable, Equatable {
    var allocatedBytes: Int64 = 0
    /// Byte che verrebbero davvero liberati (file con un solo hard link).
    var reclaimableBytes: Int64 = 0
    var itemCount = 0
    var unreadableCount = 0
    var crossesDevice = false
    var tooDeep = false
    /// Primo contenuto vietato trovato (es. un repository Git), se presente.
    var forbiddenFinding: String?

    /// Un elemento è rimovibile solo se l'ispezione non ha lasciato dubbi.
    var isCertain: Bool { forbiddenFinding == nil && unreadableCount == 0 && !crossesDevice && !tooDeep }

    var uncertaintyReason: String? {
        if let forbiddenFinding { return "Contenuto protetto trovato: \(forbiddenFinding)" }
        if unreadableCount > 0 { return "\(unreadableCount) elementi non leggibili" }
        if crossesDevice { return "Contiene un punto di mount di un altro volume" }
        if tooDeep { return "Struttura di cartelle troppo profonda" }
        return nil
    }
}

struct RemovalOutcome: Sendable, Equatable {
    var freedBytes: Int64 = 0
    var removedItems = 0
    var failures: [String] = []

    var succeeded: Bool { failures.isEmpty }
}

/// Esegue ispezione e rimozione di un `ValidatedTarget` senza mai seguire collegamenti simbolici.
///
/// La visita usa file descriptor (`openat` con `O_NOFOLLOW`, `fstatat` con `AT_SYMLINK_NOFOLLOW`,
/// `unlinkat`), così un componente sostituito da un symlink durante l'operazione non può
/// portare la rimozione fuori dall'elemento validato.
struct SafeRemover: Sendable {
    var maxDepth = 256

    // MARK: Ispezione

    func inspect(_ target: ValidatedTarget) -> ContentInspection {
        var result = ContentInspection()
        guard let parentFD = openParentDirectory(of: target) else {
            result.unreadableCount = 1
            return result
        }
        defer { close(parentFD) }
        let name = target.url.lastPathComponent
        inspectEntry(parentFD: parentFD, name: name, displayPath: name, device: target.device, policy: target.rule.forbiddenContent, depth: 0, into: &result)
        return result
    }

    private func inspectEntry(parentFD: Int32, name: String, displayPath: String, device: dev_t, policy: ForbiddenContentPolicy, depth: Int, into result: inout ContentInspection) {
        guard result.forbiddenFinding == nil else { return }
        guard depth <= maxDepth else { result.tooDeep = true; return }
        guard let info = FileStat.at(parentFD, name: name) else {
            result.unreadableCount += 1
            return
        }
        result.itemCount += 1

        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, policy.extensions.contains(ext) {
            result.forbiddenFinding = "\(displayPath) (.\(ext))"
            return
        }
        if info.isSymbolicLink { return }

        guard info.isDirectory else {
            result.allocatedBytes += info.allocatedBytes
            if info.linkCount <= 1 { result.reclaimableBytes += info.allocatedBytes }
            return
        }
        guard info.device == device else {
            result.crossesDevice = true
            return
        }
        guard let entries = listDirectory(parentFD: parentFD, name: name) else {
            result.unreadableCount += 1
            return
        }
        if policy.rejectGitRepositories, Self.looksLikeGitRepository(name: name, entries: entries) {
            result.forbiddenFinding = "\(displayPath) (repository Git)"
            return
        }
        let childFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard childFD >= 0 else {
            result.unreadableCount += 1
            return
        }
        defer { close(childFD) }
        for entry in entries {
            inspectEntry(parentFD: childFD, name: entry, displayPath: displayPath + "/" + entry, device: device, policy: policy, depth: depth + 1, into: &result)
            if result.forbiddenFinding != nil { return }
        }
    }

    /// Riconosce sia un repository con `.git` sia un repository "bare" (HEAD + objects + refs).
    static func looksLikeGitRepository(name: String, entries: [String]) -> Bool {
        if name == ".git" { return true }
        let set = Set(entries)
        if set.contains(".git") { return true }
        return set.contains("HEAD") && set.contains("objects") && set.contains("refs")
    }

    // MARK: Rimozione definitiva

    func removePermanently(_ target: ValidatedTarget) -> RemovalOutcome {
        var outcome = RemovalOutcome()
        guard let parentFD = openParentDirectory(of: target) else {
            outcome.failures.append("Impossibile aprire la cartella radice senza seguire collegamenti")
            return outcome
        }
        defer { close(parentFD) }
        removeEntry(parentFD: parentFD, name: target.url.lastPathComponent, device: target.device, depth: 0, into: &outcome)
        return outcome
    }

    private func removeEntry(parentFD: Int32, name: String, device: dev_t, depth: Int, into outcome: inout RemovalOutcome) {
        guard depth <= maxDepth else {
            outcome.failures.append("\(name): profondità massima superata")
            return
        }
        guard let info = FileStat.at(parentFD, name: name) else {
            outcome.failures.append("\(name): \(FileStat.lastErrorDescription())")
            return
        }
        if info.isDirectory {
            guard info.device == device else {
                outcome.failures.append("\(name): altro volume, saltato")
                return
            }
            let childFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard childFD >= 0 else {
                outcome.failures.append("\(name): \(FileStat.lastErrorDescription())")
                return
            }
            let entries = listDirectory(fd: childFD) ?? []
            for entry in entries {
                removeEntry(parentFD: childFD, name: entry, device: device, depth: depth + 1, into: &outcome)
            }
            close(childFD)
            if unlinkat(parentFD, name, AT_REMOVEDIR) == 0 {
                outcome.removedItems += 1
            } else {
                outcome.failures.append("\(name): \(FileStat.lastErrorDescription())")
            }
        } else {
            // File regolari e collegamenti simbolici: viene rimosso il nome, mai la destinazione del link.
            if unlinkat(parentFD, name, 0) == 0 {
                outcome.removedItems += 1
                if !info.isSymbolicLink, info.linkCount <= 1 { outcome.freedBytes += info.allocatedBytes }
            } else {
                outcome.failures.append("\(name): \(FileStat.lastErrorDescription())")
            }
        }
    }

    // MARK: Cestino

    func moveToTrash(_ target: ValidatedTarget) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: target.url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    // MARK: Helpers

    /// Apre la cartella che contiene il bersaglio percorrendo ogni componente con `O_NOFOLLOW`.
    private func openParentDirectory(of target: ValidatedTarget) -> Int32? {
        let components = StorageMath.components(target.url.deletingLastPathComponent().path)
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for component in components {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        return fd
    }

    private func listDirectory(parentFD: Int32, name: String) -> [String]? {
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return listDirectory(fd: fd)
    }

    /// Elenca i nomi di una directory aperta (escludendo `.` e `..`).
    private func listDirectory(fd: Int32) -> [String]? {
        let dupFD = dup(fd)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else {
            if dupFD >= 0 { close(dupFD) }
            return nil
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
