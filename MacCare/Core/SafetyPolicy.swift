import Foundation

/// Criterio per riconoscere un processo in esecuzione che rende una pulizia insicura.
enum ProcessMatcher: Sendable, Hashable {
    /// Nome dell'eseguibile (ultimo componente del percorso di `comm`).
    case executable(String)
    /// La riga di comando contiene la stringa indicata.
    case argumentContains(String)
    /// Un token della riga di comando ha come ultimo componente `name` (anche `.js/.cjs/.mjs`).
    case tokenNamed(String)

    func matches(executableName: String) -> Bool {
        if case .executable(let name) = self { return executableName == name }
        return false
    }

    func matches(commandLine: String) -> Bool {
        switch self {
        case .executable:
            return false
        case .argumentContains(let needle):
            return commandLine.contains(needle)
        case .tokenNamed(let name):
            let accepted: Set<String> = [name, "\(name).js", "\(name).cjs", "\(name).mjs"]
            return commandLine.split(whereSeparator: \.isWhitespace).contains { token in
                let last = token.split(separator: "/").last.map(String.init) ?? String(token)
                return accepted.contains(last)
            }
        }
    }

    var displayName: String {
        switch self {
        case .executable(let name), .tokenNamed(let name): name
        case .argumentContains(let needle): needle
        }
    }
}

/// Contenuti che, se trovati all'interno di un elemento da rimuovere, fanno saltare l'operazione.
struct ForbiddenContentPolicy: Sendable, Hashable {
    var rejectGitRepositories: Bool
    /// Estensioni (minuscole) di file o pacchetti che non devono mai essere rimossi.
    var extensions: Set<String>

    static let standard = ForbiddenContentPolicy(
        rejectGitRepositories: true,
        extensions: ["xcarchive", "ipa", "mobileprovision", "provisionprofile", "p12", "cer", "keychain", "keychain-db"]
    )

    /// I prodotti di build in DerivedData contengono copie `embedded.mobileprovision` generate da Xcode:
    /// gli originali vivono in percorsi protetti (`~/Library/MobileDevice`, `Xcode/UserData`).
    static let derivedData = ForbiddenContentPolicy(
        rejectGitRepositories: true,
        extensions: ["xcarchive", "ipa", "provisionprofile", "p12", "cer", "keychain", "keychain-db"]
    )
}

/// Regola della allowlist: identifica una radice i cui figli diretti possono essere rimossi.
struct AllowRule: Identifiable, Sendable, Hashable {
    let id: String
    let category: CategoryID
    let title: String
    /// Percorso relativo alla home dell'utente.
    let rootRelativePath: String
    /// Bundle identifier di app che non devono essere in esecuzione (suffisso `*` = prefisso).
    let blockingBundleIDs: [String]
    let blockingProcesses: [ProcessMatcher]
    /// Nomi di figli che non vengono mai rimossi.
    let excludedChildNames: Set<String>
    let forbiddenContent: ForbiddenContentPolicy
    let safety: SafetyLevel
    let note: String

    init(
        id: String,
        category: CategoryID,
        title: String,
        rootRelativePath: String,
        blockingBundleIDs: [String] = [],
        blockingProcesses: [ProcessMatcher] = [],
        excludedChildNames: Set<String> = [],
        forbiddenContent: ForbiddenContentPolicy = .standard,
        safety: SafetyLevel = .recreatable,
        note: String
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.rootRelativePath = rootRelativePath
        self.blockingBundleIDs = blockingBundleIDs
        self.blockingProcesses = blockingProcesses
        self.excludedChildNames = excludedChildNames.union([".DS_Store"])
        self.forbiddenContent = forbiddenContent
        self.safety = safety
        self.note = note
    }
}

/// Area protetta: nulla al suo interno (né la cartella stessa, né i suoi antenati) può essere rimosso.
struct ProtectedArea: Sendable, Hashable {
    let relativePath: String
    let reason: String
}

enum PolicyDenial: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownRule(String)
    case categoryMismatch(expected: CategoryID, actual: CategoryID)
    case invalidPath(String)
    case outsideHome
    case notDirectChildOfAllowedRoot
    case excludedName(String)
    case protectedPath(String)
    case neverTarget(String)
    case symbolicLink(String)
    case missingTarget
    case missingRoot
    case rootNotDirectory
    case differentVolume
    case unsupportedType

    var description: String {
        switch self {
        case .unknownRule(let id): "Regola \"\(id)\" non presente nella allowlist."
        case .categoryMismatch(let expected, let actual): "La regola appartiene a \(actual.rawValue), non a \(expected.rawValue)."
        case .invalidPath(let why): "Percorso non valido: \(why)."
        case .outsideHome: "Il percorso è fuori dalla cartella Inizio."
        case .notDirectChildOfAllowedRoot: "Il percorso non è un figlio diretto di una radice autorizzata."
        case .excludedName(let name): "\"\(name)\" è escluso dalla pulizia."
        case .protectedPath(let reason): "Percorso protetto: \(reason)."
        case .neverTarget(let path): "\(path) non può essere rimosso nel suo insieme."
        case .symbolicLink(let path): "Collegamento simbolico non seguito: \(path)."
        case .missingTarget: "L'elemento non esiste più."
        case .missingRoot: "La cartella radice non esiste."
        case .rootNotDirectory: "La radice non è una cartella."
        case .differentVolume: "L'elemento si trova su un altro volume."
        case .unsupportedType: "Tipo di elemento non supportato."
        }
    }
}

struct ValidatedTarget: Sendable, Hashable {
    let url: URL
    let rule: AllowRule
    let device: dev_t
    let isDirectory: Bool
}

enum PathClassification: Sendable, Hashable {
    case protected(reason: String)
    /// Radice autorizzata: la cartella resta, solo i figli diretti sono candidati.
    case cleanableRoot(ruleID: String)
    /// Figlio diretto di una radice autorizzata.
    case cleanableItem(ruleID: String)
    /// Contenuto interno a un elemento rimovibile (rimosso solo insieme al suo elemento).
    case insideCleanableItem(ruleID: String)
    /// Contenitore che non può mai essere rimosso in blocco (es. `~/Library/Caches`).
    case container
    /// Non riconosciuto: solo diagnostica.
    case unclassified

    var title: String {
        switch self {
        case .protected: "Protetto"
        case .cleanableRoot: "Radice autorizzata"
        case .cleanableItem, .insideCleanableItem: "Pulizia consentita"
        case .container: "Contenitore"
        case .unclassified: "Solo diagnostica"
        }
    }

    var safetyLevel: SafetyLevel {
        switch self {
        case .protected: .protected
        case .cleanableRoot, .cleanableItem, .insideCleanableItem: .recreatable
        case .container, .unclassified: .analysisOnly
        }
    }
}

/// Allowlist dei percorsi e regole di protezione.
///
/// Principi:
/// 1. Si rimuovono solo figli diretti di radici esplicitamente autorizzate (mai le radici stesse).
/// 2. Le aree protette prevalgono sempre sulle regole di autorizzazione.
/// 3. Nessun componente del percorso, dalla home al bersaglio, può essere un collegamento simbolico.
/// 4. Bersaglio e radice devono trovarsi sullo stesso volume.
struct SafetyPolicy: Sendable {
    let home: URL
    let rules: [AllowRule]
    let protectedAreas: [ProtectedArea]
    /// Percorsi (relativi alla home) che non possono essere rimossi né direttamente né tramite un antenato.
    let containerRelativePaths: [String]

    private let homeComponents: [String]

    init(home: URL, rules: [AllowRule], protectedAreas: [ProtectedArea], containerRelativePaths: [String]) {
        let homePath = PathTools.realPath(home.path) ?? home.path
        self.home = URL(fileURLWithPath: homePath, isDirectory: true)
        self.rules = rules
        self.protectedAreas = protectedAreas
        self.containerRelativePaths = containerRelativePaths + rules.map(\.rootRelativePath)
        self.homeComponents = StorageMath.components(homePath)
    }

    // MARK: Lookup

    func rule(id: String) -> AllowRule? {
        rules.first { $0.id == id }
    }

    func rules(for category: CategoryID) -> [AllowRule] {
        rules.filter { $0.category == category }
    }

    func rootURL(for rule: AllowRule) -> URL {
        url(relative: rule.rootRelativePath)
    }

    func url(relative: String) -> URL {
        relative.isEmpty ? home : home.appendingPathComponent(relative, isDirectory: true)
    }

    private func components(relative: String) -> [String] {
        homeComponents + StorageMath.components(relative)
    }

    // MARK: Normalizzazione

    /// Componenti di un percorso assoluto, rifiutando `.`/`..`/`~` e caratteri nulli.
    static func normalizedComponents(of url: URL) -> Result<[String], PolicyDenial> {
        guard url.isFileURL else { return .failure(.invalidPath("non è un URL di file")) }
        let raw = url.path
        guard raw.hasPrefix("/") else { return .failure(.invalidPath("il percorso non è assoluto")) }
        guard !raw.contains("\0") else { return .failure(.invalidPath("carattere nullo")) }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let bad = parts.first(where: { $0 == "." || $0 == ".." || $0 == "~" }) {
            return .failure(.invalidPath("componente \"\(bad)\" non ammesso"))
        }
        return .success(parts)
    }

    private func hasPrefix(_ value: [String], _ prefix: [String]) -> Bool {
        value.count >= prefix.count && Array(value.prefix(prefix.count)) == prefix
    }

    // MARK: Classificazione

    func protectionReason(forComponents comps: [String]) -> String? {
        for area in protectedAreas {
            let areaComps = components(relative: area.relativePath)
            // Il bersaglio è dentro l'area, oppure ne è un antenato (rimuoverlo toccherebbe l'area).
            if hasPrefix(comps, areaComps) || hasPrefix(areaComps, comps) {
                return area.reason
            }
        }
        return nil
    }

    func classify(_ url: URL) -> PathClassification {
        guard case .success(let comps) = Self.normalizedComponents(of: url) else { return .unclassified }
        guard hasPrefix(comps, homeComponents), comps.count > homeComponents.count else {
            return comps == homeComponents ? .container : .unclassified
        }
        for area in protectedAreas where hasPrefix(comps, components(relative: area.relativePath)) {
            return .protected(reason: area.reason)
        }
        for rule in rules {
            let root = components(relative: rule.rootRelativePath)
            if comps == root { return .cleanableRoot(ruleID: rule.id) }
            if hasPrefix(comps, root) {
                if comps.count == root.count + 1 {
                    return rule.excludedChildNames.contains(comps.last ?? "") ? .unclassified : .cleanableItem(ruleID: rule.id)
                }
                return .insideCleanableItem(ruleID: rule.id)
            }
        }
        if containerRelativePaths.contains(where: { hasPrefix(components(relative: $0), comps) }) {
            return .container
        }
        if protectionReason(forComponents: comps) != nil {
            // Antenato di un'area protetta (es. ~/Library): trattato come contenitore.
            return .container
        }
        return .unclassified
    }

    // MARK: Validazione prima della rimozione

    /// Verifica, sul filesystem attuale, che `url` possa essere rimosso secondo la regola `ruleID`
    /// della categoria `category`. Va invocata immediatamente prima di ogni rimozione.
    func validateRemoval(of url: URL, ruleID: String, category: CategoryID) -> Result<ValidatedTarget, PolicyDenial> {
        guard let rule = rule(id: ruleID) else { return .failure(.unknownRule(ruleID)) }
        guard rule.category == category else {
            return .failure(.categoryMismatch(expected: category, actual: rule.category))
        }

        let comps: [String]
        switch Self.normalizedComponents(of: url) {
        case .success(let value): comps = value
        case .failure(let denial): return .failure(denial)
        }

        guard hasPrefix(comps, homeComponents), comps.count > homeComponents.count else {
            return .failure(.outsideHome)
        }

        let rootComps = components(relative: rule.rootRelativePath)
        guard comps.count == rootComps.count + 1, hasPrefix(comps, rootComps) else {
            return .failure(.notDirectChildOfAllowedRoot)
        }

        let name = comps[comps.count - 1]
        guard !name.isEmpty else { return .failure(.invalidPath("nome vuoto")) }
        if rule.excludedChildNames.contains(name) { return .failure(.excludedName(name)) }

        if let container = containerRelativePaths.first(where: { hasPrefix(components(relative: $0), comps) }) {
            return .failure(.neverTarget(container.isEmpty ? "La cartella Inizio" : "~/\(container)"))
        }
        if let reason = protectionReason(forComponents: comps) {
            return .failure(.protectedPath(reason))
        }

        // La home stessa non deve essere un collegamento simbolico.
        let homePath = "/" + homeComponents.joined(separator: "/")
        guard let homeStat = FileStat.lstat(homePath), homeStat.isDirectory else {
            return .failure(.symbolicLink(homePath))
        }

        // Nessun componente fra la home e il bersaglio può essere un collegamento simbolico.
        var rootStat: FileStat?
        var targetStat: FileStat?
        for index in homeComponents.count..<comps.count {
            let path = "/" + comps[0...index].joined(separator: "/")
            guard let info = FileStat.lstat(path) else {
                return .failure(index == comps.count - 1 ? .missingTarget : .missingRoot)
            }
            if info.isSymbolicLink { return .failure(.symbolicLink(path)) }
            if index == rootComps.count - 1 { rootStat = info }
            if index == comps.count - 1 { targetStat = info }
        }

        guard let rootStat, let targetStat else { return .failure(.missingRoot) }
        guard rootStat.isDirectory else { return .failure(.rootNotDirectory) }
        guard targetStat.device == rootStat.device else { return .failure(.differentVolume) }
        guard targetStat.isDirectory || targetStat.isRegularFile else { return .failure(.unsupportedType) }

        let canonicalURL = URL(fileURLWithPath: "/" + comps.joined(separator: "/"), isDirectory: targetStat.isDirectory)
        return .success(ValidatedTarget(url: canonicalURL, rule: rule, device: targetStat.device, isDirectory: targetStat.isDirectory))
    }
}

// MARK: - Policy standard

extension SafetyPolicy {
    static let whatsappMediaRelativePath = "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"

    static func standard(home: URL = PathTools.userHomeDirectory()) -> SafetyPolicy {
        SafetyPolicy(home: home, rules: standardRules, protectedAreas: standardProtectedAreas, containerRelativePaths: standardContainers)
    }

    static let xcodeBuildProcesses: [ProcessMatcher] = [
        .executable("xcodebuild"),
        .executable("XCBBuildService"),
        .executable("SWBBuildService"),
        .executable("swift-build"),
    ]

    static let gradleProcesses: [ProcessMatcher] = [
        .argumentContains("org.gradle.launcher.daemon.bootstrap.GradleDaemon"),
        .argumentContains("org.gradle.wrapper.GradleWrapperMain"),
        .argumentContains("org.gradle.launcher.GradleMain"),
        .tokenNamed("gradle"),
        .tokenNamed("gradlew"),
    ]

    static let pnpmProcesses: [ProcessMatcher] = [
        .executable("pnpm"),
        .tokenNamed("pnpm"),
    ]

    static let standardRules: [AllowRule] = [
        AllowRule(
            id: "xcode.derivedData",
            category: .xcodeDerivedData,
            title: "Xcode DerivedData",
            rootRelativePath: "Library/Developer/Xcode/DerivedData",
            blockingBundleIDs: ["com.apple.dt.Xcode"],
            blockingProcesses: xcodeBuildProcesses,
            forbiddenContent: .derivedData,
            safety: .redownload,
            note: "Prodotti intermedi di build e indici. Xcode li ricrea alla build successiva."
        ),
        AllowRule(
            id: "gradle.buildCache",
            category: .gradleCaches,
            title: "Cache di build locale Gradle",
            rootRelativePath: ".gradle/caches/build-cache-1",
            blockingBundleIDs: ["com.google.android.studio*"],
            blockingProcesses: gradleProcesses,
            safety: .redownload,
            note: "Rimozione documentata da Gradle (caches/build-cache-*). Le prossime build potrebbero essere più lente."
        ),
        AllowRule(
            id: "cache.xcode",
            category: .appCaches,
            title: "Cache di Xcode",
            rootRelativePath: "Library/Caches/com.apple.dt.Xcode",
            blockingBundleIDs: ["com.apple.dt.Xcode"],
            blockingProcesses: [.executable("xcodebuild")],
            note: "Cache dell'interfaccia e dei download di Xcode."
        ),
        AllowRule(
            id: "cache.chrome",
            category: .appCaches,
            title: "Cache di Google Chrome",
            rootRelativePath: "Library/Caches/Google/Chrome",
            blockingBundleIDs: ["com.google.Chrome"],
            note: "Cache web di Chrome. Cronologia, password e profili sono in Application Support e non vengono toccati."
        ),
        AllowRule(
            id: "cache.firefox",
            category: .appCaches,
            title: "Cache di Firefox",
            rootRelativePath: "Library/Caches/Firefox",
            blockingBundleIDs: ["org.mozilla.firefox"],
            note: "Cache web di Firefox. I profili sono in Application Support e non vengono toccati."
        ),
        AllowRule(
            id: "cache.spotify",
            category: .appCaches,
            title: "Cache di Spotify",
            rootRelativePath: "Library/Caches/com.spotify.client",
            blockingBundleIDs: ["com.spotify.client"],
            note: "Brani in cache per lo streaming. I download offline non si trovano qui."
        ),
        AllowRule(
            id: "cache.vscodeShipIt",
            category: .appCaches,
            title: "Aggiornamenti scaricati di VS Code",
            rootRelativePath: "Library/Caches/com.microsoft.VSCode.ShipIt",
            blockingBundleIDs: ["com.microsoft.VSCode"],
            note: "Pacchetti di aggiornamento temporanei di Visual Studio Code."
        ),
        AllowRule(
            id: "cache.nodeGyp",
            category: .appCaches,
            title: "Header node-gyp",
            rootRelativePath: "Library/Caches/node-gyp",
            blockingProcesses: [.tokenNamed("node-gyp"), .tokenNamed("pnpm"), .tokenNamed("npm")],
            safety: .redownload,
            note: "Header di Node.js usati per compilare moduli nativi; riscaricati quando servono."
        ),
        AllowRule(
            id: "cache.typescript",
            category: .appCaches,
            title: "Cache tipi di TypeScript",
            rootRelativePath: "Library/Caches/typescript",
            blockingBundleIDs: ["com.microsoft.VSCode", "com.jetbrains.*"],
            blockingProcesses: [.tokenNamed("tsserver")],
            safety: .redownload,
            note: "Definizioni di tipo scaricate da tsserver per l'acquisizione automatica dei tipi."
        ),
    ]

    static let standardProtectedAreas: [ProtectedArea] = [
        ProtectedArea(relativePath: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared", reason: "messaggi, media e database di WhatsApp"),
        ProtectedArea(relativePath: "Library/Containers/net.whatsapp.WhatsApp", reason: "dati di WhatsApp"),
        ProtectedArea(relativePath: "Library/Group Containers", reason: "dati condivisi di altre app"),
        ProtectedArea(relativePath: "Library/Containers", reason: "dati di app in sandbox"),
        ProtectedArea(relativePath: "Library/Application Support", reason: "dati delle applicazioni"),
        ProtectedArea(relativePath: "Library/Developer/Xcode/Archives", reason: "archivi Xcode"),
        ProtectedArea(relativePath: "Library/Developer/Xcode/UserData", reason: "impostazioni e provisioning profile di Xcode"),
        ProtectedArea(relativePath: "Library/Developer/CoreSimulator", reason: "dispositivi e runtime dei simulatori (gestiti solo con simctl)"),
        ProtectedArea(relativePath: "Library/MobileDevice", reason: "provisioning profile e dati dei dispositivi"),
        ProtectedArea(relativePath: "Library/Keychains", reason: "portachiavi"),
        ProtectedArea(relativePath: "Library/Mobile Documents", reason: "iCloud Drive"),
        ProtectedArea(relativePath: "Library/Mail", reason: "posta"),
        ProtectedArea(relativePath: "Library/Messages", reason: "Messaggi"),
        ProtectedArea(relativePath: "Library/Preferences", reason: "preferenze delle app"),
        ProtectedArea(relativePath: "Library/Android", reason: "SDK ed emulatori Android"),
        ProtectedArea(relativePath: "Library/pnpm", reason: "store pnpm (gestito solo con i comandi pnpm)"),
        ProtectedArea(relativePath: ".android", reason: "configurazione ed emulatori Android"),
        ProtectedArea(relativePath: ".pnpm-store", reason: "store pnpm (gestito solo con i comandi pnpm)"),
        ProtectedArea(relativePath: ".gradle/gradle.properties", reason: "configurazione Gradle"),
        ProtectedArea(relativePath: ".gradle/init.d", reason: "script di inizializzazione Gradle"),
        ProtectedArea(relativePath: ".gradle/jdks", reason: "JDK installati da Gradle"),
        ProtectedArea(relativePath: ".gradle/wrapper", reason: "distribuzioni Gradle Wrapper"),
        ProtectedArea(relativePath: ".ssh", reason: "chiavi SSH"),
        ProtectedArea(relativePath: ".gnupg", reason: "chiavi GPG"),
        ProtectedArea(relativePath: ".aws", reason: "credenziali AWS"),
        ProtectedArea(relativePath: ".kube", reason: "credenziali Kubernetes"),
        ProtectedArea(relativePath: ".docker", reason: "configurazione Docker"),
        ProtectedArea(relativePath: ".config", reason: "configurazioni utente"),
        ProtectedArea(relativePath: ".Trash", reason: "Cestino"),
        ProtectedArea(relativePath: "Documents", reason: "documenti personali"),
        ProtectedArea(relativePath: "Desktop", reason: "Scrivania"),
        ProtectedArea(relativePath: "Downloads", reason: "Download"),
        ProtectedArea(relativePath: "Pictures", reason: "Immagini"),
        ProtectedArea(relativePath: "Movies", reason: "Filmati"),
        ProtectedArea(relativePath: "Music", reason: "Musica"),
        ProtectedArea(relativePath: "Public", reason: "cartella Pubblica"),
    ]

    static let standardContainers: [String] = [
        "",
        "Library",
        "Library/Caches",
        "Library/Caches/Google",
        "Library/Developer",
        "Library/Developer/Xcode",
        ".gradle",
        ".gradle/caches",
    ]
}
