import Foundation
import Observation

/// Réglages de l'app. Les clés API n'y figurent pas : elles vivent dans le Keychain.
struct AppSettings: Codable, Sendable {
    /// Modèle capable d'utiliser File Search (le moins cher de la liste officielle).
    var mainModel: String = GeminiModels.defaultMain
    /// Modèle le moins cher, pour l'analyse, les doublons et la transcription.
    var lightModel: String = GeminiModels.defaultLight
    /// Nom complet du store côté Google : « fileSearchStores/… ».
    var storeName: String = ""
    var webLevel: WebLevel = .standard
    var priority: SourcePriority = .filesFirst
    /// Plafond mensuel, TVA comprise, en dollars — la monnaie des deux API. Il couvre Gemini
    /// et Perplexity ensemble ; l'abonnement iCloud, lui, se règle chez Apple et n'entre pas
    /// dans ce compteur. Zéro désactive la limite.
    var monthlyCapUSD: Double = 25
    /// Budget du corpus indexé, en octets **bruts**. Google plafonne un store à 10 Go au palier 1,
    /// et l'empreinte réelle vaut environ trois fois la taille des données brutes : trois giga-octets
    /// de documents remplissent donc déjà ce quota. Au-delà du budget, les fichiers restent au
    /// catalogue — cherchables par leur nom, gratuits — et entrent dans le corpus à la demande,
    /// en prenant la place des plus anciennement indexés.
    var corpusBudgetBytes: Int64 = 3 * 1024 * 1024 * 1024
    /// Mois déjà signalé à 80 % du plafond, pour ne prévenir qu'une fois.
    var alerted80Month: String = ""
    var dictationHintShown: Bool = false
    /// Scan automatique au lancement et au retour au premier plan.
    var autoScan: Bool = true
    /// Niveau 3 du Smart Search : indexer et relancer sans rien demander.
    var autoIndexSuggested: Bool = true
    var prices: PriceTable = .current
    /// Modèles que la clé peut réellement employer, relevés auprès de Google.
    /// Vide tant que « Enregistrer et tester » n'a pas été touché.
    var availableModels: [GeminiModels.Info] = []

    init() {}

    /// Même précaution que pour la grille de prix : un réglage ajouté par une version ultérieure
    /// ne doit pas rendre illisible le fichier écrit par la précédente.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let base = AppSettings()
        mainModel = try box.decodeIfPresent(String.self, forKey: .mainModel) ?? base.mainModel
        lightModel = try box.decodeIfPresent(String.self, forKey: .lightModel) ?? base.lightModel
        storeName = try box.decodeIfPresent(String.self, forKey: .storeName) ?? base.storeName
        webLevel = try box.decodeIfPresent(WebLevel.self, forKey: .webLevel) ?? base.webLevel
        priority = try box.decodeIfPresent(SourcePriority.self, forKey: .priority) ?? base.priority
        monthlyCapUSD = try box.decodeIfPresent(Double.self, forKey: .monthlyCapUSD) ?? base.monthlyCapUSD
        corpusBudgetBytes = try box.decodeIfPresent(Int64.self, forKey: .corpusBudgetBytes)
            ?? base.corpusBudgetBytes
        alerted80Month = try box.decodeIfPresent(String.self, forKey: .alerted80Month) ?? base.alerted80Month
        dictationHintShown = try box.decodeIfPresent(Bool.self, forKey: .dictationHintShown)
            ?? base.dictationHintShown
        autoScan = try box.decodeIfPresent(Bool.self, forKey: .autoScan) ?? base.autoScan
        autoIndexSuggested = try box.decodeIfPresent(Bool.self, forKey: .autoIndexSuggested)
            ?? base.autoIndexSuggested
        prices = try box.decodeIfPresent(PriceTable.self, forKey: .prices) ?? base.prices
        availableModels = try box.decodeIfPresent([GeminiModels.Info].self,
                                                  forKey: .availableModels) ?? []
    }
}

/// Racine du fichier JSON unique.
struct AppData: Codable, Sendable {
    var schemaVersion: Int = 1
    var settings = AppSettings()
    var folders: [WatchedFolder] = []
    var files: [FileEntry] = []
    var searches: [SearchRecord] = []
    var costs: [CostEntry] = []
}

/// Charge le fichier au lancement, le réécrit à chaque modification, et sert de source
/// de vérité unique aux vues. Tout passe par le fil principal : l'app est mono-utilisateur
/// et le fichier reste petit ; l'écriture, elle, est faite hors du fil principal.
@MainActor
@Observable
final class AppStore {
    private(set) var data: AppData
    /// Dernière erreur de lecture ou d'écriture, montrée dans Diagnostics plutôt que perdue.
    private(set) var lastPersistenceError: String?
    /// Vrai quand le fichier existe mais n'a pas pu être lu. Dans ce cas l'app fonctionne
    /// normalement, mais **n'écrit rien** : écraser des données qu'on n'a pas su relire
    /// serait le seul vrai moyen de les perdre.
    private(set) var isReadOnly = false

    /// Chiffres affichés en permanence par l'accueil, Mes fichiers et les réglages.
    ///
    /// Ils étaient recalculés à chaque rafraîchissement de vue : trois filtres sur le registre
    /// et une somme sur les dépenses, pour chaque vue et à chaque modification. Avec quelques
    /// centaines de fichiers indexés d'affilée, cela devient le poste le plus lourd de l'app.
    /// On les calcule donc une fois par modification, et les vues les lisent sans rien refaire.
    struct Summary: Sendable, Equatable {
        var indexedCount = 0
        var catalogedCount = 0
        var problemCount = 0
        var waitingCount = 0
        var indexedBytes: Int64 = 0
        var monthTotal: Double = 0
    }

    private(set) var summary = Summary()

    private var saveTask: Task<Void, Never>?
    /// Les écritures sont chaînées : un instantané plus ancien ne doit jamais arriver après
    /// un plus récent, ce qui ferait reculer les données.
    private var writeTask: Task<Void, Never>?
    private let fileURL: URL

    /// Au-delà, les recherches les plus anciennes sont oubliées : le fichier est réécrit
    /// en entier à chaque modification, et rien ne justifie qu'il grossisse sans fin.
    static let maximumSearches = 500
    /// Les dépenses sont conservées treize mois : de quoi couvrir le compteur du mois
    /// et une année complète de comparaison.
    static let costRetention: TimeInterval = 13 * 30 * 24 * 3600

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppStore.defaultFileURL()
        let outcome = AppStore.load(from: self.fileURL)
        self.data = outcome.data
        self.isReadOnly = outcome.readOnly
        self.lastPersistenceError = outcome.error
        self.summary = AppStore.summarise(self.data)
    }

    private static func summarise(_ data: AppData) -> Summary {
        var result = Summary()
        for file in data.files {
            if file.status == .indexed {
                result.indexedCount += 1
                result.indexedBytes += file.size
            } else {
                result.catalogedCount += 1
                if file.status.isProblem { result.problemCount += 1 }
                if file.isWaitingToRetry { result.waitingCount += 1 }
            }
        }
        let month = CostEntry.monthKey(for: .now)
        for cost in data.costs where cost.monthKey == month {
            result.monthTotal += cost.usd
        }
        return result
    }

    static func defaultFileURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("atelier.json")
    }

    // ── Lecture ──────────────────────────────────────────────────────

    /// Deux échecs très différents se cachent derrière « le fichier ne se lit pas ».
    /// Un contenu corrompu se met de côté et on repart à neuf. Une erreur d'accès — disque
    /// occupé, données encore protégées après un redémarrage — ne dit rien du contenu :
    /// on refuse alors d'écrire, plutôt que de remplacer un historique intact par du vide.
    private static func load(from url: URL) -> (data: AppData, readOnly: Bool, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return (AppData(), false, nil)
        }

        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            return (AppData(), true, "Vos données n'ont pas pu être lues (\(error.localizedDescription)). "
                + "L'app fonctionne, mais n'enregistrera rien tant qu'elle n'aura pas relu le fichier : "
                + "relancez-la dans un moment.")
        }

        do {
            return (try decoder().decode(AppData.self, from: raw), false, nil)
        } catch {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("atelier-illisible-\(Int(Date.now.timeIntervalSince1970)).json")
            do {
                try FileManager.default.moveItem(at: url, to: backup)
                return (AppData(), false, "Le fichier de données était illisible. Il a été mis de côté "
                    + "sous « \(backup.lastPathComponent) » et l'app repart à neuf.")
            } catch {
                return (AppData(), true, "Le fichier de données est illisible et n'a pas pu être mis "
                    + "de côté. L'app n'enregistrera rien pour ne pas l'écraser.")
            }
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Sur disque, compact : le fichier est réécrit en entier à chaque modification.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Pour l'export, lisible : il est destiné à être ouvert et relu.
    private static func exportEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // ── Écriture ─────────────────────────────────────────────────────

    /// Écriture différée : les modifications rapprochées ne provoquent qu'une seule écriture.
    func scheduleSave() {
        saveTask?.cancel()
        let delay: Duration = batchDepth > 0 ? .seconds(4) : .milliseconds(400)
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        saveTask?.cancel()
        guard !isReadOnly else { return }

        let snapshot = data
        let destination = fileURL
        let previous = writeTask

        let task = Task { @MainActor [weak self] in
            // Chaînage : l'écriture précédente doit être finie avant celle-ci, sinon un
            // instantané plus ancien pourrait atterrir après un plus récent.
            _ = await previous?.value
            do {
                let encoded = try AppStore.encoder().encode(snapshot)
                try await Task.detached(priority: .utility) {
                    try encoded.write(to: destination, options: [.atomic])
                }.value
                self?.lastPersistenceError = nil
            } catch {
                self?.lastPersistenceError = error.localizedDescription
            }
        }
        writeTask = task
        await task.value
    }

    /// Modifie les données et programme une écriture.
    func update(_ change: (inout AppData) -> Void) {
        change(&data)
        summary = AppStore.summarise(data)
        scheduleSave()
    }

    // ── Écritures en rafale ──────────────────────────────────────────

    /// Pendant une indexation, le registre change à chaque fichier. Réécrire le fichier
    /// complet toutes les quatre dixièmes de seconde revient à passer l'essentiel du temps
    /// à encoder du JSON. Le temps d'un lot, on espace les écritures.
    private var batchDepth = 0

    func beginBatch() { batchDepth += 1 }

    func endBatch() async {
        batchDepth = max(0, batchDepth - 1)
        if batchDepth == 0 { await saveNow() }
    }

    // ── Réglages ─────────────────────────────────────────────────────

    var settings: AppSettings { data.settings }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        update { change(&$0.settings) }
    }

    // ── Recherches ───────────────────────────────────────────────────

    /// Les recherches sont conservées les plus récentes en tête.
    var searches: [SearchRecord] { data.searches }

    func search(id: String) -> SearchRecord? {
        data.searches.first { $0.id == id }
    }

    func upsert(_ record: SearchRecord) {
        update { data in
            if let index = data.searches.firstIndex(where: { $0.id == record.id }) {
                data.searches[index] = record
            } else {
                data.searches.insert(record, at: 0)
                if data.searches.count > AppStore.maximumSearches {
                    data.searches.removeLast(data.searches.count - AppStore.maximumSearches)
                }
            }
        }
    }

    func deleteSearch(id: String) {
        update { $0.searches.removeAll { $0.id == id } }
    }

    func clearHistory() {
        update {
            $0.searches.removeAll()
            $0.costs.removeAll()
        }
    }

    // ── Fichiers ─────────────────────────────────────────────────────

    var files: [FileEntry] { data.files }
    var folders: [WatchedFolder] { data.folders }

    var indexedFiles: [FileEntry] { data.files.filter { $0.status == .indexed } }

    /// Octets bruts déjà envoyés au corpus, et ce qu'il reste du budget.
    var indexedBytes: Int64 { summary.indexedBytes }
    var corpusBudgetBytes: Int64 { data.settings.corpusBudgetBytes }
    var corpusRemainingBytes: Int64 { max(0, corpusBudgetBytes - indexedBytes) }
    var corpusFull: Bool { indexedBytes >= corpusBudgetBytes }

    /// « 1,2 Go sur 3 Go ». Une seule formulation, employée partout.
    var corpusUsageText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: indexedBytes)) sur "
            + "\(formatter.string(fromByteCount: corpusBudgetBytes))"
    }
    var catalogedFiles: [FileEntry] { data.files.filter { $0.status != .indexed } }

    func file(id: String) -> FileEntry? { data.files.first { $0.id == id } }

    func upsert(_ entry: FileEntry) {
        update { data in
            if let index = data.files.firstIndex(where: { $0.id == entry.id }) {
                data.files[index] = entry
            } else {
                data.files.append(entry)
            }
        }
    }

    func upsertFiles(_ entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        update { data in
            var byID = Dictionary(uniqueKeysWithValues: data.files.map { ($0.id, $0) })
            for entry in entries { byID[entry.id] = entry }
            data.files = Array(byID.values).sorted { $0.relativePath < $1.relativePath }
        }
    }

    func removeFiles(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        update { $0.files.removeAll { ids.contains($0.id) } }
    }

    func addFolder(_ folder: WatchedFolder) {
        update { $0.folders.append(folder) }
    }

    func updateFolder(_ folder: WatchedFolder) {
        update { data in
            if let index = data.folders.firstIndex(where: { $0.id == folder.id }) {
                data.folders[index] = folder
            }
        }
    }

    func removeFolder(id: UUID) {
        update { data in
            data.folders.removeAll { $0.id == id }
            data.files.removeAll { $0.folderID == id }
        }
    }

    // ── Coûts ────────────────────────────────────────────────────────

    func record(_ entry: CostEntry) {
        update { data in
            data.costs.append(entry)
            let cutoff = Date.now.addingTimeInterval(-AppStore.costRetention)
            if data.costs.contains(where: { $0.date < cutoff }) {
                data.costs.removeAll { $0.date < cutoff }
            }
        }
    }

    func monthTotal(_ month: String = CostEntry.monthKey(for: .now)) -> Double {
        data.costs.filter { $0.monthKey == month }.reduce(0) { $0 + $1.usd }
    }

    func monthByProvider(_ month: String = CostEntry.monthKey(for: .now)) -> [String: Double] {
        data.costs
            .filter { $0.monthKey == month }
            .reduce(into: [:]) { total, entry in total[entry.provider, default: 0] += entry.usd }
    }

    var capReached: Bool {
        let cap = data.settings.monthlyCapUSD
        return cap > 0 && summary.monthTotal >= cap
    }

    var capRatio: Double {
        let cap = data.settings.monthlyCapUSD
        guard cap > 0 else { return 0 }
        return monthTotal() / cap
    }

    /// Alerte à 80 % du plafond, une seule fois par mois. Renvoie le message à afficher,
    /// et marque le mois comme signalé pour ne pas le répéter.
    func consumeBudgetWarning() -> String? {
        let cap = data.settings.monthlyCapUSD
        guard cap > 0 else { return nil }
        let month = CostEntry.monthKey(for: .now)
        guard data.settings.alerted80Month != month else { return nil }
        let total = monthTotal()
        let ratio = total / cap
        guard ratio >= 0.8, ratio < 1 else { return nil }
        updateSettings { $0.alerted80Month = month }
        return "Vous avez utilisé \(CostModel.format(total)) sur \(CostModel.format(cap)) ce mois-ci. "
            + "Au plafond, les recherches payantes s'arrêteront."
    }

    // ── Export / import ──────────────────────────────────────────────

    func exportData() throws -> Data {
        try AppStore.exportEncoder().encode(data)
    }

    func importData(_ raw: Data, replacing: Bool) throws {
        let imported = try AppStore.decoder().decode(AppData.self, from: raw)
        update { data in
            if replacing {
                data = imported
            } else {
                let knownSearches = Set(data.searches.map(\.id))
                data.searches.append(contentsOf: imported.searches.filter { !knownSearches.contains($0.id) })
                data.searches.sort { $0.createdAt > $1.createdAt }
                let knownCosts = Set(data.costs.map(\.id))
                data.costs.append(contentsOf: imported.costs.filter { !knownCosts.contains($0.id) })
            }
        }
    }
}
