#!/usr/bin/env bash
set -euo pipefail

if ! command -v idevicesyslog >/dev/null 2>&1; then
  echo "[ERROR] idevicesyslog is not installed." >&2
  echo "Install it with: sudo apt install libimobiledevice-utils" >&2
  exit 1
fi

if ! idevice_id -l 2>/dev/null | grep -q .; then
  echo "[ERROR] No paired iPhone is visible to libimobiledevice." >&2
  echo "Try: sudo systemctl restart usbmuxd" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)"
out_dir="\${repo_root}/artifacts/iphone/logs"
mkdir -p "$out_dir"

timestamp="$(date '+%Y%m%d-%H%M%S')"
output="\${out_dir}/syslog-\${timestamp}.log"
filter="\${1:-}"

echo "[INFO] Streaming iPhone syslog. Stop with Ctrl-C."
echo "[INFO] Saving to: $output"

if [ -n "$filter" ]; then
  echo "[INFO] Filter: $filter"
  set +e
  idevicesyslog 2>&1 | grep --line-buffered -i -- "$filter" | tee -a "$output"
  status=\${PIPESTATUS[0]}
  set -e
else
  set +e
  idevicesyslog 2>&1 | tee -a "$output"
  status=\${PIPESTATUS[0]}
  set -e
fi

if [ "$status" -ne 0 ] && [ "$status" -ne 130 ]; then
  exit "$status"
fi
