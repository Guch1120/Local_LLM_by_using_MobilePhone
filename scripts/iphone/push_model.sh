#!/usr/bin/env bash
# Copy a .litertlm model into the app's Documents folder over USB, then relaunch
# the app so it moves the file into Application Support and registers it.
#
# Usage:
#   bash scripts/iphone/push_model.sh PATH/TO/model.litertlm
#
# The file is uploaded under a ".part" name and renamed only after the transfer
# completes, so the app never imports a partially written model.
# Set NO_LAUNCH=1 to skip relaunching the app.
set -euo pipefail

bundle_id="jp.localai.iphone-server"
model="${1:-}"

if [ -z "$model" ] || [ ! -f "$model" ] || [[ "${model,,}" != *.litertlm ]]; then
  echo "Usage: $0 PATH/TO/model.litertlm" >&2
  exit 2
fi

if ! command -v pymobiledevice3 >/dev/null 2>&1; then
  echo "[ERROR] pymobiledevice3 is not installed." >&2
  exit 1
fi

if ! pymobiledevice3 usbmux list 2>/dev/null | grep -q '"DeviceClass": "iPhone"'; then
  echo "[ERROR] No iPhone is visible through usbmuxd." >&2
  echo "Try: sudo systemctl restart usbmuxd" >&2
  exit 1
fi

python_bin="$(head -1 "$(command -v pymobiledevice3)" | sed 's/^#!//')"
[ -x "$python_bin" ] || python_bin=python3

echo "[INFO] Uploading $(basename "$model") ($(du -h "$model" | cut -f1)) to the app's Documents folder..."
"$python_bin" - "$bundle_id" "$model" <<'PY'
import asyncio
import os
import sys

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService


async def main(bundle_id: str, local_path: str) -> None:
    lockdown = await create_using_usbmux()
    name = os.path.basename(local_path)
    final_path = f"/Documents/{name}"
    partial_path = f"{final_path}.part"
    service = await HouseArrestService.create(lockdown, bundle_id, documents_only=True)
    try:
        if await service.exists(partial_path):
            await service.rm(partial_path)
        await service.push(local_path, partial_path)
        await service.rename(partial_path, final_path)
    finally:
        await service.close()
    print(f"[OK] Uploaded {final_path}")


asyncio.run(main(sys.argv[1], sys.argv[2]))
PY

if [ "${NO_LAUNCH:-0}" != "1" ]; then
  echo "[INFO] Relaunching app to import the model..."
  pymobiledevice3 mounter auto-mount >/dev/null 2>&1 || true
  if pymobiledevice3 developer dvt launch "$bundle_id" >/dev/null; then
    echo "[OK] Relaunched $bundle_id. The import hashes the file and can take a minute."
  else
    echo "[WARN] Could not relaunch automatically; open the app on the iPhone." >&2
  fi
fi
