import Foundation
import Testing
@testable import MacCare

@Suite("Classificazione di percorsi e categorie")
struct CategoryClassificationTests {
    let home: TemporaryHome
    let policy: SafetyPolicy

    init() throws {
        home = try TemporaryHome()
        policy = home.policy
    }

    @Test("WhatsApp Media è protetto e la sua categoria non ha azioni", arguments: [
        SafetyPolicy.whatsappMediaRelativePath,
        SafetyPolicy.whatsappMediaRelativePath + "/foto/IMG_0001.jpg",
        "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite",
    ])
    func whatsappIsProtected(relative: String) {
        guard case .protected = policy.classify(home.path(relative)) else {
            Issue.record("\(relative) deve essere protetto")
            return
        }
    }

    @Test("Categoria WhatsApp: solo dimensione, nessuna azione")
    func whatsappCategoryHasNoAction() throws {
        let categories = CategoryCatalog.categories(CatalogContext(policy: policy))
        let whatsapp = try #require(categories.first { $0.id == .whatsappMedia })
        #expect(whatsapp.safety == .protected)
        #expect(!whatsapp.action.isDestructive)
        #expect(whatsapp.cleanableLocations.isEmpty)
    }

    @Test("Percorsi protetti", arguments: [
        "Library/Application Support/Google/Chrome/Default/History",
        "Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive",
        "Library/Developer/CoreSimulator/Devices/ABC",
        "Library/Developer/Xcode/UserData/Provisioning Profiles/x.mobileprovision",
        "Library/MobileDevice/Provisioning Profiles/y.mobileprovision",
        "Library/Keychains/login.keychain-db",
        ".android/avd/Pixel.avd",
        "Library/Android/sdk/platforms",
        ".ssh/id_ed25519",
        ".pnpm-store/v3",
        "Library/pnpm/store/v10",
        ".gradle/jdks/jdk-21",
        ".gradle/wrapper/dists",
        "Documents/progetto/.git",
        "Desktop/foto.png",
    ])
    func protectedPaths(relative: String) {
        guard case .protected = policy.classify(home.path(relative)) else {
            Issue.record("\(relative) deve essere protetto, ottenuto \(policy.classify(home.path(relative)))")
            return
        }
    }

    @Test("Contenitori che non vengono mai rimossi in blocco", arguments: [
        "Library", "Library/Caches", "Library/Developer", ".gradle", ".gradle/caches",
    ])
    func containers(relative: String) {
        #expect(policy.classify(home.path(relative)) == .container)
    }

    @Test("Radici e figli autorizzati")
    func cleanableItems() {
        #expect(policy.classify(home.path("Library/Developer/Xcode/DerivedData")) == .cleanableRoot(ruleID: "xcode.derivedData"))
        #expect(policy.classify(home.path("Library/Developer/Xcode/DerivedData/App-xyz")) == .cleanableItem(ruleID: "xcode.derivedData"))
        #expect(policy.classify(home.path("Library/Developer/Xcode/DerivedData/App-xyz/Build")) == .insideCleanableItem(ruleID: "xcode.derivedData"))
        #expect(policy.classify(home.path(".gradle/caches/build-cache-1/abc123")) == .cleanableItem(ruleID: "gradle.buildCache"))
        #expect(policy.classify(home.path("Library/Caches/com.apple.dt.Xcode/Downloads")) == .cleanableItem(ruleID: "cache.xcode"))
    }

    @Test("Cache non verificate e dati Gradle gestiti da Gradle restano solo diagnostica", arguments: [
        "Library/Caches/com.unknown.app",
        "Library/Caches/JetBrains/WebStorm2026.2",
        ".gradle/caches/modules-2",
        ".gradle/caches/transforms-4",
        ".npm/_cacache",
    ])
    func unverifiedPathsAreUnclassified(relative: String) {
        #expect(policy.classify(home.path(relative)) == .unclassified)
    }

    @Test("Le categorie distruttive usano solo radici della allowlist")
    func destructiveCategoriesUseAllowlist() {
        let categories = CategoryCatalog.categories(CatalogContext(policy: policy))
        for category in categories {
            for location in category.cleanableLocations {
                let rule = location.kind.ruleID.flatMap { policy.rule(id: $0) }
                #expect(rule != nil, "\(location.id) non ha una regola")
                #expect(rule?.category == category.id, "\(location.id) usa una regola di un'altra categoria")
                if let rule { #expect(location.url.path == policy.rootURL(for: rule).path) }
            }
            if case .removeContents = category.action {} else {
                #expect(category.cleanableLocations.isEmpty, "\(category.id) ha radici pulibili senza azione removeContents")
            }
        }
    }

    @Test("pnpm e simulatori non hanno radici di rimozione diretta")
    func toolCategoriesNeverDeleteFiles() throws {
        let categories = CategoryCatalog.categories(CatalogContext(policy: policy, pnpmStorePath: home.path("Library/pnpm/store/v10")))
        let pnpm = try #require(categories.first { $0.id == .pnpmStore })
        let sims = try #require(categories.first { $0.id == .simulators })
        #expect(pnpm.cleanableLocations.isEmpty)
        #expect(sims.cleanableLocations.isEmpty)
        #expect(pnpm.action == .pnpmStorePrune)
        #expect(sims.action == .simctlDeleteUnavailable)
        #expect(sims.safety == .analysisOnly)
    }

    @Test("Lo store pnpm fuori dalla home non viene misurato")
    func pnpmStoreOutsideHomeIgnored() throws {
        let categories = CategoryCatalog.categories(CatalogContext(policy: policy, pnpmStorePath: URL(fileURLWithPath: "/Volumes/External/pnpm-store")))
        let pnpm = try #require(categories.first { $0.id == .pnpmStore })
        #expect(!pnpm.locations.contains { $0.path.hasPrefix("/Volumes") })
    }

    @Test("Totali senza doppi conteggi fra cartelle annidate")
    func unionAvoidsNestedDoubleCounting() {
        let parent = home.path("Library/Developer").path
        let child = home.path("Library/Developer/Xcode/DerivedData").path
        let sibling = home.path(".gradle").path
        let measurements: [String: DirectoryMeasurement] = [
            parent: DirectoryMeasurement(path: parent, state: .measured, allocatedBytes: 100),
            child: DirectoryMeasurement(path: child, state: .measured, allocatedBytes: 60),
            sibling: DirectoryMeasurement(path: sibling, state: .measured, allocatedBytes: 10),
        ]
        #expect(StorageMath.unionAllocatedBytes(of: [parent, child, sibling], in: measurements) == 110)
        #expect(StorageMath.maximalPaths([child, parent]) == [parent])
        // Prefisso di stringa ≠ antenato: "/a/b" non contiene "/a/bc".
        #expect(!StorageMath.isPath("/a/bc", insideOrEqualTo: "/a/b"))
    }
}
