import Foundation

/// Client Perplexity. Deux niveaux, deux endpoints :
/// — Standard : `POST /search`, résultats bruts, jusqu'à 5 requêtes en un appel,
///   facturé **0,005 $ par appel** quel que soit le nombre de requêtes. La synthèse est écrite par Gemini.
/// — Approfondi : `POST /v1/agent`, l'agent fait lui-même plusieurs tours de recherche.
///
/// L'ancienne API Sonar (`/chat/completions`), dépréciée au 27/09/2026, n'est pas utilisée.
/// Schémas relevés dans la documentation officielle le 25/08/2026, voir NOTES_API.md §4.
struct PerplexityClient: Sendable {
    static let base = "https://api.perplexity.ai"

    var apiKey: String

    /// Un résultat web, quel que soit le niveau utilisé.
    struct Result: Sendable, Hashable {
        var title: String
        var url: String
        var snippet: String
        var date: String?
        var lastUpdated: String?
    }

    struct SearchOutcome: Sendable {
        var results: [Result]
        /// Réponse rédigée par l'agent, seulement au niveau Approfondi.
        var agentAnswer: String = ""
        /// Coût réel quand l'API le renvoie ; sinon l'estimation exacte du tarif Search.
        var costUSD: Double
        var costIsMeasured: Bool
    }

    private func request(path: String, body: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    // ── Niveau Standard : Search API ─────────────────────────────────

    private struct SearchResponse: Decodable {
        struct Page: Decodable {
            var title: String
            var url: String
            var snippet: String
            var date: String?
            var last_updated: String?
        }
        var results: [Page]?
        var id: String?
    }

    /// Jusqu'à 5 requêtes en un seul appel. `search_context_size` reste à sa valeur par défaut
    /// (`high`) : les extraits renvoyés font alors plusieurs milliers de caractères, ce qui suffit
    /// à rédiger une synthèse sans aller chercher les pages nous-mêmes.
    func search(
        queries: [String],
        maxResults: Int = 8,
        recency: String? = nil,
        prices: PriceTable
    ) async throws -> SearchOutcome {
        let trimmed = Array(queries.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(5))
        guard !trimmed.isEmpty else {
            return SearchOutcome(results: [], costUSD: 0, costIsMeasured: true)
        }

        var payload: [String: Any] = [
            "query": trimmed.count == 1 ? trimmed[0] : trimmed,
            "max_results": max(1, min(maxResults, 20)),
        ]
        if let recency { payload["search_recency_filter"] = recency }

        let (data, _) = try await HTTP.send(
            request(path: "/search", body: try JSONSerialization.data(withJSONObject: payload)),
            provider: "Perplexity"
        )
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        let results = (decoded.results ?? []).map {
            Result(title: $0.title, url: $0.url, snippet: $0.snippet, date: $0.date, lastUpdated: $0.last_updated)
        }
        // Tarif documenté : 5 $ pour mille appels, indépendamment du nombre de requêtes.
        return SearchOutcome(
            results: results,
            costUSD: CostModel.perplexitySearch(requests: 1, prices: prices),
            costIsMeasured: true
        )
    }

    // ── Niveau Approfondi : Agent API ────────────────────────────────

    private struct AgentResponse: Decodable {
        struct OutputItem: Decodable {
            struct SearchResult: Decodable {
                var id: Int?
                var url: String?
                var title: String?
                var snippet: String?
                var date: String?
                var last_updated: String?
            }
            struct ContentPart: Decodable {
                var type: String?
                var text: String?
            }
            var type: String?
            var results: [SearchResult]?
            var content: [ContentPart]?
        }
        struct Usage: Decodable {
            struct Cost: Decodable {
                var total_cost: Double?
            }
            var input_tokens: Int?
            var output_tokens: Int?
            var cost: Cost?
        }
        var status: String?
        var output: [OutputItem]?
        var usage: Usage?
    }

    /// Recherche approfondie. Le préréglage porte le modèle, le nombre de tours et les outils ;
    /// « medium » correspond à l'ancien « deep research ».
    func deepSearch(question: String, preset: String = "medium", prices: PriceTable) async throws -> SearchOutcome {
        let payload: [String: Any] = [
            "preset": preset,
            "input": question,
            "language_preference": "fr",
        ]
        let (data, _) = try await HTTP.send(
            request(path: "/v1/agent", body: try JSONSerialization.data(withJSONObject: payload)),
            provider: "Perplexity"
        )
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: data)

        var results: [Result] = []
        var answer = ""
        for item in decoded.output ?? [] {
            switch item.type {
            case "search_results":
                for entry in item.results ?? [] {
                    guard let url = entry.url else { continue }
                    results.append(Result(
                        title: entry.title ?? url,
                        url: url,
                        snippet: entry.snippet ?? "",
                        date: entry.date,
                        lastUpdated: entry.last_updated
                    ))
                }
            case "message":
                // `output_text` est une commodité des SDK : en HTTP brut il faut parcourir content[].
                answer += (item.content ?? [])
                    .filter { $0.type == "output_text" }
                    .compactMap(\.text)
                    .joined()
            default:
                continue
            }
        }

        let measured = decoded.usage?.cost?.total_cost
        return SearchOutcome(
            results: results,
            agentAnswer: answer,
            costUSD: measured ?? CostModel.perplexityAgent(requests: 1, prices: prices),
            costIsMeasured: measured != nil
        )
    }

    // ── Vérification de la clé ───────────────────────────────────────

    /// Un appel Search minimal. Il est facturé 0,005 $ : c'est le seul moyen honnête de vérifier
    /// qu'une clé fonctionne vraiment, et l'écran le dit avant de le lancer.
    func testKey(prices: PriceTable) async throws -> Int {
        let outcome = try await search(queries: ["test"], maxResults: 1, prices: prices)
        return outcome.results.count
    }
}
