import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A terminal cell is a COLUMN, not a character. CJK, Kana, Hangul, fullwidth forms and most
// emoji take two of them; `put` advanced exactly one per character, so any TUI drawing a box or
// an aligned table with non-Latin text came out crooked, the error growing along the line.
//
// Two gates. The width table against Python's unicodedata, which is the authority rather than
// my recollection; and the grid behaviours a wide character forces on the emulator.
var failures = 0
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

let expectations = (try? String(contentsOf: here.appendingPathComponent("widths.txt"), encoding: .utf8)) ?? ""
var checked = 0, wrong = 0
for line in expectations.split(separator: "\n") {
    let parts = line.split(separator: " ")
    guard parts.count == 2, let value = UInt32(parts[0].dropFirst(2), radix: 16),
          let want = Int(parts[1]), let scalar = Unicode.Scalar(value) else { continue }
    let got = TerminalWidth.columns(of: Character(scalar))
    checked += 1
    if got != want {
        if wrong < 6 { print("  U+\(String(value, radix: 16, uppercase: true)): unicodedata=\(want) ours=\(got)") }
        wrong += 1
    }
}
if wrong > 0 { print("WIDTH TABLE: \(wrong) of \(checked) disagree with Unicode"); failures += 1 }
else { print("width table: all \(checked) agree with Python's unicodedata") }

// The grid itself.
func fresh(_ columns: Int = 10) -> TerminalScreen {
    return TerminalScreen(rows: 4, columns: columns)
}
func row(_ screen: TerminalScreen, _ index: Int = 0) -> String {
    String(screen.grid[index].filter { !$0.isContinuation }.map { $0.character })
        .trimmingCharacters(in: .whitespaces)
}
func expect(_ label: String, _ got: String, _ want: String) {
    if got != want { print("  \(label): want \(want.debugDescription) got \(got.debugDescription)"); failures += 1 }
}

var screen = fresh()
for ch in "中文" { screen.put(ch) }
expect("cursor after two wide", "\(screen.cursorColumn)", "4")
expect("wide text", row(screen), "中文")

screen = fresh()
for ch in "ab" { screen.put(ch) }
expect("cursor after two narrow", "\(screen.cursorColumn)", "2")

// A wide character with one column left must wrap WHOLE, not split.
screen = fresh(4)
for ch in "abc" { screen.put(ch) }
screen.put("中")
expect("wrapped whole", row(screen), "abc")
expect("wide moved to next row", row(screen, 1), "中")

// Overwriting half a wide pair must clear its partner, or the grid keeps an orphan.
screen = fresh()
screen.put("中"); screen.moveCursor(row: 0, column: 0); screen.put("x")
expect("partner cleared", row(screen), "x")
screen = fresh()
screen.put("中"); screen.moveCursor(row: 0, column: 1); screen.put("y")
expect("left half cleared", row(screen), "y")

// A combining mark attaches to the character already there rather than taking a column.
screen = fresh()
screen.put("e"); screen.put("\u{0301}")
expect("combining attaches", "\(screen.cursorColumn)", "1")
expect("combined glyph", row(screen), "é")

// Mixed content keeps its column arithmetic.
screen = fresh(12)
for ch in "a中b" { screen.put(ch) }
expect("mixed cursor", "\(screen.cursorColumn)", "4")
expect("mixed text", row(screen), "a中b")

if failures == 0 {
    print("WIDE CHARACTERS MATCH — the width table is Unicode's, and the grid counts columns")
} else {
    print("WIDE CHARACTERS FAILED — \(failures)")
    exit(1)
}
