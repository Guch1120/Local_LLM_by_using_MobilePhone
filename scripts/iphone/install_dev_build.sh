#!/usr/bin/env bash
# Download the development-signed IPA from the "iOS dev build" workflow and
# install it on the USB-connected iPhone.
#
# Usage:
#   bash scripts/iphone/install_dev_build.sh            # latest successful run on iphone
#   bash scripts/iphone/install_dev_build.sh RUN_ID     # a specific run
#   bash scripts/iphone/install_dev_build.sh --wait     # wait for the newest run to finish first
#
# The artifact is encrypted with the DEV_IPA_PASSWORD repository secret. Provide the
# same password through $DEV_IPA_PASSWORD or the file
# ~/.config/iphone-local-ai/dev-ipa-password (chmod 600).
#
# Set NO_LAUNCH=1 to skip launching the app after install.
set -euo pipefail

bundle_id="jp.localai.iphone-server"
workflow="iOS dev build"
branch="${BRANCH:-iphone}"

password_file="${HOME}/.config/iphone-local-ai/dev-ipa-password"
if [ -z "${DEV_IPA_PASSWORD:-}" ] && [ -f "$password_file" ]; then
  DEV_IPA_PASSWORD="$(cat "$password_file")"
fi
if [ -z "${DEV_IPA_PASSWORD:-}" ]; then
  echo "[ERROR] Set DEV_IPA_PASSWORD or write it to $password_file (same value as the repository secret)." >&2
  exit 1
fi
export DEV_IPA_PASSWORD

for cmd in gh pymobiledevice3 openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] $cmd is not installed." >&2
    exit 1
  fi
done

if ! pymobiledevice3 usbmux list 2>/dev/null | grep -q '"DeviceClass": "iPhone"'; then
  echo "[ERROR] No iPhone is visible through usbmuxd." >&2
  echo "Try: sudo systemctl restart usbmuxd" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

latest_run() {
  # $1: jq filter on run status
  gh run list -w "$workflow" -L 20 --json databaseId,headBranch,status,conclusion \
    -q "[.[] | select(.headBranch == \"$branch\") $1][0].databaseId // empty"
}

run_id="${1:-}"
if [ "$run_id" = "--wait" ]; then
  run_id="$(latest_run '')"
  if [ -z "$run_id" ]; then
    echo "[ERROR] No \"$workflow\" run found for branch $branch." >&2
    exit 1
  fi
  echo "[INFO] Waiting for run $run_id..."
  gh run watch "$run_id" --exit-status >/dev/null
elif [ -z "$run_id" ]; then
  run_id="$(latest_run '| select(.conclusion == "success")')"
  if [ -z "$run_id" ]; then
    echo "[ERROR] No successful \"$workflow\" run found for branch $branch." >&2
    exit 1
  fi
fi

out_dir="$repo_root/artifacts/iphone/builds/$run_id"
if ! find "$out_dir" -name '*.ipa.enc' 2>/dev/null | grep -q .; then
  echo "[INFO] Downloading IPA from run $run_id..."
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  gh run download "$run_id" -D "$out_dir"
fi

encrypted="$(find "$out_dir" -name '*.ipa.enc' | head -1)"
if [ -z "$encrypted" ]; then
  echo "[ERROR] No encrypted IPA found in run $run_id artifacts." >&2
  exit 1
fi
ipa="${encrypted%.enc}"
if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$encrypted" -out "$ipa" -pass env:DEV_IPA_PASSWORD 2>/dev/null; then
  rm -f "$ipa"
  echo "[ERROR] Could not decrypt the IPA. Check that DEV_IPA_PASSWORD matches the repository secret." >&2
  exit 1
fi

echo "[INFO] Installing $(basename "$ipa") (run $run_id)..."
pymobiledevice3 apps install "$ipa"
echo "[OK] Installed $bundle_id from run $run_id"

if [ "${NO_LAUNCH:-0}" != "1" ]; then
  echo "[INFO] Launching app..."
  pymobiledevice3 mounter auto-mount >/dev/null 2>&1 || true
  if pymobiledevice3 developer dvt launch "$bundle_id" >/dev/null; then
    echo "[OK] Launched $bundle_id"
  else
    echo "[WARN] Could not launch automatically; open the app on the iPhone." >&2
  fi
fi
