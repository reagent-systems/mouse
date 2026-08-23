import AVFoundation
import Foundation

/// Text to speech for the Agent container's answers, ON DEVICE, a sentence at a time.
///
/// Latency is the whole point: the agent's answer arrives as a stream of phrases, and this
/// speaks each sentence the moment it completes rather than waiting for the whole reply. Fed the
/// answer-so-far on every delta, it remembers how far it has spoken and queues only the new
/// complete sentences; `finish` flushes the tail once the answer is whole.
///
/// Code is not read aloud. A fenced block or inline backticks in an answer are for the eyes —
/// hearing a function body spelled out letter by letter helps nobody — so speech skips them and
/// the text on screen carries them.
@MainActor
@Observable
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var speaking = false

    private let synthesizer = AVSpeechSynthesizer()
    /// The answer as fed so far, and how many of its characters have been queued for speech.
    private var text = ""
    private var spokenCount = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// A new answer is starting: forget the last one.
    func begin() {
        stop()
        text = ""
        spokenCount = 0
    }

    /// The answer so far. Only sentences that have COMPLETED since the last call are queued — a
    /// sentence boundary is `.`, `!`, `?` or a newline followed by a space or another newline,
    /// which is how a streamed phrase ends and a decimal point does not.
    func feed(_ answerSoFar: String) {
        text = answerSoFar
        queueCompletedSentences(final: false)
    }

    /// The answer is whole: speak whatever remains, boundary or not.
    func finish() {
        queueCompletedSentences(final: true)
    }

    /// Barge-in. The listener started talking (or tapped); the rest of the answer stays on
    /// screen and goes unsaid.
    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
    }

    private func queueCompletedSentences(final: Bool) {
        let characters = Array(text)
        let cut = Self.sentenceCut(in: characters, from: spokenCount, final: final)
        guard cut > spokenCount else { return }
        let sentence = String(characters[spokenCount..<cut])
        spokenCount = cut
        speak(Self.spoken(sentence))
    }

    /// Where the speakable prefix ends: the index just past the LAST complete sentence at or
    /// after `start`, or `start` when none has completed yet. `final` takes everything. Pure,
    /// so the rule is checkable without a synthesizer (verify/voice).
    nonisolated static func sentenceCut(in characters: [Character], from start: Int, final: Bool) -> Int {
        guard start < characters.count else { return start }
        if final { return characters.count }
        var cut = start
        var index = start
        while index < characters.count {
            let next = index + 1
            if ".!?\n".contains(characters[index]),
               next < characters.count, characters[next] == " " || characters[next] == "\n" {
                cut = next
            }
            index = next
        }
        return cut
    }

    private func speak(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if os(iOS)
        if !speaking {
            // Spoken audio through the speaker, ducking whatever else plays. Record stays in the
            // category so a barge-in can start the microphone without renegotiating the session.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .spokenAudio,
                                     options: [.defaultToSpeaker, .duckOthers, .allowBluetooth])
            try? session.setActive(true)
        }
        #endif
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speaking = true
        synthesizer.speak(utterance)
    }

    /// What of a sentence is worth saying: prose, with fenced code blocks and inline code left
    /// to the screen.
    nonisolated static func spoken(_ sentence: String) -> String {
        var result = ""
        var inFence = false
        for line in sentence.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            // Inline code: drop the backticked spans, keep the words around them.
            var stripped = ""
            var inCode = false
            for character in line {
                if character == "`" { inCode.toggle(); continue }
                if !inCode { stripped.append(character) }
            }
            result += stripped + "\n"
        }
        return result
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking { self.speaking = false }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking { self.speaking = false }
        }
    }
}
