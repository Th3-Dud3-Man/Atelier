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
                contextRow
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
        .animation(.easeInOut(duration: 0.18), value: recorder.phase)
        .toolbar { toolbarContent }
        .navigationBarTitleDisplayMode(.inline)
        // Volontairement pas de mise au point à l'ouverture : arriver sur un clavier déjà
        // déplié est brutal, et masque la moitié de l'écran avant qu'on ait rien demandé.
        // Le clavier vient quand on touche le champ, ou après « Nouvelle recherche ».
        .onChange(of: router.focusRequests) { _, _ in fieldFocused = true }
        // Micro refusé, session audio indisponible, transcription échouée : sans cette alerte,
        // une touche sur le micro ne produirait rien du tout à l'écran.
        .alert(
            "Enregistrement",
            isPresented: Binding(
                get: { recorder.errorText != nil },
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

    /// Une seule ligne sous le champ : elle dit que le micro écoute, ou bien où l'on cherche.
    /// Deux informations qui ne servent jamais en même temps, et une hauteur qui ne bouge pas.
    @ViewBuilder
    private var contextRow: some View {
        if recorder.isRecording {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.atelierAccent)
                    .frame(width: 7, height: 7)
                Text(recorder.limitReached
                     ? "Limite d'une heure atteinte — touchez le micro pour transcrire"
                     : "J'écoute — \(recorder.elapsedText) — touchez le micro pour arrêter")
                    .monospacedDigit()
                Button("Annuler") { recorder.cancel() }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .foregroundStyle(Color.atelierAccent)
            .transition(.opacity)
        } else if recorder.isTranscribing {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text(recorder.stateText.isEmpty ? "Transcription…" : recorder.stateText)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .transition(.opacity)
        } else {
            sourcePicker
        }
    }

    /// Quatre cases toujours affichées pour un réglage qu'on change une fois sur dix : le
    /// choix se fait désormais dans un menu, sur une seule ligne discrète. « Automatique »
    /// reste la valeur de départ, et c'est tout l'intérêt de l'app.
    private var sourcePicker: some View {
        Menu {
            Picker("Où chercher", selection: $mode) {
                ForEach(SourceMode.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(mode.label)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Où chercher : \(mode.label)")
    }

    /// Vrai dès que le micro travaille, d'une façon ou d'une autre.
    private var micActive: Bool { recorder.isBusy }

    private var actions: some View {
        HStack(spacing: 12) {
            // Un seul geste, une seule fonction : une touche démarre la dictée, une seconde
            // l'arrête. Il n'y a plus d'appui long à distinguer, donc plus de raison d'éviter
            // un Button — et l'accessibilité y gagne.
            Image(systemName: micActive ? "stop.fill" : "mic.fill")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(micActive ? Color.atelierAccent : Color(.secondarySystemGroupedBackground))
                )
                .overlay(Circle().stroke(Color(.separator), lineWidth: micActive ? 0 : 1))
                .foregroundStyle(micActive ? Color.white : Color.atelierAccent)
                .contentShape(Circle())
                .onTapGesture { micTapped() }
                .accessibilityElement()
                .accessibilityLabel(micActive ? "Arrêter la dictée" : "Dicter")
                .accessibilityHint("Touchez pour parler, touchez à nouveau pour transcrire")
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

    /// Un seul geste : une touche démarre la dictée, une seconde l'arrête et la fait
    /// transcrire. Il n'y a plus deux fonctions à distinguer sur le même bouton.
    private func micTapped() {
        if recorder.isRecording {
            finishRecording()
        } else if !recorder.isBusy {
            startRecording()
        }
    }

    private func startRecording() {
        guard !recorder.isBusy else { return }
        // Le clavier n'a rien à faire là pendant qu'on parle.
        fieldFocused = false
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
                // Une question dictée revient droit dans le champ : c'est là qu'on la relit,
                // et un écran de plus n'apporterait rien. Un mémo, lui, mérite le sien.
                if text.count > 280 {
                    router.transcript = Router.TranscriptDraft(text: text, raw: text)
                } else {
                    question = text
                    fieldFocused = true
                }
            }
        }
    }
}
