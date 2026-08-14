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

        guard let terminal else {
            problem = "open a project in the Files container"
            return
        }
        // Embedded: the agent's loop runs as Python steps on THIS device, and Mouse executes
        // what each step asks for. Nothing leaves the phone except the model call.
        if agent.embedded {
            await askEmbedded(prompt, terminal: terminal)
            return
        }

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

    /// One conversation turn of the embedded agent.
    ///
    /// The engine's WASI is synchronous and its stdin answers EOF, so there is no resident
    /// process — each STEP is one Python invocation. Swift writes the turn state to a file,
    /// Python decides (answer, or a tool request) and exits, Swift executes the tool natively
    /// and reruns Python with the result. The model call is a tool like any other, on
    /// URLSession's TLS, because this Python has no ssl and never will.
    private func askEmbedded(_ prompt: String, terminal: TerminalSession) async {
        guard let api = AgentAPI(address: AgentSettings.shared.address(for: agent),
                                 key: AgentSettings.shared.value(for: agent)) else {
            problem = "that is not an address"
            return
        }
        // The runtime is a download, not an assumption.
        if RuntimeStore.installed("python") == nil {
            messages.append(Message(author: .note, text: "pkg install python"))
            let landed = await run("pkg install python", on: terminal)
            guard landed.ok else {
                problem = landed.text.isEmpty ? "python did not install" : landed.text
                return
            }
        }
        let root = terminal.root
        let bridge = root.appendingPathComponent(".hermes-bridge", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
            try Self.stepDriver.write(to: bridge.appendingPathComponent("step.py"),
                                      atomically: true, encoding: .utf8)
        } catch {
            problem = "\(error.localizedDescription)"
            return
        }

        var turn: [[String: String]] = messages.compactMap { message in
            switch message.author {
            case .you: return ["role": "user", "content": message.text]
            case .agent: return ["role": "assistant", "content": message.text]
            case .note: return nil
            }
        }
        // The prompt this call is answering is already in `messages`; `turn` above carries it.

        for _ in 0..<6 {
            do {
                let data = try JSONSerialization.data(withJSONObject: ["messages": turn])
                try data.write(to: bridge.appendingPathComponent("turn.json"))
                try? FileManager.default.removeItem(at: bridge.appendingPathComponent("out.json"))
            } catch {
                problem = "\(error.localizedDescription)"
                return
            }
            let step = await run("python /.hermes-bridge/step.py", on: terminal)
            guard let data = try? Data(contentsOf: bridge.appendingPathComponent("out.json")),
                  let out = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                problem = step.text.isEmpty ? "the step produced no output" : step.text
                return
            }
            if let answer = out["answer"] as? String {
                messages.append(Message(author: .agent, text: answer))
                return
            }
            guard let tool = out["tool"] as? String else {
                problem = "the step asked for neither an answer nor a tool"
                return
            }
            let args = out["args"] as? [String: Any] ?? [:]
            messages.append(Message(author: .note, text: tool))
            switch tool {
            case "llm.complete":
                let asked = (args["messages"] as? [[String: Any]] ?? []).compactMap { m -> (String, String)? in
                    guard let role = m["role"] as? String, let content = m["content"] as? String else { return nil }
                    return (role, content)
                }
                do {
                    let reply = try await api.complete(asked)
                    turn.append(["role": "tool", "name": tool, "content": reply])
                } catch {
                    problem = "\(error)"
                    messages.append(Message(author: .agent, text: "\(error)"))
                    return
                }
            case "shell":
                let command = args["command"] as? String ?? ""
                let result = await run(command, on: terminal)
                turn.append(["role": "tool", "name": tool, "content": result.text])
            case "read_file":
                let path = args["path"] as? String ?? ""
                let text = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
                turn.append(["role": "tool", "name": tool, "content": text])
            default:
                turn.append(["role": "tool", "name": tool, "content": "unknown tool: \(tool)"])
            }
        }
        problem = "six steps without an answer"
    }

    /// The per-step driver. Stage 3 replaces this with Hermes's own loop, installed by pip;
    /// the protocol it speaks to Mouse stays exactly this.
    private static let stepDriver = """
    import json
    turn = json.load(open('/.hermes-bridge/turn.json'))
    msgs = turn['messages']
    out = None
    if msgs and msgs[-1].get('role') == 'tool' and msgs[-1].get('name') == 'llm.complete':
        out = {"answer": msgs[-1]['content']}
    else:
        system = {"role": "system", "content": "You are Hermes Agent, running embedded in Mouse on an iPhone. Mouse executes your tools. Answer concisely."}
        asking = [system] + [m for m in msgs if m.get('role') in ('user', 'assistant')]
        out = {"tool": "llm.complete", "args": {"messages": asking}}
    json.dump(out, open('/.hermes-bridge/out.json', 'w'))
    """

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
        // Screenless: this container has no terminal grid, and an agent handed one never
        // returns. `claude -p` answers in three seconds down this path and hangs forever down
        // the other.
        guard terminal.run(command, screenless: true) else { return (false, "the terminal is busy") }
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
