## What & why

<!-- One idea per PR. What changed, and what problem it solves. -->

## Gesture-law impact

<!-- How does this uphold "horizontal drags + two-finger gestures = shell;
     taps, vertical scroll, keyboard = content"? Write "none" if it truly
     doesn't touch input handling. -->

## Verified — function and feel

<!-- What you exercised: the feature itself, the gesture matrix around it
     (lane swipe / edge swipe / divider / pinch), and a force-quit-relaunch
     if model state changed. Screenshots or a short clip for anything
     visible — motion can only be judged by watching it. -->

- [ ] Builds clean (`xcodegen generate` re-run if files were added/removed)
- [ ] Feel-tested on a real device (latency, springs, keyboard — not just "it works")
- [ ] Screenshot/clip attached for visible changes
- [ ] Docs updated if behavior/look changed (`swift/README.md`, `DESIGN.md`)
- [ ] No diagnostics or demo scaffolding left in the merge
