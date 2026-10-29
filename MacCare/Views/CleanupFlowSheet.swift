import SwiftUI

/// Foglio unico del flusso di pulizia: riepilogo → avanzamento → esito.
struct CleanupFlowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var scrollable = true

    var body: some View {
        Group {
            if case .running(let progress) = model.cleanupPhase {
                CleanupProgressView(progress: progress)
            } else if model.reviewPlan != nil {
                CleanupReviewView(scrollable: scrollable)
            } else if let summary = model.lastSummary {
                CleanupSummaryView(summary: summary)
            } else {
                ContentUnavailableView("Nessuna operazione", systemImage: "sparkles")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
                    }
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 640)
        .interactiveDismissDisabled(model.isCleaning)
    }
}

// MARK: - Riepilogo e conferma

private struct CleanupReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsExecution = false
    var scrollable = true

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PageContainer(scrollable: scrollable) {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Riepilogo della pulizia")
                            .font(.title.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Conferma esplicitamente ogni categoria. Le categorie non confermate verranno saltate.")
                            .foregroundStyle(.secondary)
                    }
                    if let plan = model.reviewPlan {
                        InlineNotice(text: "Metodo: \(plan.method.title). \(plan.method.explanation)", style: plan.method == .deletePermanently ? .warning : .info)
                        InlineNotice(text: "Prima di ogni elemento MacCare ricontrolla percorso, regola, collegamenti simbolici, volume e processi in uso: in caso di dubbio l'elemento viene saltato.")
                    }
                    if let plan = model.reviewPlan {
                        ForEach(plan.categories.indices, id: \.self) { index in
                            if let binding = confirmationBinding(index) {
                                ReviewCategoryCard(plan: plan.categories[index], isConfirmed: binding)
                            }
                        }
                    }
                }
                .padding(Spacing.xl)
            }
            Divider()
            footer
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

    private func confirmationBinding(_ index: Int) -> Binding<Bool>? {
        guard let plan = model.reviewPlan, plan.categories.indices.contains(index) else { return nil }
        return Binding(
            get: { model.reviewPlan?.categories[index].isConfirmed ?? false },
            set: { model.reviewPlan?.categories[index].isConfirmed = $0 }
        )
    }

    private var confirmedCount: Int { model.reviewPlan?.confirmedCategories.count ?? 0 }

    private var confirmationTitle: String {
        "Eseguire la pulizia di \(confirmedCount) \(confirmedCount == 1 ? "categoria" : "categorie")?"
    }

    private var confirmationMessage: String {
        guard let plan = model.reviewPlan else { return "" }
        let estimate = plan.confirmedCategories.compactMap(\.estimatedBytes).reduce(0, +)
        var text = "Stima: \(estimate.formattedBytes)."
        text += plan.method == .deletePermanently ? " L'operazione non può essere annullata." : " Potrai recuperare gli elementi dal Cestino."
        let skipped = plan.categories.count - confirmedCount
        if skipped > 0 { text += " \(skipped) categorie non confermate verranno saltate." }
        return text
    }

    private var footer: some View {
        HStack {
            Button("Annulla", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Text("\(confirmedCount) di \(model.reviewPlan?.categories.count ?? 0) confermate")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(role: .destructive) {
                confirmsExecution = true
            } label: {
                Text("Esegui pulizia…")
            }
            .actionButtonStyle(.primary)
            .disabled(confirmedCount == 0)
        }
        .padding(Spacing.lg)
    }
}

private struct ReviewCategoryCard: View {
    let plan: CategoryPlan
    @Binding var isConfirmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                CategoryIcon(symbol: plan.category.symbolFallback, tint: plan.category.tint, size: 28)
                Text(plan.title).font(.headline)
                Spacer()
                Text(plan.estimatedBytes.map { $0.formattedBytes } ?? "Stima dello strumento")
                    .font(.headline)
                    .monospacedDigit()
            }
            operationDetail
            VStack(alignment: .leading, spacing: 2) {
                ForEach(plan.risks, id: \.self) { risk in
                    Label(risk, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $isConfirmed) {
                Text("Confermo la pulizia di «\(plan.title)»")
                    .font(.callout.weight(.medium))
            }
            .toggleStyle(.checkbox)
        }
        .padding(Spacing.lg)
        .glassSurface(tint: isConfirmed ? plan.category.tint : nil)
    }

    @ViewBuilder
    private var operationDetail: some View {
        switch plan.operation {
        case .removeItems(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items.prefix(8)) { item in
                    HStack {
                        Text(item.displayName)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(item.estimatedBytes.formattedBytes)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if items.count > 8 {
                    Text("e altri \(items.count - 8) elementi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.sm)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Radius.small))
        case .pnpmStorePrune(let tool):
            Text("Comando: `pnpm store prune` (pnpm \(tool.version.description), \(tool.executable.path))")
                .font(.callout)
                .textSelection(.enabled)
        case .simctlDeleteUnavailable(let count):
            Text("Comando: `xcrun simctl delete unavailable` · \(count) dispositivi non disponibili")
                .font(.callout)
        }
    }
}

private extension CategoryID {
    var symbolFallback: String {
        switch self {
        case .appCaches: "internaldrive"
        case .xcodeDerivedData: "hammer"
        case .gradleCaches: "shippingbox"
        case .pnpmStore: "cube.box"
        case .simulators: "iphone"
        default: "folder"
        }
    }
}

// MARK: - Avanzamento

private struct CleanupProgressView: View {
    @Environment(AppModel.self) private var model
    let progress: CleanupProgress

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            Text(progress.categoryTitle.isEmpty ? "Avvio della pulizia…" : progress.categoryTitle)
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ProgressView(value: Double(progress.categoryIndex), total: Double(max(1, progress.categoryCount))) {
                    Text("Categoria \(min(progress.categoryIndex + 1, progress.categoryCount)) di \(progress.categoryCount)")
                        .font(.callout)
                }
                if progress.itemCount > 1 {
                    ProgressView(value: Double(progress.itemIndex), total: Double(progress.itemCount)) {
                        Text("Elemento \(progress.itemIndex + 1) di \(progress.itemCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !progress.currentItem.isEmpty {
                    Text(progress.currentItem)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 420)
            Button("Interrompi dopo l'elemento corrente", role: .cancel) { model.cancelCleanup() }
                .actionButtonStyle(.secondary)
            Spacer()
        }
        .padding(Spacing.xxl)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Esito

struct CleanupSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let summary: CleanupSummary

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Label("Pulizia terminata", systemImage: summary.errorCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title.weight(.bold))
                        .foregroundStyle(summary.errorCount == 0 ? .green : .orange)
                    GlassGroup {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.sm)], spacing: Spacing.sm) {
                            StatTile(title: "Liberato", value: summary.freedBytes.formattedBytes, caption: "Spazio misurato realmente.", symbol: "leaf", tint: .green)
                            StatTile(title: "Nel Cestino", value: summary.trashedBytes.formattedBytes, caption: "Liberato allo svuotamento.", symbol: "trash", tint: .blue)
                            StatTile(title: "Elaborate", value: "\(summary.processedCategories.count)", caption: "Categorie completate o parziali.", symbol: "checkmark.circle", tint: .mint)
                            StatTile(title: "Errori", value: "\(summary.errorCount)", caption: "Operazioni non riuscite.", symbol: "xmark.octagon", tint: .red)
                            StatTile(title: "Saltati", value: "\(summary.skippedCount)", caption: "Elementi o categorie incerte.", symbol: "forward", tint: .orange)
                        }
                    }
                    ForEach(summary.outcomes) { outcome in
                        OutcomeCard(outcome: outcome)
                    }
                }
                .padding(Spacing.xl)
            }
            Divider()
            HStack {
                Text("Durata: \(Duration.seconds(summary.finishedAt.timeIntervalSince(summary.startedAt)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Chiudi") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .actionButtonStyle(.primary)
            }
            .padding(Spacing.lg)
        }
    }
}

private struct OutcomeCard: View {
    let outcome: CategoryOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(outcome.title).font(.headline)
                Text(outcome.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, 2)
                    .glassCapsule(tint: statusTint)
                Spacer()
                Text(outcome.freedBytes > 0 ? outcome.freedBytes.formattedBytes : (outcome.trashedBytes > 0 ? "\(outcome.trashedBytes.formattedBytes) nel Cestino" : "—"))
                    .monospacedDigit()
            }
            if let note = outcome.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !outcome.skipped.isEmpty {
                DisclosureGroup("\(outcome.skipped.count) elementi saltati") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(outcome.skipped.prefix(50)) { item in
                            Text("\(item.name) — \(item.reason)")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.callout)
            }
            if !outcome.errors.isEmpty {
                DisclosureGroup("\(outcome.errors.count) errori") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(outcome.errors.prefix(50), id: \.self) { error in
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.callout)
            }
        }
        .padding(Spacing.md)
        .glassSurface(cornerRadius: Radius.tile)
    }

    private var statusTint: Color {
        switch outcome.status {
        case .completed: .green
        case .partial: .orange
        case .skipped: .secondary
        case .failed: .red
        case .cancelled: .gray
        }
    }
}
