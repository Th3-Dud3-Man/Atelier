import Foundation
import Observation

/// Smart Search v2 : désignation des dossiers, signets persistants, scan incrémental,
/// envoi au store Gemini, retrait de ce qui a disparu.
///
/// Trois points ont été vérifiés dans la documentation Apple et déterminent tout le reste :
/// — l'autorisation obtenue sur un dossier couvre **récursivement** tout son contenu, y compris
///   les fichiers ajoutés plus tard : un seul signet, un seul `startAccessingSecurityScopedResource`
///   autour d'une session complète ;
/// — sur iOS, l'option de signet est `.minimalBookmark` (`.withSecurityScope` est propre à macOS) ;
/// — une lecture coordonnée (`NSFileCoordinator`) **attend** le téléchargement d'un fichier allégé
///   par iCloud : c'est la façon supportée de matérialiser un fichier sans `NSMetadataQuery`,
///   notoirement peu fiable sur un dossier externe.
@MainActor
@Observable
final class FolderSync: FileIndexing {

    private let store: AppStore

    private(set) var isScanning = false
    /// Texte de la pastille d'accueil, nil quand il n'y a rien à signaler.
    private(set) var progressText: String?

    /// Avancement chiffré d'une indexation, pour la barre de progression.
    ///
    /// Distinct de `progressText` : celui-ci porte aussi des étapes sans nombre — lecture du
    /// dossier, vérification du corpus — pendant lesquelles une barre n'aurait rien à montrer.
    struct Progress: Equatable, Sendable {
        var done: Int
        var total: Int
        /// Fichier en cours, affiché sous la barre.
        var current: String
        /// Fichiers écartés en chemin : budget de corpus, format refusé.
        var skipped: Int = 0

        var fraction: Double {
            total > 0 ? min(1, Double(done) / Double(total)) : 0
        }
    }

    private(set) var progress: Progress?
    private(set) var lastError: String?

    private var task: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
    }

    private var gemini: GeminiClient {
        GeminiClient(
            apiKey: Keychain.get(.gemini),
            mainModel: store.settings.mainModel,
            lightModel: store.settings.lightModel,
            storeName: store.settings.storeName
        )
    }

    // ── Dossiers ─────────────────────────────────────────────────────

    /// Ajoute un dossier choisi dans le sélecteur. L'URL est convertie en signet immédiatement :
    /// c'est lui, et non l'URL, qui survivra au prochain lancement.
    func addFolder(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let folder = WatchedFolder(displayName: url.lastPathComponent, bookmark: bookmark)
            store.addFolder(folder)
            lastError = nil
            scanAllInBackground()
        } catch {
            lastError = "Ce dossier n'a pas pu être enregistré : \(error.localizedDescription)"
        }
    }

    /// Retire un dossier : ses fichiers quittent le registre et le corpus Gemini.
    func removeFolder(_ folder: WatchedFolder) {
        let documents = store.files
            .filter { $0.folderID == folder.id }
            .compactMap(\.storeDocumentName)
        store.removeFolder(id: folder.id)

        guard !documents.isEmpty, !store.settings.storeName.isEmpty else { return }
        let client = gemini
        Task {
            for name in documents where !name.isEmpty {
                try? await client.deleteDocument(named: name)
            }
        }
    }

    // ── Scan ─────────────────────────────────────────────────────────

    func scanAllInBackground() {
        guard !isScanning, !store.folders.isEmpty else { return }
        task = Task { [weak self] in
            await self?.scanAll()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isScanning = false
        progressText = nil
    }

    /// Parcourt les dossiers, met le registre à jour, puis envoie ce qui doit l'être.
    func scanAll(force: Bool = false) async {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        defer {
            isScanning = false
            progressText = nil
            progress = nil
        }

        for folder in store.folders {
            if Task.isCancelled { return }
            await scan(folder: folder, force: force)
        }

        await indexPending()
    }

    private func scan(folder: WatchedFolder, force: Bool) async {
        progressText = "Lecture du dossier « \(folder.displayName) »…"

        let outcome: ScanOutcome
        do {
            outcome = try await Self.readFolder(
                bookmark: folder.bookmark,
                excludedSubpaths: folder.excludedSubpaths,
                excludedExtensions: folder.excludedExtensions
            )
        } catch {
            var updated = folder
            updated.needsReselection = true
            store.updateFolder(updated)
            lastError = "Le dossier « \(folder.displayName) » n'est plus accessible. "
                + "Ouvrez Mes fichiers pour le redésigner."
            return
        }

        // Le signet a vieilli : Apple demande d'en recréer un et de remplacer l'ancien.
        var updated = folder
        if let refreshed = outcome.refreshedBookmark {
            updated.bookmark = refreshed
        }
        updated.needsReselection = false
        updated.lastScan = .now
        updated.fileCount = outcome.files.count

        // Fusion avec le registre.
        let existing = store.files.filter { $0.folderID == folder.id }
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var entries: [FileEntry] = []
        var seen = Set<String>()

        for file in outcome.files {
            let id = FileEntry.makeID(folderID: folder.id, relativePath: file.relativePath)
            seen.insert(id)

            var entry = byID[id] ?? FileEntry(
                id: id,
                folderID: folder.id,
                relativePath: file.relativePath,
                name: file.name,
                size: file.size,
                modified: file.modified,
                status: SupportedTypes.isSupported(file.name) ? .cataloged : .unsupported,
                storeDocumentName: nil,
                indexedAt: nil,
                errorMessage: nil
            )
            entry.name = file.name
            entry.size = file.size
            entry.modified = file.modified
            entry.lastSeenAt = .now

            if file.size > SupportedTypes.maxFileBytes {
                entry.status = .tooLarge
                entry.errorMessage = "Fichier trop volumineux : la limite de Gemini est de 100 Mo."
            } else if !SupportedTypes.isSupported(file.name) {
                entry.status = .unsupported
                entry.errorMessage = nil
            } else if force {
                entry.status = .cataloged
                entry.indexedSignature = nil
            } else if entry.status == .indexed, entry.indexedSignature != entry.signature {
                // Le fichier a changé depuis son indexation : il repassera par l'envoi.
                entry.status = .cataloged
            }

            entries.append(entry)
        }

        store.upsertFiles(entries)
        updated.indexedCount = entries.filter { $0.status == .indexed }.count
        store.updateFolder(updated)

        // Ce qui a disparu du dossier quitte le registre et le corpus.
        let vanished = existing.filter { !seen.contains($0.id) }
        if !vanished.isEmpty {
            store.removeFiles(ids: Set(vanished.map(\.id)))
            let client = gemini
            let names = vanished.compactMap(\.storeDocumentName).filter { !$0.isEmpty }
            if !names.isEmpty {
                Task {
                    for name in names {
                        try? await client.deleteDocument(named: name)
                    }
                }
            }
        }
    }

    // ── Envoi vers le corpus ─────────────────────────────────────────

    /// Envoie les fichiers nouveaux ou modifiés, par lots, en s'arrêtant proprement.
    func indexPending() async {
        // `needsIndexing` couvre aussi les échecs précédents : un fichier en erreur, souvent un
        // téléchargement iCloud qui n'était pas terminé, doit être réessayé au scan suivant.
        // Les plus récents d'abord : quand le corpus est plus gros que le budget, ce sont eux
        // qui méritent la place.
        let pending = store.files
            .filter { $0.needsIndexing && SupportedTypes.isSupported($0.name) }
            .sorted { $0.modified > $1.modified }
        guard !pending.isEmpty else { return }

        guard !Keychain.get(.gemini).isEmpty else {
            lastError = "Ajoutez votre clé Gemini dans les réglages pour indexer vos fichiers."
            return
        }
        guard !store.capReached else {
            lastError = capMessage
            return
        }
        guard await ensureStore() else { return }

        store.beginBatch()
        defer { Task { await store.endBatch() } }

        var done = 0
        var skipped = 0
        // Compteur courant plutôt qu'une somme recalculée à chaque fichier : sur un corpus de
        // plusieurs milliers d'entrées, la seconde solution deviendrait le poste le plus lourd
        // du scan.
        var used = store.indexedBytes
        let budget = store.corpusBudgetBytes

        for entry in pending {
            if Task.isCancelled { return }
            // Le plafond peut être franchi en cours de lot : chaque fichier a son coût.
            if store.capReached {
                lastError = capMessage
                progress = nil
                return
            }
            // Budget du corpus : le fichier qui n'y tient pas reste au catalogue, sans erreur.
            // Il reste cherchable par son nom et pourra entrer à la demande, lors d'une question
            // qui le concerne vraiment.
            if entry.size > 0, used + entry.size > budget {
                skipped += 1
                continue
            }
            done += 1
            progressText = "Indexation \(done) / \(pending.count) — \(entry.name)"
            progress = Progress(done: done - 1, total: pending.count,
                                current: entry.name, skipped: skipped)
            if await index(entry) {
                used += store.file(id: entry.id)?.size ?? entry.size
            }
        }
        progress = Progress(done: done, total: pending.count, current: "", skipped: skipped)
        await reconcileDocumentNames()
        progressText = nil
        progress = nil

        if skipped > 0 {
            lastError = "Le corpus est plein (\(store.corpusUsageText)) : \(skipped) fichier(s) "
                + "restent au catalogue. Ils sont cherchables par leur nom et seront indexés "
                + "à la demande, lorsqu'une question les concernera."
        }
    }

    /// Google ne renvoie pas toujours le nom du document créé. Plutôt que de lister le corpus
    /// entier pour chaque fichier envoyé, on le fait **une fois** à la fin du lot, et seulement
    /// s'il reste des noms manquants. Sans ce nom, une réindexation ultérieure laisserait deux
    /// exemplaires du même texte dans le corpus.
    private func reconcileDocumentNames() async {
        let orphans = store.files.filter { $0.status == .indexed && ($0.storeDocumentName ?? "").isEmpty }
        guard !orphans.isEmpty, !store.settings.storeName.isEmpty else { return }

        progressText = "Vérification du corpus…"
        guard let table = try? await gemini.documentNamesByPath() else { return }

        let repaired = orphans.compactMap { entry -> FileEntry? in
            guard let name = table[entry.relativePath] else { return nil }
            var copy = entry
            copy.storeDocumentName = name
            return copy
        }
        if !repaired.isEmpty {
            store.upsertFiles(repaired)
        }
    }

    /// Message unique du mode gratuit, pour ne pas le formuler à deux endroits.
    private var capMessage: String {
        "Plafond mensuel atteint (\(CostModel.format(store.settings.monthlyCapUSD))) : "
            + "l'indexation reprendra après avoir relevé le plafond dans les réglages."
    }

    /// Niveau 3 du Smart Search : indexer un fichier précis, à la demande du moteur de recherche.
    func indexOnDemand(fileID: String) async throws -> Bool {
        guard !store.capReached else { return false }
        guard let entry = store.file(id: fileID),
              SupportedTypes.isSupported(entry.name),
              entry.size <= SupportedTypes.maxFileBytes
        else { return false }
        guard await makeRoom(for: entry) else { return false }
        guard await ensureStore() else { return false }
        let indexed = await index(entry)
        if indexed, (store.file(id: fileID)?.storeDocumentName ?? "").isEmpty {
            await reconcileDocumentNames()
        }
        return indexed
    }

    /// Vrai quand l'erreur porte sur le type du fichier plutôt que sur son contenu.
    private static func isMimeRejection(_ error: APIError) -> Bool {
        guard error.status == 400 else { return false }
        let message = error.message.lowercased()
        return message.contains("mime") || message.contains("unsupported")
            || message.contains("not supported")
    }

    /// Reconnaître le format demande de lire l'archive : hors du fil qui dessine l'écran.
    private static func decidePlan(for data: Data, name: String) async -> DocumentText.Plan {
        (try? await offMainActor { DocumentText.plan(for: data, name: name) })
            ?? .upload(mime: SupportedTypes.mimeType(for: name))
    }

    /// L'extraction lit et décompresse : c'est du travail, et il n'a rien à faire sur le fil
    /// qui dessine l'écran.
    private static func extractText(from data: Data, name: String) async -> String? {
        try? await offMainActor { DocumentText.extract(from: data, name: name) }
    }

    /// Fait de la place dans le corpus pour un fichier demandé à la volée.
    ///
    /// Sur un corpus plus gros que le budget, le catalogue est complet mais l'index est un
    /// **plan de travail** : les documents les plus anciennement indexés cèdent leur place à
    /// celui dont on a besoin maintenant. Ils reviendront de la même façon si une question les
    /// rappelle ; seule leur réindexation sera refacturée, quelques centimes tout au plus.
    private func makeRoom(for entry: FileEntry) async -> Bool {
        let budget = store.corpusBudgetBytes
        let needed = max(entry.size, 0)
        guard needed <= budget else { return false }

        var used = store.indexedBytes
        guard used + needed > budget else { return true }

        let candidates = store.indexedFiles
            .filter { $0.id != entry.id }
            .sorted { ($0.indexedAt ?? .distantPast) < ($1.indexedAt ?? .distantPast) }

        for victim in candidates {
            progressText = "Le corpus est plein : « \(victim.name) » lui cède sa place…"
            await unindex(victim)
            used -= victim.size
            if used + needed <= budget {
                progressText = nil
                return true
            }
        }
        progressText = nil
        return false
    }

    @discardableResult
    private func index(_ entry: FileEntry) async -> Bool {
        guard let folder = store.folders.first(where: { $0.id == entry.folderID }) else { return false }

        do {
            let data = try await Self.readFile(bookmark: folder.bookmark, relativePath: entry.relativePath)

            // La taille annoncée au scan vaut souvent zéro pour un fichier non encore téléchargé :
            // c'est seulement ici, une fois les octets en main, qu'on peut vraiment la vérifier.
            let realSize = Int64(data.count)
            guard realSize <= SupportedTypes.maxFileBytes else {
                var oversized = entry
                oversized.size = realSize
                oversized.status = .tooLarge
                oversized.errorMessage = "Fichier trop volumineux : la limite de Gemini est de 100 Mo."
                store.upsert(oversized)
                return false
            }

            // Un fichier réindexé remplace son ancienne version : sinon le corpus contiendrait
            // deux exemplaires du même texte et les citations deviendraient trompeuses.
            if let previous = entry.storeDocumentName, !previous.isEmpty {
                try? await gemini.deleteDocument(named: previous)
            }

            // La décision se prend sur le contenu, jamais sur l'extension : un « .doc » est
            // aussi souvent du RTF, du HTML ou un .docx renommé qu'un vrai binaire Word.
            var payload = data
            var mime: String
            switch await Self.decidePlan(for: data, name: entry.name) {
            case .upload(let declared):
                mime = declared

            case .convert:
                guard let converted = await Self.extractText(from: data, name: entry.name) else {
                    var failed = entry
                    failed.size = realSize
                    failed.status = .unsupported
                    failed.errorMessage = "Le texte n'a pas pu être extrait de ce fichier. "
                        + "Réenregistrez-le en PDF ou en .docx pour qu'il entre dans le corpus."
                    store.upsert(failed)
                    return false
                }
                payload = Data(converted.utf8)
                mime = "text/plain"

            case .reject(let reason):
                // Un refus est définitif : le marquer « non pris en charge » l'écarte des
                // reprises, au lieu de le faire réessayer indéfiniment.
                var rejected = entry
                rejected.size = realSize
                rejected.status = .unsupported
                rejected.errorMessage = reason
                store.upsert(rejected)
                return false
            }

            let documentName: String
            do {
                documentName = try await gemini.uploadDocument(
                    data: payload,
                    displayName: entry.name,
                    mimeType: mime,
                    relativePath: entry.relativePath
                )
            } catch let error as APIError where Self.isMimeRejection(error) && mime != "text/plain" {
                // Google a refusé le type. Plutôt que de laisser le fichier de côté, on tente
                // de l'ouvrir ici et de n'envoyer que son texte. La liste des types admis
                // évolue ; ce repli, lui, n'a pas à être tenu à jour.
                guard let converted = await Self.extractText(from: data, name: entry.name) else {
                    throw error
                }
                documentName = try await gemini.uploadDocument(
                    data: Data(converted.utf8),
                    displayName: entry.name,
                    mimeType: "text/plain",
                    relativePath: entry.relativePath
                )
            }

            var updated = entry
            updated.size = realSize
            updated.status = .indexed
            updated.storeDocumentName = documentName
            updated.indexedAt = .now
            updated.indexedSignature = entry.signature
            updated.errorMessage = nil
            updated.failureCount = nil
            updated.retryAfter = nil
            store.upsert(updated)

            store.record(CostEntry(
                provider: "Gemini",
                model: "gemini-embedding-001",
                usd: CostModel.indexing(bytes: realSize, prices: store.settings.prices),
                searchID: nil,
                note: "indexation — \(entry.name)"
            ))
            return true
        } catch is CancellationError {
            return false
        } catch {
            var updated = entry
            let failures = (entry.failureCount ?? 0) + 1
            updated.status = .failed
            updated.failureCount = failures
            updated.retryAfter = Date.now.addingTimeInterval(FileEntry.backoff(after: failures))
            updated.errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            if failures >= FileEntry.maximumAttempts {
                updated.errorMessage = (updated.errorMessage ?? "")
                    + " — abandonné après \(failures) essais. Touchez « Réessayer » pour insister."
            }
            store.upsert(updated)
            return false
        }
    }

    /// Tout réindexer : on repart d'un corpus vide plutôt que d'accumuler des doublons.
    func reindexAll() async {
        guard await ensureStore() else { return }
        isScanning = true
        progressText = "Remise à zéro du corpus…"

        // Une suppression qui échoue — appareil hors ligne, 429 — laisserait un document
        // orphelin chez Google, et le fichier serait renvoyé : deux exemplaires du même texte
        // dans le corpus, et des citations trompeuses. On ne repart donc de zéro que pour ce
        // qui a réellement été supprimé.
        let client = gemini
        var stillThere = 0
        var reset: [FileEntry] = []
        for file in store.files {
            var copy = file
            if let name = copy.storeDocumentName, !name.isEmpty {
                do {
                    try await client.deleteDocument(named: name)
                    copy.storeDocumentName = nil
                } catch {
                    stillThere += 1
                    continue   // on garde le nom pour pouvoir réessayer plus tard
                }
            }
            if copy.status == .indexed || copy.status == .failed {
                copy.status = .cataloged
            }
            copy.indexedAt = nil
            copy.indexedSignature = nil
            copy.errorMessage = nil
            reset.append(copy)
        }
        store.upsertFiles(reset)
        if stillThere > 0 {
            lastError = "\(stillThere) document(s) n'ont pas pu être retirés du corpus et seront "
                + "réessayés plus tard ; ils ne sont pas réindexés pour éviter les doublons."
        }
        isScanning = false
        await scanAll(force: true)
    }

    /// Efface les délais d'attente et relance : c'est le geste explicite de l'utilisateur,
    /// il l'emporte sur la temporisation.
    func retryFailed() async {
        let waiting = store.files.filter { $0.status == .failed || $0.status == .downloading }
        guard !waiting.isEmpty else { return }
        store.upsertFiles(waiting.map { file in
            var copy = file
            copy.failureCount = nil
            copy.retryAfter = nil
            return copy
        })
        lastError = nil
        await scanAll()
    }

    /// Retire un fichier du corpus sans le retirer du catalogue.
    func unindex(_ entry: FileEntry) async {
        if let name = entry.storeDocumentName, !name.isEmpty {
            try? await gemini.deleteDocument(named: name)
        }
        var updated = entry
        updated.status = .cataloged
        updated.storeDocumentName = nil
        updated.indexedAt = nil
        updated.indexedSignature = nil
        store.upsert(updated)
    }

    private func ensureStore() async -> Bool {
        if !store.settings.storeName.isEmpty { return true }
        do {
            let name = try await gemini.createStore()
            store.updateSettings { $0.storeName = name }
            return true
        } catch {
            lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    // ── Ouvrir un document cité ──────────────────────────────────────

    /// Prépare un fichier pour l'aperçu. Le contenu est recopié dans le conteneur de l'app :
    /// QuickLook s'exécute dans un autre processus et ne sait pas déclencher le téléchargement
    /// d'un fichier allégé par iCloud.
    func materialize(relativePath: String?, name: String) async -> URL? {
        guard let entry = matchingEntry(relativePath: relativePath, name: name),
              let folder = store.folders.first(where: { $0.id == entry.folderID })
        else { return nil }

        do {
            let data = try await Self.readFile(bookmark: folder.bookmark, relativePath: entry.relativePath)
            // Un sous-dossier par entrée : deux fichiers nommés « notes.pdf » dans deux dossiers
            // différents ne peuvent ainsi pas se recouvrir, tout en gardant leur nom lisible
            // — c'est celui que QuickLook affiche en titre.
            let destination = Self.previewsDirectory
                .appendingPathComponent(String(UInt(bitPattern: entry.id.hashValue)), isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let fileURL = destination.appendingPathComponent(entry.name)
            // La copie est en clair : elle est protégée au repos et effacée à la fermeture
            // de l'aperçu comme au lancement suivant.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return fileURL
        } catch {
            lastError = "Ce document n'a pas pu être ouvert : \(error.localizedDescription)"
            return nil
        }
    }

    private static var previewsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("apercu", isDirectory: true)
    }

    /// Efface les copies d'aperçu. Appelée au lancement et à la fermeture de chaque aperçu :
    /// aucun document ne reste en clair dans le dossier temporaire une fois l'aperçu refermé.
    func clearPreviews() {
        try? FileManager.default.removeItem(at: Self.previewsDirectory)
    }

    /// Retrouve l'entrée du registre correspondant à une source citée.
    /// Gemini renvoie le nom affiché du document ; le chemin relatif, lui, a été rangé
    /// en métadonnée à l'indexation et revient dans la citation quand il est disponible.
    private func matchingEntry(relativePath: String?, name: String) -> FileEntry? {
        if let relativePath, !relativePath.isEmpty,
           let match = store.files.first(where: { $0.relativePath == relativePath }) {
            return match
        }
        return store.files.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    // ── Lecture disque, hors du fil principal ────────────────────────

    /// Exécute un travail bloquant hors du fil principal, en transmettant l'annulation.
    ///
    /// `Task.detached` est indispensable ici (voir `readFolder`), mais il n'hérite pas de
    /// l'annulation : `withTaskCancellationHandler` la relaie explicitement, sans quoi le bouton
    /// « Arrêter » n'arrêterait rien.
    private nonisolated static func offMainActor<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .utility) { try work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private struct ScannedFile: Sendable {
        var relativePath: String
        var name: String
        var size: Int64
        var modified: Date
    }

    private struct ScanOutcome: Sendable {
        var files: [ScannedFile]
        /// Renseigné quand le signet a dû être recréé.
        var refreshedBookmark: Data?
    }

    /// Énumère un dossier. Le scope est ouvert une seule fois sur le dossier parent :
    /// il couvre récursivement tout le contenu, y compris les fichiers ajoutés depuis.
    ///
    /// Attention au piège : avec `SWIFT_APPROACHABLE_CONCURRENCY`, une fonction `nonisolated async`
    /// s'exécute **sur l'acteur appelant**, donc ici sur le fil principal. Une énumération de
    /// milliers de fichiers le figerait. D'où la tâche détachée — et comme une tâche détachée
    /// n'hérite pas de l'annulation, celle-ci lui est transmise à la main.
    private nonisolated static func readFolder(
        bookmark: Data,
        excludedSubpaths: [String],
        excludedExtensions: [String]
    ) async throws -> ScanOutcome {
        try await offMainActor {
            try scanFolderSynchronously(
                bookmark: bookmark,
                excludedSubpaths: excludedSubpaths,
                excludedExtensions: excludedExtensions
            )
        }
    }

    private nonisolated static func scanFolderSynchronously(
        bookmark: Data,
        excludedSubpaths: [String],
        excludedExtensions: [String]
    ) throws -> ScanOutcome {
        var isStale = false
        let root = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)

        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        var refreshed: Data?
        if isStale {
            refreshed = try? root.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        let keys: [URLResourceKey] = [
            .nameKey, .fileSizeKey, .contentModificationDateKey,
            .isDirectoryKey, .isRegularFileKey, .isPackageKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }   // un sous-dossier illisible n'interrompt pas le scan
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        let basePath = root.standardizedFileURL.path(percentEncoded: false)
        var files: [ScannedFile] = []

        for case let item as URL in enumerator {
            try Task.checkCancellation()
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true || values.isPackage == true { continue }
            guard values.isRegularFile == true else { continue }

            var relative = item.standardizedFileURL.path(percentEncoded: false)
            if relative.hasPrefix(basePath) {
                relative = String(relative.dropFirst(basePath.count))
            }
            relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }

            let name = values.name ?? item.lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            if excludedExtensions.contains(ext) { continue }
            if excludedSubpaths.contains(where: { relative.hasPrefix($0) }) { continue }

            files.append(ScannedFile(
                relativePath: relative,
                name: name,
                // La taille peut manquer sur un fichier non téléchargé : elle sera revue à la lecture.
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }

        return ScanOutcome(files: files, refreshedBookmark: refreshed)
    }

    /// Lit un fichier. La lecture coordonnée est ce qui **attend** le téléchargement d'un fichier
    /// allégé par iCloud : la documentation le dit explicitement, et cela évite `NSMetadataQuery`.
    /// Cette attente peut durer : elle ne doit surtout pas avoir lieu sur le fil principal.
    private nonisolated static func readFile(bookmark: Data, relativePath: String) async throws -> Data {
        try await offMainActor {
            try readFileSynchronously(bookmark: bookmark, relativePath: relativePath)
        }
    }

    private nonisolated static func readFileSynchronously(bookmark: Data, relativePath: String) throws -> Data {
        var isStale = false
        let root = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        var fileURL = root
        for component in relativePath.split(separator: "/") {
            fileURL.appendPathComponent(String(component))
        }

        // Demande de téléchargement au cas où : sans effet si le fichier est déjà là.
        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)

        var readError: NSError?
        var data: Data?
        var innerError: Error?

        // Le bloc est synchrone et non échappant : les variables locales ci-dessus peuvent
        // être renseignées depuis l'intérieur sans franchir de frontière de concurrence.
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &readError) { url in
            do {
                data = try Data(contentsOf: url)
            } catch {
                innerError = error
            }
        }

        if let readError { throw readError }
        if let innerError { throw innerError }
        guard let data else { throw CocoaError(.fileReadUnknown) }
        return data
    }
}
