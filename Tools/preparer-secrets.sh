#!/bin/bash
# Prépare les huit secrets GitHub nécessaires à la construction de L'Atelier.
#
# À lancer SUR LE MAC, une seule fois, quand vous avez sous la main les quatre choses
# obtenues chez Apple : le certificat .p12, le profil .mobileprovision, la clé .p8,
# et votre Team ID. Le script vous les demande une par une, dans l'ordre, vérifie
# chacune, puis les dépose sur GitHub — ou vous les met dans le presse-papier si
# l'outil `gh` n'est pas installé.
#
# Il n'écrit aucun secret sur le disque et n'envoie rien ailleurs qu'à GitHub.

set -uo pipefail

BUNDLE_ID="com.bureau.latelier"
BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; OFF=$'\033[0m'

titre()   { printf '\n%s── %s ──%s\n' "$BOLD" "$1" "$OFF"; }
info()    { printf '%s%s%s\n' "$DIM" "$1" "$OFF"; }
bon()     { printf '%s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
souci()   { printf '%s✗%s %s\n' "$RED" "$OFF" "$1"; }
abandon() { souci "$1"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || abandon "Ce script est prévu pour votre Mac."

# Un chemin déposé par glisser-déposer arrive parfois entre guillemets et avec un espace final.
nettoyer_chemin() {
    local p="$1"
    p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"
    p="${p%"${p##*[![:space:]]}"}"
    printf '%s' "${p/#\~/$HOME}"
}

demander_fichier() {
    local invite="$1" motif="$2" chemin
    while true; do
        printf '\n%s\n' "$invite" > /dev/tty
        info "Astuce : faites glisser le fichier depuis le Finder jusqu'ici, puis Entrée." > /dev/tty
        read -r -p "> " chemin < /dev/tty
        chemin="$(nettoyer_chemin "$chemin")"
        if [[ ! -f "$chemin" ]]; then
            souci "Fichier introuvable." > /dev/tty; continue
        fi
        if [[ -n "$motif" && "$chemin" != *"$motif" ]]; then
            souci "Ce n'est pas un fichier $motif." > /dev/tty; continue
        fi
        printf '%s' "$chemin"; return
    done
}

demander_texte() {
    local invite="$1" motif="$2" valeur
    while true; do
        printf '\n%s\n' "$invite" > /dev/tty
        read -r -p "> " valeur < /dev/tty
        valeur="$(printf '%s' "$valeur" | tr -d '[:space:]')"
        if [[ -z "$valeur" ]]; then souci "Rien saisi." > /dev/tty; continue; fi
        if [[ -n "$motif" && ! "$valeur" =~ $motif ]]; then
            souci "Ce n'est pas au bon format." > /dev/tty; continue
        fi
        printf '%s' "$valeur"; return
    done
}

cat <<'TXT'

  L'Atelier — préparation des secrets de construction
  ===================================================

  Ce script ne touche PAS à vos clés Gemini et Perplexity : celles-là se saisissent
  dans l'app, sur l'iPhone, et n'ont rien à faire sur GitHub.

  Ayez sous la main, obtenus chez Apple :
    1. votre Team ID (dix caractères)
    2. le certificat exporté         certificat.p12   + son mot de passe
    3. le profil téléchargé          *.mobileprovision
    4. la clé App Store Connect      AuthKey_*.p8     + son Key ID et son Issuer ID

  Si l'un des quatre vous manque, arrêtez ici (Ctrl-C) et reprenez ACHATS_ET_CLES.md.

TXT
read -r -p "Tout est là ? Entrée pour continuer, Ctrl-C pour arrêter. " _ < /dev/tty

# ── 1. Team ID ───────────────────────────────────────────────────────────────
titre "1 sur 4 — votre Team ID"
info "Visible sur developer.apple.com/account, en haut à droite, sous « Membership »."
TEAM_ID="$(demander_texte "Team ID (dix lettres et chiffres) :" '^[A-Z0-9]{10}$')"
bon "Team ID : $TEAM_ID"

# ── 2. Certificat ────────────────────────────────────────────────────────────
titre "2 sur 4 — le certificat de distribution"
P12="$(demander_fichier "Où se trouve le fichier .p12 ?" ".p12")"
P12_PASSWORD="$(demander_texte "Le mot de passe que vous avez inventé en l'exportant :" '')"

if openssl pkcs12 -in "$P12" -nokeys -passin "pass:$P12_PASSWORD" > /dev/null 2>&1; then
    bon "Le mot de passe est le bon."
else
    abandon "Ce mot de passe n'ouvre pas le certificat. Reprenez l'export (étape 3 du guide)."
fi
if openssl pkcs12 -in "$P12" -nocerts -nodes -passin "pass:$P12_PASSWORD" 2>/dev/null \
   | grep -q "PRIVATE KEY"; then
    bon "Le certificat contient bien sa clé privée."
else
    abandon "Ce .p12 ne contient pas de clé privée : la construction échouerait sur « No signing certificate found ». Réexportez en dépliant bien la ligne du trousseau."
fi

# ── 3. Profil ────────────────────────────────────────────────────────────────
titre "3 sur 4 — le profil de provisionnement"
PROFIL="$(demander_fichier "Où se trouve le fichier .mobileprovision ?" ".mobileprovision")"
PLIST="$(security cms -D -i "$PROFIL" 2>/dev/null)" || abandon "Ce profil est illisible."
PROFIL_NOM="$(printf '%s' "$PLIST" | plutil -extract Name raw - 2>/dev/null)"
PROFIL_APPID="$(printf '%s' "$PLIST" | plutil -extract Entitlements.application-identifier raw - 2>/dev/null)"

if [[ "$PROFIL_APPID" == "$TEAM_ID.$BUNDLE_ID" ]]; then
    bon "Profil « $PROFIL_NOM », pour $BUNDLE_ID."
else
    souci "Ce profil vise « $PROFIL_APPID » et non « $TEAM_ID.$BUNDLE_ID »."
    abandon "Refaites le profil pour l'identifiant $BUNDLE_ID (étape 4 du guide)."
fi

# ── 4. Clé App Store Connect ─────────────────────────────────────────────────
titre "4 sur 4 — la clé App Store Connect"
P8="$(demander_fichier "Où se trouve le fichier AuthKey_….p8 ?" ".p8")"
DEDUIT="$(basename "$P8" | sed -n 's/^AuthKey_\(.*\)\.p8$/\1/p')"
if [[ -n "$DEDUIT" ]]; then
    info "Key ID lu dans le nom du fichier : $DEDUIT"
    read -r -p "Est-ce bien lui ? [O/n] " REPONSE < /dev/tty
    [[ "$REPONSE" =~ ^[Nn] ]] && DEDUIT=""
fi
if [[ -n "$DEDUIT" ]]; then ASC_KEY_ID="$DEDUIT"
else ASC_KEY_ID="$(demander_texte "Key ID (dix caractères) :" '^[A-Z0-9]{10}$')"; fi
ASC_ISSUER_ID="$(demander_texte "Issuer ID (long identifiant avec des tirets) :" '^[0-9a-fA-F-]{36}$')"
grep -q "PRIVATE KEY" "$P8" || abandon "Ce fichier ne ressemble pas à une clé .p8."
bon "Clé $ASC_KEY_ID prête."

# ── Fabrication ──────────────────────────────────────────────────────────────
titre "Fabrication des huit secrets"
KEYCHAIN_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
CERT_B64="$(base64 -i "$P12")"
PROFIL_B64="$(base64 -i "$PROFIL")"
P8_CONTENU="$(cat "$P8")"
bon "Les huit valeurs sont prêtes."

NOMS=(APPLE_TEAM_ID BUILD_CERTIFICATE_BASE64 P12_PASSWORD PROVISIONING_PROFILE_BASE64
      KEYCHAIN_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY)
VALEURS=("$TEAM_ID" "$CERT_B64" "$P12_PASSWORD" "$PROFIL_B64"
         "$KEYCHAIN_PASSWORD" "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$P8_CONTENU")

if command -v gh > /dev/null 2>&1 && gh auth status > /dev/null 2>&1; then
    titre "Dépôt automatique sur GitHub"
    DEPOT="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
    if [[ -z "$DEPOT" ]]; then
        DEPOT="$(demander_texte "Nom du dépôt (par exemple Th3-Dud3-Man/Atelier) :" '^[^/]+/[^/]+$')"
    fi
    info "Dépôt visé : $DEPOT"
    read -r -p "Déposer les huit secrets maintenant ? [O/n] " REPONSE < /dev/tty
    if [[ ! "$REPONSE" =~ ^[Nn] ]]; then
        for i in "${!NOMS[@]}"; do
            if printf '%s' "${VALEURS[$i]}" | gh secret set "${NOMS[$i]}" --repo "$DEPOT" > /dev/null 2>&1; then
                bon "${NOMS[$i]}"
            else
                souci "${NOMS[$i]} — échec ; déposez-le à la main."
            fi
        done
        titre "Terminé"
        echo "Allez sur GitHub, onglet Actions, flux « TestFlight », bouton « Run workflow »."
        echo
        echo "Puis effacez le .p12, le .mobileprovision et le .p8 : ils ne servent plus."
        exit 0
    fi
fi

# ── Sans gh : un secret à la fois, dans le presse-papier ─────────────────────
titre "Dépôt à la main, un secret à la fois"
cat <<'TXT'
L'outil `gh` n'est pas installé (ou pas connecté). Chaque valeur va être placée
dans votre presse-papier, l'une après l'autre.

Ouvrez dès maintenant, dans le navigateur :
  votre dépôt → Settings → Secrets and variables → Actions → New repository secret

Pour chacune : collez le nom, collez la valeur (Cmd-V), enregistrez, revenez ici.
TXT
for i in "${!NOMS[@]}"; do
    printf '\n%s[%d/8] %s%s\n' "$BOLD" "$((i + 1))" "${NOMS[$i]}" "$OFF"
    printf '%s' "${VALEURS[$i]}" | pbcopy
    info "La valeur est dans le presse-papier."
    read -r -p "Collé et enregistré ? Entrée pour la suivante. " _ < /dev/tty
done
printf '%s' "rien" | pbcopy

titre "Terminé"
echo "Allez sur GitHub, onglet Actions, flux « TestFlight », bouton « Run workflow »."
echo
echo "Puis effacez le .p12, le .mobileprovision et le .p8 : ils ne servent plus."
