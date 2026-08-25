# NOTES_API — formats réels des API utilisées

Ce fichier consigne ce qui a été **lu dans la documentation officielle**, avec la date de lecture, et ce qui reste **à confirmer par un appel réel**. Rien ici n'est inventé : chaque champ vient d'une page citée en fin de section.

Convention : ✅ confirmé dans la doc · 🔬 vérifié empiriquement depuis ce poste · ⚠️ non confirmé, à valider avec une vraie clé (`Tools/test-apis.sh`).

---

## 1. Gemini — décisions structurantes

**Lu le 25/08/2026.**

### 1.1 Quelle surface d'API

Google a publié une nouvelle API « Interactions » (`POST /v1beta/interactions`), désormais recommandée pour les nouveaux développements. **Nous ne l'utilisons pas**, pour trois raisons documentées :

1. La page File Search elle-même avertit : « This version of the page covers the new Interactions API, which is currently in Beta. For stable production deployments, we recommend you continue to use the `generateContent` API. » ✅
2. Les citations File Search de `generateContent` exposent `pageNumber` par passage retrouvé — exactement ce dont l'écran de résultats a besoin. ✅
3. `generateContent` est stable et son format de réponse est figé.

→ **Toute l'app appelle `models/{model}:generateContent`** (et `:streamGenerateContent?alt=sse` pour le flux).

### 1.2 Quels modèles

La documentation liste **exactement 7 modèles compatibles avec l'outil File Search** : Gemini 3.7 Flash, 3.6 Flash, 3.5 Flash-Lite, 3.5 Flash, 3.1 Pro Preview, 3.1 Flash-Lite, 3 Flash Preview. ✅

Conséquence importante pour le budget : **`gemini-2.5-flash-lite`, le modèle le moins cher, ne sait pas faire File Search.** Le moins cher qui le sache est `gemini-3.1-flash-lite`.

| Rôle dans l'app | Modèle | Prix (entrée / sortie, par million de tokens) |
|---|---|---|
| Recherche fichiers + synthèse | `gemini-3.1-flash-lite` | 0,25 $ / 1,50 $ ✅ |
| Analyse, doublons, transcription | `gemini-2.5-flash-lite` | 0,10 $ / 0,40 $ — audio en entrée 0,30 $ ✅ |

Autres tarifs relevés (page « Last updated 2026-08-13 UTC ») :
- `gemini-3.5-flash-lite` : 0,30 $ / 2,50 $
- `gemini-3.7-flash` : 0,75 $ / 3,75 $ **en promotion jusqu'au 31/12/2026**, puis 1,50 $ / 7,50 $
- Embeddings `gemini-embedding-001` : 0,15 $ par million de tokens en entrée

**Modèles arrêtés, à ne jamais utiliser** : `gemini-2.0-flash`, `gemini-2.0-flash-lite`, `gemini-3-pro-preview`. ✅
**Alias `gemini-flash-latest`** : existe mais change de cible avec un préavis de deux semaines — non utilisé ici. ✅

### 1.3 Comment File Search est facturé

- Indexation : facturée au tarif du modèle d'embedding (0,15 $/M tokens). ✅
- **Stockage : gratuit. Embeddings de requête : gratuits.** ✅
- Les passages retrouvés comptent comme **tokens d'entrée** de l'appel `generateContent`. ✅

### 1.4 Authentification et CORS

- En-tête : `x-goog-api-key: <clé>` (le paramètre `?key=` fonctionne encore sur les endpoints hérités). ✅
- 🔬 Préflights testés depuis ce poste le 25/08/2026 : `generateContent`, `fileSearchStores` et les endpoints `/upload/` renvoient tous 200 avec `access-control-allow-origin` reflété. Sans objet pour l'app native, conservé pour mémoire.
- Politique officielle : « Do not hardcode API keys directly in web or mobile apps. » → dans l'app, la clé est saisie par l'utilisateur et rangée dans le **Keychain**, jamais dans le code ni dans le dépôt.

---

## 2. Gemini — File Search (RAG géré)

**Lu le 25/08/2026.** Base : `https://generativelanguage.googleapis.com`

### 2.1 Créer un store

```
POST /v1beta/fileSearchStores
x-goog-api-key: $KEY
Content-Type: application/json

{ "displayName": "latelier", "embeddingModel": "models/gemini-embedding-001" }
```

Réponse (`FileSearchStore`) : ✅
```json
{ "name": "fileSearchStores/latelier-123a456b789c",
  "displayName": "latelier",
  "createTime": "...", "updateTime": "...",
  "activeDocumentsCount": "0", "pendingDocumentsCount": "0", "failedDocumentsCount": "0",
  "sizeBytes": "0", "embeddingModel": "models/gemini-embedding-001" }
```

`name` est **en lecture seule** : dérivé de `displayName` + suffixe aléatoire de 12 caractères. Il faut conserver la chaîne complète `fileSearchStores/…`. ✅
`embeddingModel` accepte `models/gemini-embedding-001` (texte) ou `models/gemini-embedding-2` (multimodal, images PNG/JPEG). Omis → modèle par défaut. ✅

### 2.2 Envoyer un fichier (upload reprenable, deux étapes)

**Étape 1 — ouvrir l'envoi.** ✅
```
POST /upload/v1beta/{storeName}:uploadToFileSearchStore
x-goog-api-key: $KEY
X-Goog-Upload-Protocol: resumable
X-Goog-Upload-Command: start
X-Goog-Upload-Header-Content-Length: <octets>
X-Goog-Upload-Header-Content-Type: <mime>
Content-Type: application/json

{ "displayName": "monfichier.pdf",
  "mimeType": "application/pdf",
  "customMetadata": [ { "key": "path", "stringValue": "Recherche/Lacan/Seminaire-XI.pdf" } ],
  "chunkingConfig": { "whiteSpaceConfig": { "maxTokensPerChunk": 200, "maxOverlapTokens": 20 } } }
```

La réponse **ne contient rien d'utile dans le corps** : l'URL d'envoi est dans l'en-tête `x-goog-upload-url`. ✅

**Étape 2 — envoyer les octets.** ✅
```
POST <x-goog-upload-url>
Content-Length: <octets>
X-Goog-Upload-Offset: 0
X-Goog-Upload-Command: upload, finalize

<octets bruts>
```

Réponse : une opération longue (`{ name, metadata, done, error | response }`). Nom de la forme `fileSearchStores/{store}/upload/operations/{op}`. ✅

**Étape 3 — attendre la fin.** `GET /v1beta/{operation.name}` en boucle (les exemples officiels attendent 5 s entre deux appels) jusqu'à `done: true`, puis regarder `error` ou `response`. ✅

> ⚠️ **Bug dans la documentation officielle** : les exemples curl construisent l'URL en concaténant `fileSearchStores/` avec un nom qui contient déjà ce préfixe, ce qui donne `fileSearchStores/fileSearchStores/xxx`. Le gabarit `{fileSearchStoreName=fileSearchStores/*}` signifie que le **nom complet** remplace le segment. Notre code interpole le nom complet, sans re-préfixer.

`customMetadata` : au maximum **20 entrées par document**, chaque entrée ayant exactement un `stringValue`, `stringListValue` ou `numericValue`. ✅ On y range le chemin relatif du fichier, ce qui permet de le retrouver et de l'ouvrir depuis une citation.

### 2.3 Lister, supprimer

- `GET /v1beta/{store}/documents?pageSize=20` — **maximum 20 par page**, boucler sur `nextPageToken`. ✅
  Document : `{ name, displayName, customMetadata[], createTime, updateTime, state, sizeBytes, mimeType }`
  `state` ∈ `STATE_PENDING` | `STATE_ACTIVE` | `STATE_FAILED`. ✅
- `DELETE /v1beta/{documentName}?force=true` — `force=true` est de fait obligatoire (un document indexé contient toujours des chunks). ✅
- `DELETE /v1beta/{store}?force=true` pour tout effacer. ✅

### 2.4 Interroger le corpus et récupérer les citations

```
POST /v1beta/models/gemini-3.1-flash-lite:generateContent
{
  "contents": [ { "role": "user", "parts": [ { "text": "…" } ] } ],
  "tools": [ { "fileSearch": {
      "fileSearchStoreNames": [ "fileSearchStores/latelier-123a456b789c" ],
      "topK": 12
  } } ]
}
```

Champs de l'outil : `fileSearchStoreNames` (requis), `metadataFilter` (syntaxe AIP-160, ex. `author = "Robert Graves"`), `topK`. ✅

**Les citations sont ici** — `candidates[0].groundingMetadata` : ✅
```
groundingMetadata.groundingChunks[].retrievedContext = {
  title,          // nom affiché du document
  text,           // le passage lui-même
  pageNumber,     // ← numéro de page, entier, quand il existe
  uri,
  customMetadata[],
  fileSearchStore,
  mediaId
}
groundingMetadata.groundingSupports[] = {
  groundingChunkIndices[],   // indices dans groundingChunks
  confidenceScores[],
  segment: { partIndex, startIndex, endIndex, text }   // décalages en OCTETS
}
```

Il n'existe **pas** de champ `page_span` : le numéro de page est `pageNumber`, et c'est tout. ✅
En streaming, `groundingChunks` ne contient que les passages pas encore envoyés, et les indices portent sur l'accumulation de toutes les réponses — il faut cumuler côté client. ✅

### 2.5 Limites

| Limite | Valeur |
|---|---|
| Taille maximale d'un fichier | **100 Mo** ✅ |
| Taille totale des stores (palier 1, compte facturé) | 10 Go ✅ |
| Empreinte réelle dans le quota | **≈ 3 × la taille des données brutes** ✅ |
| Taille conseillée d'un store | < 20 Go pour garder la latence basse ✅ |
| Pagination | 20 éléments par page maximum ✅ |
| Audio et vidéo | **non pris en charge par File Search** ✅ |
| Durée de vie des embeddings | aucune ; ils persistent jusqu'à suppression ✅ |

---

## 3. Gemini — génération, JSON structuré, flux

### 3.1 Réponse standard ✅
```json
{ "candidates": [ { "content": { "parts": [ { "text": "…" } ], "role": "model" },
                    "finishReason": "STOP", "groundingMetadata": { … } } ],
  "usageMetadata": { "promptTokenCount": 4, "candidatesTokenCount": 12, "totalTokenCount": 16 },
  "modelVersion": "…", "responseId": "…" }
```

Champs d'usage utiles au calcul du coût : `promptTokenCount`, `candidatesTokenCount`, `thoughtsTokenCount`, `toolUsePromptTokenCount`, `cachedContentTokenCount`. ✅
`totalTokenCount` = prompt + pensées + réponse : **ne pas y rajouter `thoughtsTokenCount`**, ce serait compter deux fois. ✅
Les tokens de « pensée » sont facturés au tarif de **sortie**. ✅

### 3.2 JSON structuré

`generationConfig.responseMimeType: "application/json"` + `responseSchema`. ⚠️ **Le champ `responseSchema` est marqué « deprecated » dans la référence REST**, sans remplaçant documenté pour `generateContent` (un objet `responseFormat` apparaît dans la représentation JSON mais n'est défini nulle part).

Conduite retenue dans l'app : on envoie `responseMimeType` + `responseSchema`, et **si Google répond 400, on refait l'appel sans le schéma** — le prompt décrit le format attendu et l'analyseur JSON est tolérant. Le pire cas dégrade la garantie de forme, pas la fonction.

Dialecte du schéma : OpenAPI, **types en MAJUSCULES** (`OBJECT`, `STRING`, `ARRAY`, `INTEGER`, `BOOLEAN`). ✅ Ne pas copier un schéma JSON Schema classique tel quel.

### 3.3 Flux

`POST /v1beta/models/{model}:streamGenerateContent?alt=sse`, corps identique à `generateContent`. ✅

⚠️ **La documentation se contredit** sur la forme des fragments : la référence REST dit « un flux de `GenerateContentResponse` » (donc des objets `candidates`), tandis que la page de migration montre des événements `content.start` / `content.delta` / `content.stop` pour le même endpoint. Le code accepte **les deux formes** et ignore ce qu'il ne reconnaît pas. À trancher au premier appel réel.

### 3.4 Réflexion (« thinking »)

`generationConfig.thinkingConfig` a trois champs : `includeThoughts`, `thinkingBudget` (entier), `thinkingLevel` (`MINIMAL` | `LOW` | `MEDIUM` | `HIGH`). `thinkingLevel` est recommandé pour Gemini 3 et **provoque une erreur sur les modèles antérieurs**. ✅
`gemini-2.5-flash-lite` est le seul du catalogue dont la réflexion est **désactivée par défaut** : ne rien envoyer suffit à ne pas payer de tokens de pensée. ✅ C'est une raison de plus de l'utiliser pour l'analyse et les doublons.

---

## 4. Perplexity

**Lu le 25/08/2026.** Base : `https://api.perplexity.ai`

🔬 Vérifié depuis ce poste :
- `POST /search` existe et répond `401` sans clé, avec ce corps exact :
  `{"error":{"message":"Invalid API key provided. Ensure your API key is correct and active.","type":"invalid_api_key","code":401}}`
- `POST /chat/completions` répond 401 (API Sonar, **dépréciée au 27/09/2026, non utilisée**).
- `POST /v1/agent` répond 401 → l'endpoint existe. `POST /agent` et `POST /agents` renvoient 404.
- En-tête CORS `access-control-allow-origin: *` (sans objet pour l'app native).

Le détail des schémas de requête et de réponse est en cours de relevé ; il complétera cette section avant l'implémentation du client Perplexity. Aucun champ ne sera codé sans être documenté ici.

---

## 5. Ce qui reste à confirmer avec une vraie clé

`Tools/test-apis.sh` exécute ces vérifications et affiche les réponses brutes, à recoller ici :

1. ⚠️ Forme exacte des fragments SSE de `streamGenerateContent` (voir 3.3).
2. ⚠️ Acceptation de `responseSchema` malgré la mention « deprecated » (voir 3.2).
3. ⚠️ Type MIME audio produit par `AVAudioRecorder` accepté tel quel par Gemini (relevé en cours).
4. ⚠️ Présence effective de `pageNumber` sur un PDF réel du corpus.
5. ⚠️ Schémas de requête et de réponse Perplexity (section 4).
6. ⚠️ Coût réel d'une recherche complète, à comparer à l'estimation affichée.
