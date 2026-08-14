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
    /// Pinned deliberately. `@anthropic-ai/claude-code`'s current releases ship `bin/claude.exe`,
    /// a per-platform NATIVE binary, with the JS bundle only as a fallback; iOS cannot execute
    /// the binary. The 1.0.x line is the last that is JavaScript the whole way down, and it is
    /// what STATUS.md records running on the phone.
    static let claudeCode = CodingAgent(
        id: "claude-code",
        name: "Claude Code",
        runtime: .node,
        install: "npm i -g @anthropic-ai/claude-code@1.0.128",
        launch: "claude",
        executable: "claude",
        // Without a key the CLI waits for a login it cannot get on a phone, which is what a
        // three-minute silence and no output turned out to be.
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
        install: "pip install hermes-agent",
        // Hermes is a TUI, and a TUI is the gap this container does not host. It does not need
        // one: `tui_gateway` is how Hermes already talks to front-ends that are not a terminal —
        // the Telegram bot is one — speaking newline-delimited JSON over stdio,
        // `{"id": …, "command": …}` in, events out. A protocol, not a screen.
        launch: "python -m tui_gateway.entry",
        executable: "hermes",
        // Not a key: an address. Hermes runs on a machine and this is a client of its gateway,
        // which is the shape its Telegram front-end already has.
        setting: Setting(name: "HERMES_GATEWAY", placeholder: "host:port",
                         secret: false, exported: true),
        // MEASURED, not guessed: `pkg install python` lands CPython 3.14.6, and that wasi build
        // answers `python -m pip --version` with "No module named pip" and `ensurepip` with "No
        // module named ensurepip". There is no way to install a Python package on this device
        // today, so `pip install hermes-agent` cannot run, and hermes-agent's own native
        // dependencies would be the next wall behind it.
        //
        // The way in is the one Telegram uses: Hermes runs on a machine, and the chat front-end
        // is a CLIENT of its gateway. That is a network client this container can be, and it is
        // the next thing to build here.
        blocked: "no pip on the device — reachable by running hermes elsewhere and connecting to its gateway"
    )
}
