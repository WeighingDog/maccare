import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            NavigationStack(path: $model.detailPath) {
                destination(for: model.selection ?? .overview)
                    .navigationDestination(for: CategoryID.self) { id in
                        CleanupCategoryView(categoryID: id)
                    }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ScanToolbarButton()
            }
        }
        .sheet(isPresented: $model.showsCleanupFlow) {
            CleanupFlowSheet()
                .environment(model)
        }
    }

    @ViewBuilder
    private func destination(for item: SidebarItem) -> some View {
        switch item {
        case .overview: StorageDashboardView()
        case .analysis: AnalysisView()
        case .cleanup: CleanupView()
        case .development: DevelopmentView()
        case .activity: ActivityView()
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(SidebarItem.allCases) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(item == .cleanup ? model.pendingConfirmationCount : 0)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
    }
}

/// Modalità della sessione e stato dell'ultima analisi, in fondo alla sidebar.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Label(model.cleanupEnabledThisSession ? "Pulizia consentita" : "Solo analisi",
                  systemImage: model.cleanupEnabledThisSession ? "lock.open" : "lock")
                .foregroundStyle(model.cleanupEnabledThisSession ? .orange : .secondary)
            Text(scanText)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    private var scanText: String {
        if model.isScanning { return "Analisi: \(model.scanProgress.itemsVisited.formatted()) elementi" }
        if let date = model.lastScanDate { return "Analizzato \(date.relativeDescription)" }
        return "Mai analizzato"
    }
}

/// Pulsante principale della toolbar: avvia o interrompe la scansione.
struct ScanToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isScanning {
            Button {
                model.cancelScan()
            } label: {
                Label("Interrompi", systemImage: "stop.fill")
            }
            .help("Interrompi l'analisi (⌘.)")
        } else {
            Button {
                model.startScan()
            } label: {
                Label("Analizza", systemImage: "arrow.clockwise")
            }
            .disabled(model.isCleaning)
            .help("Analizza lo spazio occupato (⌘R)")
        }
    }
}

/// Riga di avanzamento dell'analisi (da usare dentro un `Form`).
struct ScanProgressRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.scanProgress
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(model.scanPhase == .preparing ? "Preparazione…" : "Analisi in corso")
                Spacer()
                Button("Interrompi") { model.cancelScan() }
                    .controlSize(.small)
            }
            if model.scanPhase == .preparing {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: progress.fraction ?? 0)
                Text("\(progress.completedRoots) di \(progress.totalRoots) cartelle · \(progress.itemsVisited.formatted()) elementi · \(progress.bytesCounted.formattedBytes)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .contain)
    }
}
