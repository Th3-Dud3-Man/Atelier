import AVFoundation
import Observation
import Speech

/// Dictée en direct, sur l'appareil.
///
/// Le micro du clavier iOS fait le même travail, mais il oblige à ouvrir le clavier, il
/// s'arrête au bout de quelques secondes de silence, et rien dans l'app ne sait qu'il tourne.
/// Ici le texte arrive au fil de la parole, dans le champ de recherche, et l'app en garde
/// la maîtrise : on voit qu'elle écoute, on l'arrête quand on veut.
///
/// **Tout reste sur l'appareil.** `requiresOnDeviceRecognition` est exigé, jamais négocié :
/// si la reconnaissance hors ligne n'est pas disponible pour le français, on le dit et on
/// renvoie vers le mémo long, plutôt que d'envoyer discrètement la voix aux serveurs d'Apple.
///
/// C'est gratuit, et cela ne remplace pas le mémo long : au-delà d'une question, un
/// enregistrement transcrit par Gemini reste meilleur sur la ponctuation et les noms propres.
@MainActor
@Observable
final class LiveDictation {

    private(set) var isListening = false
    /// Texte reconnu jusqu'ici, remanié à chaque mot tant que la phrase n'est pas figée.
    private(set) var text = ""
    private(set) var errorText: String?

    /// Le fil audio dépose ses tampons ici. `SFSpeechAudioBufferRecognitionRequest` n'est pas
    /// `Sendable`, et le bloc d'écoute l'est : cette boîte assume la traversée. C'est sûr —
    /// `append` est précisément prévu pour être appelé depuis le rappel audio, et l'objet
    /// n'est plus touché ailleurs une fois l'écoute lancée.
    private final class BufferSink: @unchecked Sendable {
        private let request: SFSpeechAudioBufferRecognitionRequest
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
        func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    // ── Écoute ───────────────────────────────────────────────────────

    func start(startingFrom existing: String = "") {
        guard !isListening else { return }
        errorText = nil
        prefix = existing.isEmpty ? "" : existing + " "
        text = existing

        Task { [weak self] in
            guard let self else { return }
            guard await Self.authorize() else {
                self.errorText = "L'accès au micro ou à la reconnaissance vocale est refusé. "
                    + "Vous pouvez l'autoriser dans Réglages › L'Atelier."
                return
            }
            self.begin()
        }
    }

    /// Texte déjà présent dans le champ avant la dictée : la reconnaissance repart de zéro,
    /// mais on ne veut pas effacer ce qui était écrit.
    private var prefix = ""

    private func begin() {
        // Le français d'abord, la langue du système ensuite : un appareil réglé autrement
        // n'a pas à se voir imposer une reconnaissance française.
        let locale = Locale.current.language.languageCode?.identifier == "fr"
            ? Locale.current
            : Locale(identifier: "fr_FR")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            errorText = "La reconnaissance vocale n'est pas disponible sur cet appareil. "
                + "Maintenez le micro pour enregistrer un mémo : il sera transcrit ensuite."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            errorText = "La reconnaissance hors ligne n'est pas installée pour cette langue, et "
                + "l'app n'enverra pas votre voix ailleurs. Réglages › Général › Clavier › "
                + "Dictée pour la télécharger — ou maintenez le micro pour un mémo transcrit."
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorText = "Le micro n'a pas pu être activé : \(error.localizedDescription)"
            return
        }

        let sink = BufferSink(request)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Poser une écoute sur un format à zéro canal fait tomber l'app : cela arrive quand
        // le micro est accaparé par un appel ou une autre app.
        guard format.channelCount > 0 else {
            errorText = "Le micro est occupé par une autre application. Réessayez dans un instant."
            cleanUp()
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            errorText = "Le micro n'a pas pu démarrer : \(error.localizedDescription)"
            cleanUp()
            return
        }

        // Le rappel arrive sur un fil quelconque : on en extrait tout de suite des valeurs
        // simples, seules capables de traverser vers l'acteur principal.
        abandoned = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in
                // On accepte encore les résultats après l'arrêt : le dernier, celui qui pose
                // la ponctuation, arrive justement après `endAudio()`. Seul un abandon franc
                // les fait taire.
                guard let self, !self.abandoned else { return }
                if let transcript, !transcript.isEmpty { self.text = self.prefix + transcript }
                if isFinal {
                    self.stop()
                } else if let failure, transcript == nil {
                    self.finishOnError(failure)
                }
            }
        }
        isListening = true
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        request?.endAudio()
        task?.finish()
        cleanUp()
    }

    /// Arrêt sans garder le texte : la dictée est abandonnée.
    func cancel() {
        guard isListening else { return }
        isListening = false
        abandoned = true
        task?.cancel()
        cleanUp()
        text = prefix.trimmingCharacters(in: .whitespaces)
    }

    /// Vrai quand la dictée a été abandonnée : les résultats en vol sont alors ignorés.
    private var abandoned = false

    func dismissError() {
        errorText = nil
    }

    private func finishOnError(_ message: String) {
        isListening = false
        cleanUp()
        // Une reconnaissance qui s'arrête sans un mot n'est pas une panne à afficher en rouge :
        // le plus souvent, personne n'a parlé.
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            errorText = "Rien n'a été entendu. Réessayez en parlant un peu plus près du micro."
        }
    }

    private func cleanUp() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // ── Autorisations ────────────────────────────────────────────────

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
