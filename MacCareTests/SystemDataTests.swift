import Foundation
import Testing
@testable import MacCare

@Suite("Dati di sistema — parser e protezioni")
struct SystemDataTests {
    @Test("Runtime dei simulatori: stato, dimensione e runtime bloccati")
    func parsesRuntimes() throws {
        let json = """
        {
          "AAA": {"identifier": "AAA", "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "26.4", "build": "23E244",
                  "state": "Deleting", "sizeBytes": 8485747282, "lastUsedAt": "2026-04-20T07:59:18Z", "deletable": true, "kind": "Patchable Cryptex Disk Image"},
          "BBB": {"identifier": "BBB", "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "27.0", "build": "24A434",
                  "state": "Ready", "sizeBytes": 8053063680, "lastUsedAt": "2026-10-27T08:56:57Z", "deletable": true, "kind": "Patchable Cryptex Disk Image"},
          "CCC": {"identifier": "CCC", "platformIdentifier": "com.apple.platform.watchsimulator", "version": "12.0", "state": "Ready"}
        }
        """
        let runtimes = try #require(SystemDataInspector.parseRuntimes(Data(json.utf8)))
        #expect(runtimes.count == 3)
        #expect(runtimes.first?.id == "AAA", "Ordinati per dimensione")
        var snapshot = SystemDataSnapshot()
        snapshot.runtimes = runtimes
        #expect(snapshot.stuckRuntimes.map(\.id) == ["AAA"])
        #expect(snapshot.stuckRuntimeBytes == 8_485_747_282)
        #expect(runtimes.first { $0.id == "CCC" }?.name == "watchOS 12.0")
        #expect(runtimes.first { $0.id == "AAA" }?.lastUsedAt != nil)
        #expect(SystemDataInspector.parseRuntimes(Data("non json".utf8)) == nil)
    }

    @Test("Volumi APFS: solo il contenitore del disco di avvio")
    func parsesAPFSList() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Containers</key><array>
          <dict><key>Volumes</key><array>
            <dict><key>Name</key><string>iSCPreboot</string><key>Roles</key><array><string>Preboot</string></array><key>CapacityInUse</key><integer>6111232</integer></dict>
          </array></dict>
          <dict><key>Volumes</key><array>
            <dict><key>Name</key><string>Macintosh HD</string><key>Roles</key><array><string>System</string></array><key>CapacityInUse</key><integer>13656576000</integer></dict>
            <dict><key>Name</key><string>Preboot</string><key>Roles</key><array><string>Preboot</string></array><key>CapacityInUse</key><integer>10874920960</integer></dict>
            <dict><key>Name</key><string>Macintosh HD - Data</string><key>Roles</key><array><string>Data</string></array><key>CapacityInUse</key><integer>442428080128</integer></dict>
            <dict><key>Name</key><string>VM</string><key>Roles</key><array><string>VM</string></array><key>CapacityInUse</key><integer>15033692160</integer></dict>
          </array></dict>
        </array></dict></plist>
        """
        let volumes = try #require(SystemDataInspector.parseAPFSList(Data(plist.utf8)))
        #expect(volumes.count == 4)
        #expect(!volumes.contains { $0.name == "iSCPreboot" }, "Il contenitore iBoot non è il disco di avvio")
        var snapshot = SystemDataSnapshot()
        snapshot.volumes = volumes
        #expect(!snapshot.systemVolumes.contains { $0.roles.contains("Data") }, "Il volume Dati è misurato a parte")
        #expect(snapshot.systemVolumes.first { $0.roles == ["VM"] }?.bytesInUse == 15_033_692_160)
    }

    @Test("Istantanee locali di Time Machine", arguments: [
        ("Snapshots for disk /:\n", 0),
        ("Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-29-101500.local\ncom.apple.TimeMachine.2026-10-29-111500.local\n", 2),
    ])
    func parsesLocalSnapshots(output: String, expected: Int) {
        #expect(SystemDataInspector.parseLocalSnapshots(output) == expected)
    }

    @Test("Lo swap si legge con sysctl")
    func readsSwapUsage() throws {
        let swap = try #require(SystemDataInspector.swapUsage())
        #expect(swap.total >= swap.used)
    }

    @Test("Nomi leggibili delle risorse di macOS")
    func friendlyAssetNames() {
        #expect(SystemDataInspector.friendlyAssetName("com_apple_MobileAsset_iOSSimulatorRuntime") == "Runtime simulatori iOS")
        #expect(SystemDataInspector.friendlyAssetName("com_apple_MobileAsset_UAF_Siri_Understanding") == "Siri Understanding")
    }

    @Test("I comandi aggiunti hanno argomenti fissi e eseguibili attesi")
    func newCommandsAreFixed() {
        #expect(AllowedCommand.simctlRuntimeList.arguments == ["simctl", "runtime", "list", "-j"])
        #expect(AllowedCommand.diskutilAPFSList.arguments == ["apfs", "list", "-plist"])
        #expect(AllowedCommand.tmutilLocalSnapshots.arguments == ["listlocalsnapshots", "/"])
        #expect(AllowedCommand.diskutilAPFSList.allowedExecutableNames == ["diskutil"])
        #expect(AllowedCommand.tmutilLocalSnapshots.allowedExecutableNames == ["tmutil"])
    }

    @Test("I percorsi di sistema sono protetti e mai rimovibili")
    func systemPathsAreProtected() throws {
        let home = try TemporaryHome()
        let policy = home.policy
        for path in ["/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime", "/Library/Developer/CoreSimulator/Caches", "/private/var/vm/swapfile0"] {
            let url = URL(fileURLWithPath: path)
            guard case .protected = policy.classify(url) else {
                Issue.record("\(path) deve essere protetto")
                continue
            }
            for rule in policy.rules {
                #expect(policy.validateRemoval(of: url, ruleID: rule.id, category: rule.category).failure == .outsideHome)
            }
        }
    }

    @Test("La categoria Dati di sistema è solo analisi")
    func systemDataCategoryIsAnalysisOnly() throws {
        let home = try TemporaryHome()
        let categories = CategoryCatalog.categories(CatalogContext(policy: home.policy))
        let system = try #require(categories.first { $0.id == .systemData })
        #expect(!system.action.isDestructive)
        #expect(system.cleanableLocations.isEmpty)
        #expect(system.locations.allSatisfy { $0.kind.isProtected })
        #expect(system.locations.allSatisfy { !StorageMath.isPath($0.path, insideOrEqualTo: home.url.path) })
    }
}
