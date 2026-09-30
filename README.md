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

The app starts with the mock backend. LiteRT-LM is isolated behind `InferenceBackend` and pinned to Google's official Swift package v0.17.1. The adapter attempts Metal first and falls back to CPU if engine initialization fails. Text inference with Gemma 4 E2B on the Metal GPU backend has been verified on an iPhone 16 Pro Max. LiteRT-LM 0.17.1's vision encoder does not run on iOS (see SPEC.md), so image input uses a second backend: llama.cpp (MIT, official Apple XCFramework `b10456` with libmtmd — the last release that still ships the iOS Simulator slice, pinned in `Packages/LlamaCpp`). `.gguf` models run on llama.cpp with Metal; an `mmproj` GGUF imported after its model enables images. The LiteRT-LM package is distributed under Apache-2.0.

For Gemma 4 E2B with image input, use `ggml-org/gemma-4-E2B-it-GGUF` (Apache-2.0):

```bash
bash scripts/iphone/push_model.sh ~/models/gemma-4-E2B-it-Q4_0.gguf ~/models/mmproj-gemma-4-E2B-it-Q8_0.gguf
```

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

GitHub Actions attaches the source revision to each built app, so a diagnostics bundle identifies the exact commit running on the phone. Pull requests run SwiftLint on Linux and the Simulator build/tests on macOS; the workflow can also be started manually. Pushes to `iphone` that change app sources build a development-signed IPA. After Apple Developer Program approval and a TestFlight install, the same USB-forwarded endpoints can be used to report app behavior from Ubuntu without Xcode. This remote path provides application logs and health/performance state; LLDB breakpoints, view hierarchy inspection, Metal debugging, and Instruments still require a Mac.

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

The mock backend returns deterministic text and does not load imported model files. Imported `.litertlm` files can be selected for the LiteRT backend. Physical-device text inference on the GPU, USB forwarding, and TestFlight upload have been verified; image input is not yet available on iOS.


## Ubuntu から iPhone 実機を確認する

Ubuntu 開発PCから USB 接続した iPhone の状態確認、スクリーンショット取得、syslog 取得、HTTP API のポート転送を行うための補助スクリプトを `scripts/iphone/` に用意しています。

```text
scripts/iphone/
  check.sh        # USB接続・Developer Mode・CoreDevice の確認
  screenshot.sh   # iPhone画面をPNGとして取得
  syslog.sh       # iPhoneのsystem logを取得
  proxy.sh        # USB経由でPC側ポートをiPhoneへ転送
  get_api_key.sh  # iPhoneのクリップボードからAPIキーを読み込む
  install_dev_build.sh  # CIの開発ビルドをUSBでインストールして起動
  push_model.sh   # .litertlmモデルをUSBでアプリへ転送して取り込む
```

初回セットアップ手順は [IPHONE_USB_SETUP.md](IPHONE_USB_SETUP.md) を参照してください。Developer Mode の有効化と DeveloperDiskImage のマウントまで完了していれば、通常は次のコマンドで接続状態を確認できます。

```bash
bash scripts/iphone/check.sh
```

iPhone のスクリーンショットを取得する場合:

```bash
bash scripts/iphone/screenshot.sh
xdg-open artifacts/iphone/latest.png
```

iPhone の system log を確認する場合:

```bash
bash scripts/iphone/syslog.sh
```

アプリ名などで絞り込む場合:

```bash
bash scripts/iphone/syslog.sh "iPhoneLocalAI"
```

OpenAI互換HTTP APIへUSB経由で接続する場合は、別ターミナルで次を起動したままにします。

```bash
bash scripts/iphone/proxy.sh
```

デフォルトでは次のように転送されます。

```text
Ubuntu 127.0.0.1:8080 -> USB -> iPhone:8080
```

疎通確認:

```bash
curl http://127.0.0.1:8080/health
```

認証が必要なエンドポイントでは、iPhone アプリ内で API キーをコピーしてから、Ubuntu 側で次を実行します。

```bash
source scripts/iphone/get_api_key.sh
```

このスクリプトは iPhone のクリップボードを `pymobiledevice3` で読み取り、現在のシェルに `API_KEY` 環境変数として設定します。キーそのものは端末に表示しません。クリップボードが空の場合はエラーになります。

設定後は、そのまま次のように使えます。

```bash
curl \
  -H "Authorization: Bearer $API_KEY" \
  http://127.0.0.1:8080/v1/models
```

現在のシェルに変数を残すため、`get_api_key.sh` は `bash scripts/iphone/get_api_key.sh` ではなく必ず `source scripts/iphone/get_api_key.sh` で実行してください。

取得したスクリーンショットやログは `artifacts/iphone/` 以下に保存され、このディレクトリは Git 管理対象外です。

### 開発ビルドを USB で直接インストールする

開発中はTestFlightを経由せず、`iOS dev build` ワークフロー(`.github/workflows/dev-build.yml`)が作る開発署名の IPA を USB で直接インストールします。`iphone` ブランチへの push のうち、アプリに含まれるファイル(`App/` `Core/` `Backends/` `Server/` `Assets.xcassets/` プロジェクト設定など)が変わったときだけ自動実行され、手動実行もできます。

GitHub Actions の macOS ランナーは Linux の約10倍の速さで無料枠の分数を消費し、private リポジトリでは利用枠を超えるとジョブが開始されなくなります。そのため、単体テスト(`iOS pull request`)は PR 作成時と手動実行時のみ走ります。TestFlight に出す前などは次で手動実行してください。

```bash
gh workflow run pull-request.yml --ref iphone
```

```bash
git push origin iphone
bash scripts/iphone/install_dev_build.sh --wait   # 最新runの完了を待ってインストール・起動
bash scripts/iphone/install_dev_build.sh          # 成功済みの最新runをインストール
bash scripts/iphone/install_dev_build.sh RUN_ID   # 指定runをインストール
```

IPA は `artifacts/iphone/builds/<run id>/` に保存されます。開発署名のアプリは Apple Developer アカウントに登録済みの端末にしかインストールできません。端末は repository secret `DEV_DEVICE_UDIDS` に `名前=UDID` をカンマ区切りで記載すると、ワークフローが App Store Connect API で自動登録します(名前に空白は使えません)。UDID は `idevice_id -l` で取得できます。

公開リポジトリの Actions 成果物は誰でもダウンロードできるため、IPA は repository secret `DEV_IPA_PASSWORD` で暗号化してアップロードされます。インストールする PC には同じパスワードを `~/.config/iphone-local-ai/dev-ipa-password`(パーミッション 600)に置くか、環境変数 `DEV_IPA_PASSWORD` で渡してください。

### モデルを USB で転送する

`.litertlm` モデルはアプリに同梱せず、USB でアプリの Documents フォルダへ転送します。アプリは起動時(またはモデル画面の「Import from Documents folder」)に Documents 内の `.litertlm` を Application Support へ移動し、SHA-256 を記録して登録します。

```bash
bash scripts/iphone/push_model.sh ~/models/gemma-4-E2B-it.litertlm
```

転送中は `.part` という名前で送り、完了後に名前を変えるので、転送途中のファイルが取り込まれることはありません。登録後、モデル画面で「Load」を押すと読み込まれます。iOS 向けには Hugging Face `litert-community` の汎用版(`gemma-4-E2B-it.litertlm` など)を使います。Documents フォルダは「ファイル」アプリからも見えるため、PC を使わずにモデルを置くこともできます。

TestFlight(`TestFlight` ワークフロー、手動実行)は、開発ビルドで確認できた変更を配布・共有するときに使います。

## GitHub Actions secrets

The TestFlight workflow is manual and uses Xcode automatic signing with Apple's cloud-managed distribution certificates. Before running it, configure these repository secrets:

```text
APPSTORE_ISSUER_ID
APPSTORE_API_KEY_ID
APPSTORE_API_PRIVATE_KEY
APPLE_TEAM_ID
DEV_DEVICE_UDIDS   # development builds only: NAME=UDID, comma-separated
DEV_IPA_PASSWORD   # development builds only: encrypts the IPA artifact
```

App Store Connect must contain an app record for bundle identifier `jp.localai.iphone-server`. The workflow passes the App Store Connect API key directly to `xcodebuild`; no distribution `.p12` or manually managed provisioning profile is stored in the repository or required as a GitHub secret.

## Project notes

- See [SPEC.md](SPEC.md) for scope and staged implementation.
- See [TESTFLIGHT_SETUP.md](TESTFLIGHT_SETUP.md) for Apple Developer, signing, GitHub Secrets, and TestFlight deployment setup.
- See [IPHONE_USB_SETUP.md](IPHONE_USB_SETUP.md) for Ubuntu USB pairing, Developer Mode, screenshot capture, syslog, and port forwarding setup.
- See [AGENTS.md](AGENTS.md) for repository rules and build commands.
- Never commit App Store Connect credentials, signing certificates, API keys, or model files.

## License

Apache License 2.0. See [LICENSE](LICENSE). Model weights are not part of this repository and are subject to their own licenses.
