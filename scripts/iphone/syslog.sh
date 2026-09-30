#!/usr/bin/env bash
# Stream the iPhone system log and save a copy under artifacts/iphone/logs/.
# Uses idevicesyslog when it is installed, otherwise pymobiledevice3.
set -euo pipefail

if command -v idevicesyslog >/dev/null 2>&1 && command -v idevice_id >/dev/null 2>&1; then
  if ! idevice_id -l 2>/dev/null | grep -q .; then
    echo "[ERROR] No paired iPhone is visible to libimobiledevice." >&2
    echo "Try: sudo systemctl restart usbmuxd" >&2
    exit 1
  fi
  syslog_cmd=(idevicesyslog)
elif command -v pymobiledevice3 >/dev/null 2>&1; then
  if ! pymobiledevice3 usbmux list 2>/dev/null | grep -q '"DeviceClass": "iPhone"'; then
    echo "[ERROR] No iPhone is visible through usbmuxd." >&2
    echo "Try: sudo systemctl restart usbmuxd" >&2
    exit 1
  fi
  syslog_cmd=(pymobiledevice3 syslog live)
else
  echo "[ERROR] Neither idevicesyslog nor pymobiledevice3 is installed." >&2
  echo "Install one with: sudo apt install libimobiledevice-utils" >&2
  echo "               or: python3 -m pip install --user -U pymobiledevice3" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out_dir="${repo_root}/artifacts/iphone/logs"
mkdir -p "$out_dir"

timestamp="$(date '+%Y%m%d-%H%M%S')"
output="${out_dir}/syslog-${timestamp}.log"
filter="${1:-}"

echo "[INFO] Streaming iPhone syslog. Stop with Ctrl-C."
echo "[INFO] Saving to: $output"

set +e
if [ -n "$filter" ]; then
  echo "[INFO] Filter: $filter"
  "${syslog_cmd[@]}" 2>&1 | grep --line-buffered -i -- "$filter" | tee -a "$output"
  status=${PIPESTATUS[0]}
else
  "${syslog_cmd[@]}" 2>&1 | tee -a "$output"
  status=${PIPESTATUS[0]}
fi
set -e

if [ "$status" -ne 0 ] && [ "$status" -ne 130 ]; then
  exit "$status"
fi
