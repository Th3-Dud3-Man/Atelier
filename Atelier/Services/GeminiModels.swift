import Foundation

/// Identifiants de modèles relevés dans la documentation officielle le 25/08/2026.
/// Voir NOTES_API.md §1.2 : seuls sept modèles savent utiliser l'outil File Search,
/// et les Flash-Lite 2.5 — les moins chers — n'en font pas partie.
enum GeminiModels {

    /// Un modèle tel que Google le décrit, relevé par `GeminiClient.listModels()`.
    /// Déclaré ici, et non dans le client, pour que les réglages puissent se relire sans
    /// rien connaître de la couche réseau.
    struct Info: Sendable, Hashable, Codable, Identifiable {
        /// Identifiant court, sans le préfixe `models/` : c'est lui qui part dans les appels.
        var id: String
        var displayName: String
        var supportedMethods: [String]

        var canGenerate: Bool { supportedMethods.contains("generateContent") }
    }

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

    /// Choisit le meilleur modèle disponible pour la recherche dans les fichiers.
    ///
    /// Les listes ci-dessus sont un ordre de préférence, pas une vérité : le catalogue de
    /// Google bouge, et un identifiant écrit dans le code finit toujours par renvoyer 404.
    /// On part donc de ce que la clé peut réellement employer, et on retient le premier
    /// modèle connu qui s'y trouve — à défaut, le premier « flash » venu, puis n'importe
    /// quel modèle capable de générer.
    static func bestMain(from available: [String]) -> String? {
        pick(preferring: fileSearchCapable, from: available)
    }

    /// Idem pour les tâches annexes : analyse, doublon, transcription.
    static func bestLight(from available: [String]) -> String? {
        pick(preferring: lightCapable, from: available) ?? bestMain(from: available)
    }

    private static func pick(preferring order: [String], from available: [String]) -> String? {
        let set = Set(available)
        if let known = order.first(where: { set.contains($0) }) { return known }

        // Aucun modèle connu : on se rabat sur le nom. « lite » d'abord, moins cher ;
        // les aperçus et les modèles expérimentaux en dernier, ils disparaissent sans prévenir.
        func rank(_ model: String) -> Int {
            var score = 0
            if model.contains("flash") { score -= 4 }
            if model.contains("lite") { score -= 2 }
            if model.contains("preview") || model.contains("exp") { score += 3 }
            return score
        }
        return available
            .filter { $0.contains("gemini") && !$0.contains("embedding") && !$0.contains("aqa") }
            .sorted { (rank($0), $0) < (rank($1), $1) }
            .first
    }

    /// `thinkingLevel` n'existe que sur les modèles Gemini 3 ; l'envoyer ailleurs déclenche une erreur.
    static func acceptsThinkingLevel(_ model: String) -> Bool {
        model.hasPrefix("gemini-3")
    }
}
