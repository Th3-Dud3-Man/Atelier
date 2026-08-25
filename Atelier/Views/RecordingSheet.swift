import SwiftUI

/// Petit panneau d'enregistrement : chrono, arrêt, annulation.
struct RecordingSheet: View {
    let recorder: VoiceRecorder
    var onStop: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if recorder.isTranscribing {
                ProgressView()
                Text(recorder.stateText.isEmpty ? "Transcription en cours…" : recorder.stateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Cela prend quelques secondes pour une minute d'enregistrement.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Circle()
                    .fill(recorder.limitReached ? Color.secondary : Color.red)
                    .frame(width: 14, height: 14)
                    .opacity(recorder.isRecording && !recorder.limitReached ? 1 : 0.3)

                Text(recorder.elapsedText)
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .monospacedDigit()

                Text(recorder.limitReached
                     ? "Limite d'une heure atteinte : l'enregistrement s'est arrêté. "
                        + "Touchez Terminer pour le faire transcrire."
                     : "Parlez, puis touchez Terminer.")
                    .font(.footnote)
                    .foregroundStyle(recorder.limitReached ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)

                if let error = recorder.errorText {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button("Annuler") { recorder.cancel() }
                        .buttonStyle(.bordered)
                    Button("Terminer", action: onStop)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDragIndicator(.hidden)
    }
}
