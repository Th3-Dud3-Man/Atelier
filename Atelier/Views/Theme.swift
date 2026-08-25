import SwiftUI

// Identité visuelle : calme, typographique, un seul accent, rien de décoratif.

extension Color {
    /// Bleu encre. Éclairci en mode sombre pour rester lisible sur fond noir.
    static let atelierAccent = Color("AccentColor")
}

extension Font {
    /// Corps des synthèses et des citations : une serif, pour distinguer la lecture de l'interface.
    /// Bâtie sur un style de texte et non sur une taille fixe, afin de suivre les tailles
    /// dynamiques d'accessibilité.
    static func serifBody(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .serif)
    }
}

enum Metrics {
    static let margin: CGFloat = 20
    static let marginWide: CGFloat = 32
    static let corner: CGFloat = 14
    static let tapTarget: CGFloat = 44
    /// Au-delà de cette largeur, l'iPad affiche la synthèse et les sources côte à côte.
    static let twoColumnThreshold: CGFloat = 900
}

/// Petite pastille d'information : source, niveau, coût, modèle.
struct Chip: View {
    let text: String
    var emphasized = false

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(emphasized ? Color.atelierAccent.opacity(0.14) : Color(.secondarySystemFill))
            .foregroundStyle(emphasized ? Color.atelierAccent : Color.secondary)
            .clipShape(Capsule())
    }
}

/// Ligne d'état unique, en gris, au-dessus des résultats. Jamais de roue plein écran.
struct StatusLine: View {
    let text: String
    /// La roue ne tourne que pendant le travail : « Recherche arrêtée. » ou « Résultat réutilisé »
    /// sont des états terminaux, et une roue qui continue à tourner à côté les contredit.
    var isActive: Bool = true
    var showsStop: Bool = false
    var onStop: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            if !text.isEmpty {
                if isActive {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if showsStop {
                    Button("Arrêter", action: onStop)
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.atelierAccent)
                }
            }
        }
        .frame(minHeight: 20)
        .animation(.default, value: text)
    }
}

/// Carte sobre pour une erreur ou une information, avec une action facultative.
struct NoticeCard: View {
    var title: String?
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var isWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold))
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner)
                .stroke(isWarning ? Color.red.opacity(0.4) : Color(.separator), lineWidth: 1)
        )
    }
}
