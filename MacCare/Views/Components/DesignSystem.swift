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
}

// MARK: - Colori semantici

extension SafetyLevel {
    var tint: Color {
        switch self {
        case .recreatable: .green
        case .redownload: .blue
        case .analysisOnly: .secondary
        case .protected: .orange
        }
    }
}

extension CategoryID {
    /// Colore dell'icona della categoria (stile icone di Impostazioni di Sistema).
    var tint: Color {
        switch self {
        case .appCaches: .teal
        case .xcodeDerivedData: .blue
        case .gradleCaches: .green
        case .pnpmStore: .orange
        case .simulators: .indigo
        case .largeDirectories: .gray
        case .whatsappMedia: .green
        case .applicationSupport: .purple
        case .libraryCaches: .cyan
        case .libraryDeveloper: .blue
        case .xcodeArchives: .brown
        case .android: .mint
        }
    }
}

extension PathClassification {
    var tint: Color { safetyLevel.tint }
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
