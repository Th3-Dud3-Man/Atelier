import SwiftUI
import UniformTypeIdentifiers

/// Réglages, volontairement cachés derrière l'historique : clés, modèles, budget,
/// données et diagnostics.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(FolderSync.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var geminiKey = ""
    @State private var perplexityKey = ""
    @State private var keyTest: String?
    /// Message affiché quand le trousseau refuse une clé, ou quand un import échoue.
    @State private var keychainError: String?
    @State private var importError: String?
    @State private var testing = false
    @State private var exporting = false
    @State private var importing = false
    @State private var importReplaces = false
    @State private var confirmingClear = false
    @State private var confirmingReplace = false
    /// Encodé au moment du clic, et non à chaque rafraîchissement de la vue.
    @State private var exportPayload = Data()

    private var exportDateStamp: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                keysSection
                modelsSection
                budgetSection
                corpusSection
                privacySection
                dataSection
                diagnosticsSection
                aboutSection
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Terminé") { dismiss() }
                }
            }
            .onAppear {
                geminiKey = Keychain.get(.gemini)
                perplexityKey = Keychain.get(.perplexity)
            }
            // Une clé collée puis l'écran refermé sans toucher le bouton serait perdue :
            // on enregistre aussi à la fermeture.
            .onDisappear { _ = saveKeys() }
            .fileExporter(
                isPresented: $exporting,
                document: JSONDocument(data: exportPayload),
                contentType: .json,
                defaultFilename: "atelier-\(exportDateStamp)"
            ) { _ in exportPayload = Data() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                importError = nil
                switch result {
                case .failure(let error):
                    importError = error.localizedDescription
                case .success(let url):
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        try store.importData(data, replacing: importReplaces)
                        importError = nil
                    } catch is DecodingError {
                        // Le cas le plus probable : un JSON qui n'est pas un export de L'Atelier.
                        importError = "Ce fichier n'est pas un export de L'Atelier : rien n'a été modifié."
                    } catch {
                        importError = "Lecture impossible : \(error.localizedDescription)"
                    }
                }
            }
            .confirmationDialog(
                "Remplacer toutes les données ?",
                isPresented: $confirmingReplace,
                titleVisibility: .visible
            ) {
                Button("Remplacer", role: .destructive) {
                    importReplaces = true
                    importing = true
                }
            } message: {
                Text("L'historique, les coûts, le registre des fichiers et les dossiers surveillés "
                     + "sont remplacés par le contenu du fichier choisi. Cette opération ne peut pas "
                     + "être annulée : exportez d'abord si vous n'êtes pas sûr.")
            }
            .confirmationDialog("Effacer l'historique ?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Effacer", role: .destructive) { store.clearHistory() }
            } message: {
                Text("Les recherches et le compteur de coûts sont supprimés. Le corpus indexé n'est pas touché.")
            }
        }
    }

    // ── Clés ─────────────────────────────────────────────────────────

    private var keysSection: some View {
        Section {
            LabeledContent("Gemini") {
                SecureField("Clé API", text: $geminiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = saveKeys() }
            }
            LabeledContent("Perplexity") {
                SecureField("Clé API (facultative)", text: $perplexityKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = saveKeys() }
            }

            Button {
                guard saveKeys() else { return }
                Task { await testKeys() }
            } label: {
                HStack {
                    Text("Enregistrer et tester")
                    if testing {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(testing)

            if let keychainError {
                Text(keychainError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let result = keyTest {
                Text(result).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Clés API")
        } footer: {
            Text("Les clés sont rangées dans le trousseau de cet appareil : jamais dans un fichier, "
                 + "jamais dans une sauvegarde, jamais envoyées ailleurs qu'au service concerné.\n\n"
                 + "Tester la clé Perplexity effectue une vraie recherche, facturée "
                 + "\(CostModel.format(0.005)).")
        }
    }

    /// Renvoie faux si le trousseau a refusé une des deux clés, pour que l'écran le dise
    /// au lieu de laisser croire que tout est en place.
    @discardableResult
    private func saveKeys() -> Bool {
        let gemini = Keychain.set(geminiKey, for: .gemini)
        let perplexity = Keychain.set(perplexityKey, for: .perplexity)
        if gemini && perplexity {
            keychainError = nil
            return true
        }
        var refused: [String] = []
        if !gemini { refused.append("Gemini") }
        if !perplexity { refused.append("Perplexity") }
        keychainError = "Le trousseau a refusé d'enregistrer la clé \(refused.joined(separator: " et ")). "
            + "Déverrouillez l'appareil, puis réessayez."
        return false
    }

    private func testKeys() async {
        testing = true
        defer { testing = false }
        var lines: [String] = []

        let client = GeminiClient(
            apiKey: Keychain.get(.gemini),
            mainModel: store.settings.mainModel,
            lightModel: store.settings.lightModel,
            storeName: store.settings.storeName
        )
        if Keychain.has(.gemini) {
            // On demande d'abord à Google ce que cette clé peut employer. Sans cela, un
            // identifiant de modèle devenu faux se manifeste par un « 404 » qui ne dit pas
            // lequel prendre à la place — et l'app paraît cassée alors que la clé est bonne.
            var usable: [String] = []
            do {
                let models = try await client.listModels()
                store.updateSettings { $0.availableModels = models }
                usable = models.filter(\.canGenerate).map(\.id)
                lines.append("Gemini : la clé est reconnue, \(usable.count) modèle(s) disponibles.")
            } catch {
                lines.append("Gemini : \((error as? APIError)?.errorDescription ?? error.localizedDescription)")
            }

            if !usable.isEmpty {
                var corrected: [String] = []
                if !usable.contains(store.settings.mainModel),
                   let replacement = GeminiModels.bestMain(from: usable) {
                    let previous = store.settings.mainModel
                    store.updateSettings { $0.mainModel = replacement }
                    corrected.append("recherche : « \(previous) » n'existe plus, remplacé par « \(replacement) »")
                }
                if !usable.contains(store.settings.lightModel),
                   let replacement = GeminiModels.bestLight(from: usable) {
                    let previous = store.settings.lightModel
                    store.updateSettings { $0.lightModel = replacement }
                    corrected.append("analyse : « \(previous) » n'existe plus, remplacé par « \(replacement) »")
                }
                if !corrected.isEmpty {
                    lines.append(contentsOf: corrected.map { "Modèle corrigé — \($0)." })
                }

                // Puis l'essai qui compte : un vrai appel, avec le modèle retenu.
                let checked = GeminiClient(
                    apiKey: Keychain.get(.gemini),
                    mainModel: store.settings.mainModel,
                    lightModel: store.settings.lightModel,
                    storeName: store.settings.storeName
                )
                do {
                    _ = try await checked.testKey()
                    lines.append("Gemini : « \(store.settings.lightModel) » répond.")
                } catch {
                    lines.append("Gemini : « \(store.settings.lightModel) » a refusé — "
                                 + "\((error as? APIError)?.errorDescription ?? error.localizedDescription)")
                }
            }
        } else {
            lines.append("Gemini : aucune clé enregistrée.")
        }

        if Keychain.has(.perplexity) {
            do {
                let count = try await PerplexityClient(apiKey: Keychain.get(.perplexity))
                    .testKey(prices: store.settings.prices)
                lines.append("Perplexity : la clé fonctionne (\(count) résultat(s)).")
                store.record(CostEntry(provider: "Perplexity", model: "search", usd: 0.005, note: "test de clé"))
            } catch {
                lines.append("Perplexity : \((error as? APIError)?.errorDescription ?? error.localizedDescription)")
            }
        } else {
            lines.append("Perplexity : aucune clé enregistrée — la recherche Internet restera indisponible.")
        }

        keyTest = lines.joined(separator: "\n")
    }

    // ── Modèles ──────────────────────────────────────────────────────

    private var modelsSection: some View {
        Section {
            Picker("Recherche et synthèse", selection: Binding(
                get: { store.settings.mainModel },
                set: { value in store.updateSettings { $0.mainModel = value } }
            )) {
                ForEach(offeredModels(preferring: GeminiModels.fileSearchCapable,
                                      current: store.settings.mainModel), id: \.self) {
                    Text($0).tag($0)
                }
            }

            Picker("Analyse et transcription", selection: Binding(
                get: { store.settings.lightModel },
                set: { value in store.updateSettings { $0.lightModel = value } }
            )) {
                ForEach(offeredModels(preferring: GeminiModels.lightCapable,
                                      current: store.settings.lightModel), id: \.self) {
                    Text($0).tag($0)
                }
            }

            Picker("Niveau Internet par défaut", selection: Binding(
                get: { store.settings.webLevel },
                set: { value in store.updateSettings { $0.webLevel = value } }
            )) {
                ForEach(WebLevel.allCases) { Text($0.label).tag($0) }
            }

            Picker("Priorité des sources", selection: Binding(
                get: { store.settings.priority },
                set: { value in store.updateSettings { $0.priority = value } }
            )) {
                ForEach(SourcePriority.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Modèles")
        } footer: {
            Text(store.settings.availableModels.isEmpty
                 ? "Cette liste est celle de la documentation. Touchez « Enregistrer et tester » "
                   + "plus haut : l'app demandera à Google les modèles que votre clé peut vraiment "
                   + "employer, et remplacera ceux qui n'existent plus."
                 : "Liste relevée auprès de Google pour votre clé : \(store.settings.availableModels.count) "
                   + "modèle(s). Tous ne savent pas utiliser File Search — si la recherche dans vos "
                   + "fichiers échoue, essayez le suivant dans la liste.")
        }
    }

    /// Ce que proposent les listes déroulantes : les modèles réellement disponibles quand la
    /// clé a été testée, l'ordre de préférence écrit dans le code sinon. Le modèle actuellement
    /// choisi y figure toujours, même s'il a disparu du catalogue, pour ne pas vider la liste.
    private func offeredModels(preferring order: [String], current: String) -> [String] {
        let available = store.settings.availableModels.filter(\.canGenerate).map(\.id)
        guard !available.isEmpty else { return order.contains(current) ? order : [current] + order }
        let known = order.filter(available.contains)
        let rest = available.filter { !known.contains($0) }.sorted()
        let list = known + rest
        // Un modèle choisi mais disparu du catalogue reste en tête : sans lui, la liste
        // n'aurait plus de sélection valide et se viderait à l'écran.
        return list.contains(current) ? list : [current] + list
    }

    // ── Budget ───────────────────────────────────────────────────────

    private var budgetSection: some View {
        Section {
            LabeledContent("Ce mois-ci") {
                Text(CostModel.formatEUR(store.monthTotal(), prices: store.settings.prices))
                    + Text(" · \(CostModel.format(store.monthTotal()))")
                    .foregroundStyle(.secondary)
            }
            Stepper(
                "Plafond : \(CostModel.formatEUR(store.settings.monthlyCapUSD, prices: store.settings.prices))",
                value: Binding(
                    get: { store.settings.monthlyCapUSD },
                    set: { value in store.updateSettings { $0.monthlyCapUSD = value } }
                ),
                in: 0...200,
                step: 5
            )
            ForEach(store.monthByProvider().sorted(by: { $0.key < $1.key }), id: \.key) { provider, amount in
                LabeledContent(provider) { Text(CostModel.format(amount)) }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Budget")
        } footer: {
            Text("Au plafond, plus aucun appel payant n'est lancé : l'historique reste consultable "
                 + "et les résultats déjà obtenus restent relisibles. Un plafond à zéro désactive "
                 + "la limite.\n\n"
                 + "Les montants affichés sont TVA comprise. Google et Perplexity facturent en "
                 + "dollars : l'euro n'est ici qu'une commodité de lecture, au taux réglable dans "
                 + "Diagnostics. Votre abonnement iCloud, lui, se paie chez Apple et n'entre pas "
                 + "dans ce compteur.")
        }
    }

    // ── Corpus ───────────────────────────────────────────────────────

    private var corpusSection: some View {
        Section {
            LabeledContent("Corpus indexé") {
                Text(store.corpusUsageText)
                    .foregroundStyle(store.corpusFull ? Color.orange : Color.secondary)
            }
            Gauge(value: gaugeFraction) { EmptyView() }
                .tint(store.corpusFull ? Color.orange : Color.atelierAccent)

            Stepper(
                "Budget : \(budgetGigabytes) Go",
                value: Binding(
                    get: { budgetGigabytes },
                    set: { value in
                        store.updateSettings { $0.corpusBudgetBytes = Int64(value) * 1024 * 1024 * 1024 }
                    }
                ),
                in: 1...30,
                step: 1
            )

            LabeledContent("Au catalogue") { Text("\(store.catalogedFiles.count) fichier(s)") }
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Corpus")
        } footer: {
            Text("Google plafonne un corpus à 10 Go, et l'empreinte réelle d'un document y vaut "
                 + "environ trois fois sa taille : trois giga-octets de fichiers remplissent donc "
                 + "déjà ce plafond.\n\n"
                 + "Au-delà du budget, les fichiers restent au catalogue : ils gardent leur nom, "
                 + "restent cherchables, ne coûtent rien, et entrent dans le corpus au moment où "
                 + "une question les concerne — en prenant la place du document indexé le plus "
                 + "ancien. L'index est un plan de travail, pas une copie de votre disque.")
        }
    }

    private var budgetGigabytes: Int {
        max(1, Int(store.corpusBudgetBytes / (1024 * 1024 * 1024)))
    }

    private var gaugeFraction: Double {
        let budget = Double(store.corpusBudgetBytes)
        guard budget > 0 else { return 0 }
        return min(1, Double(store.indexedBytes) / budget)
    }

    // ── Confidentialité ──────────────────────────────────────────────

    private var privacySection: some View {
        Section {
            Toggle("Scanner au lancement", isOn: Binding(
                get: { store.settings.autoScan },
                set: { value in store.updateSettings { $0.autoScan = value } }
            ))
            Toggle("Indexer seul un fichier pertinent", isOn: Binding(
                get: { store.settings.autoIndexSuggested },
                set: { value in store.updateSettings { $0.autoIndexSuggested = value } }
            ))
        } header: {
            Text("Comportement")
        } footer: {
            Text("Vos documents ne sont envoyés qu'à Google, pour l'indexation et la recherche. "
                 + "Perplexity ne reçoit que la question reformulée, jamais un extrait de vos fichiers. "
                 + "Rien d'autre ne sort de l'appareil.\n\n"
                 + "Un point important : la clé Gemini doit venir d'un projet Google Cloud où la "
                 + "facturation est activée. Sur l'offre gratuite, les conditions d'utilisation de "
                 + "l'API autorisent Google à lire vos documents, à les faire relire par des humains "
                 + "et à s'en servir pour améliorer ses produits. Dès que la facturation est activée, "
                 + "cela s'arrête : vos fichiers ne servent plus qu'à vous répondre.")
        }
    }

    // ── Données ──────────────────────────────────────────────────────

    private var dataSection: some View {
        Section("Données") {
            Button("Exporter (JSON)") {
                exportPayload = (try? store.exportData()) ?? Data()
                exporting = true
            }
            Button("Importer et fusionner") {
                importReplaces = false
                importing = true
            }
            Button("Importer et remplacer", role: .destructive) { confirmingReplace = true }
            Button("Effacer l'historique", role: .destructive) { confirmingClear = true }

            if let importError {
                Text(importError).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    // ── Diagnostics ──────────────────────────────────────────────────

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Fichiers indexés") { Text("\(store.indexedFiles.count)") }
            LabeledContent("Fichiers catalogués") { Text("\(store.catalogedFiles.count)") }
            LabeledContent("Recherches") { Text("\(store.searches.count)") }
            LabeledContent("Store Gemini") {
                Text(store.settings.storeName.isEmpty ? "non créé" : "créé")
                    .foregroundStyle(.secondary)
            }
            // Une autorisation absente du fichier de description ne se voit pas : iOS arrête
            // l'app au moment où elle la demande. Cette ligne la montre sans rien déclencher.
            LabeledContent("Autorisations déclarées") {
                if let missing = LiveDictation.missingUsageDescription {
                    Text("manque \(missing)")
                        .foregroundStyle(.orange)
                } else {
                    Text("micro et dictée")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Grille de prix") {
                Text("relevée le \(store.settings.prices.updatedOn)")
                    .foregroundStyle(.secondary)
            }
            Stepper(
                "TVA appliquée : \(Int(store.settings.prices.vatPercent)) %",
                value: Binding(
                    get: { store.settings.prices.vatPercent },
                    set: { value in store.updateSettings { $0.prices.vatPercent = value } }
                ),
                in: 0...30,
                step: 1
            )
            Stepper(
                "1 $ = \(euroRateText) €",
                value: Binding(
                    get: { store.settings.prices.usdToEur },
                    set: { value in store.updateSettings { $0.prices.usdToEur = value } }
                ),
                in: 0.5...1.5,
                step: 0.01
            )
            if let error = store.lastPersistenceError {
                Text("Enregistrement : \(error)").font(.footnote).foregroundStyle(.red)
            }
            if let error = sync.lastError {
                Text("Synchronisation : \(error)").font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var euroRateText: String {
        String(format: "%.2f", store.settings.prices.usdToEur).replacingOccurrences(of: ".", with: ",")
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
        } header: {
            Text("À propos")
        } footer: {
            Text("L'Atelier — moteur de recherche personnel. Vos fichiers, Internet, et des sources "
                 + "vérifiables pour chaque affirmation.")
        }
    }
}

/// Enveloppe minimale pour exporter le fichier JSON via le sélecteur système.
struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
