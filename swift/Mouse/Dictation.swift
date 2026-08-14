import AVFoundation
import Foundation
import Speech

/// Speech to text for the Agent container's input, ON DEVICE.
///
/// `requiresOnDeviceRecognition` is set, not merely preferred: the alternative sends recorded
/// audio of whatever is said near the phone to Apple's servers, and a coding agent's input is
/// the user's own source. On-device recognition is less accurate on identifiers and symbols, and
/// that is the trade this app takes. A locale with no on-device model simply reports unavailable.
@MainActor
@Observable
final class Dictation {
    /// Live text while speaking, replaced on every partial result.
    private(set) var transcript = ""
    private(set) var listening = false
    /// Set when a request cannot proceed — permission refused, no model, no recognizer.
    private(set) var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    var available: Bool { recognizer?.isAvailable == true }

    /// Ask for both permissions, then start. Two prompts on the first run — the microphone is a
    /// separate grant from recognition, and iOS shows them one at a time.
    func start() async {
        guard !listening else { return }
        problem = nil
        guard let recognizer, recognizer.isAvailable else {
            problem = "speech recognition unavailable"
            return
        }
        guard await Self.authorizeSpeech(), await Self.authorizeMicrophone() else {
            problem = "microphone or speech access refused"
            return
        }
        do {
            try beginCapture(with: recognizer)
            listening = true
        } catch {
            problem = "\(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        guard listening || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
        // The session is handed back so a program's own audio, and the ordinary ring silence,
        // are not left behind a recording category.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Take what was said and clear it, so the next dictation starts empty.
    func take() -> String {
        let text = transcript
        transcript = ""
        return text
    }

    private func beginCapture(with recognizer: SFSpeechRecognizer) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self.stop() }
                }
                if error != nil { self.stop() }
            }
        }
    }

    private static func authorizeSpeech() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    private static func authorizeMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}
