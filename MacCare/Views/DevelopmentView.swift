import SwiftUI

/// Ambiente di sviluppo: strumenti attivi, Xcode, simulatori, pnpm, Gradle, Android.
struct DevelopmentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.isScanning {
                Section { ScanProgressRow() }
            } else if !model.hasScanned {
                Section {
                    StatusText(text: "Avvia un'analisi per misurare gli strumenti di sviluppo.")
                }
            }
            categorySection("Xcode", [.xcodeDerivedData, .xcodeArchives, .libraryDeveloper], extra: "diag.deviceSupport")
            SimulatorsSection()
            PnpmSection()
            GradleSection()
            categorySection("Android", [.android])
            RunningToolsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Sviluppo")
    }

    private func categorySection(_ title: String, _ ids: [CategoryID], extra locationID: String? = nil) -> some View {
        Section(title) {
            ForEach(ids, id: \.self) { id in
                if let category = model.category(id) {
                    CategoryLinkRow(category: category)
                }
            }
            if let locationID, let location = model.categories.flatMap(\.locations).first(where: { $0.id == locationID }) {
                LabeledContent {
                    SizeText(bytes: model.measurement(for: location)?.state.isMeasured == true ? model.measurement(for: location)?.allocatedBytes : nil)
                } label: {
                    CategoryLabel(title: location.title, subtitle: "Solo analisi · gestibile da Xcode", symbol: "iphone.and.arrow.forward")
                }
            }
        }
    }
}

/// Riga che apre il dettaglio di una categoria, con dimensione a destra.
struct CategoryLinkRow: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory

    var body: some View {
        NavigationLink(value: category.id) {
            LabeledContent {
                Text(model.sizeText(for: category))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } label: {
                let status = model.statusLine(for: category)
                CategoryLabel(title: category.title, subtitle: status.text, symbol: category.symbol, subtitleStyle: status.color)
            }
        }
    }
}

/// Strumenti attivi in una sola riga: le pulizie che ne dipendono vengono saltate.
private struct RunningToolsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let snapshot = model.runningSnapshot {
            let active = activeTools(snapshot)
            Section {
                LabeledContent("Strumenti attivi") {
                    Text(snapshot.isReliable ? (active.isEmpty ? "Nessuno" : active.joined(separator: ", ")) : "Non verificabile")
                        .foregroundStyle(active.isEmpty && snapshot.isReliable ? Color.secondary : Color.orange)
                }
            } footer: {
                Text("Rilevati \(snapshot.takenAt.relativeDescription). Le pulizie che dipendono da uno strumento attivo vengono saltate.")
            }
        }
    }

    private func activeTools(_ snapshot: RunningSoftwareSnapshot) -> [String] {
        var tools: [String] = []
        if snapshot.bundleIdentifiers.contains("com.apple.dt.Xcode") { tools.append("Xcode") }
        if !snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.xcodeBuildProcesses).isEmpty { tools.append("build Xcode") }
        if snapshot.bundleIdentifiers.contains("com.apple.iphonesimulator") { tools.append("Simulator") }
        if !snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.gradleProcesses).isEmpty { tools.append("Gradle") }
        if snapshot.bundleIdentifiers.contains(where: { $0.hasPrefix("com.google.android.studio") }) { tools.append("Android Studio") }
        if !snapshot.blockers(bundleIDs: [], processes: SafetyPolicy.pnpmProcesses).isEmpty { tools.append("pnpm") }
        return tools
    }
}

private struct SimulatorsSection: View {
    @Environment(AppModel.self) private var model
    @State private var showsAll = false

    var body: some View {
        Section {
            if let category = model.category(.simulators) {
                CategoryLinkRow(category: category)
            }
            if let inventory = model.simulatorInventory {
                let devices = sortedDevices(inventory)
                ForEach(showsAll ? devices : Array(devices.prefix(6)), id: \.device.udid) { entry in
                    LabeledContent {
                        SizeText(bytes: entry.bytes)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.device.name)
                            Text(entry.device.isAvailable ? entry.device.runtimeName : "\(entry.device.runtimeName) · non disponibile")
                                .font(.callout)
                                .foregroundStyle(entry.device.isAvailable ? Color.secondary : Color.orange)
                        }
                    }
                }
                if devices.count > 6 {
                    Button(showsAll ? "Mostra meno" : "Mostra tutti i \(devices.count) dispositivi") { showsAll.toggle() }
                        .buttonStyle(.link)
                }
            } else if model.hasScanned {
                StatusText(text: "simctl non disponibile: serve Xcode.")
            }
        } header: {
            Text("Simulatori")
        } footer: {
            if let inventory = model.simulatorInventory, !inventory.unavailableDevices.isEmpty {
                Text("\(inventory.unavailableDevices.count) dispositivi non disponibili: puoi abilitare `simctl delete unavailable` nelle Impostazioni.")
            }
        }
    }

    private func sortedDevices(_ inventory: SimulatorInventory) -> [(device: SimulatorDevice, bytes: Int64?)] {
        let path = model.policy.url(relative: "Library/Developer/CoreSimulator/Devices").path
        let sizes = Dictionary(uniqueKeysWithValues: (model.measurements[path]?.children ?? []).map { ($0.name, $0.allocatedBytes) })
        return inventory.devices
            .map { (device: $0, bytes: sizes[$0.udid]) }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }
}

private struct PnpmSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("pnpm") {
            if let category = model.category(.pnpmStore) {
                CategoryLinkRow(category: category)
            }
            switch model.pnpmStatus {
            case .available(let tool):
                LabeledContent("Versione", value: tool.version.description)
                LabeledContent("Eseguibile") {
                    Text(tool.executable.path.abbreviatingHome(model.policy.home)).font(.callout.monospaced())
                }
                LabeledContent("Store attivo") {
                    Text(tool.storePath?.path.abbreviatingHome(model.policy.home) ?? "Non determinato").font(.callout.monospaced())
                }
            case .unknown:
                EmptyView()
            default:
                StatusText(text: model.pnpmStatus.message, style: .warning)
            }
        }
    }
}

private struct GradleSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cachesPath = model.policy.url(relative: ".gradle/caches").path
        let children = Array((model.measurements[cachesPath]?.children ?? []).prefix(6))
        Section {
            if let category = model.category(.gradleCaches) {
                CategoryLinkRow(category: category)
            }
            ForEach(children) { child in
                LabeledContent {
                    SizeText(bytes: child.allocatedBytes)
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Text("caches/\(child.name)").font(.callout.monospaced())
                        if child.name.hasPrefix("build-cache") {
                            Image(systemName: "checkmark.shield").foregroundStyle(.green).help("Rimovibile")
                        }
                    }
                }
            }
        } header: {
            Text("Gradle")
        } footer: {
            Text("Solo build-cache-1 è rimovibile; il resto lo pulisce Gradle automaticamente.")
        }
    }
}
