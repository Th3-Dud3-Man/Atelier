#!/usr/bin/env bash
# Vérification de syntaxe et de types HORS Xcode, pour attraper les fautes évidentes avant
# de vous faire compiler sur le Mac. Ce n'est PAS un substitut à `xcodebuild build` :
# les fichiers qui importent SwiftUI, UIKit, PDFKit, QuickLook, AVFoundation, Security ou
# Speech ne peuvent être vérifiés que par Xcode.
#
# Détail technique : sur Linux, URLSession vit dans FoundationNetworking. Le script travaille
# donc sur des copies temporaires auxquelles il ajoute cet import ; les sources restent intactes.
set -uo pipefail
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"

SKIP='^import (SwiftUI|UIKit|QuickLook|PDFKit|AVFoundation|Security|CryptoKit|Speech|Network|Observation)'
# Fichiers qui n'importent que Foundation mais s'appuient sur des API absentes hors Apple :
#   SSEStream  → URLSession.bytes(for:)
#   FolderSync → portée de sécurité, signets, NSFileCoordinator
# DocumentText importe Compression, absent hors Apple : la ligne d'import est retirée des
# copies et la fonction de décompression est remplacée par un substitut (voir linux-shims).
EXCLUDE_PATHS='Atelier/Services/SSEStream.swift
Atelier/Services/FolderSync.swift'
FILES=$(grep -RL --include='*.swift' -E "$SKIP" Atelier | sort)
ONLY_OBSERVATION=$(grep -Rl --include='*.swift' '^import Observation' Atelier \
    | xargs -r grep -L -E '^import (SwiftUI|UIKit|QuickLook|PDFKit|AVFoundation|Security|CryptoKit|Speech|Network)' | sort)
FILES=$(printf '%s\n%s\n' "$FILES" "$ONLY_OBSERVATION" | grep -v '^$' | sort -u | grep -vxF "$EXCLUDE_PATHS")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Fichiers vérifiés hors Xcode :"
for f in $FILES; do
  echo "  $f"
  {
    echo '#if canImport(FoundationNetworking)'
    echo 'import FoundationNetworking'
    echo '#endif'
    # `import Compression` n'existe pas hors Apple : la ligne saute, et linux-shims fournit
    # un substitut de `compression_decode_buffer`.
    sed 's/^import Compression$//' "$f"
  } > "$TMP/$(echo "$f" | tr '/' '_')"
done
echo
cp Tools/linux-shims.swift "$TMP/zz-shims.swift"
$SWIFTC -typecheck -swift-version 6 "$TMP"/*.swift
STATUS=$?
[ $STATUS -eq 0 ] && echo "✓ Aucun problème détecté sur ces fichiers."
exit $STATUS
