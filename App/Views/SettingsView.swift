import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var portText = "8080"
    @State private var maxTokens = 512
    @State private var temperature = 0.7
    @State private var contextTokens = 4096
    @State private var multiTokenPredictionEnabled = false
    @State private var revealKey = false
    @State private var copied = false
    @State private var huggingFaceToken = ""
    @FocusState private var numberFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("HTTP サーバー") {
                    HStack {
                        TextField("ポート", text: $portText)
                            .keyboardType(.numberPad)
                            .focused($numberFieldFocused)
                            .textFieldStyle(.roundedBorder)
                        Button("適用") {
                            if let value = Int(portText) { Task { await appState.applyPort(value) } }
                        }
                        .buttonStyle(.bordered)
                    }
                    Toggle("LAN からの接続を許可", isOn: Binding(
                        get: { appState.allowLAN },
                        set: { enabled in Task { await appState.setLANEnabled(enabled) } }
                    ))
                    Text(appState.allowLAN
                         ? "すべてのネットワークインターフェースで待ち受けます。信頼できるネットワークでのみ使ってください。"
                         : "USB のポート転送用に localhost だけで待ち受けます。LAN からの接続は無効です。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("推論の既定値") {
                    LabeledContent("既定の出力トークン数") {
                        TextField("1〜\(String(contextTokens))", value: $maxTokens, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($numberFieldFocused)
                            .frame(maxWidth: 110)
                    }
                    Stepper("128 ずつ増減", value: $maxTokens, in: 1...contextTokens, step: 128)
                    if !(1...contextTokens).contains(maxTokens) {
                        Text("1〜\(String(contextTokens)) の範囲で入力してください。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Picker("コンテキスト上限", selection: $contextTokens) {
                        ForEach([1024, 2048, 4096, 8192], id: \.self) { value in
                            Text("\(String(value)) トークン").tag(value)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("既定の temperature", value: String(format: "%.1f", temperature))
                        Slider(value: $temperature, in: 0...2, step: 0.1)
                            .accessibilityLabel("既定の temperature")
                    }
                    Button("推論設定を適用") {
                        Task {
                            await appState.applyInferenceDefaults(
                                maxTokens: maxTokens,
                                temperature: temperature,
                                contextTokens: contextTokens,
                                multiTokenPredictionEnabled: multiTokenPredictionEnabled
                            )
                        }
                    }
                    .disabled(!(1...contextTokens).contains(maxTokens))
                    Toggle("Multi-Token Prediction（実験的）", isOn: $multiTokenPredictionEnabled)
                    Text("これらは既定値です。OpenAI 形式のリクエストで出力トークン数と temperature を上書きできます。コンテキスト上限または MTP を変えると、ロード中の LiteRT モデルを再ロードします。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("推論バックエンド") {
                    LabeledContent("利用できるバックエンド", value: "Mock · LiteRT-LM · llama.cpp")
                    Text(".litertlm モデルは LiteRT-LM で動きます（GPU 優先、CPU にフォールバック、テキストのみ）。.gguf モデルは llama.cpp（Metal）で動き、mmproj ファイルがあれば画像も入力できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("MTP の設定", value: multiTokenPredictionEnabled ? "有効" : "無効")
                    Text("Multi-Token Prediction は LiteRT-LM の実験的なデコード機能です。速度とメモリへの影響は iPhone 上での計測が必要です。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("USB 転送", value: "PC 側の iproxy")
                    Text("USB 転送は PC 側の usbmuxd / libimobiledevice が行います。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Bearer API キー") {
                    HStack {
                        Group {
                            if revealKey {
                                Text(appState.apiKey).textSelection(.enabled)
                            } else {
                                SecureField("API キー", text: .constant(appState.apiKey))
                                    .disabled(true)
                            }
                        }
                        .font(.caption.monospaced())
                        Button { revealKey.toggle() } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                        }
                        .accessibilityLabel(revealKey ? "API キーを隠す" : "API キーを表示")
                    }
                    Button {
                        UIPasteboard.general.string = appState.apiKey
                        copied = true
                    } label: {
                        Label(copied ? "コピーしました" : "API キーをコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button("新しい API キーを生成", role: .destructive) {
                        Task { await appState.regenerateAPIKey() }
                    }
                    Text("キーは Keychain に保存されます。再生成すると古いキーはすぐに使えなくなります。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Hugging Face") {
                    SecureField(appState.hasHuggingFaceToken ? "アクセストークン保存済み" : "アクセストークン（任意）", text: $huggingFaceToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("トークンを保存") {
                        appState.setHuggingFaceToken(huggingFaceToken)
                        huggingFaceToken = ""
                    }
                    .disabled(huggingFaceToken.trimmingCharacters(in: .whitespaces).isEmpty)
                    if appState.hasHuggingFaceToken {
                        Button("トークンを削除", role: .destructive) { appState.setHuggingFaceToken("") }
                    }
                    Text("トークンが必要なのは gated / private リポジトリだけです。Keychain に保存され、huggingface.co にのみ送信されます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("実行環境") {
                    LabeledContent("実行", value: "フォアグラウンドのみ")
                    LabeledContent("既定のエンドポイント", value: "\(appState.endpoint)/v1")
                    LabeledContent("プロンプトのログ記録", value: "なし")
                }
                Section { ErrorBanner().listRowInsets(EdgeInsets()) }
            }
            .navigationTitle("設定")
            .toolbar {
                // The number pad has no return key.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { numberFieldFocused = false }
                }
            }
            .onAppear {
                portText = String(appState.port)
                maxTokens = appState.defaultMaxTokens
                temperature = appState.temperature
                contextTokens = appState.contextTokens
                multiTokenPredictionEnabled = appState.multiTokenPredictionEnabled
            }
            .onChange(of: contextTokens) { _, newValue in
                maxTokens = min(maxTokens, newValue)
            }
        }
    }
}
