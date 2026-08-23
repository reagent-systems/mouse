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
            exported = false
            homed = false
        }
    }

    /// The id of the agent this session has installed, or nil. Keyed by agent, not a bare
    /// flag: a turn snapshots its agent (see `send`), and a flag would let a switch mid-turn
    /// mark the wrong one installed.
    private var installedFor: String?
    /// Whether this session has already exported the agent's saved setting.
    private var exported = false
    /// Whether this session has already pointed the shell at the shared agent home.
    private var homed = false
    private(set) var working = false
    /// Shown above the input when the last attempt could not proceed.
    private(set) var problem: String?
    /// True while the agent's own sign-in program owns the terminal screen. The container
    /// swaps the exchange for the screen, and the input field feeds the program.
    private(set) var loggingIn = false
    /// The last turn, timed from send: seconds to the first word of the answer, and to the
    /// whole of it. A voice agent lives or dies by the first number; it is shown, not hidden.
    private(set) var latency: (firstWord: TimeInterval?, whole: TimeInterval)?

    private static let agentKey = "agentContainerAgent"
    /// How long a single command may hold the terminal before the container gives up on it.
    /// Installing an agent is a real download, and one step of the embedded loop pays hermes's
    /// import bill — measured near four minutes warm on the wasi CPython — so this is generous
    /// on purpose. The startup cost itself is the named next problem in the brief.
    private static let patience: TimeInterval = 600

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
        installedFor = nil
        exported = false
        homed = false
    }

    /// Whether the agent can answer: its saved key, or — for an agent with its own sign-in —
    /// the credential that sign-in left in the SHARED home. Claude Code's `setup-token`
    /// writes `.claude/.credentials.json` under $HOME, and the container points every agent
    /// at `/home` (RuntimeStore.home on disk), so one sign-in covers every project.
    var authenticated: Bool {
        if AgentSettings.shared.isSet(for: agent) { return true }
        guard agent.login != nil else { return false }
        return FileManager.default.fileExists(
            atPath: RuntimeStore.home.appendingPathComponent(".claude/.credentials.json").path)
    }

    /// Point the session's shell at the shared home, once. Everything an agent keeps in
    /// $HOME — sign-in credential, config — lands in one place regardless of project; cwd
    /// stays the workspace, so the agent still works on THIS project.
    private func pointAtSharedHome(_ agent: CodingAgent, _ terminal: TerminalSession) async {
        guard !homed, !agent.embedded else { return }
        _ = await run("export HOME=/home", on: terminal)
        homed = true
    }

    /// Ask the agent. Installs it first if this is the first time, because an agent that is not
    /// here yet is a download, not an error.
    func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !working, !loggingIn else { return }
        // The turn belongs to the agent it was sent to. This function suspends many times,
        // and the picker stays live; reading `self.agent` at each step let a switch mid-turn
        // finish a Claude turn with Hermes's install and launch lines — Hermes's launch is
        // its TUI gateway, and the chat filled with its JSON-RPC. Measured, not imagined.
        let agent = self.agent
        if let blocked = agent.blocked {
            problem = blocked
            return
        }
        guard authenticated else {
            problem = agent.login == nil
                ? "\(agent.setting?.name ?? "setup") first"
                : "sign in, or \(agent.setting?.name ?? "a key") first"
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
            let started = Date()
            await askEmbedded(prompt, agent: agent, terminal: terminal)
            // Whole-answer only: the embedded loop's steps are file-bridged, so nothing of the
            // answer exists before the last one. The number is the honest one — hermes's
            // import bill per step is most of it.
            latency = (firstWord: nil, whole: Date().timeIntervalSince(started))
            return
        }

        await pointAtSharedHome(agent, terminal)

        // The saved setup, into the session's environment. Once per session: `export` persists
        // for the life of the shell, and repeating it would put the key in the transcript twice.
        if !exported, let line = AgentSettings.shared.exportLine(for: agent) {
            _ = await run(line, on: terminal)
            if let variable = agent.endpointVariable {
                let address = AgentSettings.shared.address(for: agent)
                if !address.isEmpty {
                    let url = address.contains("://") ? address : "http://" + address
                    _ = await run("export \(variable)=\(url)", on: terminal)
                }
            }
            exported = true
        }

        if installedFor != agent.id {
            messages.append(Message(author: .note, text: agent.install))
            let install = await run(agent.install, on: terminal)
            guard install.ok else {
                // The command's own words, not a summary of them: "command not found: pip" says
                // what to do next and "\(agent.name) did not install" does not.
                problem = install.text.isEmpty ? "\(agent.name) did not install" : install.text
                return
            }
            installedFor = agent.id
        }

        // The prompt is passed as ONE argument. Quoting it here rather than trusting the shell
        // to keep a sentence together is the difference between asking a question and running
        // the words in it as commands.
        let quoted = prompt.replacingOccurrences(of: "'", with: "'\\''")
        let started = Date()
        guard let flags = agent.stream else {
            let answer = await run("\(agent.launch) -p '\(quoted)'", on: terminal)
            messages.append(Message(author: .agent, text: answer.text.isEmpty
                ? "\(agent.launch) printed nothing" : answer.text))
            latency = (firstWord: nil, whole: Date().timeIntervalSince(started))
            if !answer.ok { problem = answer.errors.isEmpty ? answer.text : answer.errors }
            return
        }
        // Streaming: the agent message exists from the first delta and grows as the answer
        // arrives — the part a listener hears first. The `result` line, when it comes, is the
        // whole answer as the agent meant it and replaces what was assembled from deltas.
        messages.append(Message(author: .agent, text: ""))
        let index = messages.count - 1
        var assembled = ""
        var whole: String?
        var firstWordAt: Date?
        let answer = await run("\(agent.launch) -p '\(quoted)' \(flags)", on: terminal) { [weak self] line in
            guard let self else { return }
            switch Self.streamedLine(line) {
            case .delta(let text):
                if firstWordAt == nil { firstWordAt = Date() }
                assembled += text
                self.messages[index].text = assembled
            case .whole(let text):
                whole = text
            case .other:
                break
            }
        }
        let text = (whole ?? assembled).trimmingCharacters(in: .whitespacesAndNewlines)
        messages[index].text = text.isEmpty ? "\(agent.launch) printed nothing" : text
        latency = (firstWord: firstWordAt?.timeIntervalSince(started),
                   whole: Date().timeIntervalSince(started))
        if !answer.ok { problem = answer.errors.isEmpty ? answer.text : answer.errors }
    }

    /// One line of the agent's streamed output, classified. Claude Code's stream-json: text
    /// deltas ride in `stream_event` lines; the finished answer rides in the `result` line.
    /// Anything else — warnings, the init record, tool events — is not part of the answer.
    private enum StreamedLine { case delta(String), whole(String), other }

    private static func streamedLine(_ line: String) -> StreamedLine {
        guard line.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return .other }
        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return .other }
            return .delta(text)
        case "result":
            return .whole(object["result"] as? String ?? "")
        default:
            return .other
        }
    }

    /// Run the agent's own sign-in program on the terminal SCREEN, inside the container.
    /// Returns when the program exits; `authenticated` then says whether it took.
    func login() async {
        let agent = self.agent   // same rule as `send`: the sign-in belongs to one agent
        guard let command = agent.login, let terminal, !working, !loggingIn else { return }
        problem = nil
        await pointAtSharedHome(agent, terminal)
        if installedFor != agent.id {
            working = true
            messages.append(Message(author: .note, text: agent.install))
            let install = await run(agent.install, on: terminal)
            working = false
            guard install.ok else {
                problem = install.text.isEmpty ? "\(agent.name) did not install" : install.text
                return
            }
            installedFor = agent.id
        }
        loggingIn = true
        defer { loggingIn = false }
        guard terminal.run(command) else { return }
        while terminal.isRunning || terminal.program != nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        messages.append(Message(author: .note,
                                text: authenticated ? "signed in" : "sign-in did not finish"))
    }

    /// The user's way out of a sign-in that is going nowhere. One tap, decisive: claude's
    /// sign-in screen swallows ^C as a keystroke (MEASURED — like vite, it keeps running),
    /// and the terminal's two-press ritual belongs to the Terminal container, not a chat.
    func cancelLogin() {
        guard loggingIn else { return }
        terminal?.stopForProjectChange()
    }

    /// One conversation turn of the embedded agent.
    ///
    /// The engine's WASI is synchronous and its stdin answers EOF, so there is no resident
    /// process — each STEP is one Python invocation. Swift writes the turn state to a file,
    /// Python decides (answer, or a tool request) and exits, Swift executes the tool natively
    /// and reruns Python with the result. The model call is a tool like any other, on
    /// URLSession's TLS, because this Python has no ssl and never will.
    private func askEmbedded(_ prompt: String, agent: CodingAgent, terminal: TerminalSession) async {
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
        // The agent itself is a download too — its wheel and the pure part of its closure.
        if !FileManager.default.fileExists(
            atPath: Pip.sitePackages.appendingPathComponent("run_agent.py").path) {
            messages.append(Message(author: .note, text: agent.install))
            let landed = await run(agent.install, on: terminal)
            guard landed.ok else {
                problem = landed.text.isEmpty ? "\(agent.name) did not install" : landed.text
                return
            }
        }
        let root = terminal.root
        let bridge = root.appendingPathComponent(".hermes-bridge", isDirectory: true)
        // The step depends on the runtime shims (ssl, threads); pip lays them when IT runs,
        // but a send must not require a pip run to have happened since the last shim change.
        Pip.layShims(in: Pip.sitePackages)
        do {
            try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
            try Self.stepDriver.write(to: bridge.appendingPathComponent("step.py"),
                                      atomically: true, encoding: .utf8)
        } catch {
            problem = "\(error.localizedDescription)"
            return
        }

        // Hermes is single-turn v1: the prompt goes in, recorded model replies accumulate
        // as the loop replays. Conversation memory across sends is hermes's session state,
        // which lives in the workspace (`HOME=/`) — not re-fed through chat().
        var recorded: [String] = []

        for _ in 0..<6 {
            do {
                let data = try JSONSerialization.data(withJSONObject: [
                    "prompt": prompt, "recorded": recorded, "model": "hermes-agent",
                ])
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
            if let failure = out["error"] as? String {
                problem = failure + ((out["calls"] as? [[String: Any]]).map { " [calls: \($0)]" } ?? "")
                messages.append(Message(author: .agent, text: failure))
                return
            }
            guard out["tool"] as? String == "llm.complete" else {
                problem = "the step asked for neither an answer nor a tool"
                return
            }
            let args = out["args"] as? [String: Any] ?? [:]
            messages.append(Message(author: .note, text: "llm.complete"))
            let asked = (args["messages"] as? [[String: Any]] ?? []).compactMap { m -> (String, String)? in
                guard let role = m["role"] as? String, let content = m["content"] as? String else { return nil }
                return (role, content)
            }
            do {
                let reply = try await api.complete(asked.isEmpty ? [("user", prompt)] : asked)
                recorded.append(reply)
            } catch {
                problem = "\(error)"
                messages.append(Message(author: .agent, text: "\(error)"))
                return
            }
        }
                problem = "six steps without an answer"
    }

    /// One step of Hermes's OWN loop — `AIAgent.chat` behind a replayed openai transport.
    /// Recorded model replies replay in order; the first unrecorded call comes back as the
    /// llm.complete tool, Mouse answers it on URLSession, and the step reruns. See the brief's
    /// record-and-replay design; the driver is generated here so nothing ships half-configured.
    private static let stepDriver = "# One step of Hermes's own loop, per invocation. Mouse wrote turn.json; this decides.\n#\n# Hermes's transport is the openai SDK, which cannot import here (pydantic-core is compiled)\n# and could not connect if it did (wasi has no sockets). So a stand-in `openai` goes into\n# sys.modules BEFORE hermes imports: recorded responses replay in order, and the first\n# unrecorded call raises Capture — written out as the llm.complete tool for Mouse's URLSession.\nimport json, sys, types, traceback\n\nBRIDGE = \"/.hermes-bridge\"\nturn = json.load(open(BRIDGE + \"/turn.json\"))\nprompt = turn[\"prompt\"]\nrecorded = turn.get(\"recorded\", [])\nmodel_name = turn.get(\"model\", \"hermes-agent\")\n\nclass Capture(BaseException):\n    # BaseException on purpose: hermes wraps its model calls in retries that catch\n    # Exception, and a captured request must walk straight through them to the driver.\n    def __init__(self, request):\n        self.request = request\n\n_replay = {\"next\": 0}\n_calls = []\n\nclass _Message:\n    def __init__(self, content):\n        self.role, self.content, self.tool_calls = \"assistant\", content, None\n    def model_dump(self):\n        return {\"role\": self.role, \"content\": self.content}\n\nclass _Choice:\n    def __init__(self, content):\n        self.message, self.finish_reason, self.index = _Message(content), \"stop\", 0\n\nclass _Response:\n    def __init__(self, content):\n        self.choices, self.usage, self.id, self.model = [_Choice(content)], None, \"replay\", model_name\n    def model_dump(self):\n        return {\"choices\": [{\"message\": self.choices[0].message.model_dump()}]}\n\ndef _create(**request):\n    _calls.append({\"keys\": sorted(request.keys()), \"stream\": bool(request.get(\"stream\")),\n                   \"model\": request.get(\"model\")})\n    i = _replay[\"next\"]\n    if i < len(recorded):\n        _replay[\"next\"] = i + 1\n        return _Response(recorded[i])\n    safe = {}\n    for key in (\"messages\", \"model\", \"tools\", \"temperature\", \"max_tokens\", \"max_completion_tokens\"):\n        if key in request:\n            try:\n                json.dumps(request[key])\n                safe[key] = request[key]\n            except (TypeError, ValueError):\n                pass\n    raise Capture(safe)\n\nclass _Delta:\n    def __init__(self, content): self.content, self.role, self.tool_calls = content, \"assistant\", None\n\nclass _StreamChunk:\n    def __init__(self, content, finish=None):\n        choice = types.SimpleNamespace(delta=_Delta(content), finish_reason=finish, index=0)\n        self.choices = [choice]\n        self.id, self.model, self.usage = \"replay\", model_name, None\n\ndef _result(request):\n    content_response = _create(**request)   # replay or Capture\n    if request.get(\"stream\"):\n        return iter([_StreamChunk(content_response.choices[0].message.content),\n                     _StreamChunk(None, finish=\"stop\")])\n    return content_response\n\nclass _Proxy:\n    def __init__(self, path):\n        self._path = path\n    def __getattr__(self, name):\n        if name.startswith(\"_\"):\n            # Dunders, and private probes like `_client`: absent. hermes reads `_client`\n            # to inspect the transport, and an ever-truthy proxy there reads as CLOSED.\n            raise AttributeError(name)\n        if name == \"is_closed\":\n            # Asked both as a property and as a method; a plain False satisfies neither\n            # branch wrongly — hermes calls it if callable, truth-tests it if not.\n            return lambda: False\n        if name in (\"close\", \"aclose\"):\n            return lambda *a, **k: None\n        return _Proxy(self._path + \".\" + name)\n    def __call__(self, *args, **kwargs):\n        _calls.append({\"path\": self._path, \"keys\": sorted(kwargs.keys()),\n                       \"stream\": bool(kwargs.get(\"stream\"))})\n        if \"messages\" in kwargs:\n            return _result(kwargs)\n        # Construction and configuration chatter (with_options, headers, …): answer with\n        # another proxy so the caller keeps walking to its real request.\n        return _Proxy(self._path + \"()\")\n\ndef _build_fake_openai():\n    fake = types.ModuleType(\"openai\")\n    class OpenAI(_Proxy):\n        def __init__(self, *a, **k):\n            _Proxy.__init__(self, \"OpenAI\")\n    class AsyncOpenAI(OpenAI): pass\n    class APIError(Exception): pass\n    class APIStatusError(APIError): pass\n    class APIConnectionError(APIError): pass\n    class APITimeoutError(APIConnectionError): pass\n    class RateLimitError(APIStatusError): pass\n    class AuthenticationError(APIStatusError): pass\n    class BadRequestError(APIStatusError): pass\n    class NotFoundError(APIStatusError): pass\n    class InternalServerError(APIStatusError): pass\n    for name, value in list(locals().items()):\n        if not name.startswith(\"_\") and name != \"fake\":\n            setattr(fake, name, value)\n    fake.__version__ = \"0.0.0-mouse-replay\"\n    return fake\n\nsys.modules[\"openai\"] = _build_fake_openai()\n\n# This build does not run `site`, so sitecustomize never loads — the runtime patches live\n# here, applied before hermes imports. wasi has no threads: a Timer never fires, a daemon\n# thread pretends to start (watchers, log listeners), a non-daemon thread runs INLINE.\n# This WASI has no clock sleep (poll_oneoff answers Not supported), and hermes's loop\n# sleeps 200ms between interrupt checks. There is nothing to yield to on one thread anyway.\nimport time as _time\n_time.sleep = lambda seconds=0: None\n\nimport threading as _threading\ndef _inline_start(self):\n    self._started.set()\n    if isinstance(self, _threading.Timer) or self.daemon:\n        return\n    self.run()\n_threading.Thread.start = _inline_start\n# join() on a pretend-started thread trips _wait_for_tstate_lock's assert; there is nothing\n# to wait for — inline threads already ran, daemons never will.\n_threading.Thread.join = lambda self, timeout=None: None\n_threading.Thread.is_alive = lambda self: False\n\nimport concurrent.futures as _cf\nclass _InlineExecutor(_cf.Executor):\n    def __init__(self, *a, **k): pass\n    def submit(self, fn, /, *args, **kwargs):\n        future = _cf.Future()\n        try:\n            future.set_result(fn(*args, **kwargs))\n        except BaseException as error:\n            future.set_exception(error)\n        return future\n    def shutdown(self, wait=True, *, cancel_futures=False): pass\n_thread_mod = types.ModuleType(\"concurrent.futures.thread\")\n_thread_mod.ThreadPoolExecutor = _InlineExecutor\nsys.modules[\"concurrent.futures.thread\"] = _thread_mod\n_cf.ThreadPoolExecutor = _InlineExecutor\n\n# QueueListener.start is the one that actually fired: logging's queue machinery wants its\n# own thread. Listening inline means handling records as they are enqueued instead.\nimport logging.handlers as _lh\ndef _listener_start(self):\n    class _Immediate:\n        def __init__(self, listener): self._l = listener\n        def put_nowait(self, record):\n            if record is not None:\n                self._l.handle(record)\n        put = put_nowait\n        def get(self, *a, **k): raise EOFError\n    self.queue = _Immediate(self)\n_lh.QueueListener.start = _listener_start\n_lh.QueueListener.stop = lambda self: None\n\n# Hermes's own diagnostics, captured in-process: the QueueListener patch above orphans\n# its file logs, and the \"invalid response\" reason is logged, not raised.\nimport io, logging\n_logbuf = io.StringIO()\n_handler = logging.StreamHandler(_logbuf)\n_handler.setFormatter(logging.Formatter(\"%(name)s %(levelname)s %(message)s\"))\n_handler.setLevel(logging.DEBUG)\nlogging.getLogger(\"agent\").addHandler(_handler)\nlogging.getLogger(\"agent\").setLevel(logging.DEBUG)\nlogging.getLogger(\"run_agent\").addHandler(_handler)\nlogging.getLogger(\"run_agent\").setLevel(logging.DEBUG)\n\nout = {}\ntry:\n    from run_agent import AIAgent\n    # THE SEAM. The loop asks these two methods for a completed, OpenAI-shaped response;\n    # everything below them is transport (worker threads, httpx streaming, retries) that\n    # cannot exist on this device. Mouse IS the transport: recorded replies replay, the\n    # first unrecorded call is captured for URLSession.\n    def _mouse_transport(self, api_kwargs, **extra):\n        _calls.append({\"transport\": sorted(api_kwargs.keys())})\n        return _create(**api_kwargs)\n    AIAgent._interruptible_streaming_api_call = _mouse_transport\n    AIAgent._interruptible_api_call = _mouse_transport\n    agent = AIAgent(base_url=\"http://mouse.bridge/v1\", api_key=\"mouse-bridge\", model=model_name)\n    answer = agent.chat(prompt)\n    out = {\"answer\": answer if isinstance(answer, str) else str(answer)}\nexcept Capture as capture:\n    out = {\"tool\": \"llm.complete\", \"args\": capture.request}\nexcept BaseException as error:\n    out = {\"error\": \"%s: %s\\n%s\" % (type(error).__name__, error, traceback.format_exc()[-1800:])}\n\nout[\"calls\"] = _calls\nout[\"log\"] = _logbuf.getvalue()[-2500:]\njson.dump(out, open(BRIDGE + \"/out.json\", \"w\"))\n"

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
    private func run(_ command: String, on terminal: TerminalSession,
                     onLine: ((String) -> Void)? = nil) async -> (ok: Bool, text: String, errors: String) {
        let before = terminal.lines.count
        var seen = before
        // Screenless: this container has no terminal grid, and an agent handed one never
        // returns. `claude -p` answers in three seconds down this path and hangs forever down
        // the other.
        guard terminal.run(command, screenless: true) else { return (false, "the terminal is busy", "") }
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
                    : printed, "")
            }
            // Lines as they land — the streaming caller reads each one now, not at exit.
            if let onLine, terminal.lines.count > seen {
                for line in terminal.lines[seen...] where line.kind != .command { onLine(line.text) }
                seen = terminal.lines.count
            }
            try? await Task.sleep(for: .milliseconds(onLine == nil ? 120 : 50))
        }
        if let onLine, terminal.lines.count > seen {
            for line in terminal.lines[seen...] where line.kind != .command { onLine(line.text) }
        }
        let produced = Array(terminal.lines[before...]).filter { $0.kind != .command }
        let failed = produced.contains { $0.kind == .error }
        let text = produced.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let errors = produced.filter { $0.kind == .error }.map(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (!failed, text, errors)
    }

}
