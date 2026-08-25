import Foundation

// Vérifie que tout le modèle survit à un aller-retour JSON : c'est la persistance entière de l'app.
var data = AppData()
data.settings.storeName = "fileSearchStores/latelier-123abc"
data.settings.webLevel = .deep
data.settings.priority = .parallel
data.settings.monthlyCapUSD = 15

let folderID = UUID()
data.folders = [WatchedFolder(id: folderID, displayName: "Recherche", bookmark: Data([1,2,3]), lastScan: .now, fileCount: 3, indexedCount: 2)]

var entry = FileEntry(id: "x", folderID: folderID, relativePath: "Lacan/Séminaire XI.pdf",
                      name: "Séminaire XI.pdf", size: 4_200_000, modified: .now,
                      status: .indexed, storeDocumentName: "fileSearchStores/x/documents/y",
                      indexedAt: .now, errorMessage: nil)
entry.indexedSignature = entry.signature
data.files = [entry]

var analysis = QueryAnalysis()
analysis.intent = "passages"
analysis.preferredSource = "files"
analysis.probableQuotes = ["Père, ne vois-tu pas que je brûle ?"]
analysis.fileQuery = "Le rêve de l'enfant qui brûle, commenté par Lacan."

var search = SearchRecord(question: "Où Lacan parle-t-il de l'enfant qui brûle ?")
search.analysis = analysis
search.effectiveSource = .both
search.webLevel = .standard
search.synthesis = "### Réponse\nLacan y revient au chapitre V [L1], après Freud [W1]."
search.sources = [
  SourceRef(tag: "L1", kind: .local, title: "Séminaire XI.pdf", excerpt: "« Père, ne vois-tu pas… »",
            page: 58, url: nil, publishedAt: nil, relativePath: "Lacan/Séminaire XI.pdf"),
  SourceRef(tag: "W1", kind: .web, title: "Article", excerpt: "…", page: nil,
            url: "https://exemple.fr/a", publishedAt: "2026-05-01", relativePath: nil),
]
search.followUps = [FollowUpTurn(question: "Et Freud ?", answer: "…", costUSD: 0.001)]
search.costUSD = 0.0123
search.models = ["gemini-3.1-flash-lite"]
search.status = .done
search.notes = ["« X.pdf » a été ajouté à l'index."]
data.searches = [search]
data.costs = [CostEntry(provider: "Gemini", model: "gemini-3.1-flash-lite", usd: 0.0123,
                        tokensIn: 4200, tokensOut: 380, searchID: search.id, note: "synthèse")]

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

do {
    let bytes = try encoder.encode(data)
    let back = try decoder.decode(AppData.self, from: bytes)
    var ok = true
    @MainActor func check(_ label: String, _ condition: Bool) {
        print(condition ? "  ✓ \(label)" : "  ✗ \(label)"); if !condition { ok = false }
    }
    print("Aller-retour JSON (\(bytes.count) octets) :")
    check("réglages", back.settings.storeName == data.settings.storeName
          && back.settings.webLevel == .deep && back.settings.priority == .parallel)
    check("dossier + signet", back.folders.first?.bookmark == Data([1,2,3])
          && back.folders.first?.id == folderID)
    check("fichier, accents dans le chemin", back.files.first?.relativePath == "Lacan/Séminaire XI.pdf")
    check("statut et signature d'indexation", back.files.first?.status == .indexed
          && back.files.first?.needsIndexing == false)
    check("recherche, question accentuée", back.searches.first?.question == search.question)
    check("analyse imbriquée", back.searches.first?.analysis?.probableQuotes.first == analysis.probableQuotes.first)
    check("sources et numéro de page", back.searches.first?.sources.first?.page == 58
          && back.searches.first?.sources.last?.url == "https://exemple.fr/a")
    check("question de suite", back.searches.first?.followUps.first?.question == "Et Freud ?")
    check("coût", abs((back.searches.first?.costUSD ?? 0) - 0.0123) < 1e-9)
    check("clé de mois", back.costs.first?.monthKey == data.costs.first?.monthKey)
    check("aucune clé API dans le JSON",
          !String(data: bytes, encoding: .utf8)!.lowercased().contains("apikey"))
    print(ok ? "\nOK : la persistance survit intégralement." : "\nÉCHEC")
    if !ok { exit(1) }
} catch {
    print("ÉCHEC d'encodage/décodage : \(error)"); exit(1)
}
