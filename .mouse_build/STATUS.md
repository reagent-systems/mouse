# Mouse Build — Status & Continuation Contract

STATUS: DONE

## The Goal
Continually modify the codebase at /Users/thyfriendlyfox/Projects/mouse and produce a
FINISHED, WORKING app that looks and feels like the screenshots in `sketches/`.
NOT a simulated app. It must build, run, and render pixel-close to the sketches.

## Definition of DONE (all must pass)
1. `npx tsc --noEmit` exits 0.
2. `npm run build` exits 0 (tsc + vite build produce dist/).
3. The app renders in a headless browser without console errors.
4. A "demo mode" lets the full module UI render WITHOUT live GitHub auth + relay,
   so the screens can be visually verified.
5. Rendered screenshots of each view (code, files, changes, graph, agent terminal,
   bottom composer) match the sketches in look & feel:
   - Ayu-dark palette, liquid-glass module cards, rounded 22px corners.
   - Code editor: syntax-highlighted README, blame line, "Follow link" hint.
   - File tree: dir/file icons, expand arrows, indentation.
   - Git changes: CHANGES header, commit msg, YELLOW Commit button + dropdown, counts.
   - Git graph: GRAPH + Auto header, colored commit dots, main/origin tags.
   - Agent: status bar + xterm terminal, "Thinking…", Y/N question affordance.
   - Bottom bar: "∞ Agent ▾", "Composer 1.5 ▾", mic button.
6. Gestures wired: vertical swipe (between views), horizontal swipe (module views),
   pinch-spread (add/remove modules), drag divider (resize).
7. Changes committed to git with a clear message.

## Progress log (append, newest last)
- Session start: tsc --noEmit passes. node v22, npm 10. node_modules present.
  Codebase already implements most views. Need demo mode + visual verification harness.
- Added IRelay interface + MockRelay + ?demo=1 demo mode; fixed CodeEditor highlighter
  self-corruption (tokenizer rewrite). Built Playwright harness (.mouse_build/verify.mjs).
  Clean build: tsc OK, vite build OK. verify.mjs PASS (all 6 views + agent terminal +
  composer render; no console errors; highlighter leak guard passes). Visually confirmed
  code/files/changes/graph/agent shots match sketches. Committed 35da05c. STATUS: DONE.

## How to continue if interrupted
Read this file. Run the verification harness at `.mouse_build/verify.mjs`.
Fix whatever fails. Update this file. Only set STATUS: DONE when every item above passes.
