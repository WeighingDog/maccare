import SwiftUI

/// Foglio unico del flusso di pulizia: riepilogo → avanzamento → esito.
struct CleanupFlowSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if case .running(let progress) = model.cleanupPhase {
                CleanupProgressView(progress: progress)
            } else if model.reviewPlan != nil {
                CleanupReviewView()
            } else if let summary = model.lastSummary {
                CleanupSummaryView(summary: summary)
            } else {
                ContentUnavailableView("Nessuna operazione", systemImage: "sparkles")
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 560)
        .interactiveDismissDisabled(model.isCleaning)
    }
}

/// Barra inferiore standard dei fogli: informazioni a sinistra, azioni a destra.
private struct SheetFooter<Leading: View, Actions: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Spacing.sm) {
            leading
            Spacer()
            actions
        }
        .padding(Spacing.lg)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Riepilogo e conferma

private struct CleanupReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsExecution = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Metodo", value: model.reviewPlan?.method.title ?? "—")
                } header: {
                    Text("Riepilogo della pulizia").font(.headline)
                } footer: {
                    Text(model.reviewPlan?.method.explanation ?? "")
                }
                if let plan = model.reviewPlan {
                    ForEach(plan.categories.indices, id: \.self) { index in
                        ReviewSection(plan: plan.categories[index], isConfirmed: confirmation(index))
                    }
                }
            }
            .formStyle(.grouped)

            SheetFooter {
                Text("\(confirmedCount) di \(model.reviewPlan?.categories.count ?? 0) confermate")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } actions: {
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pulisci…", role: .destructive) { confirmsExecution = true }
                    .actionButtonStyle(.primary)
                    .disabled(confirmedCount == 0)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: $confirmsExecution) {
            Button(model.reviewPlan?.method == .deletePermanently ? "Elimina definitivamente" : "Sposta nel Cestino", role: .destructive) {
                model.executeReviewedPlan()
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private func confirmation(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { model.reviewPlan?.categories[safe: index]?.isConfirmed ?? false },
            set: { value in
                guard model.reviewPlan?.categories.indices.contains(index) == true else { return }
                model.reviewPlan?.categories[index].isConfirmed = value
            }
        )
    }

    private var confirmedCount: Int { model.reviewPlan?.confirmedCategories.count ?? 0 }

    private var confirmationTitle: String {
        "Pulire \(confirmedCount) \(confirmedCount == 1 ? "categoria" : "categorie")?"
    }

    private var confirmationMessage: String {
        guard let plan = model.reviewPlan else { return "" }
        let estimate = plan.confirmedCategories.compactMap(\.estimatedBytes).reduce(0, +)
        var text = "Circa \(estimate.formattedBytes). "
        text += plan.method == .deletePermanently ? "L'operazione non può essere annullata." : "Gli elementi resteranno nel Cestino."
        let skipped = plan.categories.count - confirmedCount
        if skipped > 0 { text += " \(skipped) non confermate verranno saltate." }
        return text
    }
}

private struct ReviewSection: View {
    let plan: CategoryPlan
    @Binding var isConfirmed: Bool

    var body: some View {
        Section {
            switch plan.operation {
            case .removeItems(let items):
                ForEach(items.prefix(5)) { item in
                    LabeledContent {
                        Text(item.estimatedBytes.formattedBytes).monospacedDigit()
                    } label: {
                        Text(item.displayName)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if items.count > 5 {
                    Text("e altri \(items.count - 5) elementi")
                        .foregroundStyle(.secondary)
                }
            case .pnpmStorePrune(let tool):
                LabeledContent("Comando", value: "pnpm store prune")
                LabeledContent("Versione", value: tool.version.description)
            case .simctlDeleteUnavailable(let count):
                LabeledContent("Comando", value: "xcrun simctl delete unavailable")
                LabeledContent("Dispositivi", value: "\(count)")
            }
            Toggle("Confermo", isOn: $isConfirmed)
        } header: {
            HStack {
                Text(plan.title)
                Spacer()
                Text(plan.estimatedBytes?.formattedBytes ?? "stima di pnpm")
                    .monospacedDigit()
            }
        } footer: {
            Text(plan.risks.joined(separator: " "))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Avanzamento

private struct CleanupProgressView: View {
    @Environment(AppModel.self) private var model
    let progress: CleanupProgress

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(progress.categoryTitle.isEmpty ? "Avvio…" : progress.categoryTitle)
                            .font(.headline)
                        ProgressView(value: overallFraction)
                        if !progress.currentItem.isEmpty {
                            Text(progress.currentItem)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    LabeledContent("Categoria", value: "\(min(progress.categoryIndex + 1, progress.categoryCount)) di \(progress.categoryCount)")
                    if progress.itemCount > 1 {
                        LabeledContent("Elemento", value: "\(progress.itemIndex + 1) di \(progress.itemCount)")
                    }
                } header: {
                    Text("Pulizia in corso").font(.headline)
                }
            }
            .formStyle(.grouped)
            SheetFooter {
                EmptyView()
            } actions: {
                Button("Interrompi", role: .cancel) { model.cancelCleanup() }
            }
        }
    }

    private var overallFraction: Double {
        guard progress.categoryCount > 0 else { return 0 }
        let itemPart = progress.itemCount > 0 ? Double(progress.itemIndex) / Double(progress.itemCount) : 0
        return (Double(progress.categoryIndex) + itemPart) / Double(progress.categoryCount)
    }
}

// MARK: - Esito

struct CleanupSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let summary: CleanupSummary

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Spazio liberato", value: summary.freedBytes.formattedBytes)
                    LabeledContent("Spostato nel Cestino", value: summary.trashedBytes.formattedBytes)
                    LabeledContent("Categorie elaborate", value: "\(summary.processedCategories.count)")
                    LabeledContent("Errori", value: "\(summary.errorCount)")
                    LabeledContent("Elementi saltati", value: "\(summary.skippedCount)")
                } header: {
                    Label(summary.errorCount == 0 ? "Pulizia completata" : "Pulizia completata con errori",
                          systemImage: summary.errorCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(summary.errorCount == 0 ? .green : .orange)
                } footer: {
                    if summary.trashedBytes > 0 {
                        Text("Lo spazio degli elementi nel Cestino si libera svuotando il Cestino.")
                    }
                }
                ForEach(summary.outcomes) { outcome in
                    OutcomeSection(outcome: outcome)
                }
            }
            .formStyle(.grouped)
            SheetFooter {
                Text(Duration.seconds(summary.finishedAt.timeIntervalSince(summary.startedAt)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                    .foregroundStyle(.secondary)
            } actions: {
                Button("Fine") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .actionButtonStyle(.primary)
            }
        }
    }
}

private struct OutcomeSection: View {
    let outcome: CategoryOutcome

    var body: some View {
        Section {
            LabeledContent("Esito") {
                Text(outcome.status.title).foregroundStyle(statusTint)
            }
            if outcome.freedBytes > 0 || outcome.trashedBytes > 0 {
                LabeledContent(outcome.freedBytes > 0 ? "Liberato" : "Nel Cestino",
                               value: (outcome.freedBytes > 0 ? outcome.freedBytes : outcome.trashedBytes).formattedBytes)
            }
            if let note = outcome.note {
                Text(note).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !outcome.skipped.isEmpty {
                DisclosureGroup("\(outcome.skipped.count) saltati") {
                    ForEach(outcome.skipped.prefix(50)) { item in
                        LabeledContent(item.name) { Text(item.reason).foregroundStyle(.secondary) }
                    }
                }
            }
            if !outcome.errors.isEmpty {
                DisclosureGroup("\(outcome.errors.count) errori") {
                    ForEach(outcome.errors.prefix(50), id: \.self) { Text($0).foregroundStyle(.red) }
                }
            }
        } header: {
            Text(outcome.title)
        }
    }

    private var statusTint: Color {
        switch outcome.status {
        case .completed: .green
        case .partial: .orange
        case .skipped, .cancelled: .secondary
        case .failed: .red
        }
    }
}
