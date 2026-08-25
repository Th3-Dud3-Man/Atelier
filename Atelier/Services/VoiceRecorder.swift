import AVFoundation
import Observation

/// Enregistrement long, transcrit par Gemini.
///
/// La dictée du clavier iOS reste le chemin principal pour une question courte : elle est locale,
/// gratuite et excellente en français, et ne demande aucune ligne de code. Ceci sert aux mémos.
///
/// Format : **WAV 16 kHz mono**. Gemini n'accepte pas `audio/mp4`, le format naturel d'iOS
/// (voir NOTES_API.md), et il ramène de toute façon tout l'audio à 16 kbps mono : enregistrer
/// plus riche ne ferait que grossir l'envoi sans rien améliorer.
@MainActor
@Observable
final class VoiceRecorder {

    private(set) var isRecording = false
    private(set) var isTranscribing = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorText: String?
    /// Étape courante pendant la transcription, pour la feuille d'enregistrement.
    private(set) var stateText: String = ""

    private var recorder: AVAudioRecorder?
    private var timer: Task<Void, Never>?
    private var fileURL: URL?

    /// Un mémo de plus d'une heure n'a pas de sens ici, et protège d'un enregistrement oublié.
    static let maximumDuration: TimeInterval = 60 * 60

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // ── Enregistrement ───────────────────────────────────────────────

    func start() async {
        errorText = nil
        guard await requestPermission() else {
            errorText = "L'accès au micro est refusé. Vous pouvez l'autoriser dans Réglages › L'Atelier."
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            errorText = "Le micro n'a pas pu être activé : \(error.localizedDescription)"
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memo-\(Int(Date.now.timeIntervalSince1970)).wav")

        // LinearPCM 16 kHz mono : exactement ce que Gemini attend, sans conversion.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                errorText = "L'enregistrement n'a pas pu démarrer."
                return
            }
            self.recorder = recorder
            self.fileURL = url
            isRecording = true
            elapsed = 0
            startTimer()
        } catch {
            errorText = "L'enregistrement n'a pas pu démarrer : \(error.localizedDescription)"
        }
    }

    /// Arrête et renvoie les octets enregistrés.
    func stop() async -> Data? {
        timer?.cancel()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = fileURL else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try? Data(contentsOf: url)
    }

    func cancel() {
        timer?.cancel()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        isTranscribing = false
        stateText = ""
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTimer() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRecording else { return }
                self.elapsed += 1
                if self.elapsed >= Self.maximumDuration {
                    _ = await self.stop()
                    return
                }
            }
        }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // ── Transcription ────────────────────────────────────────────────

    /// Envoie l'enregistrement à Gemini et rend le texte, sans le transformer en question :
    /// il passe d'abord par l'écran de relecture.
    func transcribe(
        audio: Data,
        using client: GeminiClient,
        store: AppStore,
        onDone: @escaping (String) -> Void
    ) async {
        isTranscribing = true
        stateText = "Transcription en cours…"
        defer {
            isTranscribing = false
            stateText = ""
        }

        do {
            let reply = try await client.transcribe(audio: audio, mimeType: "audio/wav")
            store.record(CostEntry(
                provider: "Gemini",
                model: reply.model,
                usd: CostModel.geminiAudio(model: reply.model, usage: reply.usage, prices: store.settings.prices),
                tokensIn: reply.usage.inputTokens,
                tokensOut: reply.usage.outputTokens,
                note: "transcription"
            ))
            let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                errorText = "L'enregistrement n'a produit aucun texte."
                return
            }
            onDone(text)
        } catch {
            errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
