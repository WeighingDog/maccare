#if DEBUG
import AppKit
import SwiftUI

/// Solo build Debug: istantanee delle schermate per la verifica visiva.
/// Uso: `MacCare -MacCareSnapshotDir /tmp/shots [-MacCareScanOnLaunch]`
/// Non esegue mai pulizie: apre al massimo il riepilogo e lo richiude.
@MainActor
enum DebugAutomation {
    static func runIfRequested(model: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-MacCareSnapshotDir"), index + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        current = model
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            capture(directory, "00-first-launch")
            if args.contains("-MacCareScanOnLaunch") {
                model.startScan()
                try? await Task.sleep(for: .seconds(1))
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
            for id in [CategoryID.xcodeDerivedData, .appCaches, .whatsappMedia] {
                renderDetail(directory, id)
            }
            dumpMetrics(directory, model)
            // Flusso di pulizia fino al riepilogo (senza eseguire nulla).
            model.selection = .cleanup
            model.enableCleanupForSession()
            if let first = model.actionableCategories.first(where: { model.availability(for: $0) == .available }) {
                model.selectedForCleanup = [first.id]
                try? await Task.sleep(for: .seconds(0.8))
                capture(directory, "20-cleanup-enabled")
                model.prepareReview()
                try? await Task.sleep(for: .seconds(1.5))
                capture(directory, "21-review-sheet")
                model.showsCleanupFlow = false
            }
            model.disableCleanupForSession()
            model.selectedForCleanup = []
            NSApp.appearance = NSAppearance(named: .darkAqua)
            model.selection = .overview
            try? await Task.sleep(for: .seconds(1.2))
            capture(directory, "30-overview-dark")
            model.selection = .development
            try? await Task.sleep(for: .seconds(1.2))
            capture(directory, "31-development-dark")
            NSApp.terminate(nil)
        }
    }

    /// Disegna la pagina corrente fuori schermo con `ImageRenderer` (il vetro reale non viene reso).
    private static func capture(_ directory: URL, _ name: String) {
        guard let model = current else { return }
        let page: AnyView
        if model.showsCleanupFlow {
            page = AnyView(CleanupFlowSheet(scrollable: false).frame(width: 720, height: 900))
        } else {
            switch model.selection ?? .overview {
            case .overview: page = AnyView(StorageDashboardView(scrollable: false))
            case .analysis: page = AnyView(AnalysisView(scrollable: false))
            case .cleanup: page = AnyView(CleanupView(scrollable: false))
            case .development: page = AnyView(DevelopmentView(scrollable: false))
            case .activity: page = AnyView(ActivityView())
            }
        }
        let dark = NSApp.appearance?.name == .darkAqua
        let content = page
            .environment(model)
            .frame(width: 1000, height: 1900, alignment: .top)
            .background(AmbientBackground())
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func renderDetail(_ directory: URL, _ id: CategoryID) {
        guard let model = current else { return }
        let renderer = ImageRenderer(content: CleanupCategoryView(categoryID: id, scrollable: false)
            .environment(model)
            .frame(width: 1000, alignment: .top)
            .background(AmbientBackground()))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent("40-detail-\(id.rawValue).png"))
    }

    /// Metriche in testo per la verifica (solo metadati: percorsi e dimensioni).
    private static func dumpMetrics(_ directory: URL, _ model: AppModel) {
        var lines: [String] = []
        lines.append("analyzed=\(model.analyzedBytes) protected=\(model.protectedBytes) recoverable=\(model.recoverableBytes) unanalyzable=\(model.unanalyzableCount)")
        lines.append("pnpm=\(model.pnpmStatus.message)")
        lines.append("simulators=\(model.simulatorInventory?.devices.count ?? -1) unavailable=\(model.simulatorInventory?.unavailableDevices.count ?? -1)")
        for category in model.categories {
            lines.append("[\(category.id.rawValue)] size=\(model.size(of: category).formattedBytes) estimate=\(model.estimate(for: category)) availability=\(model.availability(for: category)) items=\(model.plannedRemovals(for: category).count)")
            for location in category.locations {
                let m = model.measurement(for: location)
                lines.append("   \(location.path) state=\(String(describing: m?.state)) alloc=\((m?.allocatedBytes ?? 0).formattedBytes) logical=\((m?.logicalBytes ?? 0).formattedBytes) files=\(m?.fileCount ?? 0) unreadable=\(m?.unreadableCount ?? 0) hardlinkDup=\(m?.hardLinkDuplicates ?? 0)")
            }
        }
        try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("metrics.txt"), atomically: true, encoding: .utf8)
    }

    private static var current: AppModel?
}
#endif
