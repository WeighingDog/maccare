import Foundation
import Testing
@testable import MacCare

@Suite("SafeRemover — ispezione e rimozione senza seguire link")
struct SafeRemoverTests {
    let home: TemporaryHome
    let policy: SafetyPolicy
    let remover = SafeRemover()

    init() throws {
        home = try TemporaryHome()
        policy = home.policy
    }

    private func validated(_ relative: String, rule: String = "xcode.derivedData", category: CategoryID = .xcodeDerivedData) throws -> ValidatedTarget {
        try policy.validateRemoval(of: home.path(relative), ruleID: rule, category: category).get()
    }

    @Test("Rimuove l'albero ma non la destinazione dei collegamenti simbolici interni")
    func removesTreeWithoutFollowingSymlinks() throws {
        let precious = try home.write("Documents/precious.txt", bytes: 10)
        try home.mkdir("Documents/precious-dir")
        try home.write("Documents/precious-dir/keep.txt", bytes: 10)
        try home.write("Library/Developer/Xcode/DerivedData/App-1/Build/Intermediates/a.o", bytes: 8192)
        try home.write("Library/Developer/Xcode/DerivedData/App-1/Index/b.idx", bytes: 4096)
        try home.symlink("Library/Developer/Xcode/DerivedData/App-1/link-file", to: precious)
        try home.symlink("Library/Developer/Xcode/DerivedData/App-1/Build/link-dir", to: home.path("Documents/precious-dir"))

        let target = try validated("Library/Developer/Xcode/DerivedData/App-1")
        let inspection = remover.inspect(target)
        #expect(inspection.isCertain)
        #expect(inspection.allocatedBytes >= 8192 + 4096)

        let outcome = remover.removePermanently(target)
        #expect(outcome.succeeded, "Errori: \(outcome.failures)")
        #expect(!home.exists("Library/Developer/Xcode/DerivedData/App-1"))
        #expect(home.exists("Library/Developer/Xcode/DerivedData"), "La radice deve restare")
        #expect(home.exists("Documents/precious.txt"))
        #expect(home.exists("Documents/precious-dir/keep.txt"))
        #expect(outcome.freedBytes >= 8192 + 4096)
    }

    @Test("Salta un elemento che contiene un repository Git")
    func detectsGitRepository() throws {
        try home.write("Library/Developer/Xcode/DerivedData/Weird/SourcePackages/checkouts/lib/.git/HEAD")
        let target = try validated("Library/Developer/Xcode/DerivedData/Weird")
        let inspection = remover.inspect(target)
        #expect(!inspection.isCertain)
        #expect(inspection.forbiddenFinding?.contains("repository Git") == true)
    }

    @Test("Riconosce un repository bare (HEAD + objects + refs)")
    func detectsBareRepository() throws {
        try home.write("Library/Caches/com.apple.dt.Xcode/mirror/HEAD")
        try home.mkdir("Library/Caches/com.apple.dt.Xcode/mirror/objects")
        try home.mkdir("Library/Caches/com.apple.dt.Xcode/mirror/refs")
        let target = try validated("Library/Caches/com.apple.dt.Xcode/mirror", rule: "cache.xcode", category: .appCaches)
        #expect(remover.inspect(target).forbiddenFinding != nil)
    }

    @Test("Salta archivi, certificati e profili", arguments: ["App.xcarchive", "dist.ipa", "cert.p12", "dev.cer", "login.keychain-db"])
    func detectsForbiddenExtensions(name: String) throws {
        try home.write("Library/Caches/com.apple.dt.Xcode/folder/\(name)")
        let target = try validated("Library/Caches/com.apple.dt.Xcode/folder", rule: "cache.xcode", category: .appCaches)
        #expect(remover.inspect(target).forbiddenFinding != nil)
    }

    @Test("In DerivedData le copie embedded.mobileprovision dei prodotti di build sono ammesse")
    func derivedDataAllowsEmbeddedProfiles() throws {
        try home.write("Library/Developer/Xcode/DerivedData/App-2/Build/Products/Debug-iphoneos/App.app/embedded.mobileprovision")
        let target = try validated("Library/Developer/Xcode/DerivedData/App-2")
        #expect(remover.inspect(target).isCertain)
    }

    @Test("Un file hard-linked non viene contato come spazio liberato")
    func hardLinksAreNotReclaimable() throws {
        let original = try home.write("Documents/shared.bin", bytes: 16_384)
        try home.mkdir("Library/Developer/Xcode/DerivedData/App-3")
        try FileManager.default.linkItem(at: original, to: home.path("Library/Developer/Xcode/DerivedData/App-3/shared.bin"))
        let target = try validated("Library/Developer/Xcode/DerivedData/App-3")
        let inspection = remover.inspect(target)
        #expect(inspection.reclaimableBytes == 0)
        let outcome = remover.removePermanently(target)
        #expect(outcome.succeeded)
        #expect(outcome.freedBytes == 0)
        #expect(home.exists("Documents/shared.bin"))
    }
}
