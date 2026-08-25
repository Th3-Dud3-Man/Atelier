# Ce que vous devez vérifier vous-même

Je n'ai ni Mac, ni Xcode, ni vos appareils, ni vos clés : cette session tourne dans un conteneur Linux. Le code a été relu par un compilateur Swift 6 pour tout ce qui ne dépend pas des cadres Apple (12 fichiers sur 25), mais **rien n'a été compilé ni exécuté**. Cette liste est donc le vrai passage de la théorie au fonctionnement.

Suivez-la dans l'ordre. À chaque étape : ce qu'il faut voir, et quoi faire sinon. Copiez-moi tout message d'erreur, même long, même illisible — c'est exactement ce dont j'ai besoin.

---

## Étape 0 — La compilation (sur le Mac)

1. `open Atelier.xcodeproj`
2. Le projet s'ouvre, et la colonne de gauche montre le dossier **Atelier** avec `Models`, `Services`, `Views`.
3. Cible **Atelier** › **Signing & Capabilities** › cochez *Automatically manage signing*, choisissez votre **Team**.
4. Choisissez un simulateur iPhone en haut, puis ⌘B (Build).

**Attendu :** « Build Succeeded ».

**Sinon :**
- *« The project cannot be opened »* ou *« damaged »* → le fichier projet est en cause, pas le code. Dites-le-moi : je vous donnerai la procédure de recréation en deux minutes (Fichier › Nouveau › Projet, puis glisser le dossier `Atelier`).
- *Erreurs de compilation Swift* → attendu et normal pour une première compilation à l'aveugle. Copiez-moi la liste complète (clic droit sur la zone d'erreurs › Copy). Je corrige et vous relancez.
- *« Signing requires a development team »* → l'étape 3 n'a pas été faite.
- *Erreurs de concurrence Swift 6* → si elles sont nombreuses et bloquantes, un repli existe : cible Atelier › Build Settings › cherchez `Swift Language Version` › passez de 6 à 5. Dites-le-moi, je corrigerai proprement ensuite.

---

## Étape 1 — Premier lancement sur le simulateur

5. ⌘R.

**Attendu :** un écran presque vide, fond clair ou sombre selon le système, le mot « L'Atelier » en petit, un champ de saisie **avec le clavier déjà ouvert et le curseur dedans**, un sélecteur *Auto · Mes fichiers · Internet · Les deux*, un bouton micro rond, un bouton **Rechercher** grisé, une horloge en haut à gauche, un dossier en haut à droite.

**À vérifier aussi :** le bouton Rechercher devient bleu encre dès que vous tapez ; la croix efface le champ ; le titre « L'Atelier » disparaît quand le champ prend le focus.

**Sinon :** décrivez-moi ce que vous voyez, une capture d'écran suffit.

---

## Étape 2 — Installation sur l'iPhone

6. Sur l'iPhone : **Réglages › Confidentialité et sécurité › Mode développeur** → activez, redémarrez.
7. Branchez l'iPhone, touchez **Se fier à cet ordinateur**.
8. Dans Xcode, choisissez l'iPhone, ⌘R.
9. Si l'app refuse de s'ouvrir : **Réglages › Général › VPN et gestion de l'appareil** → votre nom → **Faire confiance**.
10. Débranchez le câble et relancez l'app depuis l'écran d'accueil.

**Attendu :** l'app se lance seule, sans le Mac. L'icône est un « A » blanc sur fond bleu encre.

---

## Étape 3 — Les clés

11. Horloge (en haut à gauche) → engrenage (en haut à droite).
12. Collez la clé Gemini. Collez la clé Perplexity si vous en avez une.
13. **Enregistrer et tester**.

**Attendu :** « Gemini : la clé fonctionne. » et, le cas échéant, « Perplexity : la clé fonctionne (N résultat(s)). »

**Sinon :** le message donne la cause. Une erreur 401 signifie clé invalide ou facturation non activée côté Google AI Studio.

14. Fermez et rouvrez complètement l'app, puis revenez aux réglages : **les clés doivent toujours être là**. Si elles ont disparu, le trousseau ne les garde pas — dites-le-moi.

---

## Étape 4 — Le dossier iCloud, et le premier scan

15. Retour à l'accueil → icône **dossier** → **Ajouter un dossier**.
16. Le sélecteur système s'ouvre. Naviguez vers iCloud Drive et **sélectionnez un dossier** (pas un fichier).

**Attendu :** le bouton de validation du sélecteur s'active quand un dossier est mis en évidence. Le dossier apparaît ensuite dans « Dossiers surveillés » avec un nombre de fichiers.

**Sinon :** si le bouton de validation reste grisé quoi que vous sélectionniez, c'est un problème connu de type de contenu — dites-le-moi, la correction est d'une ligne.

17. Regardez la progression : « Indexation 3 / 120 — nom du fichier ».

**Attendu :** elle avance. Les fichiers passent de *Catalogués* à *Indexés*. Vous pouvez quitter l'écran, l'indexation continue.

**Points de vigilance à me rapporter :**
- Un fichier bloqué longtemps sur le même nom → probablement un téléchargement iCloud lent (fichier « allégé »). Attendez, puis relancez **Scanner maintenant**.
- Beaucoup de fichiers en erreur → copiez-moi deux ou trois messages.
- Aucun fichier trouvé alors que le dossier n'est pas vide → dites-le-moi, c'est l'énumération qui est en cause.

18. **Le test qui compte** : ajoutez un document dans ce dossier depuis votre Mac, attendez qu'iCloud le synchronise, mettez l'app en arrière-plan puis revenez-y.

**Attendu :** le nouveau fichier apparaît et s'indexe seul, sans rien faire.

---

## Étape 5 — Chercher dans vos fichiers

19. Posez une question dont vous **connaissez la réponse** dans vos documents, formulée **avec d'autres mots que le texte**.

**Attendu :** la ligne d'état énonce les étapes (« Analyse de la question… », « Recherche dans vos fichiers… », « Rédaction de la synthèse… ») ; les sources apparaissent ; la synthèse s'écrit progressivement ; chaque affirmation porte un `[L1]`, `[L2]`.

20. Touchez un `[L1]` dans le texte.

**Attendu :** la vue défile jusqu'à la carte source, qui se met en évidence.

21. Sur une carte source, touchez **Ouvrir**.

**Attendu :** le document s'ouvre. Pour un PDF, **à la bonne page**.

**À me rapporter :**
- Le passage cité correspond-il vraiment au document ? (C'est le point le plus important.)
- Le numéro de page est-il juste ?
- La synthèse invente-t-elle une référence absente des sources ? Si oui, copiez-moi la synthèse entière.

22. Posez une question dont la réponse **n'est pas** dans vos documents.

**Attendu :** l'app dit franchement qu'elle ne peut pas répondre à partir des sources, et indique ce qui manque. Elle ne doit rien inventer.

---

## Étape 6 — Chercher sur Internet, et l'anti-dépense

23. Sélecteur sur **Internet**, posez une question d'actualité.

**Attendu :** des sources web avec titre, domaine, date et extrait. Chaque adresse doit s'ouvrir réellement dans Safari.

24. Sélecteur sur **Les deux**, posez une question qui touche vos documents *et* l'actualité.

**Attendu :** une seule synthèse mêlant `[L…]` et `[W…]`.

25. **Le test de l'anti-dépense** : reposez, avec d'autres mots, une question déjà posée il y a moins d'une semaine.

**Attendu :** deux comportements possibles, selon la proximité des deux formulations.

- *Question strictement équivalente* : le résultat est réutilisé immédiatement, la mention indique « aucune dépense », et un bouton **Relancer** reste disponible. Cette voie est **entièrement gratuite** : elle est décidée sur l'appareil, sans aucun appel.
- *Question proche sans être identique* : une carte propose **Réutiliser / Compléter / Nouvelle recherche**. Ici, l'analyse de votre question a bien eu lieu — c'est elle qui a reconnu le doublon — et elle coûte environ 0,0005 $. **Aucune recherche n'est lancée avant votre choix** : c'est la dépense principale, celle qui est évitée.

Vérifiez aussi que **Relancer** relance vraiment (le coût affiché doit augmenter) et que **Compléter** conserve la moitié déjà obtenue au lieu de tout refaire.

26. Vérifiez le coût affiché sous la question, et le total du mois en tête de l'historique.

**À me rapporter :** le coût affiché correspond-il, à peu près, à ce que Google et Perplexity facturent réellement sur vos tableaux de bord ?

---

## Étape 7 — La voix

27. Touchez brièvement le bouton micro.

**Attendu :** au premier usage, une explication indique que la dictée passe par le micro du clavier iOS. Ensuite, le champ reprend simplement le focus.

28. Utilisez le micro **du clavier** pour dicter une question, puis lancez la recherche.

**Attendu :** le texte s'écrit au fil de la parole, gratuitement et sans réseau.

29. **Maintenez** le doigt sur le bouton micro de l'app.

**Attendu :** iOS demande l'autorisation du micro (une seule fois) ; un panneau s'ouvre avec un chronomètre qui avance.

30. Parlez une minute, puis touchez le bouton micro pour arrêter.

**Attendu :** « Transcription en cours… », puis un écran affichant le texte, **modifiable**, avec un bouton **Rechercher à partir de ce texte**.

**À me rapporter :** la qualité de la transcription sur votre diction, et le temps d'attente pour une minute d'enregistrement.

31. Refaites-le avec un mémo de **dix minutes**.

**Attendu :** cela fonctionne aussi — au-delà de douze méga-octets, l'app bascule automatiquement sur une autre voie d'envoi. Si cette étape échoue alors que la minute passait, c'est précisément cette bascule qui est en cause : dites-le-moi.

---

## Étape 8 — L'iPad

32. Installez sur l'iPad (mêmes étapes 6 à 10).

**Attendu :** l'historique occupe une barre latérale ; en paysage, la synthèse et les sources s'affichent côte à côte.

33. Avec un clavier : **⌘⏎**, **⌘K**, **⌘Y**, **⌘N**, **⌘,**.

**À me rapporter :** ceux qui ne répondent pas.

---

## Étape 9 — Les cas dégradés

34. **Mode avion**, puis lancez une recherche.

**Attendu :** un message clair (« injoignable », « vérifiez votre connexion ») et un bouton **Réessayer**. L'historique reste lisible. **Aucun plantage.**

35. Dans les réglages, passez le plafond mensuel **en dessous** de votre total du mois, puis cherchez.

**Attendu :** l'app refuse poliment, explique que le plafond est atteint, et renvoie vers les réglages. Remettez ensuite le plafond à 15 $.

36. Effacez la clé Perplexity, puis cherchez avec le sélecteur sur **Internet**.

**Attendu :** l'app bascule sur vos fichiers plutôt que d'échouer, ou vous dit clairement ce qui manque.

37. Fermez l'app complètement (glissez-la hors du sélecteur d'apps) et rouvrez-la.

**Attendu :** l'historique, les réglages, les dossiers et le corpus sont intacts.

---

## Étape 10 — Les appels réels aux API

38. Sur le Mac, dans le dossier du projet :

```bash
export GEMINI_API_KEY="votre-clé"
export PERPLEXITY_API_KEY="votre-clé"
Tools/test-apis.sh
```

**Copiez-moi la sortie complète.** Elle tranche six points que la documentation laisse ambigus (forme exacte des fragments en flux, acceptation du schéma JSON, présence du numéro de page sur un vrai PDF…). Ces points sont listés au §5 de `NOTES_API.md` ; votre sortie me permet de les figer.

---

## Ce que je ne peux pas vérifier, et qui ne dépend que de vous

- La compilation et la signature.
- L'accès réel à iCloud Drive et le téléchargement des fichiers allégés.
- Le micro et l'autorisation d'enregistrement.
- La qualité des résultats sur **votre** corpus : c'est vous seul qui savez si le bon passage a été retrouvé.
- La concordance entre les coûts affichés et vos factures réelles.

---

## Note technique : les réglages de concurrence du projet

Le projet est en **Swift 6.0** avec la concurrence stricte, mais **sans**
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` ni `SWIFT_APPROACHABLE_CONCURRENCY`, que les gabarits
Xcode 26 activent par défaut.

C'est délibéré. La chaîne Swift dont je dispose ici (6.1.2 sous Linux) ne connaît pas ces réglages :
je ne peux donc pas vérifier le code avec eux. Le projet livré correspond exactement à la sémantique
que le compilateur a validée. Chaque type isolé porte de toute façon son `@MainActor` explicite,
donc rien ne dépend d'une valeur par défaut.

Ce choix a une conséquence concrète, qui a d'ailleurs failli passer inaperçue : sous
`SWIFT_APPROACHABLE_CONCURRENCY`, une fonction `nonisolated async` s'exécute **sur l'acteur
appelant** au lieu de basculer hors de lui. Le parcours des dossiers, qui est bloquant, se serait
alors déroulé sur le fil principal et aurait figé l'interface. Le code utilise désormais une tâche
détachée avec relais d'annulation, ce qui est correct dans les deux configurations.

Si vous voulez activer ces réglages plus tard, dites-le-moi : c'est faisable, mais cela demande une
relecture des isolations, pas une simple case à cocher.
