import Foundation

/// Client Gemini. Voie stable `generateContent` : c'est elle qui renvoie les citations
/// File Search avec le numéro de page. Tous les champs proviennent de la documentation
/// officielle relevée dans NOTES_API.md (25/08/2026) ; aucun n'est inventé.
struct GeminiClient: Sendable {
    static let base = "https://generativelanguage.googleapis.com"

    var apiKey: String
    var mainModel: String
    var lightModel: String
    var storeName: String

    // ── Réponses ─────────────────────────────────────────────────────

    struct Reply: Sendable {
        var text: String
        var usage: TokenUsage
        var model: String
        var passages: [Passage] = []
        var supports: [Support] = []
    }

    /// Un passage retrouvé dans le corpus, tel que Gemini le renvoie.
    struct Passage: Sendable, Hashable {
        var title: String
        var text: String
        var page: Int?
        var uri: String?
        /// Chemin relatif rangé en métadonnée au moment de l'indexation.
        var relativePath: String?
    }

    /// Rattachement d'un fragment de la réponse aux passages qui le fondent.
    struct Support: Sendable, Hashable {
        var chunkIndices: [Int]
        /// Décalages en OCTETS dans la réponse du modèle, pas en caractères.
        var startByte: Int?
        var endByte: Int?
    }

    // ── Requête ──────────────────────────────────────────────────────

    struct Request: Encodable, Sendable {
        struct Part: Encodable, Sendable {
            var text: String?
            var inlineData: InlineData?
            var fileData: FileData?
        }

        struct InlineData: Encodable, Sendable {
            var mimeType: String
            var data: String
        }

        struct FileData: Encodable, Sendable {
            var mimeType: String
            var fileUri: String
        }

        struct Content: Encodable, Sendable {
            var role: String?
            var parts: [Part]
        }

        struct FileSearch: Encodable, Sendable {
            var fileSearchStoreNames: [String]
            var topK: Int?
            var metadataFilter: String?
        }

        struct Tool: Encodable, Sendable {
            var fileSearch: FileSearch?
        }

        struct ThinkingConfig: Encodable, Sendable {
            var thinkingLevel: String?
        }

        struct GenerationConfig: Encodable, Sendable {
            var responseMimeType: String?
            var responseSchema: JSONValue?
            var temperature: Double?
            var maxOutputTokens: Int?
            var thinkingConfig: ThinkingConfig?

            var isEmpty: Bool {
                responseMimeType == nil && responseSchema == nil && temperature == nil
                    && maxOutputTokens == nil && thinkingConfig == nil
            }
        }

        var contents: [Content]
        var systemInstruction: Content?
        var tools: [Tool]?
        var generationConfig: GenerationConfig?
    }

    // ── Décodage ─────────────────────────────────────────────────────

    private struct GenerateResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { var text: String? }
                var parts: [Part]?
            }
            var content: Content?
            var finishReason: String?
            var groundingMetadata: GroundingMetadata?
        }

        struct GroundingMetadata: Decodable {
            struct Chunk: Decodable {
                struct RetrievedContext: Decodable {
                    var title: String?
                    var text: String?
                    var pageNumber: Int?
                    var uri: String?
                    var customMetadata: [Metadata]?
                }
                var retrievedContext: RetrievedContext?
            }

            struct SupportEntry: Decodable {
                struct Segment: Decodable {
                    var partIndex: Int?
                    var startIndex: Int?
                    var endIndex: Int?
                    var text: String?
                }
                var groundingChunkIndices: [Int]?
                var segment: Segment?
            }

            var groundingChunks: [Chunk]?
            var groundingSupports: [SupportEntry]?
        }

        var candidates: [Candidate]?
        var usageMetadata: TokenUsage?
        var modelVersion: String?
    }

    struct Metadata: Codable, Sendable {
        var key: String
        var stringValue: String?
        var numericValue: Double?
    }

    // ── Appels de base ───────────────────────────────────────────────

    private func request(path: String, method: String = "GET", body: Data? = nil,
                         extraHeaders: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        return request
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    /// Un appel `generateContent`.
    ///
    /// `responseSchema` est marqué « deprecated » dans la référence REST sans remplaçant
    /// documenté : si Google renvoie 400, l'appel est refait sans les champs optionnels.
    /// Le prompt décrit de toute façon le format attendu et l'analyseur JSON est tolérant.
    func generate(model: String, request payload: Request) async throws -> Reply {
        func perform(_ payload: Request) async throws -> Reply {
            let body = try Self.encoder.encode(payload)
            let urlRequest = request(
                path: "/v1beta/models/\(model):generateContent",
                method: "POST",
                body: body
            )
            let (data, _) = try await HTTP.send(urlRequest, provider: "Gemini")
            return try Self.decode(data, fallbackModel: model)
        }

        do {
            return try await perform(payload)
        } catch let error as APIError where error.status == 400 {
            guard var config = payload.generationConfig,
                  config.responseSchema != nil || config.thinkingConfig != nil
            else { throw error }
            config.responseSchema = nil
            config.thinkingConfig = nil
            var retry = payload
            retry.generationConfig = config.isEmpty ? nil : config
            return try await perform(retry)
        }
    }

    private static func decode(_ data: Data, fallbackModel: String) throws -> Reply {
        let decoded: GenerateResponse
        do {
            decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        } catch {
            throw APIError(provider: "Gemini", status: 0,
                           message: "Réponse illisible : \(HTTP.errorMessage(from: data))")
        }
        let candidate = decoded.candidates?.first
        let text = (candidate?.content?.parts ?? []).compactMap(\.text).joined()
        return Reply(
            text: text,
            usage: decoded.usageMetadata ?? TokenUsage(),
            model: decoded.modelVersion ?? fallbackModel,
            passages: passages(from: candidate?.groundingMetadata),
            supports: supports(from: candidate?.groundingMetadata)
        )
    }

    private static func passages(from metadata: GenerateResponse.GroundingMetadata?) -> [Passage] {
        var seen = Set<String>()
        var result: [Passage] = []
        for chunk in metadata?.groundingChunks ?? [] {
            guard let context = chunk.retrievedContext, let text = context.text, !text.isEmpty else { continue }
            let signature = "\(context.title ?? "")|\(context.pageNumber ?? -1)|\(text.prefix(120))"
            guard seen.insert(signature).inserted else { continue }
            result.append(Passage(
                title: context.title ?? "Document",
                text: text,
                page: context.pageNumber,
                uri: context.uri,
                relativePath: context.customMetadata?.first { $0.key == "path" }?.stringValue
            ))
        }
        return result
    }

    private static func supports(from metadata: GenerateResponse.GroundingMetadata?) -> [Support] {
        (metadata?.groundingSupports ?? []).map { entry in
            Support(
                chunkIndices: entry.groundingChunkIndices ?? [],
                startByte: entry.segment?.startIndex,
                endByte: entry.segment?.endIndex
            )
        }
    }

    /// Événements d'une génération en flux. Le dernier est toujours `.finished`.
    enum StreamEvent: Sendable {
        case text(String)
        case finished(Reply)
    }

    /// Génération en flux, livrée comme une suite d'événements : l'appelant les consomme dans
    /// l'ordre depuis son propre contexte, ce qui évite tout passage de fermeture entre acteurs.
    ///
    /// La documentation se contredit sur la forme exacte des fragments (réponses `candidates`
    /// d'un côté, événements `delta` de l'autre) : les deux sont acceptées, voir NOTES_API.md §3.3.
    func generateStream(model: String, request payload: Request) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try Self.encoder.encode(payload)
                    let urlRequest = request(
                        path: "/v1beta/models/\(model):streamGenerateContent?alt=sse",
                        method: "POST",
                        body: body
                    )

                    var full = ""
                    var usage = TokenUsage()
                    var passages: [Passage] = []
                    var supports: [Support] = []
                    var modelVersion = model

                    for try await line in try await HTTP.streamLines(urlRequest, provider: "Gemini") {
                        guard let data = line.data(using: .utf8) else { continue }

                        if let chunk = try? JSONDecoder().decode(GenerateResponse.self, from: data) {
                            let candidate = chunk.candidates?.first
                            let piece = (candidate?.content?.parts ?? []).compactMap(\.text).joined()
                            if !piece.isEmpty {
                                full += piece
                                continuation.yield(.text(piece))
                            }
                            if let chunkUsage = chunk.usageMetadata { usage = chunkUsage }
                            if let version = chunk.modelVersion { modelVersion = version }
                            // En flux, chaque réponse ne porte que les passages pas encore envoyés.
                            passages.append(contentsOf: Self.passages(from: candidate?.groundingMetadata))
                            supports.append(contentsOf: Self.supports(from: candidate?.groundingMetadata))
                            continue
                        }

                        // Forme alternative documentée : { "delta": { "type": "text", "text": … } }
                        if let event = try? JSONDecoder().decode(DeltaEvent.self, from: data),
                           let piece = event.delta?.text, !piece.isEmpty {
                            full += piece
                            continuation.yield(.text(piece))
                        }
                    }

                    continuation.yield(.finished(Reply(
                        text: full, usage: usage, model: modelVersion,
                        passages: passages, supports: supports
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct DeltaEvent: Decodable {
        struct Delta: Decodable {
            var type: String?
            var text: String?
        }
        var delta: Delta?
    }

    // ── Store File Search ────────────────────────────────────────────

    private struct StoreResource: Decodable {
        var name: String?
        var displayName: String?
        var activeDocumentsCount: String?
        var pendingDocumentsCount: String?
        var failedDocumentsCount: String?
        var sizeBytes: String?
    }

    struct StoreInfo: Sendable {
        var name: String
        var activeDocuments: Int
        var pendingDocuments: Int
        var failedDocuments: Int
        var sizeBytes: Int64
    }

    /// Crée le store au premier usage. Son `name` est attribué par Google et doit être conservé tel quel.
    func createStore(displayName: String = "latelier") async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "displayName": displayName,
            "embeddingModel": "models/gemini-embedding-001",
        ])
        let (data, _) = try await HTTP.send(
            request(path: "/v1beta/fileSearchStores", method: "POST", body: body),
            provider: "Gemini"
        )
        guard let store = try? JSONDecoder().decode(StoreResource.self, from: data), let name = store.name else {
            throw APIError(provider: "Gemini", status: 0, message: "Le store n'a pas pu être créé.")
        }
        return name
    }

    func storeInfo() async throws -> StoreInfo? {
        guard !storeName.isEmpty else { return nil }
        let (data, _) = try await HTTP.send(request(path: "/v1beta/\(storeName)"), provider: "Gemini")
        guard let store = try? JSONDecoder().decode(StoreResource.self, from: data), let name = store.name else {
            return nil
        }
        return StoreInfo(
            name: name,
            activeDocuments: Int(store.activeDocumentsCount ?? "0") ?? 0,
            pendingDocuments: Int(store.pendingDocumentsCount ?? "0") ?? 0,
            failedDocuments: Int(store.failedDocumentsCount ?? "0") ?? 0,
            sizeBytes: Int64(store.sizeBytes ?? "0") ?? 0
        )
    }

    struct StoreDocument: Decodable, Sendable {
        var name: String?
        var displayName: String?
        var state: String?
        var sizeBytes: String?
        var customMetadata: [Metadata]?

        /// Chemin relatif rangé à l'indexation : c'est lui qui identifie vraiment le fichier.
        var path: String? {
            customMetadata?.first { $0.key == "path" }?.stringValue
        }
    }

    /// La pagination plafonne à 20 éléments par page : il faut boucler.
    func listDocuments() async throws -> [StoreDocument] {
        guard !storeName.isEmpty else { return [] }
        struct Page: Decodable {
            var documents: [StoreDocument]?
            var nextPageToken: String?
        }
        var all: [StoreDocument] = []
        var token: String?
        repeat {
            var path = "/v1beta/\(storeName)/documents?pageSize=20"
            if let token, !token.isEmpty {
                path += "&pageToken=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
            }
            let (data, _) = try await HTTP.send(request(path: path), provider: "Gemini")
            let page = try JSONDecoder().decode(Page.self, from: data)
            all.append(contentsOf: page.documents ?? [])
            token = page.nextPageToken
        } while !(token ?? "").isEmpty && all.count < 20_000
        return all
    }

    /// `force=true` est de fait obligatoire : un document indexé contient toujours des chunks.
    func deleteDocument(named documentName: String) async throws {
        _ = try await HTTP.send(
            request(path: "/v1beta/\(documentName)?force=true", method: "DELETE"),
            provider: "Gemini"
        )
    }

    func deleteStore() async throws {
        guard !storeName.isEmpty else { return }
        _ = try await HTTP.send(
            request(path: "/v1beta/\(storeName)?force=true", method: "DELETE"),
            provider: "Gemini"
        )
    }

    // ── Envoi d'un fichier ───────────────────────────────────────────

    private struct Operation: Decodable {
        struct Failure: Decodable {
            var code: Int?
            var message: String?
        }
        var name: String?
        var done: Bool?
        var error: Failure?
        var response: [String: JSONAny]?
    }

    /// Envoie un fichier au store et attend la fin de l'indexation.
    /// Protocole reprenable en deux temps, exactement comme documenté.
    func uploadDocument(
        data fileData: Data,
        displayName: String,
        mimeType: String,
        relativePath: String,
        onState: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard !storeName.isEmpty else {
            throw APIError(provider: "Gemini", status: 0, message: "Aucun store n'est configuré.")
        }

        // Étape 1 : ouvrir l'envoi. L'URL utile est dans l'en-tête « x-goog-upload-url ».
        onState?("envoi")
        let metadata: [String: Any] = [
            "displayName": String(displayName.prefix(512)),
            "mimeType": mimeType,
            "customMetadata": [["key": "path", "stringValue": String(relativePath.prefix(512))]],
        ]
        let startRequest = request(
            path: "/upload/v1beta/\(storeName):uploadToFileSearchStore",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: metadata),
            extraHeaders: [
                "X-Goog-Upload-Protocol": "resumable",
                "X-Goog-Upload-Command": "start",
                "X-Goog-Upload-Header-Content-Length": String(fileData.count),
                "X-Goog-Upload-Header-Content-Type": mimeType,
            ]
        )
        let (_, startResponse) = try await HTTP.send(startRequest, provider: "Gemini")
        guard let uploadURLString = startResponse.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = URL(string: uploadURLString)
        else {
            throw APIError(provider: "Gemini", status: 0,
                           message: "Google n'a pas fourni d'adresse d'envoi pour ce fichier.")
        }

        // Étape 2 : envoyer les octets et finaliser.
        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(String(fileData.count), forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.httpBody = fileData
        let (operationData, _) = try await HTTP.send(
            upload, provider: "Gemini", attempts: 2, session: HTTP.uploadSession
        )

        // Étape 3 : attendre la fin de l'indexation.
        onState?("indexation")
        let operation = try JSONDecoder().decode(Operation.self, from: operationData)
        let finished = try await waitForOperation(operation)

        // Le nom du document n'est pas toujours présent dans la réponse de l'opération.
        // On ne va PAS le chercher ici : cela demanderait de lister tout le corpus, page de vingt
        // par page de vingt, pour chaque fichier envoyé. L'appelant réconcilie en une seule fois
        // à la fin du lot (voir FolderSync.reconcileDocumentNames).
        return finished.response?["name"]?.stringValue ?? ""
    }

    private func waitForOperation(_ operation: Operation, maxWait: TimeInterval = 900) async throws -> Operation {
        var current = operation
        let started = Date.now

        while !(current.done ?? false) {
            try Task.checkCancellation()
            guard Date.now.timeIntervalSince(started) < maxWait else {
                throw APIError(provider: "Gemini", status: 0,
                               message: "L'indexation par Google prend trop de temps.")
            }
            try await Task.sleep(for: .seconds(3))
            // Sans nom, l'opération n'est pas interrogeable : on ne peut pas conclure qu'elle
            // a réussi. La déclarer en échec fait réessayer au scan suivant, ce qui est juste.
            guard let name = current.name, !name.isEmpty else {
                throw APIError(provider: "Gemini", status: 0,
                               message: "Google n'a pas rendu d'opération suivable pour ce fichier.")
            }
            let (data, _) = try await HTTP.send(request(path: "/v1beta/\(name)"), provider: "Gemini", attempts: 2)
            current = try JSONDecoder().decode(Operation.self, from: data)
        }

        if let failure = current.error {
            throw APIError(provider: "Gemini", status: failure.code ?? 0,
                           message: failure.message ?? "Indexation refusée.")
        }
        return current
    }

    /// Table « chemin relatif → nom de document », obtenue en une seule traversée du corpus.
    ///
    /// La clé est le chemin, pas le nom affiché : deux fichiers peuvent très bien s'appeler
    /// « notes.pdf » dans deux sous-dossiers différents, et les confondre ferait disparaître
    /// le contenu de l'un en réindexant l'autre.
    func documentNamesByPath() async throws -> [String: String] {
        var table: [String: String] = [:]
        for document in try await listDocuments() {
            guard let name = document.name else { continue }
            if let path = document.path {
                table[path] = name
            }
        }
        return table
    }

    // ── Recherche dans le corpus ─────────────────────────────────────

    /// Interroge le corpus. Ce qui compte n'est pas la réponse du modèle mais les passages
    /// retrouvés, qui arrivent dans groundingMetadata avec leur numéro de page.
    func searchFiles(query: String, topK: Int = 12) async throws -> Reply {
        guard !storeName.isEmpty else {
            return Reply(text: "", usage: TokenUsage(), model: mainModel)
        }
        let payload = Request(
            contents: [.init(role: "user", parts: [.init(text: query)])],
            systemInstruction: .init(parts: [.init(text: Prompts.retrieval)]),
            tools: [.init(fileSearch: .init(fileSearchStoreNames: [storeName], topK: topK, metadataFilter: nil))],
            generationConfig: .init(maxOutputTokens: 400)
        )
        return try await generate(model: mainModel, request: payload)
    }

    // ── JSON structuré ───────────────────────────────────────────────

    /// Renvoie le texte brut plutôt qu'un dictionnaire : `[String: Any]` n'est pas `Sendable`
    /// et ne peut donc pas traverser la frontière d'acteur. L'appelant analyse le texte chez lui.
    func generateJSON(
        model: String? = nil,
        systemInstruction: String,
        prompt: String,
        schema: JSONValue?
    ) async throws -> (text: String, usage: TokenUsage, model: String) {
        let chosen = model ?? lightModel
        var config = Request.GenerationConfig(
            responseMimeType: "application/json",
            responseSchema: schema,
            temperature: 0.2
        )
        if GeminiModels.acceptsThinkingLevel(chosen) {
            config.thinkingConfig = .init(thinkingLevel: "MINIMAL")
        }
        let reply = try await generate(model: chosen, request: Request(
            contents: [.init(role: "user", parts: [.init(text: prompt)])],
            systemInstruction: .init(parts: [.init(text: systemInstruction)]),
            generationConfig: config
        ))
        return (reply.text, reply.usage, reply.model)
    }

    /// Le modèle peut encadrer sa réponse de balises Markdown : on lit quand même.
    static func parseJSONObject(_ text: String) -> [String: Any]? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = cleaned.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"), start < end else {
            return nil
        }
        let slice = String(cleaned[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // ── Transcription ────────────────────────────────────────────────

    /// Au-delà de cette taille, l'audio passe par l'API Files plutôt que d'être joint à la requête.
    /// La limite documentée est de 20 Mo pour la requête entière ; le base64 gonfle les octets d'un
    /// tiers, d'où cette marge (12 Mo bruts ≈ 16 Mo encodés ≈ 6 minutes de WAV 16 kHz mono).
    static let inlineAudioLimit = 12 * 1024 * 1024

    /// Transcrit un enregistrement. Choisit seule la voie courte ou la voie Files.
    func transcribe(
        audio: Data,
        mimeType: String = "audio/wav",
        vocabulary: [String] = [],
        onState: (@Sendable (String) -> Void)? = nil
    ) async throws -> Reply {
        let hint = vocabulary.isEmpty
            ? ""
            : "\nTermes et noms propres pouvant apparaître : \(vocabulary.prefix(80).joined(separator: ", "))."
        let instruction = Prompts.transcription + hint

        let audioPart: Request.Part
        if audio.count <= Self.inlineAudioLimit {
            audioPart = .init(inlineData: .init(mimeType: mimeType, data: audio.base64EncodedString()))
        } else {
            onState?("envoi de l'enregistrement")
            let uploaded = try await uploadTemporaryFile(data: audio, mimeType: mimeType, displayName: "memo")
            onState?("transcription")
            audioPart = .init(fileData: .init(mimeType: mimeType, fileUri: uploaded))
        }

        return try await generate(model: lightModel, request: Request(
            contents: [.init(role: "user", parts: [.init(text: instruction), audioPart])],
            generationConfig: .init(temperature: 0)
        ))
    }

    // ── API Files (fichiers temporaires, 48 h, gratuite) ─────────────

    private struct UploadedFile: Decodable {
        struct File: Decodable {
            var name: String?
            var uri: String?
            var state: String?
        }
        var file: File?
    }

    /// Envoie un fichier volumineux à l'API Files et renvoie son URI, une fois l'état ACTIVE atteint.
    /// Même protocole reprenable que le store, mais le corps de l'étape 1 est enveloppé dans « file »
    /// et la réponse de l'étape 2 l'est aussi — deux différences faciles à manquer.
    func uploadTemporaryFile(data fileData: Data, mimeType: String, displayName: String) async throws -> String {
        let metadata: [String: Any] = ["file": ["display_name": displayName]]
        let startRequest = request(
            path: "/upload/v1beta/files",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: metadata),
            extraHeaders: [
                "X-Goog-Upload-Protocol": "resumable",
                "X-Goog-Upload-Command": "start",
                "X-Goog-Upload-Header-Content-Length": String(fileData.count),
                "X-Goog-Upload-Header-Content-Type": mimeType,
            ]
        )
        let (_, startResponse) = try await HTTP.send(startRequest, provider: "Gemini")
        guard let urlString = startResponse.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = URL(string: urlString)
        else {
            throw APIError(provider: "Gemini", status: 0,
                           message: "Google n'a pas fourni d'adresse d'envoi pour l'enregistrement.")
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.httpBody = fileData
        let (data, _) = try await HTTP.send(upload, provider: "Gemini", attempts: 2, session: HTTP.uploadSession)

        let decoded = try JSONDecoder().decode(UploadedFile.self, from: data)
        guard let uri = decoded.file?.uri, let name = decoded.file?.name else {
            throw APIError(provider: "Gemini", status: 0, message: "Envoi de l'enregistrement refusé.")
        }

        // Un fichier reste inutilisable tant qu'il est en PROCESSING.
        var state = decoded.file?.state ?? "PROCESSING"
        var attempts = 0
        while state == "PROCESSING" && attempts < 60 {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            attempts += 1
            let (statusData, _) = try await HTTP.send(request(path: "/v1beta/\(name)"), provider: "Gemini", attempts: 2)
            // files.get renvoie l'objet nu, sans enveloppe « file ».
            struct BareFile: Decodable {
                var state: String?
                var uri: String?
            }
            // Un corps illisible ne dit rien : on garde l'état précédent plutôt que de
            // conclure que le fichier est prêt et de l'utiliser trop tôt.
            state = (try? JSONDecoder().decode(BareFile.self, from: statusData))?.state ?? state
        }
        guard state != "FAILED" else {
            throw APIError(provider: "Gemini", status: 0, message: "Google n'a pas pu lire l'enregistrement.")
        }
        guard state == "ACTIVE" else {
            throw APIError(provider: "Gemini", status: 0,
                           message: "Google met trop de temps à préparer l'enregistrement.")
        }
        return uri
    }

    // ── Vérification de la clé ───────────────────────────────────────

    func testKey() async throws -> String {
        let reply = try await generate(model: lightModel, request: Request(
            contents: [.init(role: "user", parts: [.init(text: "Réponds uniquement : ok")])],
            generationConfig: .init(maxOutputTokens: 10)
        ))
        return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Valeur JSON quelconque, pour lire les rares champs dont la forme n'est pas documentée
/// (le corps `response` d'une opération longue, par exemple).
struct JSONAny: Decodable, Sendable {
    var stringValue: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        stringValue = try? container.decode(String.self)
    }
}
