# Dans l'ordre : construire l'app, puis la remplir

Deux moments distincts, et c'est ce qui compte.

**Partie A — construire et installer l'app.** Uniquement Apple et GitHub. Aucune clé
d'intelligence artificielle n'intervient ici, et il n'y a rien à payer d'autre que
l'abonnement développeur que vous avez déjà. Comptez une heure.

**Partie B — une fois l'app sur l'iPhone.** C'est là que vous créez vos clés Gemini et
Perplexity, que vous les collez dans les réglages de l'app, et que vous lui désignez
votre dossier iCloud. Comptez vingt minutes.

**La règle qui ne souffre aucune exception :** vos clés Gemini et Perplexity ne vont
**jamais** sur GitHub. Elles vivent dans le trousseau de l'iPhone. Les secrets de la
partie A ne servent qu'à Apple — signer l'app et la déposer sur TestFlight.

---

# PARTIE A — Construire et installer l'app

## Étape 0 — Vérifier que le code compile (gratuit, cinq minutes, aucun compte)

À faire en premier : inutile de s'occuper de certificats si le code ne compile pas.

1. Sur GitHub, onglet **Actions**.
2. Le flux **Compiler** s'est déclenché tout seul au dernier envoi de code. Ouvrez la
   dernière exécution.
3. **Si c'est vert :** passez à l'étape 1.
4. **Si c'est rouge :** ouvrez l'exécution, copiez l'encadré « Erreurs et avertissements »
   et envoyez-le-moi. Je corrige, et vous relancez. C'est la première fois que ce code voit
   un vrai compilateur : quelques allers-retours sont normaux.

## Étape 1 — Déclarer l'app chez Apple

1. **developer.apple.com/account** → **Certificates, Identifiers & Profiles** →
   **Identifiers** → le **+** bleu.
2. **App IDs** → **App** → Continue.
3. *Description* : `L Atelier`. *Bundle ID* : cochez **Explicit** et saisissez exactement
   `com.bureau.latelier`.
4. Ne cochez aucune capacité : l'app n'en utilise aucune.
5. **Continue** → **Register**.

**Notez votre Team ID** : les dix caractères visibles en haut à droite de la page du
compte, sous « Membership ». Vous en aurez besoin à l'étape 6.

## Étape 2 — Créer la fiche de l'app

1. **appstoreconnect.apple.com** → **Mes apps** → le **+** → **Nouvelle app**.
2. Plateforme **iOS** · nom `L'Atelier` (s'il est déjà pris, mettez `L'Atelier — Lucas` :
   ce nom ne se voit que dans TestFlight) · langue **Français** · *Bundle ID*
   `com.bureau.latelier` · **SKU** `latelier-1`.
3. **Créer**. Rien d'autre à remplir : une app qui reste en TestFlight n'a besoin ni de
   captures d'écran, ni de description, ni de passer en revue.

## Étape 3 — Exporter le certificat de distribution

C'est ce qui prouve à Apple que l'app vient de vous. **Sur le Mac.**

1. **Xcode** → menu **Xcode** → **Settings** → onglet **Accounts**.
2. Connectez votre compte Apple, sélectionnez votre équipe, puis **Manage Certificates…**.
3. En bas à gauche, le **+** → **Apple Distribution**. Une ligne apparaît.
4. Fermez Xcode. Ouvrez **Trousseaux d'accès** (Applications → Utilitaires).
5. À gauche : trousseau **Connexion**, catégorie **Mes certificats**.
6. Trouvez **Apple Distribution: votre nom (XXXXXXXXXX)** et **dépliez la ligne** avec le
   petit triangle : elle doit contenir une **clé privée**. Sans clé privée, ce n'est pas
   la bonne ligne, et la construction échouera plus tard.
7. Clic droit sur le certificat → **Exporter…** → format **Échange d'informations
   personnelles (.p12)** → enregistrez sur le bureau sous `certificat.p12`.
8. Un mot de passe vous est demandé : **inventez-en un et notez-le.** (Le Mac demandera
   ensuite votre mot de passe de session : ce n'est pas le même, ne les confondez pas.)

## Étape 4 — Créer le profil de provisionnement

1. **developer.apple.com/account** → **Profiles** → le **+**.
2. Sous **Distribution** : **App Store Connect** → Continue.
3. *App ID* : `com.bureau.latelier` → Continue.
4. Choisissez le certificat **Apple Distribution** de l'étape 3 → Continue.
5. *Provisioning Profile Name* : `Atelier App Store`.
6. **Generate** → **Download**. Mettez le `.mobileprovision` sur le bureau.

## Étape 5 — Créer la clé App Store Connect

C'est elle qui permet à GitHub de déposer la version sans votre mot de passe.

1. **appstoreconnect.apple.com** → **Utilisateurs et accès** → onglet **Intégrations**.
2. Section **App Store Connect API**, sous-onglet **Accès à l'équipe** → le **+**.
3. *Nom* : `GitHub` · *Accès* : **App Manager** → **Générer**.
4. **Téléchargez le fichier `.p8` tout de suite** : Apple ne le propose qu'une fois.
5. Sur la même page, notez le **Key ID** (dix caractères) et l'**Issuer ID** (long
   identifiant à tirets, en haut de la section).

## Étape 6 — Déposer les secrets sur GitHub

Vous avez maintenant les quatre choses nécessaires. Un script les demande dans l'ordre,
vérifie chacune, et les dépose. **Sur le Mac**, dans le Terminal :

```bash
cd ~/Desktop && git clone https://github.com/Th3-Dud3-Man/Atelier.git
cd Atelier && git checkout claude/new-session-rxzige
bash Tools/preparer-secrets.sh
```

Le script vous demande, une par une : le Team ID, le `.p12` et son mot de passe, le
`.mobileprovision`, puis le `.p8` avec son Key ID et son Issuer ID. Il vérifie au passage
que le mot de passe ouvre bien le certificat, que celui-ci contient sa clé privée, et que
le profil vise bien `com.bureau.latelier` — les trois causes d'échec les plus courantes,
détectées avant de perdre une construction.

Si l'outil `gh` est installé et connecté, il dépose les huit secrets lui-même. Sinon il
place chaque valeur dans le presse-papier, une à la fois, et vous accompagne pendant que
vous les collez dans **Settings → Secrets and variables → Actions → New repository
secret**.

<details>
<summary>Si vous préférez tout faire à la main</summary>

| Nom du secret | Ce qu'on y met |
|---|---|
| `APPLE_TEAM_ID` | les dix caractères de l'équipe (étape 1) |
| `BUILD_CERTIFICATE_BASE64` | `base64 -i ~/Desktop/certificat.p12 \| pbcopy` |
| `P12_PASSWORD` | le mot de passe inventé à l'étape 3 |
| `PROVISIONING_PROFILE_BASE64` | `base64 -i ~/Desktop/*.mobileprovision \| pbcopy` |
| `KEYCHAIN_PASSWORD` | n'importe quel mot de passe inventé, jamais réutilisé |
| `ASC_KEY_ID` | le Key ID (étape 5) |
| `ASC_ISSUER_ID` | l'Issuer ID (étape 5) |
| `ASC_PRIVATE_KEY` | `cat ~/Downloads/AuthKey_*.p8 \| pbcopy`, lignes BEGIN et END comprises |

</details>

**Une fois les huit secrets en place, effacez le `.p12`, le `.mobileprovision` et le `.p8`.**
GitHub les garde chiffrés et ne les réaffichera jamais ; un `.p12` qui traîne est un `.p12`
qui fuit.

## Étape 7 — Construire et envoyer

1. GitHub → onglet **Actions** → flux **TestFlight** → **Run workflow** → branche
   `claude/new-session-rxzige` → **Run workflow**.
2. Cinq à dix minutes. Puis App Store Connect traite la version, une dizaine de minutes
   de plus.
3. **appstoreconnect.apple.com** → votre app → onglet **TestFlight** → quand la version
   est « Prête à tester », ajoutez-vous comme **testeur interne**.

## Étape 8 — Installer sur l'iPhone et l'iPad

1. Installez **TestFlight** depuis l'App Store, sur les deux appareils.
2. Ouvrez-le avec le même compte Apple : **L'Atelier** y est. Installez.
3. Ouvrez l'app. Elle vous dira qu'il lui manque une clé — c'est normal, c'est la partie B.

**L'app est construite et installée. La partie A est terminée, et vous n'y reviendrez que
pour installer une nouvelle version : un clic sur « Run workflow », rien d'autre.**

---

# PARTIE B — Ce que vous mettez dans l'app

## Étape 9 — Préparer le dossier iCloud

1. Sur l'iPhone : **Réglages** → votre nom → **iCloud** → **iCloud Drive** activé.
2. Rangez vos documents dans **un seul dossier** d'iCloud Drive, sous-dossiers permis.
   C'est ce dossier que vous désignerez à l'app.
3. « Optimiser le stockage » peut rester activé : l'app déclenche elle-même le
   téléchargement du fichier dont elle a besoin, quand elle en a besoin.

## Étape 10 — Créer la clé Gemini

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

## Étape 11 — Créer la clé Perplexity (facultative)

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

## Étape 12 — Coller les deux clés dans l'app

1. Ouvrez **L'Atelier** sur l'iPhone.
2. Icône **horloge** (en haut à gauche) → **engrenage** (en haut à droite).
3. Collez la clé **Gemini**, puis la clé **Perplexity**.
4. **Enregistrer et tester**. L'app vous dit franchement si chaque clé fonctionne.

> Le test Perplexity effectue une vraie recherche, facturée un demi-centime. C'est le seul
> moyen honnête de vérifier qu'une clé marche.

5. Fermez complètement l'app, rouvrez-la, revenez aux réglages : **les clés doivent
   toujours être là**. Si elles ont disparu, dites-le-moi.

## Étape 13 — Désigner votre dossier

1. Retour à l'accueil → icône **dossier** (en haut à droite) → **Ajouter un dossier**.
2. Le sélecteur d'iCloud Drive s'ouvre : choisissez **un dossier**, pas un fichier.
3. L'indexation démarre seule, en arrière-plan. Vous pouvez chercher pendant ce temps.

Sur un corpus de plus de 3 Go, l'app remplit son budget avec vos documents les plus
récents, laisse le reste au catalogue, et ira y chercher à la demande. C'est prévu, et
`CHECKLIST_APPAREIL.md` contient le test qui le vérifie.

## Étape 14 — Votre première question

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
| Perplexity | perplexity.ai | crédits prépayés, ~0,006 € la recherche | **à activer** (étape 11) |
| GitHub Actions | github.com | gratuit | — |

Le plafond intégré à l'app est réglé à environ 23 € TTC par mois et couvre Gemini et
Perplexity ensemble. Avec iCloud, vous restez sous les 30 €, et l'app s'arrête d'elle-même
avant de les dépasser.

Sur GitHub, les minutes macOS comptent dix fois : les 2 000 minutes gratuites d'un dépôt
privé en valent 200, soit une vingtaine de constructions par mois. Le dépôt ne contenant
aucun secret, le rendre public rend tout illimité.

---

# Si quelque chose bloque

**« No signing certificate found »** — Le `.p12` a été exporté sans sa clé privée.
Reprenez l'étape 3 en dépliant bien la ligne du trousseau. (Le script de l'étape 6 détecte
ce cas avant la construction.)

**« Provisioning profile doesn't match »** — Le profil ne vise pas `com.bureau.latelier`,
ou son nom diffère. Reprenez l'étape 4.

**« No account for team »** — `APPLE_TEAM_ID` est faux ou contient un espace.

**L'envoi dit que le build existe déjà** — Deux constructions ont porté le même numéro.
Relancez : le numéro suit le compteur GitHub et s'incrémente seul.

**Xcode 26 introuvable sur le runner** — Le journal de l'étape « Choisir la version
d'Xcode » liste ce qui est installé. Envoyez-le-moi, je fige la version.

Dans tous les cas, le journal complet se télécharge en bas de la page de la construction,
sous **Artifacts**. C'est le document le plus utile à me transmettre.
