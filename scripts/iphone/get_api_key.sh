#!/usr/bin/env bash
# Load the API key copied on the iPhone into the current shell.
#
# Usage:
#   source scripts/iphone/get_api_key.sh
#
# The script must be sourced if you want API_KEY to remain available in your
# current shell. It intentionally never prints the key itself.

set -u

_is_sourced() {
  [[ "${BASH_SOURCE[0]}" != "$0" ]]
}

_finish() {
  local code="$1"
  if _is_sourced; then
    return "$code"
  fi
  exit "$code"
}

if ! command -v pymobiledevice3 >/dev/null 2>&1; then
  echo "[ERROR] pymobiledevice3 is not installed." >&2
  _finish 1
fi

if ! pymobiledevice3 usbmux list 2>/dev/null | grep -q '"DeviceClass": "iPhone"'; then
  echo "[ERROR] No iPhone is visible through usbmuxd." >&2
  echo "Try: sudo systemctl restart usbmuxd" >&2
  _finish 1
fi

if ! _is_sourced; then
  echo "[ERROR] This script must be sourced so API_KEY remains in your current shell." >&2
  echo "Use: source scripts/iphone/get_api_key.sh" >&2
  _finish 2
fi

clipboard="$(pymobiledevice3 developer core-device paste 2>/dev/null || true)"

if [ -z "$clipboard" ]; then
  echo "[ERROR] The iPhone clipboard is empty or could not be read." >&2
  echo "Copy the API key in the iPhone app, then run this command again:" >&2
  echo "  source scripts/iphone/get_api_key.sh" >&2
  unset clipboard
  return 1
fi

API_KEY="$clipboard"
export API_KEY
unset clipboard

echo "[OK] API_KEY loaded from the iPhone clipboard."
echo "[OK] API_KEY length: ${#API_KEY}"
