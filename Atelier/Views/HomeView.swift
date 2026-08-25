import SwiftUI

/// Écran d'accueil : une barre de recherche, un micro, un sélecteur de source,
/// un bouton d'historique. Rien d'autre.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(SearchEngine.self) private var engine
    @Environment(FolderSync.self) private var sync
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var question = ""
    @State private var mode: SourceMode = .auto
    @State private var recorder = VoiceRecorder()
    @State private var showingDictationHint = false
    @FocusState private var fieldFocused: Bool

    private var trimmed: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var margin: CGFloat {
        sizeClass == .regular ? Layout.marginWide : Layout.margin
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()

                if !fieldFocused {
                    Text("L'Atelier")
                        .font(.system(.title3, design: .serif))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }

                searchField
                sourcePicker
                actions

                if let status = statusMessage {
                    Button {
                        router.showingFiles = true
                    } label: {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color(.secondarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
                Spacer()
            }
            .frame(maxWidth: 660)
            .padding(.horizontal, margin)
        }
        .animation(.easeInOut(duration: 0.18), value: fieldFocused)
        .toolbar { toolbarContent }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { fieldFocused = true }
        .onChange(of: router.focusRequests) { _, _ in fieldFocused = true }
        .alert("La dictée du clavier", isPresented: $showingDictationHint) {
            Button("Compris") {
                store.updateSettings { $0.dictationHintShown = true }
                fieldFocused = true
            }
        } message: {
            Text("Pour dicter une question, touchez le micro du clavier iOS, en bas à droite : "
                 + "la reconnaissance est locale, gratuite et excellente en français.\n\n"
                 + "Le bouton micro de l'app, lui, sert aux enregistrements longs : maintenez-le "
                 + "pour enregistrer un mémo, qui sera transcrit puis relu avant de devenir une question.")
        }
        .sheet(isPresented: Binding(get: { recorder.isRecording || recorder.isTranscribing },
                                    set: { if !$0 { recorder.cancel() } })) {
            RecordingSheet(recorder: recorder)
                .presentationDetents([.height(260)])
                .interactiveDismissDisabled(recorder.isTranscribing)
        }
    }

    // ── Éléments ─────────────────────────────────────────────────────

    private var searchField: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Posez votre question, ou collez un texte…", text: $question, axis: .vertical)
                .lineLimit(1...8)
                .font(.body)
                .focused($fieldFocused)
                .submitLabel(.search)
                .onSubmit(launch)

            if !question.isEmpty {
                Button {
                    question = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Effacer le texte")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Layout.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.corner)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }

    private var sourcePicker: some View {
        Picker("Où chercher", selection: $mode) {
            ForEach(SourceMode.allCases) { source in
                Text(source.label).tag(source)
            }
        }
        .pickerStyle(.segmented)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                micTapped()
            } label: {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 52, height: 52)
                    .background(
                        Circle()
                            .fill(recorder.isRecording ? Color.atelierAccent : Color(.secondarySystemGroupedBackground))
                    )
                    .overlay(Circle().stroke(Color(.separator), lineWidth: recorder.isRecording ? 0 : 1))
                    .foregroundStyle(recorder.isRecording ? Color.white : Color.atelierAccent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording ? "Arrêter l'enregistrement" : "Dicter ou enregistrer")
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in startRecording() }
            )

            Button(action: launch) {
                Text("Rechercher")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmed.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if sizeClass != .regular {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    router.showingHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Historique")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                router.showingFiles = true
            } label: {
                Image(systemName: "folder")
            }
            .accessibilityLabel("Mes fichiers")
        }
    }

    // ── Pastille d'état : une seule à la fois ────────────────────────

    private var statusMessage: String? {
        if let progress = sync.progressText { return progress }
        if store.capReached {
            return "Plafond du mois atteint (\(CostModel.format(store.settings.monthlyCapUSD)))"
        }
        if store.folders.isEmpty {
            return "Choisir un dossier iCloud à indexer"
        }
        if store.indexedFiles.isEmpty {
            return "Aucun fichier indexé pour l'instant"
        }
        if Keychain.get(.gemini).isEmpty {
            return "Ajouter votre clé Gemini dans les réglages"
        }
        return nil
    }

    // ── Actions ──────────────────────────────────────────────────────

    private func launch() {
        guard !trimmed.isEmpty else { return }
        engine.start(question: trimmed, mode: mode)
        router.showResults()
        fieldFocused = false
        question = ""
    }

    private func micTapped() {
        if recorder.isRecording {
            finishRecording()
        } else if !store.settings.dictationHintShown {
            showingDictationHint = true
        } else {
            fieldFocused = true
        }
    }

    private func startRecording() {
        guard !recorder.isRecording else { return }
        Task { await recorder.start() }
    }

    private func finishRecording() {
        Task {
            guard let audio = await recorder.stop() else { return }
            let client = GeminiClient(
                apiKey: Keychain.get(.gemini),
                mainModel: store.settings.mainModel,
                lightModel: store.settings.lightModel,
                storeName: store.settings.storeName
            )
            await recorder.transcribe(audio: audio, using: client, store: store) { text in
                router.transcript = Router.TranscriptDraft(text: text, raw: text)
            }
        }
    }
}
