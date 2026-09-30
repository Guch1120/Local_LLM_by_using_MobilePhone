#!/usr/bin/env bash
# Fail unless every key of the (XML) entitlements file is present and true in the
# app's code signature. Prints key names only: the signed entitlements also
# contain the team identifier, which must not end up in a public build log.
#
# Usage: verify_entitlements.sh PATH/TO/App.app PATH/TO/App.entitlements
set -euo pipefail

app="${1:?path to the .app}"
entitlements="${2:?path to the entitlements file}"

signed="$(mktemp)"
trap 'rm -f "$signed"' EXIT
codesign -d --entitlements - --xml "$app" > "$signed" 2>/dev/null

status=0
while IFS= read -r key; do
  if [ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$signed" 2>/dev/null)" = "true" ]; then
    echo "[OK] $key"
  else
    echo "[ERROR] Entitlement missing from the code signature: $key" >&2
    status=1
  fi
done < <(sed -n 's:.*<key>\(.*\)</key>.*:\1:p' "$entitlements")
exit "$status"
