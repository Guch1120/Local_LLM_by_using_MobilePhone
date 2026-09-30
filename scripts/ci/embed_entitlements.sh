#!/usr/bin/env bash
# Ad-hoc sign an unsigned archived app so that its entitlements are part of the
# code signature. `xcodebuild -exportArchive` re-signs the app with the real
# identity and carries over the entitlements it finds in the existing signature;
# an app archived with CODE_SIGNING_ALLOWED=NO has none, so they would be lost.
#
# Usage: embed_entitlements.sh PATH/TO/App.app PATH/TO/App.entitlements
set -euo pipefail

app="${1:?path to the archived .app}"
entitlements="${2:?path to the entitlements file}"

if [ -d "$app/Frameworks" ]; then
  find "$app/Frameworks" -mindepth 1 -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0 |
    while IFS= read -r -d '' item; do
      codesign --force --sign - "$item"
    done
fi
codesign --force --sign - --entitlements "$entitlements" "$app"
bash "$(dirname "${BASH_SOURCE[0]}")/verify_entitlements.sh" "$app" "$entitlements"
