# Provenienza

Skill `ios-design` copiata senza modifiche da:

- Repository: https://github.com/pproenca/dot-skills
- Percorso: `skills/.experimental/ios-design`
- Commit: `cf93c57cac89d6fc3e4194686000411567f5caf3` (2026-08-15)
- Licenza: MIT (vedi `LICENSE`)

## Adattamento per MacCare (macOS)

La skill è scritta per iOS 26 e per un'architettura "clinic modular MVVM-C" che MacCare non usa.
In MacCare se ne applicano i principi di design e implementazione SwiftUI, con questi adattamenti:

- Architettura: app singola con `Core/` (logica, nessuna dipendenza da SwiftUI), `Models/` e `Views/`;
  le regole "Clinic Architecture Contract" non si applicano.
- Navigazione: `NavigationSplitView` con sidebar al posto di `TabView`/tab bar (`converse-tabview`, `converse-tab-bar`).
- Target: le regole sui 44×44 pt (`empathy-touch-targets`) diventano dimensioni di controllo standard macOS
  (`controlSize`) e aree cliccabili ampie (`contentShape`).
- Larghezza leggibile (`empathy-readable-width`): applicata ai contenuti delle finestre ridimensionabili.
- Materiali (`system-material-backgrounds`): su macOS 26+ si usa Liquid Glass (`glassEffect`, `.glass`),
  con fallback a `.regularMaterial` su macOS 15.
