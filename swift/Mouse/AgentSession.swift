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
        }
    }

    /// Nil until asked, then the answer to "is this agent's executable here".
    private(set) var installed: Bool?
    private(set) var working = false
    /// Shown above the input when the last attempt could not proceed.
    private(set) var problem: String?

    private static let agentKey = "agentContainerAgent"

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
        problem = nil
        working = true
        defer { working = false }

        messages.append(Message(author: .you, text: prompt))

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
        while terminal.isRunning || terminal.program != nil {
            try? await Task.sleep(for: .milliseconds(120))
        }
        let produced = Array(terminal.lines[before...]).filter { $0.kind != .command }
        let failed = produced.contains { $0.kind == .error }
        let text = produced.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (!failed, text)
    }

}
