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

    var body: some View {
        NavigationStack {
            Form {
                Section("HTTP server") {
                    HStack {
                        TextField("Port", text: $portText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                        Button("Apply") {
                            if let value = Int(portText) { Task { await appState.applyPort(value) } }
                        }
                        .buttonStyle(.bordered)
                    }
                    Toggle("Allow LAN connections", isOn: Binding(
                        get: { appState.allowLAN },
                        set: { enabled in Task { await appState.setLANEnabled(enabled) } }
                    ))
                    Text(appState.allowLAN
                         ? "The API listens on all network interfaces. Use only on a trusted network."
                         : "The API listens on localhost for USB port forwarding. LAN access is off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Inference defaults") {
                    Stepper(value: $maxTokens, in: 1...contextTokens) {
                        LabeledContent("Default output tokens", value: "\(maxTokens)")
                    }
                    Picker("Context limit", selection: $contextTokens) {
                        ForEach([1024, 2048, 4096, 8192], id: \.self) { value in
                            Text("\(value) tokens").tag(value)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Default temperature", value: String(format: "%.1f", temperature))
                        Slider(value: $temperature, in: 0...2, step: 0.1)
                            .accessibilityLabel("Default temperature")
                    }
                    Button("Apply inference settings") {
                        Task {
                            await appState.applyInferenceDefaults(
                                maxTokens: maxTokens,
                                temperature: temperature,
                                contextTokens: contextTokens,
                                multiTokenPredictionEnabled: multiTokenPredictionEnabled
                            )
                        }
                    }
                    .disabled(maxTokens > contextTokens)
                    Toggle("Multi-Token Prediction (experimental)", isOn: $multiTokenPredictionEnabled)
                    Text("These values are defaults; OpenAI requests can override output tokens and temperature. Changing context or MTP reloads a loaded LiteRT model.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Inference backend") {
                    LabeledContent("Available backends", value: "Mock · LiteRT-LM")
                    Text("LiteRT-LM tries GPU first, uses CPU as a fallback, and runs image input on CPU. Device and model support still require confirmation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("MTP setting", value: multiTokenPredictionEnabled ? "Enabled" : "Disabled")
                    Text("Multi-Token Prediction is a LiteRT-LM experimental decoding option. Its speed and memory effects need measurement on iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("USB forwarding", value: "Host-side iproxy")
                    Text("USB forwarding is provided by usbmuxd/libimobiledevice on the PC.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Bearer API key") {
                    HStack {
                        Group {
                            if revealKey {
                                Text(appState.apiKey).textSelection(.enabled)
                            } else {
                                SecureField("API key", text: .constant(appState.apiKey))
                                    .disabled(true)
                            }
                        }
                        .font(.caption.monospaced())
                        Button { revealKey.toggle() } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                        }
                        .accessibilityLabel(revealKey ? "Hide API key" : "Show API key")
                    }
                    Button {
                        UIPasteboard.general.string = appState.apiKey
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy API key", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button("Generate a new API key", role: .destructive) {
                        Task { await appState.regenerateAPIKey() }
                    }
                    Text("The key is stored in Keychain. Regenerating it immediately invalidates the old key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Runtime") {
                    LabeledContent("Execution", value: "Foreground only")
                    LabeledContent("Default endpoint", value: "\(appState.endpoint)/v1")
                    LabeledContent("Prompt logging", value: "Off")
                }
                Section { ErrorBanner().listRowInsets(EdgeInsets()) }
            }
            .navigationTitle("Settings")
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
