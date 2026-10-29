import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $path) {
                destination(for: model.selection ?? .overview)
                    .navigationDestination(for: CategoryID.self) { id in
                        CleanupCategoryView(categoryID: id)
                    }
            }
            .background { AmbientBackground() }
        }
        .onChange(of: model.selection) { path = NavigationPath() }
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
            Section("MacCare") {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(badge(for: item))
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarStatusView()
                .padding(Spacing.sm)
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        item == .cleanup ? model.pendingConfirmationCount : 0
    }
}

/// Stato della sessione: modalità e ultima scansione.
private struct SidebarStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(
                model.cleanupEnabledThisSession ? "Pulizia abilitata" : "Solo analisi",
                systemImage: model.cleanupEnabledThisSession ? "lock.open" : "lock"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(model.cleanupEnabledThisSession ? .orange : .secondary)

            if model.isScanning {
                ProgressView(value: model.scanProgress.fraction ?? 0)
                    .controlSize(.small)
                Text("\(model.scanProgress.itemsVisited.formatted()) elementi")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let date = model.lastScanDate {
                Text("Ultima scansione \(date.relativeDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nessuna scansione")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
        .glassSurface(cornerRadius: Radius.tile)
        .accessibilityElement(children: .combine)
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
                Label("Interrompi", systemImage: "stop.circle")
            }
            .help("Interrompi la scansione (⌘.)")
        } else {
            Button {
                model.startScan()
            } label: {
                Label(model.hasScanned ? "Nuova scansione" : "Avvia scansione", systemImage: "magnifyingglass")
            }
            .disabled(model.isCleaning)
            .help("Analizza lo spazio occupato (⌘R)")
        }
    }
}

/// Avanzamento reale della scansione: radici completate, elementi visitati, percorso corrente.
struct ScanProgressCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.scanProgress
        SectionCard(model.scanPhase == .preparing ? "Preparazione della scansione…" : "Scansione in corso", symbol: "magnifyingglass", tint: .accentColor) {
            Button("Interrompi", role: .cancel) { model.cancelScan() }
                .actionButtonStyle(.secondary)
                .controlSize(.small)
        } content: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if model.scanPhase == .preparing {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Verifica degli strumenti di sviluppo (pnpm, simctl) e dei processi attivi.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: progress.fraction ?? 0) {
                        Text("\(progress.completedRoots) di \(progress.totalRoots) cartelle principali")
                            .font(.callout)
                    }
                    HStack(spacing: Spacing.md) {
                        Text("\(progress.itemsVisited.formatted()) elementi")
                        Text(progress.bytesCounted.formattedBytes)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    if !progress.currentRoot.isEmpty {
                        Text(progress.currentRoot.replacingOccurrences(of: model.policy.home.path, with: "~"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
