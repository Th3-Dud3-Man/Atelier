import SwiftUI

/// Résultat d'une recherche : question, chips, ligne d'état, synthèse en flux, cartes sources,
/// actions de suite. En paysage large sur iPad, synthèse et sources côte à côte.
struct ResultsView: View {
    @Environment(AppStore.self) private var store
    @Environment(SearchEngine.self) private var engine
    @Environment(FolderSync.self) private var sync
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL

    @State private var followUpText = ""
    @State private var highlighted: String?
    @State private var showingFollowUpField = false
    @State private var previewedFile: PreviewTarget?
    @FocusState private var followUpFocused: Bool

    private var record: SearchRecord? { engine.record }

    var body: some View {
        GeometryReader { geometry in
            let twoColumns = geometry.size.width >= Metrics.twoColumnThreshold

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        if twoColumns {
                            HStack(alignment: .top, spacing: 32) {
                                VStack(alignment: .leading, spacing: 18) {
                                    synthesisSection
                                    followUpSection
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                sourcesSection
                                    .frame(width: min(420, geometry.size.width * 0.38))
                            }
                        } else {
                            synthesisSection
                            sourcesSection
                            followUpSection
                        }
                    }
                    .padding(.horizontal, sizeClass == .regular ? Metrics.marginWide : Metrics.margin)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: highlighted) { _, tag in
                    guard let tag else { return }
                    withAnimation { scroll.scrollTo(tag, anchor: .center) }
                }
            }
        }
        .navigationTitle("Résultat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let record, !record.synthesis.isEmpty {
                    ShareLink(item: shareText(record)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: $previewedFile) { target in
            DocumentPreview(url: target.url, page: target.page)
        }
    }

    // ── En-tête ──────────────────────────────────────────────────────

    @ViewBuilder
    private var header: some View {
        if let record {
            VStack(alignment: .leading, spacing: 10) {
                Text(record.question)
                    .font(.system(.title3, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)

                if let reformulated = record.analysis?.reformulated, !reformulated.isEmpty,
                   reformulated != record.question {
                    Text(reformulated)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                chips(for: record)

                StatusLine(
                    text: engine.statusText,
                    showsStop: engine.isRunning,
                    onStop: { engine.cancel() }
                )

                ForEach(record.notes, id: \.self) { note in
                    Label(note, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let prompt = engine.duplicatePrompt {
                    duplicateCard(prompt)
                }

                if let error = engine.errorText {
                    NoticeCard(
                        title: "Un appel a échoué",
                        message: error,
                        actionTitle: "Réessayer",
                        action: { engine.retry() },
                        isWarning: true
                    )
                }

                if record.reusedFromID != nil {
                    NoticeCard(
                        message: "Ce résultat reprend une recherche précédente : aucune nouvelle dépense.",
                        actionTitle: "Relancer",
                        action: { engine.start(question: record.question, mode: record.sourceMode) }
                    )
                }
            }
            .padding(.top, 8)
        }
    }

    private func chips(for record: SearchRecord) -> some View {
        HStack(spacing: 6) {
            Chip(text: record.effectiveSource.label, emphasized: true)
            if record.effectiveSource != .files, let level = record.webLevel {
                Chip(text: level.label)
            }
            Chip(text: CostModel.format(record.costUSD))
            ForEach(record.models, id: \.self) { model in
                Chip(text: model)
            }
        }
    }

    private func duplicateCard(_ prompt: SearchEngine.DuplicatePrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recherche très proche déjà faite")
                .font(.subheadline.weight(.semibold))
            Text("Le \(prompt.previous.createdAt.formatted(date: .long, time: .shortened)) : « \(prompt.previous.question) »")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !prompt.addedConstraints.isEmpty {
                Text("Ce que votre question ajoute : \(prompt.addedConstraints.joined(separator: ", ")).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // Le bouton recommandé par l'analyse est mis en avant par sa couleur, pas par un style
            // différent : trois boutons de même forme restent plus lisibles.
            HStack(spacing: 8) {
                Button("Réutiliser") { engine.resolveDuplicate(.reuse) }
                    .buttonStyle(.bordered)
                    .tint(prompt.recommendation == "reuse" ? Color.atelierAccent : .secondary)
                Button("Compléter") { engine.resolveDuplicate(.complete) }
                    .buttonStyle(.bordered)
                    .tint(prompt.recommendation == "complete" ? Color.atelierAccent : .secondary)
                Button("Nouvelle recherche") { engine.resolveDuplicate(.new) }
                    .buttonStyle(.bordered)
                    .tint(prompt.recommendation == "new" ? Color.atelierAccent : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Metrics.corner))
    }

    // ── Synthèse ─────────────────────────────────────────────────────

    @ViewBuilder
    private var synthesisSection: some View {
        if let record {
            VStack(alignment: .leading, spacing: 12) {
                if record.synthesis.isEmpty {
                    if engine.isRunning {
                        Text("…")
                            .font(.serifBody())
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    MarkdownText(markdown: record.synthesis) { tag in
                        highlighted = tag
                    }
                }

                if engine.isStreaming {
                    ProgressView().controlSize(.small)
                }

                ForEach(record.followUps) { turn in
                    Divider().padding(.vertical, 6)
                    Text(turn.question)
                        .font(.system(.body, design: .serif).weight(.semibold))
                    MarkdownText(markdown: turn.answer) { tag in highlighted = tag }
                }

                if let pending = engine.pendingFollowUp {
                    Divider().padding(.vertical, 6)
                    Text(pending.question)
                        .font(.system(.body, design: .serif).weight(.semibold))
                    MarkdownText(markdown: pending.text) { tag in highlighted = tag }
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // ── Sources ──────────────────────────────────────────────────────

    @ViewBuilder
    private var sourcesSection: some View {
        if let record, !record.sources.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sources")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)

                ForEach(record.sources) { source in
                    SourceCard(
                        source: source,
                        isHighlighted: highlighted == source.tag,
                        onOpen: { open(source) }
                    )
                    .id(source.tag)
                }
            }
        }
    }

    // ── Actions de suite ─────────────────────────────────────────────

    @ViewBuilder
    private var followUpSection: some View {
        if let record, record.status == .done || record.status == .partial {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if record.effectiveSource == .files && !Keychain.get(.perplexity).isEmpty {
                        Button("Compléter sur Internet") {
                            engine.start(question: record.question, mode: .web)
                        }
                        .buttonStyle(.bordered)
                    }
                    if record.effectiveSource != .files && store.settings.webLevel != .deep {
                        Button("Approfondir (\(CostModel.format(CostModel.perplexityAgent(requests: 1, prices: store.settings.prices))))") {
                            store.updateSettings { $0.webLevel = .deep }
                            engine.start(question: record.question, mode: record.effectiveSource)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Question de suite") {
                        showingFollowUpField = true
                        followUpFocused = true
                    }
                    .buttonStyle(.bordered)
                }

                if showingFollowUpField {
                    HStack(spacing: 8) {
                        TextField("Votre question de suite", text: $followUpText, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                            .focused($followUpFocused)
                            .onSubmit(sendFollowUp)
                        Button("Envoyer", action: sendFollowUp)
                            .buttonStyle(.borderedProminent)
                            .disabled(followUpText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func sendFollowUp() {
        let question = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        engine.askFollowUp(question)
        followUpText = ""
        followUpFocused = false
    }

    // ── Ouvrir une source ────────────────────────────────────────────

    private struct PreviewTarget: Identifiable {
        let id = UUID()
        let url: URL
        let page: Int?
    }

    private func open(_ source: SourceRef) {
        switch source.kind {
        case .web:
            if let url = source.url.flatMap(URL.init(string:)) {
                openURL(url)
            }
        case .local:
            // Le fichier est d'abord matérialisé : il peut être allégé par iCloud, et QuickLook
            // ne sait pas déclencher son téléchargement lui-même.
            Task {
                if let url = await sync.materialize(relativePath: source.relativePath, name: source.title) {
                    previewedFile = PreviewTarget(url: url, page: source.page)
                }
            }
        }
    }

    private func shareText(_ record: SearchRecord) -> String {
        var lines = ["# \(record.question)", "", record.synthesis, ""]
        for turn in record.followUps {
            lines.append(contentsOf: ["## \(turn.question)", "", turn.answer, ""])
        }
        if !record.sources.isEmpty {
            lines.append("## Sources")
            for source in record.sources {
                lines.append("- [\(source.tag)] \(source.displayReference)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
