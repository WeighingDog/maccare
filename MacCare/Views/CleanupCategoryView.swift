import AppKit
import SwiftUI

/// Dettaglio di una categoria: dimensione, stima, descrizione, rischi, azione e percorsi misurati.
struct CleanupCategoryView: View {
    @Environment(AppModel.self) private var model
    let categoryID: CategoryID
    var scrollable = true

    var body: some View {
        if let category = model.category(categoryID) {
            PageContainer(scrollable: scrollable) {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    header(category)
                    summaryGrid(category)
                    HStack(alignment: .top, spacing: Spacing.md) {
                        SectionCard("Descrizione", symbol: "text.alignleft") {
                            Text(category.details)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SectionCard("Rischi", symbol: "exclamationmark.triangle", tint: .orange) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                ForEach(category.risks, id: \.self) { risk in
                                    Label(risk, systemImage: "circle.fill")
                                        .labelStyle(BulletLabelStyle())
                                }
                            }
                        }
                    }
                    ActionCard(category: category)
                    ForEach(category.locations) { location in
                        LocationCard(location: location, category: category)
                    }
                    ScanLimitsCard()
                }
                .pageLayout()
            }
            .navigationTitle(category.title)
        } else {
            ContentUnavailableView("Categoria non trovata", systemImage: "questionmark.folder")
        }
    }

    private func header(_ category: CleanupCategory) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            CategoryIcon(symbol: category.symbol, tint: category.id.tint, size: 56)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(category.title)
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(category.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SafetyBadge(level: category.safety)
        }
    }

    private func summaryGrid(_ category: CleanupCategory) -> some View {
        let size = model.size(of: category)
        let estimate: String = switch model.estimate(for: category) {
        case .bytes(let bytes): bytes.formattedBytes
        case .determinedByTool(let text): text
        case .none: "—"
        }
        let unanalyzable = model.unanalyzableLocations(in: category).count
        return GlassGroup {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.md)], spacing: Spacing.md) {
                StatTile(title: "Dimensione", value: model.hasScanned ? size.formattedBytes : "—", caption: "Spazio allocato, percorsi annidati contati una volta.", symbol: "internaldrive", tint: category.id.tint)
                StatTile(title: "Stima recuperabile", value: estimate, caption: "Solo elementi autorizzati dalla policy.", symbol: "leaf", tint: .green)
                StatTile(title: "Elementi candidati", value: "\(model.plannedRemovals(for: category).count)", caption: "Figli diretti delle radici consentite.", symbol: "square.stack.3d.up", tint: .blue)
                StatTile(title: "Stato analisi", value: unanalyzable == 0 ? "Completa" : "Parziale", caption: unanalyzable == 0 ? "Tutti i percorsi sono leggibili." : "\(unanalyzable) percorsi non leggibili del tutto.", symbol: unanalyzable == 0 ? "checkmark.circle" : "eye.slash", tint: unanalyzable == 0 ? .green : .orange)
            }
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Azione disponibile per la categoria e motivo per cui non lo è.
private struct ActionCard: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory

    var body: some View {
        let availability = model.availability(for: category)
        let blockers = model.knownBlockers(for: category)
        SectionCard("Azione disponibile", symbol: "bolt", tint: .accentColor) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(actionDescription)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = availability.message {
                    InlineNotice(text: message, style: availability == .analysisMode ? .info : .warning)
                }
                if !blockers.isEmpty {
                    InlineNotice(text: "Al momento della scansione erano attivi: \(blockers.joined(separator: ", ")). La pulizia verrà saltata se lo sono ancora.", style: .warning)
                }
                if category.id == .xcodeDerivedData, let custom = model.xcodeCustomDerivedDataLocation {
                    InlineNotice(text: "Xcode usa una posizione personalizzata per DerivedData (\(custom)). MacCare gestisce solo la posizione predefinita.", style: .warning)
                }
                if category.action.isDestructive {
                    HStack {
                        Toggle(isOn: Binding(
                            get: { model.selectedForCleanup.contains(category.id) },
                            set: { _ in model.toggleSelection(category.id) }
                        )) {
                            Text("Includi nella prossima pulizia")
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!model.isSelectable(category))
                        Spacer()
                        Button("Vai a Pulizia") { model.selection = .cleanup }
                            .actionButtonStyle(.secondary)
                    }
                }
            }
        }
    }

    private var actionDescription: String {
        switch category.action {
        case .none(let reason):
            "Nessuna azione: \(reason.lowercased()). MacCare mostra solo le dimensioni."
        case .removeContents:
            "Rimuove i figli diretti delle cartelle autorizzate, dopo una nuova verifica di percorso, regola, collegamenti simbolici, volume e processi in uso. La cartella radice resta al suo posto."
        case .pnpmStorePrune:
            "Esegue il comando ufficiale `pnpm store prune` con la versione di pnpm rilevata. MacCare non cancella file dello store direttamente."
        case .simctlDeleteUnavailable:
            "Esegue il comando ufficiale `xcrun simctl delete unavailable`, che elimina solo i simulatori di runtime non più installati."
        }
    }
}

/// Misura di un percorso con i suoi limiti e le sottocartelle più grandi.
private struct LocationCard: View {
    @Environment(AppModel.self) private var model
    let location: LocationSpec
    let category: CleanupCategory
    @State private var showsAllChildren = false

    var body: some View {
        let measurement = model.measurement(for: location)
        SectionCard(location.title, symbol: symbol, tint: tint) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([location.url])
            } label: {
                Label("Mostra nel Finder", systemImage: "folder")
            }
            .actionButtonStyle(.secondary)
            .controlSize(.small)
            .disabled(measurement?.state == .notFound || measurement == nil)
        } content: {
            Text(location.path.replacingOccurrences(of: model.policy.home.path, with: "~"))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let note = location.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let measurement {
                stateView(measurement)
            } else {
                Text(model.hasScanned ? "Non misurato" : "In attesa della scansione")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        switch location.kind {
        case .protected: "lock.fill"
        case .analysisOnly: "eye"
        case .cleanable: "checkmark.shield"
        }
    }

    private var tint: Color {
        switch location.kind {
        case .protected: .orange
        case .analysisOnly: .secondary
        case .cleanable: .green
        }
    }

    @ViewBuilder
    private func stateView(_ measurement: DirectoryMeasurement) -> some View {
        switch measurement.state {
        case .notFound:
            InlineNotice(text: "Non presente su questo Mac.")
        case .symbolicLink:
            InlineNotice(text: "Il percorso è un collegamento simbolico: non viene seguito né misurato.", style: .warning)
        case .denied(let reason):
            InlineNotice(text: "Accesso negato: \(reason). Valuta l'Accesso completo al disco nelle Impostazioni di Sistema.", style: .warning)
        case .unsupported:
            InlineNotice(text: "Tipo di elemento non supportato.", style: .warning)
        case .measured:
            Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xxs) {
                MetricRow(label: "Spazio allocato", value: measurement.allocatedBytes.formattedBytes)
                MetricRow(label: "Dimensione apparente", value: measurement.logicalBytes.formattedBytes, valueStyle: .secondary)
                MetricRow(label: "File · cartelle", value: "\(measurement.fileCount.formatted()) · \(measurement.directoryCount.formatted())", valueStyle: .secondary)
                if measurement.hardLinkDuplicates > 0 {
                    MetricRow(label: "Hard link contati una volta", value: measurement.hardLinkDuplicates.formatted(), valueStyle: .secondary)
                }
                if measurement.symbolicLinkCount > 0 {
                    MetricRow(label: "Collegamenti simbolici non seguiti", value: measurement.symbolicLinkCount.formatted(), valueStyle: .secondary)
                }
                if measurement.skippedMountPoints > 0 {
                    MetricRow(label: "Punti di mount saltati", value: measurement.skippedMountPoints.formatted(), valueStyle: .secondary)
                }
            }
            if measurement.unreadableCount > 0 {
                InlineNotice(text: "\(measurement.unreadableCount.formatted()) elementi non leggibili: la misura è parziale (per difetto).", style: .warning)
            }
            if !measurement.children.isEmpty {
                childrenList(measurement)
            }
        }
    }

    @ViewBuilder
    private func childrenList(_ measurement: DirectoryMeasurement) -> some View {
        let visible = showsAllChildren ? Array(measurement.children.prefix(200)) : Array(measurement.children.prefix(12))
        let maxSize = max(1, measurement.children.first?.allocatedBytes ?? 1)
        Divider()
        VStack(spacing: Spacing.xs) {
            ForEach(visible) { child in
                let url = location.url.appendingPathComponent(child.name)
                let classification = model.policy.classify(url)
                HStack(spacing: Spacing.sm) {
                    Image(systemName: child.isSymbolicLink ? "link" : (child.isDirectory ? "folder" : "doc"))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(model.displayName(forChild: child.name, of: location))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Spacing.sm)
                    SizeBar(fraction: Double(child.allocatedBytes) / Double(maxSize), tint: category.id.tint)
                        .frame(width: 100)
                    Text(child.allocatedBytes.formattedBytes)
                        .font(.callout)
                        .monospacedDigit()
                        .frame(minWidth: 72, alignment: .trailing)
                    ClassificationBadge(classification: classification)
                        .frame(minWidth: 120, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        if measurement.children.count > 12 {
            Button(showsAllChildren ? "Mostra meno" : "Mostra tutti (\(min(measurement.children.count, 200)))") {
                showsAllChildren.toggle()
            }
            .buttonStyle(.link)
        }
    }
}

/// Limiti documentati della misurazione.
struct ScanLimitsCard: View {
    var body: some View {
        SectionCard("Limiti della misurazione", symbol: "ruler") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Self.limits, id: \.self) { limit in
                    Label(limit, systemImage: "circle.fill")
                        .labelStyle(BulletLabelStyle())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    static let limits = [
        "Lo spazio allocato può differire dalla dimensione apparente per file sparsi e compressi.",
        "I cloni APFS condividono blocchi: lo spazio liberato può essere inferiore a quello misurato.",
        "Gli hard link sono contati una sola volta per cartella principale, non fra cartelle diverse.",
        "I collegamenti simbolici non vengono mai seguiti; i punti di mount di altri volumi sono esclusi.",
        "Gli elementi protetti da macOS (privacy, Accesso completo al disco) possono risultare non leggibili: la misura è allora per difetto.",
        "Le dimensioni di cartelle annidate non vengono sommate due volte nei totali.",
    ]
}
