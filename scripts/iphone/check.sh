#!/usr/bin/env bash
set -u

failures=0
warnings=0

ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }

printf '=== iPhone USB development check ===\n'

for cmd in pymobiledevice3 lsusb systemctl; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "Found command: $cmd"
  else
    fail "Missing command: $cmd"
  fi
done

# The helper scripts fall back to pymobiledevice3 when these are missing.
for cmd in idevice_id iproxy; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "Found command: $cmd"
  else
    printf '[INFO] %s not found; using pymobiledevice3 instead (optional: sudo apt install libimobiledevice-utils libusbmuxd-tools)\n' "$cmd"
  fi
done

if systemctl is-active --quiet usbmuxd 2>/dev/null; then
  ok "usbmuxd is active"
else
  fail "usbmuxd is not active"
fi

if lsusb 2>/dev/null | grep -qi apple; then
  ok "Apple USB device detected"
else
  fail "No Apple USB device found by lsusb"
fi

if command -v pymobiledevice3 >/dev/null 2>&1; then
  usbmux_output="$(pymobiledevice3 usbmux list 2>&1 || true)"
  if printf '%s\n' "$usbmux_output" | grep -q '"DeviceClass": "iPhone"'; then
    ok "pymobiledevice3 sees an iPhone over usbmux"
  else
    fail "pymobiledevice3 does not see an iPhone"
    printf '%s\n' "$usbmux_output"
  fi

  devmode_output="$(pymobiledevice3 amfi developer-mode-status 2>&1 || true)"
  printf '%s\n' "$devmode_output"
  if printf '%s\n' "$devmode_output" | grep -Eqi 'enabled|true|1'; then
    ok "Developer Mode appears enabled"
  else
    warn "Could not confirm Developer Mode. If disabled, run: pymobiledevice3 amfi reveal-developer-mode"
  fi

  core_output="$(pymobiledevice3 developer core-device get-device-info 2>&1 || true)"
  if [ -n "$core_output" ] && ! printf '%s\n' "$core_output" | grep -Eqi 'error|traceback|not connected|developer mode is disabled'; then
    ok "CoreDevice developer service is reachable"
  else
    warn "CoreDevice readiness could not be confirmed. Try: pymobiledevice3 mounter auto-mount"
  fi
fi

if command -v idevice_id >/dev/null 2>&1; then
  if idevice_id -l 2>/dev/null | grep -q .; then
    ok "libimobiledevice sees a paired device"
  else
    warn "idevice_id returned no device"
  fi
fi

printf '\nSummary: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
if [ "$failures" -ne 0 ]; then
  printf 'If USB is visible but usbmux is empty, try: sudo systemctl restart usbmuxd\n'
  exit 1
fi
