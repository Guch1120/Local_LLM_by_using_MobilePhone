# Agent instructions

## Project goal

Build a foreground iOS app that runs local text and image inference and exposes it to a PC through an authenticated OpenAI-compatible HTTP API. Local-first privacy is required.

## Architecture rules

- Route HTTP input through the OpenAI adapter into `InferenceRequest`, then through the `InferenceBackend` protocol.
- Do not reference LiteRT-LM from HTTP handlers, views, or model registry code.
- Keep model files outside the app bundle. Import them into Application Support and record a SHA-256 digest.
- Keep camera, audio, TTS, ROS, and cloud inference out of v0.1.
- Keep prompt text and image contents out of logs and metrics.
- Do not add telemetry, analytics, advertising, or remote crash reporting. The only outbound connections are to `huggingface.co`, to search and download models when the user asks for it.
- Keep LAN exposure opt-in; do not silently expose the API to the local network.
- Do not commit secrets, provisioning profiles, signing certificates, or model files.
- Keep the API and errors documented when their behavior changes.

## Build and verification

- Open `iPhoneLocalAI.xcodeproj` with Xcode 26 or later for builds intended for App Store Connect upload.
- Build: `xcodebuild -project iPhoneLocalAI.xcodeproj -scheme iPhoneLocalAI -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
- Test: `xcodebuild -project iPhoneLocalAI.xcodeproj -scheme iPhoneLocalAI -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test`
- Lint: `swiftlint lint --quiet`
- Linux development cannot run Xcode or validate iOS frameworks; rely on the macOS GitHub Actions workflow until a Mac runner is available.
- Run lint, build, and tests before committing when macOS CI is available. Do not mark them as passing unless the command or GitHub Actions run completed successfully.
- The repository is public, so workflow logs and artifacts are visible to anyone: keep device UDIDs, signing material, and keys in secrets, and keep the development IPA encrypted. macOS runs are slow; avoid needless pushes of app sources (each triggers a dev build), batch related changes into one push, and start `pull-request.yml` or `testflight.yml` manually only when needed.
- Do not claim device, USB, LiteRT, or TestFlight verification until it has actually run.

## Physical iPhone verification (USB)

Use these helpers for device checks from Ubuntu:

- Connection check: `bash scripts/iphone/check.sh`
- Screenshot: `bash scripts/iphone/screenshot.sh` (latest image: `artifacts/iphone/latest.png`)
- iPhone logs: `bash scripts/iphone/syslog.sh`
- HTTP API: run `bash scripts/iphone/proxy.sh` in a separate terminal (`127.0.0.1:8080 -> iPhone:8080`)
- Screens: the app accepts launch arguments so a screen can be opened and checked with a screenshot without touching the phone, for example `APP_ARGS="-initialTab models -modelBrowserQuery gemma" bash scripts/iphone/launch.sh` (tabs: `server`, `models`, `settings`, `diagnostics`, `logs`; `-modelBrowserRepository owner/name` opens a repository's file list).
- Screen contents: `pymobiledevice3 developer accessibility list-items` prints the labels of the elements on screen. It works when the phone's display is off or locked, where screenshots come out black.
- Models on the phone: `GET /models` lists installed models and downloads; `POST /models/downloads` makes the phone download a file from Hugging Face.
- App stdout/stderr: `bash scripts/iphone/launch.sh [MODEL_ID]` relaunches the app and streams its output. llama.cpp and LiteRT-LM report load errors only there. With `MODEL_ID` the app loads that model at launch, without the API key or a tap on the phone.
- API key: `source scripts/iphone/get_api_key.sh` (reads the key copied in the app into `API_KEY`; never print it)
- Hugging Face models: `bash scripts/iphone/hf_model.sh REPO` lists the model files of a repository; with file names it downloads them to `~/models/` and pushes them to the phone. `bash scripts/iphone/try_model.sh MODEL_ID ["PROMPT"] [IMAGE]` sends a test request and prints the reply and speed.
- Model transfer: `bash scripts/iphone/push_model.sh PATH/TO/model.litertlm` (or `model.gguf mmproj.gguf`) uploads into the app's Documents folder; the app moves it into Application Support on launch. Keep model files outside the repository.
- Install app changes: push to `iphone`, then `bash scripts/iphone/install_dev_build.sh --wait` installs the development-signed IPA from the `iOS dev build` workflow over USB. Use the manual TestFlight workflow only for distribution builds.
- The helpers need only `pymobiledevice3` (user-level pip install); `iproxy`, `idevice_id`, and `idevicesyslog` are used when installed. `install_dev_build.sh` also needs an authenticated `gh` and the `DEV_IPA_PASSWORD` value.

## Dependency policy

Prefer Apple frameworks and Google's official LiteRT-LM distribution. Before adding a dependency, verify its license, source availability, maintenance status, and security impact from primary sources. Do not add model binaries to Git or the app target.
