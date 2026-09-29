# iPhone Local Multimodal LLM Server — v0.1

## Goal

Use an iPhone as a local text and vision inference server for an Ubuntu PC. The API should appear OpenAI-compatible, use USB forwarding as the initial PC connection, keep inference data local, and run while the app is in the foreground. Gemma 4 E4B is the preferred model; E2B or another backend must remain possible if E4B is not viable.

## v0.1 scope

- SwiftUI status, model, settings, diagnostics, and log screens.
- An `InferenceBackend` protocol between HTTP adapters and inference implementations.
- Install models after app installation; store imports in Application Support and verify SHA-256.
- OpenAI-compatible `GET /v1/models` and `POST /v1/chat/completions`, including text, JPEG/PNG base64 data URLs, and SSE streaming.
- Authenticated management routes: `/capabilities`, `/metrics`, and `/logs`; `/health` reports basic liveness.
- Keychain-backed bearer token, foreground HTTP server, memory and thermal diagnostics, request timing, and privacy-preserving ring-buffer logs.
- Text and synthetic-image benchmark actions in Diagnostics; results are also available from `/metrics`.
- Mock backend for development and CI without model downloads.
- GitHub Actions for iOS Simulator build/test and a separate signed TestFlight workflow.

## Out of scope

Camera capture, microphone/audio, speech recognition, TTS, embeddings, RAG, ROS, multiple simultaneously loaded models, unrestricted background serving, cloud telemetry, and public App Store release.

## Current stage

The SwiftUI app, foreground HTTP server, authenticated OpenAI API, MockBackend, `.litertlm` model import/verification, generation defaults, diagnostics, benchmark actions, and unit/integration tests are implemented. LiteRT-LM 0.17.1 is connected behind the backend protocol with Metal-first initialization and CPU fallback. The app and tests are developed primarily from Ubuntu and validated with the macOS GitHub Actions workflows because the local development environment has no Xcode toolchain. Verified on an iPhone 16 Pro Max (iOS 26.4.2) on 2026-09-30: TestFlight upload and install, development-signed IPA install over USB, USB model transfer and SHA-256 registration, Gemma 4 E2B (`gemma-4-E2B-it.litertlm`) text inference on the Metal GPU backend (non-streaming, streaming, multi-turn, Japanese), automatic reload after restart, and access from Ubuntu with the OpenAI Python SDK through `iproxy`. Image input is not available yet: with LiteRT-LM 0.17.1 the GPU vision encoder fails on iOS (`STABLEHLO_COMPOSITE failed to prepare`) and the CPU vision encoder hung the request, matching upstream issues #2979 and #2370; the app therefore reports `image: false` and rejects image requests with `unsupported_modality`.

## API behavior

- All API routes except `/health` require `Authorization: Bearer <key>`.
- `POST /v1/chat/completions` accepts string content or an array containing text and `image_url` data URLs. If `model` names an installed model that is not active, the server loads it before generating (the request waits for the load); unknown models return `model_not_found`.
- The last successfully loaded model is loaded again automatically when the app starts. If the app was terminated during that automatic load, the next launch skips it once.
- Image payloads are limited to JPEG/PNG and 12 MiB before normalization to a 2048-pixel maximum edge JPEG.
- Image input with LiteRT-LM on iOS depends on the GPU vision encoder. At load time the backend tries GPU text + GPU vision, then GPU text without vision, then CPU text without vision, and keeps the first configuration that can open a conversation; `/capabilities` reports whether images are enabled. The CPU vision encoder is not used by default because it can hang indefinitely on iOS (LiteRT-LM issues #2979, #2370); launch with `LITERT_VISION_BACKEND=cpu` (or `none`) to override.
- Model context length and Multi-Token Prediction are configurable; MTP is reported from the active LiteRT backend.
- Logs omit prompt and image contents.
- The current mock backend is named `mock-echo`; compatible `.litertlm` files are loaded through LiteRT-LM (text inference verified on device; image input see Current stage).

## Staged implementation

1. **Skeleton:** SwiftUI app, foreground HTTP server, health endpoint, mock backend, macOS CI build.
2. **OpenAI server:** model listing, chat completions, streaming, auth, parser/error/metrics tests.
3. **LiteRT text:** model load/unload, Gemma text inference and measurements.
4. **Vision:** data URL image inference; use E2B if E4B multimodal support blocks progress.
5. **USB:** verify `iproxy` and OpenAI Python SDK from Ubuntu against a physical iPhone.
6. **TestFlight:** signed archive and App Store Connect upload using repository secrets.
7. **Diagnostics:** benchmark, thermal/memory review, and repeated generation on device.
