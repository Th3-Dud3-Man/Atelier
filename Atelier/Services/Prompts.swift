import Foundation

/// Textes envoyés aux modèles. Regroupés ici pour être relus et ajustés en un seul endroit.
enum Prompts {

    // ── Récupération dans le corpus ──────────────────────────────────

    /// Cet appel sert d'abord à déclencher File Search : ce qui compte, ce sont les passages
    /// retrouvés, pas la réponse. On la garde très courte pour ne pas payer de tokens inutiles.
    static let retrieval = """
    Tu interroges les documents personnels de l'utilisateur. Réponds en français, en trois phrases \
    au maximum, en t'appuyant uniquement sur les passages retrouvés dans ces documents. \
    Si aucun passage pertinent n'est retrouvé, réponds exactement : AUCUN.
    """

    // ── Analyse de la question ───────────────────────────────────────

    static let analysisSystem = """
    Tu es l'analyste de requêtes d'un moteur de recherche personnel. On te donne une question en \
    langage naturel, souvent en français, parfois dictée. Ta tâche est de la comprendre et de \
    préparer la recherche. Tu ne réponds jamais à la question elle-même.

    Règles :
    1. « intent » décrit la nature de la demande : passages, question factuelle, actualité, \
    définition, comparaison, autre.
    2. « preferredSource » vaut « files » si la question vise les documents personnels (formulations \
    du type « dans mes documents », auteurs et œuvres que l'utilisateur possède, recherche de \
    citations), « internet » si elle vise l'actualité, des publications récentes ou des faits \
    généraux, « both » en cas de doute.
    3. « exactTerms » contient les expressions à chercher mot pour mot. « probableQuotes » contient \
    des formulations verbatim plausibles du passage recherché : par exemple, pour « le rêve de \
    l'enfant qui brûle », « Père, ne vois-tu pas que je brûle ? ».
    4. « fileQuery » est une phrase riche en français décrivant le passage idéal à retrouver dans \
    les documents. Elle sert de requête sémantique : écris-la comme le contenu recherché, pas comme \
    une question.
    5. « webQueries » : une à trois requêtes efficaces pour un moteur de recherche, dans la langue \
    la plus pertinente pour le sujet.
    6. « isRecentInfo » est vrai si la réponse dépend de l'actualité ou de publications récentes.
    7. « needsClarification » n'est vrai que si la question est réellement inintelligible, jamais \
    parce qu'elle est vaste.
    8. N'invente ni auteur, ni œuvre, ni référence : ne remplis un champ que si la question le dit \
    ou l'implique clairement.

    On te donne aussi les recherches récentes de l'utilisateur et la liste des fichiers connus mais \
    non encore indexés.
    9. Doublon : si une recherche récente demande la même chose, mets son identifiant dans \
    « duplicateOfID », liste dans « addedConstraints » ce que la nouvelle question ajoute ou \
    restreint, et recommande « reuse » (même demande, rien d'ajouté), « complete » (même demande, \
    mais une source ou une contrainte manque) ou « new ». Sois strict : un angle réellement \
    différent vaut « new ».
    10. « candidateFiles » : uniquement les noms de fichiers non indexés dont le nom indique \
    clairement qu'ils concernent la question. Recopie le nom exactement. Dans le doute, laisse vide.
    """

    /// Schéma de la réponse attendue. Dialecte OpenAPI de Gemini : types en MAJUSCULES.
    static let analysisSchema: JSONValue = .schemaObject([
        "intent": .enumField("Nature de la demande",
                             ["passages", "factuelle", "actualite", "definition", "comparaison", "autre"]),
        "preferredSource": .enumField("Où chercher", ["files", "internet", "both"]),
        "reformulated": .stringField("La question reformulée clairement, en une phrase"),
        "exactTerms": .stringList("Expressions à chercher mot pour mot"),
        "probableQuotes": .stringList("Formulations verbatim plausibles du passage recherché"),
        "fileQuery": .stringField("Phrase décrivant le contenu du passage idéal à retrouver"),
        "webQueries": .stringList("1 à 3 requêtes pour un moteur de recherche"),
        "isRecentInfo": .boolField("Vrai si la réponse dépend de l'actualité"),
        "needsClarification": .boolField("Vrai seulement si la question est inintelligible"),
        "clarificationQuestion": .stringField("La question à poser, si clarification nécessaire"),
        "duplicateOfID": .stringField("Identifiant de la recherche récente équivalente, sinon vide"),
        "duplicateRecommendation": .enumField("Que faire du doublon", ["reuse", "complete", "new"]),
        "addedConstraints": .stringList("Ce que la nouvelle question ajoute par rapport à l'ancienne"),
        "candidateFiles": .stringList("Noms exacts de fichiers non indexés concernant manifestement la question"),
    ], required: ["intent", "preferredSource", "fileQuery", "webQueries", "isRecentInfo", "needsClarification"])

    static func analysisPrompt(question: String, recent: [SearchRecord], unindexedNames: [String]) -> String {
        var text = "QUESTION\n\(question)\n"

        if !recent.isEmpty {
            text += "\nRECHERCHES RÉCENTES (identifiant · date · source · question)\n"
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            for record in recent.prefix(30) {
                text += "\(record.id) · \(formatter.string(from: record.createdAt)) · "
                text += "\(record.effectiveSource.rawValue) · \(record.question)\n"
            }
        }

        if !unindexedNames.isEmpty {
            text += "\nFICHIERS CONNUS MAIS NON INDEXÉS (noms seuls)\n"
            text += unindexedNames.prefix(300).joined(separator: "\n")
            text += "\n"
        }

        return text
    }

    // ── Synthèse ancrée ──────────────────────────────────────────────

    static let synthesisSystem = """
    Tu rédiges la réponse d'un moteur de recherche personnel, pour un lecteur exigeant. Tu reçois \
    une question et des sources numérotées : des passages de ses propres documents, notés [L1], \
    [L2]…, et des pages web, notées [W1], [W2]…

    Règles absolues :
    1. Chaque affirmation s'appuie sur une source, citée par son numéro entre crochets, \
    immédiatement après la phrase concernée.
    2. Tu n'utilises QUE les sources fournies. Tu n'ajoutes aucune référence, page, date, édition \
    ni citation venant de ta mémoire. Si tu crois savoir quelque chose qui n'est pas dans les \
    sources, tu ne l'écris pas.
    3. Les citations textuelles sont courtes (trente mots au plus), exactes, entre guillemets \
    français « », toujours suivies de leur numéro.
    4. Si les sources ne permettent pas de répondre, dis-le explicitement et indique ce qui manque. \
    Ne comble jamais un vide par une généralité.
    5. Distingue ce que les sources établissent de ce qui est une interprétation : les \
    interprétations vont sous « Nuances et hypothèses ».
    6. Pas de répétition, pas de remplissage, pas de conclusion générale.

    Format, en Markdown simple, sans tableau, avec des titres de niveau 3 :
    ### Réponse — deux à cinq phrases.
    ### Passages clés — une liste ; pour chaque source utile, une citation courte ou un résumé \
    d'une ligne, avec son numéro.
    ### Nuances et hypothèses — seulement si c'est utile.
    ### Pour aller plus loin — facultatif, une ligne, pour signaler des sources fournies mais non \
    exploitées.

    Langue : celle de la question. Longueur : 150 à 400 mots.
    """

    static func synthesisPrompt(
        question: String,
        analysis: QueryAnalysis?,
        localSources: [SourceRef],
        webSources: [SourceRef],
        agentAnswer: String
    ) -> String {
        var text = "QUESTION\n\(question)\n"

        if let analysis, !analysis.reformulated.isEmpty {
            text += "\nREFORMULATION\n\(analysis.reformulated)\n"
        }

        if !localSources.isEmpty {
            text += "\nPASSAGES DE MES DOCUMENTS\n"
            for source in localSources {
                text += "\n[\(source.tag)] \(source.title)"
                if let page = source.page { text += ", page \(page)" }
                text += "\n\(source.excerpt)\n"
            }
        }

        if !webSources.isEmpty {
            text += "\nSOURCES WEB\n"
            for source in webSources {
                text += "\n[\(source.tag)] \(source.title)"
                if let url = source.url { text += " — \(url)" }
                if let date = source.publishedAt, !date.isEmpty { text += " (\(date))" }
                text += "\n\(source.excerpt)\n"
            }
        }

        if !agentAnswer.isEmpty {
            text += """

            NOTE DE RECHERCHE PRODUITE PAR L'AGENT WEB
            Ce texte est un résumé intermédiaire. Il ne remplace pas les sources : n'en reprends que \
            ce que les sources ci-dessus confirment, et cite toujours la source, jamais cette note.

            \(agentAnswer)

            """
        }

        if localSources.isEmpty && webSources.isEmpty {
            text += "\nAUCUNE SOURCE N'A ÉTÉ TROUVÉE. Dis-le clairement et indique ce qui manque.\n"
        }

        return text
    }

    // ── Question de suite ────────────────────────────────────────────

    static let followUpSystem = """
    Mêmes règles que pour la synthèse : chaque affirmation citée par son numéro, uniquement les \
    sources fournies, aucune référence venant de ta mémoire, et tu dis franchement quand les sources \
    ne suffisent pas.

    Tu disposes de la synthèse précédente, des sources déjà numérotées et, le cas échéant, de \
    nouvelles sources. Réponds uniquement à la question de suite. Ne réécris pas la synthèse \
    précédente. Conserve la numérotation existante. Reste bref : deux à six phrases, sans titres, \
    sauf si la question appelle une liste.
    """

    static func followUpPrompt(
        previousQuestion: String,
        previousSynthesis: String,
        earlierTurns: [FollowUpTurn],
        sources: [SourceRef],
        question: String
    ) -> String {
        var text = "QUESTION D'ORIGINE\n\(previousQuestion)\n\nSYNTHÈSE PRÉCÉDENTE\n\(previousSynthesis)\n"

        // Contexte borné : seulement les quatre derniers tours.
        for turn in earlierTurns.suffix(4) {
            text += "\nQUESTION DE SUITE\n\(turn.question)\nRÉPONSE\n\(turn.answer)\n"
        }

        if !sources.isEmpty {
            text += "\nSOURCES DISPONIBLES\n"
            for source in sources {
                text += "\n[\(source.tag)] \(source.title)"
                if let page = source.page { text += ", page \(page)" }
                if let url = source.url { text += " — \(url)" }
                text += "\n\(source.excerpt.prefix(1200))\n"
            }
        }

        text += "\nNOUVELLE QUESTION\n\(question)\n"
        return text
    }

    // ── Transcription ────────────────────────────────────────────────

    static let transcription = """
    Transcris cet enregistrement en français, fidèlement, avec la ponctuation et les majuscules. \
    Ne résume pas, ne reformule pas, n'ajoute rien, ne commente pas. Rends uniquement le texte \
    transcrit. Si un passage est inaudible, écris [inaudible].
    """
}
