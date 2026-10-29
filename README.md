# MacCare

App nativa macOS (SwiftUI) per analizzare lo spazio su disco e rimuovere **in sicurezza** cache e artefatti di sviluppo ricreabili.

> Priorità assoluta: proteggere dati personali e ambiente di sviluppo. Un'operazione incerta viene **saltata**, non eseguita.

- Deployment target: **macOS 15.0** (Liquid Glass attivo da macOS 26, con alternativa a materiali su macOS 15)
- Linguaggio: Swift 6 (strict concurrency), SwiftUI, Swift Charts, Swift Testing
- Verificato con: Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0.1

## Aprire e avviare

```bash
open MacCare.xcodeproj
```

In Xcode: schema **MacCare** → destinazione **My Mac** → ⌘R. Il progetto usa la firma "Sign to Run Locally" (ad-hoc), quindi non serve un team di sviluppo. Per distribuirla, imposta il tuo team in *Signing & Capabilities* e notarizza.

Da riga di comando:

```bash
xcodebuild -project MacCare.xcodeproj -scheme MacCare -configuration Debug -destination 'platform=macOS' build
```

```bash
xcodebuild -project MacCare.xcodeproj -scheme MacCare -destination 'platform=macOS' test
```

Il progetto usa le cartelle sincronizzate di Xcode 16+ (`PBXFileSystemSynchronizedRootGroup`): i file aggiunti in `MacCare/` e `MacCareTests/` entrano automaticamente nei target.

## Struttura

```
MacCare/
  App/        MacCareApp, AppModel (stato @Observable), AppSettings, DebugAutomation (solo Debug)
  Models/     CleanupCategory, CategoryCatalog, ScanModels (misure, StorageMath, volume)
  Core/       SafetyPolicy, StorageScanner, CleanupManager, SafeRemover, OperationLogger,
              ProcessInspector, CommandRunner, DevToolsInspector, FileStat
  Views/      StorageDashboardView, AnalysisView, CleanupView, CleanupFlowSheet,
              CleanupCategoryView, DevelopmentView, ActivityView, SettingsView, Components/
MacCareTests/ test di policy, classificazione, scanner, rimozione, manager, comandi, registro
.claude/skills/ios-design/  skill di design usata per l'interfaccia (vedi SOURCE.md)
```

| Componente | Ruolo |
|---|---|
| `SafetyPolicy` | Allowlist delle radici autorizzate, aree protette, contenitori mai rimovibili, validazione sul filesystem prima di ogni rimozione |
| `StorageScanner` | Misura in sola lettura con `FileManager`, una visita per radice esterna, cancellabile, con avanzamento |
| `CleanupManager` | Esegue solo piani confermati, rivalida ogni elemento, controlla i processi in uso, registra l'esito |
| `SafeRemover` | Ispezione e rimozione basate su file descriptor (`openat`/`O_NOFOLLOW`/`unlinkat`), oppure Cestino |
| `OperationLogger` | Registro persistente JSON (`~/Library/Application Support/MacCare/activity-log.json`, permessi 0600) |
| `CategoryCatalog` | Definizione delle categorie; le categorie distruttive ricavano i percorsi dalla policy |

## Operazioni realmente implementate

**Analisi (sempre in sola lettura)**
- Capacità del volume: totale, utilizzato, disponibile (incluso lo spazio eliminabile da macOS).
- Misura di: cache verificate, `~/Library/Caches` (totale e sottocartelle), `~/Library/Developer` (DerivedData, Archives, CoreSimulator, iOS DeviceSupport), `~/Library/Application Support`, media WhatsApp, `~/.android`, `~/Library/Android/sdk`, `~/.gradle` (e `caches/*`), store pnpm (`pnpm store path`, `~/Library/pnpm/store`, `~/.pnpm-store`), `~/Library/Logs`, cartelle nascoste della home (escluse quelle con credenziali), opzionalmente `~/Library/Containers` e `~/Library/Group Containers`.
- Per ogni percorso: spazio allocato, dimensione apparente, file e cartelle, hard link duplicati, symlink non seguiti, elementi non leggibili, scomposizione per sottocartella con la classificazione della policy.
- Elenco dei simulatori (`xcrun simctl list devices --json`) con dimensione per dispositivo.
- Rilevamento di pnpm (versione, eseguibile, store) e dei processi attivi (Xcode, build, Simulator, Gradle, Android Studio, pnpm).

**Pulizia (solo dopo l'abilitazione per la sessione, il riepilogo e la conferma per categoria)**

| Categoria | Operazione | Blocchi |
|---|---|---|
| Cache applicazioni | Figli diretti di: `Caches/com.apple.dt.Xcode`, `Caches/Google/Chrome`, `Caches/Firefox`, `Caches/com.spotify.client`, `Caches/com.microsoft.VSCode.ShipIt`, `Caches/node-gyp`, `Caches/typescript` | App proprietaria aperta; per node-gyp/typescript processi npm/pnpm/tsserver |
| Xcode DerivedData | Figli diretti di `~/Library/Developer/Xcode/DerivedData` | Xcode aperto, `xcodebuild`, `XCBBuildService`, `SWBBuildService`, `swift-build` |
| Cache Gradle | Solo figli di `~/.gradle/caches/build-cache-1` (rimozione documentata da Gradle) | Daemon/launcher Gradle, `gradle`/`gradlew`, Android Studio |
| Store pnpm | `pnpm store prune` (comando ufficiale), pnpm ≥ 7 | Versione cambiata dopo la scansione, pnpm in esecuzione |
| Simulatori | `xcrun simctl delete unavailable`, solo se abilitato nelle Impostazioni | Simulator aperto, build Xcode in corso |
| Altre directory grandi | Nessuna (diagnostica) | — |

Metodo di rimozione: **Sposta nel Cestino** (predefinito, reversibile) oppure **Elimina definitivamente**.

## Regole di sicurezza

- All'avvio l'app è sempre in **modalità solo analisi**. La pulizia si abilita per la sola sessione, con una conferma.
- Sono rimovibili solo i **figli diretti** delle radici in allowlist, mai le radici stesse. `~/Library/Caches`, `~/.gradle`, `~/.pnpm-store`, `~/Library/Developer`, `~/Library/Application Support` e la home non sono mai bersagli, nemmeno tramite un antenato.
- Le **aree protette prevalgono** su qualsiasi regola: WhatsApp, Application Support, Containers e Group Containers, Archives, Xcode UserData, CoreSimulator, MobileDevice, portachiavi, iCloud Drive, Mail, Messaggi, Preferenze, Android, store pnpm, configurazione/JDK/wrapper Gradle, `.ssh`, `.gnupg`, `.aws`, `.kube`, `.docker`, `.config`, Cestino, Documenti, Scrivania, Download, Immagini, Filmati, Musica, Pubblica.
- Prima di **ogni** elemento: nuova validazione di regola e categoria; percorso assoluto senza `.`/`..`/`~`; nessun componente symlink dalla home al bersaglio (verifica con `lstat`); stesso volume della radice; solo file o cartelle regolari; nome non escluso.
- Ispezione del contenuto: un repository Git (`.git` o repository bare), `.xcarchive`, `.ipa`, `.p12`, `.cer`, `.provisionprofile`, `.mobileprovision` (ammesso solo in DerivedData, dove Xcode ne crea copie `embedded`), `.keychain`/`.keychain-db`, elementi non leggibili o punti di mount fanno **saltare** l'elemento.
- Rimozione con file descriptor e `O_NOFOLLOW`: un symlink inserito durante l'operazione non porta mai fuori dall'elemento validato; dei link interni si rimuove il nome, mai la destinazione.
- Si eliminano solo elementi presenti nel riepilogo confermato: ciò che compare dopo la scansione non viene toccato.
- Se l'elenco dei processi non è affidabile, le operazioni che lo richiedono vengono saltate.
- Nessun privilegio di amministratore, nessun tentativo di aggirare TCC/SIP.
- I comandi esterni sono un insieme chiuso (`AllowedCommand`) con argomenti fissi e nessuna shell; l'eseguibile deve avere il nome atteso.
- Il registro contiene solo metadati operativi (data, tipo, esito, categoria, titolo, dettaglio, byte, percorso).

## Sandbox e permessi

L'app **non è in App Sandbox** (`ENABLE_APP_SANDBOX = NO`) e usa l'**Hardened Runtime**. Motivo tecnico: un'app in sandbox non può leggere `~/Library/Caches`, `~/Library/Developer`, `~/.gradle` né avviare `pnpm` o `xcrun simctl` senza che l'utente scelga ogni cartella a mano. Per questo non è distribuibile sul Mac App Store, ma solo come app firmata Developer ID.

Anche senza sandbox, macOS protegge alcuni dati con TCC:
- **Dati di altre app** (es. il contenitore di WhatsApp): la lettura può essere negata. Il percorso viene allora indicato come *non analizzabile*, senza valori stimati. Sul Mac di sviluppo, durante la verifica, la cartella media di WhatsApp è risultata non leggibile.
- **Accesso completo al disco**: facoltativo. MacCare non lo richiede da sé: le Impostazioni contengono un pulsante che apre il pannello di Sistema, e la scelta resta all'utente.
- Documenti, Scrivania e Download non vengono letti.

## Limitazioni note

- **Misure**: lo spazio allocato può sovrastimare lo spazio liberabile (cloni APFS, file condivisi). Gli hard link sono deduplicati per radice di scansione, non fra radici diverse. Gli elementi non leggibili rendono la misura parziale (per difetto).
- **"In uso"**: si controllano app e processi (`NSWorkspace`, `ps`), non i singoli file aperti (`lsof` non viene usato).
- **DerivedData personalizzata**: se Xcode usa una posizione diversa dalla predefinita, MacCare lo segnala ma gestisce solo `~/Library/Developer/Xcode/DerivedData`.
- **pnpm**: la stima reale la fornisce pnpm. Lo spazio liberato viene misurato come differenza dello store prima e dopo. La soglia "pnpm ≥ 7" è una scelta conservativa di MacCare. Per trovare pnpm e node viene letto il PATH della shell di login (zsh/bash, con timeout); l'opzione si disattiva nelle Impostazioni.
- **Gradle**: `modules-2`, `transforms-*`, `jars-*`, le cache per versione e `wrapper/dists` non vengono toccati: li gestisce la pulizia automatica di Gradle, l'unico metodo supportato.
- **Cestino**: lo spazio si libera solo svuotando il Cestino, operazione lasciata all'utente.
- **Cache JetBrains** escluse di proposito: in `~/Library/Caches/JetBrains/*` c'è anche la *Local History*, che è un dato dell'utente.
- **SwiftPM** (`~/Library/Caches/org.swift.swiftpm`) escluso: contiene repository Git (mirror). Esiste il comando ufficiale `swift package purge-cache`.
- **Dynamic Type**: su macOS il ridimensionamento del testo di sistema è limitato. L'interfaccia usa solo stili tipografici semantici.
- **Interfaccia**: da rivedere (decisione presa durante lo sviluppo). Per le istantanee di verifica, nella build Debug:

```bash
/path/to/MacCare.app/Contents/MacOS/MacCare -MacCareSnapshotDir /tmp/shots -MacCareScanOnLaunch
```

  Le istantanee usano `ImageRenderer`: Liquid Glass e alcuni controlli di sistema non vengono disegnati fuori schermo. La modalità esegue una scansione reale in sola lettura, arriva fino al riepilogo della pulizia senza eseguirla e registra nel log la scansione e l'abilitazione di sessione.

## Test

57 test con Swift Testing, eseguiti su home finte create in directory temporanee (`MacCareTests-<UUID>`); nessun dato reale viene letto o modificato. Coprono:

- **SafetyPolicy**: figli diretti consentiti; rifiuto di radici, nipoti, `..`, regole sconosciute o di altra categoria, percorsi fuori dalla home, figli symlink, radici symlink (con verifica che la destinazione resti intatta), elementi spariti, nomi esclusi; prevalenza delle aree protette (WhatsApp) anche con una regola errata; contenitori mai rimovibili; coerenza delle regole standard.
- **Classificazione**: WhatsApp e altri 15 percorsi protetti; contenitori; radici ed elementi autorizzati; cache non verificate e dati Gradle gestiti da Gradle come sola diagnostica; categorie distruttive vincolate alla allowlist; pnpm e simulatori senza rimozione diretta di file; store pnpm fuori dalla home ignorato; totali senza doppi conteggi.
- **SafeRemover**: rimozione di un albero che contiene symlink verso file e cartelle esterni (le destinazioni restano); rilevamento di repository Git normali e bare, archivi, certificati e portachiavi; copie `embedded.mobileprovision` ammesse solo in DerivedData; hard link non contati come spazio liberato.
- **StorageScanner**: misure annidate in un'unica visita; symlink non seguiti; hard link contati una volta; percorsi assenti e non leggibili; cancellazione; sola lettura (date di modifica invariate); cartelle con credenziali escluse.
- **CleanupManager**: elementi confermati eliminati e registrati; categoria non confermata saltata; Xcode aperto, build in corso, daemon Gradle o elenco processi non affidabile → saltato; elemento sostituito da symlink dopo la scansione → saltato; elementi contraffatti fuori allowlist rifiutati; simulatori senza consenso → nessun comando; pnpm con versione cambiata → nessun prune.
- **Supporto**: argomenti fissi dei comandi; eseguibile inatteso rifiutato; versioni semantiche; riconoscimento dei processi; parsing di simctl; registro persistente limitato, con permessi 0600 e solo campi di metadati.

Non coperti dai test automatici: lo spostamento nel Cestino (finirebbe nel Cestino reale), l'esecuzione reale di `pnpm store prune` e di `simctl delete unavailable`, e qualsiasi pulizia sui dati reali.
