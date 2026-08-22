#!/bin/bash
# Build ONE harness. A separate file rather than an inline xargs body: embedding the source lists
# in the command line overflowed it, and the failure was silent enough that three harnesses then
# reported ok from binaries an earlier run had left behind.
# M resolves relative to this script so a harness always builds the shipping source of the
# checkout it lives in — an absolute path here silently built ANOTHER checkout's engine when the
# suite ran from a worktree, which is the "green about code that does not ship" trap again.
T="$(cd "$(dirname "$0")" && pwd)"
M="$(cd "$T/../swift/Mouse" && pwd)"
NODE_SET="$M/NodeEngine.swift $M/NodeSockets.swift $M/NodeWatch.swift $M/NodeKeys.swift $M/NodeScrypt.swift $M/NodeBrotli.swift $M/NodeDNS.swift $M/PackageManager.swift"
TERM_SET="$NODE_SET $M/TerminalScreen.swift $M/TerminalWidth.swift $M/TerminalPrograms.swift"
# msh installs language runtimes (`pkg install python`), so the shell set carries them.
SHELL_SET="$M/Shell.swift $M/ShellLanguage.swift $M/GitCore.swift $M/GitRemote.swift $M/Runtimes.swift $M/PipInstaller.swift $TERM_SET"
# The terminal SESSION — scrollback, engines, the run/interrupt path — without its SwiftUI views.
SESSION_SET="$SHELL_SET $M/TerminalSession.swift"
name="$1"; dir="$T/$name"
# Pick the source set from what the harness actually REFERENCES, not from its name. Keying on
# names meant every new terminal or shell harness failed to build until someone remembered to
# add it here — which is a verification gap wearing the costume of a typo.
# The agent container's API client stands alone — one HTTP call, no engine behind it.
if grep -qE 'AgentAPI' "$dir/main.swift" 2>/dev/null; then
  SRC="$M/AgentAPI.swift"
# The voice layer's pure rules — sentence boundaries, what of an answer is said aloud — stand
# alone; the synthesizer behind them is iOS's and is not what the gate checks.
elif grep -qE 'Speech\.' "$dir/main.swift" 2>/dev/null; then
  SRC="$M/Speech.swift"
# The wheel installer needs the zip reader (Runtimes) and TarGz (PackageManager) behind it.
elif grep -qE 'Pip\.' "$dir/main.swift" 2>/dev/null; then
  SRC="$M/PipInstaller.swift $M/Runtimes.swift $NODE_SET"
elif grep -qE 'TerminalSession' "$dir/main.swift" 2>/dev/null; then
  SRC="$SESSION_SET"
elif grep -qE 'Shell\(|ShellLanguage|GitCore|GitRemote' main_probe 2>/dev/null || \
   grep -qE 'Shell\(|ShellLanguage|GitCore|GitRemote' "$dir/main.swift" 2>/dev/null; then
  SRC="$SHELL_SET"
elif grep -qE 'TerminalScreen|TerminalWidth|TerminalProgram' "$dir/main.swift" 2>/dev/null; then
  SRC="$TERM_SET"
else
  SRC="$NODE_SET"
fi
rm -f "$dir/verify_bin" "$dir/verify_out.txt"
cd "$dir" && xcrun swiftc -O -o verify_bin main.swift $SRC -lz -lresolv > verify_build.log 2>&1
