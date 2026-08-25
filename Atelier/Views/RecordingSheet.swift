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
                    .fill(Color.red)
                    .frame(width: 14, height: 14)
                    .opacity(recorder.isRecording ? 1 : 0.3)

                Text(recorder.elapsedText)
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .monospacedDigit()

                Text("Parlez, puis touchez Terminer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

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
