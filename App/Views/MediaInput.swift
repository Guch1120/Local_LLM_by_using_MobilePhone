import AVFoundation
import SwiftUI
import UIKit

enum MediaInputError: Error, LocalizedError {
    case microphoneDenied
    case recordingFailed
    case unreadableAudio

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "マイクへのアクセスが許可されていません。設定アプリの「プライバシーとセキュリティ」→「マイク」で許可してください。"
        case .recordingFailed:
            return "録音を開始できませんでした。"
        case .unreadableAudio:
            return "この音声ファイルは読み込めませんでした。"
        }
    }
}

/// Records the microphone to a 16 kHz mono WAV, which llama.cpp's audio encoder reads directly.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    /// Longer clips are cut; Gemma 4 handles audio in 30-second pieces.
    nonisolated static let maximumDuration: TimeInterval = 30

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Receives the WAV data and its length when a recording ends (by the user or at the limit).
    var onFinish: ((Data, TimeInterval) -> Void)?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var discardRecording = false

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw MediaInputError.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.record(forDuration: Self.maximumDuration) else { throw MediaInputError.recordingFailed }
        self.recorder = recorder
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                self.elapsed = recorder.currentTime
            }
        }
    }

    /// Ends the recording; the clip arrives through `onFinish`.
    func stop() {
        recorder?.stop()
    }

    /// Ends the recording and throws the clip away.
    func cancel() {
        discardRecording = true
        recorder?.stop()
    }

    private func finish(url: URL, successfully: Bool) {
        timer?.invalidate()
        timer = nil
        isRecording = false
        recorder = nil
        defer { try? FileManager.default.removeItem(at: url) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let discard = discardRecording
        discardRecording = false
        guard !discard, successfully, let data = try? Data(contentsOf: url), data.count > 44 else { return }
        // 16-bit mono at 16 kHz after the 44-byte header.
        onFinish?(data, Double(data.count - 44) / 32_000)
    }

    /// Converts an audio file the user picked (m4a, mp3, wav, ...) to WAV, keeping at most
    /// `maximumDuration` seconds from the start.
    nonisolated static func wavClip(from url: URL) throws -> (data: Data, duration: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(min(file.length, AVAudioFramePosition(format.sampleRate * maximumDuration)))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw MediaInputError.unreadableAudio
        }
        try file.read(into: buffer, frameCount: frames)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: output) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        try writeWAV(buffer, to: output, settings: settings, format: format)
        return (try Data(contentsOf: output), Double(buffer.frameLength) / format.sampleRate)
    }

    /// The writer closes the file when it is released at the end of this function.
    private nonisolated static func writeWAV(
        _ buffer: AVAudioPCMBuffer, to url: URL, settings: [String: Any], format: AVAudioFormat
    ) throws {
        let writer = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        try writer.write(from: buffer)
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor in self.finish(url: url, successfully: flag) }
    }
}

/// The system camera, returning the photo taken.
struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
