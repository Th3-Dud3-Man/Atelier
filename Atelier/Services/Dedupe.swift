import Foundation

/// Anti-dépense, première étape : gratuite et instantanée, avant tout appel payant.
/// Deux formulations différentes de la même demande doivent produire la même empreinte.
enum Dedupe {
    /// Mots vides français, y compris les tournures d'adresse (« trouve-moi », « peux-tu »)
    /// qui n'apportent rien au sens de la question.
    private static let stopwords: Set<String> = [
        "le", "la", "les", "un", "une", "des", "du", "de", "d", "l", "et", "ou", "a", "au", "aux",
        "en", "dans", "sur", "sous", "pour", "par", "avec", "sans", "que", "qui", "quoi", "dont",
        "est", "sont", "ete", "etre", "ce", "cet", "cette", "ces", "se", "sa", "son", "ses",
        "mes", "mon", "ma", "me", "moi", "je", "tu", "il", "elle", "on", "nous", "vous", "ils",
        "elles", "y", "n", "ne", "pas", "plus", "peux", "peut", "s", "c", "j", "m", "t",
        "trouve", "trouver", "retrouve", "retrouver", "cherche", "chercher", "montre", "montrer",
        "donne", "donner", "dis", "dire", "parle", "parlent", "parlant", "quel", "quelle",
        "quels", "quelles", "comment", "pourquoi", "ou", "quand", "est-ce",
    ]

    /// Minuscules, sans accents, sans ponctuation, sans mots vides, mots triés.
    static func fingerprint(_ text: String) -> String {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "fr_FR")
        )
        var cleaned = ""
        cleaned.reserveCapacity(folded.count)
        for character in folded {
            cleaned.append(character.isLetter || character.isNumber ? character : " ")
        }
        let words = cleaned
            .split(separator: " ")
            .map(String.init)
            .filter { !stopwords.contains($0) }
        return words.sorted().joined(separator: " ")
    }

    static let freshWindow: TimeInterval = 7 * 24 * 3600

    struct ExactMatch: Sendable {
        var record: SearchRecord
        /// Moins de sept jours : le résultat est réutilisé directement.
        var isFresh: Bool
    }

    /// Une question strictement équivalente a-t-elle déjà reçu une réponse ?
    static func exactMatch(for question: String, in searches: [SearchRecord]) -> ExactMatch? {
        let target = fingerprint(question)
        guard !target.isEmpty else { return nil }
        for record in searches where record.status == .done && !record.synthesis.isEmpty {
            guard fingerprint(record.question) == target else { continue }
            return ExactMatch(record: record, isFresh: Date.now.timeIntervalSince(record.createdAt) < freshWindow)
        }
        return nil
    }
}
