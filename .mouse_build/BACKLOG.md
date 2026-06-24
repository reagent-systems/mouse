# Mouse — Evolution Backlog

Append-only queue of task batches, each instantiated from
`.mouse_build/TASK_TEMPLATE.md`. The driver (`mouse-evolve` cron) executes the
oldest `status: pending` batch, marks it `done`, and its final task appends the
next batch. The loop never ends because every batch's last task re-seeds the queue.

Legend: `[ ]` pending · `[x]` done · `[-]` skipped (note why)

---

## Batch 1 — focus: fidelity — 2026-06-23 — status: done
1. [x] Measure module-card corner radius, border color, and backdrop-blur against
       `sketches/Screenshot_2026-03-11_at_16.47.20.png`; adjust `--radius` / `.module`
       in `src/style.css` until they match within ~1px.
2. [x] Verify the Commit button amber (`--amber`) and its darker dropdown match the
       sketch's yellow-orange; tune if off. Confirm via a fresh verify screenshot.
3. [x] Confirm code-editor syntax colors (tag/attr/str/heading) match the sketch
       legend; adjust `--syn-*` vars if any channel is wrong.
4. [x] Add the "Follow link (cmd + click)" hint line to the code editor footer to
       match `Screenshot_2026-03-11_at_17.37.50.png`, gated so it only shows in the code view.
5. [x] **Generate the next batch from `.mouse_build/TASK_TEMPLATE.md`:** choose the
       least-recently-used focus area, write a new `Batch 2` block with 4 concrete
       tasks + this same final task, and append it to `.mouse_build/BACKLOG.md`. This
       is what keeps the loop alive — never skip it.

## Batch 2 — focus: gestures — 2026-06-24 — status: pending
1. [ ] Audit `src/gestures/index.ts` for the horizontal swipe view-change handler:
       add a velocity/momentum threshold so a fast flick advances exactly one view
       even when the drag distance is short, and snap-backs below threshold.
2. [ ] Make the module divider drag-resize in `src/modules/ModuleStack.ts` clamp to
       a minimum module height (use `.module { min-height }` = 72px) so a panel can
       never be dragged to zero/negative height; add a guard test in verify.mjs that
       drags a divider to the extreme and asserts every `.module` stays >= 60px tall.
3. [ ] Add a subtle haptic-feel timing cue: when a swipe commits a view change,
       briefly pulse the active view-slot (CSS transform/opacity ~120ms) so the
       gesture feels acknowledged; gate behind `prefers-reduced-motion: reduce`.
4. [ ] Ensure pinch/two-finger-spread (the "more module spaces" gesture from
       `Screenshot_2026-03-11_at_16.47.20.png`) has `touch-action` set correctly on
       `.module-stack`/`.view-track` so the browser never hijacks it; document the
       chosen touch-action values inline and screenshot the stack mid-gesture.
5. [ ] **Generate the next batch from `.mouse_build/TASK_TEMPLATE.md`:** choose the
       least-recently-used focus area, write a new `Batch 3` block with 4 concrete
       tasks + this same final task, and append it to `.mouse_build/BACKLOG.md`. This
       is what keeps the loop alive — never skip it.
