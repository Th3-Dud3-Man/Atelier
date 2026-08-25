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
    var monthlyCapUSD: Double = 15
    /// Mois déjà signalé à 80 % du plafond, pour ne prévenir qu'une fois.
    var alerted80Month: String = ""
    var dictationHintShown: Bool = false
    /// Scan automatique au lancement et au retour au premier plan.
    var autoScan: Bool = true
    /// Niveau 3 du Smart Search : indexer et relancer sans rien demander.
    var autoIndexSuggested: Bool = true
    var prices: PriceTable = .current
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
    /// Dernière erreur d'écriture, montrée dans Diagnostics plutôt que perdue.
    private(set) var lastPersistenceError: String?

    private var saveTask: Task<Void, Never>?
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppStore.defaultFileURL()
        self.data = AppStore.load(from: self.fileURL)
    }

    static func defaultFileURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("atelier.json")
    }

    // ── Lecture ──────────────────────────────────────────────────────

    private static func load(from url: URL) -> AppData {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppData() }
        do {
            let raw = try Data(contentsOf: url)
            return try decoder().decode(AppData.self, from: raw)
        } catch {
            // Un fichier illisible est mis de côté plutôt qu'écrasé : rien ne disparaît en silence.
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("atelier-illisible-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return AppData()
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // ── Écriture ─────────────────────────────────────────────────────

    /// Écriture différée : les modifications rapprochées ne provoquent qu'une seule écriture.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        saveTask?.cancel()
        let snapshot = data
        let destination = fileURL
        do {
            let encoded = try AppStore.encoder().encode(snapshot)
            try await Task.detached(priority: .utility) {
                try encoded.write(to: destination, options: [.atomic])
            }.value
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }

    /// Modifie les données et programme une écriture.
    func update(_ change: (inout AppData) -> Void) {
        change(&data)
        scheduleSave()
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
        update { $0.costs.append(entry) }
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
        return cap > 0 && monthTotal() >= cap
    }

    var capRatio: Double {
        let cap = data.settings.monthlyCapUSD
        guard cap > 0 else { return 0 }
        return monthTotal() / cap
    }

    // ── Export / import ──────────────────────────────────────────────

    func exportData() throws -> Data {
        try AppStore.encoder().encode(data)
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
