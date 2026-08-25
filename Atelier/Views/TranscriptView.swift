import SwiftUI

/// Relecture d'une transcription avant qu'elle devienne une question.
/// Le texte est modifiable : une transcription n'est jamais envoyée telle quelle sans accord.
struct TranscriptView: View {
    let draft: Router.TranscriptDraft

    @Environment(\.dismiss) private var dismiss
    @Environment(SearchEngine.self) private var engine
    @Environment(Router.self) private var router
    @State private var text: String = ""
    @State private var mode: SourceMode = .auto

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Relisez et corrigez si nécessaire, puis lancez la recherche.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .font(.serifBody())
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Metrics.corner))
                    .frame(minHeight: 220)

                Picker("Où chercher", selection: $mode) {
                    ForEach(SourceMode.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !question.isEmpty else { return }
                    dismiss()
                    engine.start(question: question, mode: mode, rawTranscript: draft.raw)
                    router.showResults()
                } label: {
                    Text("Rechercher à partir de ce texte")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding(Metrics.margin)
            .navigationTitle("Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copier le texte")
                }
            }
            .onAppear { text = draft.text }
        }
    }
}
