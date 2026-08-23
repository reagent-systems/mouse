import Foundation

/// The coding agents the Agent container can drive.
///
/// Nothing here is bundled. Each entry carries the agent's OWN install command, verbatim from
/// its documentation, and the container runs it through the same msh + npm + Node the terminal
/// uses — the acceptance test system.md sets for this app. The catalog is the part that ships:
/// which agents exist, what each needs, and how to start it.
///
/// Oh My Pi (`omp`) is deliberately absent. It is a Bun CLI with Rust native bindings, and Bun
/// is a native binary — iOS will not execute one, the same wall that stops opencode's Go TUI and
/// current claude-code's `claude.exe`. Listing it as choosable would be a lie; it returns when
/// there is a wasm Bun or an `omp` server this app can speak to.
struct CodingAgent: Identifiable, Sendable, Hashable {
    let id: String
    /// What the picker shows.
    let name: String
    /// The runtime it needs, named the way the user would install it (`pkg install …`).
    let runtime: Runtime
    /// Its own install command, exactly as its documentation gives it.
    let install: String
    /// The command that starts an interactive session once installed.
    let launch: String
    /// The executable the install is expected to leave behind, used to answer "is it here yet".
    let executable: String
    /// The env var that redirects this agent's endpoint when the address field is set, for
    /// CLI agents. nil when the agent has no such override, or is embedded (the embedded path
    /// uses the address directly).
    let endpointVariable: String?

    /// The agent's OWN sign-in or setup command — a full-screen program the container hosts
    /// on an embedded terminal screen, so it works the way the agent documents it instead of
    /// the way a settings form imagines it. nil when a key is the only way in.
    let login: String?
    /// What the row that starts it says: the agent's own word for it.
    let loginTitle: String?
    /// The file, under the shared home, that a finished sign-in/setup leaves behind — the
    /// container's evidence that the agent can answer. nil when a saved key is the only test.
    let configured: String?
    /// What that file must SAY to count — any of these substrings. Empty means existing is
    /// enough (claude writes its credential file only on success); hermes writes a default
    /// config.yaml the moment its setup starts, and only a chosen provider or endpoint
    /// (`provider:` / `base_url:` under `model:`) means the setup went through.
    let configuredWhen: [String]

    /// Flags that make the agent's print mode STREAM its answer as JSON lines, so the chat can
    /// show (and speak) the first phrase while the rest is still arriving. nil when the agent
    /// answers only whole; the container then waits for the whole.
    let stream: String?

    /// Whether this agent runs EMBEDDED: its loop as Python steps on the device's own wasi
    /// CPython, with Mouse executing every tool the loop asks for. The alternative is a local
    /// CLI on the Node layer (Claude Code).
    let embedded: Bool

    /// The one thing this agent needs before it can answer, saved between launches.
    let setting: Setting?

    struct Setting: Sendable, Hashable {
        /// The environment variable, or the settings key — the agent's own name for it.
        let name: String
        /// What the field asks for. Short: it sits under a text field, not in a manual.
        let placeholder: String
        /// Keychain rather than UserDefaults.
        let secret: Bool
        /// Exported into the shell before the agent runs.
        let exported: Bool
    }

    /// Set when the agent cannot work on this device today. The picker shows the entry and the
    /// reason rather than hiding it — a missing choice reads as an oversight.
    let blocked: String?

    enum Runtime: String, Sendable {
        case node
        case python

        /// The `pkg` name that provides it, or nil when the app already carries it.
        var packageName: String? {
            switch self {
            case .node: return nil          // the Node layer is the app
            case .python: return "python"   // CPython wasm32-wasi, downloaded on demand
            }
        }
    }

    static let all: [CodingAgent] = [claudeCode, hermes]

    /// Claude Code — Node, so it runs on the layer this app already is.
    ///
    /// Pinned deliberately, and MOVED: 1.0.128 died everywhere in 2026 (it awaits statsig
    /// initialisation and statsig.anthropic.com is NXDOMAIN now), and the installer-stub era
    /// that ships `claude.exe` — a native binary iOS can never run — starts by 2.1.232. The
    /// 2.1.9x line is the newest that is JavaScript the whole way down, and 2.1.98 is measured
    /// answering through this engine's streaming pipeline in one second.
    static let claudeCode = CodingAgent(
        id: "claude-code",
        name: "Claude Code",
        runtime: .node,
        install: "npm i -g @anthropic-ai/claude-code@2.1.98",
        launch: "claude",
        executable: "claude",
        // ANTHROPIC_BASE_URL, when the address field is set: any Anthropic-shaped endpoint —
        // a relay, a proxy, a test double — and empty means the real API.
        endpointVariable: "ANTHROPIC_BASE_URL",
        // `setup-token` is Claude Code's documented sign-in: it renders its own screen,
        // prints the OAuth URL, takes the pasted code, and stores a long-lived credential in
        // the SHARED home (/home) — sign in once, every project has it. MEASURED rendering
        // and prompting on this engine.
        login: "claude setup-token",
        loginTitle: "sign in",
        configured: ".claude/.credentials.json",
        configuredWhen: [],
        // MEASURED on 2.1.98: one `stream_event` line per text delta, then `assistant`, then a
        // `result` line carrying the whole answer. `--verbose` is required for stream-json.
        stream: "--output-format stream-json --verbose --include-partial-messages",
        embedded: false,
        // The other way in. Either this key or a completed sign-in satisfies the container.
        setting: Setting(name: "ANTHROPIC_API_KEY", placeholder: "sk-ant-…",
                         secret: true, exported: true),
        blocked: nil
    )

    /// Hermes Agent — Python, on the CPython wasm build `pkg install python` fetches.
    ///
    /// Its own README offers local, Docker and SSH shell backends, which is why it fits here at
    /// all: the local backend wants `fork`/`exec` that iOS does not have, and the remote ones are
    /// already network-shaped.
    static let hermes = CodingAgent(
        id: "hermes",
        name: "Hermes Agent",
        runtime: .python,
        install: "pip install hermes-agent==0.19.0",
        // Its CLI. Unused for an embedded agent — the loop runs through the file bridge — and
        // named truthfully rather than left pointing at an internal gateway it once launched.
        launch: "hermes",
        executable: "hermes",
        endpointVariable: nil,
        // `hermes setup`, exactly — the wizard itself, on the terminal screen inside the
        // container, now that WASI programs can read what a person types. Its own sections,
        // its own defaults, its own files in ~/.hermes (the shared home). No curses on this
        // Python, so hermes's numbered-menu fallbacks render; no network from this Python
        // yet, so the Nous Portal login inside it cannot complete — bring-your-own-key
        // providers and custom endpoints do.
        login: "python -m hermes_cli.main setup",
        loginTitle: "set up",
        configured: ".hermes/config.yaml",
        configuredWhen: ["provider:", "base_url:"],
        stream: nil,
        // Embedded, per the user's architecture: the loop runs on the device's Python, and
        // Mouse is the scoped tool surface it drives — model calls on URLSession's real TLS
        // (this Python has no ssl), shell on msh, files on the workspace.
        embedded: true,
        // Not a key: an address. Hermes runs on a machine and this is a client of its gateway,
        // which is the shape its Telegram front-end already has.
        // The key, not the address. Hermes requires bearer auth on every deployment including
        // the loopback bind, and `hermes gateway` serves 127.0.0.1:8642 by default — which the
        // simulator reaches — so the key is the one thing that cannot be defaulted.
        // No field of Mouse's: provider, endpoint, key and model are hermes's own config,
        // written by its setup and read by its loop — the way `hermes chat` does it.
        setting: nil,
        // MEASURED, not guessed: `pkg install python` lands CPython 3.14.6, and that wasi build
        // answers `python -m pip --version` with "No module named pip" and `ensurepip` with "No
        // module named ensurepip". There is no way to install a Python package on this device
        // today, so `pip install hermes-agent` cannot run, and hermes-agent's own native
        // dependencies would be the next wall behind it.
        //
        // The way in is the one Telegram uses: Hermes runs on a machine, and the chat front-end
        // is a CLIENT of its gateway. That is a network client this container can be, and it is
        // the next thing to build here.
        // Not blocked any more: with an address it works, and without one the setup field is
        // what asks for it. The wall was never Hermes — it was having nowhere to send to.
        blocked: nil
    )
}
