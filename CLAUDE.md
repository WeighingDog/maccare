# MacCare — istruzioni per Claude

- App macOS SwiftUI, deployment target macOS 15, Liquid Glass da macOS 26 con fallback (`Views/Components/DesignSystem.swift`).
- **Interfaccia**: segui la skill di progetto `.claude/skills/ios-design` (vedi `SOURCE.md` per gli adattamenti a macOS). Usa `Spacing`, `Radius`, `glassSurface`, `glassCapsule`, `actionButtonStyle` invece di valori o stili ad hoc.
- **Sicurezza prima di tutto**: nessuna nuova rimozione senza una `AllowRule` in `SafetyPolicy.standardRules` e i relativi test. Le aree protette prevalgono sempre. Un'operazione incerta va saltata.
- Mai rimozioni ricorsive su percorsi costruiti dinamicamente fuori da `SafeRemover`; mai comandi esterni fuori da `AllowedCommand`.
- I test usano solo `TemporaryHome` (directory temporanee): non toccare mai dati reali nei test.
- Build e test:
  - `xcodebuild -project MacCare.xcodeproj -scheme MacCare -destination 'platform=macOS' test`
  - Istantanee UI (Debug): `MacCare.app/Contents/MacOS/MacCare -MacCareSnapshotDir /tmp/shots -MacCareScanOnLaunch`
