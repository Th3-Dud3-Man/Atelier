# Plan — L'Atelier (application native iOS / iPadOS)

> Bascule du 25/08/2026 : abandon de la web app, passage au natif Swift 6 / SwiftUI.
> Ce qui est conservé du travail précédent : `NOTES_API.md` (formats réels Gemini et Perplexity, relevés dans la documentation officielle) et les textes des prompts d'analyse, de doublon et de synthèse.

## Les 10 lignes

1. **Un seul module, structure plate** : `Atelier/` avec `Models/`, `Services/`, `Views/`. Aucune dépendance externe, aucun générateur de projet — le `project.pbxproj` est écrit à la main et utilise un *groupe synchronisé* (Xcode 16+) qui prend automatiquement tous les fichiers du dossier.
2. **Toute l'intelligence est chez Gemini** : aucun index local, aucun embedding sur l'appareil, aucun Foundation Models / Core ML. L'app lit les fichiers, les envoie, affiche les réponses.
3. **Recherche fichiers** : Gemini File Search (`generateContent` + outil `fileSearch`), qui renvoie les passages retrouvés avec leur numéro de page.
4. **Recherche Internet** : Perplexity Search API (standard) et Agent API (approfondi), synthèse rédigée par Gemini.
5. **Un appel d'analyse** en JSON au début de chaque recherche : intention, source, requêtes web, jugement de doublon, fichiers catalogués à repêcher.
6. **Smart Search v2** : dossiers iCloud désignés une fois par le sélecteur, gardés par *security-scoped bookmarks* ; re-scan incrémental à chaque lancement et à chaque retour au premier plan ; niveau 3 entièrement automatique (l'app lit, indexe et relance seule).
7. **Persistance** : un fichier JSON dans Documents (historique, registre, réglages, coûts) ; clés API dans le Keychain.
8. **Voix** : la dictée du clavier iOS d'abord (gratuite, locale) ; enregistrement long `AVAudioRecorder` transcrit par Gemini ensuite ; `SpeechAnalyzer` seulement s'il reste du temps.
9. **Anti-dépense et budget** : empreinte normalisée puis jugement Gemini ; coût par appel, compteur mensuel, plafond avec bascule en mode gratuit.
10. **Livraison** : dépôt propre, `README.md` en français, `NOTES_API.md`, `CHECKLIST_APPAREIL.md`, et `Tools/test-apis.sh` à lancer avec vos clés.

## Ordre de marche

| Étape | Contenu | État |
|---|---|---|
| 1 | Projet Xcode, modèles, persistance JSON, Keychain, écran d'accueil | écrit |
| 2 | Dossiers iCloud, signets, scan incrémental, envoi au store Gemini, écran Mes fichiers | écrit |
| 3 | Analyse, recherche fichiers, synthèse en flux, cartes sources, QuickLook | écrit |
| 4 | Perplexity, mode « les deux », anti-dépense, coûts et plafond | écrit |
| 5 | iPad (`NavigationSplitView`, raccourcis), voix longue, historique et questions de suite | écrit |
| 6 | Réglages complets, diagnostics, README, checklist appareil | écrit |
| 7 | **Compilation, installation, essais sur vos appareils** | **vous attend** |

« Écrit » signifie : rédigé, relu, et passé au compilateur Swift 6 pour les 12 fichiers sur 31 qui
ne dépendent pas des cadres Apple. Cela ne veut pas dire « compilé » : voir ci-dessous.

## Ce que je ne peux pas vérifier depuis ici

Cette session tourne dans un conteneur Linux **sans Xcode** : je ne peux ni compiler, ni lancer le simulateur, ni signer, ni installer sur vos appareils. Je livre un projet qui s'ouvre dans Xcode et un protocole de test ; la compilation et l'installation se font sur votre Mac, et je corrige tout ce que le compilateur signale.
De même, je n'ai pas vos clés API : `Tools/test-apis.sh` fait les appels réels et écrit les réponses brutes, que vous me recollerez pour figer les derniers formats (voir la section 5 de `NOTES_API.md`).
