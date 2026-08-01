#!/bin/bash
# One command to verify everything, because guessing a harness's source list produced a false
# "BUILD FAILED" twice — for the shell harness and the tty harness — and a build failure that is
# really a typo is the most expensive kind of noise: it looks exactly like a regression.
#
# Usage: ./verify.sh [harness ...]      (no arguments = all of them)
M=/Users/thyfriendlyfox/Projects/mouse/swift/Mouse
T="$(cd "$(dirname "$0")" && pwd)"

# The Node engine and everything it links.
NODE_SET="$M/NodeEngine.swift $M/NodeSockets.swift $M/NodeWatch.swift $M/NodeKeys.swift \
$M/NodeScrypt.swift $M/NodeBrotli.swift $M/NodeDNS.swift $M/PackageManager.swift"
# Harnesses that drive the terminal screen need phase T as well.
TERM_SET="$NODE_SET $M/TerminalScreen.swift $M/TerminalWidth.swift $M/TerminalPrograms.swift"
# msh needs the shell, its language, git and the terminal.
SHELL_SET="$M/Shell.swift $M/ShellLanguage.swift $M/GitCore.swift $M/GitRemote.swift $TERM_SET"

sources_for() {
  case "$1" in
    shell)     echo "$SHELL_SET" ;;
    tty|termtest) echo "$TERM_SET" ;;
    # termsays drives the TerminalSession itself, so it needs the shell as well as the screen.
    termsays)  echo "$SHELL_SET $M/Terminal.swift $M/Workspace.swift $M/CarouselDeck.swift" ;;
    *)         echo "$NODE_SET" ;;
  esac
}

# Each harness recompiles the whole engine, so a serial full run is around an hour. Build in
# PARALLEL — the machine has cores and the builds are independent.
JOBS=${JOBS:-6}

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  targets=()
  for dir in "$T"/*/; do
    name=$(basename "$dir")
    [ -f "$dir/main.swift" ] && targets+=("$name")
  done
fi

build_one() {
  name="$1"; dir="$T/$name"
  # The binary AND any stale results go first: a failed build otherwise leaves both in place and
  # the old ones pass, which has happened here before.
  rm -f "$dir/verify_bin" "$dir/verify_out.txt"
  (cd "$dir" && xcrun swiftc -O -o verify_bin main.swift $(sources_for "$name") -lz -lresolv \
     > verify_build.log 2>&1)
}
export -f build_one 2>/dev/null || true

echo "building ${#targets[@]} harnesses ($JOBS at a time)..."
printf '%s\n' "${targets[@]}" | xargs -P "$JOBS" -n 1 "$T/build-one.sh"

# Some harnesses are INVESTIGATIONS, not assertions: a corpus documenting why path.matchesGlob is
# refused, a probe written to decide whether process.stdout was worth rebuilding, sweeps that list
# differences by design. They "fail" every run, and five expected failures is exactly how a real
# regression hides — so they are reported separately rather than counted.
is_diagnostic() {
  case "$1" in
    glob|reachable|shapes|breadth|vitestrun) return 0 ;;
    *) return 1 ;;
  esac
}

# Run SERIALLY: several harnesses bind ports or spawn children, and running those at once would
# make them fight each other rather than test anything.
pass=0; fail=0; broke=0; diag=0
for name in "${targets[@]}"; do
  dir="$T/$name"
  printf '%-14s ' "$name"
  if [ ! -x "$dir/verify_bin" ]; then
    echo "BUILD FAILED — see $name/verify_build.log"
    broke=$((broke+1)); continue
  fi
  (cd "$dir" && ./verify_bin > verify_out.txt 2>&1)
  # The verdict grep is case-INSENSITIVE but the case match below was not, so a harness ending
  # in "3 lines differ" was graded ok. And a harness whose failure text used none of these words
  # produced an empty verdict, which was counted as neither a pass nor a failure — it simply
  # vanished from the totals. Both holes hid REAL failures, so the verdict is normalised to
  # upper case and a missing verdict is now a failure rather than a shrug.
  # A verdict is a TOP-LEVEL line; detail lines are indented. Without that distinction the
  # grep picks up a harness's own reported content — jest legitimately prints "failed=1" and
  # mocha "failures: 6", both expected results of suites with deliberately failing tests — and
  # grades the run on those instead of on its conclusion.
  # Two stages on purpose: first keep only TOP-LEVEL lines, then look for a verdict word in
  # them. Combining the two into one anchored pattern fails on a line that IS the keyword
  # ("ALL PASS"), because the anchor then demands a character in front of it.
  verdict=$(grep -E "^[^[:space:]]" "$dir/verify_out.txt" \
            | grep -iE "ALL PASS|MATCH|MISMATCH|FAIL|DIFFER" | tail -1)
  # Grade the CONCLUSION, not the prose explaining it. Every verdict here is "<result> — <why>",
  # and the why is written for a person: a passing sweep that mentions "a rejected call" or "in
  # different writes" was being read as a failure because the words appear somewhere in the line.
  # That cost two boundaries a false red each. Everything before the em dash is the result.
  upper=$(printf '%s' "${verdict%%—*}" | tr '[:lower:]' '[:upper:]')
  if is_diagnostic "$name"; then
    echo "diagnostic: ${verdict:0:60}"
    diag=$((diag+1)); continue
  fi
  case "$upper" in
    *MISMATCH*|*FAILURE*|*FAILED*|*DIFFER*) echo "FAIL: $verdict"; fail=$((fail+1)) ;;
    "")   echo "FAIL: no verdict line at all — inspect $name/verify_out.txt"; fail=$((fail+1)) ;;
    *)    echo "ok: ${verdict:0:70}"; pass=$((pass+1)) ;;
  esac
done
echo
echo "passed $pass, FAILED $fail, build-broken $broke, diagnostics $diag (not counted)"
[ $fail -ne 0 ] && echo "^ a real regression: these are assertions, not investigations"
[ $fail -eq 0 ] && [ $broke -eq 0 ]
