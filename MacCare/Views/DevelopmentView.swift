import SwiftUI

/// Vista dedicata all'ambiente di sviluppo: Xcode, simulatori, Android, Gradle, pnpm.
struct DevelopmentView: View {
    @Environment(AppModel.self) private var model
    var scrollable = true

    var body: some View {
        PageContainer(scrollable: scrollable) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                PageHeader("Sviluppo", subtitle: "Xcode, simulatori, Android, Gradle e pnpm")
                if model.isScanning { ScanProgressCard() }
                if !model.hasScanned && !model.isScanning {
                    InlineNotice(text: "Avvia una scansione per misurare gli strumenti di sviluppo.", style: .info)
                }
                RunningToolsCard()
                GlassGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Spacing.md)], spacing: Spacing.md) {
                        ForEach([CategoryID.xcodeDerivedData, .xcodeArchives, .libraryDeveloper, .gradleCaches, .pnpmStore, .android], id: \.self) { id in
                            if let category = model.category(id) {
                                ToolSummaryTile(category: category)
                            }
                        }
                    }
                }
                SimulatorsCard()
                PnpmCard()
                GradleCard()
            }
            .pageLayout()
        }
        .navigationTitle("Sviluppo")
    }
}

private struct ToolSummaryTile: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory

    var body: some View {
        NavigationLink(value: category.id) {
            HStack(spacing: Spacing.sm) {
                CategoryIcon(symbol: category.symbol, tint: category.id.tint, size: 40)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(category.title).font(.headline)
                    Text(model.hasScanned ? model.size(of: category).formattedBytes : "—")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    SafetyBadge(level: category.safety, compact: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.md)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassSurface(cornerRadius: Radius.tile, tint: category.id.tint, interactive: true)
        .accessibilityHint("Apre il dettaglio")
    }
}

/// Strumenti attivi rilevati: determinano quali pulizie verranno saltate.
private struct RunningToolsCard: View {
    @Environment(AppModel.self) private var model

    private struct Check: Identifiable {
        let id: String
        let title: String
        let running: Bool
    }

    var body: some View {
        if let snapshot = model.runningSnapshot {
            let checks = [
                Check(id: "xcode", title: "Xcode", running: snapshot.bundleIdentifiers.contains("com.apple.dt.Xcode")),
                Check(id: "build", title: "Build Xcode", running: !snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.xcodeBuildProcesses).isEmpty),
                Check(id: "sim", title: "Simulator", running: snapshot.bundleIdentifiers.contains("com.apple.iphonesimulator")),
                Check(id: "gradle", title: "Gradle", running: !snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.gradleProcesses).isEmpty),
                Check(id: "studio", title: "Android Studio", running: snapshot.bundleIdentifiers.contains { $0.hasPrefix("com.google.android.studio") }),
                Check(id: "pnpm", title: "pnpm", running: !snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.pnpmProcesses).isEmpty),
            ]
            SectionCard("Processi attivi", symbol: "cpu", tint: .accentColor) {
                Text("Rilevati \(snapshot.takenAt.relativeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } content: {
                if !snapshot.isReliable {
                    InlineNotice(text: "Elenco dei processi non disponibile: le pulizie che lo richiedono verranno saltate.", style: .warning)
                }
                HStack(spacing: Spacing.sm) {
                    ForEach(checks) { check in
                        Label(check.title, systemImage: check.running ? "circle.fill" : "circle")
                            .font(.callout)
                            .foregroundStyle(check.running ? .orange : .secondary)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xxs)
                            .glassCapsule(tint: check.running ? .orange : nil)
                            .accessibilityLabel("\(check.title): \(check.running ? "in esecuzione" : "non attivo")")
                    }
                }
                Text("Le pulizie che dipendono da uno strumento attivo vengono saltate e registrate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SimulatorsCard: View {
    @Environment(AppModel.self) private var model

    private struct Row: Identifiable {
        let id: String
        let name: String
        let runtime: String
        let state: String
        let available: Bool
        let bytes: Int64?
    }

    var body: some View {
        SectionCard("Simulatori", symbol: "iphone", tint: .indigo) {
            NavigationLink("Dettagli", value: CategoryID.simulators)
                .buttonStyle(.link)
        } content: {
            if let inventory = model.simulatorInventory {
                let rows = rows(inventory)
                if rows.isEmpty {
                    Text("Nessun dispositivo simulato.").foregroundStyle(.secondary)
                } else {
                    Table(rows) {
                        TableColumn("Dispositivo", value: \.name)
                        TableColumn("Runtime", value: \.runtime)
                        TableColumn("Stato") { row in
                            Text(row.available ? row.state : "Non disponibile")
                                .foregroundStyle(row.available ? Color.secondary : Color.orange)
                        }
                        TableColumn("Dati") { row in
                            Text(row.bytes?.formattedBytes ?? "—").monospacedDigit()
                        }
                        .width(min: 70, ideal: 90)
                    }
                    .frame(minHeight: 200, idealHeight: 260)
                    .scrollContentBackground(.hidden)
                }
                Text(inventory.unavailableDevices.isEmpty
                     ? "Tutti i dispositivi hanno un runtime installato."
                     : "\(inventory.unavailableDevices.count) dispositivi non disponibili. Con la manutenzione abilitata nelle Impostazioni possono essere rimossi con `xcrun simctl delete unavailable`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.hasScanned ? "simctl non disponibile (serve Xcode)." : "In attesa della scansione.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rows(_ inventory: SimulatorInventory) -> [Row] {
        let devicesPath = model.policy.url(relative: "Library/Developer/CoreSimulator/Devices").path
        let sizes = Dictionary(uniqueKeysWithValues: (model.measurements[devicesPath]?.children ?? []).map { ($0.name, $0.allocatedBytes) })
        return inventory.devices
            .map { Row(id: $0.udid, name: $0.name, runtime: $0.runtimeName, state: $0.state, available: $0.isAvailable, bytes: sizes[$0.udid]) }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }
}

private struct PnpmCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionCard("pnpm", symbol: "cube.box", tint: .yellow) {
            NavigationLink("Dettagli", value: CategoryID.pnpmStore)
                .buttonStyle(.link)
        } content: {
            switch model.pnpmStatus {
            case .available(let tool):
                Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xxs) {
                    MetricRow(label: "Versione", value: tool.version.description)
                    MetricRow(label: "Eseguibile", value: tool.executable.path.replacingOccurrences(of: model.policy.home.path, with: "~"), valueStyle: .secondary)
                    MetricRow(label: "Store attivo", value: tool.storePath?.path.replacingOccurrences(of: model.policy.home.path, with: "~") ?? "Non determinato", valueStyle: .secondary)
                }
                InlineNotice(text: "Pulizia disponibile solo tramite `pnpm store prune` (pacchetti non referenziati).", style: .success)
            case .unsupported, .notFound, .failed, .unknown:
                InlineNotice(text: model.pnpmStatus.message, style: model.pnpmStatus == .unknown ? .info : .warning)
            }
        }
    }
}

private struct GradleCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cachesPath = model.policy.url(relative: ".gradle/caches").path
        let children = Array((model.measurements[cachesPath]?.children ?? []).prefix(10))
        SectionCard("Gradle", symbol: "shippingbox", tint: .green) {
            NavigationLink("Dettagli", value: CategoryID.gradleCaches)
                .buttonStyle(.link)
        } content: {
            if children.isEmpty {
                Text(model.hasScanned ? "~/.gradle/caches non presente." : "In attesa della scansione.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xxs) {
                    ForEach(children) { child in
                        MetricRow(label: child.name, value: child.allocatedBytes.formattedBytes, valueStyle: child.name.hasPrefix("build-cache") ? .primary : .secondary)
                    }
                }
            }
            Text("Solo `build-cache-1` è rimovibile (procedura documentata). Le altre cache sono ripulite automaticamente da Gradle: le cache per versione inutilizzate da 30 giorni e i file condivisi non più usati.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
