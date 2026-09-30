# iPhone Local Multimodal LLM Server — v0.1

## Goal

Use an iPhone as a local text and vision inference server for an Ubuntu PC. The API should appear OpenAI-compatible, use USB forwarding as the initial PC connection, keep inference data local, and run while the app is in the foreground. Gemma 4 E4B is the preferred model; E2B or another backend must remain possible if E4B is not viable.

## v0.1 scope

- SwiftUI status, model, settings, diagnostics, and log screens.
- An `InferenceBackend` protocol between HTTP adapters and inference implementations.
- Install models after app installation; store imports in Application Support and verify SHA-256.
- A model browser in the Models tab searches Hugging Face, lists the `.gguf` / `.litertlm` files of a repository with a memory-fit hint, and downloads the chosen files to the phone.
- OpenAI-compatible `GET /v1/models` and `POST /v1/chat/completions`, including text, JPEG/PNG base64 data URLs, and SSE streaming.
- Authenticated management routes: `/capabilities`, `/metrics`, and `/logs`; `/health` reports basic liveness.
- Keychain-backed bearer token, foreground HTTP server, memory and thermal diagnostics, request timing, and privacy-preserving ring-buffer logs.
- Text and synthetic-image benchmark actions in Diagnostics; results are also available from `/metrics`.
- Mock backend for development and CI without model downloads.
- GitHub Actions for iOS Simulator build/test and a separate signed TestFlight workflow.

## Out of scope

Camera capture, microphone/audio, speech recognition, TTS, embeddings, RAG, ROS, multiple simultaneously loaded models, unrestricted background serving, cloud telemetry, and public App Store release.

## Current stage

The SwiftUI app, foreground HTTP server, authenticated OpenAI API, MockBackend, `.litertlm` model import/verification, generation defaults, diagnostics, benchmark actions, and unit/integration tests are implemented. LiteRT-LM 0.17.1 is connected behind the backend protocol with Metal-first initialization and CPU fallback. The app and tests are developed primarily from Ubuntu and validated with the macOS GitHub Actions workflows because the local development environment has no Xcode toolchain. Verified on an iPhone 16 (iOS 26.4.2) on 2026-09-30: TestFlight upload and install, development-signed IPA install over USB, USB model transfer and SHA-256 registration, Gemma 4 E2B (`gemma-4-E2B-it.litertlm`) text inference on the Metal GPU backend (non-streaming, streaming, multi-turn, Japanese), automatic reload after restart, and access from Ubuntu with the OpenAI Python SDK through `iproxy`. Image input is not available yet: with LiteRT-LM 0.17.1 the GPU vision encoder fails on iOS (`STABLEHLO_COMPOSITE failed to prepare`) and the CPU vision encoder hung the request, matching upstream issues #2979 and #2370; the app therefore reports `image: false` and rejects image requests with `unsupported_modality`.

## API behavior

- All API routes except `/health` require `Authorization: Bearer <key>`.
- `POST /v1/chat/completions` accepts string content or an array containing text and `image_url` data URLs. If `model` names an installed model that is not active, the server loads it before generating (the request waits for the load); unknown models return `model_not_found`.
- The last successfully loaded model is loaded again automatically when the app starts. If the app was terminated during that automatic load, the next launch skips it once.
- Image payloads are limited to JPEG/PNG and 12 MiB before normalization to a 2048-pixel maximum edge JPEG.
- `.gguf` models run on the llama.cpp backend (Metal). A GGUF file whose name contains `mmproj` is stored as the multimodal projector of the most recently imported GGUF model and enables image input through libmtmd. Gemma 4 models (`general.architecture = gemma4`) are prompted with the Gemma 4 chat template (`<|turn>role ... <turn|>`); other models use the chat template stored in the GGUF file through llama.cpp's built-in template support, falling back to ChatML when the template is not recognized.
- When a llama.cpp model fails to load, the error message and the `model_load_failed` log entry include llama.cpp's last warnings and errors.
- LiteRT-LM models are text-only by default; use a GGUF model with an mmproj file for images. With LiteRT-LM 0.17.1 the GPU vision encoder always fails on iOS, and each failed attempt leaves address space behind that later model loads need, while the CPU vision encoder can hang indefinitely (LiteRT-LM issues #2979, #2370). At load time the backend tries GPU text, then CPU text. Launch with `LITERT_VISION_BACKEND=gpu` (GPU vision first) or `cpu` to experiment; `/capabilities` reports whether images are enabled.
- The app is signed with the Extended Virtual Addressing and Increased Memory Limit entitlements (`App/iPhoneLocalAI.entitlements`). Without the larger address space, memory-mapping a multi-gigabyte model fails (`mmap failed: Cannot allocate memory`) once another model has been loaded and unloaded in the same process.
- Model context length and Multi-Token Prediction are configurable; MTP is reported from the active LiteRT backend.
- `GET /models` lists the installed models (`id`, `name`, `backend`, `size_bytes`, `modalities`, `loaded`) and the Hugging Face downloads (`id`, `repository`, `file`, `state`, `received_bytes`, `total_bytes`, `error`, `model`). `POST /models/downloads` with `{"repository": "owner/name", "file": "model.gguf"}` (optional `revision`) queues a download and answers `202` with the download; an unknown repository or file, a file that is not a model, or too little free storage answers `400` with `download_failed`. States are `queued`, `downloading`, `importing`, `completed`, `failed`; downloads run one at a time, only while the app is in the foreground, and a failed download can be retried in the app.
- The app contacts `huggingface.co` only to search and download models when the user (or an API client) asks for it. An optional access token for gated repositories is stored in Keychain and sent only to Hugging Face. Inference data never leaves the device.
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
