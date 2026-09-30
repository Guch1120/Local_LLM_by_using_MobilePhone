#!/usr/bin/env bash
# Copy model files into the app's Documents folder over USB, then relaunch the
# app so it moves them into Application Support and registers them.
#
# Usage:
#   bash scripts/iphone/push_model.sh PATH/TO/model.litertlm
#   bash scripts/iphone/push_model.sh PATH/TO/model.gguf PATH/TO/mmproj.gguf   # llama.cpp + image input
#
# A GGUF file whose name contains "mmproj" is attached to the most recently
# imported GGUF model, so pass the model before (or together with) its mmproj.
#
# The file is uploaded under a ".part" name and renamed only after the transfer
# completes, so the app never imports a partially written model.
# Set NO_LAUNCH=1 to skip relaunching the app.
set -euo pipefail

bundle_id="jp.localai.iphone-server"
if [ "$#" -eq 0 ]; then
  echo "Usage: $0 MODEL_FILE [MMPROJ_FILE ...]  (.litertlm or .gguf)" >&2
  exit 2
fi
for model in "$@"; do
  if [ ! -f "$model" ] || [[ ! "${model,,}" =~ \.(litertlm|gguf)$ ]]; then
    echo "[ERROR] Not a .litertlm or .gguf file: $model" >&2
    exit 2
  fi
done

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

for model in "$@"; do
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
        await lockdown.close()
    print(f"[OK] Uploaded {final_path}")


asyncio.run(main(sys.argv[1], sys.argv[2]))
PY
done

if [ "${NO_LAUNCH:-0}" != "1" ]; then
  echo "[INFO] Relaunching app to import the model..."
  pymobiledevice3 mounter auto-mount >/dev/null 2>&1 || true
  # Letting the launch command kill a running instance and start a new one at once leaves the
  # new instance with a black screen. Stop the app, wait for it to go away, then launch.
  pymobiledevice3 developer dvt pkill --bundle "$bundle_id" >/dev/null 2>&1 || true
  sleep 3
  if pymobiledevice3 developer dvt launch --no-kill-existing "$bundle_id" >/dev/null; then
    echo "[OK] Relaunched $bundle_id. The import hashes the file and can take a minute."
  else
    echo "[WARN] Could not relaunch automatically; open the app on the iPhone." >&2
  fi
fi
