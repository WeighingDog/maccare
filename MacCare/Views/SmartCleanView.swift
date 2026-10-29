import SwiftUI

/// Home: Analizza → risultati con una casella per categoria → Pulisci → esito.
struct SmartCleanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: Equatable {
        case idle, scanning, results, cleaning, done
    }

    private var phase: Phase {
        if model.isCleaning { return .cleaning }
        if model.presentedSummary != nil { return .done }
        if model.isScanning && !model.hasScanned { return .scanning }
        if model.hasScanned { return .results }
        return .idle
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            ScrollView {
                Group {
                    switch phase {
                    case .idle: IdleState()
                    case .scanning: ScanningState()
                    case .results: ResultsState()
                    case .cleaning: CleaningState()
                    case .done: DoneState()
                    }
                }
                .frame(maxWidth: phase == .results ? 680 : 460)
                .padding(.horizontal, Spacing.xxl)
                .padding(.vertical, Spacing.xxl)
                .frame(maxWidth: .infinity, minHeight: phase == .results ? nil : proxy.size.height)
                .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(.adaptive(reduceMotion), value: phase)
        .navigationTitle("Pulizia intelligente")
        .confirmationDialog(confirmationTitle, isPresented: $model.confirmsCleaning, titleVisibility: .visible) {
            Button(model.settings.removalMethod == .moveToTrash ? "Sposta nel Cestino" : "Elimina definitivamente", role: .destructive) {
                model.cleanSelected()
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationTitle: String {
        let count = model.selectedCategories.count
        return "Pulire \(count) \(count == 1 ? "categoria" : "categorie")?"
    }

    private var confirmationMessage: String {
        let lines = model.selectedCategories.map { "\($0.title) — \(model.estimateText(for: $0))" }
        let method = model.settings.removalMethod == .moveToTrash
            ? "Gli elementi andranno nel Cestino: potrai recuperarli finché non lo svuoti."
            : "Gli elementi verranno eliminati definitivamente."
        return lines.joined(separator: "\n") + "\n\n" + method
    }
}

// MARK: - Stato iniziale

private struct IdleState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Spacing.xl) {
            if let volume = model.volume {
                DiskRing(usedFraction: Double(volume.usedBytes) / Double(max(1, volume.totalBytes))) {
                    VStack(spacing: 2) {
                        Text(volume.availableBytes.formattedBytes)
                            .font(.title.weight(.semibold))
                            .monospacedDigit()
                        Text("disponibili su \(volume.totalBytes.formattedBytes)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(volume.name): \(volume.availableBytes.formattedBytes) disponibili su \(volume.totalBytes.formattedBytes)")
            }
            VStack(spacing: Spacing.xs) {
                Text("Libera spazio in sicurezza")
                    .font(.title2.weight(.semibold))
                Text("MacCare misura cache e file di sviluppo e propone solo ciò che si può eliminare senza rischi. L'analisi non modifica nulla.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.startScan()
            } label: {
                Text("Analizza").frame(minWidth: 120)
            }
            .actionButtonStyle(.primary)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            if case .failed(let message) = model.scanPhase {
                StatusText(text: "Analisi non riuscita: \(message)", style: .error)
            } else if model.scanPhase == .cancelled {
                StatusText(text: "Analisi interrotta.")
            }
        }
    }
}

// MARK: - Analisi in corso

private struct ScanningState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.scanProgress
        VStack(spacing: Spacing.xl) {
            DiskRing(progress: model.scanPhase == .preparing ? 0 : (progress.fraction ?? 0)) {
                VStack(spacing: 2) {
                    Text(progress.itemsVisited.formatted())
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("elementi esaminati")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.smooth, value: progress.completedRoots)
            VStack(spacing: Spacing.xs) {
                Text(model.scanPhase == .preparing ? "Preparazione…" : "Analisi in corso")
                    .font(.title2.weight(.semibold))
                Text(progress.currentRoot.isEmpty ? "Verifica degli strumenti di sviluppo" : progress.currentRoot.abbreviatingHome(model.policy.home))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Interrompi") { model.cancelScan() }
                .actionButtonStyle(.secondary)
                .controlSize(.large)
        }
    }
}

// MARK: - Risultati

private struct ResultsState: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            hero
            MetricsStrip()
            CategoryList()
            if !model.systemInsights.isEmpty {
                SystemInsightsList()
            }
            actionBar
        }
    }

    private var hero: some View {
        HStack(spacing: Spacing.xl) {
            if let volume = model.volume {
                let total = Double(max(1, volume.totalBytes))
                DiskRing(usedFraction: Double(volume.usedBytes) / total,
                         highlightFraction: Double(model.recoverableBytes) / total,
                         diameter: 112, lineWidth: 10) {
                    CategorySymbol(symbol: "internaldrive", font: .title2)
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Puoi liberare")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(model.recoverableBytes.formattedBytes)
                    .font(.system(size: heroSize, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("senza toccare documenti, progetti e dati delle app")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }

    private var actionBar: some View {
        let count = model.selectedCategories.count
        return HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 0 ? "Seleziona cosa pulire" : "\(count) \(count == 1 ? "categoria selezionata" : "categorie selezionate")")
                Text(footerText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.requestCleaning()
            } label: {
                Text(model.cleanButtonTitle)
                    .monospacedDigit()
                    .frame(minWidth: 120)
            }
            .actionButtonStyle(.primary)
            .controlSize(.large)
            .disabled(count == 0 || model.isScanning)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var footerText: String {
        if model.isScanning { return "Aggiornamento dell'analisi…" }
        guard let date = model.lastScanDate else { return "" }
        return "Analizzato \(date.relativeDescription)"
    }
}

/// Le misure di contesto in un'unica fila, con tipografia secondaria.
private struct MetricsStrip: View {
    @Environment(AppModel.self) private var model
    @State private var showsUnanalyzable = false

    var body: some View {
        HStack(spacing: 0) {
            metric("Occupato", model.volume?.usedBytes.formattedBytes ?? "—")
            Divider().frame(height: 28)
            metric("Protetto", model.protectedBytes.formattedBytes, help: "Misurato ma mai modificato: WhatsApp, archivi, SDK, dati delle app")
            Divider().frame(height: 28)
            metric("Recuperato", recoveredText, help: "Spazio liberato in questa sessione")
            Divider().frame(height: 28)
            Button {
                showsUnanalyzable = true
            } label: {
                metric("Non analizzabili", "\(model.unanalyzableCount)", warning: model.unanalyzableCount > 0)
            }
            .buttonStyle(.plain)
            .disabled(model.unanalyzableCount == 0)
            .popover(isPresented: $showsUnanalyzable, arrowEdge: .bottom) {
                UnanalyzablePopover()
            }
        }
        .padding(.vertical, Spacing.sm)
        .groupedContainer()
    }

    private var recoveredText: String {
        if model.sessionFreedBytes == 0, model.sessionTrashedBytes > 0 {
            return "\(model.sessionTrashedBytes.formattedBytes) nel Cestino"
        }
        return model.sessionFreedBytes.formattedBytes
    }

    private func metric(_ title: String, _ value: String, help: String? = nil, warning: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(warning ? Palette.warning : .primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// Elenco delle categorie pulibili, ognuna con la sua casella.
private struct CategoryList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let categories = model.actionableCategories.sorted { lhs, rhs in
            let l = model.isSelectable(lhs), r = model.isSelectable(rhs)
            if l != r { return l }
            return (model.estimate(for: lhs).bytes ?? 0) > (model.estimate(for: rhs).bytes ?? 0)
        }
        VStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                CategoryRow(category: category)
                if index < categories.count - 1 {
                    Divider().padding(.leading, 64)
                }
            }
        }
        .groupedContainer()
    }
}

private struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory
    @State private var isHovering = false

    var body: some View {
        let selectable = model.isSelectable(category)
        let status = model.statusLine(for: category)
        let isOn = Binding(
            get: { model.selectedForCleanup.contains(category.id) },
            set: { _ in model.toggleSelection(category.id) }
        )
        HStack(spacing: Spacing.sm) {
            Toggle("Seleziona \(category.title)", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!selectable || model.isCleaning)
            CategorySymbol(symbol: category.symbol, font: .title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .foregroundStyle(selectable ? .primary : .secondary)
                Text(status.text)
                    .font(.callout)
                    .foregroundStyle(status.color)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            Text(model.estimateText(for: category))
                .monospacedDigit()
                .foregroundStyle(selectable ? .primary : .secondary)
            Button {
                model.openCategory(category.id)
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0.45)
            .help("Dettagli")
            .accessibilityLabel("Dettagli di \(category.title)")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .contentShape(.rect)
        .onTapGesture { if selectable && !model.isCleaning { model.toggleSelection(category.id) } }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// Anomalie nei Dati di sistema: non si puliscono da qui, si spiega come intervenire.
private struct SystemInsightsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let insights = model.systemInsights
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Dati di sistema")
                .font(.headline)
                .padding(.leading, Spacing.xxs)
            VStack(spacing: 0) {
                ForEach(Array(insights.enumerated()), id: \.element.id) { index, insight in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warning)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(insight.title).monospacedDigit()
                            Text(insight.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Spacing.sm)
                        Button("Dettagli") { model.openCategory(.systemData) }
                            .buttonStyle(.link)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .accessibilityElement(children: .combine)
                    if index < insights.count - 1 { Divider().padding(.leading, 52) }
                }
            }
            .groupedContainer()
        }
    }
}

private struct UnanalyzablePopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Percorsi non analizzabili")
                .font(.headline)
            ForEach(model.categories) { category in
                ForEach(model.unanalyzableLocations(in: category)) { location in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.title)
                        Text(location.path.abbreviatingHome(model.policy.home))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Text("macOS protegge questi dati. Per misurarli puoi concedere a MacCare l'Accesso completo al disco.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.lg)
        .frame(width: 360)
    }
}

// MARK: - Pulizia in corso

private struct CleaningState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .running(let progress) = model.cleanupPhase {
            let fraction = overallFraction(progress)
            VStack(spacing: Spacing.xl) {
                DiskRing(progress: fraction) {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .animation(.smooth, value: fraction)
                VStack(spacing: Spacing.xs) {
                    Text(progress.categoryTitle.isEmpty ? "Avvio della pulizia…" : progress.categoryTitle)
                        .font(.title2.weight(.semibold))
                    Text(progress.currentItem.isEmpty ? "Verifica di sicurezza degli elementi" : progress.currentItem)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Interrompi") { model.cancelCleanup() }
                    .actionButtonStyle(.secondary)
                    .controlSize(.large)
            }
        }
    }

    private func overallFraction(_ progress: CleanupProgress) -> Double {
        guard progress.categoryCount > 0 else { return 0 }
        let itemPart = progress.itemCount > 0 ? Double(progress.itemIndex) / Double(progress.itemCount) : 0
        return (Double(progress.categoryIndex) + itemPart) / Double(progress.categoryCount)
    }
}

// MARK: - Esito

private struct DoneState: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        if let summary = model.presentedSummary {
            VStack(spacing: Spacing.xl) {
                Image(systemName: summary.errorCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 56, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, summary.errorCount == 0 ? Palette.recoverable : Palette.warning)
                    .symbolEffect(.bounce, value: appeared && !reduceMotion)
                    .accessibilityHidden(true)
                VStack(spacing: Spacing.xs) {
                    Text(headline(summary))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(detail(summary))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                OutcomeList(summary: summary)
                Button {
                    model.dismissSummary()
                } label: {
                    Text("Fatto").frame(minWidth: 120)
                }
                .actionButtonStyle(.primary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .onAppear { appeared = true }
        }
    }

    private func headline(_ summary: CleanupSummary) -> String {
        if summary.freedBytes > 0 { return "Liberati \(summary.freedBytes.formattedBytes)" }
        if summary.trashedBytes > 0 { return "\(summary.trashedBytes.formattedBytes) spostati nel Cestino" }
        return "Nessuno spazio liberato"
    }

    private func detail(_ summary: CleanupSummary) -> String {
        var parts = [summary.outcomes.count == 1
            ? "\(summary.processedCategories.count) di 1 categoria elaborata"
            : "\(summary.processedCategories.count) di \(summary.outcomes.count) categorie elaborate"]
        if summary.skippedCount > 0 {
            parts.append(summary.skippedCount == 1 ? "1 elemento saltato per sicurezza" : "\(summary.skippedCount) elementi saltati per sicurezza")
        }
        if summary.errorCount > 0 { parts.append(summary.errorCount == 1 ? "1 errore" : "\(summary.errorCount) errori") }
        var text = parts.joined(separator: " · ")
        if summary.trashedBytes > 0 { text += "\nLo spazio si libera quando svuoti il Cestino." }
        return text
    }
}

private struct OutcomeList: View {
    let summary: CleanupSummary

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(summary.outcomes.enumerated()), id: \.element.id) { index, outcome in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        if let note = outcome.note {
                            Text(note).foregroundStyle(.secondary)
                        }
                        ForEach(outcome.skipped.prefix(20)) { item in
                            Text("\(item.name) — \(item.reason)").foregroundStyle(.secondary)
                        }
                        ForEach(outcome.errors.prefix(20), id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, Spacing.xxs)
                } label: {
                    HStack {
                        Text(outcome.title)
                        Spacer()
                        Text(outcome.status.title)
                            .foregroundStyle(outcome.status == .completed ? Color.secondary : Palette.warning)
                        Text((outcome.freedBytes > 0 ? outcome.freedBytes : outcome.trashedBytes).formattedBytes)
                            .monospacedDigit()
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                if index < summary.outcomes.count - 1 { Divider() }
            }
        }
        .groupedContainer()
    }
}
