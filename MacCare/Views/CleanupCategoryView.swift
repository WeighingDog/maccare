import SwiftUI

/// Dettaglio a pagina intera di una categoria.
struct CleanupCategoryView: View {
    @Environment(AppModel.self) private var model
    let categoryID: CategoryID

    var body: some View {
        if let category = model.category(categoryID) {
            CategoryDetailForm(category: category, compact: false)
                .navigationTitle(category.title)
        } else {
            ContentUnavailableView("Categoria non trovata", systemImage: "questionmark.folder")
        }
    }
}

/// Dettaglio di una categoria: misure, azione, rischi e percorsi. `compact` per l'inspector.
struct CategoryDetailForm: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory
    var compact = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: Spacing.sm) {
                    IconTile(symbol: category.symbol, tint: category.id.tint, size: compact ? 32 : 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title).font(compact ? .headline : .title3.weight(.semibold))
                        Text(category.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent("Dimensione", value: model.sizeText(for: category))
                LabeledContent("Recuperabile", value: model.estimateText(for: category))
                LabeledContent("Sicurezza") { SafetyLabel(level: category.safety) }
                LabeledContent("Analisi", value: model.measurementStateText(for: category))
            }

            ActionSection(category: category)

            Section {
                ForEach(category.risks, id: \.self) { risk in
                    Label(risk, systemImage: "exclamationmark.triangle")
                        .symbolRenderingMode(.multicolor)
                }
            } header: {
                Text("Rischi")
            } footer: {
                if !compact {
                    Text(category.details)
                }
            }

            ForEach(visibleLocations) { location in
                LocationSection(location: location, category: category, compact: compact)
            }

            if !compact {
                Section {
                    DisclosureGroup("Limiti della misurazione") {
                        ForEach(Self.limits, id: \.self) { Text($0).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Nella diagnostica le cartelle sono molte: si mostrano le più grandi.
    private var visibleLocations: [LocationSpec] {
        guard category.locations.count > 8 else { return category.locations }
        return Array(category.locations
            .sorted { (model.measurement(for: $0)?.allocatedBytes ?? 0) > (model.measurement(for: $1)?.allocatedBytes ?? 0) }
            .prefix(compact ? 5 : 12))
    }

    static let limits = [
        "Lo spazio allocato può differire dalla dimensione apparente (file sparsi o compressi).",
        "I cloni APFS condividono blocchi: lo spazio liberato può essere inferiore a quello misurato.",
        "Gli hard link sono contati una volta per cartella principale.",
        "I collegamenti simbolici non vengono seguiti; gli altri volumi sono esclusi.",
        "Gli elementi protetti da macOS non sono leggibili: la misura è allora per difetto.",
    ]
}

private struct ActionSection: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory

    var body: some View {
        let availability = model.availability(for: category)
        let blockers = model.knownBlockers(for: category)
        Section("Azione") {
            LabeledContent("Operazione", value: operationText)
            if category.action.isDestructive {
                Toggle("Includi nella prossima pulizia", isOn: Binding(
                    get: { model.selectedForCleanup.contains(category.id) },
                    set: { _ in model.toggleSelection(category.id) }
                ))
                .disabled(!model.isSelectable(category))
            }
            if let message = availability.message, availability != .available {
                StatusText(text: message, style: model.isSelectable(category) ? .neutral : .warning)
            }
            if !blockers.isEmpty {
                StatusText(text: "In uso: \(blockers.joined(separator: ", ")). Gli elementi interessati verranno saltati.", style: .warning)
            }
            if category.id == .xcodeDerivedData, let custom = model.xcodeCustomDerivedDataLocation {
                StatusText(text: "Xcode usa una posizione personalizzata (\(custom)): MacCare gestisce solo quella predefinita.", style: .warning)
            }
        }
    }

    private var operationText: String {
        switch category.action {
        case .none: "Nessuna (solo dimensioni)"
        case .removeContents: "Rimozione dei contenuti autorizzati"
        case .pnpmStorePrune: "pnpm store prune"
        case .simctlDeleteUnavailable: "simctl delete unavailable"
        }
    }
}

private struct LocationSection: View {
    @Environment(AppModel.self) private var model
    let location: LocationSpec
    let category: CleanupCategory
    let compact: Bool
    @State private var showsContents = false

    var body: some View {
        let measurement = model.measurement(for: location)
        Section {
            LabeledContent("Percorso") {
                Text(location.path.abbreviatingHome(model.policy.home))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            if let measurement {
                switch measurement.state {
                case .measured:
                    LabeledContent("Spazio allocato", value: measurement.allocatedBytes.formattedBytes)
                    if !compact {
                        LabeledContent("Dimensione apparente", value: measurement.logicalBytes.formattedBytes)
                        LabeledContent("File", value: measurement.fileCount.formatted())
                    }
                    if measurement.unreadableCount > 0 {
                        StatusText(text: "\(measurement.unreadableCount.formatted()) elementi non leggibili: misura per difetto", style: .warning)
                    }
                    if !measurement.children.isEmpty {
                        DisclosureGroup("Contenuto (\(measurement.children.count))", isExpanded: $showsContents) {
                            ForEach(measurement.children.prefix(compact ? 10 : 40)) { child in
                                ChildRow(child: child, location: location)
                            }
                        }
                    }
                case .notFound:
                    StatusText(text: "Non presente su questo Mac")
                case .symbolicLink:
                    StatusText(text: "Collegamento simbolico: non seguito", style: .warning)
                case .denied:
                    StatusText(text: "Accesso negato da macOS", style: .warning)
                case .unsupported:
                    StatusText(text: "Tipo di elemento non supportato", style: .warning)
                }
            }
        } header: {
            HStack {
                Text(location.title)
                Spacer()
                if location.kind.isProtected {
                    Image(systemName: "lock.fill").foregroundStyle(.orange).help("Protetto")
                }
                if measurement?.state.isMeasured == true {
                    Button("Mostra nel Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([location.url])
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
        } footer: {
            if !compact, let note = location.note {
                Text(note)
            }
        }
    }
}

private struct ChildRow: View {
    @Environment(AppModel.self) private var model
    let child: ChildMeasurement
    let location: LocationSpec

    var body: some View {
        let classification = model.policy.classify(location.url.appendingPathComponent(child.name))
        LabeledContent {
            HStack(spacing: Spacing.sm) {
                Text(child.allocatedBytes.formattedBytes).monospacedDigit()
                Image(systemName: classification.safetyLevel.symbol)
                    .foregroundStyle(classification.tint)
                    .help(classification.title)
                    .accessibilityLabel(classification.title)
            }
        } label: {
            Label(model.displayName(forChild: child.name, of: location),
                  systemImage: child.isSymbolicLink ? "link" : (child.isDirectory ? "folder" : "doc"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
