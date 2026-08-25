# Ce qu'il faut acheter, et où trouver chaque clé

Guide pas à pas, dans l'ordre. Comptez une heure la première fois, pauses comprises.
Rien ici ne demande de savoir programmer : ce sont des formulaires à remplir et des
fichiers à copier.

**Une règle qui ne souffre aucune exception :** vos clés Gemini et Perplexity ne vont
**jamais** sur GitHub. Elles se saisissent dans les réglages de l'app, sur votre iPhone,
et vivent dans le trousseau de l'appareil. Les secrets GitHub décrits plus bas ne servent
qu'à Apple — signer l'app et la déposer sur TestFlight.

---

## Récapitulatif de ce que vous allez payer

| Quoi | Où | Combien | Obligatoire ? |
|---|---|---|---|
| Compte Apple Developer | developer.apple.com | 99 € / an | oui, vous l'avez déjà |
| Crédit API Google (Gemini) | aistudio.google.com | à l'usage, quelques euros / mois | **oui** |
| Crédit API Perplexity | perplexity.ai/settings/api | à l'usage, ~0,006 € la recherche | seulement pour Internet |
| iCloud | Réglages de l'iPhone | 0,99 € à 2,99 € / mois | oui, pour le dossier surveillé |
| GitHub Actions | github.com | gratuit sur un dépôt public, 2 000 min/mois sur un privé | oui |

Les minutes GitHub sur macOS comptent **dix fois** : 2 000 minutes gratuites en valent 200
sur un Mac. Une construction prend cinq à dix minutes. Vous avez donc de quoi faire une
vingtaine d'envois par mois sur un dépôt privé — largement assez, et gratuit et illimité
si le dépôt est public. Comme il ne contient aucun secret, le rendre public ne vous
expose à rien.

---

## Étape 1 — La clé Gemini (indispensable)

C'est elle qui lit vos fichiers et rédige les réponses.

1. Allez sur **aistudio.google.com**, connectez-vous avec votre compte Google.
2. En haut à gauche, **Get API key** (ou « Obtenir une clé API »).
3. **Create API key** → choisissez ou créez un projet Google Cloud.
4. **Le point à ne pas rater : activez la facturation sur ce projet.** Le bouton
   « Set up billing » ou « Enable billing » vous emmène sur la console Google Cloud, où
   vous ajoutez une carte bancaire.

   Pourquoi c'est indispensable, et pas seulement une question de quota : sur l'offre
   gratuite, les conditions d'utilisation de l'API autorisent Google à lire vos documents,
   à les faire relire par des humains et à s'en servir pour améliorer ses produits, et
   votre corpus est plafonné à 1 Go. Dès que la facturation est activée, Google s'interdit
   contractuellement tout cela et le plafond passe à 10 Go.

5. Copiez la clé. Elle commence par `AIza…`.
6. **Fixez un plafond de dépense chez Google**, en plus de celui de l'app : console Google
   Cloud → **Billing** → **Budgets & alerts** → **Create budget** → 25 € par mois, avec
   alerte par courriel à 50 %, 90 % et 100 %. Ceinture et bretelles.

**Où la coller :** dans l'app, sur l'iPhone. Écran d'accueil → icône horloge (en haut à
gauche) → engrenage (en haut à droite) → champ **Gemini**. Nulle part ailleurs.

---

## Étape 2 — La clé Perplexity (facultative)

Elle ne sert qu'à la recherche Internet. Sans elle, l'app cherche dans vos fichiers et
le dit clairement.

1. Allez sur **perplexity.ai**, connectez-vous.
2. **Settings** → **API** (ou directement perplexity.ai/settings/api).
3. Section **API Keys** → **Generate**. Copiez la clé, elle commence par `pplx-…`.
4. Perplexity fonctionne avec des crédits prépayés : ajoutez-en 10 $ dans la section
   **Billing**. À 0,006 € la recherche, cela dure très longtemps.

**Où la coller :** même écran de réglages, champ **Perplexity**.

---

## Étape 3 — iCloud

L'app lit un dossier d'iCloud Drive que vous lui désignez.

1. Sur l'iPhone : **Réglages** → votre nom → **iCloud** → **iCloud+** → choisissez un
   forfait dont l'espace couvre vos documents.
2. **iCloud Drive** doit être activé.
3. « Optimiser le stockage » peut rester activé : l'app déclenche elle-même le
   téléchargement du fichier dont elle a besoin, au moment où elle en a besoin.

Rangez vos documents dans **un seul dossier** d'iCloud Drive, avec des sous-dossiers si
vous voulez. C'est ce dossier que vous désignerez à l'app.

---

## Étape 4 — Apple : l'identifiant de l'app

À faire une fois, sur le Mac ou dans un navigateur.

1. **developer.apple.com/account** → **Certificates, Identifiers & Profiles** →
   **Identifiers** → le **+** bleu.
2. **App IDs** → **App** → Continue.
3. **Description** : `L Atelier`. **Bundle ID** : cochez *Explicit* et saisissez
   exactement `com.bureau.latelier`.
4. Dans la liste des capacités, ne cochez rien : l'app n'en utilise aucune.
5. **Continue** → **Register**.

## Étape 5 — Apple : la fiche de l'app

1. **appstoreconnect.apple.com** → **Mes apps** → le **+** → **Nouvelle app**.
2. Plateforme **iOS**, nom `L'Atelier` (s'il est pris, mettez `L'Atelier — Lucas` : ce
   nom ne se voit que dans TestFlight), langue **Français**, *Bundle ID*
   `com.bureau.latelier`, **SKU** `latelier-1`.
3. **Créer**. Vous n'avez rien d'autre à remplir : une app qui reste en TestFlight n'a
   besoin ni de captures d'écran, ni de description, ni de passer en revue.

---

## Étape 6 — Le certificat de distribution (le fichier .p12)

C'est ce qui prouve à Apple que l'app vient bien de vous. À faire **sur le Mac**.

1. Ouvrez **Xcode** → menu **Xcode** → **Settings** → onglet **Accounts**.
2. Connectez votre compte Apple s'il ne l'est pas déjà, sélectionnez votre équipe, puis
   **Manage Certificates…**.
3. En bas à gauche, le **+** → **Apple Distribution**. Une ligne apparaît dans la liste.
4. Fermez Xcode. Ouvrez **Trousseaux d'accès** (Applications → Utilitaires).
5. À gauche : trousseau **Connexion**, catégorie **Mes certificats**.
6. Trouvez la ligne **Apple Distribution: votre nom (XXXXXXXXXX)**. Déroulez-la avec le
   petit triangle : elle doit contenir une **clé privée**. Si elle n'en contient pas,
   ce n'est pas la bonne ligne.
7. Clic droit sur le certificat → **Exporter « Apple Distribution… »** → format
   **Échange d'informations personnelles (.p12)** → enregistrez sous
   `~/Desktop/certificat.p12`.
8. Un mot de passe vous est demandé : **inventez-en un et notez-le**. Ce sera le secret
   `P12_PASSWORD`. (Le Mac vous demandera ensuite votre mot de passe de session : ce
   n'est pas le même, ne le confondez pas.)

Au passage, notez votre **Team ID** : c'est le code à dix caractères entre parenthèses,
visible aussi sur developer.apple.com/account, en haut à droite, sous « Membership ».

## Étape 7 — Le profil de provisionnement

1. **developer.apple.com/account** → **Profiles** → le **+**.
2. Sous **Distribution**, choisissez **App Store Connect** → Continue.
3. **App ID** : `com.bureau.latelier` → Continue.
4. Choisissez le certificat **Apple Distribution** créé à l'étape 6 → Continue.
5. **Provisioning Profile Name** : `Atelier App Store`. Retenez ce nom exactement.
6. **Generate** → **Download**. Vous obtenez un fichier `.mobileprovision`. Mettez-le
   sur le bureau.

## Étape 8 — La clé App Store Connect (le fichier .p8)

C'est elle qui permet à GitHub de déposer la version sur TestFlight sans votre mot de passe.

1. **appstoreconnect.apple.com** → **Utilisateurs et accès** → onglet **Intégrations**
   (ou « Clés »).
2. Section **App Store Connect API**, sous-onglet **Accès à l'équipe** → le **+**.
3. **Nom** : `GitHub`. **Accès** : **App Manager**. → **Générer**.
4. **Téléchargez le fichier `.p8` immédiatement** : Apple ne le propose qu'une fois.
5. Sur la même page, notez le **Key ID** (dix caractères) et l'**Issuer ID** (un long
   identifiant avec des tirets, en haut de la section).

---

## Étape 9 — Les huit secrets GitHub

Sur votre dépôt : **Settings** → **Secrets and variables** → **Actions** →
**New repository secret**. Un secret à la fois, le nom exactement comme écrit ici.

| Nom du secret | Ce qu'on y met | D'où il vient |
|---|---|---|
| `APPLE_TEAM_ID` | les dix caractères de votre équipe | étape 6 |
| `BUILD_CERTIFICATE_BASE64` | le `.p12` transformé en texte (voir ci-dessous) | étape 6 |
| `P12_PASSWORD` | le mot de passe inventé à l'export | étape 6 |
| `PROVISIONING_PROFILE_BASE64` | le `.mobileprovision` transformé en texte | étape 7 |
| `KEYCHAIN_PASSWORD` | n'importe quel mot de passe inventé, jamais réutilisé ailleurs | vous |
| `ASC_KEY_ID` | le Key ID | étape 8 |
| `ASC_ISSUER_ID` | l'Issuer ID | étape 8 |
| `ASC_PRIVATE_KEY` | **tout le contenu** du fichier `.p8` | étape 8 |

**Transformer un fichier en texte.** Deux fichiers ne peuvent pas être collés tels quels :
il faut les convertir. Ouvrez **Terminal** (Applications → Utilitaires) et tapez, une
ligne à la fois :

```bash
base64 -i ~/Desktop/certificat.p12 | pbcopy
```

Le contenu est maintenant dans le presse-papier : collez-le directement dans le secret
`BUILD_CERTIFICATE_BASE64`. Puis, pour le profil :

```bash
base64 -i ~/Desktop/*.mobileprovision | pbcopy
```

Collez dans `PROVISIONING_PROFILE_BASE64`. Enfin, pour la clé `.p8` :

```bash
cat ~/Downloads/AuthKey_*.p8 | pbcopy
```

Collez dans `ASC_PRIVATE_KEY` — avec les lignes `-----BEGIN PRIVATE KEY-----` et
`-----END PRIVATE KEY-----`, elles font partie de la clé.

**Une fois les huit secrets en place, effacez les fichiers du bureau et des
téléchargements.** GitHub les garde chiffrés et ne les réaffichera jamais ; vous n'avez
plus besoin des originaux, et un `.p12` qui traîne est un `.p12` qui fuit.

---

## Étape 10 — Construire et envoyer

1. Sur GitHub, onglet **Actions**.
2. À gauche, le flux **TestFlight** → bouton **Run workflow** → choisissez la branche
   `claude/new-session-rxzige` → **Run workflow**.
3. Cinq à dix minutes plus tard, la version est dans App Store Connect. Elle passe
   d'abord par un traitement automatique d'une dizaine de minutes.
4. **appstoreconnect.apple.com** → votre app → onglet **TestFlight** → dès que la version
   est « Prête à tester », ajoutez-vous comme testeur interne.
5. Installez **TestFlight** depuis l'App Store sur l'iPhone et l'iPad, ouvrez-le, et
   l'app est là.

Il existe aussi un second flux, **Compiler**, qui se déclenche tout seul à chaque envoi de
code et ne demande **aucun secret**. Il ne fait que compiler et affiche les erreurs.
C'est le plus rapide pour me faire remonter ce que dit le compilateur : ouvrez la
construction en échec, copiez l'encadré « Erreurs et avertissements », envoyez-le-moi.

Faites-le tourner **avant** toute l'installation Apple : s'il y a des erreurs de
compilation, autant les corriger avant de s'occuper des certificats.

---

## Si quelque chose bloque

**« No signing certificate found »** — Le `.p12` n'a pas été exporté avec sa clé privée.
Reprenez l'étape 6 en vérifiant que la ligne du trousseau se déroule bien sur une clé.

**« Provisioning profile doesn't match »** — Le nom du profil dans le secret et celui
d'Apple diffèrent, ou le profil ne vise pas `com.bureau.latelier`. Reprenez l'étape 7.

**« No account for team »** — `APPLE_TEAM_ID` est faux ou contient un espace.

**L'envoi échoue en disant que le build existe déjà** — Deux constructions ont porté le
même numéro. Relancez : le numéro suit le compteur des exécutions GitHub et s'incrémente
tout seul.

**Xcode 26 introuvable sur le runner** — Le journal de l'étape « Choisir la version
d'Xcode » liste ce qui est installé. Envoyez-le-moi, je fige la version.

Dans tous les cas : le journal complet est téléchargeable en bas de la page de la
construction, sous **Artifacts**. C'est le document le plus utile à me transmettre.
