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

print("\nTarification :")
let prices = PriceTable.current
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

print(ok ? "\nOK" : "\nÉCHEC")
if !ok { exit(1) }
