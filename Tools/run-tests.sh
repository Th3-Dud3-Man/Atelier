#!/usr/bin/env bash
# Exécute les tests qui peuvent tourner hors Xcode, c'est-à-dire ceux qui ne touchent
# qu'à la logique pure : persistance JSON, empreinte anti-dépense, calcul des coûts.
#
# Ce n'est pas une suite de tests d'interface : celle-là se déroule sur vos appareils,
# guidée par CHECKLIST_APPAREIL.md.
set -uo pipefail
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# AppData s'appuie sur Observation, qui n'apporte rien au test : on retire l'annotation.
sed 's/^import Observation$//; s/^@Observable$//' Atelier/Models/AppData.swift > "$TMP/AppData.swift"

STATUS=0
for test in Tools/tests/*.swift; do
  name=$(basename "$test" .swift)
  echo "── $name ──"
  # Swift n'autorise le code au niveau supérieur que dans un fichier nommé main.swift.
  cp "$test" "$TMP/main.swift"
  if $SWIFTC -swift-version 6 \
      Atelier/Models/Domain.swift Atelier/Models/Library.swift \
      Atelier/Services/CostModel.swift Atelier/Services/GeminiModels.swift \
      Atelier/Services/Dedupe.swift \
      "$TMP/AppData.swift" "$TMP/main.swift" -o "$TMP/$name" 2>"$TMP/$name.log"; then
    "$TMP/$name" || STATUS=1
  else
    echo "  échec de compilation :"; sed 's/^/    /' "$TMP/$name.log" | head -20; STATUS=1
  fi
  echo
done
exit $STATUS
