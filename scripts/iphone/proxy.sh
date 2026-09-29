#!/usr/bin/env bash
set -euo pipefail

if ! command -v iproxy >/dev/null 2>&1; then
  echo "[ERROR] iproxy is not installed." >&2
  echo "Install it with: sudo apt install libusbmuxd-tools" >&2
  exit 1
fi

if ! command -v idevice_id >/dev/null 2>&1 || ! idevice_id -l 2>/dev/null | grep -q .; then
  echo "[ERROR] No paired iPhone is visible through usbmuxd." >&2
  echo "Try: sudo systemctl restart usbmuxd" >&2
  exit 1
fi

local_port="\${1:-8080}"
device_port="\${2:-8080}"

if ! [[ "$local_port" =~ ^[0-9]+$ && "$device_port" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 [LOCAL_PORT] [IPHONE_PORT]" >&2
  exit 2
fi

echo "[INFO] USB port forwarding"
echo "       127.0.0.1:\${local_port} -> iPhone:\${device_port}"
echo "[INFO] Keep this process running. Stop with Ctrl-C."

exec iproxy "$local_port" "$device_port"
