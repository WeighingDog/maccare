import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Generali", systemImage: "gearshape") { GeneralSettings() }
            Tab("Policy", systemImage: "lock.shield") { PolicyOverview() }
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Pulizia") {
                Picker("Metodo di rimozione", selection: $settings.removalMethod) {
                    ForEach(RemovalMethod.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $settings.allowSimulatorMaintenance) {
                    Text("Elimina simulatori non disponibili")
                    Text("Usa solo `xcrun simctl delete unavailable`.")
                }
            }

            Section("Analisi") {
                Toggle(isOn: $settings.includeOtherAppContainers) {
                    Text("Misura i contenitori di altre app")
                    Text("macOS può chiedere il permesso per ogni app.")
                }
                Toggle(isOn: $settings.useLoginShellPath) {
                    Text("Usa il PATH della shell di login")
                    Text("Serve a trovare pnpm e node.")
                }
                Picker("Soglia cartelle grandi", selection: $settings.largeDirectoryThresholdMB) {
                    ForEach([100, 250, 500, 1_000, 5_000], id: \.self) { mb in
                        Text(Int64(mb * 1_000_000).formattedBytes).tag(mb)
                    }
                }
            }

            Section {
                LabeledContent("Accesso completo al disco") {
                    Button("Apri Impostazioni…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                LabeledContent("Registro attività") {
                    Button("Mostra nel Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([OperationLogger.defaultFileURL()])
                    }
                }
            } header: {
                Text("Permessi e dati")
            } footer: {
                Text("Facoltativo: serve solo a misurare i dati protetti da macOS. Il registro contiene solo metadati, mai il contenuto dei file.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Trasparenza sulla policy: allowlist e aree protette.
private struct PolicyOverview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.policy.rules) { rule in
                    LabeledContent(rule.title) {
                        Text("~/\(rule.rootRelativePath)/*")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Cartelle autorizzate")
            } footer: {
                Text("Si rimuove solo il contenuto di queste cartelle, mai le cartelle stesse.")
            }
            Section("Aree protette") {
                ForEach(model.policy.protectedAreas, id: \.self) { area in
                    LabeledContent {
                        Text(area.reason)
                    } label: {
                        Text("~/\(area.relativePath)").font(.callout.monospaced())
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
