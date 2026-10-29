import Foundation

/// Informazioni dinamiche raccolte prima della scansione.
struct CatalogContext: Sendable {
    let policy: SafetyPolicy
    /// Radice del sistema (sostituibile nei test).
    var systemRoot = URL(fileURLWithPath: "/", isDirectory: true)
    var pnpmStorePath: URL?
    var homeDotDirectories: [URL] = []
    var includeOtherAppContainers = false

    var home: URL { policy.home }
}

/// Definizione delle categorie. Le categorie con azioni distruttive ricavano
/// i propri percorsi dalle regole della `SafetyPolicy` (unica fonte di verità).
enum CategoryCatalog {
    /// Cartelle nascoste già coperte da altre categorie (escluse dalla diagnostica generica).
    static let dotDirectoriesCoveredElsewhere: Set<String> = [".gradle", ".android", ".pnpm-store", ".Trash"]
    /// Cartelle con credenziali: non vengono nemmeno misurate (principio del minimo accesso).
    static let credentialDirectories: Set<String> = [".ssh", ".gnupg", ".aws", ".kube", ".docker", ".config", ".azure", ".gcloud"]
    static var dotDirectoriesExcludedFromDiagnostics: Set<String> { dotDirectoriesCoveredElsewhere.union(credentialDirectories) }

    static func categories(_ context: CatalogContext) -> [CleanupCategory] {
        let policy = context.policy
        func url(_ relative: String) -> URL { policy.url(relative: relative) }
        func cleanable(_ rule: AllowRule, breakdown: Bool = true) -> LocationSpec {
            LocationSpec(id: rule.id, title: rule.title, url: policy.rootURL(for: rule), kind: .cleanable(ruleID: rule.id), wantsBreakdown: breakdown, note: rule.note)
        }

        var result: [CleanupCategory] = []

        // 1. Cache applicazioni verificate
        result.append(CleanupCategory(
            id: .appCaches,
            title: "Cache applicazioni",
            symbol: "internaldrive",
            summary: "Cache ricreabili di app verificate una per una.",
            details: "Solo cartelle di cache note e ricreate automaticamente dalle rispettive app. Il resto di ~/Library/Caches viene solo misurato. Ogni cache viene saltata se l'app proprietaria è aperta.",
            risks: [
                "Le app ricostruiscono la cache: il primo avvio può essere più lento.",
                "I browser potrebbero ricaricare immagini e risorse dei siti.",
            ],
            safety: .recreatable,
            section: .cleanup,
            locations: policy.rules(for: .appCaches).map { cleanable($0) },
            action: .removeContents
        ))

        // 2. Xcode DerivedData
        result.append(CleanupCategory(
            id: .xcodeDerivedData,
            title: "Xcode DerivedData",
            symbol: "hammer",
            summary: "Prodotti intermedi di build e indici di Xcode.",
            details: "Ogni sottocartella corrisponde a un progetto o a una cache di moduli. La pulizia viene saltata se Xcode o un processo di build (xcodebuild, SWBBuildService…) è in esecuzione.",
            risks: [
                "La build successiva di ogni progetto sarà completa e più lunga.",
                "L'indicizzazione del codice in Xcode ripartirà da zero.",
            ],
            safety: .redownload,
            section: .development,
            locations: policy.rules(for: .xcodeDerivedData).map { cleanable($0) },
            action: .removeContents
        ))

        // 3. Gradle
        var gradleLocations: [LocationSpec] = [
            LocationSpec(id: "gradle.home", title: "Gradle User Home (~/.gradle)", url: url(".gradle"), kind: .analysisOnly, wantsBreakdown: true,
                         note: "Configurazione, JDK e wrapper sono protetti."),
            LocationSpec(id: "gradle.caches", title: "Cache Gradle (~/.gradle/caches)", url: url(".gradle/caches"), kind: .analysisOnly, wantsBreakdown: true,
                         note: "modules-2, transforms, jars e cache per versione sono gestiti dalla pulizia automatica di Gradle."),
        ]
        gradleLocations.append(contentsOf: policy.rules(for: .gradleCaches).map { cleanable($0) })
        result.append(CleanupCategory(
            id: .gradleCaches,
            title: "Cache Gradle",
            symbol: "shippingbox",
            summary: "Solo la cache di build locale, secondo la documentazione Gradle.",
            details: "Gradle non offre un comando di pulizia della cache: la gestisce automaticamente (cache per versione inutilizzate da 30 giorni, file condivisi non usati, log dei daemon oltre 14 giorni). MacCare rimuove soltanto il contenuto di caches/build-cache-1, la cui rimozione è documentata, e solo se nessun processo Gradle è attivo. Il resto viene mostrato a scopo informativo.",
            risks: [
                "Le prossime build Gradle non potranno riusare gli output in cache e saranno più lente.",
                "Se un daemon Gradle è attivo la pulizia viene saltata: chiudi Android Studio o esegui `gradle --stop`.",
            ],
            safety: .redownload,
            section: .development,
            locations: gradleLocations,
            action: .removeContents
        ))

        // 4. pnpm
        var pnpmLocations: [LocationSpec] = []
        if let store = context.pnpmStorePath, StorageMath.isPath(store.path, insideOrEqualTo: context.home.path) {
            pnpmLocations.append(LocationSpec(id: "pnpm.activeStore", title: "Store attivo (pnpm store path)", url: store, kind: .protected, wantsBreakdown: true))
        }
        for (id, title, relative) in [
            ("pnpm.libraryStore", "Store predefinito macOS (~/Library/pnpm/store)", "Library/pnpm/store"),
            ("pnpm.legacyStore", "Store ~/.pnpm-store", ".pnpm-store"),
        ] where !pnpmLocations.contains(where: { $0.path == url(relative).path }) {
            pnpmLocations.append(LocationSpec(id: id, title: title, url: url(relative), kind: .protected, wantsBreakdown: true))
        }
        result.append(CleanupCategory(
            id: .pnpmStore,
            title: "Store pnpm",
            symbol: "cube.box",
            summary: "Pacchetti non più referenziati, rimossi con il comando ufficiale.",
            details: "MacCare non cancella mai file dello store direttamente: esegue `pnpm store prune`, che rimuove solo i pacchetti non usati da alcun progetto. Lo store usa hard link e cloni APFS, quindi la sua dimensione non coincide con lo spazio recuperabile: la stima reale la fornisce pnpm al termine.",
            risks: [
                "Se in futuro servono pacchetti rimossi, pnpm li riscaricherà.",
                "Viene rimossa anche la cache dei metadati dei pacchetti (riscaricata alla prossima installazione).",
            ],
            safety: .redownload,
            section: .development,
            locations: pnpmLocations,
            action: .pnpmStorePrune
        ))

        // 5. Simulatori
        result.append(CleanupCategory(
            id: .simulators,
            title: "Simulatori",
            symbol: "iphone",
            summary: "Dispositivi CoreSimulator, solo analisi per impostazione predefinita.",
            details: "I dati dei simulatori vengono misurati per dispositivo. Nessun file viene toccato direttamente: se abiliti la manutenzione in Impostazioni, MacCare può eseguire il comando ufficiale `xcrun simctl delete unavailable`, che elimina solo i dispositivi di runtime non più installati.",
            risks: [
                "I dispositivi eliminati perdono app installate e dati di test.",
                "I runtime dei simulatori non vengono mai rimossi da MacCare.",
            ],
            safety: .analysisOnly,
            section: .development,
            locations: [
                LocationSpec(id: "sim.root", title: "CoreSimulator", url: url("Library/Developer/CoreSimulator"), kind: .protected, wantsBreakdown: true),
                LocationSpec(id: "sim.devices", title: "Dispositivi simulati", url: url("Library/Developer/CoreSimulator/Devices"), kind: .protected, wantsBreakdown: true),
                LocationSpec(id: "sim.caches", title: "Cache CoreSimulator", url: url("Library/Developer/CoreSimulator/Caches"), kind: .protected, wantsBreakdown: true),
            ],
            action: .simctlDeleteUnavailable
        ))

        // 6. Altre directory grandi (diagnostica)
        var diagnostic: [LocationSpec] = [
            LocationSpec(id: "diag.deviceSupport", title: "Xcode iOS DeviceSupport", url: url("Library/Developer/Xcode/iOS DeviceSupport"), kind: .analysisOnly, wantsBreakdown: true,
                         note: "Simboli copiati dai dispositivi collegati. Gestibili da Xcode (Devices and Simulators)."),
            LocationSpec(id: "diag.logs", title: "Log utente (~/Library/Logs)", url: url("Library/Logs"), kind: .analysisOnly, wantsBreakdown: true),
        ]
        diagnostic.append(contentsOf: context.homeDotDirectories.map { dir in
            LocationSpec(id: "diag.dot.\(dir.lastPathComponent)", title: "~/\(dir.lastPathComponent)", url: dir, kind: .analysisOnly, wantsBreakdown: true)
        })
        if context.includeOtherAppContainers {
            diagnostic.append(LocationSpec(id: "diag.containers", title: "Contenitori app (~/Library/Containers)", url: url("Library/Containers"), kind: .protected, wantsBreakdown: true))
            diagnostic.append(LocationSpec(id: "diag.groupContainers", title: "Contenitori condivisi (~/Library/Group Containers)", url: url("Library/Group Containers"), kind: .protected, wantsBreakdown: true))
        }
        result.append(CleanupCategory(
            id: .largeDirectories,
            title: "Altre directory grandi",
            symbol: "folder.badge.questionmark",
            summary: "Cartelle voluminose individuate dalla scansione, solo diagnostica.",
            details: "Elenco delle cartelle più grandi trovate durante la scansione, con la classificazione della policy. Nessuna azione: le dimensioni servono a capire dove intervenire manualmente o con gli strumenti ufficiali delle singole app.",
            risks: ["Nessun rischio: MacCare non modifica queste cartelle."],
            safety: .analysisOnly,
            section: .diagnostic,
            locations: diagnostic,
            action: .none(reason: "Solo diagnostica")
        ))

        // Dati di sistema (gestiti da macOS: solo analisi)
        func system(_ path: String) -> URL { context.systemRoot.appendingPathComponent(path, isDirectory: true) }
        result.append(CleanupCategory(
            id: .systemData,
            title: "Dati di sistema",
            symbol: "gearshape.2",
            summary: "Runtime dei simulatori, risorse di macOS, swap e volumi di sistema.",
            details: "Parte di ciò che Impostazioni › Spazio chiama «Dati di sistema». Sono file gestiti da macOS e da Xcode: MacCare li misura e indica come intervenire con gli strumenti ufficiali (Xcode › Impostazioni › Componenti, riavvio), ma non li modifica mai. Alcune cartelle di sistema non sono leggibili senza privilegi: la misura può essere per difetto.",
            risks: [
                "Rimuovere a mano runtime o risorse di sistema può rendere inutilizzabili Xcode o funzioni di macOS.",
                "Lo swap si riduce chiudendo app o riavviando, non cancellando file.",
            ],
            safety: .protected,
            section: .diagnostic,
            locations: [
                LocationSpec(id: "sys.assets", title: "Risorse scaricate da macOS (AssetsV2)", url: system("System/Library/AssetsV2"), kind: .protected, wantsBreakdown: true,
                             note: "Include i runtime dei simulatori scaricati da Xcode, i modelli di Siri e Apple Intelligence e la documentazione."),
                LocationSpec(id: "sys.simCaches", title: "Cache dei runtime dei simulatori", url: system("Library/Developer/CoreSimulator/Caches"), kind: .protected, wantsBreakdown: true,
                             note: "Ricreate automaticamente dal sistema quando servono."),
                LocationSpec(id: "sys.vm", title: "Swap e immagine di sospensione", url: system("private/var/vm"), kind: .protected, wantsBreakdown: true),
            ],
            action: .none(reason: "Gestiti da macOS: solo analisi")
        ))

        // Categorie protette o di sola analisi
        result.append(CleanupCategory(
            id: .whatsappMedia,
            title: "Media WhatsApp",
            symbol: "message",
            summary: "Foto, video e documenti ricevuti su WhatsApp.",
            details: "Cartella mostrata solo per dimensione. MacCare non cancella, sposta o modifica alcun file: per liberare spazio usa Impostazioni › Spazio e dati › Gestisci spazio dentro WhatsApp.",
            risks: ["Sono dati personali non ricreabili."],
            safety: .protected,
            section: .protected,
            locations: [LocationSpec(id: "whatsapp.media", title: "WhatsApp Message/Media", url: url(SafetyPolicy.whatsappMediaRelativePath), kind: .protected)],
            action: .none(reason: "Dati personali protetti")
        ))

        result.append(CleanupCategory(
            id: .applicationSupport,
            title: "Application Support",
            symbol: "folder.badge.gearshape",
            summary: "Dati e database delle applicazioni.",
            details: "Contiene dati di app, profili, database e impostazioni. Il contenuto non è identificabile con certezza sufficiente: MacCare mostra solo le dimensioni delle sottocartelle.",
            risks: ["Rimuovere dati da qui può causare la perdita di documenti, profili o account."],
            safety: .protected,
            section: .protected,
            locations: [LocationSpec(id: "appSupport", title: "~/Library/Application Support", url: url("Library/Application Support"), kind: .protected, wantsBreakdown: true)],
            action: .none(reason: "Dati delle applicazioni protetti")
        ))

        result.append(CleanupCategory(
            id: .libraryCaches,
            title: "Cache utente (totale)",
            symbol: "tray.full",
            summary: "Tutta la cartella ~/Library/Caches, solo analisi.",
            details: "Misura complessiva delle cache. Solo le sottocartelle presenti in «Cache applicazioni» possono essere pulite; le altre vengono mostrate a scopo diagnostico perché non sono verificate.",
            risks: ["Non tutte le cache sono davvero temporanee: alcune app vi salvano dati importanti."],
            safety: .analysisOnly,
            section: .diagnostic,
            locations: [LocationSpec(id: "libraryCaches", title: "~/Library/Caches", url: url("Library/Caches"), kind: .analysisOnly, wantsBreakdown: true)],
            action: .none(reason: "Solo analisi: la cartella non viene mai pulita in blocco")
        ))

        result.append(CleanupCategory(
            id: .libraryDeveloper,
            title: "Developer (totale)",
            symbol: "wrench.and.screwdriver",
            summary: "Tutta la cartella ~/Library/Developer.",
            details: "Include DerivedData, archivi, simulatori, DeviceSupport e altri dati degli strumenti di sviluppo Apple. La cartella non viene mai pulita in blocco.",
            risks: ["Contiene archivi firmati e dati dei simulatori."],
            safety: .analysisOnly,
            section: .development,
            locations: [LocationSpec(id: "libraryDeveloper", title: "~/Library/Developer", url: url("Library/Developer"), kind: .analysisOnly, wantsBreakdown: true)],
            action: .none(reason: "Solo analisi")
        ))

        result.append(CleanupCategory(
            id: .xcodeArchives,
            title: "Archivi Xcode",
            symbol: "archivebox",
            summary: "Build archiviate per distribuzione e simboli di debug.",
            details: "Gli archivi contengono build firmate e dSYM necessari per simbolicare i crash. Sono protetti: gestiscili da Xcode › Organizer.",
            risks: ["Senza dSYM non è possibile leggere i crash delle versioni pubblicate."],
            safety: .protected,
            section: .protected,
            locations: [LocationSpec(id: "xcodeArchives", title: "Xcode Archives", url: url("Library/Developer/Xcode/Archives"), kind: .protected, wantsBreakdown: true)],
            action: .none(reason: "Archivi protetti")
        ))

        result.append(CleanupCategory(
            id: .android,
            title: "Android SDK ed emulatori",
            symbol: "apps.iphone",
            summary: "SDK, immagini di sistema ed emulatori Android.",
            details: "SDK ed emulatori (AVD) sono protetti. Per rimuoverli usa Android Studio › SDK Manager e Device Manager.",
            risks: ["Rimuovere SDK o AVD richiede nuovi download di diversi GB."],
            safety: .protected,
            section: .protected,
            locations: [
                LocationSpec(id: "android.home", title: "~/.android", url: url(".android"), kind: .protected, wantsBreakdown: true),
                LocationSpec(id: "android.sdk", title: "Android SDK (~/Library/Android/sdk)", url: url("Library/Android/sdk"), kind: .protected, wantsBreakdown: true),
            ],
            action: .none(reason: "SDK ed emulatori protetti")
        ))

        return result
    }
}
