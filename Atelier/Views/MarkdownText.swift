import SwiftUI

/// Rend le Markdown simple des synthèses : titres de niveau 3, listes, gras, italique,
/// et surtout les marqueurs de citation [L1] et [W2], transformés en liens touchables.
///
/// Astuce : plutôt que de bricoler une chaîne attribuée après coup, on réécrit « [L1] » en
/// lien Markdown « [L1](atelier://cite/L1) » AVANT l'analyse. SwiftUI en fait alors un vrai lien,
/// que `openURL` intercepte.
struct MarkdownText: View {
    let markdown: String
    var onCitation: (String) -> Void = { _ in }

    private enum Block: Identifiable {
        case heading(String)
        case paragraph(String)
        case bullet(String)

        var id: String {
            switch self {
            case .heading(let text): "h\(text)"
            case .paragraph(let text): "p\(text)"
            case .bullet(let text): "b\(text)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(attributed(text))
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .kerning(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                case .paragraph(let text):
                    Text(attributed(text))
                        .font(.serifBody())
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.serifBody()).foregroundStyle(.secondary)
                        Text(attributed(text))
                            .font(.serifBody())
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(Color.atelierAccent)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "atelier", url.host() == "cite" else { return .systemAction }
            onCitation(url.lastPathComponent)
            return .handled
        })
    }

    private var blocks: [Block] {
        var result: [Block] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                result.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                result.append(.bullet(String(line.dropFirst(2))))
            } else if let match = line.firstMatch(of: /^\d+[.)]\s+(.*)$/) {
                result.append(.bullet(String(match.output.1)))
            } else {
                result.append(.paragraph(line))
            }
        }
        return result
    }

    private func attributed(_ raw: String) -> AttributedString {
        let linked = raw.replacing(/\[([LW])(\d{1,2})\]/) { match in
            let tag = "\(match.output.1)\(match.output.2)"
            return "[\(tag)](atelier://cite/\(tag))"
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(raw)
    }
}
