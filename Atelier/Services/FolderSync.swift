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
                entry.status = .unsupported
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
        let pending = store.files.filter { $0.status == .cataloged && SupportedTypes.isSupported($0.name) }
        guard !pending.isEmpty else { return }

        guard !Keychain.get(.gemini).isEmpty else {
            lastError = "Ajoutez votre clé Gemini dans les réglages pour indexer vos fichiers."
            return
        }
        guard await ensureStore() else { return }

        var done = 0
        for entry in pending {
            if Task.isCancelled { return }
            done += 1
            progressText = "Indexation \(done) / \(pending.count) — \(entry.name)"
            await index(entry)
        }
        progressText = nil
    }

    /// Niveau 3 du Smart Search : indexer un fichier précis, à la demande du moteur de recherche.
    func indexOnDemand(fileID: String) async throws -> Bool {
        guard let entry = store.file(id: fileID),
              SupportedTypes.isSupported(entry.name),
              entry.size <= SupportedTypes.maxFileBytes
        else { return false }
        guard await ensureStore() else { return false }
        return await index(entry)
    }

    @discardableResult
    private func index(_ entry: FileEntry) async -> Bool {
        guard let folder = store.folders.first(where: { $0.id == entry.folderID }) else { return false }

        do {
            let data = try await Self.readFile(bookmark: folder.bookmark, relativePath: entry.relativePath)

            // Un fichier réindexé remplace son ancienne version : sinon le corpus contiendrait
            // deux exemplaires du même texte et les citations deviendraient trompeuses.
            if let previous = entry.storeDocumentName, !previous.isEmpty {
                try? await gemini.deleteDocument(named: previous)
            }

            let documentName = try await gemini.uploadDocument(
                data: data,
                displayName: entry.name,
                mimeType: SupportedTypes.mimeType(for: entry.name),
                relativePath: entry.relativePath
            )

            var updated = entry
            updated.status = .indexed
            updated.storeDocumentName = documentName
            updated.indexedAt = .now
            updated.indexedSignature = entry.signature
            updated.errorMessage = nil
            store.upsert(updated)

            store.record(CostEntry(
                provider: "Gemini",
                model: "gemini-embedding-001",
                usd: CostModel.indexing(bytes: entry.size, prices: store.settings.prices),
                searchID: nil,
                note: "indexation — \(entry.name)"
            ))
            return true
        } catch is CancellationError {
            return false
        } catch {
            var updated = entry
            updated.status = .failed
            updated.errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            store.upsert(updated)
            return false
        }
    }

    /// Tout réindexer : on repart d'un corpus vide plutôt que d'accumuler des doublons.
    func reindexAll() async {
        guard await ensureStore() else { return }
        isScanning = true
        progressText = "Remise à zéro du corpus…"

        let client = gemini
        let names = store.files.compactMap(\.storeDocumentName).filter { !$0.isEmpty }
        for name in names {
            try? await client.deleteDocument(named: name)
        }

        let reset = store.files.map { file -> FileEntry in
            var copy = file
            if copy.status == .indexed || copy.status == .failed {
                copy.status = .cataloged
            }
            copy.storeDocumentName = nil
            copy.indexedAt = nil
            copy.indexedSignature = nil
            copy.errorMessage = nil
            return copy
        }
        store.upsertFiles(reset)
        isScanning = false
        await scanAll(force: true)
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
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("apercu", isDirectory: true)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let fileURL = destination.appendingPathComponent(entry.name)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            lastError = "Ce document n'a pas pu être ouvert : \(error.localizedDescription)"
            return nil
        }
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
