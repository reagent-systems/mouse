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
    /// Flipped when the speaker STOPPED — about a second of silence after words — with a
    /// transcript worth sending. Hands-free: the container sends on this rather than waiting
    /// for a tap. Cleared on the next `start`.
    private(set) var finished = false
    /// Flipped when the microphone closed on its own with NOTHING said — the give-up
    /// timeout. The container reads it as "the conversation is over" and stops reopening
    /// the mic; a tap-to-stop or an endpoint never sets it.
    private(set) var heardNothing = false
    /// Set when a request cannot proceed — permission refused, no model, no recognizer.
    private(set) var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    /// When the transcript last changed — the clock the endpoint watches.
    private var lastChange = Date()
    private var endpointWatch: Task<Void, Never>?
    /// Silence after words that ends a turn. Long enough for a breath mid-sentence, short
    /// enough that the answer starts before the speaker wonders whether anything heard them.
    private static let endpointAfter: TimeInterval = 1.1
    /// Silence with NO words that gives the microphone back — a tap with nothing said, or a
    /// hands-free turn the speaker did not take.
    private static let giveUpAfter: TimeInterval = 6

    var available: Bool { recognizer?.isAvailable == true }

    /// Ask for both permissions, then start. Two prompts on the first run — the microphone is a
    /// separate grant from recognition, and iOS shows them one at a time.
    func start() async {
        guard !listening else { return }
        problem = nil
        finished = false
        heardNothing = false
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
            lastChange = Date()
            watchForEndpoint()
        } catch {
            problem = "\(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        endpointWatch?.cancel()
        endpointWatch = nil
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
        // playAndRecord, not record: the answer is spoken back on the same session, and the
        // speaker's next words (a barge-in) must start the microphone without renegotiating.
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.defaultToSpeaker, .duckOthers, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No usable input (a device with no microphone route) makes installTap throw an
        // Objective-C exception that Swift cannot catch — so it is refused here, in words.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Dictation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no microphone input"])
        }
        // The tap runs on the audio engine's realtime thread. This class is @MainActor, so a
        // plain closure literal here would INHERIT that isolation and trap on its first call
        // (dispatch_assert_queue, measured: SIGTRAP the moment the orb was tapped). @Sendable
        // opts out; the request is the only thing it touches.
        nonisolated(unsafe) let sink = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            sink.append(buffer)
        }
        engine.prepare()
        try engine.start()

        // Same rule: recognition results arrive on the recognizer's queue. Take the values
        // there, cross to the main actor with them, touch state only on the main actor.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let heard = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let heard {
                    if heard != self.transcript {
                        self.transcript = heard
                        self.lastChange = Date()
                    }
                    if isFinal { self.endpoint() }
                }
                if failed { self.stop() }
            }
        }
    }

    /// The endpoint detector: on-device recognition reports partials and rarely finalizes on
    /// its own, so the turn ends on SILENCE — measured from the last change to the transcript.
    private func watchForEndpoint() {
        endpointWatch?.cancel()
        endpointWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.listening else { return }
                let quiet = Date().timeIntervalSince(self.lastChange)
                if !self.transcript.isEmpty, quiet > Self.endpointAfter {
                    self.endpoint()
                    return
                }
                if self.transcript.isEmpty, quiet > Self.giveUpAfter {
                    self.stop()
                    self.heardNothing = true
                    return
                }
            }
        }
    }

    private func endpoint() {
        let worthSending = !transcript.trimmingCharacters(in: .whitespaces).isEmpty
        stop()
        finished = worthSending
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
