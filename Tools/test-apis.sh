#!/usr/bin/env bash
# Vérifie les appels réels aux API, avec vos clés, et affiche les réponses brutes.
#
# Pourquoi ce script existe : l'application a été écrite d'après la documentation officielle,
# mais six points ne peuvent être tranchés que par un appel réel (voir NOTES_API.md §5).
# Lancez-le une fois, collez-moi la sortie, et je fige les derniers formats.
#
#   export GEMINI_API_KEY="..."
#   export PERPLEXITY_API_KEY="..."      # facultatif
#   Tools/test-apis.sh
#
# Coût total : quelques centimes. Chaque étape payante est annoncée et demande confirmation.

set -uo pipefail

GEMINI="${GEMINI_API_KEY:-}"
PPLX="${PERPLEXITY_API_KEY:-}"
MAIN_MODEL="${ATELIER_MAIN_MODEL:-gemini-3.1-flash-lite}"
LIGHT_MODEL="${ATELIER_LIGHT_MODEL:-gemini-2.5-flash-lite}"
BASE="https://generativelanguage.googleapis.com"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

have_jq() { command -v jq >/dev/null 2>&1; }
pretty() { if have_jq; then jq . 2>/dev/null || cat; else cat; fi; }
title() { printf '\n\033[1m── %s ──\033[0m\n' "$1"; }
ask() {
  printf '%s [o/N] ' "$1"
  read -r answer </dev/tty
  [ "$answer" = "o" ] || [ "$answer" = "O" ]
}

if [ -z "$GEMINI" ]; then
  echo "GEMINI_API_KEY n'est pas défini. Exportez-le puis relancez." >&2
  exit 1
fi

# ── 1. L'appel de base fonctionne-t-il ? ─────────────────────────────
title "1. Gemini — appel simple ($LIGHT_MODEL)"
curl -sS -X POST "$BASE/v1beta/models/$LIGHT_MODEL:generateContent" \
  -H "x-goog-api-key: $GEMINI" -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Réponds uniquement : ok"}]}]}' | pretty

# ── 2. responseSchema est marqué « deprecated » : est-il encore accepté ? ──
title "2. Gemini — JSON structuré avec responseSchema (NOTES_API §3.2)"
echo "Si cet appel renvoie une erreur 400, l'app retire le schéma et refait l'appel — c'est prévu."
curl -sS -X POST "$BASE/v1beta/models/$LIGHT_MODEL:generateContent" \
  -H "x-goog-api-key: $GEMINI" -H "Content-Type: application/json" \
  -d '{
    "contents":[{"role":"user","parts":[{"text":"Analyse : Que dit Lacan du stade du miroir ?"}]}],
    "generationConfig":{
      "responseMimeType":"application/json",
      "responseSchema":{
        "type":"OBJECT",
        "properties":{
          "intent":{"type":"STRING"},
          "preferredSource":{"type":"STRING","enum":["files","internet","both"]},
          "webQueries":{"type":"ARRAY","items":{"type":"STRING"}}
        },
        "required":["intent","preferredSource","webQueries"]
      }
    }
  }' | pretty

# ── 3. Quelle est la vraie forme des fragments SSE ? ─────────────────
title "3. Gemini — flux SSE (NOTES_API §3.3 : la documentation se contredit)"
echo "Les trois premiers fragments bruts, tels qu'ils arrivent :"
curl -sS -N -X POST "$BASE/v1beta/models/$LIGHT_MODEL:streamGenerateContent?alt=sse" \
  -H "x-goog-api-key: $GEMINI" -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Compte de un à dix, en français."}]}]}' \
  | head -8

# ── 4. Le circuit complet File Search, avec un vrai PDF ──────────────
title "4. Gemini — File Search de bout en bout"
echo "Cette étape crée un store d'essai, y envoie un petit fichier, l'interroge, puis efface tout."
if ask "La lancer ?"; then
  STORE=$(curl -sS -X POST "$BASE/v1beta/fileSearchStores" \
    -H "x-goog-api-key: $GEMINI" -H "Content-Type: application/json" \
    -d '{"displayName":"atelier-essai"}')
  echo "$STORE" | pretty
  STORE_NAME=$(echo "$STORE" | { have_jq && jq -r '.name' || sed -n 's/.*"name": *"\([^"]*\)".*/\1/p'; })

  if [ -n "${STORE_NAME:-}" ] && [ "$STORE_NAME" != "null" ]; then
    # Un fichier dont on connaît le contenu, pour vérifier que la citation est exacte.
    cat > "$WORK/essai.txt" <<'TXT'
Note d'essai pour L'Atelier.
Le rêve rapporté par Freud, dit « de l'enfant qui brûle », contient cette adresse :
« Père, ne vois-tu pas que je brûle ? »
Lacan le commente au chapitre V du Séminaire XI.
TXT
    BYTES=$(wc -c < "$WORK/essai.txt")

    echo; echo "Étape 1 — ouverture de l'envoi (l'URL est dans l'en-tête x-goog-upload-url) :"
    curl -sS -D "$WORK/headers.txt" -o /dev/null -X POST \
      "$BASE/upload/v1beta/$STORE_NAME:uploadToFileSearchStore" \
      -H "x-goog-api-key: $GEMINI" \
      -H "X-Goog-Upload-Protocol: resumable" \
      -H "X-Goog-Upload-Command: start" \
      -H "X-Goog-Upload-Header-Content-Length: $BYTES" \
      -H "X-Goog-Upload-Header-Content-Type: text/plain" \
      -H "Content-Type: application/json" \
      -d '{"displayName":"essai.txt","mimeType":"text/plain","customMetadata":[{"key":"path","stringValue":"essai.txt"}]}'
    grep -i "x-goog-upload" "$WORK/headers.txt" || echo "(aucun en-tête d'envoi reçu)"
    UPLOAD_URL=$(grep -i "x-goog-upload-url:" "$WORK/headers.txt" | cut -d' ' -f2 | tr -d '\r')

    if [ -n "${UPLOAD_URL:-}" ]; then
      echo; echo "Étape 2 — envoi des octets :"
      curl -sS -X POST "$UPLOAD_URL" \
        -H "X-Goog-Upload-Offset: 0" \
        -H "X-Goog-Upload-Command: upload, finalize" \
        --data-binary "@$WORK/essai.txt" | pretty

      echo; echo "Attente de l'indexation (15 s)…"; sleep 15

      echo; echo "Étape 3 — interrogation. À vérifier : la présence de retrievedContext,"
      echo "et de pageNumber (absent pour un .txt, attendu pour un PDF) :"
      curl -sS -X POST "$BASE/v1beta/models/$MAIN_MODEL:generateContent" \
        -H "x-goog-api-key: $GEMINI" -H "Content-Type: application/json" \
        -d "{
          \"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"Que dit ce document du rêve de l'enfant qui brûle ?\"}]}],
          \"tools\":[{\"fileSearch\":{\"fileSearchStoreNames\":[\"$STORE_NAME\"],\"topK\":5}}]
        }" | pretty
    fi

    echo; echo "Nettoyage du store d'essai :"
    curl -sS -X DELETE "$BASE/v1beta/$STORE_NAME?force=true" -H "x-goog-api-key: $GEMINI" | pretty
  fi
fi

echo
echo "Pour vérifier pageNumber sur un vrai PDF, relancez l'étape 4 en remplaçant essai.txt"
echo "par un de vos PDF (et text/plain par application/pdf)."

# ── 5. Perplexity ────────────────────────────────────────────────────
if [ -n "$PPLX" ]; then
  title "5. Perplexity — Search API (0,005 \$ par appel, quel que soit le nombre de requêtes)"
  curl -sS -X POST "https://api.perplexity.ai/search" \
    -H "Authorization: Bearer $PPLX" -H "Content-Type: application/json" \
    -d '{"query":["psychanalyse lacanienne publications 2026","École de la Cause freudienne actualité"],"max_results":3}' \
    | pretty

  title "6. Perplexity — Agent API (niveau approfondi)"
  echo "Cet appel coûte de l'ordre de 0,01 à 0,05 \$."
  if ask "Le lancer ?"; then
    curl -sS -X POST "https://api.perplexity.ai/v1/agent" \
      -H "Authorization: Bearer $PPLX" -H "Content-Type: application/json" \
      -d '{"preset":"low","input":"Quelles publications récentes sur la passe dans l'\''École de la Cause freudienne ?","language_preference":"fr"}' \
      | pretty
  fi
else
  title "5. Perplexity — ignoré"
  echo "PERPLEXITY_API_KEY n'est pas défini : la recherche Internet n'a pas été testée."
fi

echo
echo "Terminé. Collez-moi cette sortie : elle fige les six points en attente de NOTES_API.md §5."
