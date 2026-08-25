import SwiftUI

/// Écran d'accueil : une barre de recherche, un micro, un sélecteur de source,
/// un bouton d'historique. Rien d'autre.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(SearchEngine.self) private var engine
    @Environment(FolderSync.self) private var sync
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network
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
        sizeClass == .regular ? Metrics.marginWide : Metrics.margin
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
                        switch status.destination {
                        case .files: router.showingFiles = true
                        case .settings: router.showingSettings = true
                        case .none: break
                        }
                    } label: {
                        Text(status.text)
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
        .sheet(isPresented: Binding(get: { recorder.isBusy },
                                    set: { if !$0 { recorder.cancel() } })) {
            RecordingSheet(recorder: recorder, onStop: finishRecording)
                .presentationDetents([.height(300)])
                .interactiveDismissDisabled(recorder.isTranscribing)
        }
        // Micro refusé, session audio indisponible, transcription échouée : ces trois échecs
        // laissent le panneau fermé, ou le referment en emportant leur message. Sans cette
        // alerte, un appui long sur le micro ne produirait rien du tout à l'écran.
        .alert(
            "Enregistrement",
            isPresented: Binding(
                get: { recorder.errorText != nil && !recorder.isBusy },
                set: { if !$0 { recorder.dismissError() } }
            )
        ) {
            Button("Fermer") { recorder.dismissError() }
        } message: {
            Text(recorder.errorText ?? "")
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner)
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
            // Volontairement pas un Button : un Button plus un appui long déclencherait les deux,
            // et l'enregistrement s'arrêterait au relâchement du doigt. Les deux gestes posés
            // séparément s'excluent proprement — l'appui long l'emporte s'il est tenu.
            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(recorder.isRecording ? Color.atelierAccent : Color(.secondarySystemGroupedBackground))
                )
                .overlay(Circle().stroke(Color(.separator), lineWidth: recorder.isRecording ? 0 : 1))
                .foregroundStyle(recorder.isRecording ? Color.white : Color.atelierAccent)
                .contentShape(Circle())
                .onTapGesture { micTapped() }
                .onLongPressGesture(minimumDuration: 0.4) { startRecording() }
                .accessibilityElement()
                .accessibilityLabel(recorder.isRecording ? "Arrêter l'enregistrement" : "Dicter ou enregistrer")
                .accessibilityHint("Touchez pour dicter, maintenez pour enregistrer un mémo")
                .accessibilityAddTraits(.isButton)

            Button(action: launch) {
                Text("Rechercher")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmed.isEmpty || !network.isOnline)
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

    /// Une seule pastille à la fois, et elle mène là où l'on peut agir.
    private struct StatusPill {
        enum Destination { case files, settings, none }
        var text: String
        var destination: Destination
    }

    private var statusMessage: StatusPill? {
        if !network.isOnline {
            return StatusPill(
                text: "Hors ligne — l'historique reste consultable",
                destination: .none
            )
        }
        if Keychain.get(.gemini).isEmpty {
            return StatusPill(text: "Ajouter votre clé Gemini dans les réglages", destination: .settings)
        }
        if store.capReached {
            return StatusPill(
                text: "Plafond du mois atteint "
                    + "(\(CostModel.formatEUR(store.settings.monthlyCapUSD, prices: store.settings.prices)))",
                destination: .settings
            )
        }
        if let progress = sync.progressText {
            return StatusPill(text: progress, destination: .files)
        }
        if store.folders.isEmpty {
            return StatusPill(text: "Choisir un dossier iCloud à indexer", destination: .files)
        }
        if store.indexedFiles.isEmpty {
            return StatusPill(text: "Aucun fichier indexé pour l'instant", destination: .files)
        }
        return nil
    }

    // ── Actions ──────────────────────────────────────────────────────

    private func launch() {
        guard !trimmed.isEmpty, network.isOnline else { return }
        // Clé absente : plutôt qu'un message d'erreur, on ouvre directement la saisie.
        guard Keychain.has(.gemini) else {
            router.showingSettings = true
            return
        }
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
