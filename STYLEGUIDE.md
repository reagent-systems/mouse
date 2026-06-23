# Mouse — Style Guide

The design language for **Mouse**: a mobile‑first, dark, **liquid‑glass** interface
for running AI coding agents in GitHub Codespaces. This document is the source of
truth for visual and interaction design. All UI styles live in
[`src/style.css`](src/style.css) and use plain CSS with custom properties (design
tokens) — there is no CSS framework.

---

## 1. Principles

- **Mobile‑first.** The app renders inside a phone‑sized frame (`max 430 × 932px`);
  design for touch targets and one‑handed use first, desktop second.
- **Liquid glass.** Surfaces are frosted/translucent panels over a dark background,
  with soft borders and generous corner radii.
- **Dark, low‑chroma base, warm accent.** Neutral charcoal surfaces (Ayu‑Dark
  inspired) with a single warm amber accent for primary actions.
- **Calm motion.** Short, springy transitions; spinners and blinks only to convey
  live state.
- **Content is honest and minimal.** No decorative reassurance copy (see §9).

---

## 2. Design tokens

Defined as CSS custom properties on `:root` in `src/style.css`. **Always reference
tokens; never hard‑code hex values in component CSS or inline styles.**

### Color

| Token | Value | Use |
| ----- | ----- | --- |
| `--bg` | `#0f1419` | App background |
| `--panel` | `#151a1e` | Solid panel base |
| `--surface` | `rgba(230,225,207,0.045)` | Subtle raised surface / inputs |
| `--surface-2` | `rgba(230,225,207,0.07)` | Slightly stronger surface |
| `--border` | `rgba(45,54,64,0.85)` | Default hairline border |
| `--border-bright` | `#2d3640` | Emphasized / hover border |
| `--text` | `#e6e1cf` | Primary text |
| `--text-dim` | `#8a9199` | Secondary text |
| `--text-faint` | `#5c6773` | Tertiary / hints / placeholders |
| `--accent` | `#ffb454` | Primary actions, focus, brand |
| `--accent-muted` | `rgba(255,180,84,0.22)` | Accent fills / selection |
| `--amber` | `#ff8f40` | Warm secondary (commit, starting) |
| `--green` | `#b8cc52` | Success, prompts, additions |
| `--red` | `#f07178` | Errors, deletions |
| `--blue` | `#59c2ff` | Info, directories, modified |
| `--pink` | `#d2a6ff` | Tags, untracked |
| `--cyan` | `#95e6cb` | TypeScript / accents |
| `--on-accent` | `#0f1419` | Text/icons on accent fills |

**Syntax‑highlight tokens** (code views): `--syn-tag`, `--syn-attr`, `--syn-str`,
`--syn-kw`, `--syn-cmt`, `--syn-num`, `--syn-fn`, `--syn-text`.

### Shape & spacing

| Token | Value | Use |
| ----- | ----- | --- |
| `--radius` | `22px` | Cards, modules, large surfaces |
| `--radius-sm` | `14px` | Small cards, buttons, inputs |
| `--safe-area-top` / `--safe-area-bottom` | `env(safe-area-inset-*)` | Device notch / home indicator padding |

Spacing uses direct `px` values; common rhythm is **4 / 6 / 8 / 10 / 12 / 14 / 16 / 24px**.

### Semantic color mapping

- **Primary action** → `--accent` background, `--on-accent` text.
- **Success / git additions / shell prompt** → `--green`.
- **Error / git deletions** → `--red`.
- **Info / directories / modified files** → `--blue`.
- **Live/in‑progress** → `--amber` (e.g. `state-starting`, commit button).

---

## 3. Typography

- **UI font:** `system-ui, -apple-system, 'Segoe UI', sans-serif`.
- **Mono font:** `'SF Mono', 'Fira Code', ui-monospace, monospace` — terminals,
  code, hashes, commands, device codes.
- **Base size:** `14px`. Common scale: `28` (auth title), `18/16/15` (section
  titles), `13/12.5/12` (body), `11/10` (hints, labels, meta).
- **Labels** (section headers like `CHANGES`, `GRAPH`): uppercase, `10px`,
  `font-weight: 600`, letter‑spacing `~0.08em`, color `--text-dim`.
- Truncate single‑line text with ellipsis (`white-space:nowrap; overflow:hidden;
  text-overflow:ellipsis`) rather than wrapping in dense rows.

---

## 4. Surfaces & layout

- **`.glass`** — the shared frosted surface utility (background + 40px blur +
  hairline border). Apply alongside a component class, e.g.
  `class="auth-card glass"`. Use it for any floating card/panel.
- **`.app`** — the phone frame: full height, `max-width: 430px`, `max-height: 932px`,
  with safe‑area padding. At `≥540px` it gains a rounded device‑style shadow.
- **`.module` / `.module-stack`** — the resizable, swipeable panel system. Modules
  are glass surfaces with `--radius` corners stacked vertically and separated by
  draggable `.module-divider`s.

---

## 5. Components

### Buttons

- **Primary** — `.auth-btn`: full‑width, `--accent` background, `--on-accent`
  text, radius `14px`, weight `600`. Hover brightens; `:disabled` drops opacity.
- **Outline** — `.auth-btn.auth-btn-outline`: translucent accent fill + accent
  border, for secondary actions.
- **Commit** — `.commit-btn`: `--amber` background (action‑warm), with an optional
  split dropdown `.commit-btn-drop`.
- **Icon button** — `.mic-btn`: 38px circle; `.listening` state adds accent glow.

### Inputs

- `.composer-input`, `.picker-create-input`, `.terminal-input`: transparent or
  `--surface` background, hairline border, `--text` color, accent/transparent
  focus, placeholder uses `--text-faint`.

### Cards

- `.auth-card`, `.cs-card`, `.relay-setup` — pair with `.glass`. Radius `--radius`
  (large) or `--radius-sm` (compact). Hover raises border to `--border-bright`.

### Status indicators

- **Agent status icon** `.agent-icon` with modifiers: `.spinning` (accent ring),
  `.waiting` (blue ring), `.done` (green ✓), `.error` (red ✕), `.idle` (outline).
- **Codespace state dot** `.cs-dot`: `.state-available` (green glow),
  `.state-stopped` (faint), `.state-starting` (amber, blinking).
- **Spinner** `.auth-spinner` — accent top on muted ring.

### Feedback

- **Toast** `.toast` — bottom‑center pill above the bottom bar, respects
  `--safe-area-bottom`, auto‑fades. Use for transient connection/status messages.
- **Loading / empty / error states** — center dim text for loading and empty;
  use `--red` for error text. Keep copy short and factual.

---

## 6. Motion

| Animation | Token / value | Use |
| --------- | ------------- | --- |
| `spin` | `0.8s linear infinite` | Spinners, active agent ring |
| `blink` | `1s` | "Starting" states |
| Panel swipe | `transform 0.28s cubic-bezier(0.25,0.46,0.45,0.94)` | View paging |
| Module add/remove | `flex/opacity 300ms cubic-bezier(0.34,1.56,0.64,1)` | Springy panel insert |
| Hover/state | `0.12s–0.2s` | Background/border transitions |

Keep durations short (≤300ms). Use the springy easing only for additive/spatial
changes (adding panels), the smoother easing for paging.

---

## 7. Iconography

Icons are **text glyphs / emoji** (e.g. `⬡`, `🎙`, `↻`, `▸/▾`, `✓`, `✕`), not an
icon font or SVG set (the GitHub mark is an inline SVG). Keep glyphs monochrome and
colored via `currentColor` or a token. Prefer simple, legible symbols.

---

## 8. Interaction & gestures

The panel system is gesture‑driven (`src/gestures/index.ts`):

- **Horizontal swipe** within a module pages between views (code/files/changes/…).
- **Pinch / spread** on the stack removes / adds a panel.
- **Vertical drag** on a divider resizes adjacent panels.

Provide non‑gesture fallbacks where practical and ensure touch targets are ≥32px.

---

## 9. UI content rules (required)

These are hard product rules for any visible copy:

- **No client‑side / privacy reassurance text.** Do **not** add subtitles,
  captions, or secondary lines (under titles, in drop zones, near uploads, etc.)
  that explain where data runs or whether it leaves the device.
- Forbidden patterns and close paraphrases (unless explicitly requested): mentions
  of *“browser”, “this tab”, “device”, “local”, “on your machine”, “not uploaded”,
  “not sent”, “stays in”, “processed only”, “offline”, “privacy”, “your data
  never…”*.
- If behavior/security must be documented, put it in product docs or an explicit
  legal/privacy section — never as default visible UI under headings or inside
  upload areas.
- Keep microcopy **functional**: say what a control does or the current state, not
  reassurance.

---

## 10. Do / Don’t

**Do**
- Reference design tokens for every color, radius, and accent.
- Reuse `.glass`, `.auth-btn`, `.cs-card`, status‑icon, and label patterns.
- Keep new panels consistent with the swipe/resize module model.
- Truncate dense rows; keep one accent per surface.

**Don’t**
- Hard‑code hex colors or one‑off radii in components or inline styles.
- Introduce a second primary accent or heavy drop shadows (the frame shadow aside).
- Add reassurance/privacy microcopy (see §9).
- Wrap long text in compact list rows.
