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
///
/// Une règle traverse tout ce fichier : **chaque écriture est rattachée à l'identifiant de la
/// recherche qui l'a demandée**. Une recherche annulée peut encore être suspendue dans un `await`
/// quand la suivante démarre ; sans ce garde-fou, son coût et son avancement viendraient s'écrire
/// sur la nouvelle.
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

    /// Carte affichée quand une recherche très proche existe déjà.
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
    /// Question de clarification quand la demande est réellement inintelligible.
    /// Ce n'est pas une erreur : elle s'affiche comme une question, pas comme un échec.
    private(set) var clarification: String?
    /// Plafond atteint. État distinct d'une erreur : réessayer ne servirait à rien.
    private(set) var capBlocked: String?
    /// Avertissement de budget, montré une seule fois quand 80 % du plafond est franchi.
    private(set) var budgetWarning: String?
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
    /// Mémorisé pour reprendre après le choix de l'utilisateur sur la carte de doublon.
    private var pendingRun: (question: String, mode: SourceMode, analysis: QueryAnalysis, runID: String)?

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

    // ── Écriture rattachée à une recherche ───────────────────────────

    /// Vrai tant que la recherche `runID` est bien celle affichée.
    private func isCurrent(_ runID: String) -> Bool {
        record?.id == runID
    }

    /// Modifie la recherche en cours, et seulement si c'est bien celle qui le demande.
    @discardableResult
    private func mutate(_ runID: String, _ change: (inout SearchRecord) -> Void) -> Bool {
        guard var current = record, current.id == runID else { return false }
        change(&current)
        record = current
        return true
    }

    private func setStatus(_ runID: String, phase newPhase: Phase, text: String) {
        guard isCurrent(runID) else { return }
        phase = newPhase
        statusText = text
    }

    // ── Lancement ────────────────────────────────────────────────────

    /// - Parameter allowReuse: mettre à faux pour forcer une vraie recherche.
    ///   « Relancer », « Compléter sur Internet » et « Approfondir » passent par là : sans cela,
    ///   la question étant identique, la réutilisation gratuite les rendrait sans effet.
    /// `keeping` et `forced` servent au bouton « Compléter » : la moitié déjà obtenue est
    /// reprise telle quelle, et seule la moitié manquante est relancée — et donc facturée.
    func start(
        question: String,
        mode: SourceMode,
        rawTranscript: String? = nil,
        allowReuse: Bool = true,
        keeping: [SourceRef] = [],
        forced: SourceMode? = nil
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        cancel()
        clearTransientState()
        // cancel() a pu laisser « Recherche arrêtée. » à l'écran : on repart propre, sinon ce
        // message s'affiche brièvement au lancement de la recherche suivante.
        phase = .idle
        statusText = ""

        var fresh = SearchRecord(question: trimmed)
        fresh.rawTranscript = rawTranscript
        fresh.sourceMode = mode
        fresh.priority = store.settings.priority
        fresh.webLevel = mode == .files ? nil : store.settings.webLevel
        // Les passages conservés s'affichent dès le départ : la moitié déjà lue ne disparaît pas
        // de l'écran pendant que l'autre se cherche.
        fresh.sources = keeping
        record = fresh
        // Enregistrée dès sa création : une recherche interrompue par une fermeture de l'app
        // ne doit pas disparaître de l'historique en laissant son coût au compteur.
        store.upsert(fresh)

        let runID = fresh.id
        task = Task { [weak self] in
            await self?.run(
                question: trimmed, mode: mode, runID: runID,
                allowReuse: allowReuse, keeping: keeping, forced: forced
            )
        }
    }

    private func clearTransientState() {
        errorText = nil
        clarification = nil
        capBlocked = nil
        budgetWarning = nil
        duplicatePrompt = nil
        pendingFollowUp = nil
        pendingRun = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        guard isRunning else { return }
        phase = .canceled
        statusText = "Recherche arrêtée."
        isStreaming = false
        if var current = record, current.status == .running {
            current.status = current.synthesis.isEmpty ? .canceled : .partial
            record = current
            store.upsert(current)
        }
    }

    /// Repart de zéro : sur iPad, l'accueil ne réapparaît que si plus aucune recherche n'est en cours.
    func reset() {
        cancel()
        record = nil
        phase = .idle
        statusText = ""
        clearTransientState()
    }

    /// Rejoue la recherche en cours, pour de vrai.
    func retry() {
        guard let current = record else { return }
        start(question: current.question, mode: current.sourceMode, allowReuse: false)
    }

    /// Relance en ajoutant Internet à un résultat obtenu sur les seuls fichiers.
    /// Le mode est bien « les deux » : relancer sur `.web` seul remplacerait les passages
    /// locaux au lieu de les compléter, et ferait disparaître le bouton avec eux.
    func completeWithWeb() {
        guard let current = record else { return }
        let kept = current.localSources
        start(
            question: current.question,
            mode: .both,
            allowReuse: false,
            keeping: kept,
            // Rien à garder — le résultat précédent n'avait aucun passage local : autant
            // laisser l'analyse choisir les deux moitiés.
            forced: kept.isEmpty ? nil : .web
        )
    }

    /// Relance au niveau approfondi.
    func deepen() {
        guard let current = record else { return }
        store.updateSettings { $0.webLevel = .deep }
        start(question: current.question, mode: current.effectiveSource, allowReuse: false)
    }

    // ── Déroulé ──────────────────────────────────────────────────────

    private func run(
        question: String,
        mode: SourceMode,
        runID: String,
        allowReuse: Bool,
        keeping: [SourceRef] = [],
        forced: SourceMode? = nil
    ) async {
        do {
            // 1. Étape gratuite : la même question a-t-elle déjà reçu une réponse ?
            if allowReuse,
               let match = Dedupe.exactMatch(for: question, in: store.searches.filter({ $0.id != runID })),
               match.isFresh,
               !(match.record.analysis?.isRecentInfo ?? false) {
                reuse(match.record, runID: runID, automatic: true)
                return
            }

            guard !Keychain.get(.gemini).isEmpty else {
                throw APIError(provider: "Gemini", status: 401,
                               message: "Aucune clé Gemini n'est enregistrée.")
            }

            // 2. Plafond mensuel. La vérification vient AVANT l'analyse, qui est elle-même
            // un appel payant. La réutilisation ci-dessus reste possible : elle ne coûte rien.
            if store.capReached {
                stopAtCap(runID: runID)
                return
            }

            // 3. Analyse : un seul appel, qui décide aussi de la source et juge le doublon.
            setStatus(runID, phase: .analyzing, text: "Analyse de la question…")
            let analysis = try await analyze(question: question, runID: runID)
            try Task.checkCancellation()
            guard isCurrent(runID) else { return }

            mutate(runID) { $0.analysis = analysis }

            // Question inintelligible : on demande une précision plutôt que de dépenser davantage.
            if analysis.needsClarification, let precision = analysis.clarificationQuestion, !precision.isEmpty {
                phase = .done
                statusText = ""
                clarification = precision
                finish(runID: runID, status: .partial)
                return
            }

            // 4. Doublon jugé par le modèle : on demande avant d'aller plus loin.
            if allowReuse, let previous = duplicateCandidate(from: analysis), !analysis.isRecentInfo {
                pendingRun = (question, mode, analysis, runID)
                duplicatePrompt = DuplicatePrompt(
                    previous: previous,
                    addedConstraints: analysis.addedConstraints,
                    recommendation: analysis.duplicateRecommendation ?? "new"
                )
                phase = .awaitingChoice
                statusText = ""
                return
            }

            try await proceed(
                question: question, mode: mode, analysis: analysis, runID: runID,
                forced: forced, keeping: keeping
            )
        } catch is CancellationError {
            if isCurrent(runID) {
                phase = .canceled
                statusText = "Recherche arrêtée."
            }
        } catch {
            fail(with: error, runID: runID)
        }
    }

    /// Réponse de l'utilisateur à la carte de doublon.
    func resolveDuplicate(_ choice: DuplicateChoice) {
        guard let pending = pendingRun, let prompt = duplicatePrompt else { return }
        duplicatePrompt = nil
        pendingRun = nil
        guard isCurrent(pending.runID) else { return }

        switch choice {
        case .reuse:
            reuse(prompt.previous, runID: pending.runID, automatic: false)

        case .complete:
            // On garde la moitié déjà obtenue et on ne relance que ce qui manque.
            let previousHasWeb = !prompt.previous.webSources.isEmpty
            let missing: SourceMode = previousHasWeb ? .files : .web
            let kept = previousHasWeb ? prompt.previous.webSources : prompt.previous.localSources

            // Si la moitié manquante est justement celle qu'on ne peut pas faire, mieux vaut
            // réutiliser et le dire, plutôt que de refaire en silence la moitié déjà en main.
            guard canSearch(missing) else {
                reuse(prompt.previous, runID: pending.runID, automatic: false)
                errorText = missing == .web
                    ? "La partie Internet n'a pas pu être ajoutée : aucune clé Perplexity n'est enregistrée."
                    : "La partie fichiers n'a pas pu être ajoutée : aucun document n'est indexé."
                return
            }

            mutate(pending.runID) { record in
                record.sources = kept
                record.reusedFromID = prompt.previous.id
            }
            launch(pending, mode: missing, forced: missing, keeping: kept)

        case .new:
            launch(pending, mode: pending.mode, forced: nil, keeping: [])
        }
    }

    private func launch(
        _ pending: (question: String, mode: SourceMode, analysis: QueryAnalysis, runID: String),
        mode: SourceMode,
        forced: SourceMode?,
        keeping: [SourceRef]
    ) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.proceed(
                    question: pending.question, mode: mode, analysis: pending.analysis,
                    runID: pending.runID, forced: forced, keeping: keeping
                )
            } catch is CancellationError {
                if self.isCurrent(pending.runID) { self.phase = .canceled }
            } catch {
                self.fail(with: error, runID: pending.runID)
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

    /// Réutilise un résultat précédent. Aucune nouvelle recherche n'est lancée ; le coût déjà
    /// engagé (l'analyse, quand la carte de doublon a été montrée) reste compté, il a bien eu lieu.
    private func reuse(_ previous: SearchRecord, runID: String, automatic: Bool) {
        let applied = mutate(runID) { current in
            current.synthesis = previous.synthesis
            current.sources = previous.sources
            current.effectiveSource = previous.effectiveSource
            current.webLevel = previous.webLevel
            current.models = previous.models
            current.reusedFromID = previous.id
            current.status = .done
        }
        guard applied else { return }
        persist(runID)
        phase = .done
        statusText = automatic
            ? "Résultat réutilisé : aucune recherche n'a été relancée."
            : "Résultat précédent réutilisé."
    }

    // ── Cœur : recherche puis synthèse ───────────────────────────────

    private func proceed(
        question: String,
        mode: SourceMode,
        analysis: QueryAnalysis,
        runID: String,
        forced: SourceMode? = nil,
        keeping: [SourceRef] = []
    ) async throws {
        guard isCurrent(runID) else { return }

        let resolved = forced ?? resolveSource(requested: mode, analysis: analysis)
        mutate(runID) { current in
            // En mode « Compléter », la source affichée reflète les deux moitiés.
            current.effectiveSource = keeping.isEmpty ? resolved : .both
            // Le niveau se lit sur ce que la fiche montre, pas sur la moitié relancée :
            // en « Compléter les fichiers », `resolved` vaut `.files` alors que la fiche
            // conserve des sources web, dont le niveau doit rester affiché.
            current.webLevel = current.effectiveSource == .files ? nil : self.store.settings.webLevel
        }

        // Le plafond a pu être franchi entre-temps, par une question de suite par exemple.
        if store.capReached {
            stopAtCap(runID: runID)
            return
        }

        var localSources = keeping.filter { $0.kind == .local }
        var webSources = keeping.filter { $0.kind == .web }
        var agentAnswer = ""

        let wantsFiles = resolved == .files || resolved == .both
        let wantsWeb = resolved == .web || resolved == .both

        if wantsFiles && wantsWeb && store.settings.priority == .parallel {
            setStatus(runID, phase: .searchingFiles, text: "Recherche dans vos fichiers et sur Internet…")
            async let files = searchFiles(analysis: analysis, runID: runID)
            async let web = searchWeb(analysis: analysis, question: question, runID: runID)
            let (filesResult, webResult) = try await (files, web)
            localSources = filesResult
            webSources = webResult.sources
            agentAnswer = webResult.answer
        } else if store.settings.priority == .webFirst {
            if wantsWeb {
                setStatus(runID, phase: .searchingWeb, text: webStatusText)
                let result = try await searchWeb(analysis: analysis, question: question, runID: runID)
                webSources = result.sources
                agentAnswer = result.answer
            }
            if wantsFiles {
                setStatus(runID, phase: .searchingFiles, text: "Recherche dans vos fichiers…")
                localSources = try await searchFiles(analysis: analysis, runID: runID)
            }
        } else {
            if wantsFiles {
                setStatus(runID, phase: .searchingFiles, text: "Recherche dans vos fichiers…")
                localSources = try await searchFiles(analysis: analysis, runID: runID)
            }
            if wantsWeb {
                setStatus(runID, phase: .searchingWeb, text: webStatusText)
                let result = try await searchWeb(analysis: analysis, question: question, runID: runID)
                webSources = result.sources
                agentAnswer = result.answer
            }
        }

        // Niveau 3 du Smart Search, quelle que soit la priorité : si l'analyse a repéré un fichier
        // catalogué qui concerne manifestement la question et que la moisson est maigre, l'app le
        // lit, l'indexe et refait la recherche en l'incluant.
        if wantsFiles {
            localSources = try await indexCandidatesIfNeeded(
                analysis: analysis, currentSources: localSources, runID: runID
            )
        }

        try Task.checkCancellation()
        guard isCurrent(runID) else { return }

        // Renumérotation finale : les marqueurs donnés au rédacteur doivent être exactement
        // ceux des cartes affichées, sans quoi chaque citation pointerait à côté.
        localSources = renumber(localSources, prefix: "L")
        webSources = renumber(webSources, prefix: "W")
        mutate(runID) { $0.sources = localSources + webSources }

        try await synthesize(
            question: question, analysis: analysis, runID: runID,
            localSources: localSources, webSources: webSources, agentAnswer: agentAnswer
        )
    }

    private var webStatusText: String {
        store.settings.webLevel == .deep
            ? "Recherche approfondie sur Internet…"
            : "Recherche sur Internet…"
    }

    private func renumber(_ sources: [SourceRef], prefix: String) -> [SourceRef] {
        sources.enumerated().map { index, source in
            var copy = source
            copy.tag = "\(prefix)\(index + 1)"
            return copy
        }
    }

    /// Cette source est-elle seulement possible dans l'état actuel ?
    private func canSearch(_ source: SourceMode) -> Bool {
        switch source {
        case .web: !Keychain.get(.perplexity).isEmpty
        case .files: !store.settings.storeName.isEmpty && !store.indexedFiles.isEmpty
        case .both, .auto: true
        }
    }

    private func resolveSource(requested: SourceMode, analysis: QueryAnalysis) -> SourceMode {
        var resolved = requested == .auto ? analysis.resolvedSource : requested
        // Sans clé Perplexity ou sans corpus, une source devient impossible : plutôt que de lancer
        // un appel voué à l'échec, on bascule sur celle qui reste.
        let hasWeb = canSearch(.web)
        let hasCorpus = canSearch(.files)
        if !hasWeb && resolved == .both { resolved = .files }
        if !hasCorpus && resolved == .both { resolved = .web }
        if !hasWeb && resolved == .web && hasCorpus { resolved = .files }
        if !hasCorpus && resolved == .files && hasWeb { resolved = .web }
        return resolved
    }

    // ── Appels ───────────────────────────────────────────────────────

    private func analyze(question: String, runID: String) async throws -> QueryAnalysis {
        let prompt = Prompts.analysisPrompt(
            question: question,
            recent: Array(store.searches.filter { $0.status == .done && $0.id != runID }.prefix(30)),
            unindexedNames: catalogueShortlist(for: question)
        )

        let result = try await gemini.generateJSON(
            systemInstruction: Prompts.analysisSystem,
            prompt: prompt,
            schema: Prompts.analysisSchema
        )
        recordCost(runID: runID, provider: "Gemini", model: result.model, usage: result.usage, note: "analyse")
        let json = GeminiClient.parseJSONObject(result.text) ?? [:]
        return Self.decodeAnalysis(json, fallbackQuery: question)
    }

    /// Noms de fichiers catalogués soumis à l'analyse — au plus trois cents.
    ///
    /// Sur un corpus plus gros que le budget, le catalogue peut compter des dizaines de milliers
    /// d'entrées : envoyer les trois cents plus récentes reviendrait à ne jamais montrer le bon
    /// fichier. On rapproche donc d'abord les mots de la question du **chemin** de chaque fichier
    /// — un simple filtrage de texte sur une liste déjà en mémoire, sans index ni empreinte — puis
    /// on complète avec les plus récents si la place le permet.
    private func catalogueShortlist(for question: String, limit: Int = 300) -> [String] {
        let cataloged = store.files.filter { $0.status == .cataloged }
        guard cataloged.count > limit else {
            return cataloged.sorted { $0.modified > $1.modified }.map(\.name)
        }

        let words = Dedupe.keywords(question)
        var matched: [(entry: FileEntry, score: Int)] = []
        if !words.isEmpty {
            for entry in cataloged {
                let haystack = Dedupe.foldedPath(entry.relativePath)
                let score = words.reduce(into: 0) { total, word in
                    if haystack.contains(word) { total += 1 }
                }
                if score > 0 { matched.append((entry, score)) }
            }
        }

        var shortlist = matched
            .sorted { ($0.score, $0.entry.modified) > ($1.score, $1.entry.modified) }
            .prefix(limit)
            .map(\.entry)

        if shortlist.count < limit {
            let chosen = Set(shortlist.map(\.id))
            let filler = cataloged
                .filter { !chosen.contains($0.id) }
                .sorted { $0.modified > $1.modified }
                .prefix(limit - shortlist.count)
            shortlist.append(contentsOf: filler)
        }
        return shortlist.map(\.name)
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

    private func searchFiles(analysis: QueryAnalysis, runID: String) async throws -> [SourceRef] {
        guard !store.settings.storeName.isEmpty else { return [] }

        // La requête est enrichie des citations probables : c'est ce qui permet de retrouver un
        // passage dont la formulation ne reprend pas les mots de la question.
        var query = analysis.fileQuery
        if !analysis.probableQuotes.isEmpty {
            query += "\nFormulations possibles : " + analysis.probableQuotes.joined(separator: " / ")
        }
        if !analysis.exactTerms.isEmpty {
            query += "\nTermes exacts : " + analysis.exactTerms.joined(separator: ", ")
        }

        let reply = try await gemini.searchFiles(query: query)
        recordCost(runID: runID, provider: "Gemini", model: reply.model,
                   usage: reply.usage, note: "recherche fichiers")
        return reply.passages.map { passage in
            SourceRef(
                tag: "L?",
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

    private func searchWeb(
        analysis: QueryAnalysis,
        question: String,
        runID: String
    ) async throws -> (sources: [SourceRef], answer: String) {
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
            searchID: runID,
            note: outcome.costIsMeasured ? "coût facturé" : "coût estimé"
        ))
        addCost(runID: runID, outcome.costUSD)

        let sources = outcome.results.map { result in
            SourceRef(
                tag: "W?",
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

    /// Niveau 3 du Smart Search : l'app lit, indexe et relance seule. Rien à faire pour l'utilisateur.
    private func indexCandidatesIfNeeded(
        analysis: QueryAnalysis,
        currentSources: [SourceRef],
        runID: String
    ) async throws -> [SourceRef] {
        guard store.settings.autoIndexSuggested,
              let indexer,
              !analysis.candidateFiles.isEmpty,
              // On ne dérange le corpus que si la recherche n'a rien donné de solide.
              currentSources.count < 3
        else { return currentSources }

        let candidates = store.files.filter { file in
            file.status == .cataloged && analysis.candidateFiles.contains { candidate in
                file.name.compare(candidate, options: .caseInsensitive) == .orderedSame
            }
        }
        guard !candidates.isEmpty else { return currentSources }

        setStatus(runID, phase: .indexing, text: "")
        var indexed: [String] = []
        for file in candidates.prefix(3) {
            guard isCurrent(runID) else { return currentSources }
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
        guard !indexed.isEmpty, isCurrent(runID) else { return currentSources }

        mutate(runID) { current in
            for name in indexed {
                current.notes.append("« \(name) » a été ajouté à l'index.")
            }
        }

        setStatus(runID, phase: .searchingFiles, text: "Nouvelle recherche dans vos fichiers…")
        let refreshed = try await searchFiles(analysis: analysis, runID: runID)
        // Le classement de File Search change quand de nouveaux documents entrent dans le store :
        // la seconde recherche peut rapporter moins que la première. On garde alors la meilleure
        // des deux, plutôt que d'appauvrir la synthèse au moment même où l'on annonce l'avoir
        // enrichie.
        return refreshed.count >= currentSources.count ? refreshed : currentSources
    }

    private func synthesize(
        question: String,
        analysis: QueryAnalysis,
        runID: String,
        localSources: [SourceRef],
        webSources: [SourceRef],
        agentAnswer: String
    ) async throws {
        setStatus(runID, phase: .synthesizing, text: "Rédaction de la synthèse…")
        isStreaming = true
        mutate(runID) { $0.synthesis = "" }

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
                guard isCurrent(runID) else { return }
                switch event {
                case .text(let piece):
                    mutate(runID) { $0.synthesis += piece }
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
            mutate(runID) { $0.synthesis = reply.text }
            finalReply = reply
        }

        isStreaming = false
        guard isCurrent(runID) else { return }

        if let reply = finalReply {
            recordCost(runID: runID, provider: "Gemini", model: reply.model,
                       usage: reply.usage, note: "synthèse")
            mutate(runID) { current in
                current.models = Array(Set(current.models + [reply.model])).sorted()
            }
        }

        budgetWarning = store.consumeBudgetWarning()
        finish(runID: runID, status: .done)
        statusText = ""
        phase = .done
    }

    // ── Questions de suite ───────────────────────────────────────────

    func askFollowUp(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = record, !current.synthesis.isEmpty else { return }

        task?.cancel()
        pendingFollowUp = (trimmed, "")
        let runID = current.id
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runFollowUp(trimmed, on: current, runID: runID)
            } catch is CancellationError {
                self.pendingFollowUp = nil
            } catch {
                self.pendingFollowUp = nil
                if self.isCurrent(runID) {
                    self.errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func runFollowUp(_ question: String, on base: SearchRecord, runID: String) async throws {
        guard !store.capReached else {
            pendingFollowUp = nil
            capBlocked = capMessage
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
            guard isCurrent(runID) else { return }
            switch event {
            case .text(let piece):
                text += piece
                pendingFollowUp = (question, text)
            case .finished(let finished):
                reply = finished
            }
        }

        guard isCurrent(runID) else { return }

        var turn = FollowUpTurn(question: question)
        turn.answer = text
        if let reply {
            turn.costUSD = CostModel.gemini(model: reply.model, usage: reply.usage, prices: store.settings.prices)
            recordCost(runID: runID, provider: "Gemini", model: reply.model,
                       usage: reply.usage, note: "question de suite")
        }

        mutate(runID) { $0.followUps.append(turn) }
        persist(runID)
        budgetWarning = store.consumeBudgetWarning()
        pendingFollowUp = nil
    }

    // ── Ouvrir une recherche de l'historique ─────────────────────────

    func open(_ existing: SearchRecord) {
        cancel()
        clearTransientState()
        record = existing
        phase = existing.status == .done ? .done : .failed
        statusText = ""
        errorText = existing.errorMessage
    }

    // ── Utilitaires ──────────────────────────────────────────────────

    private func recordCost(runID: String, provider: String, model: String, usage: TokenUsage, note: String) {
        let amount = CostModel.gemini(model: model, usage: usage, prices: store.settings.prices)
        store.record(CostEntry(
            provider: provider,
            model: model,
            usd: amount,
            tokensIn: usage.inputTokens,
            tokensOut: usage.outputTokens,
            searchID: runID,
            note: note
        ))
        addCost(runID: runID, amount)
    }

    /// Le coût suit la recherche qui l'a engagé, même si l'écran affiche déjà la suivante.
    private func addCost(runID: String, _ amount: Double) {
        if mutate(runID, { $0.costUSD += amount }) {
            persist(runID)
        } else if var stale = store.search(id: runID) {
            stale.costUSD += amount
            store.upsert(stale)
        }
    }

    private func persist(_ runID: String) {
        guard let current = record, current.id == runID else { return }
        store.upsert(current)
    }

    private func finish(runID: String, status: SearchStatus) {
        mutate(runID) { $0.status = status }
        persist(runID)
    }

    private var capMessage: String {
        "Plafond mensuel atteint (\(CostModel.format(store.settings.monthlyCapUSD))). "
            + "L'historique et les résultats déjà obtenus restent consultables ; "
            + "relevez le plafond dans les réglages pour chercher de nouveau."
    }

    /// Mode gratuit. État distinct d'une erreur : proposer « Réessayer » n'aurait aucun sens.
    private func stopAtCap(runID: String) {
        guard isCurrent(runID) else { return }
        phase = .failed
        statusText = ""
        capBlocked = capMessage
        finish(runID: runID, status: .partial)
    }

    private func fail(with error: Error, runID: String) {
        isStreaming = false
        guard isCurrent(runID) else { return }
        phase = .failed
        statusText = ""
        let message = (error as? APIError)?.errorDescription ?? error.localizedDescription
        errorText = message
        mutate(runID) { current in
            current.status = current.synthesis.isEmpty ? .failed : .partial
            current.errorMessage = message
        }
        persist(runID)
    }
}
