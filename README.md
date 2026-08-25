# L'Atelier

Un moteur de recherche personnel, pour votre iPhone et votre iPad. Vous posez une question ; l'app cherche **dans vos propres documents**, **sur Internet**, ou les deux, et vous répond avec une synthèse dont chaque affirmation renvoie à une source réelle — nom du fichier et page, ou titre et adresse de la page web.

Application native, écrite en Swift et SwiftUI, sans aucune dépendance extérieure. Rien ne tourne sur un serveur : vos clés restent dans le trousseau de l'appareil, votre historique dans un fichier sur l'appareil. Seuls Google (pour l'indexation et la rédaction) et Perplexity (pour la recherche web) sont appelés, et uniquement quand vous cherchez.

---

## 1. Ce dont vous avez besoin

- Un Mac avec **Xcode 26** ou plus récent.
- Un iPhone et un iPad sous **iOS 26 / iPadOS 26** minimum.
- Une **clé API Gemini** (Google AI Studio, facturation activée) — indispensable.
- Une **clé API Perplexity** avec des crédits — facultative, seulement pour la recherche Internet.
- Un **abonnement iCloud** dont l'espace suffit à vos documents : l'app lit le dossier iCloud Drive que vous lui désignez, et fonctionne très bien avec « Optimiser le stockage » activé — elle télécharge à la demande ce dont elle a besoin.
- Un compte Apple Developer, ou à défaut un compte Apple gratuit (voir §6).

Budget de fonctionnement : de l'ordre de 25 € par mois tout compris, iCloud inclus, pour un usage quotidien — et le plafond intégré vous garantit de ne pas le dépasser. Le détail est au §7. L'abonnement Apple Developer (99 € par an) est à part.

---

> **Vous partez de zéro ?** Suivez `ACHATS_ET_CLES.md`, qui va dans l'ordre : d'abord **construire et installer** l'app (Apple et GitHub, **aucun Mac nécessaire**, aucune clé d'IA — étapes 0 à 7), ensuite, l'app une fois sur l'iPhone, tout ce qu'il faut **y mettre** (dossier iCloud, clés Gemini et Perplexity — étapes 8 à 13).

## 2. Installer l'app sur vos appareils

**Une seule fois, sur le Mac :**

1. Ouvrez le dossier du projet et double-cliquez sur `Atelier.xcodeproj`.
2. Dans la colonne de gauche, cliquez sur le projet **Atelier** (tout en haut), puis sur la cible **Atelier**, onglet **Signing & Capabilities**.
3. Cochez **Automatically manage signing** et choisissez votre **Team** dans le menu déroulant.
4. L'identifiant est `com.bureau.latelier`. Si Xcode se plaint qu'il est déjà utilisé, changez **Bundle Identifier** en quelque chose d'unique, par exemple `com.votrenom.latelier`.

> Cette section suppose un Mac. **Sans Mac, tout se fait depuis GitHub** : voir `ACHATS_ET_CLES.md`.

**Pour chaque appareil :**

5. Sur l'iPhone (ou l'iPad) : **Réglages › Confidentialité et sécurité › Mode développeur**, activez-le, et redémarrez l'appareil quand il le demande.
6. Branchez l'appareil au Mac par un câble. Sur l'appareil, touchez **Se fier à cet ordinateur**.
7. Dans Xcode, en haut de la fenêtre, choisissez votre appareil dans la liste, puis cliquez sur le bouton ▶︎ (ou ⌘R).
8. Au premier lancement, l'iPhone peut refuser d'ouvrir l'app : allez dans **Réglages › Général › VPN et gestion de l'appareil**, touchez votre nom de développeur, puis **Faire confiance**.
9. Relancez l'app depuis l'écran d'accueil. Vous pouvez débrancher le câble : elle fonctionne seule.

Recommencez les étapes 6 à 9 pour le second appareil.

---

## 3. Le premier démarrage, dans l'ordre

### a. Vos clés

Ouvrez l'app, touchez l'icône **horloge** en haut à gauche, puis l'**engrenage** en haut à droite.

- Collez votre clé **Gemini**.
- Collez votre clé **Perplexity** si vous en avez une.
- Touchez **Enregistrer et tester**. L'app vous dit franchement si chaque clé fonctionne.

> Le test Perplexity effectue une vraie recherche, facturée un demi-centime. C'est le seul moyen honnête de vérifier qu'une clé fonctionne.

### b. Votre dossier de documents

Toujours depuis l'accueil, touchez l'icône **dossier** en haut à droite, puis **Ajouter un dossier**. Choisissez, dans iCloud Drive, le dossier qui contient vos documents.

L'indexation démarre immédiatement, en arrière-plan. Vous pouvez chercher pendant ce temps : ce qui est déjà indexé est déjà trouvable.

**Ce qui se passe ensuite, tout seul :** à chaque ouverture de l'app et à chaque retour à l'écran, elle relit le dossier et repère ce qui a changé. Un document ajouté depuis n'importe quel appareil devient donc cherchable à la prochaine ouverture. Un document supprimé disparaît des résultats. Un document modifié est réindexé sans créer de doublon.

**Formats pris en charge :** PDF, Word, texte, Markdown, RTF, HTML, tableurs, présentations, ePub, fichiers de code. Les images, l'audio et la vidéo ne peuvent pas être indexés par Gemini : ils restent connus par leur nom, dans le catalogue, mais leur contenu n'est jamais envoyé.

**Deux limites de Gemini à connaître :** un fichier ne doit pas dépasser 100 Mo, et l'espace occupé chez Google vaut environ trois fois la taille de vos documents. L'écran **Mes fichiers** vous montre où vous en êtes.

### c. Si votre corpus dépasse le budget

Google plafonne un corpus à **10 Go**, et comme l'empreinte réelle vaut environ trois fois la taille brute, **trois giga-octets de documents remplissent déjà ce plafond**. Un corpus plus gros que cela ne peut donc pas être indexé d'un bloc — ce n'est pas un choix de l'app, c'est la limite du service.

L'app est faite pour ce cas, et elle ne vous demande rien :

- **Tout est catalogué**, quelle que soit la taille : chaque fichier est connu par son nom, son dossier et sa date. Le catalogue vit sur l'appareil, ne coûte rien et n'est jamais envoyé.
- **Le corpus indexé est un plan de travail**, pas une copie de votre disque. Il tient dans un budget que vous réglez (3 Go par défaut, le maximum qui tienne dans le quota Google), et l'app le remplit d'abord avec vos documents les plus récents.
- **Le reste entre à la demande.** Quand une question porte sur un fichier catalogué, l'app l'envoie à ce moment-là, cherche dedans, et répond. S'il n'y a plus de place, le document indexé le plus ancien cède la sienne — il reviendra de la même façon le jour où vous en aurez besoin.

Concrètement : vos 10 Go sont tous cherchables, et vous ne payez l'indexation que de ce qui sert vraiment. Une réindexation coûte quelques centimes, jamais plus.

---

## 4. L'usage au quotidien

Ouvrez l'app : le clavier est déjà là, le curseur dans le champ. Tapez, touchez **Rechercher**.

**Le sélecteur sous le champ** décide où chercher :
- **Auto** — l'app décide seule, d'après votre question. C'est le réglage normal.
- **Mes fichiers** — vos documents seulement.
- **Internet** — Perplexity seulement.
- **Les deux** — une synthèse unique qui distingue les deux types de sources.

**Pour dicter**, touchez le **micro rond** sous le champ. Le texte s'écrit au fil de votre parole, directement dans la question. Touchez-le à nouveau pour arrêter. La reconnaissance se fait **sur l'appareil** : votre voix ne part nulle part, et cela ne coûte rien. Le clavier reste fermé pendant ce temps.

**Pour un mémo long**, maintenez ce même micro. L'app enregistre jusqu'à une heure, puis Gemini transcrit — meilleur sur la ponctuation et les noms propres, pour quelques centièmes de centime la minute. Vous relisez avant que cela devienne une question.

**Pour un mémo long**, maintenez le doigt sur le bouton micro rond de l'app. Un panneau s'ouvre avec un chronomètre. À la fin, l'enregistrement est transcrit par Gemini, et le texte s'affiche pour que vous le relisiez et le corrigiez **avant** qu'il devienne une question.

**Dans les résultats :**
- Les petits numéros `[L1]`, `[W2]` sont touchables : ils font défiler jusqu'à la source correspondante.
- Une carte source « fichier » s'ouvre dans un aperçu — à la bonne page pour un PDF.
- Une carte source « web » s'ouvre dans Safari.
- **Question de suite** poursuit la conversation en réutilisant les sources déjà trouvées.
- **Compléter sur Internet** ajoute une recherche web à un résultat obtenu sur vos seuls fichiers.
- **Approfondir** relance en mode recherche approfondie, plus lente et plus chère ; le coût estimé est affiché sur le bouton.

**L'historique** (icône horloge) garde tout : recherches, synthèses, sources, questions de suite. Il est cherchable, et chaque ligne affiche son coût.

### Sur iPad

L'historique occupe une barre latérale repliable, et en paysage large la synthèse et les sources s'affichent côte à côte. Avec un clavier : **⌘⏎** lance la recherche, **⌘K** revient au champ, **⌘Y** montre ou cache l'historique, **⌘N** démarre une nouvelle recherche, **⌘⇧F** ouvre Mes fichiers, **⌘,** les réglages.

---

## 5. Ce que l'app fait pour ne pas dépenser inutilement

1. **Avant tout appel payant**, elle compare votre question aux précédentes. Deux formulations différentes de la même demande sont reconnues comme identiques.
2. Si la même question a déjà reçu une réponse **il y a moins de sept jours**, le résultat est réutilisé directement, sans rien dépenser. Un bouton **Relancer** reste disponible.
3. Si la question est **proche sans être identique**, une carte vous propose : **Réutiliser**, **Compléter** (ne relancer que ce qui manque, en gardant la moitié déjà obtenue), ou **Nouvelle recherche**. Seule l'analyse de la question a été payée à ce stade — environ un demi-millième de dollar ; la recherche elle-même, qui coûte dix fois plus, attend votre choix.
4. Une question portant sur l'actualité n'est **jamais** réutilisée automatiquement.
5. Chaque recherche affiche son coût. L'historique affiche le total du mois. Au **plafond** (25 $ par défaut, soit environ 23 € TTC, modifiable), les appels payants s'arrêtent : l'historique reste consultable et l'app vous le dit clairement.

---

## 6. Signature : ce qu'il faut savoir sur la durée de validité

- **Avec un compte Apple Developer payant (99 $/an)** : l'app installée reste valable environ **un an**. Passé ce délai, vous rebranchez l'appareil au Mac et vous relancez la compilation — une vingtaine de minutes, une fois par an.
- **Avec un compte Apple gratuit** (« Personal Team ») : tout fonctionne, mais l'app **expire au bout de sept jours** et doit être réinstallée. C'est utilisable pour essayer, pas au quotidien.

Si votre inscription au programme développeur n'est pas encore active — l'inscription individuelle prend parfois un ou deux jours —, installez d'abord avec le compte gratuit. Le passage au compte payant ne demande ensuite qu'une chose : sélectionner votre équipe dans Xcode et recompiler. Rien d'autre ne change, et vos données sur l'appareil sont conservées.

*Note, pour plus tard :* une distribution App Store « non listée » n'expire jamais, mais suppose une revue par Apple et une demande d'autorisation spécifique. Ce n'est pas nécessaire aujourd'hui.

---

## 7. Ce que cela coûte

| Quoi | Combien |
|---|---|
| Indexation de vos documents | environ 0,15 $ par million de mots, **une fois par fichier** |
| Stockage chez Google | **gratuit** |
| Une recherche dans vos fichiers | environ 0,005 $ |
| Une recherche Internet standard | 0,005 $ (tarif fixe, jusqu'à cinq requêtes par appel) |
| Une recherche Internet approfondie | de 0,01 à 0,05 $ |
| Une transcription d'une minute | environ 0,0006 $ |

Ces montants sont **hors taxes**, comme les tarifs publiés. L'app, elle, affiche tout **TVA comprise** (20 %, modifiable dans Diagnostics), et convertit les totaux en euros pour que le plafond corresponde à votre budget réel.

### Votre budget de 30 € par mois

| Poste | Où cela se paie | Ordre de grandeur |
|---|---|---|
| iCloud (le dossier que l'app surveille) | Apple, abonnement | 0,99 € à 2,99 € selon le forfait |
| Gemini — indexation puis recherche dans vos fichiers | Google, à l'usage | quelques euros |
| Perplexity — recherche Internet | Perplexity, crédits prépayés | 0,006 € par recherche standard |

Le plafond de l'app est réglé à **25 $, soit environ 23 € TTC**, et il couvre Gemini et Perplexity ensemble. Avec l'abonnement iCloud, vous restez sous les 30 €, et l'app s'arrête d'elle-même avant de les dépasser. En pratique, 23 € par mois représentent plus de deux mille recherches : vous ne les atteindrez pas.

L'abonnement Apple Developer à 99 € par an n'entre pas dans ce compte, et l'app ne le connaît pas.

**Il n'existe pas de version gratuite de cette app :** chercher dans vos fichiers passe par Gemini, comme chercher sur Internet passe par Perplexity. Ce qui est gratuit, c'est le catalogue — savoir quels fichiers vous avez, les retrouver par leur nom — et le stockage du corpus chez Google. Ce qui se paie, c'est l'indexation, une fois par fichier, et chaque question posée.

**Et la clé gratuite de Google ?** Elle existe, mais ne l'utilisez pas ici. Les conditions d'utilisation de l'API Gemini distinguent l'offre gratuite de l'offre facturée : sur la gratuite, Google se réserve le droit de lire vos documents, de les faire relire par des humains et de s'en servir pour améliorer ses produits ; le corpus y est en outre plafonné à 1 Go. Dès que la facturation est activée sur le projet, cela cesse — vos fichiers ne servent plus qu'à vous répondre. Pour des documents personnels, la clé facturée est le seul choix raisonnable. Les tarifs sont relevés le 13 août 2026 et modifiables dans **Réglages › Diagnostics** si Google ou Perplexity les changent.

---

## 8. En cas de problème

**« Gemini refuse la clé (erreur 401) »** — La clé est incorrecte, ou la facturation n'est pas activée sur le projet Google AI Studio. Recollez-la dans les réglages.

**« Le dossier n'est plus accessible »** — L'autorisation d'accès a été perdue (dossier déplacé, renommé, ou autorisation révoquée). Ouvrez **Mes fichiers** et redésignez le dossier : votre registre et votre corpus sont conservés.

**Un fichier reste en erreur** — Son message précis est sous son nom dans **Mes fichiers**. Les causes habituelles : fichier de plus de 100 Mo, ou fichier iCloud non encore téléchargé (l'app réessaiera au prochain scan).

**Une recherche échoue** — La carte d'erreur donne la cause en clair et un bouton **Réessayer**. L'app retente déjà toute seule, avec un délai croissant, sur les erreurs 429 et 5xx.

**L'app ne trouve rien dans vos fichiers** — Vérifiez dans **Mes fichiers** que les documents concernés sont bien dans la liste **Indexés** et non dans **Catalogués**. Si le scan n'a jamais tourné, touchez **Scanner maintenant**.

**Rien ne se passe au lancement de la recherche** — Vérifiez que la clé Gemini est enregistrée, et que le plafond mensuel n'est pas atteint (visible en tête de l'historique).

---

## 9. Confidentialité

- Vos documents sont envoyés **uniquement à Google**, pour être indexés et cités — et seulement ceux qui entrent dans le corpus : le catalogue, lui, ne quitte jamais l'appareil.
- La clé Gemini doit venir d'un projet **où la facturation est activée** : c'est ce qui interdit contractuellement à Google d'exploiter vos documents (voir §7).
- Perplexity ne reçoit **que la question reformulée**, jamais un extrait de vos fichiers.
- Aucune autre destination. Aucune analyse d'usage, aucun traceur, aucun compte.
- Les clés vivent dans le **trousseau** de l'appareil, protégées après le premier déverrouillage, jamais dans une sauvegarde ni dans le dépôt de code.
- L'historique est un fichier JSON dans l'espace privé de l'app, exportable et effaçable depuis les réglages.

---

## 10. Améliorations possibles, notées mais non faites

- **Transcription locale avec `SpeechAnalyzer` (iOS 26)** : gratuite et sans envoi de l'audio à Google. Aujourd'hui la transcription passe par Gemini, pour un coût de l'ordre du millième de dollar par minute. Le remplacement est circonscrit à un seul fichier, `VoiceRecorder.swift`.
- **Synchronisation de l'historique entre iPhone et iPad** : aujourd'hui chaque appareil garde le sien. L'export/import JSON des réglages permet de transférer manuellement.
- **Filtres d'exclusion par sous-dossier** dans l'écran Mes fichiers : la structure de données les gère déjà, l'interface de saisie reste à faire.

---

## 11. Fichiers utiles du dépôt

| Fichier | À quoi il sert |
|---|---|
| `ACHATS_ET_CLES.md` | Dans l'ordre : construire et installer l'app, puis ce qu'il faut y mettre |
| `.github/workflows/signature.yml` | Crée le certificat et le profil chez Apple, sans Mac, et dépose les secrets |
| `Tools/apple_signature.py` | Les appels à l'API App Store Connect employés par ce flux |
| `CHECKLIST_APPAREIL.md` | Ce que vous devez vérifier vous-même, dans l'ordre, sur iPhone et iPad |
| `.github/workflows/build.yml` | Compile à chaque envoi de code et affiche les erreurs — aucun secret nécessaire |
| `.github/workflows/testflight.yml` | Construit, signe et dépose une version sur TestFlight, sur demande |
| `NOTES_API.md` | Les formats réels des API, relevés dans la documentation officielle, avec ce qui reste à confirmer |
| `Tools/test-apis.sh` | Vérifie les appels réels avec vos clés et affiche les réponses brutes |
| `Tools/typecheck.sh` | Relit le code hors Xcode (ne remplace pas une compilation) |
| `Tools/run-tests.sh` | Exécute les tests de logique pure : persistance, anti-dépense, calcul des coûts |
| `Tools/make-icon.sh` | Régénère l'icône de l'app |
| `PLAN.md` | Le plan de construction et son état |
| `docs/CAHIER_DES_CHARGES.md` | Le cahier des charges consolidé, pour qu'une session de travail future n'ait pas besoin de la conversation d'origine |
