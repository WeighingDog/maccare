import SwiftUI

struct AnalysisView: View {
    @Environment(AppModel.self) private var model
    var scrollable = true

    var body: some View {
        Group {
            if !model.hasScanned && !model.isScanning {
                ContentUnavailableView {
                    Label("Nessun dato", systemImage: "chart.bar.doc.horizontal")
                } description: {
                    Text("Avvia una scansione per misurare le cartelle analizzate da MacCare.")
                } actions: {
                    Button("Avvia scansione") { model.startScan() }
                        .actionButtonStyle(.primary)
                }
            } else {
                PageContainer(scrollable: scrollable) {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        PageHeader("Analisi", subtitle: "Dimensioni misurate, livello di sicurezza e azioni disponibili")
                        if model.isScanning { ScanProgressCard() }
                        ForEach(CategorySection.allCases, id: \.self) { section in
                            let categories = model.categories(in: section)
                            if !categories.isEmpty {
                                CategoryListCard(section: section, categories: categories)
                            }
                        }
                        LargeDirectoriesCard()
                    }
                    .pageLayout()
                }
            }
        }
        .navigationTitle("Analisi")
    }
}

private struct CategoryListCard: View {
    @Environment(AppModel.self) private var model
    let section: CategorySection
    let categories: [CleanupCategory]

    var body: some View {
        let sorted = categories.sorted { model.size(of: $0) > model.size(of: $1) }
        let maxSize = max(1, sorted.map { model.size(of: $0) }.max() ?? 1)
        SectionCard(section.title, symbol: symbol) {
            VStack(spacing: Spacing.xxs) {
                ForEach(sorted) { category in
                    NavigationLink(value: category.id) {
                        CategoryRow(category: category, maxSize: maxSize)
                    }
                    .buttonStyle(.plain)
                    if category.id != sorted.last?.id { Divider() }
                }
            }
        }
    }

    private var symbol: String {
        switch section {
        case .cleanup: "sparkles"
        case .development: "hammer"
        case .protected: "lock.shield"
        case .diagnostic: "stethoscope"
        }
    }
}

/// Cartelle più grandi trovate in tutte le scomposizioni, con la classificazione della policy.
struct LargeDirectoriesCard: View {
    @Environment(AppModel.self) private var model
    var limit = 25

    var body: some View {
        let items = model.largeDirectories(limit: limit)
        SectionCard("Directory grandi individuate", symbol: "folder.badge.questionmark") {
            Text("≥ \(Int64(model.settings.largeDirectoryThresholdMB * 1_000_000).formattedBytes)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } content: {
            if items.isEmpty {
                Text("Nessuna cartella sopra la soglia impostata.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let maxSize = max(1, items.first?.allocatedBytes ?? 1)
                VStack(spacing: Spacing.xs) {
                    ForEach(items) { item in
                        HStack(spacing: Spacing.sm) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(item.path.replacingOccurrences(of: model.policy.home.path, with: "~"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: Spacing.sm)
                            SizeBar(fraction: Double(item.allocatedBytes) / Double(maxSize), tint: item.classification.tint == .secondary ? .gray : item.classification.tint)
                                .frame(width: 120)
                            Text(item.allocatedBytes.formattedBytes)
                                .font(.callout)
                                .monospacedDigit()
                                .frame(minWidth: 72, alignment: .trailing)
                            ClassificationBadge(classification: item.classification)
                                .frame(minWidth: 120, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("Solo diagnostica: queste cartelle non vengono modificate. Le dimensioni di cartelle annidate si sovrappongono.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
