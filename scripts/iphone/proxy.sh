#!/usr/bin/env bash
# Forward a local TCP port to the iPhone over USB.
# Uses iproxy when it is installed, otherwise pymobiledevice3 (no root needed).
set -euo pipefail

forwarder=""
if command -v iproxy >/dev/null 2>&1 && command -v idevice_id >/dev/null 2>&1; then
  if ! idevice_id -l 2>/dev/null | grep -q .; then
    echo "[ERROR] No paired iPhone is visible through usbmuxd." >&2
    echo "Try: sudo systemctl restart usbmuxd" >&2
    exit 1
  fi
  forwarder="iproxy"
elif command -v pymobiledevice3 >/dev/null 2>&1; then
  if ! pymobiledevice3 usbmux list 2>/dev/null | grep -q '"DeviceClass": "iPhone"'; then
    echo "[ERROR] No iPhone is visible through usbmuxd." >&2
    echo "Try: sudo systemctl restart usbmuxd" >&2
    exit 1
  fi
  forwarder="pymobiledevice3"
else
  echo "[ERROR] Neither iproxy nor pymobiledevice3 is installed." >&2
  echo "Install one with: sudo apt install libusbmuxd-tools libimobiledevice-utils" >&2
  echo "               or: python3 -m pip install --user -U pymobiledevice3" >&2
  exit 1
fi

local_port="${1:-8080}"
device_port="${2:-8080}"

if ! [[ "$local_port" =~ ^[0-9]+$ && "$device_port" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 [LOCAL_PORT] [IPHONE_PORT]" >&2
  exit 2
fi

echo "[INFO] USB port forwarding ($forwarder)"
echo "       127.0.0.1:${local_port} -> iPhone:${device_port}"
echo "[INFO] Keep this process running. Stop with Ctrl-C."

if [ "$forwarder" = "iproxy" ]; then
  exec iproxy "$local_port" "$device_port"
fi
exec pymobiledevice3 usbmux forward "$local_port" "$device_port"
