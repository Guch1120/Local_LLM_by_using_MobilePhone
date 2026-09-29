# iPhone Local Multimodal LLM Server

An iOS app that exposes a local, OpenAI-compatible inference API so a nearby PC can use models hosted on the iPhone. The app is designed to run in the foreground; inference data stays on device.

## Current implementation

- SwiftUI management screens for server status, imported models, settings, diagnostics, and logs.
- An authenticated HTTP server with `/health`, `/capabilities`, `/diagnostics`, `/metrics`, `/logs`, `/v1/models`, and `/v1/chat/completions` routes.
- Non-streaming and Server-Sent Events chat completions, including JPEG/PNG data URL parsing.
- Image inputs are orientation-corrected, resized to a 2048-pixel maximum edge, and recompressed as JPEG before inference.
- A `MockInferenceBackend` for API and UI development without a model or Apple Silicon.
- A persistent, 500-entry on-device diagnostic log with app lifecycle, model, inference, thermal, and error events. Prompt and image contents are not recorded.
- Model file import into Application Support with a streaming SHA-256 calculation.
- Saved generation defaults for output length, temperature, LiteRT context length, and experimental Multi-Token Prediction.
- A privacy manifest for app-local UserDefaults and model-file metadata access; no app tracking or collected data is declared.
- CI workflows for unsigned iOS Simulator builds on pull requests and signed TestFlight uploads when repository secrets are configured.

The app starts with the mock backend. LiteRT-LM is isolated behind `InferenceBackend` and pinned to Google's official Swift package v0.17.1. The adapter attempts Metal first and falls back to CPU if engine initialization fails. Google's Swift API is currently an early preview, so successful loading, image inference, and GPU acceleration still need confirmation on the iPhone. The package is distributed under Apache-2.0.

## Build

Open `iPhoneLocalAI.xcodeproj` in Xcode 26 or later, select the `iPhoneLocalAI` scheme, and build for an iOS Simulator or device. The project currently targets iOS 17 and Swift 5 language mode. Xcode 26 is required for App Store Connect uploads made after April 2026.

On a Mac with Xcode installed:

```bash
xcodebuild -project iPhoneLocalAI.xcodeproj \
  -scheme iPhoneLocalAI \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Use the development API

Keep the app in the foreground. The API key is shown on the Settings screen. Once a host-side USB port forward is available, set the OpenAI client base URL to `http://127.0.0.1:8080/v1` and use that key as the bearer token.

On Ubuntu, install `usbmuxd` and `libimobiledevice`, then forward the port:

```bash
iproxy 8080:8080
```

Check the server and list the active model:

```bash
curl http://127.0.0.1:8080/health
curl -H "Authorization: Bearer <API_KEY>" http://127.0.0.1:8080/v1/models
```

## Remote debugging without a Mac

The app must remain in the foreground while the API is in use. Once USB forwarding is connected, collect the single diagnostics bundle from Ubuntu:

```bash
curl -fsS -H "Authorization: Bearer <API_KEY>" \
  http://127.0.0.1:8080/diagnostics | tee iphone-diagnostics.json | jq .
```

The bundle includes the app version, build number, Git revision, iOS version, server/model state, memory and thermal metrics, inference timings, log-storage health, and up to 200 recent log entries. Logs survive app relaunches and retain at most 500 entries on the iPhone. They contain lifecycle and error descriptions but not prompt text or image data. The API key is never included in the bundle.

For a smaller live view, use `GET /health`, `GET /metrics`, or `GET /logs`. All except `/health` require the bearer token. The Settings screen shows the API key; rotate it there if it is exposed.

GitHub Actions attaches the source revision to each built app, so a diagnostics bundle identifies the exact commit running on the phone. Pushes to `iphone` or `main` run the unsigned Simulator build workflow. After Apple Developer Program approval and a TestFlight install, the same USB-forwarded endpoints can be used to report app behavior from Ubuntu without Xcode. This remote path provides application logs and health/performance state; LLDB breakpoints, view hierarchy inspection, Metal debugging, and Instruments still require a Mac.

The OpenAI Python client can use the active model ID returned by `/v1/models`:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="<API_KEY>")
response = client.chat.completions.create(
    model="mock-echo",  # replace with the ID returned by /v1/models
    messages=[{"role": "user", "content": "Hello from Ubuntu"}],
)
print(response.choices[0].message.content)
```

The mock backend returns deterministic text and does not load imported model files. Imported `.litertlm` files can be selected for the LiteRT backend. Physical-device model inference, LiteRT GPU operation, USB forwarding, and TestFlight upload still need verification.

## GitHub Actions secrets

The TestFlight workflow is manual and uses Xcode automatic signing with Apple's cloud-managed distribution certificates. Before running it, configure these repository secrets:

```text
APPSTORE_ISSUER_ID
APPSTORE_API_KEY_ID
APPSTORE_API_PRIVATE_KEY
APPLE_TEAM_ID
```

App Store Connect must contain an app record for bundle identifier `jp.localai.iphone-server`. The workflow passes the App Store Connect API key directly to `xcodebuild`; no distribution `.p12` or manually managed provisioning profile is stored in the repository or required as a GitHub secret.

## Project notes

- See [SPEC.md](SPEC.md) for scope and staged implementation.
- See [TESTFLIGHT_SETUP.md](TESTFLIGHT_SETUP.md) for Apple Developer, signing, GitHub Secrets, and TestFlight deployment setup.
- See [AGENTS.md](AGENTS.md) for repository rules and build commands.
- Never commit App Store Connect credentials, signing certificates, API keys, or model files.
