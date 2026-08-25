import Foundation

// Types du domaine. Tous Codable : ils forment le fichier JSON unique de l'app.
// Les valeurs brutes des énumérations sont écrites sur disque — ne jamais les renommer.

enum SourceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, files, web, both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .files: "Mes fichiers"
        case .web: "Internet"
        case .both: "Les deux"
        }
    }
}

enum WebLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, deep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Standard"
        case .deep: "Approfondi"
        }
    }
}

enum SourcePriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case filesFirst, webFirst, parallel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .filesFirst: "Fichiers d'abord"
        case .webFirst: "Internet d'abord"
        case .parallel: "En parallèle"
        }
    }
}

/// Une source citée dans une synthèse. `tag` est le marqueur affiché : L1, L2… ou W1, W2…
struct SourceRef: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case local, web }

    var tag: String
    var kind: Kind
    var title: String
    var excerpt: String
    var page: Int?
    var url: String?
    var publishedAt: String?
    /// Chemin relatif dans le dossier surveillé, pour rouvrir le document avec QuickLook.
    var relativePath: String?

    var id: String { tag }

    var displayReference: String {
        switch kind {
        case .local:
            if let page { return "\(title), p. \(page)" }
            return title
        case .web:
            return url.map { "\(title) — \($0)" } ?? title
        }
    }

    var domain: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Question de suite : elle réutilise les sources déjà trouvées et peut en ajouter.
struct FollowUpTurn: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var question: String
    var answer: String = ""
    var createdAt: Date = .now
    var costUSD: Double = 0
}

/// Sortie de l'appel d'analyse. Un seul appel Gemini au début de chaque recherche.
struct QueryAnalysis: Codable, Hashable, Sendable {
    var intent: String = "other"
    /// « files », « internet » ou « both » — la décision quand la source est en Auto.
    var preferredSource: String = "both"
    var reformulated: String = ""
    var exactTerms: [String] = []
    var probableQuotes: [String] = []
    var fileQuery: String = ""
    var webQueries: [String] = []
    /// Une question d'actualité n'est jamais réutilisée automatiquement.
    var isRecentInfo: Bool = false
    var needsClarification: Bool = false
    var clarificationQuestion: String?
    /// Jugement de doublon rendu dans le même appel, pour ne pas en payer un second.
    var duplicateOfID: String?
    var duplicateRecommendation: String?
    var addedConstraints: [String] = []
    /// Noms de fichiers catalogués mais non indexés qui concernent manifestement la question.
    var candidateFiles: [String] = []

    var resolvedSource: SourceMode {
        switch preferredSource.lowercased() {
        case "files": .files
        case "internet", "web": .web
        default: .both
        }
    }
}

enum SearchStatus: String, Codable, Sendable {
    case running, done, partial, failed, canceled
}

/// Une recherche complète, telle qu'elle est conservée dans l'historique.
struct SearchRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var createdAt: Date = .now
    var question: String
    /// Transcription brute d'un enregistrement, avant correction éventuelle.
    var rawTranscript: String?
    var analysis: QueryAnalysis?
    var sourceMode: SourceMode = .auto
    /// Source réellement employée après arbitrage (jamais `.auto`).
    var effectiveSource: SourceMode = .files
    var priority: SourcePriority = .filesFirst
    var webLevel: WebLevel?
    var synthesis: String = ""
    var sources: [SourceRef] = []
    var followUps: [FollowUpTurn] = []
    var costUSD: Double = 0
    var models: [String] = []
    var status: SearchStatus = .running
    /// Renseigné quand le résultat provient d'une recherche antérieure.
    var reusedFromID: String?
    /// Lignes d'information affichées sous les résultats (« … ajouté à l'index »).
    var notes: [String] = []
    var errorMessage: String?

    var localSources: [SourceRef] { sources.filter { $0.kind == .local } }
    var webSources: [SourceRef] { sources.filter { $0.kind == .web } }
}

/// Une dépense, pour le compteur mensuel.
struct CostEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var date: Date = .now
    var provider: String
    var model: String = ""
    var usd: Double
    var tokensIn: Int = 0
    var tokensOut: Int = 0
    var searchID: String?
    var note: String = ""

    /// « 2026-08 », clé de regroupement mensuel.
    var monthKey: String { CostEntry.monthKey(for: date) }

    static func monthKey(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}
