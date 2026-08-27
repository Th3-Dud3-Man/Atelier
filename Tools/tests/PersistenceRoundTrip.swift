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

var ok = true
@MainActor func check(_ label: String, _ condition: Bool) {
    print(condition ? "  ✓ \(label)" : "  ✗ \(label)"); if !condition { ok = false }
}

do {
    let bytes = try encoder.encode(data)
    let back = try decoder.decode(AppData.self, from: bytes)
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
} catch {
    print("ÉCHEC d'encodage/décodage : \(error)"); exit(1)
}

// ── Ce qui compte le plus : un fichier écrit par la version précédente se relit ─────────
// Deux champs ont été ajoutés au registre. S'ils n'étaient pas facultatifs, le fichier de
// l'utilisateur deviendrait illisible à la mise à jour — et son corpus, orphelin chez Google.

print("\nUn registre écrit avant l'ajout du délai de reprise :")
let ancien = Data(#"""
{"schemaVersion":1,
 "settings":{"mainModel":"gemini-3.1-flash-lite"},
 "folders":[],
 "files":[{"id":"abc/notes.pdf","folderID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
           "relativePath":"Contrats/notes.pdf","name":"notes.pdf","size":12345,
           "modified":"2026-08-01T10:00:00Z","status":"indexed",
           "storeDocumentName":"fileSearchStores/x/documents/y",
           "indexedAt":"2026-08-02T10:00:00Z","indexedSignature":"12345-1785578400",
           "lastSeenAt":"2026-08-20T10:00:00Z"}],
 "searches":[],"costs":[]}
"""#.utf8)

let lecteur = JSONDecoder()
lecteur.dateDecodingStrategy = .iso8601
if let restauré = try? lecteur.decode(AppData.self, from: ancien) {
    check("le registre se relit", restauré.files.count == 1)
    let fichier = restauré.files[0]
    check("le nom du document chez Google est intact",
          fichier.storeDocumentName == "fileSearchStores/x/documents/y")
    check("le fichier reste indexé", fichier.status == .indexed)
    check("il n'est pas réindexé pour rien", fichier.needsIndexing == false)
    check("les champs ajoutés valent zéro sans casser la lecture",
          fichier.failureCount == nil && fichier.retryAfter == nil)
} else {
    check("le registre se relit", false)
    check("le nom du document chez Google est intact", false)
    check("le fichier reste indexé", false)
    check("il n'est pas réindexé pour rien", false)
    check("les champs ajoutés valent zéro sans casser la lecture", false)
}

print("\nTemporisation des échecs :")
var enÉchec = FileEntry(id: "x", folderID: UUID(), relativePath: "a.pdf", name: "a.pdf",
                        size: 10, modified: .now, status: .failed)
check("un premier échec se réessaie tout de suite", enÉchec.needsIndexing)
enÉchec.failureCount = 1
enÉchec.retryAfter = Date.now.addingTimeInterval(60)
check("mais pas avant l'heure dite", !enÉchec.needsIndexing)
check("et l'app le dit", enÉchec.isWaitingToRetry)
enÉchec.retryAfter = Date.now.addingTimeInterval(-1)
check("passé le délai, il repasse", enÉchec.needsIndexing)
enÉchec.failureCount = FileEntry.maximumAttempts
check("au bout de quatre essais, l'app cesse d'insister seule", !enÉchec.needsIndexing)
check("les délais s'allongent",
      FileEntry.backoff(after: 1) < FileEntry.backoff(after: 3))
check("et plafonnent",
      FileEntry.backoff(after: 9) == FileEntry.backoff(after: 4))

print(ok ? "\nOK : la persistance survit intégralement." : "\nÉCHEC")
if !ok { exit(1) }
