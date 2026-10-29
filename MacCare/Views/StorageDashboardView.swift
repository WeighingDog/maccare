import SwiftUI

/// Panoramica: disco, riepilogo delle sei misure e consigli di pulizia.
struct StorageDashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                VolumeRow()
            }

            if model.isScanning {
                Section { ScanProgressRow() }
            } else if !model.hasScanned {
                Section {
                    FirstScanRow()
                }
            }

            if case .failed(let message) = model.scanPhase {
                Section { StatusText(text: "Analisi non riuscita: \(message)", style: .error) }
            } else if model.scanPhase == .cancelled {
                Section { StatusText(text: "Analisi interrotta: i dati sono quelli dell'ultima analisi completa.", style: .warning) }
            }

            if model.hasScanned {
                SummarySection()
                RecommendationsSection()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Panoramica")
        .navigationSubtitle(model.lastScanDate.map { "Analizzato \($0.relativeDescription)" } ?? "")
    }
}

private struct VolumeRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let volume = model.volume {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.name).font(.headline)
                    Spacer()
                    Text("\(volume.usedBytes.formattedBytes) di \(volume.totalBytes.formattedBytes) utilizzati")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                StorageBar(segments: segments(volume), totalBytes: volume.totalBytes)
                StorageLegend(segments: segments(volume))
            }
            .padding(.vertical, Spacing.xxs)
        }
    }

    private func segments(_ volume: VolumeSnapshot) -> [StorageBar.Segment] {
        guard model.hasScanned else {
            return [.init(id: "used", title: "Utilizzato", bytes: volume.usedBytes, color: .gray)]
        }
        let recoverable = model.recoverableBytes
        let protected = model.protectedBytes
        let other = max(0, model.analyzedBytes - recoverable - protected)
        return [
            .init(id: "recoverable", title: "Recuperabile", bytes: recoverable, color: .green),
            .init(id: "protected", title: "Protetto", bytes: protected, color: .orange),
            .init(id: "analyzed", title: "Altro analizzato", bytes: other, color: .blue),
            .init(id: "rest", title: "Non analizzato", bytes: max(0, volume.usedBytes - model.analyzedBytes), color: .gray),
        ]
    }
}

private struct FirstScanRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nessuna analisi")
                Text("L'analisi legge solo le dimensioni: nessun file viene modificato.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Analizza") { model.startScan() }
                .actionButtonStyle(.primary)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Le sei misure richieste, ciascuna su una riga.
private struct SummarySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Riepilogo") {
            row("Spazio analizzato", "chart.pie.fill", .blue, model.analyzedBytes.formattedBytes)
            row("Potenzialmente recuperabile", "leaf.fill", .green, model.recoverableBytes.formattedBytes)
            row("Recuperato in questa sessione", "checkmark.seal.fill", .mint, recoveredText)
            row("Dati protetti", "lock.fill", .orange, model.protectedBytes.formattedBytes)
            NavigationLink {
                UnanalyzableList()
            } label: {
                LabeledContent {
                    Text("\(model.unanalyzableCount)").monospacedDigit()
                } label: {
                    CategoryLabel(title: "Non analizzabili", subtitle: nil, symbol: "eye.slash.fill", tint: .gray)
                }
            }
            .disabled(model.unanalyzableCount == 0)
            Button {
                model.selection = .cleanup
            } label: {
                LabeledContent {
                    Text("\(model.pendingConfirmationCount)").monospacedDigit()
                } label: {
                    CategoryLabel(title: "In attesa di conferma", subtitle: nil, symbol: "hourglass", tint: .yellow)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var recoveredText: String {
        var text = model.sessionFreedBytes.formattedBytes
        if model.sessionTrashedBytes > 0 { text += " · \(model.sessionTrashedBytes.formattedBytes) nel Cestino" }
        return text
    }

    private func row(_ title: String, _ symbol: String, _ tint: Color, _ value: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            CategoryLabel(title: title, subtitle: nil, symbol: symbol, tint: tint)
        }
    }
}

/// Categorie con un'azione, ordinate per stima: come i "Consigli" di Impostazioni › Spazio.
private struct RecommendationsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let categories = model.actionableCategories.sorted {
            (model.estimate(for: $0).bytes ?? 0) > (model.estimate(for: $1).bytes ?? 0)
        }
        Section("Consigli") {
            ForEach(categories) { category in
                NavigationLink(value: category.id) {
                    LabeledContent {
                        Text(model.estimateText(for: category)).monospacedDigit()
                    } label: {
                        let status = model.statusLine(for: category)
                        CategoryLabel(title: category.title, subtitle: status.text, symbol: category.symbol, tint: category.id.tint, subtitleStyle: status.color)
                    }
                }
            }
        }
    }
}

/// Percorsi con accesso negato o letti in parte.
struct UnanalyzableList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.categories) { category in
                    ForEach(model.unanalyzableLocations(in: category)) { location in
                        LabeledContent {
                            Text(stateText(location))
                                .foregroundStyle(.orange)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.title)
                                Text(location.path.abbreviatingHome(model.policy.home))
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            } footer: {
                Text("macOS protegge alcuni dati (privacy, dati di altre app). Per misurarli puoi concedere a MacCare l'Accesso completo al disco nelle Impostazioni di Sistema.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Non analizzabili")
    }

    private func stateText(_ location: LocationSpec) -> String {
        guard let measurement = model.measurement(for: location) else { return "—" }
        if case .denied = measurement.state { return "Accesso negato" }
        return "\(measurement.unreadableCount.formatted()) elementi non leggibili"
    }
}
