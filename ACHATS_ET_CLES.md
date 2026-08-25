# Dans l'ordre : construire l'app, puis la remplir

Deux moments distincts, et c'est ce qui compte.

**Partie A — construire et installer l'app.** Uniquement Apple et GitHub, **et aucun Mac
n'est nécessaire** : le certificat et le profil de signature sont créés par l'API d'Apple
depuis GitHub. Rien à payer d'autre que l'abonnement développeur que vous avez déjà.
Comptez une demi-heure, entièrement dans un navigateur.

**Partie B — une fois l'app sur l'iPhone.** C'est là que vous créez vos clés Gemini et
Perplexity, que vous les collez dans les réglages de l'app, et que vous lui désignez
votre dossier iCloud. Comptez vingt minutes.

**La règle qui ne souffre aucune exception :** vos clés Gemini et Perplexity ne vont
**jamais** sur GitHub. Elles vivent dans le trousseau de l'iPhone. Les secrets de la
partie A ne servent qu'à Apple — signer l'app et la déposer sur TestFlight.

---

# PARTIE A — Construire et installer l'app (sans Mac)

Tout se fait depuis un navigateur. Le certificat et le profil de signature, qu'on exporte
d'habitude depuis un Mac, sont créés ici par l'API d'Apple, à l'intérieur de GitHub.

Vous n'avez que deux formulaires à remplir chez Apple et quatre valeurs à copier.

## Étape 0 — Vérifier que le code compile (gratuit, cinq minutes)

Inutile de s'occuper de signature si le code ne compile pas.

1. Sur GitHub, onglet **Actions**.
2. Le flux **Compiler** s'est déclenché tout seul au dernier envoi de code. Ouvrez la
   dernière exécution.
3. **Vert :** passez à l'étape 1.
4. **Rouge :** copiez l'encadré « Erreurs et avertissements » et envoyez-le-moi. Je
   corrige, vous relancez. C'est la première fois que ce code voit un vrai compilateur :
   quelques allers-retours sont normaux.

## Étape 1 — Créer la clé App Store Connect

C'est la seule clé Apple dont vous aurez besoin. Elle sert à tout : créer l'identifiant de
l'app, le certificat, le profil, et déposer les versions.

1. **appstoreconnect.apple.com** → **Utilisateurs et accès** → onglet **Intégrations**.
2. Section **App Store Connect API**, sous-onglet **Accès à l'équipe** → le **+**.
3. *Nom* : `GitHub` · *Accès* : **App Manager** → **Générer**.
4. **Téléchargez le fichier `.p8` tout de suite** : Apple ne le propose qu'une seule fois.
5. Notez, sur la même page, le **Key ID** (dix caractères) et l'**Issuer ID** (long
   identifiant à tirets, en haut de la section).

*Le `.p8` est un fichier texte. Ouvrez-le avec n'importe quel éditeur — Bloc-notes,
TextEdit — pour en copier le contenu. Sur iPhone ou iPad, renommez-le en `.txt` dans
l'app Fichiers, il s'ouvrira alors d'une simple touche.*

## Étape 2 — Créer un jeton GitHub

Il permet au flux de déposer lui-même les secrets qu'il fabrique, pour que vous n'ayez
jamais à manipuler une clé privée.

1. **github.com/settings/personal-access-tokens** → **Generate new token**
   (*fine-grained*).
2. *Repository access* : **Only select repositories** → votre dépôt **Atelier**.
3. *Repository permissions* → **Secrets** → **Read and write**. Rien d'autre.
4. *Expiration* : 30 jours suffisent, ce jeton ne sert qu'aujourd'hui.
5. **Generate token** et copiez-le : lui non plus ne se réaffiche pas.

## Étape 3 — Déposer les quatre premiers secrets

Sur votre dépôt : **Settings** → **Secrets and variables** → **Actions** →
**New repository secret**. Quatre fois, le nom exactement comme écrit ici.

| Nom du secret | Ce qu'on y met |
|---|---|
| `ASC_KEY_ID` | le Key ID de l'étape 1 |
| `ASC_ISSUER_ID` | l'Issuer ID de l'étape 1 |
| `ASC_PRIVATE_KEY` | **tout le contenu** du fichier `.p8`, lignes `BEGIN` et `END` comprises |
| `GH_SECRETS_TOKEN` | le jeton de l'étape 2 |

## Étape 4 — Lancer « Préparer la signature »

1. Onglet **Actions** → flux **Préparer la signature** → **Run workflow**.
2. Une minute. Le flux, dans l'ordre : déclare l'identifiant `com.bureau.latelier` chez
   Apple s'il n'existe pas ; fabrique une clé privée ; demande à Apple un certificat de
   distribution ; crée le profil `Atelier App Store` ; en déduit votre identifiant
   d'équipe ; et dépose **cinq secrets de plus** sur le dépôt.

La clé privée est fabriquée dans l'exécution et va directement dans les secrets : elle
n'est jamais affichée, jamais écrite sur un disque qui vous survive.

**Si Apple refuse en disant que vous avez trop de certificats de distribution** (la limite
est de trois) : relancez le flux en cochant *Révoquer le plus ancien certificat de
distribution*. Attention, un certificat révoqué invalide les apps signées avec lui — sans
effet si vous ne distribuez rien d'autre.

**Ce flux n'est à relancer que dans un an**, quand le certificat expirera.

## Étape 5 — Créer la fiche de l'app

Maintenant que l'identifiant existe chez Apple, la fiche peut être créée.

1. **appstoreconnect.apple.com** → **Mes apps** → le **+** → **Nouvelle app**.
2. Plateforme **iOS** · nom `L'Atelier` (s'il est pris, `L'Atelier — Lucas` : ce nom ne se
   voit que dans TestFlight) · langue **Français** · *Bundle ID* `com.bureau.latelier` ·
   **SKU** `latelier-1`.
3. **Créer**. Rien d'autre à remplir : une app qui reste en TestFlight n'a besoin ni de
   captures d'écran, ni de description, ni de passer en revue.

## Étape 6 — Construire et envoyer

1. Onglet **Actions** → flux **TestFlight** → **Run workflow** → branche
   `claude/new-session-rxzige` → **Run workflow**.
2. Cinq à dix minutes, puis une dizaine de minutes de traitement chez Apple.
3. **appstoreconnect.apple.com** → votre app → onglet **TestFlight** → quand la version
   est « Prête à tester », ajoutez-vous comme **testeur interne**.

## Étape 7 — Installer sur l'iPhone et l'iPad

1. Installez **TestFlight** depuis l'App Store, sur les deux appareils.
2. Ouvrez-le avec le même compte Apple : **L'Atelier** y est. Installez.
3. L'app vous dira qu'il lui manque une clé — c'est normal, c'est la partie B.

**Une fois cette partie faite, vous n'y reviendrez que pour installer une nouvelle
version : un clic sur « Run workflow », rien d'autre.**

Quand tout marche, vous pouvez supprimer le secret `GH_SECRETS_TOKEN` : il n'a servi qu'à
l'étape 4.

---

# PARTIE B — Ce que vous mettez dans l'app

## Étape 8 — Préparer le dossier iCloud

1. Sur l'iPhone : **Réglages** → votre nom → **iCloud** → **iCloud Drive** activé.
2. Rangez vos documents dans **un seul dossier** d'iCloud Drive, sous-dossiers permis.
   C'est ce dossier que vous désignerez à l'app.
3. « Optimiser le stockage » peut rester activé : l'app déclenche elle-même le
   téléchargement du fichier dont elle a besoin, quand elle en a besoin.

## Étape 9 — Créer la clé Gemini

C'est elle qui lit vos fichiers et rédige les réponses. Sans elle, l'app ne fait rien.

1. **aistudio.google.com** → connectez-vous → **Get API key** → **Create API key**.
2. Choisissez ou créez un projet Google Cloud.
3. **Activez la facturation sur ce projet** (« Set up billing »), avec une carte bancaire.

   Ce n'est pas qu'une question de quota. Sur l'offre gratuite, les conditions
   d'utilisation autorisent Google à lire vos documents, à les faire relire par des
   humains et à s'en servir pour améliorer ses produits, et votre corpus est plafonné à
   1 Go. Avec la facturation activée, Google s'interdit contractuellement tout cela et le
   plafond passe à 10 Go.

4. Copiez la clé — elle commence par `AIza…`. Gardez l'onglet ouvert.
5. **Posez un garde-fou** : console Google Cloud → **Billing** → **Budgets & alerts** →
   **Create budget** → 25 € par mois, alertes à 50 %, 90 % et 100 %.

*Renouvellement : rien à faire. Google facture l'usage du mois écoulé, comme
l'électricité. Un mois sans question ne coûte rien, et le service ne s'interrompt jamais.*

## Étape 10 — Créer la clé Perplexity (facultative)

Elle ne sert qu'à la recherche Internet. Sans elle, l'app cherche dans vos fichiers et
le dit clairement.

1. **perplexity.ai** → **Settings** → **API**.
2. **API Keys** → **Generate**. La clé commence par `pplx-…`.
3. **Billing** → **Buy more credits** → 10 $. Ce ne sont **pas** 10 $ par mois : une
   réserve prépayée qui se consomme, plus de mille cinq cents recherches, et un mois sans
   recherche ne coûte rien.
4. **Pour que cela ne s'arrête jamais** : sur la même page, à côté d'**Auto reload**,
   **Change preferences** → recharger 10 $ dès que le solde passe sous 3 $. Cette option
   est **désactivée par défaut**, et c'est le seul des quatre services qui puisse
   s'arrêter tout seul.
5. Abaissez au passage le plafond de dépense mensuel proposé à une dizaine de dollars.

*À ne pas confondre avec l'abonnement Perplexity Pro (~20 €/mois), qui est un autre
produit dont l'app n'a pas besoin.*

## Étape 11 — Coller les deux clés dans l'app

1. Ouvrez **L'Atelier** sur l'iPhone.
2. Icône **horloge** (en haut à gauche) → **engrenage** (en haut à droite).
3. Collez la clé **Gemini**, puis la clé **Perplexity**.
4. **Enregistrer et tester**. L'app vous dit franchement si chaque clé fonctionne.

> Le test Perplexity effectue une vraie recherche, facturée un demi-centime. C'est le seul
> moyen honnête de vérifier qu'une clé marche.

5. Fermez complètement l'app, rouvrez-la, revenez aux réglages : **les clés doivent
   toujours être là**. Si elles ont disparu, dites-le-moi.

## Étape 12 — Désigner votre dossier

1. Retour à l'accueil → icône **dossier** (en haut à droite) → **Ajouter un dossier**.
2. Le sélecteur d'iCloud Drive s'ouvre : choisissez **un dossier**, pas un fichier.
3. L'indexation démarre seule, en arrière-plan. Vous pouvez chercher pendant ce temps.

Sur un corpus de plus de 3 Go, l'app remplit son budget avec vos documents les plus
récents, laisse le reste au catalogue, et ira y chercher à la demande. C'est prévu, et
`CHECKLIST_APPAREIL.md` contient le test qui le vérifie.

## Étape 13 — Votre première question

Posez une question dont vous **connaissez la réponse** dans vos documents, formulée **avec
d'autres mots que le texte**. C'est le seul essai qui prouve que la recherche fonctionne
vraiment.

Puis suivez `CHECKLIST_APPAREIL.md` : il reprend, dans l'ordre, tout ce qu'il faut
éprouver sur l'appareil, avec le résultat attendu à chaque fois et ce qu'il faut me
signaler.

---

# Ce que vous payez, et comment cela se renouvelle

| | Où | Combien | Renouvellement |
|---|---|---|---|
| Apple Developer | developer.apple.com | 99 € / an | automatique |
| iCloud | Réglages de l'iPhone | 0,99 € à 2,99 € / mois | automatique |
| Gemini | aistudio.google.com | à l'usage, quelques € / mois | prélevé chaque mois |
| Perplexity | perplexity.ai | crédits prépayés, ~0,006 € la recherche | **à activer** (étape 10) |
| GitHub Actions | github.com | gratuit | — |

Le plafond intégré à l'app est réglé à environ 23 € TTC par mois et couvre Gemini et
Perplexity ensemble. Avec iCloud, vous restez sous les 30 €, et l'app s'arrête d'elle-même
avant de les dépasser.

Sur GitHub, les minutes macOS comptent dix fois : les 2 000 minutes gratuites d'un dépôt
privé en valent 200, soit une vingtaine de constructions par mois. Le dépôt ne contenant
aucun secret, le rendre public rend tout illimité.

---

# Si quelque chose bloque

**« Les secrets de signature manquent »** — L'étape 4 n'a pas été faite, ou elle a échoué.
Ouvrez son exécution : le message d'Apple y est repris tel quel.

**« No signing certificate found » ou « Provisioning profile doesn't match »** — Le
certificat et le profil ne se correspondent plus. Relancez **Préparer la signature** : il
retire l'ancien profil et en recrée un accordé au nouveau certificat.

**L'étape 4 échoue en disant que le jeton n'a pas le droit d'écrire les secrets** — Le
jeton de l'étape 2 n'a pas l'autorisation **Secrets : Read and write**, ou ne vise pas ce
dépôt. Refaites-le.

**Apple refuse de créer un certificat de plus** — Vous en avez déjà trois. Relancez
l'étape 4 en cochant la case de révocation.

**L'envoi dit que le build existe déjà** — Deux constructions ont porté le même numéro.
Relancez : le numéro suit le compteur GitHub et s'incrémente seul.

**Xcode 26 introuvable sur le runner** — Le journal de l'étape « Choisir la version
d'Xcode » liste ce qui est installé. Envoyez-le-moi, je fige la version.

Dans tous les cas, le journal complet se télécharge en bas de la page de la construction,
sous **Artifacts**. C'est le document le plus utile à me transmettre.
