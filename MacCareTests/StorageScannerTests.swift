import Foundation
import Testing
@testable import MacCare

@Suite("StorageScanner — misure in sola lettura")
struct StorageScannerTests {
    let home: TemporaryHome
    let scanner = StorageScanner(reportInterval: 10)

    init() throws {
        home = try TemporaryHome()
    }

    @Test("Misura annidata in una sola visita, con scomposizione dei figli")
    func nestedMeasurement() async throws {
        try home.write("Library/Developer/Xcode/DerivedData/A/f1", bytes: 10_000)
        try home.write("Library/Developer/Xcode/DerivedData/B/f2", bytes: 20_000)
        try home.write("Library/Developer/Other/f3", bytes: 5_000)
        let parent = home.path("Library/Developer")
        let child = home.path("Library/Developer/Xcode/DerivedData")

        let result = try await scanner.measure([
            MeasurementRequest(url: parent, wantsBreakdown: true),
            MeasurementRequest(url: child, wantsBreakdown: true),
        ])
        let parentM = try #require(result[parent.path])
        let childM = try #require(result[child.path])
        #expect(parentM.fileCount == 3)
        #expect(childM.fileCount == 2)
        #expect(parentM.allocatedBytes >= childM.allocatedBytes)
        #expect(childM.children.map(\.name).sorted() == ["A", "B"])
        #expect(childM.children.first?.name == "B", "Figli ordinati per dimensione")
        #expect(parentM.logicalBytes == 35_000)
        #expect(StorageMath.unionAllocatedBytes(of: [parent.path, child.path], in: result) == parentM.allocatedBytes)
    }

    @Test("I collegamenti simbolici non vengono seguiti")
    func symlinksNotFollowed() async throws {
        try home.write("Elsewhere/big.bin", bytes: 1_000_000)
        try home.write("Scan/small.bin", bytes: 1_000)
        try home.symlink("Scan/link", to: home.path("Elsewhere"))
        try home.symlink("LinkedRoot", to: home.path("Elsewhere"))

        let result = try await scanner.measure([
            MeasurementRequest(url: home.path("Scan"), wantsBreakdown: false),
            MeasurementRequest(url: home.path("LinkedRoot"), wantsBreakdown: false),
        ])
        let scan = try #require(result[home.path("Scan").path])
        #expect(scan.logicalBytes == 1_000)
        #expect(scan.symbolicLinkCount == 1)
        #expect(result[home.path("LinkedRoot").path]?.state == .symbolicLink)
    }

    @Test("Gli hard link sono contati una sola volta")
    func hardLinksCountedOnce() async throws {
        let original = try home.write("Store/pkg/file.js", bytes: 50_000)
        try home.mkdir("Store/project/node_modules")
        try FileManager.default.linkItem(at: original, to: home.path("Store/project/node_modules/file.js"))
        let result = try await scanner.measure([MeasurementRequest(url: home.path("Store"), wantsBreakdown: false)])
        let store = try #require(result[home.path("Store").path])
        #expect(store.logicalBytes == 50_000)
        #expect(store.hardLinkDuplicates == 1)
    }

    @Test("Percorsi inesistenti e cartelle non leggibili")
    func missingAndUnreadable() async throws {
        try home.write("Locked/inner/secret.txt", bytes: 100)
        try home.write("Locked/visible.txt", bytes: 100)
        let inner = home.path("Locked/inner")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: inner.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inner.path) }

        let result = try await scanner.measure([
            MeasurementRequest(url: home.path("DoesNotExist"), wantsBreakdown: false),
            MeasurementRequest(url: home.path("Locked"), wantsBreakdown: false),
        ])
        #expect(result[home.path("DoesNotExist").path]?.state == .notFound)
        let locked = try #require(result[home.path("Locked").path])
        #expect(locked.state == .measured)
        #expect(locked.unreadableCount >= 1)
        #expect(locked.isPartial)
    }

    @Test("La scansione si interrompe quando il task viene annullato")
    func cancellation() async throws {
        for index in 0..<300 { try home.write("Many/f\(index)", bytes: 10) }
        let url = home.path("Many")
        let scanner = self.scanner
        let task = Task {
            try await scanner.measure([MeasurementRequest(url: url, wantsBreakdown: false)])
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("La scansione è in sola lettura: contenuti e date di modifica invariati")
    func scanIsReadOnly() async throws {
        let file = try home.write("RO/a/b/file.bin", bytes: 12_345)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let dirBefore = try FileManager.default.attributesOfItem(atPath: home.path("RO/a").path)
        _ = try await scanner.measure([MeasurementRequest(url: home.path("RO"), wantsBreakdown: true)])
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        let dirAfter = try FileManager.default.attributesOfItem(atPath: home.path("RO/a").path)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(dirBefore[.modificationDate] as? Date == dirAfter[.modificationDate] as? Date)
        #expect(try Data(contentsOf: file).count == 12_345)
    }

    @Test("Le cartelle con credenziali non vengono misurate nella diagnostica")
    func credentialDirectoriesExcluded() throws {
        for name in [".ssh", ".aws", ".gnupg", ".npm", ".cache"] { try home.mkdir(name) }
        let dirs = DevToolsInspector.homeDotDirectories(home: home.url, excluding: CategoryCatalog.dotDirectoriesExcludedFromDiagnostics)
        let names = Set(dirs.map(\.lastPathComponent))
        #expect(names == [".npm", ".cache"])
    }
}
