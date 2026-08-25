import Foundation

/// Grille de prix datée et modifiable dans les réglages. Les valeurs viennent de la page
/// de tarification Gemini (« Last updated 2026-08-13 UTC », lue le 25/08/2026) et de la
/// documentation Perplexity. Voir NOTES_API.md.
///
/// Les chiffres réellement facturés priment toujours : quand une réponse porte un objet
/// d'usage, le coût est calculé dessus ; la grille ne sert qu'à estimer avant l'appel
/// et à combler l'absence d'usage.
struct PriceTable: Codable, Sendable, Equatable {
    /// Date de relevé des tarifs, affichée dans les réglages.
    var updatedOn: String
    /// Par million de tokens, en dollars.
    var geminiInput: [String: Double]
    var geminiOutput: [String: Double]
    /// Tarif audio en entrée, par million de tokens.
    var geminiAudioInput: [String: Double]
    /// Indexation File Search, au tarif du modèle d'embedding, par million de tokens.
    var embeddingPerMillion: Double
    /// Perplexity Search API, par millier de requêtes.
    var perplexitySearchPer1000: Double
    /// Perplexity Agent API, coût moyen par requête.
    var perplexityAgentPerRequest: Double
    /// TVA appliquée par le fournisseur, en pourcentage. Les tarifs publiés par Google et
    /// Perplexity sont hors taxes ; la facture d'un particulier en France ne l'est pas.
    /// Zéro pour un compte professionnel qui récupère la TVA.
    var vatPercent: Double = 20
    /// Conversion affichée pour les totaux, à corriger dans les réglages quand le change bouge.
    /// Les deux API facturent en dollars : l'euro n'est ici qu'une commodité de lecture.
    var usdToEur: Double = 0.92

    /// Multiplicateur appliqué à chaque coût pour obtenir le montant réellement facturé.
    var vatMultiplier: Double { 1 + max(0, vatPercent) / 100 }

    static let current = PriceTable(
        updatedOn: "2026-08-13",
        geminiInput: [
            "gemini-2.5-flash-lite": 0.10,
            "gemini-2.5-flash": 0.30,
            "gemini-3.1-flash-lite": 0.25,
            "gemini-3.5-flash-lite": 0.30,
            "gemini-3-flash-preview": 0.50,
            "gemini-3.7-flash": 0.75,
            "gemini-3.6-flash": 0.75,
            "gemini-3.5-flash": 1.50,
        ],
        geminiOutput: [
            "gemini-2.5-flash-lite": 0.40,
            "gemini-2.5-flash": 2.50,
            "gemini-3.1-flash-lite": 1.50,
            "gemini-3.5-flash-lite": 2.50,
            "gemini-3-flash-preview": 3.00,
            "gemini-3.7-flash": 3.75,
            "gemini-3.6-flash": 3.75,
            "gemini-3.5-flash": 9.00,
        ],
        geminiAudioInput: [
            "gemini-2.5-flash-lite": 0.30,
            "gemini-2.5-flash": 1.00,
            "gemini-3.1-flash-lite": 0.50,
            "gemini-3.5-flash-lite": 0.30,
        ],
        embeddingPerMillion: 0.15,
        perplexitySearchPer1000: 5.00,
        perplexityAgentPerRequest: 0.05
    )

    func input(for model: String) -> Double { geminiInput[model] ?? 0.30 }
    func output(for model: String) -> Double { geminiOutput[model] ?? 2.50 }
    func audioInput(for model: String) -> Double { geminiAudioInput[model] ?? input(for: model) * 3 }

    /// Décodage tolérant : une grille écrite par une version antérieure de l'app n'a pas les
    /// champs ajoutés depuis. Sans cela, une simple mise à jour rendrait le fichier illisible,
    /// et l'app repartirait de zéro — historique et registre compris.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let base = PriceTable.current
        updatedOn = try box.decodeIfPresent(String.self, forKey: .updatedOn) ?? base.updatedOn
        geminiInput = try box.decodeIfPresent([String: Double].self, forKey: .geminiInput) ?? base.geminiInput
        geminiOutput = try box.decodeIfPresent([String: Double].self, forKey: .geminiOutput) ?? base.geminiOutput
        geminiAudioInput = try box.decodeIfPresent([String: Double].self, forKey: .geminiAudioInput)
            ?? base.geminiAudioInput
        embeddingPerMillion = try box.decodeIfPresent(Double.self, forKey: .embeddingPerMillion)
            ?? base.embeddingPerMillion
        perplexitySearchPer1000 = try box.decodeIfPresent(Double.self, forKey: .perplexitySearchPer1000)
            ?? base.perplexitySearchPer1000
        perplexityAgentPerRequest = try box.decodeIfPresent(Double.self, forKey: .perplexityAgentPerRequest)
            ?? base.perplexityAgentPerRequest
        vatPercent = try box.decodeIfPresent(Double.self, forKey: .vatPercent) ?? 20
        usdToEur = try box.decodeIfPresent(Double.self, forKey: .usdToEur) ?? 0.92
    }

    init(
        updatedOn: String,
        geminiInput: [String: Double],
        geminiOutput: [String: Double],
        geminiAudioInput: [String: Double],
        embeddingPerMillion: Double,
        perplexitySearchPer1000: Double,
        perplexityAgentPerRequest: Double,
        vatPercent: Double = 20,
        usdToEur: Double = 0.92
    ) {
        self.updatedOn = updatedOn
        self.geminiInput = geminiInput
        self.geminiOutput = geminiOutput
        self.geminiAudioInput = geminiAudioInput
        self.embeddingPerMillion = embeddingPerMillion
        self.perplexitySearchPer1000 = perplexitySearchPer1000
        self.perplexityAgentPerRequest = perplexityAgentPerRequest
        self.vatPercent = vatPercent
        self.usdToEur = usdToEur
    }
}

/// Compteurs d'usage renvoyés par Gemini (`usageMetadata`).
struct TokenUsage: Codable, Sendable, Equatable {
    var promptTokenCount: Int?
    var candidatesTokenCount: Int?
    var totalTokenCount: Int?
    var thoughtsTokenCount: Int?
    var toolUsePromptTokenCount: Int?
    var cachedContentTokenCount: Int?

    var inputTokens: Int { (promptTokenCount ?? 0) + (toolUsePromptTokenCount ?? 0) }
    /// Les tokens de réflexion sont facturés au tarif de sortie.
    var outputTokens: Int { (candidatesTokenCount ?? 0) + (thoughtsTokenCount ?? 0) }
}

enum CostModel {
    /// Coût d'un appel Gemini à partir de l'usage réellement renvoyé.
    static func gemini(model: String, usage: TokenUsage, prices: PriceTable) -> Double {
        let input = Double(usage.inputTokens) * prices.input(for: model)
        let output = Double(usage.outputTokens) * prices.output(for: model)
        return (input + output) / 1_000_000 * prices.vatMultiplier
    }

    /// Coût d'une transcription : l'audio est facturé à son propre tarif d'entrée.
    static func geminiAudio(model: String, usage: TokenUsage, prices: PriceTable) -> Double {
        let input = Double(usage.inputTokens) * prices.audioInput(for: model)
        let output = Double(usage.outputTokens) * prices.output(for: model)
        return (input + output) / 1_000_000 * prices.vatMultiplier
    }

    /// Indexation d'un fichier : environ 4 caractères par token, au tarif d'embedding.
    static func indexing(bytes: Int64, prices: PriceTable) -> Double {
        let tokens = Double(bytes) / 4
        return tokens * prices.embeddingPerMillion / 1_000_000 * prices.vatMultiplier
    }

    static func perplexitySearch(requests: Int, prices: PriceTable) -> Double {
        Double(requests) * prices.perplexitySearchPer1000 / 1000 * prices.vatMultiplier
    }

    static func perplexityAgent(requests: Int, prices: PriceTable) -> Double {
        Double(requests) * prices.perplexityAgentPerRequest * prices.vatMultiplier
    }

    /// Estimation affichée AVANT de lancer, donc sans usage réel.
    /// Ordres de grandeur : analyse ≈ 0,0005 $, recherche fichiers ≈ 0,003 $, synthèse ≈ 0,002 $.
    static func estimate(source: SourceMode, level: WebLevel, prices: PriceTable) -> Double {
        // Ces trois montants sont hors taxes, comme les tarifs publiés ; la TVA est appliquée
        // à la fin, une seule fois — les appels Perplexity, eux, la portent déjà.
        var total = 0.0005
        if source == .files || source == .both || source == .auto { total += 0.005 }
        if source == .web || source == .both || source == .auto { total += 0.002 }
        total *= prices.vatMultiplier
        if source == .web || source == .both || source == .auto {
            total += level == .deep
                ? perplexityAgent(requests: 1, prices: prices)
                : perplexitySearch(requests: 1, prices: prices)
        }
        return total
    }

    /// « 0,014 $ » ou « gratuit » — jamais « 0,00 $ », qui donnerait l'impression que rien n'est compté.
    /// Le montant est celui réellement facturé, TVA comprise.
    static func format(_ usd: Double) -> String {
        guard usd > 0 else { return "gratuit" }
        let decimals = usd < 0.01 ? 4 : 2
        let text = String(format: "%.\(decimals)f", usd).replacingOccurrences(of: ".", with: ",")
        return "\(text) $"
    }

    /// Les deux API facturent en dollars, mais un budget mensuel se pense en euros.
    /// Employé pour les totaux et le plafond, jamais pour le coût d'un appel isolé.
    static func formatEUR(_ usd: Double, prices: PriceTable) -> String {
        let euros = usd * max(0, prices.usdToEur)
        guard euros > 0 else { return "0 €" }
        let text = String(format: "%.2f", euros).replacingOccurrences(of: ".", with: ",")
        return "\(text) €"
    }
}
