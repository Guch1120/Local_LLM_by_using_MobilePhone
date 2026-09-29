#!/usr/bin/env bash
set -euo pipefail

if ! command -v pymobiledevice3 >/dev/null 2>&1; then
  echo "[ERROR] pymobiledevice3 is not installed." >&2
  exit 1
fi

if ! pymobiledevice3 usbmux list 2>/dev/null | grep -q '"DeviceClass": "iPhone"'; then
  echo "[ERROR] No iPhone is visible through usbmuxd." >&2
  echo "Try: sudo systemctl restart usbmuxd" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)"
out_dir="\${repo_root}/artifacts/iphone/screenshots"
latest="\${repo_root}/artifacts/iphone/latest.png"
mkdir -p "$out_dir"

timestamp="$(date '+%Y%m%d-%H%M%S')"
output="\${1:-\${out_dir}/iphone-\${timestamp}.png}"
mkdir -p "$(dirname "$output")"

echo "[INFO] Ensuring DeveloperDiskImage is mounted..."
pymobiledevice3 mounter auto-mount >/dev/null

echo "[INFO] Capturing iPhone screen..."
pymobiledevice3 developer core-device screen-capture screenshot "$output"

cp -f "$output" "$latest"

echo "[OK] Screenshot: $output"
echo "[OK] Latest copy: $latest"
