import Foundation

/// Identifiants de modèles relevés dans la documentation officielle le 25/08/2026.
/// Voir NOTES_API.md §1.2 : seuls sept modèles savent utiliser l'outil File Search,
/// et les Flash-Lite 2.5 — les moins chers — n'en font pas partie.
enum GeminiModels {
    /// Recherche dans les fichiers et rédaction de la synthèse.
    /// Le moins cher des modèles compatibles File Search : 0,25 $ / 1,50 $ par million de tokens.
    static let defaultMain = "gemini-3.1-flash-lite"

    /// Analyse, jugement de doublon, transcription. Le moins cher du catalogue,
    /// et le seul dont la réflexion est désactivée par défaut : 0,10 $ / 0,40 $.
    static let defaultLight = "gemini-2.5-flash-lite"

    /// Liste exhaustive des modèles compatibles File Search, dans l'ordre du moins cher au plus cher.
    static let fileSearchCapable = [
        "gemini-3.1-flash-lite",
        "gemini-3.5-flash-lite",
        "gemini-3-flash-preview",
        "gemini-3.7-flash",
        "gemini-3.6-flash",
        "gemini-3.5-flash",
        "gemini-3.1-pro-preview",
    ]

    /// Modèles économiques utilisables pour les tâches annexes.
    static let lightCapable = [
        "gemini-2.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemini-2.5-flash",
    ]

    static func supportsFileSearch(_ model: String) -> Bool {
        fileSearchCapable.contains(model)
    }

    /// `thinkingLevel` n'existe que sur les modèles Gemini 3 ; l'envoyer ailleurs déclenche une erreur.
    static func acceptsThinkingLevel(_ model: String) -> Bool {
        model.hasPrefix("gemini-3")
    }
}
