#!/usr/bin/env python3
"""Find failing random streams, then delta-shrink to a minimal op list."""
import random
import subprocess

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


def render_ours(stream):
    with open("stream.bin", "wb") as f:
        f.write(stream.encode())
    out = subprocess.run(["./termtest", "render", "stream.bin", str(ROWS), str(COLS)],
                         capture_output=True, check=True)
    lines = out.stdout.decode().split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    lines += [""] * (ROWS - len(lines))
    return [line.rstrip() for line in lines]


def render_pyte(stream):
    screen = MaterializedScreen(COLS, ROWS)
    pyte.Stream(screen).feed(stream)
    return [line.rstrip() for line in screen.display]


def fails(parts):
    stream = f"{ESC}[2J{ESC}[H" + "".join(parts)
    return render_ours(stream) != render_pyte(stream)


rng = random.Random(1337)
found = None
for i in range(200):
    parts = [rng.choice(ops)(rng) for _ in range(rng.randint(5, 60))]
    if fails(parts):
        found = parts
        print(f"failing stream #{i}, {len(parts)} ops")
        break

if not found:
    print("no failure found")
    raise SystemExit(0)

# Greedy delta-shrink: drop ops while still failing.
changed = True
while changed:
    changed = False
    i = 0
    while i < len(found):
        candidate = found[:i] + found[i + 1:]
        if candidate and fails(candidate):
            found = candidate
            changed = True
        else:
            i += 1

print("minimal ops:")
for part in found:
    print(f"  {part!r}")
stream = f"{ESC}[2J{ESC}[H" + "".join(found)
for a, b in zip(render_ours(stream), render_pyte(stream)):
    if a != b or a:
        print(f"  ours: {a!r}\n  pyte: {b!r}")
