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

enum Radius {
    static let small: CGFloat = 8
    static let card: CGFloat = 20
    static let tile: CGFloat = 16
}

enum Layout {
    /// Larghezza massima leggibile del contenuto in finestre molto larghe (empathy-readable-width).
    static let readableWidth: CGFloat = 1_080
}

// MARK: - Colori semantici

extension SafetyLevel {
    var tint: Color {
        switch self {
        case .recreatable: .green
        case .redownload: .teal
        case .analysisOnly: .secondary
        case .protected: .orange
        }
    }
}

extension CategoryID {
    var tint: Color {
        switch self {
        case .appCaches: .teal
        case .xcodeDerivedData: .blue
        case .gradleCaches: .green
        case .pnpmStore: .yellow
        case .simulators: .indigo
        case .largeDirectories: .gray
        case .whatsappMedia: .mint
        case .applicationSupport: .purple
        case .libraryCaches: .cyan
        case .libraryDeveloper: .blue
        case .xcodeArchives: .brown
        case .android: .green
        }
    }
}

extension PathClassification {
    var tint: Color { safetyLevel.tint }
}

// MARK: - Liquid Glass adattivo

/// Superficie "card": Liquid Glass su macOS 26+, materiale di sistema su macOS 15.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = Radius.card
    var tint: Color?
    var interactive = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                }
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.18)) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Capsula in vetro per badge e indicatori di stato.
struct GlassCapsule: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: .capsule)
        } else {
            content.background((tint ?? .secondary).opacity(0.14), in: .capsule)
        }
    }
}

enum ActionProminence {
    case primary
    case secondary
}

/// Stile dei pulsanti coerente con l'importanza dell'azione (taste-button),
/// con gli stili Liquid Glass su macOS 26+.
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
    func glassSurface(cornerRadius: CGFloat = Radius.card, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    func glassCapsule(tint: Color? = nil) -> some View {
        modifier(GlassCapsule(tint: tint))
    }

    func actionButtonStyle(_ prominence: ActionProminence) -> some View {
        modifier(ActionButtonStyleModifier(prominence: prominence))
    }

    /// Contenitore standard delle schermate: scroll, larghezza leggibile, margini di sistema.
    func pageLayout() -> some View {
        frame(maxWidth: Layout.readableWidth, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity)
    }
}

/// Raggruppa più superfici in vetro per rendering coerente (GlassEffectContainer su macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = Spacing.md
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Sfondo con profondità discreta per far risaltare il vetro (system-gradients: profondità, non decorazione).
struct AmbientBackground: View {
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [tint.opacity(0.10), .clear, tint.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension Animation {
    /// Animazione che rispetta "Riduci movimento" (empathy-reduce-motion).
    static func adaptive(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : .smooth(duration: 0.35)
    }
}

/// Contenitore di pagina: scorrevole nell'app, statico per le istantanee di verifica (build Debug).
struct PageContainer<Content: View>: View {
    var scrollable = true
    @ViewBuilder var content: Content

    var body: some View {
        if scrollable {
            ScrollView { content }
                .scrollIndicators(.automatic)
        } else {
            content
        }
    }
}
