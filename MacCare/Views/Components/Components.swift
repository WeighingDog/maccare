import SwiftUI

/// Badge del livello di sicurezza.
struct SafetyBadge: View {
    let level: SafetyLevel
    var compact = false

    var body: some View {
        Label(level.title, systemImage: level.symbol)
            .labelStyle(.titleAndIcon)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(level == .analysisOnly ? Color.secondary : level.tint)
            .padding(.horizontal, compact ? Spacing.xs : Spacing.sm - 2)
            .padding(.vertical, compact ? 2 : Spacing.xxs)
            .glassCapsule(tint: level == .analysisOnly ? nil : level.tint)
            .accessibilityLabel("Livello di sicurezza: \(level.title)")
            .help(level.explanation)
    }
}

/// Badge per la classificazione di un percorso secondo la policy.
struct ClassificationBadge: View {
    let classification: PathClassification

    var body: some View {
        Text(classification.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(classification.safetyLevel == .analysisOnly ? Color.secondary : classification.tint)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .glassCapsule(tint: classification.safetyLevel == .analysisOnly ? nil : classification.tint)
            .accessibilityLabel("Classificazione: \(classification.title)")
    }
}

/// Icona di categoria in un contenitore arrotondato colorato.
struct CategoryIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

/// Riquadro con titolo, valore principale e didascalia.
struct StatTile: View {
    let title: String
    let value: String
    let caption: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .glassSurface(cornerRadius: Radius.tile, tint: tint)
        .accessibilityElement(children: .combine)
    }
}

/// Barra di utilizzo segmentata (stile Impostazioni di Sistema › Spazio).
struct UsageBar: View {
    struct Segment: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 16

    private var total: Int64 { max(1, segments.reduce(0) { $0 + max(0, $1.bytes) }) }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(segments.filter { $0.bytes > 0 }) { segment in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: max(2, proxy.size.width * CGFloat(Double(segment.bytes) / Double(total)) - 2))
                        .help("\(segment.title): \(segment.bytes.formattedBytes)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .clipShape(.capsule)
        .background(.quaternary, in: .capsule)
        .accessibilityElement()
        .accessibilityLabel("Utilizzo dello spazio")
        .accessibilityValue(segments.map { "\($0.title) \($0.bytes.formattedBytes)" }.joined(separator: ", "))
    }
}

/// Barra proporzionale semplice per righe di elenco.
struct SizeBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(tint.gradient)
                .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
        }
        .frame(height: 6)
        .background(.quaternary, in: .capsule)
        .accessibilityHidden(true)
    }
}

/// Card con titolo e contenuto (slot @ViewBuilder, compose-viewbuilder).
struct SectionCard<Content: View, Accessory: View>: View {
    let title: String
    var symbol: String?
    var tint: Color?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String? = nil, tint: Color? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(tint ?? .secondary)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.xs)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.lg)
        .glassSurface()
    }
}

/// Coppia etichetta/valore allineata (per Grid).
struct MetricRow: View {
    let label: String
    let value: String
    var valueStyle: HierarchicalShapeStyle = .primary

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .foregroundStyle(valueStyle)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Riga di avviso inline (errori non bloccanti, blocchi "in uso", note).
struct InlineNotice: View {
    enum Style { case info, warning, error, success }

    let text: String
    var style: Style = .info

    private var symbol: String {
        switch style {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .success: "checkmark.circle"
        }
    }

    private var tint: Color {
        switch style {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
        .foregroundStyle(style == .info ? .secondary : .primary)
    }
}

/// Intestazione di pagina con gerarchia tipografica chiara.
struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    init(_ title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.md)
            accessory
        }
    }
}

extension Date {
    var relativeDescription: String {
        formatted(.relative(presentation: .named))
    }
}
