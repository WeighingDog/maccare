import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsEnable = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.cleanupEnabledThisSession },
                    set: { enabled in
                        if enabled { confirmsEnable = true } else { model.disableCleanupForSession() }
                    }
                )) {
                    Text("Consenti la pulizia in questa sessione")
                    Text("Al prossimo avvio MacCare torna in sola analisi.")
                }
                .disabled(!model.hasScanned || model.isCleaning)
                Picker("Metodo", selection: $settings.removalMethod) {
                    ForEach(RemovalMethod.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.cleanupEnabledThisSession)
            } footer: {
                if !model.hasScanned {
                    Text("Esegui prima un'analisi.")
                }
            }

            Section("Categorie") {
                ForEach(model.actionableCategories) { category in
                    CleanupRow(category: category)
                }
            }

            if let summary = model.lastSummary {
                Section("Ultima pulizia") {
                    LabeledContent("Liberato", value: summary.freedBytes.formattedBytes)
                    if summary.trashedBytes > 0 {
                        LabeledContent("Nel Cestino", value: summary.trashedBytes.formattedBytes)
                    }
                    LabeledContent("Errori · saltati", value: "\(summary.errorCount) · \(summary.skippedCount)")
                    Button("Mostra riepilogo…") { model.showsCleanupFlow = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Pulizia")
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .confirmationDialog("Consentire la pulizia in questa sessione?", isPresented: $confirmsEnable) {
            Button("Consenti") { model.enableCleanupForSession() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Prima di ogni operazione vedrai un riepilogo e dovrai confermare ogni categoria.")
        }
    }

    private var selectedEstimate: Int64 {
        model.actionableCategories
            .filter { model.selectedForCleanup.contains($0.id) }
            .compactMap { model.estimate(for: $0).bytes }
            .reduce(0, +)
    }

    private var actionBar: some View {
        let count = model.selectedForCleanup.count
        return HStack(spacing: Spacing.md) {
            Text(count == 0 ? "Nessuna categoria selezionata" : "\(count) selezionate · circa \(selectedEstimate.formattedBytes)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Rivedi e pulisci…") { model.prepareReview() }
                .actionButtonStyle(.primary)
                .controlSize(.large)
                .disabled(count == 0 || !model.cleanupEnabledThisSession || model.isScanning || model.isCleaning)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Riga categoria: icona, stato in una riga, stima e interruttore di selezione.
private struct CleanupRow: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory

    var body: some View {
        let status = model.statusLine(for: category)
        HStack(spacing: Spacing.sm) {
            CategoryLabel(title: category.title, subtitle: status.text, symbol: category.symbol, tint: category.id.tint, subtitleStyle: status.color)
            Spacer()
            Text(model.estimateText(for: category))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                model.openCategory(category.id)
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Dettagli di \(category.title)")
            .accessibilityLabel("Dettagli di \(category.title)")
            Toggle("Seleziona \(category.title)", isOn: Binding(
                get: { model.selectedForCleanup.contains(category.id) },
                set: { _ in model.toggleSelection(category.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!model.cleanupEnabledThisSession || !model.isSelectable(category) || model.isCleaning)
        }
    }
}
