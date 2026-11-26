#!/usr/bin/env bash
# The official llama.cpp XCFramework has no iOS Simulator slice since b12088, so the Simulator unit tests
# cannot link it. This builds a Simulator-only XCFramework from the pinned tag and points the (CI checkout's)
# Packages/LlamaCpp/Package.swift at it. Run on a macOS runner; the build directory can be cached.
set -euo pipefail
cd "$(dirname "$0")/../.."
TAG=$(grep -oE 'releases/download/b[0-9]+' Packages/LlamaCpp/Package.swift | head -1 | sed 's|.*/||')
OUT=Packages/LlamaCpp/llama-sim.xcframework
if [ ! -d "$OUT" ]; then
  WORK=${RUNNER_TEMP:-/tmp}/llama.cpp-$TAG
  rm -rf "$WORK"
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$WORK"
  (cd "$WORK" && ./build-xcframework.sh ios-sim)
  cp -R "$WORK/build-apple/llama.xcframework" "$OUT"
fi
python3 - <<'PY'
import re
p = "Packages/LlamaCpp/Package.swift"
s = open(p).read()
s = re.sub(r'\.binaryTarget\(.*?\n        \)', '.binaryTarget(name: "LlamaFramework", path: "llama-sim.xcframework")', s, flags=re.S)
open(p, "w").write(s)
PY
echo "Package.swift now uses the Simulator-only $TAG XCFramework"
