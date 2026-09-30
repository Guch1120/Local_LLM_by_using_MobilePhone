#!/usr/bin/env bash
# Relaunch the app on the USB-connected iPhone and stream its stdout/stderr.
# llama.cpp and LiteRT-LM write their load errors to stderr, which the app's own
# log does not contain, so this is the way to see why a model failed to load.
#
# Usage:
#   bash scripts/iphone/launch.sh                 # relaunch and stream output
#   bash scripts/iphone/launch.sh MODEL_ID        # also load MODEL_ID at launch
#
# MODEL_ID overrides the "last loaded model" for this launch only (it is passed
# as a UserDefaults launch argument), so no API key or tap on the phone is needed.
#
# APP_ARGS adds launch arguments, for example to open a screen for a screenshot:
#   APP_ARGS="-initialTab models" bash scripts/iphone/launch.sh
#   APP_ARGS="-initialTab models -modelBrowserQuery gemma" bash scripts/iphone/launch.sh
#   APP_ARGS="-initialTab models -modelBrowserRepository owner/name" bash scripts/iphone/launch.sh
# Output is saved under artifacts/iphone/logs/. Stop with Ctrl-C; the app keeps running.
set -euo pipefail

bundle_id="jp.localai.iphone-server"

if ! command -v pymobiledevice3 >/dev/null 2>&1; then
  echo "[ERROR] pymobiledevice3 is not installed." >&2
  exit 1
fi

if ! pymobiledevice3 usbmux list 2>/dev/null | grep -q '"DeviceClass": "iPhone"'; then
  echo "[ERROR] No iPhone is visible through usbmuxd." >&2
  echo "Try: sudo systemctl restart usbmuxd" >&2
  exit 1
fi

model_id="${1:-}"
if [[ ! "$model_id" =~ ^[A-Za-z0-9._-]*$ ]]; then
  echo "Usage: $0 [MODEL_ID]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out_dir="${repo_root}/artifacts/iphone/logs"
mkdir -p "$out_dir"
output="${out_dir}/launch-$(date '+%Y%m%d-%H%M%S').log"

launch_arguments="$bundle_id"
if [ -n "$model_id" ]; then
  launch_arguments="$bundle_id -lastLoadedModelID $model_id -autoLoadInProgress NO"
  echo "[INFO] Loading model at launch: $model_id"
fi

if [ -n "${APP_ARGS:-}" ]; then
  launch_arguments="$launch_arguments $APP_ARGS"
fi

pymobiledevice3 mounter auto-mount >/dev/null 2>&1 || true
echo "[INFO] Launching $bundle_id. Stop with Ctrl-C."
echo "[INFO] Saving to: $output"

set +e
pymobiledevice3 developer dvt launch --stream "$launch_arguments" 2>&1 | tee "$output"
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ] && [ "$status" -ne 130 ]; then
  exit "$status"
fi
