# Agent instructions

## Project goal

Build a foreground iOS app that runs local text and image inference and exposes it to a PC through an authenticated OpenAI-compatible HTTP API. Local-first privacy is required.

## Architecture rules

- Route HTTP input through the OpenAI adapter into `InferenceRequest`, then through the `InferenceBackend` protocol.
- Do not reference LiteRT-LM from HTTP handlers, views, or model registry code.
- Keep model files outside the app bundle. Import them into Application Support and record a SHA-256 digest.
- Keep camera, audio, TTS, ROS, and cloud inference out of v0.1.
- Keep prompt text and image contents out of logs and metrics.
- Do not add telemetry, analytics, advertising, or remote crash reporting.
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
- Do not claim device, USB, LiteRT, or TestFlight verification until it has actually run.

## Dependency policy

Prefer Apple frameworks and Google's official LiteRT-LM distribution. Before adding a dependency, verify its license, source availability, maintenance status, and security impact from primary sources. Do not add model binaries to Git or the app target.
