import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Two things a full-screen program depends on, both found by trying to test wide characters
// end to end and discovering the screen was empty afterwards.
//
// The alternate screen is a SAVE/RESTORE pair: `ESC[?1049h` puts the normal screen aside and
// hands over a cleared one, `ESC[?1049l` puts it back. Leaving used to CLEAR instead, so
// quitting `less`, `top`, vim or any ink TUI wiped the terminal rather than returning the user
// to their work. And the columns have to survive the round trip, since what was saved may well
// be wide text.
var failures = 0
func expect(_ label: String, _ got: String, _ want: String) {
    if got != want { print("  \(label): want \(want.debugDescription) got \(got.debugDescription)"); failures += 1 }
}
func text(_ screen: TerminalScreen, _ row: Int) -> String {
    String(screen.grid[row].filter { !$0.isContinuation }.map(\.character))
        .trimmingCharacters(in: .whitespaces)
}

// The ordinary cycle a TUI performs.
let screen = TerminalScreen(rows: 8, columns: 24)
let parser = AnsiParser(screen: screen)
parser.feed("\u{1B}[Hmain 中文 work")
parser.feed("\u{1B}[2;1Hsecond line")
parser.feed("\u{1B}[2;5H")            // a cursor position worth restoring
let beforeRow = text(screen, 0), beforeColumn = screen.cursorColumn
parser.feed("\u{1B}[?1049h")
expect("alt starts cleared", text(screen, 0), "")
parser.feed("\u{1B}[Halt 日本語 screen")
expect("alt draws", text(screen, 0), "alt 日本語 screen")
parser.feed("\u{1B}[?1049l")
expect("normal screen restored", text(screen, 0), beforeRow)
expect("second line restored", text(screen, 1), "second line")
expect("cursor restored", "\(screen.cursorColumn)", "\(beforeColumn)")

// Wide text must survive the save/restore with its columns intact, not collapse to one cell.
expect("wide survives round trip", String(screen.grid[0][5].character), "中")
expect("continuation survives", screen.grid[0][6].isContinuation ? "cont" : "plain", "cont")

// Leaving an alternate screen never entered must not destroy anything.
let s2 = TerminalScreen(rows: 4, columns: 20)
let p2 = AnsiParser(screen: s2)
p2.feed("\u{1B}[Huntouched")
p2.feed("\u{1B}[?1049l")
expect("bare leave is a no-op", text(s2, 0), "untouched")

// Entering twice must not lose the ORIGINAL normal screen behind the second save.
let s3 = TerminalScreen(rows: 4, columns: 20)
let p3 = AnsiParser(screen: s3)
p3.feed("\u{1B}[Horiginal")
p3.feed("\u{1B}[?1049h\u{1B}[Hfirst alt")
p3.feed("\u{1B}[?1049h\u{1B}[Hsecond alt")   // already alternate: a no-op, not a re-save
p3.feed("\u{1B}[?1049l")
expect("double enter keeps original", text(s3, 0), "original")

if failures == 0 {
    print("ALT SCREEN MATCH — the normal screen and its columns come back, as a real terminal's do")
} else {
    print("ALT SCREEN FAILED — \(failures)")
    exit(1)
}
