"""Manage files in the app's model folder over USB (the app must not be running while models.json is edited).

usage: phone_files.py remove ID           delete a model (files and models.json entry) whose id contains ID
       phone_files.py upload LOCAL [NAME] copy a file (for example a LoRA adapter) into the model folder
       phone_files.py list
"""
import asyncio, json, os, sys
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService

FOLDER = "/Library/Application Support/Models/"

async def main():
    afc = await HouseArrestService.create(await create_using_usbmux(), "jp.localai.iphone-server")
    cmd = sys.argv[1]
    if cmd == "list":
        for n in sorted(await afc.listdir(FOLDER)):
            if n not in (".", ".."): print(n, round((await afc.stat(FOLDER + n))["st_size"] / 1e9, 2), "GB")
    elif cmd == "remove":
        key = sys.argv[2]
        raw = await afc.get_file_contents(FOLDER + "models.json")
        data = json.loads(raw); items = data if isinstance(data, list) else data.get("models", data)
        keep = [m for m in items if key not in m.get("id", "")]
        for n in await afc.listdir(FOLDER):
            if key in n and n != "models.json": await afc.rm(FOLDER + n); print("removed", n)
        out = keep if isinstance(data, list) else {**data, "models": keep}
        await afc.set_file_contents(FOLDER + "models.json", json.dumps(out, indent=2).encode())
        print("models:", [m["id"] for m in keep])
    elif cmd == "upload":
        path = os.path.expanduser(sys.argv[2]); name = sys.argv[3] if len(sys.argv) > 3 else os.path.basename(path)
        await afc.set_file_contents(FOLDER + name, open(path, "rb").read()); print("uploaded", name)
asyncio.run(main())
