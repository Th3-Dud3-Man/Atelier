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

**Lu le 25/08/2026.** Base : `https://api.perplexity.ai` — authentification `Authorization: Bearer <clé>`.

Bandeau officiel : « Sonar Chat Completions is now Agent API. Sonar will be supported until **September 27, 2026**. » → `/chat/completions` n'est pas utilisée. ✅

🔬 Vérifié depuis ce poste : `POST /search` et `POST /v1/agent` existent et répondent 401 sans clé, avec ce corps exact :
`{"error":{"message":"Invalid API key provided. Ensure your API key is correct and active.","type":"invalid_api_key","code":401}}`
`POST /agent` et `POST /agents` renvoient 404 — le bon chemin de l'agent est bien `/v1/agent`.

### 4.1 Search API — niveau Standard

```
POST /search
{ "query": "…"  |  ["…", "…"],     // jusqu'à 5 requêtes en un appel
  "max_results": 8,                 // 1 à 20, défaut 10
  "search_context_size": "high",    // low | medium | high, défaut high
  "search_recency_filter": "month", // hour | day | week | month | year
  "search_domain_filter": ["…"],    // 20 entrées maximum, « -domaine » pour exclure
  "country": "FR", "search_language_filter": ["fr"] }
```
✅ Champs relevés dans le schéma OpenAPI officiel. `search_context_size` **ne peut pas** être combiné avec `max_tokens` ou `max_tokens_per_page` dans le même appel.

Réponse : ✅
```json
{ "id": "…",
  "results": [ { "title": "…", "url": "…", "snippet": "…", "date": "2026-05-01", "last_updated": "2026-05-21" } ],
  "server_time": null }
```
`title`, `url`, `snippet` sont obligatoires ; `date` et `last_updated` peuvent être nuls. **Il n'y a aucun objet `usage` ni `cost`.** ✅

**Tarification — le point le plus utile de toute cette section** : « Search API charges for each successful `POST /search` request, **not for each query in the request**. » À 5 $ les mille appels, une recherche coûte donc **exactement 0,005 $**, qu'elle porte une ou cinq requêtes, quel que soit `max_results`. ✅ L'estimation affichée avant lancement est donc exacte, pas approchée.

À `search_context_size: "high"` (le défaut), les extraits font plusieurs milliers de caractères : assez pour rédiger une synthèse sans aller chercher les pages nous-mêmes. ✅ C'est ce que fait l'app.

Limite de débit : **50 unités par seconde**, indépendante du palier ; une requête multiple consomme une unité **par requête** du tableau. ✅

### 4.2 Agent API — niveau Approfondi

```
POST /v1/agent
{ "preset": "medium",            // fast | low | medium | high | xhigh | wide-research
  "input": "…",                  // chaîne, ou tableau d'éléments {type,role,content}
  "language_preference": "fr",
  "stream": false }
```
✅ `input`, et non `messages`. Les préréglages portent le modèle, le nombre de tours et les outils ; ils ont été renommés (`deep-research` → `medium`).

Réponse : ✅
```json
{ "status": "completed",
  "output": [
    { "type": "search_results", "results": [ { "id": 1, "url": "…", "title": "…", "snippet": "…", "date": "…" } ] },
    { "type": "message", "content": [ { "type": "output_text", "text": "…" } ] }
  ],
  "usage": { "input_tokens": 12088, "output_tokens": 2743,
             "cost": { "currency": "USD", "total_cost": 0.04021 } } }
```

⚠️ Deux pièges relevés :
- `output_text` **est une commodité des SDK**, pas un champ JSON : en HTTP brut il faut parcourir `output[]`, prendre les éléments `type == "message"`, puis leurs `content[]` de `type == "output_text"`. C'est ce que fait le client.
- Le format des citations **change selon le préréglage** : `fast` produit `[1]`, les autres `[web:1]`. L'app n'exploite pas ces marqueurs — elle prend les `search_results` comme sources et fait rédiger la synthèse par Gemini, ce qui rend la question sans objet.

Tarification des outils : `web_search` 0,0025 $ par appel, `fetch_url` 0,0005 $, plus les tokens du modèle. Le coût réel est renvoyé dans `usage.cost.total_cost` ; l'app l'utilise quand il est présent et retombe sur la grille sinon. ✅

### 4.3 Erreurs

Enveloppe observée : `{"error": {"message": …, "type": …, "code": 401}}` (`code` est un **nombre**). La Search API renvoie en plus un 422 de validation au format `{"detail": [{"loc": …, "msg": …, "type": …}]}`. ✅

⚠️ `Retry-After` n'est documenté que pour une autre API de Perplexity (Router). Le client honore l'en-tête s'il est présent et retombe sinon sur un délai croissant — correct dans les deux cas.

Non facturés : les requêtes invalides, celles limitées en débit, et les échecs amont. ✅

---

---

## 5. Audio : quel format enregistrer

**Lu le 25/08/2026** sur les pages Audio et Files API.

Formats acceptés, liste exhaustive et identique sur les deux pages officielles : ✅
`audio/wav`, `audio/mp3`, `audio/aiff`, `audio/aac`, `audio/ogg`, `audio/flac`.

**`audio/mp4` n'y figure pas.** C'est pourtant le format naturel d'un enregistrement iOS (`kAudioFormatMPEG4AAC` dans un conteneur `.m4a`). La recherche a cherché la chaîne « audio/mp4 » dans les guides audio, les deux pages Files, la référence REST de `generateContent` et celle des Interactions : **zéro occurrence**.

→ L'app enregistre donc en **WAV, PCM linéaire, 16 kHz, mono, 16 bits**. Ce n'est pas un compromis : Gemini ramène de toute façon tout l'audio à 16 kbps et fusionne les canaux ✅, si bien qu'enregistrer plus riche ne ferait que grossir l'envoi sans rien améliorer.

| Limite | Valeur |
|---|---|
| Taille maximale d'une requête avec audio joint | **20 Mo**, requête entière comprise ✅ |
| Durée maximale d'un prompt | 9,5 heures ✅ |
| Tokens | **32 par seconde**, soit 1 920 par minute ✅ |
| API Files : taille, durée de vie | 2 Go par fichier, **48 heures**, gratuite ✅ |

Le base64 gonfle les octets d'un tiers : le seuil de bascule de l'app est fixé à **12 Mo bruts** (≈ 16 Mo encodés, ≈ 6 minutes), au-delà desquels l'enregistrement passe par l'API Files. Un mémo de dix minutes fait ≈ 19 Mo bruts : il emprunte donc la voie Files, comme prévu.

⚠️ Deux différences de forme faciles à manquer, prises en compte dans le code : l'étape 1 de l'API Files enveloppe son corps dans `{"file": {...}}` (contrairement au store), et la réponse de l'étape 2 est elle aussi enveloppée (`.file.uri`), alors que `files.get` renvoie l'objet nu. Un fichier reste inutilisable tant que son `state` vaut `PROCESSING` : l'app attend `ACTIVE`. ✅

---

## 6. Ce qui reste à confirmer avec une vraie clé

`Tools/test-apis.sh` exécute ces vérifications et affiche les réponses brutes, à recoller ici :

1. ⚠️ Forme exacte des fragments SSE de `streamGenerateContent` (§3.3). Le code accepte les deux formes documentées.
2. ⚠️ Acceptation de `responseSchema` malgré la mention « deprecated » (§3.2). Le code refait l'appel sans le schéma en cas de 400.
3. ⚠️ Présence effective de `pageNumber` sur un PDF réel du corpus (§2.4).
4. ⚠️ Lisibilité de l'en-tête `x-goog-upload-url` depuis l'app (§2.2) — sans objet en natif, mais à confirmer au premier import.
5. ⚠️ Concordance entre le coût affiché et la facturation réelle, côté Google comme côté Perplexity.
6. ⚠️ Acceptation du WAV 16 kHz produit par `AVAudioRecorder`, et comportement sur un mémo de dix minutes (§5).
