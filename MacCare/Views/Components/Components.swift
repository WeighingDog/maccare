import SwiftUI

/// Simbolo monocromatico di categoria, come le icone di Finder e Impostazioni.
struct CategorySymbol: View {
    let symbol: String
    var font: Font = .body

    var body: some View {
        Image(systemName: symbol)
            .font(font)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.secondary)
            .frame(minWidth: 20)
            .accessibilityHidden(true)
    }
}

/// Livello di sicurezza come testo secondario con simbolo.
struct SafetyLabel: View {
    let level: SafetyLevel

    var body: some View {
        Label(level.title, systemImage: level.symbol)
            .foregroundStyle(.secondary)
            .help(level.explanation)
            .accessibilityLabel("Sicurezza: \(level.title)")
    }
}

/// Classificazione della policy per un percorso.
struct ClassificationLabel: View {
    let classification: PathClassification

    var body: some View {
        Text(classification.title)
            .foregroundStyle(classification.tint)
    }
}

/// Riga con simbolo, titolo e sottotitolo di una riga.
struct CategoryLabel: View {
    let title: String
    let subtitle: String?
    let symbol: String
    var subtitleStyle: Color = .secondary

    var body: some View {
        HStack(spacing: Spacing.sm) {
            CategorySymbol(symbol: symbol)
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

/// Anello del disco: spazio occupato in tono neutro, la parte recuperabile nel colore d'accento.
/// Con `progress` diventa un indicatore di avanzamento.
struct DiskRing<Center: View>: View {
    var usedFraction: Double = 0
    var highlightFraction: Double = 0
    var progress: Double?
    var diameter: CGFloat = 220
    var lineWidth: CGFloat = 12
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.track, lineWidth: lineWidth)
            if let progress {
                arc(from: 0, to: max(0.004, min(1, progress)), color: Palette.recoverable, cap: .round)
            } else {
                let used = min(1, max(0, usedFraction))
                let highlight = min(used, max(0, highlightFraction))
                arc(from: 0, to: used - highlight, color: Palette.neutral, cap: .butt)
                if highlight > 0 {
                    arc(from: used - highlight, to: used, color: Palette.recoverable, cap: .butt)
                }
            }
            center
        }
        .frame(width: diameter, height: diameter)
        .padding(lineWidth / 2)
    }

    private func arc(from: Double, to: Double, color: Color, cap: CGLineCap) -> some View {
        Circle()
            .trim(from: from, to: max(from, to))
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: cap))
            .rotationEffect(.degrees(-90))
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
    var height: CGFloat = 10

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
        .background(Palette.track)
        .clipShape(.rect(cornerRadius: 3, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Utilizzo dello spazio")
        .accessibilityValue(segments.map { "\($0.title) \($0.bytes.formattedBytes)" }.joined(separator: ", "))
    }
}

/// Legenda compatta della barra, con i valori.
struct StorageLegend: View {
    let segments: [StorageBar.Segment]

    var body: some View {
        HStack(spacing: Spacing.lg) {
            ForEach(segments.filter { $0.bytes > 0 }) { segment in
                HStack(spacing: Spacing.xxs + 2) {
                    RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 10, height: 10)
                    Text(segment.title).foregroundStyle(.secondary)
                    Text(segment.bytes.formattedBytes).monospacedDigit()
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
