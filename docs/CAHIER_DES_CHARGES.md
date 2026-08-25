# Cahier des charges — L'Atelier

Consolidation des deux briefs de Lucas (25/08/2026), pour qu'une session de travail future n'ait
pas besoin de la conversation d'origine. En cas de doute, ce document fait foi ; `README.md`
décrit ce qui existe, celui-ci décrit ce qui est demandé.

---

## 1. La mission

Un moteur de recherche personnel, pour un utilisateur unique, sur iPhone et iPad. Une question en
langage naturel ; l'app cherche dans ses documents, sur Internet, ou les deux, et répond par une
synthèse **dont chaque affirmation renvoie à une source réelle**.

Philosophie explicite : « simple qui marche parfaitement pour une seule personne ». Aucun compte,
aucun multi-utilisateur, aucune scalabilité, aucune analytique, aucun monitoring. Quand deux
solutions marchent, prendre la plus courte. Le résultat doit fonctionner, pas impressionner.

## 2. Décisions techniques arrêtées

| Sujet | Décision |
|---|---|
| Plateforme | iOS et iPadOS **uniquement**, iOS 26 minimum. Swift 6, SwiftUI, vraies vues natives — pas de WKWebView. |
| Projet | Un seul module, structure plate : `Views/`, `Services/`, `Models/`. Pas de multi-package, pas de générateur de projet, pas d'architecture en couches. |
| Dépendances | **Aucune**, sauf accord explicite de Lucas. `URLSession`, `Codable`, `PDFKit`, `QuickLook` suffisent. |
| Persistance | **Un fichier JSON** dans Documents. Ni SwiftData, ni Core Data, ni SQLite. Export et import. |
| Clés API | **Keychain**, saisies dans les réglages, jamais dans le code ni le dépôt. |
| Réseau | Appels directs à Gemini et Perplexity, `async/await`, annulation, délais, relance à délai croissant sur 429 et 5xx, streaming si l'API le permet. |
| Recherche fichiers | **Gemini File Search** (RAG géré par Google). |
| Intelligence | **Gemini** pour l'analyse, la reformulation, la détection de doublons, la synthèse, la transcription. |
| Internet | **Perplexity Search API** (standard) et **Agent API** (approfondi). L'API Sonar est dépréciée au 27/09/2026 : interdite. |
| Ouverture d'une source | QuickLook, à la bonne page pour un PDF quand c'est possible. |
| Budget de fonctionnement | moins de 20 $ par mois. |

### Garde-fou, énoncé mot pour mot dans le brief

> Ne construis aucun index local, aucune base vectorielle, aucun embedding sur l'appareil.
> N'utilise ni Apple Intelligence, ni Foundation Models, ni Core ML, ni Core AI. Toute
> l'intelligence reste chez Gemini. Le natif nous sert à accéder aux fichiers et à faire une belle
> interface, pas à réimplémenter un moteur de recherche. **Si tu te surprends à écrire du code
> d'indexation, tu t'es trompé.**

### Ce qui a été explicitement supprimé lors de la bascule au natif

HTML/CSS/JS, manifeste et « Ajouter à l'écran d'accueil », hébergement statique, **fonction relais
et CORS**, stockage navigateur, `MediaRecorder`, **agent de synchronisation sur le Mac et sa file
d'attente** (l'app fait ce travail elle-même). Le Mac ne sert plus qu'à compiler et installer.

## 3. Écran par écran

**Accueil.** Barre de recherche multi-ligne (collage possible) avec **focus immédiat**, bouton
micro, sélecteur *Auto · Mes fichiers · Internet · Les deux*, bouton d'historique en haut à gauche.
Une seule petite ligne d'état peut apparaître sous les boutons (« Indexation 120/300 », « Hors
ligne », « Plafond atteint »). **Rien d'autre.** Retour = lancer ; Maj+Retour = nouvelle ligne.

**Déroulé d'une recherche.**
1. **Analyse** : un seul appel Gemini, réponse en JSON — intention, source préférée, termes exacts,
   formulations probables du passage recherché, 1 à 3 requêtes web, décision de doublon, et les
   fichiers catalogués non indexés susceptibles de concerner la question. Cible : moins de 2 s.
2. Recherche fichiers et/ou Internet selon la source et la priorité réglable (fichiers d'abord /
   Internet d'abord / en parallèle). En « fichiers d'abord », Internet ne part que si la réponse
   fichiers est insuffisante ou sur demande.
3. **Synthèse** en français, 150–400 mots, structurée en « Réponse », « Passages clés », « Nuances
   et hypothèses ». Règle absolue : toute affirmation renvoie à une source numérotée ; le modèle
   n'ajoute aucune référence venant de sa mémoire ; si les sources ne suffisent pas, il le dit.
   Sources locales `[L1]…`, web `[W1]…`, chaque numéro cliquable vers sa carte.
4. Affichage progressif, bouton « Arrêter », ligne d'état nommant l'étape.
5. Suites : « Compléter sur Internet », « Approfondir » (avec coût estimé et confirmation),
   « Question de suite », « Copier la synthèse », « Partager » en Markdown.

**Cartes sources.** Fichier : nom, page si connue, extrait, « Copier la citation ». Web : titre,
domaine, extrait, ouverture dans Safari, copie de l'URL.

**Historique.** Liste par jour, recherche instantanée, réouverture, suppression, total du mois en
en-tête, accès aux réglages par une icône. Les questions de suite restent sous leur recherche.

**Mes fichiers.** Dossiers surveillés (chemin, nombre, dernier scan, retrait), listes *Indexés* et
*Catalogués non indexés* avec recherche par nom, boutons « Scanner maintenant », « Ajouter un
dossier », « Tout réindexer », exclusions par type ou sous-dossier, erreurs par fichier. Rappeler
les limites Gemini à l'approche du plafond : 100 Mo par fichier, empreinte ≈ 3 × les données.

**Réglages** (cachés, accessibles depuis l'historique). Clés avec « Tester », modèle Gemini, niveau
Internet par défaut, priorité des sources, plafond mensuel, export/import, effacement, liste des
fichiers indexés, diagnostics.

## 4. Smart Search v2 — comment les fichiers entrent dans l'app

**Désignation.** Un ou plusieurs dossiers iCloud choisis au sélecteur, convertis en
*security-scoped bookmarks* persistants, résolus à chaque lancement, tout accès encadré par
`startAccessingSecurityScopedResource` et son pendant. Signet invalide → demander une
re-sélection **sans perdre le registre**.

**Registre.** Par fichier : chemin relatif, nom, taille, date de modification, empreinte,
identifiant côté store Gemini, statut (`indexé`, `catalogué`, `non supporté`, `erreur`).

**Synchronisation automatique.** À chaque lancement et à chaque retour au premier plan : parcours
récursif, comparaison au registre. Nouveau ou modifié → envoi. Disparu → retrait du store. Format
non supporté → gardé au catalogue, sans erreur. En tâche de fond, par lots, reprenable, avec une
progression discrète et **jamais bloquante**.

**Deux pièges à traiter explicitement.** (1) Ne pas s'appuyer sur `NSMetadataQuery` pour un dossier
externe : peu fiable, et ne voit pas correctement les sous-dossiers → re-scan incrémental
explicite. (2) Les fichiers allégés par « Optimiser le stockage » ne sont pas lisibles
directement : appeler `startDownloadingUbiquitousItem`, attendre la disponibilité, et reprendre
plus tard ceux qui n'arrivent pas.

**Niveau 3, devenu automatique.** Si l'analyse repère qu'un fichier catalogué mais non indexé
concerne manifestement la question, l'app le lit, l'indexe et relance la recherche en l'incluant,
en affichant une simple ligne : « *Nom du fichier* ajouté à l'index ». Plus de sélecteur, plus de
tap.

## 5. Anti-dépense

Avant tout appel payant : (1) normalisation de la question — minuscules, sans accents, sans mots
vides — et comparaison exacte avec les questions récentes ; (2) sinon, la même requête d'analyse
Gemini reçoit les 30 dernières questions et indique si l'une est la même demande, ce que la
nouvelle ajoute, et la recommandation *réutiliser / compléter / nouvelle*.

Identique et moins de 7 jours → **réutilisation automatique** avec un bouton « Relancer ». Sinon,
carte de choix. **Les questions sur l'actualité ne sont jamais réutilisées automatiquement.**

## 6. Coûts et plafond

Coût estimé par appel à partir des champs d'usage renvoyés par les API, sinon d'une grille de prix
datée et modifiable dans les réglages. Total mensuel, plafond (défaut 15 $), alerte à 80 %, mode
gratuit au plafond.

## 7. Voix, par ordre de priorité

1. **La dictée du clavier iOS** dans le champ : zéro ligne de code, gratuite, locale, excellente en
   français. C'est le chemin principal ; le bouton micro ne fait que rappeler qu'elle existe, la
   première fois.
2. Enregistrement long avec `AVAudioRecorder`, envoyé à Gemini pour transcription, texte affiché et
   **éditable avant** de devenir la requête.
3. S'il reste du temps en fin de parcours seulement : remplacer l'appel Gemini par `SpeechAnalyzer`
   d'iOS 26, local et gratuit. Sinon, le noter dans le README comme amélioration possible.

## 8. États à gérer proprement

Hors ligne (historique lisible, recherche désactivée avec une phrase claire) ; clé absente (la
recherche concernée ouvre la saisie de clé) ; erreur d'API (message humain, bouton Réessayer,
nouvel essai automatique avec délai croissant) ; plafond atteint ; import trop volumineux pour le
palier.

## 9. UX et style

Interface calme, typographique, **une seule couleur d'accent**, clair/sombre selon le système,
police système pour l'interface et une police à empattements pour la synthèse et les citations.
Zones tactiles ≥ 44 pt, zones sûres respectées, pas d'animation inutile. Au doigt sur iPhone, au
doigt et au clavier sur iPad. Accessibilité de base : libellés, contraste, tailles dynamiques.

**iPad** : `NavigationSplitView`, historique en barre latérale repliable, synthèse et sources côte
à côte en paysage large. Raccourcis ⌘⏎ lancer, ⌘K focus, ⌘Y historique, ⌘, réglages.

## 10. Confidentialité

Les documents sont envoyés **uniquement à Google**. Perplexity ne reçoit **que la question
reformulée**. Aucune autre destination. Aucune clé dans le code, le dépôt ou les journaux.

## 11. Barre de qualité

- Chaque appel d'API testé avec les vraies clés, formats réels consignés dans `NOTES_API.md`.
- Test de référence : une question formulée autrement que le texte doit retrouver le bon passage et
  le citer avec sa page.
- **Pas de fonction affichée mais non implémentée, pas de « à venir », pas de TODO visible.**
- Livraison : dépôt git propre, `README.md` en français pour non-développeur,
  `CHECKLIST_APPAREIL.md` avec la marche à suivre en cas d'échec.

## 12. Installation et signature — qui fait quoi

**Lucas** : s'inscrire au programme Apple Developer et accepter les accords, activer le mode
développeur sur ses appareils, les brancher et les approuver, faire confiance au certificat.

**L'assistant** : configurer la signature automatique, compiler, installer, vérifier que l'app
fonctionne débranchée. *En pratique, les sessions tournant dans un conteneur Linux sans Xcode,
cette part revient à Lucas, guidée par `CHECKLIST_APPAREIL.md`.*

Si le compte payant n'est pas encore actif : construire avec une équipe personnelle gratuite
(build expirant au bout de sept jours) et préparer le passage au compte payant par simple
recompilation. À écrire dans le README : avec un compte payant, un build signé reste valable
environ un an ; passé ce délai, rebrancher et recompiler, une vingtaine de minutes une fois par an.
Mentionner en note que la distribution App Store « non listée » n'expire jamais mais suppose une
revue Apple — ce n'est pas pour maintenant.

## 13. Méthode de travail

- Lire les documentations indiquées **avant** de coder ; n'inventer aucun paramètre d'API.
- Plan de 10 lignes, puis construire d'une traite.
- En cas de blocage : toutes les questions en un seul bloc, **trois au maximum**, avec une réponse
  par défaut pour chacune, et continuer sur le reste.
- Dire explicitement ce qui ne peut pas être vérifié sans les appareils, et le mettre dans la
  checklist.
- Une fonction menacée de déborder est livrée dans sa version simple, avec une note dans le
  README — jamais à moitié.

## 14. Budget de temps

Une journée et demie à deux journées. Ordre d'arbitrage : **d'abord** la recherche dans les
fichiers de bout en bout, **ensuite** Internet et l'anti-dépense, **ensuite** l'iPad et la voix
longue, **en dernier** les raffinements.
