import SwiftUI

/// Analisi: tabella gerarchica categorie › percorsi, con inspector dei dettagli.
struct AnalysisView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .categories
    @State private var selection: AnalysisRow.ID?
    @State private var sortOrder = [KeyPathComparator(\AnalysisRow.size, order: .reverse)]
    @State private var showsInspector = false

    enum Mode: String, CaseIterable, Identifiable {
        case categories, largeDirectories
        var id: String { rawValue }
        var title: String { self == .categories ? "Categorie" : "Cartelle grandi" }
    }

    var body: some View {
        Group {
            if !model.hasScanned {
                ContentUnavailableView {
                    Label(model.isScanning ? "Analisi in corso" : "Nessun dato", systemImage: "chart.bar.doc.horizontal")
                } description: {
                    Text(model.isScanning ? "\(model.scanProgress.itemsVisited.formatted()) elementi esaminati" : "Avvia un'analisi per misurare le cartelle.")
                } actions: {
                    if !model.isScanning {
                        Button("Analizza") { model.startScan() }
                            .actionButtonStyle(.primary)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    SpaceHeader()
                    Divider()
                    if mode == .categories {
                        categoriesTable
                    } else {
                        LargeDirectoriesTable()
                    }
                }
            }
        }
        .navigationTitle("Spazio")
        .onChange(of: selection) { _, newValue in
            if newValue != nil { showsInspector = true }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Vista", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!model.hasScanned)
            }
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Dettagli", systemImage: "sidebar.trailing")
                }
                .help("Mostra o nascondi i dettagli")
            }
        }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let id = selectedCategoryID, let category = model.category(id) {
                    CategoryDetailForm(category: category, compact: true)
                } else {
                    ContentUnavailableView("Nessuna selezione", systemImage: "sidebar.trailing", description: Text("Seleziona una riga per vederne i dettagli."))
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
    }

    private var selectedCategoryID: CategoryID? {
        guard let selection else { return nil }
        return CategoryID(rawValue: String(selection.split(separator: "/").first ?? ""))
    }

    private var rows: [AnalysisRow] {
        model.categories
            .map { AnalysisRow(category: $0, model: model) }
            .sorted(using: sortOrder)
    }

    private var categoriesTable: some View {
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Nome", value: \.title) { row in
                HStack(spacing: Spacing.xs) {
                    if let symbol = row.symbol {
                        CategorySymbol(symbol: symbol)
                    }
                    Text(row.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.path ?? row.title)
                }
            }
            .width(min: 200, ideal: 250)
            TableColumn("Dimensione", value: \.size) { row in
                Text(row.sizeText).monospacedDigit()
            }
            .width(min: 80, ideal: 100)
            TableColumn("Recuperabile") { row in
                Text(row.recoverableText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Sicurezza", value: \.safety.title) { row in
                SafetyLabel(level: row.safety)
            }
            .width(min: 110, ideal: 130)
            TableColumn("Analisi") { row in
                Text(row.stateText)
                    .foregroundStyle(row.stateIsProblem ? .orange : .secondary)
            }
            .width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: AnalysisRow.ID.self) { ids in
            if let id = ids.first, let categoryID = CategoryID(rawValue: String(id.split(separator: "/").first ?? "")) {
                Button("Apri dettagli") { model.openCategory(categoryID) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let categoryID = CategoryID(rawValue: String(id.split(separator: "/").first ?? "")) {
                model.openCategory(categoryID)
            }
        }
    }
}

/// Barra del disco sopra la tabella, come in Impostazioni › Spazio.
private struct SpaceHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let volume = model.volume {
            let segments = segments(volume)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.name).font(.headline)
                    Spacer()
                    Text("\(volume.usedBytes.formattedBytes) di \(volume.totalBytes.formattedBytes) utilizzati")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                StorageBar(segments: segments, totalBytes: volume.totalBytes)
                StorageLegend(segments: segments)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
        }
    }

    private func segments(_ volume: VolumeSnapshot) -> [StorageBar.Segment] {
        let recoverable = model.recoverableBytes
        let protected = model.protectedBytes
        let other = max(0, model.analyzedBytes - recoverable - protected)
        return [
            .init(id: "recoverable", title: "Recuperabile", bytes: recoverable, color: Palette.recoverable),
            .init(id: "protected", title: "Protetto", bytes: protected, color: Palette.neutralStrong),
            .init(id: "analyzed", title: "Altro analizzato", bytes: other, color: Palette.neutral),
            .init(id: "rest", title: "Non analizzato", bytes: max(0, volume.usedBytes - model.analyzedBytes), color: Palette.neutralWeak),
        ]
    }
}

/// Riga della tabella: una categoria o, come figlio, uno dei suoi percorsi.
struct AnalysisRow: Identifiable, Hashable {
    let id: String
    let categoryID: CategoryID
    let title: String
    let symbol: String?
    let path: String?
    let size: Int64
    let sizeText: String
    let recoverableText: String
    let safety: SafetyLevel
    let stateText: String
    let stateIsProblem: Bool
    var children: [AnalysisRow]?

    @MainActor
    init(category: CleanupCategory, model: AppModel) {
        id = category.id.rawValue
        categoryID = category.id
        title = category.title
        symbol = category.symbol
        path = nil
        size = model.size(of: category)
        sizeText = model.sizeText(for: category)
        recoverableText = model.estimateText(for: category)
        safety = category.safety
        stateText = model.measurementStateText(for: category)
        stateIsProblem = stateText == "Parziale" || stateText == "Accesso negato"
        let locations = category.locations.filter { model.measurement(for: $0)?.state != .notFound }
        children = locations.count > 1 ? locations
            .map { AnalysisRow(location: $0, category: category, model: model) }
            .sorted { $0.size > $1.size } : nil
    }

    @MainActor
    private init(location: LocationSpec, category: CleanupCategory, model: AppModel) {
        let measurement = model.measurement(for: location)
        id = "\(category.id.rawValue)/\(location.id)"
        categoryID = category.id
        title = location.title
        symbol = nil
        path = location.path.abbreviatingHome(model.policy.home)
        size = measurement?.state.isMeasured == true ? measurement?.allocatedBytes ?? 0 : 0
        switch measurement?.state {
        case .measured?: sizeText = size.formattedBytes
        case .denied?: sizeText = "—"
        default: sizeText = "—"
        }
        if let ruleID = location.kind.ruleID, measurement?.state.isMeasured == true {
            let bytes = model.plannedRemovals(for: category).filter { $0.ruleID == ruleID }.reduce(0) { $0 + $1.estimatedBytes }
            recoverableText = bytes.formattedBytes
        } else {
            recoverableText = "—"
        }
        safety = location.kind.isProtected ? .protected : (location.kind.ruleID != nil ? category.safety : .analysisOnly)
        switch measurement?.state {
        case .denied?:
            stateText = "Accesso negato"
            stateIsProblem = true
        case .symbolicLink?:
            stateText = "Link non seguito"
            stateIsProblem = false
        case .measured? where measurement?.isPartial == true:
            stateText = "Parziale"
            stateIsProblem = true
        case .measured?:
            stateText = "Completa"
            stateIsProblem = false
        default:
            stateText = "—"
            stateIsProblem = false
        }
        children = nil
    }
}

/// Cartelle più grandi trovate in tutte le scomposizioni (solo diagnostica).
private struct LargeDirectoriesTable: View {
    @Environment(AppModel.self) private var model
    @State private var selection: LargeDirectory.ID?

    var body: some View {
        let items = model.largeDirectories(limit: 200)
        if items.isEmpty {
            ContentUnavailableView("Nessuna cartella sopra la soglia", systemImage: "folder", description: Text("La soglia si cambia nelle Impostazioni."))
        } else {
            Table(items, selection: $selection) {
                TableColumn("Nome") { item in
                    Label(item.name, systemImage: "folder")
                        .lineLimit(1)
                        .help(item.path)
                }
                .width(min: 180, ideal: 260)
                TableColumn("Dimensione") { item in
                    Text(item.allocatedBytes.formattedBytes).monospacedDigit()
                }
                .width(min: 80, ideal: 100)
                TableColumn("Policy") { item in
                    ClassificationLabel(classification: item.classification)
                }
                .width(min: 110, ideal: 140)
                TableColumn("Percorso") { item in
                    Text(item.path.abbreviatingHome(model.policy.home))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: LargeDirectory.ID.self) { ids in
                if let path = ids.first {
                    Button("Mostra nel Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            }
        }
    }
}
