# Mouse — Self-Perpetuating Task Template

This is a TEMPLATE for generating a batch of improvement tasks for the Mouse app.
Its defining property: **the final task is always to create more tasks from this
template.** That makes the backlog self-replenishing — every batch ends by
seeding the next batch.

The recursion lives HERE, in the content. The scheduler is a single stable
recurring cron job (`mouse-evolve`) that re-reads this template each tick. No run
ever creates a new cron job, so this perpetuates forever without recursive
scheduling.

---

## How to instantiate a batch

1. Read `.mouse_build/BACKLOG.md`. Find the highest existing `Batch N` number.
2. Pick a **focus area** for the new batch (rotate through the list below; pick the
   one least recently used by scanning past batches in BACKLOG.md).
3. Emit a `Batch N+1` block with **4 concrete, verifiable tasks** drawn from that
   focus area, PLUS the mandatory final task (verbatim). Append it to BACKLOG.md.
4. Each task MUST be: specific, touch real files under `/Users/thyfriendlyfox/Projects/mouse`,
   and end in a state checkable by `npm run build` + `node .mouse_build/verify.mjs`.

## Batch shape (fill the slots)

```
## Batch {N} — focus: {FOCUS_AREA} — {ISO_DATE} — status: pending
1. [ ] {concrete task in this focus area}
2. [ ] {concrete task in this focus area}
3. [ ] {concrete task in this focus area}
4. [ ] {concrete task in this focus area}
5. [ ] {FINAL TASK — verbatim below}
```

## The FINAL TASK (always task 5, copy verbatim)

> **Generate the next batch from `.mouse_build/TASK_TEMPLATE.md`:** choose the
> least-recently-used focus area, write a new `Batch {N+1}` block with 4 concrete
> tasks + this same final task, and append it to `.mouse_build/BACKLOG.md`. This
> is what keeps the loop alive — never skip it.

---

## Focus areas (rotate)

- **fidelity** — tighten pixel-match to `sketches/` (spacing, fonts, glass blur, colors, icons).
- **gestures** — swipe/pinch/drag-resize robustness; momentum; haptic-feel timing.
- **demo-realism** — richer MockRelay scripts (multi-agent, errors, long output, y/n flows).
- **resilience** — relay reconnect, error toasts, empty/loading states, offline handling.
- **a11y** — focus order, ARIA roles, reduced-motion, contrast, keyboard nav.
- **performance** — bundle size, lazy view mounting, xterm fit throttling, RAF batching.
- **tests** — expand `.mouse_build/verify.mjs` assertions; add per-view snapshot diffs.
- **polish** — micro-animations, transitions, loading skeletons, toast styling.

## Invariants every batch must preserve
- `npx tsc --noEmit` exits 0.
- `npm run build` exits 0.
- `node .mouse_build/verify.mjs` prints `VERIFY: PASS`.
- Each completed batch is committed to git with a clear message.
- The final task is executed so BACKLOG.md always has a fresh pending batch.
