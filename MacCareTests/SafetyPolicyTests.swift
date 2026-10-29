import Foundation
import Testing
@testable import MacCare

@Suite("SafetyPolicy — validazione prima della rimozione")
struct SafetyPolicyTests {
    let home: TemporaryHome
    let policy: SafetyPolicy

    init() throws {
        home = try TemporaryHome()
        policy = home.policy
        try home.write("Library/Developer/Xcode/DerivedData/MyApp-abc/Build/file.o")
        try home.write("Library/Caches/com.apple.dt.Xcode/Cache.db")
        try home.write(SafetyPolicy.whatsappMediaRelativePath + "/photo.jpg")
        try home.write("Library/Application Support/SomeApp/data.sqlite")
        try home.write("Documents/tesi.pages")
    }

    @Test("Consente un figlio diretto di DerivedData")
    func allowsDerivedDataChild() {
        let result = policy.validateRemoval(of: home.path("Library/Developer/Xcode/DerivedData/MyApp-abc"), ruleID: "xcode.derivedData", category: .xcodeDerivedData)
        #expect(result.isSuccess)
    }

    @Test("Rifiuta la radice DerivedData stessa")
    func deniesRootItself() {
        let result = policy.validateRemoval(of: home.path("Library/Developer/Xcode/DerivedData"), ruleID: "xcode.derivedData", category: .xcodeDerivedData)
        #expect(result.failure == .notDirectChildOfAllowedRoot)
    }

    @Test("Rifiuta elementi più profondi del primo livello")
    func deniesGrandchild() {
        let result = policy.validateRemoval(of: home.path("Library/Developer/Xcode/DerivedData/MyApp-abc/Build"), ruleID: "xcode.derivedData", category: .xcodeDerivedData)
        #expect(result.failure == .notDirectChildOfAllowedRoot)
    }

    @Test("Rifiuta percorsi con componenti '..'")
    func deniesTraversal() {
        let url = URL(fileURLWithPath: home.url.path + "/Library/Developer/Xcode/DerivedData/../../../../Documents")
        let result = policy.validateRemoval(of: url, ruleID: "xcode.derivedData", category: .xcodeDerivedData)
        guard case .invalidPath = result.failure else {
            Issue.record("Atteso invalidPath, ottenuto \(String(describing: result.failure))")
            return
        }
    }

    @Test("Rifiuta una regola non presente nella allowlist")
    func deniesUnknownRule() {
        let result = policy.validateRemoval(of: home.path("Library/Developer/Xcode/DerivedData/MyApp-abc"), ruleID: "rm.everything", category: .xcodeDerivedData)
        #expect(result.failure == .unknownRule("rm.everything"))
    }

    @Test("Rifiuta una regola usata con la categoria sbagliata")
    func deniesCategoryMismatch() {
        let result = policy.validateRemoval(of: home.path("Library/Developer/Xcode/DerivedData/MyApp-abc"), ruleID: "xcode.derivedData", category: .appCaches)
        #expect(result.failure == .categoryMismatch(expected: .appCaches, actual: .xcodeDerivedData))
    }

    @Test("Rifiuta percorsi fuori dalla home")
    func deniesOutsideHome() {
        let result = policy.validateRemoval(of: URL(fileURLWithPath: "/private/tmp/qualcosa"), ruleID: "xcode.derivedData", category: .xcodeDerivedData)
        #expect(result.failure == .outsideHome)
    }

    @Test("Rifiuta un figlio che è un collegamento simbolico")
    func deniesSymlinkChild() throws {
        let outside = try home.write("Documents/importante.txt")
        try home.symlink("Library/Developer/Xcode/DerivedData/link", to: outside)
        let result = policy.validateRemoval(of: home.path("Library/Developer/Xcode/DerivedData/link"), ruleID: "xcode.derivedData", category: .xcodeDerivedData)
        guard case .symbolicLink = result.failure else {
            Issue.record("Atteso symbolicLink, ottenuto \(String(describing: result.failure))")
            return
        }
    }

    @Test("Rifiuta se la radice autorizzata è un collegamento simbolico")
    func deniesSymlinkedRoot() throws {
        let other = try TemporaryHome()
        try other.write("Library/Caches/node-gyp/22.0.0/include/node.h")
        try other.mkdir("Elsewhere/victim")
        try home.mkdir("Library/Caches")
        try home.symlink("Library/Caches/node-gyp", to: other.path("Elsewhere"))
        let result = policy.validateRemoval(of: home.path("Library/Caches/node-gyp/victim"), ruleID: "cache.nodeGyp", category: .appCaches)
        guard case .symbolicLink = result.failure else {
            Issue.record("Atteso symbolicLink, ottenuto \(String(describing: result.failure))")
            return
        }
        #expect(other.exists("Elsewhere/victim"))
    }

    @Test("Rifiuta un elemento non più esistente")
    func deniesMissing() {
        let result = policy.validateRemoval(of: home.path("Library/Developer/Xcode/DerivedData/Sparito"), ruleID: "xcode.derivedData", category: .xcodeDerivedData)
        #expect(result.failure == .missingTarget)
    }

    @Test("Rifiuta nomi esclusi (.DS_Store)")
    func deniesExcludedName() throws {
        try home.write("Library/Developer/Xcode/DerivedData/.DS_Store")
        let result = policy.validateRemoval(of: home.path("Library/Developer/Xcode/DerivedData/.DS_Store"), ruleID: "xcode.derivedData", category: .xcodeDerivedData)
        #expect(result.failure == .excludedName(".DS_Store"))
    }

    @Test("Le aree protette prevalgono su una regola che le includerebbe")
    func protectedAreaWinsOverRule() throws {
        let unsafeRule = AllowRule(id: "unsafe.groupContainers", category: .appCaches, title: "Regola errata", rootRelativePath: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message", note: "")
        let unsafePolicy = SafetyPolicy(home: home.url, rules: [unsafeRule], protectedAreas: SafetyPolicy.standardProtectedAreas, containerRelativePaths: SafetyPolicy.standardContainers)
        let result = unsafePolicy.validateRemoval(of: home.path(SafetyPolicy.whatsappMediaRelativePath), ruleID: "unsafe.groupContainers", category: .appCaches)
        guard case .protectedPath = result.failure else {
            Issue.record("WhatsApp deve restare protetto, ottenuto \(String(describing: result.failure))")
            return
        }
    }

    @Test("Una regola sulla Library non può rimuovere i contenitori principali")
    func containersNeverTargets() throws {
        let broadRule = AllowRule(id: "unsafe.library", category: .appCaches, title: "Regola errata", rootRelativePath: "Library", note: "")
        let unsafePolicy = SafetyPolicy(home: home.url, rules: [broadRule], protectedAreas: SafetyPolicy.standardProtectedAreas, containerRelativePaths: SafetyPolicy.standardContainers)
        #expect(unsafePolicy.validateRemoval(of: home.path("Library/Caches"), ruleID: "unsafe.library", category: .appCaches).failure == .neverTarget("~/Library/Caches"))
        #expect(unsafePolicy.validateRemoval(of: home.path("Library/Developer"), ruleID: "unsafe.library", category: .appCaches).failure == .neverTarget("~/Library/Developer"))
        guard case .protectedPath = unsafePolicy.validateRemoval(of: home.path("Library/Application Support"), ruleID: "unsafe.library", category: .appCaches).failure else {
            Issue.record("Application Support deve essere protetto")
            return
        }
    }

    @Test("Nessuna regola standard ha la radice dentro un'area protetta")
    func standardRulesDoNotOverlapProtectedAreas() {
        for rule in policy.rules {
            let root = policy.rootURL(for: rule).path
            for area in policy.protectedAreas {
                let areaPath = policy.url(relative: area.relativePath).path
                #expect(!StorageMath.isPath(root, insideOrEqualTo: areaPath), "La regola \(rule.id) è dentro \(area.relativePath)")
                #expect(!StorageMath.isPath(areaPath, insideOrEqualTo: root), "La regola \(rule.id) contiene \(area.relativePath)")
            }
        }
    }

    @Test("Nessuna regola standard punta ai contenitori vietati")
    func standardRulesAreNarrow() {
        let forbiddenRoots = ["", "Library", "Library/Caches", ".gradle", ".pnpm-store", "Library/Developer", "Library/Application Support"]
        for rule in policy.rules {
            #expect(!forbiddenRoots.contains(rule.rootRelativePath), "Regola troppo ampia: \(rule.id)")
        }
    }
}
