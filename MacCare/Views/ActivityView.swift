import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var confirmsClear = false
    @State private var selection: ActivityEntry.ID?

    enum Filter: String, CaseIterable, Identifiable {
        case all, scans, cleanups, problems

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "Tutte"
            case .scans: "Scansioni"
            case .cleanups: "Pulizie"
            case .problems: "Errori e salti"
            }
        }

        func includes(_ entry: ActivityEntry) -> Bool {
            switch self {
            case .all: true
            case .scans: entry.kind == .scan
            case .cleanups: entry.kind == .cleanup || entry.kind == .command
            case .problems: [.failed, .skipped, .partial].contains(entry.outcome)
            }
        }
    }

    private var entries: [ActivityEntry] {
        model.activity.filter { entry in
            filter.includes(entry) && (searchText.isEmpty
                || entry.title.localizedCaseInsensitiveContains(searchText)
                || entry.detail.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        Group {
            if model.activity.isEmpty {
                ContentUnavailableView {
                    Label("Nessuna attività", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Scansioni e pulizie verranno registrate qui con i loro esiti. Il registro contiene solo metadati operativi.")
                }
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                Table(entries, selection: $selection) {
                    TableColumn("Data") { entry in
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 140)
                    TableColumn("Tipo") { entry in
                        Label(entry.kind.title, systemImage: entry.kind.symbol)
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Esito") { entry in
                        OutcomeLabel(outcome: entry.outcome)
                    }
                    .width(min: 90, ideal: 100)
                    TableColumn("Operazione") { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            if !entry.detail.isEmpty {
                                Text(entry.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .help(entry.detail)
                    }
                    TableColumn("Spazio") { entry in
                        Text(spaceText(entry))
                            .monospacedDigit()
                            .foregroundStyle(entry.freedBytes ?? 0 > 0 ? .primary : .secondary)
                    }
                    .width(min: 80, ideal: 110)
                }
            }
        }
        .navigationTitle("Attività")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Cerca nel registro")
        .toolbar {
            ToolbarItem {
                Picker("Filtro", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem {
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    Label("Cancella registro", systemImage: "trash")
                }
                .disabled(model.activity.isEmpty)
                .help("Cancella lo storico delle operazioni")
            }
        }
        .confirmationDialog("Cancellare il registro delle attività?", isPresented: $confirmsClear) {
            Button("Cancella registro", role: .destructive) { model.clearActivity() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Verranno rimossi solo i metadati delle operazioni registrate da MacCare. Nessun altro file viene toccato.")
        }
    }

    private func spaceText(_ entry: ActivityEntry) -> String {
        if let freed = entry.freedBytes, freed > 0 { return freed.formattedBytes }
        if let trashed = entry.trashedBytes, trashed > 0 { return "\(trashed.formattedBytes) (Cestino)" }
        if let bytes = entry.bytes { return bytes.formattedBytes }
        return "—"
    }
}

private struct OutcomeLabel: View {
    let outcome: ActivityEntry.Outcome

    var body: some View {
        Text(outcome.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: .capsule)
    }

    private var tint: Color {
        switch outcome {
        case .success: .green
        case .partial: .orange
        case .skipped: .secondary
        case .failed: .red
        case .cancelled: .gray
        case .info: .blue
        }
    }
}
