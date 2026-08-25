import Foundation

// Deux règles que l'utilisateur constatera directement : la reconnaissance des reformulations,
// et l'affichage des coûts.
// Le code au niveau supérieur est isolé sur l'acteur principal : la fonction d'assertion
// doit l'être aussi pour pouvoir écrire dans `ok`.
var ok = true
@MainActor func check(_ label: String, _ condition: Bool) {
    print(condition ? "  ✓ \(label)" : "  ✗ \(label)"); if !condition { ok = false }
}

print("Empreinte anti-dépense :")
let a = Dedupe.fingerprint("Où Lacan définit-il le stade du miroir ?")
let b = Dedupe.fingerprint("ou lacan definit il le STADE DU MIROIR")
check("insensible à la casse, aux accents et à la ponctuation", a == b)
check("deux sujets différents restent distincts",
      Dedupe.fingerprint("le stade du miroir") != Dedupe.fingerprint("la forclusion du Nom-du-Père"))
check("les tournures d'adresse sont ignorées",
      Dedupe.fingerprint("Trouve-moi le stade du miroir") == Dedupe.fingerprint("le stade du miroir"))

print("\nAffichage des coûts :")
check("zéro se dit « gratuit »", CostModel.format(0) == "gratuit")
check("un montant minuscule reste visible", CostModel.format(0.0005) == "0,0005 $")
check("un montant courant garde deux décimales", CostModel.format(1.5) == "1,50 $")

print("\nTarification hors taxes :")
// Les tarifs publiés par Google et Perplexity sont hors taxes ; on vérifie d'abord le calcul
// brut, TVA neutralisée, puis la TVA elle-même.
var prices = PriceTable.current
prices.vatPercent = 0
check("Perplexity : 0,005 $ par appel, quel que soit le nombre de requêtes",
      abs(CostModel.perplexitySearch(requests: 1, prices: prices) - 0.005) < 1e-12)
var usage = TokenUsage()
usage.promptTokenCount = 1_000_000
usage.candidatesTokenCount = 1_000_000
check("Gemini : entrée + sortie au tarif du modèle",
      abs(CostModel.gemini(model: "gemini-3.1-flash-lite", usage: usage, prices: prices) - 1.75) < 1e-9)
usage.thoughtsTokenCount = 1_000_000
check("les tokens de réflexion sont facturés au tarif de sortie",
      abs(CostModel.gemini(model: "gemini-3.1-flash-lite", usage: usage, prices: prices) - 3.25) < 1e-9)

print("\nTVA et conversion :")
var taxed = PriceTable.current
check("la grille part sur 20 % de TVA", abs(taxed.vatPercent - 20) < 1e-12)
check("un appel Perplexity est facturé TVA comprise",
      abs(CostModel.perplexitySearch(requests: 1, prices: taxed) - 0.006) < 1e-12)
check("un appel Gemini est facturé TVA comprise",
      abs(CostModel.gemini(model: "gemini-3.1-flash-lite", usage: usage, prices: taxed) - 3.90) < 1e-9)
check("l'indexation aussi",
      abs(CostModel.indexing(bytes: 4_000_000, prices: taxed) - 0.18) < 1e-9)
taxed.usdToEur = 0.50
check("les totaux se lisent en euros",
      CostModel.formatEUR(10, prices: taxed) == "5,00 €")

print("\nChoix d'un modèle dans ce que la clé propose vraiment :")
check("le modèle connu le moins cher est retenu quand il existe",
      GeminiModels.bestMain(from: ["gemini-3.5-flash", "gemini-3.1-flash-lite", "autre"])
        == "gemini-3.1-flash-lite")
check("aucun modèle connu : on retient un « flash lite » plausible",
      GeminiModels.bestMain(from: ["gemini-9-pro", "gemini-9-flash-lite", "gemini-9-flash"])
        == "gemini-9-flash-lite")
check("les aperçus passent après les modèles stables",
      GeminiModels.bestMain(from: ["gemini-9-flash-preview", "gemini-9-flash"]) == "gemini-9-flash")
check("les modèles d'embedding ne sont jamais proposés",
      GeminiModels.bestMain(from: ["gemini-embedding-001"]) == nil)
check("catalogue vide : aucun choix, et l'app doit le dire",
      GeminiModels.bestMain(from: []) == nil)
check("le modèle léger tombe sur le principal si rien de plus économique n'existe",
      GeminiModels.bestLight(from: ["gemini-3.1-flash-lite"]) == "gemini-3.1-flash-lite")

print("\nUn fichier de réglages écrit par une version antérieure :")
let older = Data(#"{"updatedOn":"2026-01-01","geminiInput":{},"geminiOutput":{},"geminiAudioInput":{},"embeddingPerMillion":0.15,"perplexitySearchPer1000":5.0,"perplexityAgentPerRequest":0.05}"#.utf8)
if let restored = try? JSONDecoder().decode(PriceTable.self, from: older) {
    check("la grille se lit encore, sans les champs ajoutés depuis", restored.updatedOn == "2026-01-01")
    check("les champs manquants reprennent leur valeur par défaut",
          abs(restored.vatPercent - 20) < 1e-12 && abs(restored.usdToEur - 0.92) < 1e-12)
} else {
    check("la grille se lit encore, sans les champs ajoutés depuis", false)
    check("les champs manquants reprennent leur valeur par défaut", false)
}
let bareSettings = Data(#"{"mainModel":"gemini-3.1-flash-lite"}"#.utf8)
if let restored = try? JSONDecoder().decode(AppSettings.self, from: bareSettings) {
    check("les réglages se lisent même réduits à un seul champ",
          restored.mainModel == "gemini-3.1-flash-lite" && restored.monthlyCapUSD == 25)
} else {
    check("les réglages se lisent même réduits à un seul champ", false)
}

print(ok ? "\nOK" : "\nÉCHEC")
if !ok { exit(1) }
