# Mouse — Evolution Backlog

Append-only queue of task batches, each instantiated from
`.mouse_build/TASK_TEMPLATE.md`. The driver (`mouse-evolve` cron) executes the
oldest `status: pending` batch, marks it `done`, and its final task appends the
next batch. The loop never ends because every batch's last task re-seeds the queue.

Legend: `[ ]` pending · `[x]` done · `[-]` skipped (note why)

---

## Batch 1 — focus: fidelity — 2026-06-23 — status: pending
1. [ ] Measure module-card corner radius, border color, and backdrop-blur against
       `sketches/Screenshot_2026-03-11_at_16.47.20.png`; adjust `--radius` / `.module`
       in `src/style.css` until they match within ~1px.
2. [ ] Verify the Commit button amber (`--amber`) and its darker dropdown match the
       sketch's yellow-orange; tune if off. Confirm via a fresh verify screenshot.
3. [ ] Confirm code-editor syntax colors (tag/attr/str/heading) match the sketch
       legend; adjust `--syn-*` vars if any channel is wrong.
4. [ ] Add the "Follow link (cmd + click)" hint line to the code editor footer to
       match `Screenshot_2026-03-11_at_17.37.50.png`, gated so it only shows in the code view.
5. [ ] **Generate the next batch from `.mouse_build/TASK_TEMPLATE.md`:** choose the
       least-recently-used focus area, write a new `Batch 2` block with 4 concrete
       tasks + this same final task, and append it to `.mouse_build/BACKLOG.md`. This
       is what keeps the loop alive — never skip it.
