#if DEBUG
import AppKit
import SwiftUI

/// Solo build Debug: percorre le schermate e ne salva un'istantanea per la verifica visiva.
///
/// Uso: `MacCare -MacCareSnapshotDir /tmp/shots [-MacCareScanOnLaunch] [-MacCareDark]`
/// Le istantanee usano `/usr/sbin/screencapture`, che richiede il permesso di Registrazione schermo
/// per l'app che avvia MacCare (es. Terminale). Non esegue mai pulizie: apre al massimo il riepilogo.
@MainActor
enum DebugAutomation {
    static func runIfRequested(model: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-MacCareSnapshotDir"), index + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if args.contains("-MacCareDark") { NSApp.appearance = NSAppearance(named: .darkAqua) }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            capture(directory, "00-first-launch")
            if args.contains("-MacCareScanOnLaunch") {
                model.startScan()
                try? await Task.sleep(for: .seconds(1.5))
                capture(directory, "01-scanning")
                let deadline = Date().addingTimeInterval(600)
                while model.isScanning, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            for (offset, item) in SidebarItem.allCases.enumerated() {
                model.selection = item
                try? await Task.sleep(for: .seconds(1.2))
                capture(directory, "1\(offset)-\(item.rawValue)")
            }
            model.selection = .smartClean
            model.openCategory(.xcodeDerivedData)
            try? await Task.sleep(for: .seconds(1.2))
            capture(directory, "20-detail-derivedData")
            model.detailPath = NavigationPath()
            model.openCategory(.systemData)
            try? await Task.sleep(for: .seconds(1.2))
            capture(directory, "20b-detail-systemData")
            model.detailPath = NavigationPath()

            // Selezione e conferma finale, senza eseguire nulla.
            if let first = model.actionableCategories.first(where: { model.isSelectable($0) }) {
                model.selectedForCleanup = [first.id]
                try? await Task.sleep(for: .seconds(0.8))
                capture(directory, "21-selected")
                model.requestCleaning()
                try? await Task.sleep(for: .seconds(1.2))
                capture(directory, "22-confirmation")
                model.confirmsCleaning = false
                model.selectedForCleanup = []
            }

            // Etichetta del pulsante con stime fornite da pnpm.
            model.selectedForCleanup = [.pnpmStore]
            try? await Task.sleep(for: .seconds(0.6))
            capture(directory, "21b-selected-pnpm")
            model.selectedForCleanup = [.pnpmStore, .appCaches]
            try? await Task.sleep(for: .seconds(0.6))
            capture(directory, "21c-selected-pnpm-caches")
            model.selectedForCleanup = []

            // Stato "esito" con dati d'esempio (solo per l'istantanea: nessuna pulizia, nessun registro).
            model.presentedSummary = CleanupSummary(
                startedAt: .now.addingTimeInterval(-12), finishedAt: .now, method: .moveToTrash,
                outcomes: [
                    CategoryOutcome(category: .xcodeDerivedData, title: "Xcode DerivedData", status: .completed, trashedBytes: 28_580_000_000, processedItems: 9),
                    CategoryOutcome(category: .appCaches, title: "Cache applicazioni", status: .partial, trashedBytes: 61_000_000, processedItems: 3,
                                    skipped: [SkippedItem(name: "Chrome/Default", reason: "In uso da: Google Chrome")]),
                ]
            )
            try? await Task.sleep(for: .seconds(1.2))
            capture(directory, "23-done-example")
            model.presentedSummary = nil
            try? await Task.sleep(for: .seconds(0.5))
            NSApp.terminate(nil)
        }
    }

    /// Cattura ogni finestra visibile dell'app (compresi i fogli) con `screencapture -l`.
    private static func capture(_ directory: URL, _ name: String) {
        for window in NSApp.windows where window.isVisible && window.frame.width > 200 {
            let suffix = window.isSheet ? "-sheet" : ""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l\(window.windowNumber)", directory.appendingPathComponent("\(name)\(suffix).png").path]
            try? process.run()
            process.waitUntilExit()
        }
    }
}
#endif
