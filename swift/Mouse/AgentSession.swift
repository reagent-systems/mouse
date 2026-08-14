import Foundation

/// The Agent container's state: which agent is chosen, whether it is here yet, and the exchange
/// so far.
///
/// The agent runs through a `TerminalSession` on the workspace — the same msh, the same npm, the
/// same Node the Terminal container uses. Nothing about the agent is special-cased into the app;
/// this drives its published CLI the way a person would.
///
/// One-shot prompts, not an interactive session. Every agent here has a print mode
/// (`claude -p "…"`) that answers and exits, and that mode needs no ANSI screen. The interactive
/// TUI is the larger gap system.md names, and hosting it belongs with the phase-T screen the
/// Terminal container already owns — not here, pretending.
@MainActor
@Observable
final class AgentSession {
    struct Message: Identifiable {
        enum Author { case you, agent, note }
        let id = UUID()
        let author: Author
        var text: String
    }

    private(set) var messages: [Message] = []
    /// Nil until a workspace is open — the agent works on a project, like everything else here.
    private(set) var terminal: TerminalSession?

    var agent: CodingAgent {
        didSet {
            guard agent.id != oldValue.id else { return }
            UserDefaults.standard.set(agent.id, forKey: Self.agentKey)
            installed = nil
            exported = false
        }
    }

    /// Nil until asked, then the answer to "is this agent's executable here".
    private(set) var installed: Bool?
    /// Whether this session has already exported the agent's saved setting.
    private var exported = false
    private(set) var working = false
    /// Shown above the input when the last attempt could not proceed.
    private(set) var problem: String?

    private static let agentKey = "agentContainerAgent"
    /// How long a single command may hold the terminal before the container gives up on it.
    /// Installing an agent is a real download, so this is minutes rather than seconds.
    private static let patience: TimeInterval = 180

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.agentKey)
        agent = CodingAgent.all.first { $0.id == saved } ?? CodingAgent.claudeCode
    }

    /// Point the session at the ring's workspace. Cheap and idempotent — the view calls it on
    /// every appearance, and a workspace that has not changed keeps its terminal and its history.
    func attach(root: URL?) {
        guard let root else { terminal = nil; return }
        guard terminal?.root != root else { return }
        terminal = TerminalSession(root: root)
        messages = []
        installed = nil
        exported = false
    }

    /// Ask the agent. Installs it first if this is the first time, because an agent that is not
    /// here yet is a download, not an error.
    func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !working else { return }
        guard let terminal else {
            problem = "open a project in the Files container"
            return
        }
        if let blocked = agent.blocked {
            problem = blocked
            return
        }
        guard AgentSettings.shared.isSet(for: agent) else {
            problem = "\(agent.setting?.name ?? "setup") first"
            return
        }
        problem = nil
        working = true
        defer { working = false }

        messages.append(Message(author: .you, text: prompt))

        // The saved setup, into the session's environment. Once per session: `export` persists
        // for the life of the shell, and repeating it would put the key in the transcript twice.
        if !exported, let line = AgentSettings.shared.exportLine(for: agent) {
            _ = await run(line, on: terminal)
            exported = true
        }

        if installed != true {
            messages.append(Message(author: .note, text: agent.install))
            let install = await run(agent.install, on: terminal)
            guard install.ok else {
                // The command's own words, not a summary of them: "command not found: pip" says
                // what to do next and "\(agent.name) did not install" does not.
                problem = install.text.isEmpty ? "\(agent.name) did not install" : install.text
                return
            }
            installed = true
        }

        // The prompt is passed as ONE argument. Quoting it here rather than trusting the shell
        // to keep a sentence together is the difference between asking a question and running
        // the words in it as commands.
        let quoted = prompt.replacingOccurrences(of: "'", with: "'\\''")
        let answer = await run("\(agent.launch) -p '\(quoted)'", on: terminal)
        messages.append(Message(author: .agent, text: answer.text.isEmpty
            ? "\(agent.launch) printed nothing" : answer.text))
        if !answer.ok { problem = answer.text }
    }

    /// Run one command and wait for it to finish, answering with what it printed and whether it
    /// FAILED. `TerminalSession.run` is fire-and-forget, so completion is observed rather than
    /// awaited.
    ///
    /// Two things this got wrong, both of which turned a plain failure into `(no output)` on
    /// screen. It waited only on `isRunning`, but a command that takes the terminal as a
    /// full-screen `program` leaves that false — so the wait ended immediately and the next
    /// command was refused, printing nothing at all. And it called any new line success, so
    /// `msh: command not found: pip` counted as a successful install and the launch went ahead.
    /// An error line is a failure, and its text is the most useful thing on the screen.
    private func run(_ command: String, on terminal: TerminalSession) async -> (ok: Bool, text: String) {
        let before = terminal.lines.count
        guard terminal.run(command) else { return (false, "the terminal is busy") }
        // BOUNDED. An installed bin that msh launches interactively becomes a full-screen
        // program and owns the terminal until it decides to leave — `claude -p` does exactly
        // that and was still holding it after ninety seconds with nothing printed. An unbounded
        // wait here is a container that spins forever with no way to say why.
        let deadline = Date().addingTimeInterval(Self.patience)
        while terminal.isRunning || terminal.program != nil {
            if Date() > deadline {
                terminal.interrupt()
                let printed = Array(terminal.lines[before...]).filter { $0.kind != .command }
                    .map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return (false, printed.isEmpty
                    ? "\(command) is still running after \(Int(Self.patience))s and printed nothing"
                    : printed)
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        let produced = Array(terminal.lines[before...]).filter { $0.kind != .command }
        let failed = produced.contains { $0.kind == .error }
        let text = produced.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (!failed, text)
    }

}
