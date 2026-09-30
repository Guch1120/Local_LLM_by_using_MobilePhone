# iPhone USB Development Setup (Ubuntu)

This guide documents the verified Linux-side setup for connecting a physical iPhone over USB so a coding agent can inspect the screen, collect logs, and access the app's HTTP API without using a Mac for day-to-day checks.

## Verified environment

The following combination was verified successfully:

- Ubuntu 22.04
- Python 3.10
- pymobiledevice3 11.19.4
- iOS 26.4.2
- USB connection through a hub
- Developer Mode enabled on the iPhone
- DeveloperDiskImage mounted with pymobiledevice3
- CoreDevice screenshot capture working

The exact package versions do not have to match, but newer iOS releases may require a recent pymobiledevice3.

## 1. Install host tools

On a fresh Ubuntu development PC:

```bash
sudo apt update
sudo apt install -y \
  usbmuxd \
  libimobiledevice-utils \
  libusbmuxd-tools \
  python3-pip

python3 -m pip install --user -U pymobiledevice3
```

Only `pymobiledevice3` is required by the helper scripts. On a PC where `sudo` is not available, skip the `apt` packages if `usbmuxd` is already running (`systemctl is-active usbmuxd`): the scripts then use `pymobiledevice3` for port forwarding and syslog instead of `iproxy` and `idevicesyslog`. To keep it apart from other Python packages, it can also be installed into its own virtual environment:

```bash
python3 -m venv ~/.local/share/pymobiledevice3-venv
~/.local/share/pymobiledevice3-venv/bin/pip install -U pymobiledevice3
ln -sf ~/.local/share/pymobiledevice3-venv/bin/pymobiledevice3 ~/.local/bin/pymobiledevice3
```

If `pymobiledevice3` is not found after installation, ensure `~/.local/bin` is in `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add the same line to `~/.bashrc` if necessary.

## 2. Connect and trust the iPhone

1. Unlock the iPhone.
2. Connect it to the Ubuntu PC over USB.
3. Choose **Trust** on the iPhone if prompted.
4. Enter the iPhone passcode when requested.

Trust/pairing is host-specific, so repeat this on each development PC.

Check physical USB detection:

```bash
lsusb | grep -i apple
```

Check usbmuxd:

```bash
systemctl status usbmuxd --no-pager
```

Check that both toolchains can see the phone:

```bash
pymobiledevice3 usbmux list
idevice_id -l
```

A working connection shows the iPhone in the JSON output from `pymobiledevice3 usbmux list` and returns a device identifier from `idevice_id -l`.

### If the iPhone is visible in the file manager but not in usbmuxd

Restart usbmuxd and retry:

```bash
sudo systemctl restart usbmuxd
pymobiledevice3 usbmux list
idevice_id -l
```

This recovered the verified setup when `lsusb` and the Ubuntu file manager could see the iPhone but `pymobiledevice3 usbmux list` returned `[]`.

For more detail:

```bash
lsusb -t
sudo journalctl -u usbmuxd -b -n 100 --no-pager -o cat
```

## 3. Reveal and enable Developer Mode

Check the current state:

```bash
pymobiledevice3 amfi developer-mode-status
```

If Developer Mode is disabled and the option is not visible on the iPhone:

```bash
pymobiledevice3 amfi reveal-developer-mode
```

Then on the iPhone open:

```text
Settings
  -> Privacy & Security
  -> Developer Mode
```

Enable Developer Mode. The iPhone will restart. After reboot, confirm the second Developer Mode prompt and enter the passcode.

Do not remove the device passcode just to run:

```bash
pymobiledevice3 amfi enable-developer-mode
```

On a passcode-protected phone that command can fail with:

```text
Cannot enable developer-mode when passcode is set
```

In that case, use `reveal-developer-mode` and enable it manually on the iPhone.

## 4. Mount DeveloperDiskImage

After Developer Mode is enabled:

```bash
pymobiledevice3 mounter auto-mount
```

A successful setup prints:

```text
DeveloperDiskImage mounted successfully
```

This is required for CoreDevice developer services such as screen capture.

## 5. Verify screenshot capture

Capture a PNG:

```bash
pymobiledevice3 developer core-device screen-capture screenshot iphone.png
```

Inspect it:

```bash
file iphone.png
xdg-open iphone.png
```

The verified setup produced a native iPhone screenshot successfully through CoreDevice.

## 6. Repository helper scripts

The repository contains:

```text
scripts/iphone/
  check.sh
  screenshot.sh
  syslog.sh
  proxy.sh
  launch.sh
  hf_model.sh
  try_model.sh
```

Run them with `bash` on any checkout:

```bash
bash scripts/iphone/check.sh
bash scripts/iphone/screenshot.sh
bash scripts/iphone/syslog.sh
bash scripts/iphone/proxy.sh
```

If desired, make them executable locally:

```bash
chmod +x scripts/iphone/*.sh
```

### check.sh

Checks required commands, usbmuxd state, USB device visibility, Developer Mode, and performs a non-destructive CoreDevice readiness check where possible.

```bash
bash scripts/iphone/check.sh
```

### screenshot.sh

Mounts the DeveloperDiskImage if necessary and stores a timestamped screenshot under:

```text
artifacts/iphone/screenshots/
```

It also updates:

```text
artifacts/iphone/latest.png
```

Example:

```bash
bash scripts/iphone/screenshot.sh
xdg-open artifacts/iphone/latest.png
```

### syslog.sh

Streams iPhone syslog output and saves a copy under:

```text
artifacts/iphone/logs/
```

Raw log:

```bash
bash scripts/iphone/syslog.sh
```

Optional text filter:

```bash
bash scripts/iphone/syslog.sh "iPhoneLocalAI"
```

Stop with Ctrl-C.

### proxy.sh

Forwards a local Ubuntu TCP port to the same port on the iPhone through usbmuxd. It uses `iproxy` when installed and `pymobiledevice3 usbmux forward` otherwise.

Default:

```bash
bash scripts/iphone/proxy.sh
```

This maps:

```text
Ubuntu 127.0.0.1:8080 -> iPhone:8080
```

Custom ports:

```bash
bash scripts/iphone/proxy.sh 18080 8080
```

Then verify the app server:

```bash
curl http://127.0.0.1:8080/health
```

Keep `proxy.sh` running while the host accesses the iPhone API. The iPhone app must also be open in the foreground with its HTTP server started; otherwise `curl` will report connection refused even if USB pairing is healthy.

### launch.sh

Relaunches the app and streams its stdout/stderr, which is where llama.cpp and LiteRT-LM report why a model failed to load. The output is also saved under `artifacts/iphone/logs/`.

```bash
bash scripts/iphone/launch.sh
bash scripts/iphone/launch.sh gemma-4-e2b-it-q4_0
```

`pymobiledevice3 developer accessibility list-items` prints the labels of the elements on screen, which is a quick way to check what a screen shows.

Restart the app with this script rather than with `pymobiledevice3 developer dvt launch` directly: that command kills the running instance and starts a new one at once, and the new instance then shows a black screen although it keeps serving the API. The helper scripts stop the app, wait a few seconds, and launch with `--no-kill-existing`.

With a model ID (as listed in the app's Models screen), the app loads that model at launch. The ID is passed as a launch argument that overrides the remembered model for this launch only, so neither the API key nor a tap on the phone is needed. Stop with Ctrl-C; the app keeps running.

## 7. Recommended coding-agent workflow

A useful test loop is:

```text
Edit code
  -> push/build/TestFlight update when needed
  -> launch app on iPhone
  -> screenshot.sh
  -> inspect artifacts/iphone/latest.png
  -> syslog.sh when runtime detail is needed
  -> proxy.sh + curl for API checks
  -> fix code
```

For an agent, useful commands are:

```bash
bash scripts/iphone/check.sh
bash scripts/iphone/screenshot.sh
curl http://127.0.0.1:8080/health
```

Run `bash scripts/iphone/proxy.sh` in another terminal before the curl request.

## Troubleshooting quick reference

### `ERROR Device is not connected`

Check:

```bash
lsusb | grep -i apple
pymobiledevice3 usbmux list
idevice_id -l
```

If USB is physically visible but usbmuxd reports no phone:

```bash
sudo systemctl restart usbmuxd
```

Then unlock/reconnect the phone and retry.

### `Developer Mode is disabled`

Run:

```bash
pymobiledevice3 amfi reveal-developer-mode
```

Then enable Developer Mode manually on the iPhone and reboot.

### DeveloperDiskImage is not mounted

Run:

```bash
pymobiledevice3 mounter auto-mount
```

### CoreDevice/tunnel error

pymobiledevice3 automatically retries modern developer commands using its tunnel mechanism when required. If a future version requires an explicit tunnel daemon, inspect:

```bash
pymobiledevice3 remote --help
pymobiledevice3 developer --help
```

Do not hard-code a tunneld invocation into automation unless the installed pymobiledevice3 version actually requires it.

## Security notes

- Do not commit device pairing records, Apple credentials, API keys, provisioning files, or captured private screen/log content.
- `artifacts/iphone/` is gitignored.
- The iPhone must remain unlocked for some developer operations.
- Developer Mode intentionally increases the device's development attack surface; keep normal device security controls enabled.
