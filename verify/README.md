# verify/ — the verification suite

The gate suite the phase-G run (27ed75b..953dd98) was verified with, rescued
from the session scratchpad where it was built. This is the evidence behind
the claims in [STATUS.md](../STATUS.md) and system.md — without it those
claims are unreproducible.

## Layout

- One directory per harness (~90). Each holds a `main.swift` plus its
  fixtures and recorded real-node baselines (`*.txt`, `*.json`).
- `verify.sh` — runs everything: builds in parallel, runs serially (several
  harnesses bind ports or spawn children), grades by top-level verdict line.
- `build-one.sh` — builds a single harness. Picks the source set by what the
  harness references (node / +terminal / +shell), not by its name.
- `crosscheck.py` — the pyte reference-emulator cross-check for the terminal.

Built binaries and `node_modules` trees are not checked in; harnesses that
need packages install them through the engine's own PackageManager on first
run, which is itself part of what is being tested.

## Running

```
./verify.sh
```

Requirements: Xcode command-line tools (`xcrun swiftc`), real node v22 on
PATH (baselines were recorded against v22 — a different major will produce
false mismatches), Python 3 with `pyte` for the terminal cross-checks.

Rules the suite itself taught (see AGENTS.md for the full set):

- Never trust a green result from a binary you didn't just build —
  `build-one.sh` deletes the binary and the output file before building.
- Diagnostics are not assertions: `verify.sh` reports investigation
  harnesses separately so a permanently-red exploration can't hide a real
  regression.
- A gate must be proven able to fail before its passing means anything.
