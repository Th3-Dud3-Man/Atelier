import SwiftUI

/// Une source citée. Fichier : nom, page, extrait, ouverture dans QuickLook.
/// Web : titre, domaine, extrait, ouverture dans Safari.
struct SourceCard: View {
    let source: SourceRef
    var isHighlighted = false
    var onOpen: () -> Void

    @State private var expanded = false

    private var excerpt: String {
        let text = source.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expanded, text.count > 320 else { return text }
        return String(text.prefix(320)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(source.tag)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.atelierAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(Color.atelierAccent)

                Text(source.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let meta = metaLine {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { withAnimation { expanded.toggle() } }
            }

            HStack(spacing: 8) {
                Button(source.kind == .local ? "Ouvrir" : "Ouvrir dans Safari", action: onOpen)
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Copier la citation") {
                    UIPasteboard.general.string = citationText
                }
                .font(.footnote)
                .buttonStyle(.bordered)
                .controlSize(.small)

                if source.kind == .web, let url = source.url {
                    Button("Copier le lien") {
                        UIPasteboard.general.string = url
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Metrics.corner)
                .fill(isHighlighted ? Color.atelierAccent.opacity(0.10) : Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner)
                .stroke(isHighlighted ? Color.atelierAccent : Color(.separator), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
    }

    private var metaLine: String? {
        switch source.kind {
        case .local:
            var parts: [String] = []
            if let page = source.page { parts.append("page \(page)") }
            if let path = source.relativePath, !path.isEmpty { parts.append(path) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .web:
            var parts: [String] = []
            if let domain = source.domain { parts.append(domain) }
            if let date = source.publishedAt, !date.isEmpty { parts.append(date) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private var citationText: String {
        let quote = source.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        return "« \(quote) »\n— \(source.displayReference)"
    }
}
