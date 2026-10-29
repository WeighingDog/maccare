import Charts
import SwiftUI

struct StorageDashboardView: View {
    @Environment(AppModel.self) private var model
    var scrollable = true

    var body: some View {
        PageContainer(scrollable: scrollable) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                PageHeader("Panoramica", subtitle: subtitle)

                if model.isScanning {
                    ScanProgressCard()
                        .transition(.opacity)
                } else if !model.hasScanned {
                    FirstScanCard()
                }

                if case .failed(let message) = model.scanPhase {
                    InlineNotice(text: "Scansione non riuscita: \(message)", style: .error)
                } else if model.scanPhase == .cancelled {
                    InlineNotice(text: "Scansione annullata. I dati mostrati provengono dall'ultima scansione completata.", style: .warning)
                }

                if let volume = model.volume {
                    VolumeCard(volume: volume)
                }

                if model.hasScanned {
                    MetricsGrid()
                    DistributionCard()
                    TopCategoriesCard()
                }
            }
            .pageLayout()
            .animation(.default, value: model.scanPhase)
        }
        .navigationTitle("Panoramica")
    }

    private var subtitle: String {
        if let date = model.lastScanDate {
            return "Ultima scansione \(date.relativeDescription)"
        }
        return "Analisi dello spazio su disco"
    }
}

/// Stato vuoto iniziale: nessun valore storico, solo l'invito alla prima scansione.
private struct FirstScanCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "internaldrive")
                .font(.system(size: 44, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: Spacing.xxs) {
                Text("Nessuna scansione eseguita")
                    .font(.title2.weight(.semibold))
                Text("MacCare calcola le dimensioni reali di questo Mac in sola lettura. Nessun file viene modificato durante l'analisi.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button {
                model.startScan()
            } label: {
                Label("Avvia scansione", systemImage: "magnifyingglass")
                    .padding(.horizontal, Spacing.xs)
            }
            .actionButtonStyle(.primary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.xxl)
        .glassSurface(tint: .accentColor)
    }
}

private struct VolumeCard: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeSnapshot

    private var segments: [UsageBar.Segment] {
        let protected = model.protectedBytes
        let recoverable = model.recoverableBytes
        let analyzedOther = max(0, model.analyzedBytes - protected - recoverable)
        let otherUsed = max(0, volume.usedBytes - model.analyzedBytes)
        return [
            .init(id: "recoverable", title: "Potenzialmente recuperabile", bytes: model.hasScanned ? recoverable : 0, color: .green),
            .init(id: "protected", title: "Dati protetti analizzati", bytes: model.hasScanned ? protected : 0, color: .orange),
            .init(id: "analyzed", title: "Altro analizzato", bytes: model.hasScanned ? analyzedOther : 0, color: .blue),
            .init(id: "other", title: model.hasScanned ? "Non analizzato" : "Utilizzato", bytes: model.hasScanned ? otherUsed : volume.usedBytes, color: .gray),
        ]
    }

    var body: some View {
        SectionCard(volume.name, symbol: "internaldrive", tint: .accentColor) {
            Text("\(volume.totalBytes.formattedBytes) totali")
                .font(.callout)
                .foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: Spacing.md) {
                UsageBar(segments: segments + [.init(id: "free", title: "Disponibile", bytes: volume.availableBytes, color: Color(nsColor: .tertiaryLabelColor).opacity(0.25))])

                Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xs) {
                    GridRow {
                        legend("Utilizzato", volume.usedBytes, color: .primary)
                        legend("Disponibile", volume.availableBytes, color: .secondary)
                        if volume.purgeableBytes > 0 {
                            legend("di cui eliminabile da macOS", volume.purgeableBytes, color: .secondary)
                        }
                    }
                }

                if model.hasScanned {
                    Divider()
                    HStack(spacing: Spacing.lg) {
                        ForEach(segments.filter { $0.bytes > 0 }) { segment in
                            HStack(spacing: Spacing.xs) {
                                Circle().fill(segment.color).frame(width: 8, height: 8).accessibilityHidden(true)
                                Text(segment.title).foregroundStyle(.secondary)
                                Text(segment.bytes.formattedBytes).monospacedDigit()
                            }
                            .font(.caption)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    private func legend(_ title: String, _ bytes: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(bytes.formattedBytes)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Le sei misure distinte richieste: occupato, recuperabile, recuperato, protetto, non analizzabile, in attesa.
private struct MetricsGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassGroup {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Spacing.md)], spacing: Spacing.md) {
                StatTile(
                    title: "Spazio analizzato",
                    value: model.analyzedBytes.formattedBytes,
                    caption: "Occupato dalle cartelle esaminate, senza doppi conteggi.",
                    symbol: "chart.pie",
                    tint: .blue
                )
                StatTile(
                    title: "Potenzialmente recuperabile",
                    value: model.recoverableBytes.formattedBytes,
                    caption: "Stima delle sole categorie autorizzate. Non è garantito.",
                    symbol: "leaf",
                    tint: .green
                )
                StatTile(
                    title: "Recuperato",
                    value: model.sessionFreedBytes.formattedBytes,
                    caption: recoveredCaption,
                    symbol: "checkmark.seal",
                    tint: .mint
                )
                StatTile(
                    title: "Dati protetti",
                    value: model.protectedBytes.formattedBytes,
                    caption: "Misurati ma mai modificati (WhatsApp, archivi, SDK…).",
                    symbol: "lock.shield",
                    tint: .orange
                )
                StatTile(
                    title: "Non analizzabili",
                    value: "\(model.unanalyzableCount)",
                    caption: model.unanalyzableCount == 0 ? "Tutti i percorsi sono stati letti." : "Percorsi con accesso negato o letti in parte.",
                    symbol: "eye.slash",
                    tint: .gray
                )
                StatTile(
                    title: "In attesa di conferma",
                    value: "\(model.pendingConfirmationCount)",
                    caption: "Categorie selezionate per la pulizia non ancora confermate.",
                    symbol: "hourglass",
                    tint: .yellow
                )
            }
        }
    }

    private var recoveredCaption: String {
        var parts = ["In questa sessione"]
        if model.sessionTrashedBytes > 0 { parts.append("\(model.sessionTrashedBytes.formattedBytes) nel Cestino") }
        if model.allTimeFreedBytes > 0 { parts.append("\(model.allTimeFreedBytes.formattedBytes) dall'inizio") }
        return parts.joined(separator: " · ")
    }
}

/// Distribuzione dello spazio analizzato fra le cartelle principali (non sovrapposte).
private struct DistributionCard: View {
    @Environment(AppModel.self) private var model

    struct Slice: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let color: Color
    }

    private var slices: [Slice] {
        var titleForPath: [String: (String, Color)] = [:]
        for category in model.categories {
            for location in category.locations where titleForPath[location.path] == nil {
                titleForPath[location.path] = (location.title, category.id.tint)
            }
        }
        let maximal = StorageMath.maximalPaths(Array(titleForPath.keys).filter { model.measurements[$0]?.state.isMeasured == true })
        let sorted = maximal
            .compactMap { path -> Slice? in
                guard let bytes = model.measurements[path]?.allocatedBytes, bytes > 0, let info = titleForPath[path] else { return nil }
                return Slice(id: path, title: info.0, bytes: bytes, color: info.1)
            }
            .sorted { $0.bytes > $1.bytes }
        guard sorted.count > 7 else { return sorted }
        let rest = sorted.dropFirst(7).reduce(0) { $0 + $1.bytes }
        return Array(sorted.prefix(7)) + [Slice(id: "other", title: "Altre cartelle", bytes: rest, color: .gray)]
    }

    var body: some View {
        let data = slices
        SectionCard("Distribuzione dello spazio analizzato", symbol: "chart.pie", tint: .accentColor) {
            HStack(alignment: .center, spacing: Spacing.xl) {
                Chart(data) { slice in
                    SectorMark(
                        angle: .value("Spazio", slice.bytes),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5
                    )
                    .cornerRadius(4)
                    .foregroundStyle(slice.color.gradient)
                    .accessibilityLabel(slice.title)
                    .accessibilityValue(slice.bytes.formattedBytes)
                }
                .chartLegend(.hidden)
                .frame(width: 180, height: 180)
                .overlay {
                    VStack(spacing: 0) {
                        Text(model.analyzedBytes.formattedBytes)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text("analizzati")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                }

                Grid(alignment: .leading, horizontalSpacing: Spacing.md, verticalSpacing: Spacing.xs) {
                    ForEach(data) { slice in
                        GridRow {
                            Circle().fill(slice.color).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(slice.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(slice.bytes.formattedBytes)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text("Le cartelle annidate (es. DerivedData dentro ~/Library/Developer) sono conteggiate una sola volta.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TopCategoriesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let actionable = model.actionableCategories.sorted { model.size(of: $0) > model.size(of: $1) }
        let maxSize = max(1, actionable.map { model.size(of: $0) }.max() ?? 1)
        SectionCard("Categorie di pulizia", symbol: "sparkles", tint: .green) {
            Button("Vai a Pulizia") { model.selection = .cleanup }
                .actionButtonStyle(.secondary)
                .controlSize(.small)
        } content: {
            VStack(spacing: Spacing.xxs) {
                ForEach(actionable) { category in
                    NavigationLink(value: category.id) {
                        CategoryRow(category: category, maxSize: maxSize)
                    }
                    .buttonStyle(.plain)
                    if category.id != actionable.last?.id { Divider() }
                }
            }
        }
    }
}

/// Riga di categoria: icona, titolo, dimensione, stima e livello di sicurezza.
struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory
    var maxSize: Int64 = 1

    var body: some View {
        let size = model.size(of: category)
        HStack(spacing: Spacing.sm) {
            CategoryIcon(symbol: category.symbol, tint: category.id.tint)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(category.title).font(.body.weight(.medium))
                    if model.isPartiallyMeasured(category) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .help("Alcuni elementi non sono leggibili: la misura è parziale.")
                            .accessibilityLabel("Misura parziale")
                    }
                }
                Text(category.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                SizeBar(fraction: Double(size) / Double(maxSize), tint: category.id.tint)
                    .frame(maxWidth: 260)
            }
            Spacer(minLength: Spacing.sm)
            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                Text(size.formattedBytes)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text(estimateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SafetyBadge(level: category.safety, compact: true)
                .frame(minWidth: 120, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Apre il dettaglio della categoria")
    }

    private var estimateText: String {
        switch model.estimate(for: category) {
        case .bytes(let bytes): "Stima: \(bytes.formattedBytes)"
        case .determinedByTool(let text): text
        case .none: category.action.isDestructive ? "Solo analisi" : "Nessuna azione"
        }
    }
}
