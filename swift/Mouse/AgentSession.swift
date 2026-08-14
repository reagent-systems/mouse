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
            guard await run(agent.install, on: terminal) else {
                problem = "\(agent.name) did not install"
                return
            }
            installed = true
        }

        // The prompt is passed as ONE argument. Quoting it here rather than trusting the shell
        // to keep a sentence together is the difference between asking a question and running
        // the words in it as commands.
        let quoted = prompt.replacingOccurrences(of: "'", with: "'\\''")
        let answered = await run("\(agent.launch) -p '\(quoted)'", on: terminal)
        let reply = transcriptTail(of: terminal)
        messages.append(Message(author: .agent, text: reply.isEmpty
            ? (answered ? "(no output)" : "\(agent.launch) failed") : reply))
    }

    /// Run one command and wait for it to finish. `TerminalSession.run` is fire-and-forget, so
    /// completion is observed rather than awaited — `isRunning` falling is the signal.
    private func run(_ command: String, on terminal: TerminalSession) async -> Bool {
        let before = terminal.lines.count
        guard terminal.run(command) else { return false }
        while terminal.isRunning {
            try? await Task.sleep(for: .milliseconds(120))
        }
        return terminal.lines.count > before
    }

    /// Everything the last command printed: the lines after its echoed command line.
    private func transcriptTail(of terminal: TerminalSession) -> String {
        guard let start = terminal.lines.lastIndex(where: { $0.kind == .command }) else { return "" }
        return terminal.lines[terminal.lines.index(after: start)...]
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
