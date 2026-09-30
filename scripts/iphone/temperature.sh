#!/usr/bin/env bash
# Show the iPhone's battery temperature in degrees Celsius over USB.
#
# iOS gives apps no temperature in degrees, only four levels (nominal, fair, serious,
# critical), so the number comes from the battery sensor that the PC reads through the
# diagnostics service. The battery is cooler than the chip that runs the model: use the
# value to see the trend, and the level the app reports to know when it pauses.
#
# Usage:
#   bash scripts/iphone/temperature.sh            # one reading
#   bash scripts/iphone/temperature.sh 10         # a reading every 10 seconds (Ctrl-C to stop)
#
# Prints: battery and "virtual" (thermal model) temperature, battery level, charging, and the
# app's thermal level when the USB port forward (proxy.sh) and the API key are available.
set -euo pipefail

if ! command -v pymobiledevice3 >/dev/null 2>&1; then
  echo "[ERROR] pymobiledevice3 is not installed." >&2
  exit 1
fi

interval="${1:-0}"
if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 [INTERVAL_SECONDS]" >&2
  exit 2
fi

key="${API_KEY:-}"
if [ -z "$key" ] && [ -f "$HOME/.config/iphone-local-ai/api-key" ]; then
  key="$(cat "$HOME/.config/iphone-local-ai/api-key")"
fi
port="${PORT:-8080}"

reading() {
  local app_level="-"
  if [ -n "$key" ]; then
    app_level="$(curl -s -m 3 -H "Authorization: Bearer $key" "http://127.0.0.1:${port}/metrics" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("thermal_state","-"))' 2>/dev/null || echo "-")"
  fi
  pymobiledevice3 diagnostics battery single 2>/dev/null | APP_LEVEL="$app_level" python3 -c '
import json, os, sys, time
d = json.load(sys.stdin)
# Temperature values are in 0.01 degrees Celsius.
print("%s  battery %.1f C  virtual %.1f C  level %d%%  charging=%s  app thermal level=%s" % (
    time.strftime("%H:%M:%S"), d["Temperature"] / 100, d["VirtualTemperature"] / 100,
    d["CurrentCapacity"], d["IsCharging"], os.environ["APP_LEVEL"]))'
}

if [ "$interval" -eq 0 ]; then
  reading
else
  while true; do
    reading
    sleep "$interval"
  done
fi
