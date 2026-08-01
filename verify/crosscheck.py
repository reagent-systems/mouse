#!/usr/bin/env python3
"""Cross-check TerminalScreen against pyte (a known-good VT emulator).

Feeds the same escape stream to both and diffs the final visible text.
Streams stay inside the subset both emulators implement (no charsets,
no mouse, no double-width).
"""
import random
import subprocess
import sys

import pyte

class MaterializedScreen(pyte.Screen):
    """pyte's sparse buffer makes IL/DL skip rows that were never written
    (`if y + count in self.buffer`), leaving stale lines real xterm removes.
    Materializing the row keys first sidesteps the storage artifact without
    changing semantics."""

    def _touch(self):
        for y in range(self.lines):
            _ = self.buffer[y]


    # xterm clamps relative vertical moves at the margin only when the cursor
    # starts inside the region; pyte's max()/min() wrongly drag an outside
    # cursor onto the margin.
    def cursor_up(self, count=None):
        top, _bottom = self.margins or pyte.screens.Margins(0, self.lines - 1)
        limit = top if self.cursor.y >= top else 0
        self.cursor.y = max(self.cursor.y - (count or 1), limit)

    def cursor_down(self, count=None):
        _top, bottom = self.margins or pyte.screens.Margins(0, self.lines - 1)
        limit = bottom if self.cursor.y <= bottom else self.lines - 1
        self.cursor.y = min(self.cursor.y + (count or 1), limit)

    def insert_lines(self, count=None):
        self._touch()
        super().insert_lines(count)

    def delete_lines(self, count=None):
        self._touch()
        super().delete_lines(count)


ROWS, COLS = 24, 80
ESC = "\x1b"

structured = [
    # name, stream
    ("plain wrap", "x" * 200),
    ("crlf lines", "one\r\ntwo\r\nthree\r\n\r\nfive"),
    ("cup grid", "".join(f"{ESC}[{r};{c}H#" for r in range(1, 25, 3) for c in range(1, 81, 7))),
    ("el variants", "aaaaaa\r\nbbbbbb\r\ncccccc" + f"{ESC}[1;3H{ESC}[K{ESC}[2;3H{ESC}[1K{ESC}[3;1H{ESC}[2K"),
    ("ed 0", "\r\n".join("row%02d" % i for i in range(24)) + f"{ESC}[12;3H{ESC}[J"),
    ("ed 1", "\r\n".join("row%02d" % i for i in range(24)) + f"{ESC}[12;3H{ESC}[1J"),
    ("scroll region lf", f"{ESC}[2J{ESC}[Hheader\r\n" + "\r\n".join("l%d" % i for i in range(22)) +
     f"{ESC}[5;10r{ESC}[10;1H" + "\n" * 8 + "scrolled"),
    ("ri top", f"{ESC}[2J{ESC}[Ha\r\nb\r\nc{ESC}[1;1H{ESC}M{ESC}Mnew"),
    ("region ri", f"{ESC}[2J{ESC}[3;8r{ESC}[3;1Htop" + f"{ESC}M" * 4 + "up"),
    ("il dl", "\r\n".join("line%d" % i for i in range(10)) + f"{ESC}[4;1H{ESC}[2L{ESC}[8;1H{ESC}[M"),
    ("ich dch ech", f"{ESC}[Habcdefghij{ESC}[1;3H{ESC}[3@{ESC}[1;9H{ESC}[2P{ESC}[1;1H{ESC}[2X"),
    ("tabs", "a\tb\tc\td\r\n\te"),
    ("backspace", "hello\b\b\bXY"),
    ("save restore", f"{ESC}[5;5Hmark{ESC}7{ESC}[Hhome{ESC}8!"),
    ("vpa cha", f"{ESC}[Habc{ESC}[10d{ESC}[40Gmid"),
    ("full paint", "".join(f"{ESC}[{r};1H" + "".join(chr(33 + (r * 7 + c) % 90) for c in range(COLS)) for r in range(1, ROWS + 1))),
]

ops = [
    lambda rng: "".join(rng.choice("abcdefghij ") for _ in range(rng.randint(1, 40))),
    lambda rng: f"{ESC}[{rng.randint(1, 30)};{rng.randint(1, 90)}H",
    lambda rng: f"{ESC}[{rng.randint(1, 5)}{rng.choice('ABCD')}",
    lambda rng: "\r\n",
    lambda rng: "\r",
    lambda rng: "\t",
    lambda rng: f"{ESC}[{rng.choice(['', '1', '2'])}J",
    lambda rng: f"{ESC}[{rng.choice(['', '1', '2'])}K",
    lambda rng: f"{ESC}[{rng.randint(1, 3)}L",
    lambda rng: f"{ESC}[{rng.randint(1, 3)}M",
    lambda rng: f"{ESC}[{rng.randint(1, 3)}P",
    lambda rng: f"{ESC}[{rng.randint(1, 3)}@",
    lambda rng: f"{ESC}[{rng.randint(1, 3)}X",
    lambda rng: f"{ESC}M",
    lambda rng: (lambda top: f"{ESC}[{top};{rng.randint(top + 1, 24)}r")(rng.randint(1, 20)),
    lambda rng: f"{ESC}[r",
    lambda rng: f"{ESC}[{rng.randint(1, 24)}d",
    lambda rng: f"{ESC}[{rng.randint(1, 80)}G",
]


def render_ours(stream: str) -> list[str]:
    with open("stream.bin", "wb") as f:
        f.write(stream.encode())
    out = subprocess.run(["./termtest", "render", "stream.bin", str(ROWS), str(COLS)],
                         capture_output=True, check=True)
    lines = out.stdout.decode().split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    lines += [""] * (ROWS - len(lines))
    return [line.rstrip() for line in lines]


def render_pyte(stream: str) -> list[str]:
    screen = MaterializedScreen(COLS, ROWS)
    pyte.Stream(screen).feed(stream)
    return [line.rstrip() for line in screen.display]


def run(name: str, stream: str) -> bool:
    ours, theirs = render_ours(stream), render_pyte(stream)
    if ours == theirs:
        return True
    print(f"MISMATCH: {name}")
    for i, (a, b) in enumerate(zip(ours, theirs)):
        if a != b:
            print(f"  row {i:2d} ours : {a!r}")
            print(f"  row {i:2d} pyte : {b!r}")
    return False


failures = 0
for name, stream in structured:
    failures += 0 if run(name, stream) else 1

rng = random.Random(20260727)
for i in range(1000):
    stream = f"{ESC}[2J{ESC}[H" + "".join(rng.choice(ops)(rng) for _ in range(rng.randint(5, 60)))
    failures += 0 if run(f"random #{i}", stream) else 1

print("ALL MATCH" if failures == 0 else f"{failures} MISMATCHES")
sys.exit(1 if failures else 0)
