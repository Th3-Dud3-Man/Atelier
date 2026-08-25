import Foundation
import Observation

/// Ce dont le moteur a besoin pour indexer un fichier au vol (niveau 3 du Smart Search).
/// Implémenté par FolderSync ; déclaré ici pour que le moteur reste testable et lisible seul.
protocol FileIndexing: Sendable {
    /// Lit le fichier, l'envoie au store Gemini et met le registre à jour.
    /// Renvoie faux si le fichier est introuvable ou d'un format non pris en charge.
    @MainActor
    func indexOnDemand(fileID: String) async throws -> Bool
}

/// Conduit une recherche de bout en bout et publie son avancement pour l'écran de résultats.
@MainActor
@Observable
final class SearchEngine {

    enum Phase: Equatable {
        case idle
        case analyzing
        case searchingFiles
        case searchingWeb
        case indexing
        case synthesizing
        case awaitingChoice
        case done
        case failed
        case canceled
    }

    /// Carte affichée avant tout appel payant quand une recherche très proche existe déjà.
    struct DuplicatePrompt: Equatable {
        var previous: SearchRecord
        var addedConstraints: [String]
        var recommendation: String
    }

    enum DuplicateChoice { case reuse, complete, new }

    // ── État observé par les vues ────────────────────────────────────

    private(set) var record: SearchRecord?
    private(set) var phase: Phase = .idle
    private(set) var statusText: String = ""
    private(set) var errorText: String?
    private(set) var duplicatePrompt: DuplicatePrompt?
    /// Vrai pendant que la synthèse s'écrit, pour afficher le curseur.
    private(set) var isStreaming = false
    /// Question de suite en cours de rédaction, affichée au fil de l'eau.
    private(set) var pendingFollowUp: (question: String, text: String)?

    var isRunning: Bool {
        switch phase {
        case .analyzing, .searchingFiles, .searchingWeb, .indexing, .synthesizing: true
        default: false
        }
    }

    private let store: AppStore
    private let indexer: FileIndexing?
    private var task: Task<Void, Never>?
    /// Mémorisé pour pouvoir reprendre après le choix de l'utilisateur sur la carte de doublon.
    private var pendingRun: (question: String, mode: SourceMode, analysis: QueryAnalysis)?

    init(store: AppStore, indexer: FileIndexing? = nil) {
        self.store = store
        self.indexer = indexer
    }

    private var gemini: GeminiClient {
        GeminiClient(
            apiKey: Keychain.get(.gemini),
            mainModel: store.settings.mainModel,
            lightModel: store.settings.lightModel,
            storeName: store.settings.storeName
        )
    }

    private var perplexity: PerplexityClient {
        PerplexityClient(apiKey: Keychain.get(.perplexity))
    }

    // ── Lancement ────────────────────────────────────────────────────

    func start(question: String, mode: SourceMode, rawTranscript: String? = nil) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        cancel()
        errorText = nil
        duplicatePrompt = nil
        pendingFollowUp = nil
        pendingRun = nil

        var fresh = SearchRecord(question: trimmed)
        fresh.rawTranscript = rawTranscript
        fresh.sourceMode = mode
        fresh.priority = store.settings.priority
        fresh.webLevel = mode == .files ? nil : store.settings.webLevel
        record = fresh

        task = Task { [weak self] in
            await self?.run(question: trimmed, mode: mode)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isRunning {
            phase = .canceled
            statusText = "Recherche arrêtée."
            isStreaming = false
            if var current = record, current.status == .running {
                current.status = current.synthesis.isEmpty ? .canceled : .partial
                record = current
                store.upsert(current)
            }
        }
    }

    /// Rejoue la recherche en cours, à l'identique.
    func retry() {
        guard let current = record else { return }
        start(question: current.question, mode: current.sourceMode)
    }

    // ── Déroulé ──────────────────────────────────────────────────────

    private func run(question: String, mode: SourceMode) async {
        do {
            // 1. Étape gratuite : la même question a-t-elle déjà reçu une réponse ?
            if let match = Dedupe.exactMatch(for: question, in: store.searches),
               match.isFresh,
               !(match.record.analysis?.isRecentInfo ?? false) {
                reuse(match.record, automatic: true)
                return
            }

            guard !Keychain.get(.gemini).isEmpty else {
                throw APIError(provider: "Gemini", status: 401,
                               message: "Aucune clé Gemini n'est enregistrée.")
            }

            // 2. Analyse : un seul appel, qui décide aussi de la source et juge le doublon.
            phase = .analyzing
            statusText = "Analyse de la question…"
            let analysis = try await analyze(question: question)
            try Task.checkCancellation()

            if var current = record {
                current.analysis = analysis
                record = current
            }

            if analysis.needsClarification, let question = analysis.clarificationQuestion, !question.isEmpty {
                phase = .failed
                statusText = ""
                errorText = question
                finish(status: .partial)
                return
            }

            // 3. Doublon jugé par le modèle : on demande avant de dépenser.
            if let previous = duplicateCandidate(from: analysis), !analysis.isRecentInfo {
                pendingRun = (question, mode, analysis)
                duplicatePrompt = DuplicatePrompt(
                    previous: previous,
                    addedConstraints: analysis.addedConstraints,
                    recommendation: analysis.duplicateRecommendation ?? "new"
                )
                phase = .awaitingChoice
                statusText = ""
                return
            }

            try await proceed(question: question, mode: mode, analysis: analysis, forceWeb: false)
        } catch is CancellationError {
            phase = .canceled
            statusText = "Recherche arrêtée."
        } catch {
            fail(with: error)
        }
    }

    /// Réponse de l'utilisateur à la carte de doublon.
    func resolveDuplicate(_ choice: DuplicateChoice) {
        guard let pending = pendingRun, let prompt = duplicatePrompt else { return }
        duplicatePrompt = nil
        pendingRun = nil

        switch choice {
        case .reuse:
            reuse(prompt.previous, automatic: false)
        case .complete:
            // Ce qui manque, c'est ce que la recherche précédente n'a pas fait.
            let missing: SourceMode = prompt.previous.webSources.isEmpty ? .web : .files
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await proceed(question: pending.question, mode: missing,
                                      analysis: pending.analysis, forceWeb: missing == .web)
                } catch is CancellationError {
                    self.phase = .canceled
                } catch {
                    self.fail(with: error)
                }
            }
        case .new:
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await proceed(question: pending.question, mode: pending.mode,
                                      analysis: pending.analysis, forceWeb: false)
                } catch is CancellationError {
                    self.phase = .canceled
                } catch {
                    self.fail(with: error)
                }
            }
        }
    }

    private func duplicateCandidate(from analysis: QueryAnalysis) -> SearchRecord? {
        guard let id = analysis.duplicateOfID, !id.isEmpty,
              let recommendation = analysis.duplicateRecommendation,
              recommendation == "reuse" || recommendation == "complete",
              let previous = store.search(id: id),
              previous.status == .done, !previous.synthesis.isEmpty
        else { return nil }
        return previous
    }

    /// Réutilise un résultat précédent : aucun appel, aucun coût.
    private func reuse(_ previous: SearchRecord, automatic: Bool) {
        guard var current = record else { return }
        current.synthesis = previous.synthesis
        current.sources = previous.sources
        current.effectiveSource = previous.effectiveSource
        current.webLevel = previous.webLevel
        current.models = previous.models
        current.costUSD = 0
        current.reusedFromID = previous.id
        current.status = .done
        record = current
        store.upsert(current)
        phase = .done
        statusText = automatic
            ? "Résultat réutilisé, sans nouvelle dépense."
            : "Résultat précédent réutilisé."
    }

    // ── Cœur : recherche puis synthèse ───────────────────────────────

    private func proceed(question: String, mode: SourceMode, analysis: QueryAnalysis, forceWeb: Bool) async throws {
        let resolved = resolveSource(requested: mode, analysis: analysis, forceWeb: forceWeb)
        if var current = record {
            current.effectiveSource = resolved
            current.webLevel = resolved == .files ? nil : store.settings.webLevel
            record = current
        }

        // Plafond mensuel : au-delà, plus aucun appel payant.
        if store.capReached {
            phase = .failed
            statusText = ""
            errorText = "Plafond mensuel atteint (\(CostModel.format(store.settings.monthlyCapUSD))). "
                + "L'historique reste consultable ; relevez le plafond dans les réglages pour continuer à chercher."
            finish(status: .partial)
            return
        }

        var localSources: [SourceRef] = []
        var webSources: [SourceRef] = []
        var agentAnswer = ""

        let wantsFiles = resolved == .files || resolved == .both
        let wantsWeb = resolved == .web || resolved == .both

        if wantsFiles && wantsWeb && store.settings.priority == .parallel {
            phase = .searchingFiles
            statusText = "Recherche dans vos fichiers et sur Internet…"
            async let files = searchFiles(analysis: analysis)
            async let web = searchWeb(analysis: analysis, question: question)
            let (filesResult, webResult) = try await (files, web)
            localSources = filesResult
            webSources = webResult.sources
            agentAnswer = webResult.answer
        } else if store.settings.priority == .webFirst {
            if wantsWeb {
                let result = try await runWeb(analysis: analysis, question: question)
                webSources = result.sources
                agentAnswer = result.answer
            }
            if wantsFiles {
                localSources = try await runFiles(analysis: analysis)
            }
        } else {
            if wantsFiles {
                localSources = try await runFiles(analysis: analysis)
                // Niveau 3 : un fichier catalogué semble concerner la question.
                localSources = try await indexCandidatesIfNeeded(
                    analysis: analysis, currentSources: localSources
                )
            }
            if wantsWeb {
                let result = try await runWeb(analysis: analysis, question: question)
                webSources = result.sources
                agentAnswer = result.answer
            }
        }

        try Task.checkCancellation()

        var sources = localSources
        sources.append(contentsOf: webSources)
        if var current = record {
            current.sources = sources
            record = current
        }

        try await synthesize(
            question: question, analysis: analysis,
            localSources: localSources, webSources: webSources, agentAnswer: agentAnswer
        )
    }

    private func resolveSource(requested: SourceMode, analysis: QueryAnalysis, forceWeb: Bool) -> SourceMode {
        if forceWeb { return .web }
        var resolved = requested == .auto ? analysis.resolvedSource : requested
        // Sans clé Perplexity ou sans corpus, une source devient impossible : on le dit plus tard,
        // mais on ne lance pas un appel voué à l'échec.
        let hasWeb = !Keychain.get(.perplexity).isEmpty
        let hasCorpus = !store.settings.storeName.isEmpty && !store.indexedFiles.isEmpty
        if !hasWeb && resolved == .both { resolved = .files }
        if !hasCorpus && resolved == .both { resolved = .web }
        if !hasWeb && resolved == .web && hasCorpus { resolved = .files }
        if !hasCorpus && resolved == .files && hasWeb { resolved = .web }
        return resolved
    }

    private func runFiles(analysis: QueryAnalysis) async throws -> [SourceRef] {
        phase = .searchingFiles
        statusText = "Recherche dans vos fichiers…"
        return try await searchFiles(analysis: analysis)
    }

    private func runWeb(analysis: QueryAnalysis, question: String) async throws -> (sources: [SourceRef], answer: String) {
        phase = .searchingWeb
        statusText = store.settings.webLevel == .deep
            ? "Recherche approfondie sur Internet…"
            : "Recherche sur Internet…"
        return try await searchWeb(analysis: analysis, question: question)
    }

    // ── Appels ───────────────────────────────────────────────────────

    private func analyze(question: String) async throws -> QueryAnalysis {
        let unindexed = store.catalogedFiles
            .filter { $0.status == .cataloged }
            .sorted { $0.modified > $1.modified }
            .prefix(300)
            .map(\.name)

        let prompt = Prompts.analysisPrompt(
            question: question,
            recent: Array(store.searches.filter { $0.status == .done }.prefix(30)),
            unindexedNames: Array(unindexed)
        )

        let result = try await gemini.generateJSON(
            systemInstruction: Prompts.analysisSystem,
            prompt: prompt,
            schema: Prompts.analysisSchema
        )
        recordCost(provider: "Gemini", model: result.model, usage: result.usage, note: "analyse")
        let json = GeminiClient.parseJSONObject(result.text) ?? [:]
        return Self.decodeAnalysis(json, fallbackQuery: question)
    }

    static func decodeAnalysis(_ json: [String: Any], fallbackQuery: String) -> QueryAnalysis {
        func strings(_ key: String) -> [String] {
            (json[key] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        var analysis = QueryAnalysis()
        analysis.intent = json["intent"] as? String ?? "autre"
        analysis.preferredSource = json["preferredSource"] as? String ?? "both"
        analysis.reformulated = json["reformulated"] as? String ?? ""
        analysis.exactTerms = strings("exactTerms")
        analysis.probableQuotes = strings("probableQuotes")
        analysis.fileQuery = (json["fileQuery"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackQuery
        analysis.webQueries = strings("webQueries").isEmpty ? [fallbackQuery] : strings("webQueries")
        analysis.isRecentInfo = json["isRecentInfo"] as? Bool ?? false
        analysis.needsClarification = json["needsClarification"] as? Bool ?? false
        analysis.clarificationQuestion = json["clarificationQuestion"] as? String
        analysis.duplicateOfID = json["duplicateOfID"] as? String
        analysis.duplicateRecommendation = json["duplicateRecommendation"] as? String
        analysis.addedConstraints = strings("addedConstraints")
        analysis.candidateFiles = strings("candidateFiles")
        return analysis
    }

    private func searchFiles(analysis: QueryAnalysis) async throws -> [SourceRef] {
        guard !store.settings.storeName.isEmpty else { return [] }

        // La requête sémantique est enrichie des citations probables : c'est ce qui permet de
        // retrouver un passage dont la formulation ne reprend pas les mots de la question.
        var query = analysis.fileQuery
        if !analysis.probableQuotes.isEmpty {
            query += "\nFormulations possibles : " + analysis.probableQuotes.joined(separator: " / ")
        }
        if !analysis.exactTerms.isEmpty {
            query += "\nTermes exacts : " + analysis.exactTerms.joined(separator: ", ")
        }

        let reply = try await gemini.searchFiles(query: query)
        recordCost(provider: "Gemini", model: reply.model, usage: reply.usage, note: "recherche fichiers")
        return sources(from: reply.passages, startingAt: 1)
    }

    private func sources(from passages: [GeminiClient.Passage], startingAt start: Int) -> [SourceRef] {
        passages.enumerated().map { index, passage in
            SourceRef(
                tag: "L\(start + index)",
                kind: .local,
                title: passage.title,
                excerpt: passage.text,
                page: passage.page,
                url: nil,
                publishedAt: nil,
                relativePath: passage.relativePath
            )
        }
    }

    private func searchWeb(analysis: QueryAnalysis, question: String) async throws -> (sources: [SourceRef], answer: String) {
        guard !Keychain.get(.perplexity).isEmpty else { return ([], "") }
        let level = store.settings.webLevel
        let prices = store.settings.prices

        let outcome: PerplexityClient.SearchOutcome
        if level == .deep {
            outcome = try await perplexity.deepSearch(question: question, prices: prices)
        } else {
            outcome = try await perplexity.search(
                queries: analysis.webQueries.isEmpty ? [question] : analysis.webQueries,
                recency: analysis.isRecentInfo ? "month" : nil,
                prices: prices
            )
        }

        store.record(CostEntry(
            provider: "Perplexity",
            model: level == .deep ? "agent" : "search",
            usd: outcome.costUSD,
            searchID: record?.id,
            note: outcome.costIsMeasured ? "coût facturé" : "coût estimé"
        ))
        addCost(outcome.costUSD)

        let sources = outcome.results.enumerated().map { index, result in
            SourceRef(
                tag: "W\(index + 1)",
                kind: .web,
                title: result.title,
                excerpt: String(result.snippet.prefix(1500)),
                page: nil,
                url: result.url,
                publishedAt: result.date ?? result.lastUpdated,
                relativePath: nil
            )
        }
        return (sources, outcome.agentAnswer)
    }

    /// Niveau 3 du Smart Search : si l'analyse a repéré un fichier catalogué mais non indexé,
    /// l'app le lit, l'indexe et relance la recherche en l'incluant. Rien à faire pour l'utilisateur.
    private func indexCandidatesIfNeeded(
        analysis: QueryAnalysis,
        currentSources: [SourceRef]
    ) async throws -> [SourceRef] {
        guard store.settings.autoIndexSuggested,
              let indexer,
              !analysis.candidateFiles.isEmpty
        else { return currentSources }

        // On ne dérange le corpus que si la recherche n'a rien donné de solide.
        guard currentSources.count < 3 else { return currentSources }

        let candidates = store.catalogedFiles.filter { file in
            file.status == .cataloged && analysis.candidateFiles.contains { candidate in
                file.name.compare(candidate, options: .caseInsensitive) == .orderedSame
            }
        }
        guard !candidates.isEmpty else { return currentSources }

        phase = .indexing
        var indexed: [String] = []
        for file in candidates.prefix(3) {
            statusText = "Ajout de « \(file.name) » à l'index…"
            do {
                if try await indexer.indexOnDemand(fileID: file.id) {
                    indexed.append(file.name)
                }
            } catch {
                // Un fichier qui résiste ne doit pas faire échouer la recherche.
                continue
            }
        }
        guard !indexed.isEmpty else { return currentSources }

        if var current = record {
            for name in indexed {
                current.notes.append("« \(name) » a été ajouté à l'index.")
            }
            record = current
        }

        phase = .searchingFiles
        statusText = "Nouvelle recherche dans vos fichiers…"
        return try await searchFiles(analysis: analysis)
    }

    private func synthesize(
        question: String,
        analysis: QueryAnalysis,
        localSources: [SourceRef],
        webSources: [SourceRef],
        agentAnswer: String
    ) async throws {
        phase = .synthesizing
        statusText = "Rédaction de la synthèse…"
        isStreaming = true

        if var current = record {
            current.synthesis = ""
            record = current
        }

        let payload = GeminiClient.Request(
            contents: [.init(role: "user", parts: [.init(text: Prompts.synthesisPrompt(
                question: question, analysis: analysis,
                localSources: localSources, webSources: webSources, agentAnswer: agentAnswer
            ))])],
            systemInstruction: .init(parts: [.init(text: Prompts.synthesisSystem)]),
            generationConfig: .init(temperature: 0.3, maxOutputTokens: 1600)
        )

        let model = store.settings.mainModel
        var finalReply: GeminiClient.Reply?

        do {
            for try await event in gemini.generateStream(model: model, request: payload) {
                switch event {
                case .text(let piece):
                    if var current = record {
                        current.synthesis += piece
                        record = current
                    }
                case .finished(let reply):
                    finalReply = reply
                }
            }
        } catch is CancellationError {
            isStreaming = false
            throw CancellationError()
        } catch {
            // Le flux a échoué : on retente une fois sans streaming plutôt que de perdre la recherche.
            isStreaming = false
            let reply = try await gemini.generate(model: model, request: payload)
            if var current = record {
                current.synthesis = reply.text
                record = current
            }
            finalReply = reply
        }

        isStreaming = false
        if let reply = finalReply {
            recordCost(provider: "Gemini", model: reply.model, usage: reply.usage, note: "synthèse")
            if var current = record {
                current.models = Array(Set(current.models + [reply.model])).sorted()
                record = current
            }
        }

        finish(status: .done)
        statusText = ""
        phase = .done
    }

    // ── Questions de suite ───────────────────────────────────────────

    func askFollowUp(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = record, !current.synthesis.isEmpty else { return }

        task?.cancel()
        pendingFollowUp = (trimmed, "")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runFollowUp(trimmed, on: current)
            } catch is CancellationError {
                self.pendingFollowUp = nil
            } catch {
                self.pendingFollowUp = nil
                self.errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func runFollowUp(_ question: String, on base: SearchRecord) async throws {
        guard !store.capReached else {
            errorText = "Plafond mensuel atteint : les questions de suite reprendront le mois prochain, "
                + "ou après avoir relevé le plafond dans les réglages."
            pendingFollowUp = nil
            return
        }

        let payload = GeminiClient.Request(
            contents: [.init(role: "user", parts: [.init(text: Prompts.followUpPrompt(
                previousQuestion: base.question,
                previousSynthesis: base.synthesis,
                earlierTurns: base.followUps,
                sources: base.sources,
                question: question
            ))])],
            systemInstruction: .init(parts: [.init(text: Prompts.followUpSystem)]),
            generationConfig: .init(temperature: 0.3, maxOutputTokens: 900)
        )

        var text = ""
        var reply: GeminiClient.Reply?
        for try await event in gemini.generateStream(model: store.settings.mainModel, request: payload) {
            switch event {
            case .text(let piece):
                text += piece
                pendingFollowUp = (question, text)
            case .finished(let finished):
                reply = finished
            }
        }

        var turn = FollowUpTurn(question: question)
        turn.answer = text
        if let reply {
            let cost = CostModel.gemini(model: reply.model, usage: reply.usage, prices: store.settings.prices)
            turn.costUSD = cost
            recordCost(provider: "Gemini", model: reply.model, usage: reply.usage, note: "question de suite")
        }

        if var current = record {
            current.followUps.append(turn)
            record = current
            store.upsert(current)
        }
        pendingFollowUp = nil
    }

    // ── Ouvrir une recherche de l'historique ─────────────────────────

    func open(_ existing: SearchRecord) {
        cancel()
        record = existing
        phase = existing.status == .done ? .done : .failed
        statusText = ""
        errorText = existing.errorMessage
        duplicatePrompt = nil
        pendingFollowUp = nil
    }

    // ── Utilitaires ──────────────────────────────────────────────────

    private func recordCost(provider: String, model: String, usage: TokenUsage, note: String) {
        let amount = note == "transcription"
            ? CostModel.geminiAudio(model: model, usage: usage, prices: store.settings.prices)
            : CostModel.gemini(model: model, usage: usage, prices: store.settings.prices)
        store.record(CostEntry(
            provider: provider,
            model: model,
            usd: amount,
            tokensIn: usage.inputTokens,
            tokensOut: usage.outputTokens,
            searchID: record?.id,
            note: note
        ))
        addCost(amount)
    }

    private func addCost(_ amount: Double) {
        guard var current = record else { return }
        current.costUSD += amount
        record = current
    }

    private func finish(status: SearchStatus) {
        guard var current = record else { return }
        current.status = status
        record = current
        store.upsert(current)
    }

    private func fail(with error: Error) {
        isStreaming = false
        phase = .failed
        statusText = ""
        errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
        if var current = record {
            current.status = current.synthesis.isEmpty ? .failed : .partial
            current.errorMessage = errorText
            record = current
            store.upsert(current)
        }
    }
}
