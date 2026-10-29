import SwiftUI

/// Icona in un quadrato arrotondato a colore pieno, come nelle Impostazioni di Sistema.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Livello di sicurezza come testo colorato con simbolo (nessuna capsula).
struct SafetyLabel: View {
    let level: SafetyLevel

    var body: some View {
        Label(level.title, systemImage: level.symbol)
            .font(.callout)
            .foregroundStyle(level.tint)
            .help(level.explanation)
            .accessibilityLabel("Sicurezza: \(level.title)")
    }
}

/// Classificazione della policy per un percorso.
struct ClassificationLabel: View {
    let classification: PathClassification

    var body: some View {
        Text(classification.title)
            .font(.callout)
            .foregroundStyle(classification.tint)
    }
}

/// Riga con icona, titolo e sottotitolo di una riga.
struct CategoryLabel: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    var subtitleStyle: Color = .secondary

    var body: some View {
        HStack(spacing: Spacing.sm) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(subtitleStyle)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Barra dello spazio segmentata, come in Impostazioni di Sistema › Generali › Spazio.
struct StorageBar: View {
    struct Segment: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let color: Color
    }

    let segments: [Segment]
    let totalBytes: Int64
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, Double(totalBytes))
            HStack(spacing: 1) {
                ForEach(segments.filter { $0.bytes > 0 }) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(2, proxy.size.width * Double(segment.bytes) / total))
                        .help("\(segment.title): \(segment.bytes.formattedBytes)")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 3, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Utilizzo dello spazio")
        .accessibilityValue(segments.map { "\($0.title) \($0.bytes.formattedBytes)" }.joined(separator: ", "))
    }
}

/// Legenda compatta della barra.
struct StorageLegend: View {
    let segments: [StorageBar.Segment]

    var body: some View {
        HStack(spacing: Spacing.md) {
            ForEach(segments) { segment in
                HStack(spacing: Spacing.xxs) {
                    Circle().fill(segment.color).frame(width: 8, height: 8)
                    Text(segment.title)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.callout)
    }
}

/// Testo di stato breve con simbolo (avvisi non bloccanti).
struct StatusText: View {
    enum Style { case neutral, warning, error, success }

    let text: String
    var style: Style = .neutral

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
        .foregroundStyle(style == .neutral ? .secondary : .primary)
    }

    private var symbol: String {
        switch style {
        case .neutral: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch style {
        case .neutral: .secondary
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }
}

/// Valore di dimensione allineato a destra con cifre tabellari.
struct SizeText: View {
    let bytes: Int64?
    var placeholder = "—"

    var body: some View {
        Text(bytes.map(\.formattedBytes) ?? placeholder)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
