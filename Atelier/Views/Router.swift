import Observation
import SwiftUI

/// Navigation et feuilles modales. Un seul objet, observé par toutes les vues.
@MainActor
@Observable
final class Router {
    /// Sur iPhone, la pile de navigation ; vide = accueil.
    var path: [Screen] = []
    var showingHistory = false
    var showingFiles = false
    var showingSettings = false
    /// Incrémenté par ⌘K pour redonner le focus au champ de recherche.
    var focusRequests = 0
    /// Transcription en attente de relecture avant de devenir une question.
    var transcript: TranscriptDraft?

    enum Screen: Hashable {
        case results
    }

    struct TranscriptDraft: Identifiable, Equatable {
        var id = UUID()
        var text: String
        var raw: String
    }

    func showResults() {
        if path.last != .results {
            path.append(.results)
        }
    }

    func backToHome() {
        path.removeAll()
    }

    func requestFocus() {
        focusRequests += 1
    }
}
