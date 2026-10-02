# iPhone Local Multimodal LLM Server — v0.1

## Goal

Use an iPhone as a local text and vision inference server for an Ubuntu PC. The API should appear OpenAI-compatible, use USB forwarding as the initial PC connection, keep inference data local, and run while the app is in the foreground. Gemma 4 E4B is the preferred model; E2B or another backend must remain possible if E4B is not viable.

## v0.1 scope

- SwiftUI status, model, settings, diagnostics, and log screens.
- An `InferenceBackend` protocol between HTTP adapters and inference implementations.
- Install models after app installation; store imports in Application Support and verify SHA-256.
- A model browser in the Models tab searches Hugging Face by name, format and use (text, or image + text), lists the `.gguf` / `.litertlm` files of a repository with a memory-fit hint, and downloads the chosen files to the phone. A GGUF model can be downloaded together with its image projector (mmproj), which is then attached to that model. Multi-token-prediction helper files (`mtp-*.gguf`) are listed as not usable on their own: llama.cpp only loads them next to their main model, which the app does not support.
- OpenAI-compatible `GET /v1/models` and `POST /v1/chat/completions`, including text, JPEG/PNG base64 data URLs, and SSE streaming.
- Authenticated management routes: `/capabilities`, `/metrics`, and `/logs`; `/health` reports basic liveness.
- Keychain-backed bearer token, foreground HTTP server, memory and thermal diagnostics, request timing, and privacy-preserving ring-buffer logs.
- Text and synthetic-image benchmark actions in Diagnostics; results are also available from `/metrics`.
- Mock backend for development and CI without model downloads.
- GitHub Actions for iOS Simulator build/test and a separate signed TestFlight workflow.

## Out of scope

Speech output (TTS), standalone speech recognition (audio is only an input of a multimodal model), embeddings, RAG, ROS, multiple simultaneously loaded models, unrestricted background serving, cloud telemetry, and public App Store release.

## Current stage

The SwiftUI app, foreground HTTP server, authenticated OpenAI API, MockBackend, `.litertlm` model import/verification, generation defaults, diagnostics, benchmark actions, and unit/integration tests are implemented. LiteRT-LM 0.17.1 is connected behind the backend protocol with Metal-first initialization and CPU fallback. The app and tests are developed primarily from Ubuntu and validated with the macOS GitHub Actions workflows because the local development environment has no Xcode toolchain. Verified on an iPhone 16 (iOS 26.4.2) on 2026-09-30: TestFlight upload and install, development-signed IPA install over USB, USB model transfer and SHA-256 registration, Gemma 4 E2B (`gemma-4-E2B-it.litertlm`) text inference on the Metal GPU backend (non-streaming, streaming, multi-turn, Japanese), automatic reload after restart, and access from Ubuntu with the OpenAI Python SDK through `iproxy`. Image input does not work with LiteRT-LM 0.17.1 on iOS: the GPU vision encoder fails (`STABLEHLO_COMPOSITE failed to prepare`) and the CPU vision encoder hung the request, matching upstream issues #2979 and #2370, so LiteRT-LM models report `image: false` and reject image requests with `unsupported_modality`. Image input runs on the llama.cpp backend instead. Verified on the same iPhone 16 with build 12: text and image requests to Gemma 4 E2B (`gemma-4-E2B-it-Q4_0.gguf` with `mmproj-gemma-4-E2B-it-Q8_0.gguf`) on Metal; twenty consecutive switches between two LiteRT-LM models and two GGUF models without a failed load (before the Extended Virtual Addressing entitlement the first switch from LiteRT-LM to GGUF failed); a non-Gemma model (Qwen2.5 0.5B) answering through its own chat template; a model downloaded from Hugging Face by the phone itself through `POST /models/downloads`, registered and used; and the model browser's search and repository screens.

Measured on the iPhone 16 with build 14, Gemma 4 E2B Q4_0 with the Q8_0 projector on llama.cpp/Metal, 128 output tokens, streaming over USB (thermal state nominal, about 800 MB app memory):

| Input | Time to first token | Generation |
| --- | --- | --- |
| Text only | 0.1–0.2 s | 29–30 tokens/s |
| Image 320×240 | 0.7 s | 31 tokens/s |
| Image 640×480 | 1.4 s | 30 tokens/s |
| Image 1920×1440 | 2.7 s | 30 tokens/s |

An image adds to the time before the first token (encoding the picture and evaluating its tokens); generation speed stays the same. The first request after a model switch also waits for the load, about 3 s for this model.

### Context window and conversation length

Measured on the iPhone 16 on 2026-10-01 (builds 24 and 25) with Gemma 4 E2B Q4_0 and the Q8_0 projector on llama.cpp/Metal, through `scripts/iphone/measure_turns.py`. Token counts are the tokenizer's own, taken from `usage`.

- **Model limit and KV cache.** The model supports 131,072 tokens (`gemma4.context_length`). The app starts it with the context size from Settings; the choices 1024, 2048, 4096 and 8192 were fixed in the first commit without a recorded reason and are not a model or memory limit. The KV cache costs 18 KiB per token (the 3 full-attention layers take 6 KiB per token together and the 12 sliding-window layers 12 KiB, because llama.cpp keeps the window cache full-size): 72 MiB at 4096 and 144 MiB at 8192, read from the llama.cpp load log; the compute buffer (518 MiB) does not grow with the context. The app's memory was about 810 MB at 4096 and 823 MB at 8192. llama.cpp rounds the size up to a multiple of 256; there is no power-of-two requirement, and the output token limit is only a stop condition.
- **Image cost.** With llama.cpp's defaults for Gemma 4 (40 to 280 image tokens) one image costs 52 tokens at 320×240 and below, 134 at 640×480 and 270 from 1280×960 up (markers included). Upscaling a small picture did not help: the same picture at 1280×960 was described worse than at 640×480.
- **Turns that fit in 4096 tokens.**

| Conversation | Growth per turn | Turns until the context was full |
| --- | --- | --- |
| Text only, short replies (about 45 tokens) | 75 tokens | 54 |
| Text only, replies of 150 tokens | about 155 tokens | about 27 (from a 21-turn run, extrapolated) |
| A 640×480 image in every turn, short replies | 205 tokens | 20 |

The turn counts scale with the context: twice the turns at 8192. They depend on the reply length and, with images, on the image size (270 tokens per image from 1280×960 up).

- **Latency grows with the conversation.** Every request evaluates the whole history again, including every image, because the server keeps no cache between requests: a turn took 1.6 s at the start and 29 s at 3900 tokens (text only), and 2.7 s and 40 s with an image in each of 20 turns. Prompt evaluation runs at about 200 tokens per second; decoding slows from 31 to about 21 tokens per second as the context fills and the phone warms up. Reusing the cache of the common prefix would make a turn cost only its new tokens.
- **Memory of earlier turns.** In a 54-turn text conversation, 26 of 26 questions about what was said in earlier turns were answered correctly up to the full 4096 tokens. Three facts planted at the start, middle and end of a 3264-token conversation (context 4096) and of a 6971-token one (context 8192) were all repeated correctly (35 s to read the 6971 tokens).
- **Heat.** The thermal level reached "serious" within one to two minutes of continuous use while the battery rose only from 36 to 37 C, and the decode speed at "serious" was 28 to 29 tokens per second against 30 when cool. By the end of a long run the battery was at 39 to 40 C. iOS gives apps no temperature in degrees; `scripts/iphone/temperature.sh` reads the battery temperature over USB, which is a weak proxy for the chip.

**Quality of the answers (Gemma 4 E2B Q4_0, temperature 0).** A robot-planning conversation of 8 turns was coherent and followed the limits asked for (three steps, two points, one word). Asked for an exhaustive list of the objects in `test.png` (10 items on a table), the model found about half and invented items: with free wording it missed the red bowl and the orange cup and called the spoons knives; when the question named the categories it found all ten but also reported two knives that are not there. Counts and "how many red objects" questions were wrong. Plan on prompts that name the categories, structured output and a check of the result, or a larger model.

## API behavior

- All API routes except `/health` require `Authorization: Bearer <key>`.
- `POST /v1/chat/completions` accepts string content or an array containing text and `image_url` data URLs. If `model` names an installed model that is not active, the server loads it before generating (the request waits for the load); unknown models return `model_not_found`.
- The last successfully loaded model is loaded again automatically when the app starts. If the app was terminated during that automatic load, the next launch skips it once.
- A reply ends when the model stops or when it reaches the output limit: `max_tokens` of the request, else the default in Settings (512), and never more than what is left of the context. With a llama.cpp model a reply cut off by the limit has `finish_reason: "length"` (otherwise `"stop"`), and the live view says so; LiteRT-LM does not report it and always answers `"stop"`.
- Image payloads are limited to JPEG/PNG and 12 MiB before normalization to a 2048-pixel maximum edge JPEG.
- `.gguf` models run on the llama.cpp backend (Metal). A GGUF file whose name contains `mmproj` is stored as the multimodal projector of the most recently imported GGUF model and enables image input through libmtmd. Gemma 4 models (`general.architecture = gemma4`) are prompted with the Gemma 4 chat template (`<|turn>role ... <turn|>`); other models use the chat template stored in the GGUF file through llama.cpp's built-in template support, falling back to ChatML when the template is not recognized.
- When a llama.cpp model fails to load, the error message and the `model_load_failed` log entry include llama.cpp's last warnings and errors. A load logs `model_verifying`, `model_unloading_previous`, `model_backend_loading` and `model_loaded` in turn, so a load that never returns shows where it stopped.
- stdout and stderr never block the app: when it was started from a PC and nothing reads its output any more, the output is dropped. llama.cpp debug messages, which contain the prompt text, are not written to stderr.
- LiteRT-LM models are text-only by default; use a GGUF model with an mmproj file for images. With LiteRT-LM 0.17.1 the GPU vision encoder always fails on iOS, and each failed attempt leaves address space behind that later model loads need, while the CPU vision encoder can hang indefinitely (LiteRT-LM issues #2979, #2370). At load time the backend tries GPU text, then CPU text. Launch with `LITERT_VISION_BACKEND=gpu` (GPU vision first) or `cpu` to experiment; `/capabilities` reports whether images are enabled.
- The app is signed with the Extended Virtual Addressing and Increased Memory Limit entitlements (`App/iPhoneLocalAI.entitlements`). Without the larger address space, memory-mapping a multi-gigabyte model fails (`mmap failed: Cannot allocate memory`) once another model has been loaded and unloaded in the same process.
- `usage` in a chat response and `/metrics` carry exact token counts for llama.cpp models (`token_counts_estimated: false`); LiteRT-LM models and the mock backend still get a word-count estimate. With `stream_options: {"include_usage": true}` a streaming response ends with a chunk that has empty `choices` and the `usage`.
- `/capabilities` and `/metrics` report `context_tokens`, the window the loaded model was started with (null when nothing is loaded); a request whose prompt does not fit is rejected at once with HTTP 400, type `context_length_exceeded`, and a message that states both numbers (prompt tokens and context), so a client can shorten the history and send it again. Changing the context size in Settings reloads the loaded model, for llama.cpp as well.
- Thermal pause: requests get 503 (`thermal_limit`) while the thermal state is `critical`. The Settings choice "発熱時の動作" makes the app pause from `serious` on instead (default: `critical` only, because `serious` only lowers the speed).
- Model context length and Multi-Token Prediction are configurable; MTP is reported from the active LiteRT backend.
- `GET /models` lists the installed models (`id`, `name`, `backend`, `size_bytes`, `modalities`, `loaded`) and the Hugging Face downloads (`id`, `repository`, `file`, `state`, `received_bytes`, `total_bytes`, `error`, `model`). `POST /models/downloads` with `{"repository": "owner/name", "file": "model.gguf"}` (optional `revision`) queues a download and answers `202` with the download; an unknown repository or file, a file that is not a model, or too little free storage answers `400` with `download_failed`. States are `queued`, `downloading`, `importing`, `completed`, `failed`; downloads run one at a time, only while the app is in the foreground, and a failed download can be retried in the app.
- The app contacts `huggingface.co` only to search and download models when the user (or an API client) asks for it. An optional access token for gated repositories is stored in Keychain and sent only to Hugging Face. Inference data never leaves the device.
- Logs omit prompt and image contents.
- The Chat tab runs the model on the phone without a PC: pick an installed model, then type text and, when the loaded model accepts them, attach photos (library or camera) and audio (a microphone recording of up to 30 seconds, or the first 30 seconds of an audio file, converted to WAV). The attach buttons follow what the loaded model accepts; with Gemma 4 and its mmproj that is text, image and audio. Chat requests go through the same inference path as API requests (thermal pause, context limit, metrics) and send the whole conversation each turn. The conversation, photos and recordings stay in memory and are not stored or logged; "新しい会話" clears them.
- Audio input: llama.cpp models whose projector has an audio encoder (`mtmd_support_audio`) take audio clips through the same media marker as images; libmtmd decodes WAV, MP3 and FLAC and resamples them. The API accepts OpenAI's `input_audio` content part (`{"type": "input_audio", "input_audio": {"data": "<base64>", "format": "wav"}}`, also `mp3` and FLAC), checked by its bytes and limited to 12 MiB; `/capabilities` reports `audio: true` for such a model, and requests with audio to other models get `unsupported_modality`. After a model with a projector is loaded, its registry entry records whether it took images and audio, which the Models tab shows.
- Verified on the iPhone 16 with build 28 (2026-10-02), Gemma 4 E2B Q4_0 with the Q8_0 projector, through `input_audio`: a 13-second speech recording (22.05 kHz FLAC) was transcribed word for word except one dropped "yes" in the speaker's own words, and a 10-second LibriSpeech sentence (16 kHz FLAC) correctly except "flour fattened sauce" heard as "flour fat and sauce"; a Japanese summary of the first clip was correct. A 13-second clip cost about 330 prompt tokens and a 10-second one about 265; each request took 2.4 to 2.5 s with the model loaded. The Chat tab offered text, image and audio for this model and text only for Qwen2.5 0.5B.
- In the Chat tab, "PC からのリクエスト" shows the request from the PC that is running or ran last: the last user message, its images, and the reply as it is generated, with the time to the first token and the generation speed. This live view exists only on the screen and in memory; it is replaced by the next request and is never written to logs, metrics or storage.
- The current mock backend is named `mock-echo`; compatible `.litertlm` files are loaded through LiteRT-LM (text inference verified on device; image input see Current stage).

## Staged implementation

1. **Skeleton:** SwiftUI app, foreground HTTP server, health endpoint, mock backend, macOS CI build.
2. **OpenAI server:** model listing, chat completions, streaming, auth, parser/error/metrics tests.
3. **LiteRT text:** model load/unload, Gemma text inference and measurements.
4. **Vision:** data URL image inference; use E2B if E4B multimodal support blocks progress.
5. **USB:** verify `iproxy` and OpenAI Python SDK from Ubuntu against a physical iPhone.
6. **TestFlight:** signed archive and App Store Connect upload using repository secrets.
7. **Diagnostics:** benchmark, thermal/memory review, and repeated generation on device.
