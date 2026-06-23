# Mouse

**Mouse** is a mobile and desktop client for working in **GitHub Codespaces** with AI agents: sign in with GitHub, pick or create a Codespace, connect through a small **relay**, and use an in-app terminal plus agent composer.

Repository: **[github.com/reagent-systems/mouse](https://github.com/reagent-systems/mouse)**

## Features

- **GitHub device flow** — Sign in from the phone or desktop without embedding secrets in the app.
- **Codespaces** — List, create, start, and connect to Codespaces backed by your GitHub App or classic OAuth app.
- **Terminal** — xterm.js session over WebSocket, bridged by [`@mouse-app/relay`](https://www.npmjs.com/package/@mouse-app/relay) running inside the Codespace.
- **AI agents** — Composer and stack UI for agents (e.g. OpenCode) relayed through the same connection.
- **Native shells** — **Capacitor** for iOS/Android (including native HTTP for GitHub APIs in the WebView) and **Electron** for desktop.

## Stack

| Layer | Technology |
| ----- | ---------- |
| UI & logic | TypeScript, Vite |
| Terminal | xterm.js |
| Mobile | Capacitor 8 (`@capacitor/ios`, `@capacitor/android`) |
| Desktop | Electron |
| Auth | GitHub Device Flow (`src/auth/GitHubAuth.ts`) |
| Codespaces API | REST (`src/codespaces/CodespacesApi.ts`) |

## Prerequisites

- **Node.js 18+**
- **npm**
- For **iOS**: Xcode and CocoaPods / SPM as required by Capacitor
- For **Android**: Android Studio / SDK as required by Capacitor
- A **GitHub account** with **Codespaces** access and a configured **GitHub App** (or OAuth app) for the client — see below

## Quick start

```bash
git clone https://github.com/reagent-systems/mouse.git
cd mouse
npm install
cp .env.example .env
# Edit .env: VITE_GITHUB_CLIENT_ID, VITE_GITHUB_APP_SLUG (for GitHub App mode), etc.
npm run dev
```

Open the URL Vite prints (typically `http://localhost:5173`).

### GitHub configuration

Mouse needs a **Client ID** and, for **GitHub App** sign-in, an app **install** on your account and **`VITE_GITHUB_APP_SLUG`** so the in-app install step can open the right GitHub URL.

Copy **`.env.example`** to **`.env`**, fill in the variables, then restart dev or rebuild:

```bash
npm run build
```

Details and troubleshooting (Codespaces permissions, `Resource not accessible by integration`, OAuth vs GitHub App) are documented in **`.env.example`**.

### Codespaces & the relay

GitHub does not expose a raw terminal stream to arbitrary third-party apps. Mouse connects to **`@mouse-app/relay`** on port **2222** inside the Codespace (forwarded to `*.app.github.dev`).

- **npm package:** [`@mouse-app/relay`](https://www.npmjs.com/package/@mouse-app/relay) — see [`relay/README.md`](relay/README.md).
- **Auto-start:** This repo includes [`.devcontainer/devcontainer.json`](.devcontainer/devcontainer.json) so the relay can start automatically when you open a Codespace for **this** repository. For other projects, merge the snippet from the app’s “Relay” setup screen or the relay README into your own `.devcontainer`.

## Scripts

| Command | Description |
| ------- | ----------- |
| `npm run dev` | Vite dev server |
| `npm run build` | Typecheck + production bundle to `dist/` |
| `npm run preview` | Preview the production build |
| `npm run electron:dev` | Electron + Vite (desktop dev) |
| `npm run electron:dist` | Build a desktop installer (see `electron-builder` config in `package.json`) |
| `npm run cap:sync` | Build + `cap sync` (web assets into `ios/` / `android/`) |
| `npm run cap:ios:sim` | Sync + build and run on a pinned iOS Simulator (see `package.json`) |
| `npm run cap:open:ios` / `cap:open:android` | Open native projects in Xcode / Android Studio |

## Project layout

```
src/
  app.ts              # App shell: auth → codespace picker → main (stack + bottom bar)
  auth/               # GitHub device flow, install gate, AuthGate UI
  codespaces/         # Codespace picker, GitHub API helpers, relay snippet
  terminal/           # Relay WebSocket, xterm view
  modules/            # Module stack, agent modules, code editor view
  components/         # Bottom bar, etc.
relay/                # Publishable @mouse-app/relay package (PTY WebSocket bridge)
electron/             # Electron main process
ios/ / android/       # Capacitor native projects (generated/synced)
```

## Contributing

Issues and pull requests are welcome in this repository. For UI work, follow the
design system in [`STYLEGUIDE.md`](STYLEGUIDE.md).

## License

No `LICENSE` file is present in the tree yet; add one to make terms explicit for contributors and distributors.
