import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    var scrollable = true
    @State private var confirmsEnable = false

    var body: some View {
        PageContainer(scrollable: scrollable) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                PageHeader("Pulizia", subtitle: "Seleziona le categorie, rivedi il riepilogo e conferma ciascuna")
                modeBanner
                if !model.hasScanned {
                    InlineNotice(text: "Esegui una scansione per calcolare le stime: nessuna categoria è selezionabile senza dati reali.", style: .info)
                }
                GlassGroup {
                    VStack(spacing: Spacing.md) {
                        ForEach(model.actionableCategories) { category in
                            CleanupCandidateCard(category: category)
                        }
                    }
                }
                if let summary = model.lastSummary {
                    LastSummaryCard(summary: summary)
                }
            }
            .pageLayout()
            .padding(.bottom, 72)
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .navigationTitle("Pulizia")
        .confirmationDialog("Abilitare la pulizia per questa sessione?", isPresented: $confirmsEnable) {
            Button("Abilita pulizia") { model.enableCleanupForSession() }
            Button("Resta in solo analisi", role: .cancel) {}
        } message: {
            Text("Potrai selezionare le categorie autorizzate. Prima di qualsiasi operazione vedrai un riepilogo e dovrai confermare ogni categoria. Al prossimo avvio MacCare tornerà in modalità solo analisi.")
        }
    }

    @ViewBuilder
    private var modeBanner: some View {
        @Bindable var settings = model.settings
        HStack(alignment: .center, spacing: Spacing.md) {
            Image(systemName: model.cleanupEnabledThisSession ? "lock.open.fill" : "lock.fill")
                .font(.title2)
                .foregroundStyle(model.cleanupEnabledThisSession ? .orange : .secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(model.cleanupEnabledThisSession ? "Pulizia abilitata per questa sessione" : "Modalità solo analisi")
                    .font(.headline)
                Text(model.cleanupEnabledThisSession
                     ? "Le operazioni restano limitate alla allowlist e richiedono una conferma per categoria."
                     : "Nessuna operazione può modificare il disco finché non abiliti la pulizia.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.md)
            if model.cleanupEnabledThisSession {
                Picker("Metodo", selection: $settings.removalMethod) {
                    ForEach(RemovalMethod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help(settings.removalMethod.explanation)
                Button("Torna a solo analisi") { model.disableCleanupForSession() }
                    .actionButtonStyle(.secondary)
            } else {
                Button("Abilita pulizia…") { confirmsEnable = true }
                    .actionButtonStyle(.secondary)
                    .disabled(!model.hasScanned)
            }
        }
        .padding(Spacing.lg)
        .glassSurface(tint: model.cleanupEnabledThisSession ? .orange : nil)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 0 ? "Nessuna categoria selezionata" : "\(count) categorie selezionate")
                    .font(.headline)
                Text(count == 0 ? "Seleziona una o più categorie disponibili." : "Stima: \(selectedEstimate.formattedBytes) · stime da strumenti esterni escluse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.prepareReview()
            } label: {
                Label("Rivedi riepilogo…", systemImage: "list.bullet.clipboard")
            }
            .actionButtonStyle(.primary)
            .controlSize(.large)
            .disabled(count == 0 || !model.cleanupEnabledThisSession || model.isScanning || model.isCleaning)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .glassSurface(cornerRadius: Radius.card)
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.md)
        .frame(maxWidth: Layout.readableWidth)
    }
}

/// Categoria candidata: selezione, stima, disponibilità, blocchi e rischi.
private struct CleanupCandidateCard: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory

    var body: some View {
        let availability = model.availability(for: category)
        let selectable = model.isSelectable(category)
        let blockers = model.knownBlockers(for: category)
        HStack(alignment: .top, spacing: Spacing.md) {
            Toggle(isOn: Binding(
                get: { model.selectedForCleanup.contains(category.id) },
                set: { _ in model.toggleSelection(category.id) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!selectable || model.isCleaning)
            .accessibilityLabel("Seleziona \(category.title)")
            .padding(.top, Spacing.xs)

            CategoryIcon(symbol: category.symbol, tint: category.id.tint, size: 40)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Text(category.title).font(.headline)
                    SafetyBadge(level: category.safety, compact: true)
                }
                Text(category.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let message = availability.message, availability != .analysisMode {
                    InlineNotice(text: message, style: selectable ? .info : .warning)
                }
                if !blockers.isEmpty {
                    InlineNotice(text: "Attualmente in uso: \(blockers.joined(separator: ", ")). Gli elementi che ne dipendono verranno saltati; gli altri potranno essere puliti.", style: .warning)
                }
                DisclosureGroup("Rischi") {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        ForEach(category.risks, id: \.self) { Text("• \($0)").font(.callout) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.xxs)
                }
                .font(.callout)
            }

            Spacer(minLength: Spacing.sm)

            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                Text(estimateValue)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(estimateCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NavigationLink(value: category.id) {
                    Text("Dettagli")
                }
                .buttonStyle(.link)
                .padding(.top, Spacing.xxs)
            }
        }
        .padding(Spacing.lg)
        .glassSurface(tint: model.selectedForCleanup.contains(category.id) ? category.id.tint : nil)
        .opacity(selectable ? 1 : 0.75)
    }

    private var estimateValue: String {
        switch model.estimate(for: category) {
        case .bytes(let bytes): bytes.formattedBytes
        case .determinedByTool: "Da calcolare"
        case .none: "—"
        }
    }

    private var estimateCaption: String {
        switch model.estimate(for: category) {
        case .bytes: "\(model.plannedRemovals(for: category).count) elementi · stima"
        case .determinedByTool(let text): text
        case .none: "Nessuna stima"
        }
    }
}

private struct LastSummaryCard: View {
    @Environment(AppModel.self) private var model
    let summary: CleanupSummary

    var body: some View {
        SectionCard("Ultima pulizia", symbol: "checkmark.seal", tint: .green) {
            Button("Apri riepilogo") { model.showsCleanupFlow = true }
                .actionButtonStyle(.secondary)
                .controlSize(.small)
        } content: {
            Text("\(summary.finishedAt.formatted(date: .abbreviated, time: .shortened)) · liberati \(summary.freedBytes.formattedBytes)"
                 + (summary.trashedBytes > 0 ? " · nel Cestino \(summary.trashedBytes.formattedBytes)" : "")
                 + " · \(summary.errorCount) errori · \(summary.skippedCount) saltati")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
