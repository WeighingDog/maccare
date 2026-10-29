import Foundation
@testable import MacCare

/// Home finta in una directory temporanea: i test non toccano mai i dati reali.
final class TemporaryHome {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Percorso canonico (/var → /private/var) per confronti coerenti con la policy.
        url = URL(fileURLWithPath: PathTools.realPath(base.path) ?? base.path, isDirectory: true)
    }

    deinit {
        // Rimuove solo la propria directory temporanea, verificandone il nome.
        let tmp = PathTools.realPath(FileManager.default.temporaryDirectory.path) ?? ""
        if url.lastPathComponent.hasPrefix("MacCareTests-"), url.path.hasPrefix(tmp) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    var policy: SafetyPolicy { .standard(home: url) }

    func path(_ relative: String) -> URL {
        url.appendingPathComponent(relative)
    }

    @discardableResult
    func mkdir(_ relative: String) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func write(_ relative: String, bytes: Int = 4096) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: target)
        return target
    }

    func symlink(_ relative: String, to destination: URL) throws {
        let link = path(relative)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    }

    func exists(_ relative: String) -> Bool {
        FileStat.lstat(path(relative).path) != nil
    }
}

struct StubProbe: RunningSoftwareProbe {
    var result: RunningSoftwareSnapshot

    static let idle = StubProbe(result: RunningSoftwareSnapshot(bundleIdentifiers: [], executableNames: [], commandLines: [], isReliable: true))

    func snapshot() async -> RunningSoftwareSnapshot { result }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { true } else { false }
    }

    var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
