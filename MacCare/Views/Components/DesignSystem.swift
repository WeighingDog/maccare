import SwiftUI

/// Spaziature su base 4 pt (skill ios-design › system-spacing-grid).
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

/// Palette volutamente sobria: il colore d'accento di sistema per ciò che è recuperabile,
/// toni neutri per tutto il resto, arancione e rosso solo per avvisi ed errori.
enum Palette {
    static let recoverable = Color.accentColor
    static let neutralStrong = Color.primary.opacity(0.42)
    static let neutral = Color.primary.opacity(0.22)
    static let neutralWeak = Color.primary.opacity(0.10)
    static let track = Color.primary.opacity(0.07)
    static let warning = Color.orange
}

extension PathClassification {
    /// Solo le classificazioni che richiedono attenzione hanno un colore.
    var tint: Color {
        switch self {
        case .cleanableItem, .insideCleanableItem: .accentColor
        default: .secondary
        }
    }
}

// MARK: - Liquid Glass solo sui controlli

enum ActionProminence {
    case primary
    case secondary
}

/// Pulsanti: stili Liquid Glass su macOS 26+, stili bordered su macOS 15.
/// Il vetro è riservato ai controlli: i contenuti restano su fondo pieno (linee guida Apple).
struct ActionButtonStyleModifier: ViewModifier {
    let prominence: ActionProminence

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            switch prominence {
            case .primary: content.buttonStyle(.glassProminent)
            case .secondary: content.buttonStyle(.glass)
            }
        } else {
            switch prominence {
            case .primary: content.buttonStyle(.borderedProminent)
            case .secondary: content.buttonStyle(.bordered)
            }
        }
    }
}

extension View {
    func actionButtonStyle(_ prominence: ActionProminence) -> some View {
        modifier(ActionButtonStyleModifier(prominence: prominence))
    }

    /// Contenitore "lista raggruppata": fondo dei controlli e bordo sottile, come le liste di sistema.
    func groupedContainer(cornerRadius: CGFloat = 10) -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}

extension Animation {
    /// Animazione che rispetta "Riduci movimento" (empathy-reduce-motion).
    static func adaptive(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.35)
    }
}

extension String {
    /// Sostituisce la home con "~" per percorsi più leggibili.
    func abbreviatingHome(_ home: URL) -> String {
        hasPrefix(home.path) ? "~" + dropFirst(home.path.count) : self
    }
}

extension Date {
    var relativeDescription: String {
        formatted(.relative(presentation: .named))
    }
}
