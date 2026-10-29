import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Sicurezza", systemImage: "lock.shield") { SafetySettings() }
            Tab("Analisi", systemImage: "magnifyingglass") { AnalysisSettings() }
            Tab("Policy", systemImage: "list.bullet.rectangle") { PolicyOverview() }
        }
        .frame(width: 620, height: 520)
    }
}

private struct SafetySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Metodo di rimozione", selection: $settings.removalMethod) {
                    ForEach(RemovalMethod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(settings.removalMethod.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Pulizia")
            } footer: {
                Text("All'avvio MacCare è sempre in modalità solo analisi: la pulizia si abilita per la singola sessione dalla sezione Pulizia.")
            }

            Section("Simulatori") {
                Toggle("Consenti `xcrun simctl delete unavailable`", isOn: $settings.allowSimulatorMaintenance)
                Text("Elimina solo i simulatori con runtime non più installato, tramite il comando ufficiale. Runtime, dispositivi disponibili e file di CoreSimulator non vengono mai toccati direttamente.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Registro") {
                LabeledContent("Posizione") {
                    Text(OperationLogger.defaultFileURL().path.replacingOccurrences(of: model.policy.home.path, with: "~"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                Button("Mostra nel Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([OperationLogger.defaultFileURL()])
                }
                Text("Contiene solo metadati operativi (date, percorsi, dimensioni, esiti), mai il contenuto dei file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AnalysisSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Ambito") {
                Toggle("Misura i contenitori di altre app", isOn: $settings.includeOtherAppContainers)
                Text("Include ~/Library/Containers e ~/Library/Group Containers (solo dimensioni). macOS potrebbe chiedere il permesso di accedere ai dati di altre app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper(value: $settings.largeDirectoryThresholdMB, in: 100...20_000, step: 100) {
                    LabeledContent("Soglia directory grandi", value: Int64(settings.largeDirectoryThresholdMB * 1_000_000).formattedBytes)
                }
            }

            Section("Strumenti di sviluppo") {
                Toggle("Usa il PATH della shell di login", isOn: $settings.useLoginShellPath)
                Text("Le app avviate dal Finder non ereditano il PATH del Terminale. Con questa opzione MacCare legge il PATH da zsh/bash (in sola lettura, con timeout) per trovare pnpm e node.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Accesso al disco") {
                Text("MacCare non richiede privilegi di amministratore e non aggira le protezioni di macOS. Alcune cartelle protette dalla privacy possono risultare non leggibili: vengono indicate come «non analizzabili». Se vuoi misurarle, puoi concedere l'Accesso completo al disco a MacCare nelle Impostazioni di Sistema.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Apri Privacy e sicurezza…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.title).font(.callout.weight(.medium))
                        Text("~/\(rule.rootRelativePath)/*")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Allowlist (\(model.policy.rules.count) regole)")
            } footer: {
                Text("Sono rimovibili solo i figli diretti di queste cartelle, mai le cartelle stesse.")
            }
            Section("Aree protette (\(model.policy.protectedAreas.count))") {
                ForEach(model.policy.protectedAreas, id: \.self) { area in
                    LabeledContent {
                        Text(area.reason).foregroundStyle(.secondary)
                    } label: {
                        Text("~/\(area.relativePath)").font(.caption.monospaced())
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
