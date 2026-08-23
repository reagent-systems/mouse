import Foundation

// The voice layer's two pure rules, checked without a microphone or a speaker:
//
//  1. Sentence boundaries for speak-as-it-streams. A sentence is complete at `.`, `!`, `?` or a
//     newline FOLLOWED BY a space or newline — so "3.14 is pi" does not split at the decimal,
//     a streamed "ends. " does, and a phrase still arriving ("Third one clos") waits. The cut
//     sits just past the terminator; the space after it leads the next sentence and is trimmed.
//  2. What of an answer is spoken: prose only. Fenced code and inline backticks stay on screen.

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "ok  " : "FAIL") \(name)")
    if !ok { failures += 1 }
}

func cut(_ text: String, from start: Int = 0, final: Bool = false) -> Int {
    Speech.sentenceCut(in: Array(text), from: start, final: final)
}

// 1. boundaries
check("no boundary yet → nothing to say", cut("Sure") == 0)
check("terminator without a following space is still mid-stream", cut("Sure.") == 0)
check("terminator + space completes the sentence", cut("Sure. ") == 5)
check("decimal point does not split", cut("Pi is 3.14 and ") == 0)
check("several complete sentences → past the last one", cut("One. Two! Three? Fo") == 16)
check("newline + newline is a boundary", cut("Line one\n\nLine tw") == 9)
check("resumes from where speech left off", cut("One. Two. Thr", from: 5) == 9)
check("final takes the tail, boundary or not", cut("Third one clos", final: true) == 14)
check("final with nothing left stays put", cut("Done. ", from: 6, final: true) == 6)
check("start past the end is clamped", cut("ab", from: 5) == 5)

// 2. spoken text
let fenced = "Use this:\n```swift\nlet x = 1\n```\nand you are set."
check("fenced code is not spoken", !Speech.spoken(fenced).contains("let x"))
check("prose around the fence survives", Speech.spoken(fenced).contains("Use this:") && Speech.spoken(fenced).contains("and you are set."))
check("inline code is dropped, words kept", Speech.spoken("Run `swift build` now").trimmingCharacters(in: .whitespacesAndNewlines) == "Run  now")
check("plain prose is unchanged", Speech.spoken("Hello there.").trimmingCharacters(in: .whitespacesAndNewlines) == "Hello there.")

print(failures == 0 ? "voice: all checks passed" : "voice: \(failures) failed")
exit(failures == 0 ? 0 : 1)
