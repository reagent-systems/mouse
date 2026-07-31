import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import zlib

/// The Node layer (system.md phase G): Mouse does not run Node — it IS Node. JavaScript
/// executes on JavaScriptCore (interpreter-only in-process; the WebView JIT surface comes
/// later), and everything Node the runtime provides — the CommonJS module system over
/// `node_modules`, the core modules, the event loop — is supplied here.
///
/// Scope, honestly: CommonJS only (`import` errors clearly), the core-module subset real
/// CLIs lean on (`fs` `path` `os` `util` `events` `buffer` `tty` `assert`, timers,
/// `process`), and a macrotask loop (timers, immediates, nextTick; promises ride JSC's own
/// microtask queue). `net` is real TCP (see NodeSockets.swift) and `child_process` runs
/// through msh; `http` clients ride URLSession, and `http.createServer` rides `net`.
/// Paths are workspace-virtual: "/" is the project root, exactly like msh.
///
/// Foundation + JavaScriptCore only: verified headlessly against REAL Node's output for the
/// same fixture scripts (per AGENTS.md).
///
/// Threading (the ICMPPinger pattern): ALL JavaScript runs on `queue`, a dedicated serial
/// queue — never the main actor. That is what lets `child_process.execSync` block its own
/// thread on a semaphore while msh runs on the main actor, and lets URLSession completions
/// re-enter the event loop as jobs. JSValues are touched only on `queue`.
final class NodeEngine: @unchecked Sendable {

    struct Result {
        var out = ""
        var err = ""
        var status: Int32 = 0
    }

    /// The kernel doorway back into msh: `child_process` commands run through this, on the
    /// main actor, while the JS thread waits. nil when no shell is attached (harness).
    struct ShellBridge: @unchecked Sendable {
        let execute: @MainActor (String) async -> (out: String, err: String, status: Int32)
    }

    /// Where a running program's output goes when it owns a terminal: live, not accumulated.
    /// nil = collect into `Result` (pipelines, scripts, the headless harness).
    struct TTY: @unchecked Sendable {
        let write: (String) -> Void
        /// stderr's live sink — same screen on a real TTY, but the host keeps the error
        /// coloring while the program is still in transcript mode.
        let writeError: (String) -> Void
        var rows: Int
        var columns: Int
        /// The program asked for raw keystrokes (`stdin.setRawMode(true)`) — the host uses
        /// this to decide the screen is now the program's.
        let rawModeChanged: (Bool) -> Void
    }

    private let root: URL
    private let env: [String: String]
    private let shell: ShellBridge?
    private var tty: TTY?
    private let queue = DispatchQueue(label: "mouse.node", qos: .userInitiated)
    private var context: JSContext!
    private var virtualMachine: JSVirtualMachine!
    /// `vm` contexts, each a separate global in the same virtual machine.
    private var vmContexts: [Int: JSContext] = [:]
    private var vmNextID = 1
    private var out = ""
    private var err = ""
    private var exitCode: Int32? = nil
    private var moduleCache: [String: JSValue] = [:]
    /// Modules mid-evaluation, keyed to their MODULE object (not exports): a circular
    /// require must read `module.exports` LIVE — semver's range/comparator cycle assigns
    /// `module.exports = Class` before requiring its partner, and the partner must see the
    /// class, not a stale snapshot of the original empty object.
    private var modulesInProgress: [String: JSValue] = [:]
    private var packageTypeCache: [String: String] = [:]

    private struct Timer {
        let id: Int
        var due: Date
        let interval: Double?
        let callback: JSValue
        let arguments: [Any]
    }
    private var timers: [Timer] = []
    private var immediates: [(JSValue, [Any])] = []
    private var nextTimerID = 1

    /// Cross-thread wakeups: async completions (HTTP) enqueue jobs and signal; the loop
    /// sleeps on the semaphore between timers.
    private let wakeup = DispatchSemaphore(value: 0)
    private let jobsLock = NSLock()
    private var jobs: [() -> Void] = []
    private var outstanding = 0
    /// MessagePort deliveries. Node runs these in their OWN loop phase: after nextTick and the
    /// microtask queue, before immediates — verified against real node, including the case where
    /// the nextTick is queued AFTER the postMessage and still runs first. A microtask-based drain
    /// cannot express that, which is why this is a phase rather than a promise.
    private var portDeliveries: [JSValue] = []
    /// Open TCP handles (`net`, and `http` servers above it). Counted separately from
    /// `outstanding` because they are opened and closed from the socket queue, not the JS
    /// thread — hence the lock, which the loop's quiescence check reads through.
    private let handlesLock = NSLock()
    private var openHandles = 0
    private lazy var sockets: SocketTable = SocketTable(
        deliver: { [weak self] job in self?.enqueueJob(job) },
        retain: { [weak self] in
            guard let self else { return }
            handlesLock.lock(); openHandles += 1; handlesLock.unlock()
        },
        release: { [weak self] in
            guard let self else { return }
            handlesLock.lock(); openHandles -= 1; handlesLock.unlock()
            wakeup.signal()   // the last handle closing is what lets the loop notice and exit
        })
    private lazy var watchers: WatchTable = WatchTable(
        deliver: { [weak self] job in self?.enqueueJob(job) },
        retain: { [weak self] in
            guard let self else { return }
            handlesLock.lock(); openHandles += 1; handlesLock.unlock()
        },
        release: { [weak self] in
            guard let self else { return }
            handlesLock.lock(); openHandles -= 1; handlesLock.unlock()
            wakeup.signal()
        })
    /// Children whose handle still holds the event loop open (node's ref/unref, per child).
    private var refedChildren: Set<Int> = []

    /// Child engines by id — a spawned node process is one of these.
    private var children: [Int: NodeEngine] = [:]

    /// Live `URLSessionWebSocketTask`s by id — the WebSocket global's handles.
    private var webSocketTasks: [Int: URLSessionWebSocketTask] = [:]
    private func finishWebSocket(_ id: Int) {
        enqueueJob { [weak self] in
            guard let self, webSocketTasks[id] != nil else { return }
            webSocketTasks[id] = nil
            outstanding -= 1
        }
    }
    /// A forked child's message channel back to its parent. nil when there is none, which is
    /// what makes `process.send` undefined — the standard way a program asks "was I forked?".
    private var ipcSink: ((String) -> Void)?
    /// Give this engine an IPC channel before `run`.
    func attachIPC(_ sink: @escaping (String) -> Void) { ipcSink = sink }
    /// The channel holds the event loop open, as node's does — otherwise a forked child runs its
    /// script, finds nothing pending, and exits before the first message arrives.
    private var channelHoldsLoop = false
    /// A message from the parent, delivered as `process.on('message')` on the JS thread.
    func deliverMessage(_ json: String) {
        enqueueJob { [weak self] in
            guard let self, let context = self.context else { return }
            context.objectForKeyedSubscript("__mouseDeliverMessage")?.call(withArguments: [json])
        }
    }

    /// This engine IS a worker thread, with its `workerData` as JSON. nil in the main engine,
    /// which is what `isMainThread` reports.
    private var workerData: String?
    func markAsWorker(data: String) { workerData = data }

    /// This engine's stdout/stderr/stdin are a pipe to a parent, not a terminal.
    private var stdioIsPipe = false
    /// Mark stdio as a pipe before `run` — a spawned child does this.
    func markStdioAsPipe() { stdioIsPipe = true }
    private var watchersUsed = false
    private var socketsUsed = false
    private var hasOpenHandles: Bool {
        handlesLock.lock()
        defer { handlesLock.unlock() }
        return openHandles > 0
    }
    private var cancelled = false
    /// stdin has listeners on an attached TTY — the program is waiting on the keyboard,
    /// which keeps the event loop alive exactly like node's ref'd stdin.
    private var stdinActive = false
    /// The ESM entry's top-level await hasn't settled yet — the loop keeps driving.
    private var entryPending = false

    init(root: URL, env: [String: String], shell: ShellBridge? = nil, tty: TTY? = nil) {
        self.root = root
        self.env = env
        self.shell = shell
        self.tty = tty
    }

    /// Attach the terminal after init — the host program can't hand closures over itself
    /// to its own initializer. Must happen before `run`.
    func attachTTY(_ tty: TTY) {
        self.tty = tty
    }

    // MARK: - Live input (a program owning the keyboard)

    /// A keystroke from the host. Delivered to `process.stdin` handlers on the JS thread.
    func deliverInput(_ text: String) {
        enqueueJob { [weak self] in
            guard let self, let context = self.context else { return }
            let function = context.objectForKeyedSubscript("__mouseDeliverInput")
            function?.call(withArguments: [text])
        }
    }

    /// Stop a running program from outside — what `child.kill()` means for a spawned child.
    /// The loop notices on its next turn and unwinds with 130, as an interrupted program does.
    func terminate() {
        cancelled = true
        wakeup.signal()
    }

    /// No more input is coming — the writing end of the pipe closed.
    func endInput() {
        enqueueJob { [weak self] in
            guard let self, let context = self.context else { return }
            context.objectForKeyedSubscript("__mouseEndInput")?.call(withArguments: [])
        }
    }

    /// The terminal changed size: update `process.stdout.columns/rows` and emit `resize`.
    func resizeTTY(rows: Int, columns: Int) {
        enqueueJob { [weak self] in
            guard let self, let context = self.context else { return }
            self.tty?.rows = rows
            self.tty?.columns = columns
            context.objectForKeyedSubscript("__mouseResize")?.call(withArguments: [rows, columns])
        }
    }

    /// SIGINT (^C in cooked mode, or the container closing). Runs the program's handlers;
    /// a program with none ends here. In raw mode the host sends the ^C byte through
    /// `deliverInput` instead — that is the terminal discipline real ttys follow.
    func interrupt() {
        enqueueJob { [weak self] in
            guard let self, let context = self.context else { return }
            if context.objectForKeyedSubscript("__mouseSigint")?.call(withArguments: [])?.toBool() != true {
                self.exitCode = 130
            }
        }
    }

    private func enqueueJob(_ job: @escaping () -> Void) {
        jobsLock.lock()
        jobs.append(job)
        jobsLock.unlock()
        wakeup.signal()
    }

    // MARK: - Entry

    /// Run one script as the main module. `path` is workspace-virtual ("/tool/cli.js").
    func run(source: String, path: String, argv: [String], cwd: String, stdin: String) async -> Result {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: self.runOnQueue(source: source, path: path, argv: argv, cwd: cwd, stdin: stdin))
                }
            }
        } onCancel: {
            cancelled = true
            wakeup.signal()
        }
    }

    private func runOnQueue(source rawSource: String, path: String, argv: [String], cwd: String, stdin: String) -> Result {
        var source = rawSource
        if source.hasPrefix("#!") {   // executables carry shebangs; the wrapper won't parse them
            source = source.drop(while: { $0 != "\n" }).isEmpty ? "" : String(source.drop(while: { $0 != "\n" }))
        }
        // One virtual machine for the engine AND every `vm` context it creates: JSValues can
        // only cross between contexts that share a VM, which is what makes a contextified
        // sandbox possible at all.
        virtualMachine = JSVirtualMachine()!
        context = JSContext(virtualMachine: virtualMachine)!
        context.name = "mouse-node"
        var fatal: String? = nil
        var fatalValue: JSValue? = nil
        context.exceptionHandler = { [weak self] _, exception in
            guard let self, self.exitCode == nil else { return }
            let text = exception?.toString() ?? "unknown error"
            if text.contains("__mouse_exit__") { return }
            let stack = exception?.forProperty("stack")?.toString() ?? text
            fatal = stack.contains(text) ? stack : text + "\n" + stack
            fatalValue = exception
        }

        installNativeBridge(argv: argv, cwd: cwd, stdin: stdin)
        // The channel does NOT hold the loop by itself. A forked child that sends its result
        // and has nothing else to do EXITS in node — the hold belongs to a message LISTENER,
        // which is what says "more work may arrive". Holding unconditionally left every
        // short-lived worker alive forever, waiting on a channel nobody was going to use.
        context.evaluateScript(Self.bootstrap)
        installRejectionHook()

        let dir = virtualDirname(path)
        // The entry carries a map as often as anything it requires — an installed CLI IS a
        // bundle, and it is usually what you run.
        registerSourceMap(id: normalize(path), source: source)
        switch typeScriptSource(id: normalize(path), source: source) {
        case .failed(let message):
            err += message + "\n"
            exitCode = 1
        case .compiled(let compiled): source = compiled
        case .notTypeScript: break
        }
        let entryIsESM = isESModule(id: normalize(path), source: source)
        if entryIsESM {
            source = transpileCached(source)
        } else if source.contains("import") {
            source = Self.rewriteDynamicImport(source)
        }
        if exitCode == nil, wrapModule(source, async: entryIsESM, sourceURL: path) == nil {
            // node prints the file, the SyntaxError and exits 1. This printed NOTHING and
            // exited 0 — a program that does not run and does not say so, which is the worst
            // outcome available: every other failure at least tells you it happened.
            err += "\(path)\n" + (lastParseProblem ?? "SyntaxError: could not parse") + "\n"
            exitCode = 1
        }
        if exitCode == nil, let function = wrapModule(source, async: entryIsESM, sourceURL: path) {
            let module = context.evaluateScript("({exports: {}})")!
            let require = makeRequire(fromDir: dir, esm: entryIsESM)
            if entryIsESM {
                // The entry may hold a real top-level await (directly or through an import).
                // The event loop drives it; settle/reject arrives as a microtask.
                let entrySettled: @convention(block) (JSValue?) -> Void = { [weak self] error in
                    guard let self else { return }
                    self.entryPending = false
                    if let error, !error.isUndefined, !error.isNull, self.exitCode == nil {
                        let text = error.toString() ?? "unknown error"
                        let stack = error.forProperty("stack")?.toString() ?? text
                        // An ESM entry settles through here rather than through the context's
                        // exception handler, and it needs the same header for the same reason.
                        self.err += self.sourceContext(of: error)
                        self.err += self.remapStack((stack.contains(text) ? stack : text + "\n" + stack)) + "\n"
                        self.exitCode = 1
                    }
                }
                let launcher = context.evaluateScript("""
                    (function(fn, exports, require, module, filename, dirname, settled){
                        fn(exports, require, module, filename, dirname, require, filename)
                            .then(function(){ settled(undefined); },
                                  function(e){ settled(e === undefined || e === null ? new Error('undefined thrown') : e); });
                        return module.__esmDone === true || module.__esmError !== undefined;
                    })
                    """)!
                // Set BEFORE the call and only ever CLEAR after: JSC drains microtasks at
                // the call's exit, so a pure-microtask entry settles DURING the call — the
                // settled callback clears the flag, and assigning `finished != true` after
                // the call would overwrite that clear and stamp exit 13 on a healthy run.
                entryPending = true
                let finished = launcher.call(withArguments: [function, module.forProperty("exports")!, require, module, path, dir,
                                                             JSValue(object: entrySettled, in: context)!])
                if finished?.toBool() == true { entryPending = false }
            } else {
                function.call(withArguments: [module.forProperty("exports")!, require, module, path, dir, require, path])
            }
        }
        if let fatal, exitCode == nil {
            // A synchronous top-level throw: an installed `uncaughtException` handler gets
            // first refusal, matching real node — handled means no exit 1 (the handler may
            // itself `process.exit`, which the exit bridge already recorded). This is the
            // synchronous half of error handling; the async half (unhandledRejection) needs
            // JSC's private rejection hook and stays parked (see below / system.md).
            let handled = context.objectForKeyedSubscript("__mouseEmitUncaught")?
                .call(withArguments: [fatalValue ?? JSValue(nullIn: context)!])?.toBool() ?? false
            if !handled, exitCode == nil {
                err += sourceContext(of: fatalValue)
                err += remapStack(fatal.hasSuffix("\n") ? fatal : fatal + "\n")
                exitCode = 1
            }
        }

        runEventLoop()
        // A program that exits with a server still listening must not leave the port held —
        // there is no process teardown here to do it for us.
        if socketsUsed { sockets.closeAll() }
        if watchersUsed { watchers.closeAll() }

        // `beforeExit`: the loop has emptied and nothing has called process.exit(). A handler
        // may schedule more work, in which case node drains again and emits again — so this
        // loops, with a cap, rather than firing once. node does NOT emit it after an explicit
        // exit, which is why this is guarded on exitCode.
        if exitCode == nil {
            var rounds = 0
            while exitCode == nil, rounds < 32 {
                rounds += 1
                let recorded = context.objectForKeyedSubscript("process")?.forProperty("exitCode")
                let code = (recorded?.isUndefined == false && recorded?.isNull == false)
                    ? Int32(recorded!.toInt32()) : 0
                let handled = context.objectForKeyedSubscript("__mouseEmitBeforeExit")?
                    .call(withArguments: [code])?.toBool() ?? false
                if !handled { break }
                // Whether the handler scheduled anything has to be read BEFORE draining —
                // afterwards the queues are empty again and every round looks identical.
                let scheduled = !immediates.isEmpty || !timers.isEmpty || outstanding > 0
                if !scheduled { break }
                runEventLoop()
            }
        }

        // `process.exitCode = n` is the OTHER way a program reports failure: it does not exit,
        // it records what the exit status should be once the loop drains. It was a plain
        // property nothing ever read, so every tool that reports failure this way — mocha,
        // and any test runner or linter that lets pending work finish — exited 0 on failure.
        // An explicit `process.exit(n)` still wins, having already set exitCode here.
        if exitCode == nil,
           let recorded = context.objectForKeyedSubscript("process")?.forProperty("exitCode"),
           !recorded.isUndefined, !recorded.isNull {
            exitCode = Int32(recorded.toInt32())
        }

        // `exit` runs last, synchronously, for every kind of exit — natural drain, an explicit
        // process.exit(), or a fatal error. Anything it writes still belongs in the output.
        context.objectForKeyedSubscript("__mouseEmitExit")?.call(withArguments: [exitCode ?? 0])

        return Result(out: out, err: err, status: exitCode ?? 0)
    }

    /// `sourceURL` names the module in stack traces. Without it JSC reports every frame as a
    /// bare `functionName@` — unreadable for anyone debugging a real error in the terminal,
    /// which is the app's one honest error surface.
    /// The file, the line, the line's own text and a caret — what node prints above an
    /// uncaught error, and the part an editor can act on. A stack tells you where; this tells
    /// you what is there, which is the difference between reading a trace and reading the code.
    /// A file that carries its own source map — which every bundled CLI does, since esbuild,
    /// webpack and tsup all emit one. node maps these only under `--enable-source-maps`; here it
    /// is the default, deliberately: a trace into line 45678 of a bundle tells a reader nothing,
    /// and this is an editor. Both spellings are honoured — a data: URI carrying the map, and a
    /// path beside the file.
    private func registerSourceMap(id: String, source: String) {
        guard let marker = source.range(of: "//# sourceMappingURL=", options: .backwards) else { return }
        let rest = source[marker.upperBound...]
        let reference = String(rest.prefix(while: { !$0.isNewline })).trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else { return }
        var text: String?
        if reference.hasPrefix("data:") {
            if let comma = reference.range(of: "base64,") {
                let encoded = String(reference[comma.upperBound...])
                text = Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) }
            } else if let comma = reference.firstIndex(of: ",") {
                text = String(reference[reference.index(after: comma)...]).removingPercentEncoding
            }
        } else if !reference.hasPrefix("http") {
            let beside = normalize(virtualDirname(id) + "/" + reference)
            text = try? String(contentsOf: realURL(beside), encoding: .utf8)
        }
        guard let text, text.contains("\"mappings\"") else { return }
        context.objectForKeyedSubscript("__rememberSourceMap")?.call(withArguments: [id, text])
    }

    /// A compiled file's position, in the terms its AUTHOR wrote. Empty when the file was not
    /// compiled — the ordinary case, and the reason this is a lookup rather than a transform.
    private func originalPosition(file: String, line: Int, column: Int)
        -> (file: String, line: Int, column: Int)? {
        guard let mapper = context.objectForKeyedSubscript("__mapPosition"),
              let mapped = mapper.call(withArguments: [file, line, column])?.toString(),
              !mapped.isEmpty else { return nil }
        let parts = mapped.components(separatedBy: "|")
        guard parts.count == 3, let line = Int(parts[1]), let column = Int(parts[2]) else { return nil }
        // The map names its sources relative to the compiled file; a bundle's are its inputs.
        let source = parts[0].isEmpty ? file : normalize(virtualDirname(file) + "/" + parts[0])
        return (source, line, column)
    }

    /// Every frame in a rendered stack, moved back to the source it was written in. A stack is
    /// a string by the time we see it, so this is a rewrite over the positions in it — the same
    /// job `source-map-support` does for node, in the one place that renders them.
    private func remapStack(_ text: String) -> String {
        guard text.contains("mouse://"),
              let pattern = try? NSRegularExpression(pattern: #"mouse://([^\s:]+):(\d+):(\d+)"#) else { return text }
        let ns = text as NSString
        var result = "", cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let file = ns.substring(with: match.range(at: 1))
            let line = Int(ns.substring(with: match.range(at: 2))) ?? 0
            let column = Int(ns.substring(with: match.range(at: 3))) ?? 0
            guard let original = originalPosition(file: file, line: line, column: column) else { continue }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "mouse://\(original.file):\(original.line):\(original.column)"
            cursor = match.range.location + match.range.length
        }
        guard cursor > 0 else { return text }
        result += ns.substring(from: cursor)
        return result
    }

    private func sourceContext(of error: JSValue?) -> String {
        guard let error,
              let sourceURL = error.forProperty("sourceURL")?.toString(),
              sourceURL.hasPrefix("mouse://"),
              let lineValue = error.forProperty("line"), lineValue.isNumber else { return "" }
        let line = Int(lineValue.toInt32())
        var virtual = String(sourceURL.dropFirst("mouse://".count))
        virtual = virtual.removingPercentEncoding ?? virtual
        guard line >= 1,
              let text = try? String(contentsOf: realURL(virtual), encoding: .utf8) else { return "" }
        var reportedLine = line
        var column = Int(error.forProperty("column")?.toInt32() ?? 1)
        // A compiled file: the header must quote the line the AUTHOR wrote, or it points
        // confidently at whatever happens to sit there in the output.
        var quoted = virtual
        var body = text
        if let original = originalPosition(file: virtual, line: line, column: column) {
            reportedLine = original.line
            column = original.column
            quoted = original.file
            // Quote the SOURCE file's line, which for a bundle is a different file entirely.
            if original.file != virtual, let source = try? String(contentsOf: realURL(original.file), encoding: .utf8) {
                body = source
            }
        }
        let lines = body.components(separatedBy: "\n")
        guard reportedLine <= lines.count else { return "" }
        let caret = String(repeating: " ", count: max(0, column - 1)) + "^"
        return "\(quoted):\(reportedLine)\n\(lines[reportedLine - 1])\n\(caret)\n\n"
    }

    private func wrapModule(_ source: String, async: Bool = false, sourceURL: String? = nil) -> JSValue? {
        var body = source
        if body.hasPrefix("#!") {
            body = String(body.drop(while: { $0 != "\n" }))
        }
        // `__mouseRequire` is a SEPARATE parameter (always the same value as `require`) that
        // the transpiler routes its generated import-requires through. A module that does
        // `const require = createRequire(...)` — legal ESM (yargs, many dual packages) —
        // shadows the `require` PARAMETER scope-wide, which would put the transpiled imports
        // above that line in TDZ; `__mouseRequire` is untouched by that shadow.
        let keyword = async ? "async function" : "function"
        // No newline after the wrapper: the body's first line must BE the file's first line, or
        // every line number in every stack trace is off by one — which for an editor means the
        // click lands on the wrong line, all day. node wraps this way for the same reason.
        let wrapped = "(\(keyword)(exports, require, module, __filename, __dirname, __mouseRequire, __mouseFilename){"
                    + body + "\n})"
        // Evaluating a function EXPRESSION can only fail by failing to parse, so the context's
        // own handler — which treats an exception as fatal for the program — must not see it.
        let outerHandler = context.exceptionHandler
        var syntaxProblem: JSValue?
        context.exceptionHandler = { _, exception in syntaxProblem = exception }
        let function: JSValue?
        if let sourceURL, let url = URL(string: "mouse://" + sourceURL.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) {
            function = context.evaluateScript(wrapped, withSourceURL: url)
        } else {
            function = context.evaluateScript(wrapped)
        }
        context.exceptionHandler = outerHandler
        guard let function, function.isObject else {
            // A syntax error here is the transpiler's output failing to parse, and the message
            // is the only thing that says WHERE. Swallowing it left "Cannot parse '<2 MB file>'".
            if let problem = syntaxProblem {
                let line = problem.forProperty("line")
                lastParseProblem = problem.toString() + (line?.isNumber == true ? " (line \(line!.toInt32()))" : "")
            }
            return nil
        }
        lastParseProblem = nil
        return function
    }

    /// The JSC syntax error from the most recent `wrapModule` failure.
    private var lastParseProblem: String?


    // MARK: - Event loop

    private func runEventLoop() {
        while exitCode == nil {
            if cancelled { exitCode = 130; break }
            drainTicks()

            jobsLock.lock()
            let pendingJobs = jobs
            jobs = []
            jobsLock.unlock()
            if !pendingJobs.isEmpty {
                for job in pendingJobs {
                    guard exitCode == nil else { break }
                    job()
                }
                continue
            }

            if !portDeliveries.isEmpty {
                let batch = portDeliveries
                portDeliveries = []
                for callback in batch {
                    guard exitCode == nil else { break }
                    invoke(callback, [])
                }
                continue
            }

            if !immediates.isEmpty {
                let batch = immediates
                immediates = []
                for (callback, arguments) in batch {
                    guard exitCode == nil else { break }
                    invoke(callback, arguments)
                }
                continue
            }

            let next = timers.min(by: { $0.due < $1.due })
            if next == nil, outstanding == 0, !stdinActive, !hasOpenHandles {
                // Quiescent with the entry's top-level await still pending: nothing can
                // ever settle it. Real node exits 13 here.
                if entryPending { exitCode = 13 }
                break
            }
            if let next {
                let wait = next.due.timeIntervalSinceNow
                if wait > 0 {
                    _ = wakeup.wait(timeout: .now() + min(wait, 60))
                    continue
                }
                timers.removeAll { $0.id == next.id }
                if let interval = next.interval {
                    var repeated = next
                    repeated.due = Date().addingTimeInterval(interval)
                    timers.append(repeated)
                }
                invoke(next.callback, next.arguments)
            } else {
                // Only in-flight I/O remains: sleep until a completion signals.
                _ = wakeup.wait(timeout: .now() + 60)
            }
        }
        drainTicks()
    }

    /// Call a JS callback the way node does: with the tick queue drained before any promise
    /// reaction the callback queues. Falls back to a direct call if the trampoline is missing
    /// (it cannot be, after the bootstrap, but a direct call is the safe degradation).
    private func invoke(_ callback: JSValue, _ arguments: [Any]) {
        guard let trampoline = context.objectForKeyedSubscript("__invoke"),
              !trampoline.isUndefined else {
            callback.call(withArguments: arguments)
            return
        }
        trampoline.call(withArguments: [callback, arguments])
    }

    /// Wrap a JS callback so that calling it drains the tick queue before the stack unwinds.
    /// Done at registration rather than at call time on purpose: the handlers that fire these
    /// live on the host side and must not capture the engine to reach the trampoline.
    private func trampolined(_ callback: JSValue) -> JSValue {
        guard let wrap = context.objectForKeyedSubscript("__wrapInvoke"), !wrap.isUndefined,
              let wrapped = wrap.call(withArguments: [callback]), !wrapped.isUndefined else {
            return callback
        }
        return wrapped
    }

    private func drainTicks() {
        guard exitCode == nil else { return }
        context.evaluateScript("globalThis.__drainTicks && globalThis.__drainTicks()")
    }

    // MARK: - Native bridge

    /// JavaScriptCore's unhandled-rejection hook, resolved at runtime.
    ///
    /// This was refused for a long time on the grounds that JSC exposes no rejection hook — a
    /// conclusion reached by reading the PUBLIC headers. The symbol is exported all the same.
    /// It matters because the userland alternative cannot work: patching
    /// `Promise.prototype.then` is called ZERO times by `await`, since JSC's await path uses the
    /// internal `PerformPromiseThen`, so a userland tracker would miss every awaited rejection
    /// and false-positive on the ones it did see.
    ///
    /// Resolved by `dlsym` rather than linked, so an OS without it keeps the previous behaviour
    /// instead of failing to launch.
    private typealias SetRejectionCallback = @convention(c)
        (JSGlobalContextRef?, JSObjectRef?, UnsafeMutablePointer<JSValueRef?>?) -> Void

    private static let setRejectionCallback: SetRejectionCallback? = {
        guard let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
                                  RTLD_NOW),
              let symbol = dlsym(handle, "JSGlobalContextSetUnhandledRejectionCallback") else { return nil }
        return unsafeBitCast(symbol, to: SetRejectionCallback.self)
    }()

    /// Runs inside each `vm` context. Binds the sandbox's keys as live accessors on the guest
    /// global, and copies back any global the script CREATES — node shows those on the sandbox
    /// too, and a plain accessor cannot intercept a property that did not exist yet.
    private static let vmContextSetup = """
    (function(){
      let sandbox = null;
      const bound = new Set();
      function bind(key) {
        if (bound.has(key)) return;
        bound.add(key);
        Object.defineProperty(globalThis, key, {
          configurable: true, enumerable: true,
          get: function(){ return sandbox[key]; },
          set: function(value){ sandbox[key] = value; },
        });
      }
      globalThis.__vmBind = function(target) {
        sandbox = target;
        for (const key of Object.getOwnPropertyNames(sandbox)) bind(key);
      };
      globalThis.__vmSyncBack = function() {
        if (!sandbox) return;
        for (const key of Object.getOwnPropertyNames(globalThis)) {
          if (bound.has(key) || key.startsWith('__vm')) continue;
          // Only what the script itself introduced: the guest's own built-ins are not the
          // sandbox's business.
          const descriptor = Object.getOwnPropertyDescriptor(globalThis, key);
          if (!descriptor || !descriptor.enumerable) continue;
          sandbox[key] = globalThis[key];
          delete globalThis[key];
          bind(key);
        }
        // A key added to the SANDBOX from outside becomes a global on the next run.
        for (const key of Object.getOwnPropertyNames(sandbox)) bind(key);
      };
    })();
    """

    private func installRejectionHook() {
        guard let install = Self.setRejectionCallback,
              let hook = context.objectForKeyedSubscript("__mouseOnUnhandledRejection"),
              !hook.isUndefined else { return }
        install(context.jsGlobalContextRef, hook.jsValueRef, nil)
    }

    private func installNativeBridge(argv: [String], cwd: String, stdin: String) {
        let bridge = JSValue(newObjectIn: context)!

        // A JSValue is not Sendable and never will be, yet these callbacks deliberately travel
        // to the JS thread — where they are only ever CALLED, on that thread. `Carried` records
        // the crossing in one place instead of leaving a warning at every bridge.
        struct Carried<Value>: @unchecked Sendable {
            let value: Value
            init(_ value: Value) { self.value = value }
        }

        func expose(_ name: String, _ block: Any) {
            bridge.setObject(block, forKeyedSubscript: name as NSString)
        }

        let stdoutWrite: @convention(block) (String) -> Void = { [weak self] text in
            guard let self else { return }
            if let tty = self.tty { tty.write(text) } else { self.out += text }
        }
        let stderrWrite: @convention(block) (String) -> Void = { [weak self] text in
            guard let self else { return }
            // A program owning the screen draws stderr there too — that is what a TTY does.
            if let tty = self.tty { tty.writeError(text) } else { self.err += text }
        }
        let setRawMode: @convention(block) (Bool) -> Void = { [weak self] raw in
            self?.tty?.rawModeChanged(raw)
        }
        expose("setRawMode", setRawMode)
        let stdinActiveBlock: @convention(block) (Bool) -> Void = { [weak self] active in
            self?.stdinActive = active   // JS thread — same thread as the event loop
        }
        expose("stdinActive", stdinActiveBlock)
        let exitBlock: @convention(block) (Int32) -> Void = { [weak self] code in
            if self?.exitCode == nil { self?.exitCode = code }
        }
        expose("stdout", stdoutWrite)
        expose("stderr", stderrWrite)
        expose("exit", exitBlock)

        // An unhandled rejection with no listener is fatal in node, exactly like an uncaught
        // throw: the message goes to stderr and the process dies with status 1.
        let unhandledRejection: @convention(block) (String) -> Void = { [weak self] text in
            guard let self, self.exitCode == nil else { return }
            self.err += text.hasSuffix("\n") ? text : text + "\n"
            self.exitCode = 1
        }
        expose("unhandledRejection", unhandledRejection)

        // -- vm contexts --
        // node's contextified sandbox is an object with its own GLOBAL: code run against it
        // sees the sandbox's properties as globals, writes land back on the object, and none of
        // the host's globals leak in. A second JSContext in the shared virtual machine gives
        // exactly that, once the sandbox's keys are installed as live accessors on the guest
        // global — get/set forwarding, so reads and writes stay live in both directions rather
        // than being copied at the boundary.
        let vmCreate: @convention(block) (JSValue?) -> Int = { [weak self] sandbox in
            guard let self, let sandbox else { return 0 }
            let guest = JSContext(virtualMachine: self.virtualMachine)!
            guest.name = "mouse-vm"
            // Errors are marshalled back through the run bridge, not printed here.
            guest.exceptionHandler = { _, _ in }
            guest.evaluateScript(Self.vmContextSetup)
            guest.objectForKeyedSubscript("__vmBind")?.call(withArguments: [sandbox])
            let id = self.vmNextID
            self.vmNextID += 1
            self.vmContexts[id] = guest
            return id
        }
        expose("vmCreate", vmCreate)

        let vmRun: @convention(block) (Int, String, String) -> Any = { [weak self] id, code, filename in
            guard let self, let guest = self.vmContexts[id] else {
                return ["__vmThrow": "vm context has been released"]
            }
            var thrown: JSValue? = nil
            guest.exceptionHandler = { _, exception in thrown = exception }
            // Bind first as well as after: a key added to the sandbox BETWEEN runs should be
            // visible to the next one, and binding only afterwards made it visible one run late.
            guest.objectForKeyedSubscript("__vmSyncBack")?.call(withArguments: [])
            let result = guest.evaluateScript(code, withSourceURL: URL(string: "mouse-vm://" + (filename.hasPrefix("/") ? filename : "/" + filename)))
            // Globals CREATED inside the run are new properties on the guest global; node shows
            // them on the sandbox, so they are copied over and given accessors from now on.
            guest.objectForKeyedSubscript("__vmSyncBack")?.call(withArguments: [])
            if let thrown {
                guest.exceptionHandler = { _, _ in }
                return ["__vmThrow": thrown]
            }
            return result ?? JSValue(undefinedIn: guest)!
        }
        expose("vmRun", vmRun)

        let vmRelease: @convention(block) (Int) -> Void = { [weak self] id in
            self?.vmContexts.removeValue(forKey: id)
        }
        expose("vmRelease", vmRelease)

        // -- CPU time --
        // `process.cpuUsage()` returned hardcoded zeros, which is the shape of stub this
        // project refuses: it looks like a working API and silently reports nothing. getrusage
        // has the real numbers, in microseconds, which is node's unit too.
        let cpuUsage: @convention(block) () -> [String: Double] = {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return ["user": 0, "system": 0] }
            let user = Double(usage.ru_utime.tv_sec) * 1_000_000 + Double(usage.ru_utime.tv_usec)
            let system = Double(usage.ru_stime.tv_sec) * 1_000_000 + Double(usage.ru_stime.tv_usec)
            return ["user": user, "system": system]
        }
        expose("cpuUsage", cpuUsage)

        // -- monotonic clock --
        // `process.hrtime`, `hrtime.bigint` and `performance.now` all read a MONOTONIC clock:
        // one that never runs backwards when the wall clock is corrected, with sub-millisecond
        // resolution. `Date.now()` is neither, so a benchmark spanning an NTP step could report
        // a negative duration. DispatchTime is mach_absolute_time underneath — the same source
        // node uses on Darwin.
        //
        // Nanoseconds outgrow Double's exact-integer range, so the value crosses as a decimal
        // string and the JS side rebuilds an exact BigInt from it.
        let monotonicNanos: @convention(block) () -> String = {
            String(DispatchTime.now().uptimeNanoseconds)
        }
        expose("monotonicNanos", monotonicNanos)

        // -- filesystem (workspace-virtual paths) --
        let readFile: @convention(block) (String) -> Any = { [weak self] path in
            guard let self, let data = try? Data(contentsOf: self.realURL(path)) else { return NSNull() }
            return data.base64EncodedString()
        }
        let writeFile: @convention(block) (String, String, Bool) -> Bool = { [weak self] path, base64, append in
            guard let self, let data = Data(base64Encoded: base64) else { return false }
            let url = self.realURL(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append, let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                return true
            }
            return (try? data.write(to: url)) != nil
        }
        // The FULL stat, straight from lstat(2). `mode` is not a luxury: chokidar decides
        // whether it may read an entry with `4 & parseInt(stats.mode…)`, so a Stats without a
        // mode silently filtered out EVERY FILE while directories (no such check) passed.
        // The rest are here for the same reason — a library reading a missing field gets
        // undefined and draws a wrong conclusion quietly.
        let statFile: @convention(block) (String, Bool) -> Any = { [weak self] path, followLinks in
            guard let self else { return NSNull() }
            let url = self.realURL(path)
            var info = stat()
            let result = followLinks ? stat(url.path, &info) : lstat(url.path, &info)
            guard result == 0 else { return NSNull() }
            let kind = info.st_mode & S_IFMT
            func milliseconds(_ time: timespec) -> Double {
                Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
            }
            return [
                "dir": kind == S_IFDIR,
                "link": kind == S_IFLNK,
                "file": kind == S_IFREG,
                "size": Double(info.st_size),
                "mode": Int(info.st_mode),
                "uid": Int(info.st_uid),
                "gid": Int(info.st_gid),
                "ino": Double(info.st_ino),
                "dev": Int(info.st_dev),
                "nlink": Int(info.st_nlink),
                "rdev": Int(info.st_rdev),
                "blocks": Double(info.st_blocks),
                "blksize": Int(info.st_blksize),
                "mtimeMs": milliseconds(info.st_mtimespec),
                "atimeMs": milliseconds(info.st_atimespec),
                "ctimeMs": milliseconds(info.st_ctimespec),
                "birthtimeMs": milliseconds(info.st_birthtimespec),
            ] as [String: Any]
        }
        let readdir: @convention(block) (String) -> Any = { [weak self] path in
            guard let self,
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: self.realURL(path).path) else {
                return NSNull()
            }
            return entries.sorted()
        }
        let mkdir: @convention(block) (String) -> Bool = { [weak self] path in
            guard let self else { return false }
            return (try? FileManager.default.createDirectory(at: self.realURL(path), withIntermediateDirectories: true)) != nil
        }
        let removePath: @convention(block) (String) -> Bool = { [weak self] path in
            guard let self else { return false }
            return (try? FileManager.default.removeItem(at: self.realURL(path))) != nil
        }
        let renamePath: @convention(block) (String, String) -> Bool = { [weak self] from, to in
            guard let self else { return false }
            return (try? FileManager.default.moveItem(at: self.realURL(from), to: self.realURL(to))) != nil
        }
        // statfs(2) — free space and block counts. Build tools check available space before
        // writing large artifacts, and node exports it.
        let statFilesystem: @convention(block) (String) -> Any = { [weak self] path in
            guard let self else { return NSNull() }
            var info = statfs()
            guard statfs(self.realURL(path).path, &info) == 0 else { return NSNull() }
            return [
                "type": Int(info.f_type),
                "bsize": Double(info.f_bsize),
                "blocks": Double(info.f_blocks),
                "bfree": Double(info.f_bfree),
                "bavail": Double(info.f_bavail),
                "files": Double(info.f_files),
                "ffree": Double(info.f_ffree),
            ] as [String: Any]
        }
        expose("statfs", statFilesystem)
        expose("readFile", readFile)
        expose("writeFile", writeFile)
        expose("stat", statFile)
        expose("readdir", readdir)
        expose("mkdir", mkdir)
        expose("remove", removePath)
        expose("rename", renamePath)

        // -- module resolution (the Node algorithm, in Swift) --
        let resolve: @convention(block) (String, String) -> Any = { [weak self] request, fromDir in
            guard let self else { return NSNull() }
            switch self.resolveModule(request, fromDir: fromDir) {
            case .core(let name): return ["kind": "core", "id": name]
            case .file(let id): return ["kind": "file", "id": id]
            case .json(let id): return ["kind": "json", "id": id]
            case .notFound(let message), .notExported(let message): return ["kind": "error", "message": message]
            case .addon(let id): return ["kind": "addon", "id": id]
            }
        }
        expose("resolve", resolve)

        // -- timers --
        let setTimer: @convention(block) (JSValue, Double, Bool, JSValue) -> Int = { [weak self] callback, delay, repeats, args in
            guard let self else { return 0 }
            let id = self.nextTimerID
            self.nextTimerID += 1
            let arguments = (args.toArray() ?? [])
            self.timers.append(Timer(id: id, due: Date().addingTimeInterval(max(0, delay) / 1000),
                                     interval: repeats ? max(1, delay) / 1000 : nil,
                                     callback: callback, arguments: arguments))
            return id
        }
        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeAll { $0.id == id }
        }
        let setImmediateBlock: @convention(block) (JSValue, JSValue) -> Void = { [weak self] callback, args in
            self?.immediates.append((callback, args.toArray() ?? []))
        }
        expose("setTimer", setTimer)
        expose("clearTimer", clearTimer)
        expose("setImmediate", setImmediateBlock)

        // -- child_process → msh: block THIS thread while the shell runs on the main actor --
        // (Safe: the JS thread only waits; the box is written before signal, read after wait.)
        final class ShellResultBox: @unchecked Sendable {
            var value: (out: String, err: String, status: Int32) = ("", "", 1)
        }
        let shellBridge = self.shell
        let shellExec: @convention(block) (String) -> [String: Any] = { command in
            guard let shellBridge else {
                return ["stdout": "", "stderr": "child_process: no shell attached\n", "status": 127]
            }
            let semaphore = DispatchSemaphore(value: 0)
            let box = ShellResultBox()
            Task { @MainActor in
                box.value = await shellBridge.execute(command)
                semaphore.signal()
            }
            semaphore.wait()
            return ["stdout": box.value.out, "stderr": box.value.err, "status": Int(box.value.status)]
        }
        // The child's end of the channel. Only reachable when one exists, which is the point.
        let ipcSend: @convention(block) (String) -> Void = { [weak self] json in
            self?.ipcSink?(json)
        }
        // The hold follows the message LISTENER: taken when the first one is added, given back
        // when the last one goes or the channel is disconnected. `process.disconnect()` uses the
        // same door, since without it a child that finished its work would hang on a channel
        // nobody is using.
        let ipcHold: @convention(block) (Bool) -> Void = { [weak self] hold in
            guard let self else { return }
            if hold, !channelHoldsLoop {
                channelHoldsLoop = true
                outstanding += 1
            } else if !hold, channelHoldsLoop {
                channelHoldsLoop = false
                outstanding -= 1
                wakeup.signal()
            }
        }
        let ipcDisconnect: @convention(block) () -> Void = { [weak self] in
            guard let self, channelHoldsLoop else { return }
            channelHoldsLoop = false
            outstanding -= 1
            wakeup.signal()
        }
        expose("ipcHold", ipcHold)
        expose("ipcSend", ipcSend)
        expose("ipcDisconnect", ipcDisconnect)
        expose("shellExec", shellExec)

        // -- a LIVE child process ----------------------------------------------------------
        // `child_process.spawn` used to mean "run a command through msh and collect its
        // output", which is right for `git status` and useless for a long-lived peer:
        // esbuild-wasm spawns node running its own service script and speaks a binary protocol
        // over the pipes. A node child is a SECOND engine on its own queue, with its stdout and
        // stderr wired into this one's event loop and its stdin fed from ours — the same
        // machinery a terminal program uses, pointed at a pipe instead of a screen.
        // The IPC flag travels as a STRING ("ipc" or ""): a Bool in the middle of this block's
        // signature did not marshal through JSC, and the symptom was brutal — the callback
        // landed in the wrong slot, so a child's very first write threw and it exited 1 with no
        // output at all.
        // `mode` is "" | "ipc" | "eval" | "eval-ipc": the eval forms mean `script` IS the source
        // rather than a path to it, which is how `node -e` reaches a child.
        let spawnNode: @convention(block) (String, [String], String, String, String, String, JSValue) -> Int32 = {
            [weak self] script, argv, cwd, mode, workerData, envJSON, callback in
            guard let self else { return 0 }
            let wantsIPC = mode.contains("ipc")
            let isEval = mode.hasPrefix("eval")
            let carried = Carried(trampolined(callback))
            let id = sockets.claimExternalID()
            outstanding += 1
            // `options.env` finally reaches the child. A caller that passes env expects exactly
            // it (node REPLACES the environment rather than merging), and the JS side is what
            // decides whether to inherit — same as node, where `{...process.env}` is the caller's
            // job. An empty string means "say nothing", which inherits.
            var childEnv = env
            // node COERCES env values to strings, and callers rely on it: vitest passes
            // `PROD: false` and `DEV: true` as booleans. Casting the whole dictionary to
            // [String: String] failed on those and dropped the ENTIRE environment on the floor —
            // silently, so the child simply never saw the variables it was given.
            if !envJSON.isEmpty, let data = envJSON.data(using: .utf8),
               let overrides = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                childEnv = overrides.reduce(into: [String: String]()) { result, pair in
                    if pair.value is NSNull { return }
                    if let text = pair.value as? String { result[pair.key] = text; return }
                    // JSON true/false parse to NSNumber, which stringifies as 1/0 — but node
                    // gives the child "true"/"false", and a program reading PROD sees the
                    // difference. A boolean has to be told apart from the number it is stored as.
                    if CFGetTypeID(pair.value as CFTypeRef) == CFBooleanGetTypeID() {
                        result[pair.key] = (pair.value as? Bool) == true ? "true" : "false"
                        return
                    }
                    if let number = pair.value as? NSNumber { result[pair.key] = number.stringValue; return }
                    result[pair.key] = String(describing: pair.value)
                }
            }
            let child = NodeEngine(root: root, env: childEnv, shell: shell)
            // Output crosses back as event-loop jobs on OUR thread, like every other event.
            child.attachTTY(TTY(
                write: { [weak self] text in
                    self?.enqueueJob { carried.value.call(withArguments: ["stdout", text]) }
                },
                writeError: { [weak self] text in
                    self?.enqueueJob { carried.value.call(withArguments: ["stderr", text]) }
                },
                rows: 24, columns: 80,
                rawModeChanged: { _ in }))
            child.markStdioAsPipe()
            if mode.contains("worker") { child.markAsWorker(data: workerData) }
            if wantsIPC {
                // fork(): the child's `process.send` reaches the parent as a 'message' event.
                child.attachIPC { [weak self] json in
                    self?.enqueueJob { carried.value.call(withArguments: ["message", json]) }
                }
            }
            children[id] = child
            refedChildren.insert(id)
            // The path is a VIRTUAL one and may carry dot segments — tinypool builds its worker
            // path as `.../dist/index.js/../entry/process.js`, which the OS refuses outright
            // because index.js is a file, not a directory. Normalising is what every other reader
            // here does; this one did not, and its `?? script` fallback then ran the PATH as the
            // program: a child that starts, does nothing, says nothing, and never exits — the
            // failure that hid vitest's worker for an entire boundary.
            var source = script
            if !isEval {
                guard let text = try? String(contentsOf: realURL(normalize(script)), encoding: .utf8) else {
                    let message = "Error: Cannot find module '\(script)'\n"
                    enqueueJob {
                        carried.value.call(withArguments: ["stderr", message])
                        carried.value.call(withArguments: ["exit", 1])
                        self.children[id] = nil
                        if self.refedChildren.remove(id) != nil { self.outstanding -= 1 }
                    }
                    return Int32(id)
                }
                source = text
            }
            let childPath = isEval ? "/[eval]" : normalize(script)
            Task.detached { [weak self] in
                let result = await child.run(source: source, path: childPath,
                                             argv: ["node"] + (isEval ? [] : [script]) + argv,
                                             cwd: cwd, stdin: "")
                self?.enqueueJob {
                    guard let self else { return }
                    if !result.out.isEmpty { carried.value.call(withArguments: ["stdout", result.out]) }
                    if !result.err.isEmpty { carried.value.call(withArguments: ["stderr", result.err]) }
                    carried.value.call(withArguments: ["exit", Int(result.status)])
                    self.children[id] = nil
                    // Only give back the handle if it is still held; an unref'd child already
                    // returned it.
                    if self.refedChildren.remove(id) != nil { self.outstanding -= 1 }
                }
            }
            return Int32(id)
        }
        let spawnWrite: @convention(block) (Int32, String) -> Void = { [weak self] id, text in
            self?.children[Int(id)]?.deliverInput(text)
        }
        let spawnEnd: @convention(block) (Int32) -> Void = { [weak self] id in
            self?.children[Int(id)]?.endInput()
        }
        let spawnKill: @convention(block) (Int32) -> Void = { [weak self] id in
            self?.children[Int(id)]?.terminate()
        }
        // `child.unref()` must genuinely release the handle. esbuild keeps its service alive
        // with a ping loop and unrefs the child so the loop does not hold the PROGRAM open —
        // with a no-op unref, `transform()` resolved and then nothing ever exited.
        let spawnMessage: @convention(block) (Int32, String) -> Void = { [weak self] id, json in
            self?.children[Int(id)]?.deliverMessage(json)
        }
        expose("spawnMessage", spawnMessage)
        // A port delivery: its own phase in the loop, which is where node runs them.
        let portDeliver: @convention(block) (JSValue) -> Void = { [weak self] callback in
            self?.portDeliveries.append(callback)
        }
        expose("portDeliver", portDeliver)
        // A handle JavaScript itself owns. node's BroadcastChannel keeps the loop alive until it
        // is closed or unref'd, and there was no way to express that from the bootstrap: every
        // other handle here is owned by the host side (a socket, a child, a timer).
        let loopHold: @convention(block) (Bool) -> Void = { [weak self] hold in
            guard let self else { return }
            outstanding += hold ? 1 : -1
        }
        expose("loopHold", loopHold)
        let spawnRef: @convention(block) (Int32, Bool) -> Void = { [weak self] id, refed in
            guard let self, children[Int(id)] != nil else { return }
            if refed, !refedChildren.contains(Int(id)) {
                refedChildren.insert(Int(id))
                outstanding += 1
            } else if !refed, refedChildren.contains(Int(id)) {
                refedChildren.remove(Int(id))
                outstanding -= 1
            }
        }
        expose("spawnRef", spawnRef)
        expose("spawnNode", spawnNode)
        expose("spawnWrite", spawnWrite)
        expose("spawnEnd", spawnEnd)
        expose("spawnKill", spawnKill)

        // -- HTTP over URLSession: fire on any thread, complete as an event-loop job --
        let httpRequest: @convention(block) (String, String, [String: String], String, JSValue) -> Void = { [weak self] urlText, method, headers, bodyBase64, callback in
            guard let self else { return }
            guard let url = URL(string: urlText) else {
                let carried = Carried(trampolined(callback))
                self.enqueueJob { carried.value.call(withArguments: [["error": "invalid URL: \(urlText)"]]) }
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if !bodyBase64.isEmpty { request.httpBody = Data(base64Encoded: bodyBase64) }
            self.outstanding += 1
            let carried = Carried(trampolined(callback))
            URLSession.shared.dataTask(with: request) { data, response, error in
                self.enqueueJob {
                    self.outstanding -= 1
                    if let error {
                        carried.value.call(withArguments: [["error": error.localizedDescription]])
                        return
                    }
                    let http = response as? HTTPURLResponse
                    var headerMap: [String: String] = [:]
                    for (name, value) in http?.allHeaderFields ?? [:] {
                        headerMap[String(describing: name).lowercased()] = String(describing: value)
                    }
                    carried.value.call(withArguments: [[
                        "status": http?.statusCode ?? 0,
                        "headers": headerMap,
                        "body": (data ?? Data()).base64EncodedString(),
                    ]])
                }
            }.resume()
        }
        expose("httpRequest", httpRequest)

        // -- the same transport, delivered INCREMENTALLY ------------------------------------
        // URLSession's completion-handler form hands over a finished body, which is fine for a
        // JSON call and wrong for a stream: an agent CLI reading server-sent events from an
        // HTTPS API got every token at once. The delegate form reports the head, then each
        // chunk as it arrives, then the end — which is what `fetch` and `https.request` now
        // ride. TLS stays where the system owns it; only the delivery changed.
        let httpStream: @convention(block) (String, String, [String: String], String, JSValue) -> Void = {
            [weak self] urlText, method, headers, bodyBase64, callback in
            guard let self else { return }
            let carried = Carried(trampolined(callback))
            guard let url = URL(string: urlText) else {
                enqueueJob { carried.value.call(withArguments: ["error", "invalid URL: \(urlText)"]) }
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if !bodyBase64.isEmpty { request.httpBody = Data(base64Encoded: bodyBase64) }
            outstanding += 1
            let collector = StreamCollector(
                deliver: { [weak self] event, payload in
                    self?.enqueueJob { carried.value.call(withArguments: [event, payload]) }
                },
                finished: { [weak self] in
                    self?.enqueueJob { self?.outstanding -= 1 }
                })
            // A delegate session must be invalidated or it retains its delegate forever;
            // StreamCollector does that when the task completes.
            let session = URLSession(configuration: .default, delegate: collector, delegateQueue: nil)
            collector.session = session
            session.dataTask(with: request).resume()
        }
        expose("httpStream", httpStream)

        // -- WebSocket, the one TLS-capable path ------------------------------------------
        // `ws://` works through our own sockets (the `ws` package proves it), but `wss://`
        // needs a TLS handshake we cannot put on a raw socket. URLSession has a native
        // WebSocket task, so the standard `WebSocket` global rides that — which is also what
        // node 22 exposes. Frames, masking and the close handshake belong to the system here.
        let wsOpen: @convention(block) (String, [String], JSValue) -> Int32 = { [weak self] urlText, protocols, callback in
            guard let self, let url = URL(string: urlText) else { return 0 }
            let carried = Carried(trampolined(callback))
            let deliver: @Sendable (String, Any) -> Void = { [weak self] event, payload in
                self?.enqueueJob { carried.value.call(withArguments: [event, payload]) }
            }
            let id = sockets.claimExternalID()
            outstanding += 1
            // `open` comes from the DELEGATE's handshake callback, not from a ping round-trip:
            // a ping races the first inbound frame, so the server's greeting could arrive
            // before the open event — node fires open first, always. The gate below also holds
            // messages until open has been delivered, so the order cannot invert.
            let opener = WebSocketOpener(deliver: deliver)
            let session = URLSession(configuration: .default, delegate: opener, delegateQueue: nil)
            let task = protocols.isEmpty ? session.webSocketTask(with: url)
                                         : session.webSocketTask(with: url, protocols: protocols)
            opener.session = session
            webSocketTasks[id] = task
            // A receive call yields ONE message and must be reissued — the loop is the read
            // side, and it ends when the socket does.
            @Sendable func receiveNext() {
                task.receive { [weak self] result in
                    switch result {
                    case let .success(message):
                        switch message {
                        case let .data(data): opener.message(["binary": true, "data": data.base64EncodedString()])
                        case let .string(text): opener.message(["binary": false, "data": text])
                        @unknown default: break
                        }
                        receiveNext()
                    case let .failure(error):
                        // A normal close arrives here as an error too; the close event carries
                        // whichever code the peer sent.
                        let code = task.closeCode == .invalid ? 1006 : task.closeCode.rawValue
                        deliver("close", ["code": code, "reason": error.localizedDescription])
                        self?.finishWebSocket(id)
                    }
                }
            }
            task.resume()
            receiveNext()
            return Int32(id)
        }
        let wsSend: @convention(block) (Int32, String, Bool) -> Void = { [weak self] id, payload, isText in
            guard let task = self?.webSocketTasks[Int(id)] else { return }
            let message: URLSessionWebSocketTask.Message = isText
                ? .string(payload)
                : .data(Data(base64Encoded: payload) ?? Data())
            task.send(message) { _ in }
        }
        let wsClose: @convention(block) (Int32, Int32, String) -> Void = { [weak self] id, code, reason in
            guard let self, let task = webSocketTasks[Int(id)] else { return }
            let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: Int(code)) ?? .normalClosure
            task.cancel(with: closeCode, reason: reason.data(using: .utf8))
            finishWebSocket(Int(id))
        }
        expose("wsOpen", wsOpen)
        expose("wsSend", wsSend)
        expose("wsClose", wsClose)

        // -- net: real TCP through SocketTable ---------------------------------------------
        // One dispatcher shape for every socket: `callback(event, payload)`. The JS side
        // switches on the name, so adding an event costs nothing here. All of these run on
        // the JS thread already (SocketTable delivers through `enqueueJob`).
        func dispatcher(_ callback: JSValue) -> SocketTable.Handler {
            let carried = Carried(trampolined(callback))
            @Sendable func plain(_ address: SocketTable.Address) -> [String: Any] {
                ["address": address.address, "port": address.port, "family": address.family]
            }
            return { id, event in
                switch event {
                case let .connect(local, remote):
                    carried.value.call(withArguments: [id, "connect", ["local": plain(local), "remote": plain(remote)]])
                case let .listening(address):
                    carried.value.call(withArguments: [id, "listening", plain(address)])
                case let .connection(socket, local, remote):
                    carried.value.call(withArguments: [id, "connection", ["id": socket, "local": plain(local), "remote": plain(remote)]])
                case let .handoff(fd, local, remote):
                    carried.value.call(withArguments: [id, "handoff", ["fd": Int(fd), "local": plain(local),
                                                                      "remote": plain(remote)]])
                case let .data(bytes):
                    carried.value.call(withArguments: [id, "data", bytes.base64EncodedString()])
                case let .datagram(bytes, from):
                    carried.value.call(withArguments: [id, "datagram", ["data": bytes.base64EncodedString(),
                                                                        "from": plain(from)]])
                case .end:
                    carried.value.call(withArguments: [id, "end", NSNull()])
                case .drain:
                    carried.value.call(withArguments: [id, "drain", NSNull()])
                case .close:
                    carried.value.call(withArguments: [id, "close", NSNull()])
                case let .error(message, code):
                    carried.value.call(withArguments: [id, "error", ["message": message, "code": code]])
                }
            }
        }
        let netConnect: @convention(block) (String, Int32, JSValue) -> Int32 = { [weak self] host, port, callback in
            guard let self else { return 0 }
            socketsUsed = true
            return Int32(sockets.connect(host: host, port: Int(port), handler: dispatcher(callback)))
        }
        let netListen: @convention(block) (String, Int32, Int32, JSValue) -> Int32 = { [weak self] host, port, backlog, callback in
            guard let self else { return 0 }
            socketsUsed = true
            return Int32(sockets.listen(host: host, port: Int(port),
                                        backlog: Int(backlog), handler: dispatcher(callback)))
        }
        // cluster's primary: accept here, run the connection somewhere else. Same OS process, so
        // the descriptor is valid in the worker engine and only the number crosses the channel.
        let netListenHandoff: @convention(block) (String, Int32, Int32, JSValue) -> Int32 = { [weak self] host, port, backlog, callback in
            guard let self else { return 0 }
            socketsUsed = true
            return Int32(sockets.listen(host: host, port: Int(port), backlog: Int(backlog),
                                        handoff: true, handler: dispatcher(callback)))
        }
        let netAdopt: @convention(block) (Int32, JSValue) -> Int32 = { [weak self] fd, callback in
            guard let self else { return 0 }
            socketsUsed = true
            return Int32(sockets.adopt(fd: fd, handler: dispatcher(callback)))
        }
        let netDiscard: @convention(block) (Int32) -> Void = { [weak self] fd in
            self?.sockets.discard(fd: fd)
        }
        let netWrite: @convention(block) (Int32, String) -> Bool = { [weak self] id, base64 in
            guard let self, let data = Data(base64Encoded: base64) else { return true }
            return sockets.write(id: Int(id), data: data)
        }
        let netEnd: @convention(block) (Int32) -> Void = { [weak self] id in self?.sockets.end(id: Int(id)) }
        let netDestroy: @convention(block) (Int32) -> Void = { [weak self] id in self?.sockets.destroy(id: Int(id)) }
        let netPause: @convention(block) (Int32) -> Void = { [weak self] id in self?.sockets.pause(id: Int(id)) }
        let netResume: @convention(block) (Int32) -> Void = { [weak self] id in self?.sockets.resume(id: Int(id)) }
        let netRef: @convention(block) (Int32, Bool) -> Void = { [weak self] id, refed in
            self?.sockets.setRef(id: Int(id), refed: refed)
        }
        let netNoDelay: @convention(block) (Int32, Bool) -> Void = { [weak self] id, on in
            self?.sockets.setNoDelay(id: Int(id), on)
        }
        let netKeepAlive: @convention(block) (Int32, Bool, Int32) -> Void = { [weak self] id, on, delay in
            self?.sockets.setKeepAlive(id: Int(id), on, delay: Int(delay))
        }
        let netResolve: @convention(block) (String, Int32, JSValue) -> Void = { [weak self] host, family, callback in
            guard let self else { return }
            socketsUsed = true
            let carried = Carried(trampolined(callback))
            sockets.resolve(host: host, family: Int(family)) { found, code in
                let list = found.map { ["address": $0.address, "family": $0.family == "IPv6" ? 6 : 4] as [String: Any] }
                carried.value.call(withArguments: [list, code ?? ""])
            }
        }
        // -- UDP ---------------------------------------------------------------------------
        // The refusal here used to say "not available yet", which promised nothing. The socket
        // layer is POSIX, so a datagram table is the same machinery with SOCK_DGRAM and
        // recvfrom — every packet whole, with its sender.
        let dgramBind: @convention(block) (String, Int32, Bool, JSValue) -> Int32 = { [weak self] host, port, broadcast, callback in
            guard let self else { return 0 }
            socketsUsed = true
            return Int32(sockets.bindDatagram(host: host, port: Int(port), broadcast: broadcast,
                                              handler: dispatcher(callback)))
        }
        let dgramSend: @convention(block) (Int32, String, String, Int32, JSValue) -> Void = {
            [weak self] id, base64, host, port, callback in
            guard let self, let data = Data(base64Encoded: base64) else { return }
            let carried = Carried(trampolined(callback))
            sockets.sendDatagram(id: Int(id), data: data, host: host, port: Int(port)) { code in
                carried.value.call(withArguments: [code ?? ""])
            }
        }
        let dgramMembership: @convention(block) (Int32, String, String, Bool) -> String = { [weak self] id, group, interface, join in
            // nil from the socket layer means SUCCESS. Coalescing it to "EBADF" reported every
            // successful join as a failure — the empty string is the "no problem" answer here.
            guard let self else { return "EBADF" }
            return sockets.multicastMembership(id: Int(id), group: group, interface: interface, join: join) ?? ""
        }
        let dgramOption: @convention(block) (Int32, Int32, Int32, String) -> Void = { [weak self] id, ttl, loopback, interface in
            // -1 means "leave this one alone": each knob is set independently.
            self?.sockets.multicastOption(id: Int(id), ttl: ttl < 0 ? nil : Int(ttl),
                                          loopback: loopback < 0 ? nil : loopback == 1,
                                          interface: interface.isEmpty ? nil : interface)
        }
        expose("dgramMembership", dgramMembership)
        expose("dgramOption", dgramOption)
        expose("dgramBind", dgramBind)
        expose("dgramSend", dgramSend)
        expose("netResolve", netResolve)
        // The dns.resolve* family. dns.lookup is getaddrinfo; these ask a DNS SERVER for a
        // specific record type, which is why they were absent. res_9_query does the asking.
        let dnsResolve: @convention(block) (String, String, JSValue) -> Void = { [weak self] name, type, callback in
            guard let self else { return }
            let carried = Carried(trampolined(callback))
            NodeDNS.resolve(name: name, type: type) { [weak self] records, code in
                self?.enqueueJob {
                    carried.value.call(withArguments: [records ?? [], code ?? ""])
                }
            }
            outstanding += 1
            pendingLookups += 1
        }
        let dnsReverse: @convention(block) (String, JSValue) -> Void = { [weak self] address, callback in
            guard let self else { return }
            let carried = Carried(trampolined(callback))
            NodeDNS.reverse(address: address) { [weak self] names, code in
                self?.enqueueJob {
                    carried.value.call(withArguments: [names ?? [], code ?? ""])
                }
            }
            outstanding += 1
            pendingLookups += 1
        }
        let dnsService: @convention(block) (String, Int32, JSValue) -> Void = { [weak self] address, port, callback in
            guard let self else { return }
            let carried = Carried(trampolined(callback))
            NodeDNS.lookupService(address: address, port: Int(port)) { [weak self] host, service, code in
                self?.enqueueJob {
                    carried.value.call(withArguments: [host ?? "", service ?? "", code ?? ""])
                }
            }
            outstanding += 1
            pendingLookups += 1
        }
        // Every completion above releases the handle it took, so a program waiting only on a
        // lookup stays alive exactly until the answer arrives.
        let dnsDone: @convention(block) () -> Void = { [weak self] in
            guard let self, pendingLookups > 0 else { return }
            pendingLookups -= 1
            outstanding -= 1
        }
        expose("dnsResolve", dnsResolve)
        expose("dnsReverse", dnsReverse)
        expose("dnsService", dnsService)
        expose("dnsDone", dnsDone)

        // -- fs.watch: kqueue through WatchTable -------------------------------------------
        let fsWatch: @convention(block) (String, Bool, JSValue) -> Int32 = { [weak self] path, recursive, callback in
            guard let self else { return 0 }
            watchersUsed = true
            let carried = Carried(trampolined(callback))
            guard let id = watchers.watch(path: realURL(path).path, recursive: recursive, handler: { event in
                switch event {
                case let .rename(name): carried.value.call(withArguments: ["rename", name])
                case let .change(name): carried.value.call(withArguments: ["change", name])
                }
            }) else { return 0 }
            return Int32(id)
        }
        let fsUnwatch: @convention(block) (Int32) -> Void = { [weak self] id in
            self?.watchers.close(id: Int(id))
        }
        expose("fsWatch", fsWatch)
        expose("fsUnwatch", fsUnwatch)
        // A socket FILE instead of a host and port. The audit called this reachable but
        // unbuilt; it is the same stream machinery with a different address family.
        let netConnectUnix: @convention(block) (String, JSValue) -> Int32 = { [weak self] path, callback in
            guard let self else { return 0 }
            socketsUsed = true
            return Int32(sockets.connectUnix(path: realURL(path).path, handler: dispatcher(callback)))
        }
        let netListenUnix: @convention(block) (String, Int32, JSValue) -> Int32 = { [weak self] path, backlog, callback in
            guard let self else { return 0 }
            socketsUsed = true
            return Int32(sockets.listenUnix(path: realURL(path).path, backlog: Int(backlog),
                                            handler: dispatcher(callback)))
        }
        expose("netConnectUnix", netConnectUnix)
        expose("netListenUnix", netListenUnix)
        expose("netConnect", netConnect)
        expose("netListen", netListen)
        expose("netListenHandoff", netListenHandoff)
        expose("netAdopt", netAdopt)
        expose("netDiscard", netDiscard)
        expose("netWrite", netWrite)
        expose("netEnd", netEnd)
        expose("netDestroy", netDestroy)
        expose("netPause", netPause)
        expose("netResume", netResume)
        expose("netRef", netRef)
        expose("netNoDelay", netNoDelay)
        expose("netKeepAlive", netKeepAlive)

        // -- crypto: CryptoKit digests/HMAC, the system CSPRNG -----------------------------
        let cryptoHash: @convention(block) (String, String) -> String? = { algorithm, base64 in
            guard let data = Data(base64Encoded: base64) else { return nil }
            switch algorithm {
            case "md5": return Data(Insecure.MD5.hash(data: data)).base64EncodedString()
            case "sha1": return Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
            case "sha256": return Data(SHA256.hash(data: data)).base64EncodedString()
            case "sha384": return Data(SHA384.hash(data: data)).base64EncodedString()
            case "sha512": return Data(SHA512.hash(data: data)).base64EncodedString()
            default: return nil
            }
        }
        expose("cryptoHash", cryptoHash)

        // -- ciphers and KDFs -------------------------------------------------------------
        // AEAD modes come from CryptoKit; CBC and CTR from CommonCrypto, which is the only
        // system API that exposes them. Everything is one-shot: node's Cipher is a stream, but
        // the JS side buffers and calls this at final(), which is what keeps the tag handling
        // honest (an AEAD tag cannot be produced before the last byte anyway).
        let cipherSeal: @convention(block) (String, String, String, String, String) -> Any = {
            algorithm, keyBase64, ivBase64, plainBase64, aadBase64 in
            guard let key = Data(base64Encoded: keyBase64),
                  let iv = Data(base64Encoded: ivBase64),
                  let plain = Data(base64Encoded: plainBase64) else { return NSNull() }
            let aad = Data(base64Encoded: aadBase64) ?? Data()
            do {
                switch algorithm {
                case "aes-128-gcm", "aes-192-gcm", "aes-256-gcm":
                    let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key),
                                               nonce: try AES.GCM.Nonce(data: iv),
                                               authenticating: aad)
                    return ["data": box.ciphertext.base64EncodedString(),
                            "tag": box.tag.base64EncodedString()] as [String: Any]
                case "chacha20-poly1305":
                    let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key),
                                                  nonce: try ChaChaPoly.Nonce(data: iv),
                                                  authenticating: aad)
                    return ["data": box.ciphertext.base64EncodedString(),
                            "tag": box.tag.base64EncodedString()] as [String: Any]
                default:
                    guard let out = Self.commonCrypt(algorithm: algorithm, key: key, iv: iv,
                                                     input: plain, encrypt: true) else { return NSNull() }
                    return ["data": out.base64EncodedString(), "tag": ""] as [String: Any]
                }
            } catch { return NSNull() }
        }
        let cipherOpen: @convention(block) (String, String, String, String, String, String) -> Any = {
            algorithm, keyBase64, ivBase64, cipherBase64, tagBase64, aadBase64 in
            guard let key = Data(base64Encoded: keyBase64),
                  let iv = Data(base64Encoded: ivBase64),
                  let body = Data(base64Encoded: cipherBase64) else { return NSNull() }
            let aad = Data(base64Encoded: aadBase64) ?? Data()
            let tag = Data(base64Encoded: tagBase64) ?? Data()
            do {
                switch algorithm {
                case "aes-128-gcm", "aes-192-gcm", "aes-256-gcm":
                    let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: iv),
                                                    ciphertext: body, tag: tag)
                    let plain = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
                    return plain.base64EncodedString()
                case "chacha20-poly1305":
                    let box = try ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: iv),
                                                       ciphertext: body, tag: tag)
                    let plain = try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
                    return plain.base64EncodedString()
                default:
                    guard let out = Self.commonCrypt(algorithm: algorithm, key: key, iv: iv,
                                                     input: body, encrypt: false) else { return NSNull() }
                    return out.base64EncodedString()
                }
            } catch { return NSNull() }   // a wrong tag lands here, which is the point of AEAD
        }
        let pbkdf2Block: @convention(block) (String, String, Int32, Int32, String) -> Any = {
            passwordBase64, saltBase64, iterations, length, digest in
            guard let password = Data(base64Encoded: passwordBase64),
                  let salt = Data(base64Encoded: saltBase64) else { return NSNull() }
            let algorithm: UInt32
            switch digest.lowercased() {
            case "sha1": algorithm = UInt32(kCCPRFHmacAlgSHA1)
            case "sha224": algorithm = UInt32(kCCPRFHmacAlgSHA224)
            case "sha256": algorithm = UInt32(kCCPRFHmacAlgSHA256)
            case "sha384": algorithm = UInt32(kCCPRFHmacAlgSHA384)
            case "sha512": algorithm = UInt32(kCCPRFHmacAlgSHA512)
            default: return NSNull()
            }
            var derived = [UInt8](repeating: 0, count: Int(length))
            let status = password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(algorithm), UInt32(iterations),
                        &derived, derived.count)
                }
            }
            guard status == kCCSuccess else { return NSNull() }
            return Data(derived).base64EncodedString()
        }
        let hkdfBlock: @convention(block) (String, String, String, String, Int32) -> Any = {
            digest, keyBase64, saltBase64, infoBase64, length in
            guard let key = Data(base64Encoded: keyBase64) else { return NSNull() }
            let salt = Data(base64Encoded: saltBase64) ?? Data()
            let info = Data(base64Encoded: infoBase64) ?? Data()
            let material = SymmetricKey(data: key)
            let count = Int(length)
            func derive<H: HashFunction>(_ hash: H.Type) -> String {
                let derived = HKDF<H>.deriveKey(inputKeyMaterial: material, salt: salt,
                                                info: info, outputByteCount: count)
                return derived.withUnsafeBytes { Data($0).base64EncodedString() }
            }
            switch digest.lowercased() {
            case "sha256": return derive(SHA256.self)
            case "sha384": return derive(SHA384.self)
            case "sha512": return derive(SHA512.self)
            case "sha1": return derive(Insecure.SHA1.self)
            default: return NSNull()
            }
        }
        // -- asymmetric: EC and Ed25519 signing ------------------------------------------
        // CryptoKit imports and exports PKCS#8/SPKI PEM for P-256/384/521 directly, so no
        // ASN.1 of ours is involved for EC. Ed25519 has no PEM API, but RFC 8410 wrappers are
        // FIXED shapes (48 bytes private, 44 public) — checked byte for byte here rather than
        // parsed loosely, so a malformed key errors instead of yielding garbage.
        let ed25519PrivatePrefix = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03,
                                         0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])
        // X25519's PKCS#8/SPKI wrappers are fixed-shape like Ed25519's — only the OID differs
        // (1.3.101.110 vs .112) — so the raw 32 bytes CryptoKit wants are a prefix strip away.
        let x25519PrivatePrefix = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03,
                                        0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20])
        let x25519PublicPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e,
                                       0x03, 0x21, 0x00])
        let ed25519PublicPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70,
                                        0x03, 0x21, 0x00])
        // X448 (OID 1.3.101.111). Fixed-shape wrappers like X25519's, over 56 raw bytes rather
        // than 32 — the keys themselves are computed in JS, since X448 is arithmetic and not a
        // system key type, but they still have to be RECOGNISED here.
        let x448PrivatePrefix = Data([0x30, 0x46, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03,
                                      0x2b, 0x65, 0x6f, 0x04, 0x3a, 0x04, 0x38])
        let x448PublicPrefix = Data([0x30, 0x42, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6f,
                                     0x03, 0x39, 0x00])
        func pemBody(_ pem: String) -> Data? {
            let lines = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }
            return Data(base64Encoded: lines.joined())
        }
        func pemWrap(_ body: Data, _ label: String) -> String {
            let base64 = body.base64EncodedString()
            var lines: [String] = []
            var index = base64.startIndex
            while index < base64.endIndex {
                let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
                lines.append(String(base64[index..<end]))
                index = end
            }
            return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
        }
        func edPrivate(_ pem: String) -> Curve25519.Signing.PrivateKey? {
            guard let body = pemBody(pem), body.count == 48,
                  body.prefix(16) == ed25519PrivatePrefix else { return nil }
            return try? Curve25519.Signing.PrivateKey(rawRepresentation: body.suffix(32))
        }
        func edPublic(_ pem: String) -> Curve25519.Signing.PublicKey? {
            guard let body = pemBody(pem), body.count == 44,
                  body.prefix(12) == ed25519PublicPrefix else { return nil }
            return try? Curve25519.Signing.PublicKey(rawRepresentation: body.suffix(32))
        }
        /// What kind of key is this? JS needs it for `asymmetricKeyType` and to reject an
        /// algorithm/key mismatch the way node does.
        let keyIdentify: @convention(block) (String) -> Any = { pem in
            // RSA is decided by the algorithm identifier in the DER, not by guessing at length.
            if NodeKeys.isRSA(pem: pem) {
                return ["type": "rsa", "curve": "",
                        "modulusLength": NodeKeys.modulusLength(pem: pem)] as [String: Any]
            }
            if (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil ||
               (try? P256.Signing.PublicKey(pemRepresentation: pem)) != nil {
                return ["type": "ec", "curve": "prime256v1"] as [String: Any]
            }
            if (try? P384.Signing.PrivateKey(pemRepresentation: pem)) != nil ||
               (try? P384.Signing.PublicKey(pemRepresentation: pem)) != nil {
                return ["type": "ec", "curve": "secp384r1"] as [String: Any]
            }
            if (try? P521.Signing.PrivateKey(pemRepresentation: pem)) != nil ||
               (try? P521.Signing.PublicKey(pemRepresentation: pem)) != nil {
                return ["type": "ec", "curve": "secp521r1"] as [String: Any]
            }
            if edPrivate(pem) != nil || edPublic(pem) != nil {
                return ["type": "ed25519", "curve": ""] as [String: Any]
            }
            // X25519 is told apart from Ed25519 by its OID alone — same wrapper shape, and both
            // are 32 raw bytes, so a length check would confuse them.
            if let body = NodeKeys.der(fromPEM: pem) {
                if body.count == x25519PrivatePrefix.count + 32,
                   body.prefix(x25519PrivatePrefix.count) == x25519PrivatePrefix {
                    return ["type": "x25519", "curve": ""] as [String: Any]
                }
                if body.count == x25519PublicPrefix.count + 32,
                   body.prefix(x25519PublicPrefix.count) == x25519PublicPrefix {
                    return ["type": "x25519", "curve": ""] as [String: Any]
                }
                if body.count == x448PrivatePrefix.count + 56,
                   body.prefix(x448PrivatePrefix.count) == x448PrivatePrefix {
                    return ["type": "x448", "curve": ""] as [String: Any]
                }
                if body.count == x448PublicPrefix.count + 56,
                   body.prefix(x448PublicPrefix.count) == x448PublicPrefix {
                    return ["type": "x448", "curve": ""] as [String: Any]
                }
            }
            return ["type": "unknown", "curve": ""] as [String: Any]
        }
        /// Sign. `raw` picks node's `dsaEncoding: 'ieee-p1363'` over the DER default.
        let keySign: @convention(block) (String, String, String, Bool) -> Any = { pem, dataBase64, digestName, raw in
            guard let data = Data(base64Encoded: dataBase64) else { return NSNull() }
            func ecSignature<Key>(_ key: Key, _ sign: (Key, Data) throws -> (der: Data, raw: Data)) -> Any {
                guard let pair = try? sign(key, data) else { return NSNull() }
                return (raw ? pair.raw : pair.der).base64EncodedString()
            }
            func digestData(_ name: String, _ input: Data) -> (any Digest)? {
                // OpenSSL's legacy names reach us through real libraries: `jwa` signs ES256 by
                // asking for "RSA-SHA256" (the prefix is historical and works for any key type
                // in node), and certificates use "ecdsa-with-SHA256". Not normalizing these
                // made jsonwebtoken fail on a digest node accepts.
                var normalized = name.lowercased().replacingOccurrences(of: "-", with: "")
                for prefix in ["rsa", "ecdsawith", "ecdsa"] where normalized.hasPrefix(prefix) {
                    normalized = String(normalized.dropFirst(prefix.count))
                    break
                }
                switch normalized {
                case "sha256": return SHA256.hash(data: input)
                case "sha384": return SHA384.hash(data: input)
                case "sha512": return SHA512.hash(data: input)
                case "sha1": return Insecure.SHA1.hash(data: input)
                default: return nil
                }
            }
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
                guard let digest = digestData(digestName, data),
                      let signature = try? key.signature(for: digest) else { return NSNull() }
                return (raw ? signature.rawRepresentation : signature.derRepresentation).base64EncodedString()
            }
            if let key = try? P384.Signing.PrivateKey(pemRepresentation: pem) {
                guard let digest = digestData(digestName, data),
                      let signature = try? key.signature(for: digest) else { return NSNull() }
                return (raw ? signature.rawRepresentation : signature.derRepresentation).base64EncodedString()
            }
            if let key = try? P521.Signing.PrivateKey(pemRepresentation: pem) {
                guard let digest = digestData(digestName, data),
                      let signature = try? key.signature(for: digest) else { return NSNull() }
                return (raw ? signature.rawRepresentation : signature.derRepresentation).base64EncodedString()
            }
            if let key = edPrivate(pem) {
                // Ed25519 signs the MESSAGE, never a digest — that is the algorithm, and node
                // rejects a digest name for it too.
                guard let signature = try? key.signature(for: data) else { return NSNull() }
                return signature.base64EncodedString()
            }
            return NSNull()
        }
        let keyVerify: @convention(block) (String, String, String, String, Bool) -> Any = {
            pem, dataBase64, signatureBase64, digestName, raw in
            guard let data = Data(base64Encoded: dataBase64),
                  let signature = Data(base64Encoded: signatureBase64) else { return false }
            func digestData(_ name: String, _ input: Data) -> (any Digest)? {
                // OpenSSL's legacy names reach us through real libraries: `jwa` signs ES256 by
                // asking for "RSA-SHA256" (the prefix is historical and works for any key type
                // in node), and certificates use "ecdsa-with-SHA256". Not normalizing these
                // made jsonwebtoken fail on a digest node accepts.
                var normalized = name.lowercased().replacingOccurrences(of: "-", with: "")
                for prefix in ["rsa", "ecdsawith", "ecdsa"] where normalized.hasPrefix(prefix) {
                    normalized = String(normalized.dropFirst(prefix.count))
                    break
                }
                switch normalized {
                case "sha256": return SHA256.hash(data: input)
                case "sha384": return SHA384.hash(data: input)
                case "sha512": return SHA512.hash(data: input)
                case "sha1": return Insecure.SHA1.hash(data: input)
                default: return nil
                }
            }
            // A public key may arrive as either an SPKI public PEM or a private one.
            if let key = (try? P256.Signing.PublicKey(pemRepresentation: pem))
                ?? (try? P256.Signing.PrivateKey(pemRepresentation: pem))?.publicKey {
                guard let digest = digestData(digestName, data) else { return false }
                let parsed = raw ? try? P256.Signing.ECDSASignature(rawRepresentation: signature)
                                 : try? P256.Signing.ECDSASignature(derRepresentation: signature)
                guard let parsed else { return false }
                return key.isValidSignature(parsed, for: digest)
            }
            if let key = (try? P384.Signing.PublicKey(pemRepresentation: pem))
                ?? (try? P384.Signing.PrivateKey(pemRepresentation: pem))?.publicKey {
                guard let digest = digestData(digestName, data) else { return false }
                let parsed = raw ? try? P384.Signing.ECDSASignature(rawRepresentation: signature)
                                 : try? P384.Signing.ECDSASignature(derRepresentation: signature)
                guard let parsed else { return false }
                return key.isValidSignature(parsed, for: digest)
            }
            if let key = (try? P521.Signing.PublicKey(pemRepresentation: pem))
                ?? (try? P521.Signing.PrivateKey(pemRepresentation: pem))?.publicKey {
                guard let digest = digestData(digestName, data) else { return false }
                let parsed = raw ? try? P521.Signing.ECDSASignature(rawRepresentation: signature)
                                 : try? P521.Signing.ECDSASignature(derRepresentation: signature)
                guard let parsed else { return false }
                return key.isValidSignature(parsed, for: digest)
            }
            if let key = edPublic(pem) ?? edPrivate(pem)?.publicKey {
                return key.isValidSignature(signature, for: data)
            }
            return false
        }
        let keyGenerate: @convention(block) (String, String) -> Any = { type, curve in
            switch (type, curve) {
            case ("ec", "prime256v1"), ("ec", "P-256"), ("ec", ""):
                let key = P256.Signing.PrivateKey()
                return ["privateKey": key.pemRepresentation,
                        "publicKey": key.publicKey.pemRepresentation] as [String: Any]
            case ("ec", "secp384r1"), ("ec", "P-384"):
                let key = P384.Signing.PrivateKey()
                return ["privateKey": key.pemRepresentation,
                        "publicKey": key.publicKey.pemRepresentation] as [String: Any]
            case ("ec", "secp521r1"), ("ec", "P-521"):
                let key = P521.Signing.PrivateKey()
                return ["privateKey": key.pemRepresentation,
                        "publicKey": key.publicKey.pemRepresentation] as [String: Any]
            case ("x25519", _):
                let key = Curve25519.KeyAgreement.PrivateKey()
                return ["privateKey": pemWrap(x25519PrivatePrefix + key.rawRepresentation, "PRIVATE KEY"),
                        "publicKey": pemWrap(x25519PublicPrefix + key.publicKey.rawRepresentation,
                                             "PUBLIC KEY")] as [String: Any]
            case ("ed25519", _):
                let key = Curve25519.Signing.PrivateKey()
                let privateBody = ed25519PrivatePrefix + key.rawRepresentation
                let publicBody = ed25519PublicPrefix + key.publicKey.rawRepresentation
                return ["privateKey": pemWrap(privateBody, "PRIVATE KEY"),
                        "publicKey": pemWrap(publicBody, "PUBLIC KEY")] as [String: Any]
            default:
                return NSNull()
            }
        }
        let rsaSign: @convention(block) (String, String, String, Bool) -> Any = { pem, dataBase64, digest, pss in
            guard let data = Data(base64Encoded: dataBase64),
                  let signature = NodeKeys.sign(pem: pem, message: data,
                                                digest: Self.digestName(digest), pss: pss) else { return NSNull() }
            return signature.base64EncodedString()
        }
        let rsaVerify: @convention(block) (String, String, String, String, Bool) -> Any = {
            pem, dataBase64, signatureBase64, digest, pss in
            guard let data = Data(base64Encoded: dataBase64),
                  let signature = Data(base64Encoded: signatureBase64) else { return false }
            return NodeKeys.verify(pem: pem, message: data, signature: signature,
                                   digest: Self.digestName(digest), pss: pss)
        }
        let rsaEncrypt: @convention(block) (String, String, Int32, String) -> Any = { pem, plainBase64, padding, digest in
            guard let plain = Data(base64Encoded: plainBase64),
                  let sealed = NodeKeys.encrypt(pem: pem, plain: plain, padding: Int(padding),
                                                digest: Self.digestName(digest)) else { return NSNull() }
            return sealed.base64EncodedString()
        }
        let rsaDecrypt: @convention(block) (String, String, Int32, String) -> Any = { pem, cipherBase64, padding, digest in
            guard let body = Data(base64Encoded: cipherBase64),
                  let plain = NodeKeys.decrypt(pem: pem, cipher: body, padding: Int(padding),
                                               digest: Self.digestName(digest)) else { return NSNull() }
            return plain.base64EncodedString()
        }
        let rsaGenerate: @convention(block) (Int32) -> Any = { bits in
            guard let pair = NodeKeys.generate(modulusLength: Int(bits)) else { return NSNull() }
            return ["privateKey": pair.privatePEM, "publicKey": pair.publicPEM] as [String: Any]
        }
        expose("rsaSign", rsaSign)
        expose("rsaVerify", rsaVerify)
        expose("rsaEncrypt", rsaEncrypt)
        expose("rsaDecrypt", rsaDecrypt)
        let rsaPrivateEncrypt: @convention(block) (String, String) -> Any = { pem, base64 in
            guard let data = Data(base64Encoded: base64),
                  let sealed = NodeKeys.privateEncrypt(pem: pem, data: data) else { return NSNull() }
            return sealed.base64EncodedString()
        }
        let rsaPublicDecrypt: @convention(block) (String, String) -> Any = { pem, base64 in
            guard let data = Data(base64Encoded: base64),
                  let opened = NodeKeys.publicDecrypt(pem: pem, data: data) else { return NSNull() }
            return opened.base64EncodedString()
        }
        expose("rsaPrivateEncrypt", rsaPrivateEncrypt)
        expose("rsaPublicDecrypt", rsaPublicDecrypt)
        expose("rsaGenerate", rsaGenerate)
        // -- ECDH, on CryptoKit's key agreement ------------------------------------------
        // This refused for a while claiming it needed SecKey. It does not: CryptoKit does ECDH
        // over P-256/384/521 and X25519, and node's public-key encoding (the uncompressed point
        // 0x04‖X‖Y) is exactly CryptoKit's x963Representation, so the wire format lines up with
        // no conversion at all.
        let ecdhGenerate: @convention(block) (String) -> Any = { curve in
            func pair<Key>(_ key: Key, _ priv: (Key) -> Data, _ pub: (Key) -> Data) -> [String: Any] {
                ["privateKey": priv(key).base64EncodedString(), "publicKey": pub(key).base64EncodedString()]
            }
            switch curve {
            case "prime256v1", "P-256", "secp256r1":
                let key = P256.KeyAgreement.PrivateKey()
                return pair(key, { $0.rawRepresentation }, { $0.publicKey.x963Representation })
            case "secp384r1", "P-384":
                let key = P384.KeyAgreement.PrivateKey()
                return pair(key, { $0.rawRepresentation }, { $0.publicKey.x963Representation })
            case "secp521r1", "P-521":
                let key = P521.KeyAgreement.PrivateKey()
                return pair(key, { $0.rawRepresentation }, { $0.publicKey.x963Representation })
            case "x25519":
                let key = Curve25519.KeyAgreement.PrivateKey()
                return pair(key, { $0.rawRepresentation }, { $0.publicKey.rawRepresentation })
            default:
                return NSNull()
            }
        }
        let ecdhCompute: @convention(block) (String, String, String) -> Any = { curve, privateBase64, peerBase64 in
            guard let priv = Data(base64Encoded: privateBase64),
                  let peer = Data(base64Encoded: peerBase64) else { return NSNull() }
            do {
                switch curve {
                case "prime256v1", "P-256", "secp256r1":
                    let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: priv)
                    let other = try P256.KeyAgreement.PublicKey(x963Representation: peer)
                    let secret = try key.sharedSecretFromKeyAgreement(with: other)
                    return secret.withUnsafeBytes { Data($0).base64EncodedString() }
                case "secp384r1", "P-384":
                    let key = try P384.KeyAgreement.PrivateKey(rawRepresentation: priv)
                    let other = try P384.KeyAgreement.PublicKey(x963Representation: peer)
                    let secret = try key.sharedSecretFromKeyAgreement(with: other)
                    return secret.withUnsafeBytes { Data($0).base64EncodedString() }
                case "secp521r1", "P-521":
                    let key = try P521.KeyAgreement.PrivateKey(rawRepresentation: priv)
                    let other = try P521.KeyAgreement.PublicKey(x963Representation: peer)
                    let secret = try key.sharedSecretFromKeyAgreement(with: other)
                    return secret.withUnsafeBytes { Data($0).base64EncodedString() }
                case "x25519":
                    let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv)
                    let other = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
                    let secret = try key.sharedSecretFromKeyAgreement(with: other)
                    return secret.withUnsafeBytes { Data($0).base64EncodedString() }
                default:
                    return NSNull()
                }
            } catch { return NSNull() }
        }
        // `crypto.diffieHellman({privateKey, publicKey})` — node's KEY OBJECT agreement, which is
        // X25519 and the EC curves, NOT finite-field DH. The refusal used to say "finite-field DH
        // needs a bignum implementation": true of `createDiffieHellman`, and the wrong function.
        // CryptoKit reads EC PEMs directly; X25519 has no PEM initialiser, so its fixed wrapper
        // is stripped above.
        let keyAgree: @convention(block) (String, String) -> Any = { privatePEM, publicPEM in
            func der(_ pem: String) -> Data? {
                let joined = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
                return Data(base64Encoded: joined)
            }
            // X25519 first: its OID is what distinguishes it, and CryptoKit wants raw bytes.
            if let privateDER = der(privatePEM), let publicDER = der(publicPEM),
               privateDER.count == x25519PrivatePrefix.count + 32,
               privateDER.prefix(x25519PrivatePrefix.count) == x25519PrivatePrefix,
               publicDER.count == x25519PublicPrefix.count + 32,
               publicDER.prefix(x25519PublicPrefix.count) == x25519PublicPrefix {
                do {
                    let key = try Curve25519.KeyAgreement.PrivateKey(
                        rawRepresentation: privateDER.suffix(32))
                    let peer = try Curve25519.KeyAgreement.PublicKey(
                        rawRepresentation: publicDER.suffix(32))
                    let secret = try key.sharedSecretFromKeyAgreement(with: peer)
                    return secret.withUnsafeBytes { Data($0).base64EncodedString() }
                } catch { return NSNull() }
            }
            // Then the EC curves, whichever one the PEM turns out to be.
            if let key = try? P256.KeyAgreement.PrivateKey(pemRepresentation: privatePEM),
               let peer = try? P256.KeyAgreement.PublicKey(pemRepresentation: publicPEM),
               let secret = try? key.sharedSecretFromKeyAgreement(with: peer) {
                return secret.withUnsafeBytes { Data($0).base64EncodedString() }
            }
            if let key = try? P384.KeyAgreement.PrivateKey(pemRepresentation: privatePEM),
               let peer = try? P384.KeyAgreement.PublicKey(pemRepresentation: publicPEM),
               let secret = try? key.sharedSecretFromKeyAgreement(with: peer) {
                return secret.withUnsafeBytes { Data($0).base64EncodedString() }
            }
            if let key = try? P521.KeyAgreement.PrivateKey(pemRepresentation: privatePEM),
               let peer = try? P521.KeyAgreement.PublicKey(pemRepresentation: publicPEM),
               let secret = try? key.sharedSecretFromKeyAgreement(with: peer) {
                return secret.withUnsafeBytes { Data($0).base64EncodedString() }
            }
            return NSNull()
        }
        expose("keyAgree", keyAgree)
        expose("ecdhGenerate", ecdhGenerate)
        expose("ecdhCompute", ecdhCompute)
        expose("keyIdentify", keyIdentify)
        expose("keySign", keySign)
        expose("keyVerify", keyVerify)
        expose("keyGenerate", keyGenerate)
        expose("cipherSeal", cipherSeal)
        expose("cipherOpen", cipherOpen)
        expose("pbkdf2", pbkdf2Block)
        // scrypt: PBKDF2 around a memory-hard mix, so it needs no system primitive beyond the
        // PBKDF2 above. NSNull means "node would reject these params" — the JS side turns that
        // into ERR_CRYPTO_INVALID_SCRYPT_PARAMS rather than re-deriving the rules.
        let scryptBlock: @convention(block) (String, String, Int32, Int32, Int32, Int32) -> Any = {
            passwordBase64, saltBase64, n, r, parallel, length in
            guard let password = Data(base64Encoded: passwordBase64),
                  let salt = Data(base64Encoded: saltBase64),
                  let derived = NodeScrypt.derive(password: password, salt: salt, n: Int(n),
                                                  r: Int(r), p: Int(parallel), length: Int(length))
            else { return NSNull() }
            return derived.base64EncodedString()
        }
        expose("scrypt", scryptBlock)
        expose("hkdf", hkdfBlock)
        let cryptoHmac: @convention(block) (String, String, String) -> String? = { algorithm, keyBase64, base64 in
            guard let keyData = Data(base64Encoded: keyBase64), let data = Data(base64Encoded: base64) else { return nil }
            let key = SymmetricKey(data: keyData)
            switch algorithm {
            case "md5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: key)).base64EncodedString()
            case "sha1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key)).base64EncodedString()
            case "sha256": return Data(HMAC<SHA256>.authenticationCode(for: data, using: key)).base64EncodedString()
            case "sha384": return Data(HMAC<SHA384>.authenticationCode(for: data, using: key)).base64EncodedString()
            case "sha512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: key)).base64EncodedString()
            default: return nil
            }
        }
        expose("cryptoHmac", cryptoHmac)
        let randomBytes: @convention(block) (Int) -> String = { count in
            // SystemRandomNumberGenerator is the platform CSPRNG.
            var generator = SystemRandomNumberGenerator()
            let bytes = (0..<max(0, count)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            return Data(bytes).base64EncodedString()
        }
        expose("randomBytes", randomBytes)
        let randomUUID: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        expose("randomUUID", randomUUID)

        // -- zlib: real deflate/inflate over libz (windowBits picks gzip/zlib/raw) ---------
        // `level` was accepted and dropped, so `{level: 0}` (store, do not compress) compressed
        // anyway. Found by a sweep for options that are silently ignored.
        let zlibTransform: @convention(block) (String, String, Int32) -> String? = { mode, base64, level in
            guard let input = Data(base64Encoded: base64) else { return nil }
            let deflating: Bool
            let windowBits: Int32
            switch mode {
            case "gzip": deflating = true; windowBits = 15 + 16
            case "deflate": deflating = true; windowBits = 15
            case "deflateRaw": deflating = true; windowBits = -15
            case "inflateRaw": deflating = false; windowBits = -15
            // 15+32 auto-detects gzip vs zlib headers — covers gunzip/inflate/unzip.
            case "gunzip", "inflate", "unzip": deflating = false; windowBits = 15 + 32
            default: return nil
            }
            return Self.zlibCode(input, deflating: deflating, windowBits: windowBits,
                                 level: level)?.base64EncodedString()
        }
        expose("zlibTransform", zlibTransform)
        // `mode` on writeFile/mkdir was ignored, so a program writing a secret with mode 0o600
        // got a world-readable file. POSIX chmod, on the real path behind the virtual one.
        let chmodPath: @convention(block) (String, Int32) -> Bool = { [weak self] path, mode in
            guard let self else { return false }
            return chmod(realURL(path).path, mode_t(mode)) == 0
        }
        expose("chmodPath", chmodPath)
        // Incremental coding: open a live stream, push chunks, close. Same windowBits map as
        // the one-shot path.
        let zlibOpen: @convention(block) (String) -> Int = { [weak self] mode in
            guard let self else { return 0 }
            let deflating: Bool
            let windowBits: Int32
            switch mode {
            case "gzip": deflating = true; windowBits = 15 + 16
            case "deflate": deflating = true; windowBits = 15
            case "deflateRaw": deflating = true; windowBits = -15
            case "inflateRaw": deflating = false; windowBits = -15
            case "gunzip", "inflate", "unzip": deflating = false; windowBits = 15 + 32
            default: return 0
            }
            guard let stream = ZlibStream(deflating: deflating, windowBits: windowBits) else { return 0 }
            let handle = self.nextZlibHandle
            self.nextZlibHandle += 1
            self.zlibStreams[handle] = stream
            return handle
        }
        expose("zlibOpen", zlibOpen)
        let zlibPush: @convention(block) (Int, String, Bool) -> String? = { [weak self] handle, base64, finish in
            guard let self, let stream = self.zlibStreams[handle] else { return nil }
            let input = base64.isEmpty ? Data() : (Data(base64Encoded: base64) ?? Data())
            guard let output = stream.push(input, finish: finish) else { return nil }
            return output.base64EncodedString()
        }
        expose("zlibPush", zlibPush)
        // brotli through Apple's Compression framework. The refusal said brotli "is not built
        // into this device"; COMPRESSION_BROTLI has shipped since iOS 15. A surface sweep found
        // it, not a package failing.
        let brotliTransform: @convention(block) (String, String) -> String? = { mode, base64 in
            guard let data = Data(base64Encoded: base64) else { return nil }
            return BrotliStream.transform(data, compressing: mode == "compress")?.base64EncodedString()
        }
        let brotliOpen: @convention(block) (String) -> Int = { [weak self] mode in
            guard let self, let stream = BrotliStream(compressing: mode == "compress") else { return 0 }
            brotliHandle += 1
            brotliStreams[brotliHandle] = stream
            return brotliHandle
        }
        let brotliPush: @convention(block) (Int, String, Bool) -> String? = { [weak self] handle, base64, finish in
            guard let self, let stream = brotliStreams[handle] else { return nil }
            let input = base64.isEmpty ? Data() : (Data(base64Encoded: base64) ?? Data())
            return stream.push(input, finish: finish)?.base64EncodedString()
        }
        let brotliClose: @convention(block) (Int) -> Void = { [weak self] handle in
            self?.brotliStreams.removeValue(forKey: handle)
        }
        expose("brotliTransform", brotliTransform)
        expose("brotliOpen", brotliOpen)
        expose("brotliPush", brotliPush)
        expose("brotliClose", brotliClose)
        let zlibClose: @convention(block) (Int) -> Void = { [weak self] handle in
            guard let self else { return }
            self.zlibStreams.removeValue(forKey: handle)?.close()
        }
        expose("zlibClose", zlibClose)
        let createRequireBlock: @convention(block) (String) -> Any = { [weak self] fromPath in
            guard let self else { return NSNull() }
            var from = fromPath
            if from.hasPrefix("file://") { from = String(from.dropFirst(7)) }
            return self.makeRequire(fromDir: self.virtualDirname(self.normalize(from)))
        }
        expose("createRequire", createRequireBlock)
        // The same code-only rewrite the loader applies, for source compiled at RUNTIME.
        let rewriteImports: @convention(block) (String) -> String = { text in
            Self.rewriteImportForms(text, meta: false).text
        }
        expose("rewriteImports", rewriteImports)

        context.setObject(bridge, forKeyedSubscript: "__mouse" as NSString)
        context.setObject(argv, forKeyedSubscript: "__argv" as NSString)
        // napi-rs generates a loader that tries this platform's `.node` and only falls back to
        // the package's WebAssembly build when told to. On iOS the native one can never load —
        // no downloaded machine code runs — so the fallback is not a preference here, it is the
        // only reachable branch, and this is the flag its own authors provide for saying so.
        var childEnvironment = env
        if childEnvironment["NAPI_RS_FORCE_WASI"] == nil { childEnvironment["NAPI_RS_FORCE_WASI"] = "true" }
        context.setObject(childEnvironment, forKeyedSubscript: "__env" as NSString)
        context.setObject(cwd, forKeyedSubscript: "__cwd" as NSString)
        context.setObject(stdin, forKeyedSubscript: "__stdin" as NSString)
        // Is the seeded text ALL the input there will ever be? Only the host knows. A terminal
        // can always deliver more, and a spawned CHILD's parent writes to its pipe later — the
        // first version of this inferred "no TTY means no writer" and broke every child that
        // reads stdin. True only for a run given a fixed string with no live source.
        context.setObject(tty == nil && !stdioIsPipe,
                          forKeyedSubscript: "__stdinIsComplete" as NSString)
        // A pipe is not a terminal: the sink is the same machinery, but `isTTY` must be false
        // or a program takes its interactive path — colors, spinners, raw mode — while writing
        // to a parent that wanted bytes.
        context.setObject(tty != nil && !stdioIsPipe, forKeyedSubscript: "__isTTY" as NSString)
        // A child's stdio is a PIPE, and a pipe carries bytes. Decoding it as UTF-8 destroys a
        // binary protocol (esbuild's length-prefixed packets), so a piped child encodes through
        // latin1 — one codepoint per byte, lossless in both directions — while a terminal keeps
        // UTF-8, which is what a screen wants.
        context.setObject(stdioIsPipe, forKeyedSubscript: "__stdioBinary" as NSString)
        context.setObject(ipcSink != nil, forKeyedSubscript: "__hasIPC" as NSString)
        context.setObject(workerData ?? "", forKeyedSubscript: "__workerData" as NSString)
        context.setObject(workerData != nil, forKeyedSubscript: "__isWorker" as NSString)
        context.setObject(tty?.rows ?? 24, forKeyedSubscript: "__ttyRows" as NSString)
        context.setObject(tty?.columns ?? 80, forKeyedSubscript: "__ttyColumns" as NSString)
    }

    /// A live libz stream: the state that makes INCREMENTAL coding possible. The one-shot
    /// path can't serve `zlib.createGunzip()` fed chunk-by-chunk (minizlib under tar does
    /// exactly that) — a partial member isn't decodable on its own, so each chunk must feed
    /// the same z_stream and take whatever output is ready.
    private final class ZlibStream {
        let stream: UnsafeMutablePointer<z_stream>
        let deflating: Bool
        var closed = false

        init?(deflating: Bool, windowBits: Int32) {
            self.deflating = deflating
            stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            stream.initialize(to: z_stream())
            let size = Int32(MemoryLayout<z_stream>.size)
            let status = deflating
                ? deflateInit2_(stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, zlibVersion(), size)
                : inflateInit2_(stream, windowBits, zlibVersion(), size)
            guard status == Z_OK else {
                stream.deallocate()
                return nil
            }
        }

        /// Feed `input`, return whatever output libz produces. `finish` flushes the tail.
        func push(_ input: Data, finish: Bool) -> Data? {
            guard !closed else { return nil }
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            var source = [UInt8](input)
            let ok: Bool = source.withUnsafeMutableBufferPointer { sourcePointer in
                stream.pointee.next_in = sourcePointer.baseAddress
                stream.pointee.avail_in = uInt(sourcePointer.count)
                while true {
                    var status: Int32 = Z_OK
                    let produced = buffer.withUnsafeMutableBufferPointer { bufferPointer -> Int in
                        stream.pointee.next_out = bufferPointer.baseAddress
                        stream.pointee.avail_out = uInt(bufferPointer.count)
                        status = deflating
                            ? deflate(stream, finish ? Z_FINISH : Z_NO_FLUSH)
                            : inflate(stream, finish ? Z_FINISH : Z_NO_FLUSH)
                        return bufferPointer.count - Int(stream.pointee.avail_out)
                    }
                    if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                    if status == Z_STREAM_END { return true }
                    if status == Z_OK { if produced == 0 && stream.pointee.avail_in == 0 { return true }; continue }
                    // Z_BUF_ERROR just means "no progress possible right now" mid-stream.
                    if status == Z_BUF_ERROR { return !finish }
                    return false
                }
            }
            return ok ? output : nil
        }

        func close() {
            guard !closed else { return }
            closed = true
            if deflating { deflateEnd(stream) } else { inflateEnd(stream) }
            stream.deallocate()
        }

        deinit { close() }
    }

    /// Live coder streams, keyed by the handle JS holds. Touched only on the JS queue.
    private var zlibStreams: [Int: ZlibStream] = [:]
    /// Live brotli coders, the same shape as the zlib table above.
    private var brotliStreams: [Int: BrotliStream] = [:]
    private var brotliHandle = 0
    /// Outstanding DNS queries, so the loop waits for an answer instead of exiting under it.
    private var pendingLookups = 0
    private var nextZlibHandle = 1

    /// One-shot deflate or inflate with explicit windowBits (15=zlib, 15+16=gzip, -15=raw,
    /// 15+32=auto-detect on inflate). libz, not Compression — same reason as GitCore.
    /// `level` is node's compression level: -1 for the default, 0 to store without compressing,
    /// 1..9 for fastest..smallest. It used to be dropped on the floor.
    private static func zlibCode(_ input: Data, deflating: Bool, windowBits: Int32,
                                 level: Int32 = -1) -> Data? {
        var stream = z_stream()
        let streamSize = Int32(MemoryLayout<z_stream>.size)
        let initStatus = deflating
            ? deflateInit2_(&stream, level, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, zlibVersion(), streamSize)
            : inflateInit2_(&stream, windowBits, zlibVersion(), streamSize)
        guard initStatus == Z_OK else { return nil }
        defer { if deflating { deflateEnd(&stream) } else { inflateEnd(&stream) } }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var source = [UInt8](input)
        let finished: Bool = source.withUnsafeMutableBufferPointer { sourcePointer in
            stream.next_in = sourcePointer.baseAddress
            stream.avail_in = uInt(sourcePointer.count)
            while true {
                var status: Int32 = Z_OK
                let produced = buffer.withUnsafeMutableBufferPointer { bufferPointer -> Int in
                    stream.next_out = bufferPointer.baseAddress
                    stream.avail_out = uInt(bufferPointer.count)
                    status = deflating ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_FINISH)
                    return bufferPointer.count - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                if status == Z_STREAM_END { return true }
                guard status == Z_OK || status == Z_BUF_ERROR else { return false }
                // Z_BUF_ERROR with output space left means the input was truncated/corrupt.
                if status == Z_BUF_ERROR && produced == 0 { return false }
            }
        }
        return finished ? output : nil
    }

    /// OpenSSL's legacy digest names reach us through real libraries — `jwa` signs RS256 by
    /// asking for "RSA-SHA256", certificates use "ecdsa-with-SHA256". One normalizer, used by
    /// every signing path.
    static func digestName(_ raw: String) -> String {
        var normalized = raw.lowercased().replacingOccurrences(of: "-", with: "")
        for prefix in ["rsassapss", "rsa", "ecdsawith", "ecdsa"] where normalized.hasPrefix(prefix) {
            normalized = String(normalized.dropFirst(prefix.count))
            break
        }
        return normalized
    }

    /// CBC and CTR through CommonCrypto — the only system API that exposes them (CryptoKit is
    /// AEAD-only, deliberately). PKCS#7 padding for CBC, none for CTR, matching node's
    /// defaults for `aes-256-cbc` and `aes-256-ctr`.
    static func commonCrypt(algorithm: String, key: Data, iv: Data, input: Data, encrypt: Bool) -> Data? {
        let mode: UInt32
        let padding: CCPadding
        if algorithm.hasSuffix("-cbc") { mode = UInt32(kCCModeCBC); padding = CCPadding(ccPKCS7Padding) }
        else if algorithm.hasSuffix("-ctr") { mode = UInt32(kCCModeCTR); padding = CCPadding(ccNoPadding) }
        else if algorithm.hasSuffix("-ecb") { mode = UInt32(kCCModeECB); padding = CCPadding(ccPKCS7Padding) }
        else { return nil }
        // Key length is implied by the name, and a mismatch must fail rather than truncate.
        let expected: Int
        if algorithm.hasPrefix("aes-128") { expected = 16 }
        else if algorithm.hasPrefix("aes-192") { expected = 24 }
        else if algorithm.hasPrefix("aes-256") { expected = 32 }
        else { return nil }
        guard key.count == expected else { return nil }

        var cryptor: CCCryptorRef?
        let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        let created = key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
            iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                CCCryptorCreateWithMode(operation, CCMode(mode), CCAlgorithm(kCCAlgorithmAES),
                                        padding, iv.isEmpty ? nil : ivBytes.baseAddress,
                                        keyBytes.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(0), &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let updated = input.withUnsafeBytes { inputBytes in
            CCCryptorUpdate(cryptor, inputBytes.baseAddress, input.count,
                            &output, output.count, &moved)
        }
        guard updated == kCCSuccess else { return nil }
        var total = moved
        var finalMoved = 0
        let finished = output.withUnsafeMutableBytes { buffer -> CCCryptorStatus in
            CCCryptorFinal(cryptor, buffer.baseAddress?.advanced(by: total),
                           buffer.count - total, &finalMoved)
        }
        guard finished == kCCSuccess else { return nil }
        total += finalMoved
        return Data(output[0..<total])
    }

    // MARK: - Paths (workspace-virtual ↔ real)

    /// "/a/b" and "a/b" both live under the workspace root; ".." clamps at "/".
    private func normalize(_ path: String) -> String {
        var parts: [String] = []
        for piece in path.split(separator: "/") {
            if piece == "." { continue }
            if piece == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(piece))
        }
        return "/" + parts.joined(separator: "/")
    }

    private func realURL(_ path: String) -> URL {
        let normalized = normalize(path)
        return normalized == "/" ? root : root.appendingPathComponent(String(normalized.dropFirst()))
    }

    private func virtualDirname(_ path: String) -> String {
        let normalized = normalize(path)
        guard let slash = normalized.lastIndex(of: "/") else { return "/" }
        let dir = String(normalized[..<slash])
        return dir.isEmpty ? "/" : dir
    }

    // MARK: - Module resolution

    private enum Resolution {
        case core(String)
        case file(String)
        case json(String)
        case notFound(String)
        /// A `.node` file: compiled machine code, which node loads through `process.dlopen`.
        /// It resolves — the file is right there — and fails at LOAD, which is where the
        /// platform's answer belongs. Reporting it as not-found sent people deleting
        /// node_modules over something no reinstall can fix.
        case addon(String)
        /// A package declared "exports" and the request is not in it. Node treats the map as
        /// the package's ONLY public surface, so this is a refusal, not a miss — and it has its
        /// own error code, which tools branch on.
        case notExported(String)
    }

    static let coreModules: Set<String> = [
        "fs", "path", "os", "util", "events", "buffer", "tty", "assert", "url",
        "child_process", "http", "https", "net", "crypto", "stream", "zlib",
        "readline", "readline/promises", "string_decoder", "constants", "querystring",
        "fs/promises", "stream/promises", "process", "module", "timers", "timers/promises",
        "path/posix", "path/win32", "http2", "tls", "dns", "worker_threads", "async_hooks",
        "v8", "vm", "perf_hooks", "inspector", "dgram", "cluster", "diagnostics_channel",
        "console", "util/types", "domain", "wasi",
    ]

    /// `esm` is the syntax the REQUEST was written in, which is what picks the export
    /// condition: node resolves `import 'x'` on "import" and `require('x')` on "require",
    /// and a dual package ships genuinely different files behind the two.
    private func resolveModule(_ rawRequest: String, fromDir: String, esm: Bool = false) -> Resolution {
        var request = rawRequest
        if request.hasPrefix("node:") { request = String(request.dropFirst(5)) }
        if Self.coreModules.contains(request) { return .core(request) }

        // A `file://` URL is a legal specifier for dynamic import, and it is what a tool hands
        // us when cache-busting an ESM config (eslint appends the file's mtime as a query).
        // Neither query nor fragment is part of the filename, and the path is percent-encoded.
        if request.lowercased().hasPrefix("file://") {
            var rest = String(request.dropFirst("file://".count))
            if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                rest = String(rest[rest.startIndex..<cut])
            }
            if !rest.hasPrefix("/") {   // an authority, which for a file URL carries no path
                rest = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
            }
            request = rest.removingPercentEncoding ?? rest
            if let found = loadAsFileOrDirectory(normalize(request), esm: esm) { return found }
            return .notFound("Cannot find module '\(rawRequest)'")
        }

        // "#name": the package.json "imports" field of the requiring package.
        if request.hasPrefix("#") {
            var dir = fromDir
            while true {
                let packageJSON = realURL(dir + "/package.json")
                if let data = try? Data(contentsOf: packageJSON),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let imports = json["imports"] as? [String: Any] {
                    if let target = exportsTarget(imports[request], esm: esm) ?? (imports[request] as? String) {
                        if let found = loadAsFileOrDirectory(normalize(dir + "/" + target), esm: esm) { return found }
                    }
                    break
                }
                if dir == "/" || dir.isEmpty { break }
                dir = virtualDirname(dir)
            }
            return .notFound("Cannot find module '\(rawRequest)'")
        }

        // `require(".")` and `require("..")` are relative DIRECTORY requests — webpack's
        // Compiler.js requires its own package that way (`require(".")`), and without the bare
        // forms here they fell through to the node_modules walk and failed.
        if request == "." || request == ".." ||
           request.hasPrefix("./") || request.hasPrefix("../") || request.hasPrefix("/") {
            let base = request.hasPrefix("/") ? request : fromDir + "/" + request
            if let found = loadAsFileOrDirectory(normalize(base), esm: esm) { return found }
            return .notFound("Cannot find module '\(rawRequest)'")
        }

        // A tsconfig `paths` alias, which looks like a bare specifier and is neither a package
        // nor a path. Tried before node_modules, as every TS runner does — an alias that shadows
        // a package name is the project saying which one it means.
        for alias in typeScriptAliases(fromDir: fromDir) {
            let parts = alias.pattern.components(separatedBy: "*")
            var candidate: String?
            if parts.count == 2 {
                if request.hasPrefix(parts[0]), request.hasSuffix(parts[1]),
                   request.count >= parts[0].count + parts[1].count {
                    let star = String(request.dropFirst(parts[0].count).dropLast(parts[1].count))
                    candidate = alias.target.replacingOccurrences(of: "*", with: star)
                }
            } else if request == alias.pattern {
                candidate = alias.target
            }
            if let candidate, let found = loadAsFileOrDirectory(normalize(candidate), esm: esm) {
                return found
            }
        }

        // Bare specifier: walk node_modules upward from the requiring directory. A bare
        // specifier with a slash is NOT a path — `rollup/parseAst` is an "exports" KEY, and a
        // package that declares "exports" publishes only what that map names. Trying the map
        // before the literal path is node's order; falling back to the path afterwards keeps
        // packages whose map is incomplete working, where node would refuse.
        let (packageName, subpath) = Self.splitBareSpecifier(request)
        var dir = fromDir
        while true {
            let packageDir = normalize(dir + "/node_modules/" + packageName)
            if subpath != ".", isDirectoryPath(packageDir),
               let data = try? Data(contentsOf: realURL(packageDir + "/package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let exports = json["exports"] {
                guard let target = exportsTarget(exports, subpath: subpath, esm: esm),
                      let found = loadAsFileOrDirectory(normalize(packageDir + "/" + target), esm: esm) else {
                    return .notExported("Package subpath '\(subpath)' is not defined by \"exports\" in "
                                        + packageDir + "/package.json")
                }
                return found
            }
            let candidate = normalize(dir + "/node_modules/" + request)
            if let found = loadAsFileOrDirectory(candidate, esm: esm) { return found }
            if dir == "/" || dir.isEmpty { break }
            dir = virtualDirname(dir)
        }
        return .notFound("Cannot find module '\(rawRequest)'")
    }

    private func loadAsFileOrDirectory(_ path: String, esm: Bool = false) -> Resolution? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false

        func fileResolution(_ virtual: String) -> Resolution {
            if virtual.hasSuffix(".json") { return .json(virtual) }
            if virtual.hasSuffix(".node") { return .addon(virtual) }
            return .file(virtual)
        }

        if fm.fileExists(atPath: realURL(path).path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return fileResolution(path)
        }
        for suffix in [".js", ".cjs", ".json", ".node", ".ts", ".tsx", ".mts", ".cts"] {
            let candidate = path + suffix
            if fm.fileExists(atPath: realURL(candidate).path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return fileResolution(candidate)
            }
        }
        guard isDirectoryPath(path) else { return nil }

        // package.json: "exports" (string or {".": …}) wins, then "main", then index.js.
        let packageJSON = realURL(path + "/package.json")
        if let data = try? Data(contentsOf: packageJSON),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // With "exports" present, node ignores "main" and "index.js" entirely: the map is
            // the whole of what the package publishes.
            if let exports = json["exports"] {
                guard let target = exportsTarget(exports, esm: esm) else { return nil }
                return loadAsFileOrDirectory(normalize(path + "/" + target), esm: esm)
            }
            if let main = json["main"] as? String, !main.isEmpty {
                if let found = loadAsFileOrDirectory(normalize(path + "/" + main), esm: esm) { return found }
            }
        }
        for index in ["/index.js", "/index.json"] {
            let candidate = path + index
            if FileManager.default.fileExists(atPath: realURL(candidate).path) {
                return fileResolution(candidate)
            }
        }
        return nil
    }

    private func isDirectoryPath(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: realURL(path).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Split a bare specifier into its package and the subpath below it: `rollup/parseAst`
    /// is the package `rollup` and the exports key `./parseAst`, and a scope keeps two
    /// segments (`@babel/core/lib/x` → `@babel/core`, `./lib/x`).
    static func splitBareSpecifier(_ request: String) -> (String, String) {
        var pieces = request.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var nameCount = 1
        if pieces.first?.hasPrefix("@") == true && pieces.count >= 2 { nameCount = 2 }
        guard pieces.count > nameCount else { return (request, ".") }
        let name = pieces.prefix(nameCount).joined(separator: "/")
        pieces.removeFirst(nameCount)
        return (name, "./" + pieces.joined(separator: "/"))
    }

    /// node's PACKAGE_EXPORTS_RESOLVE: a string, an array of fallbacks, a conditions object,
    /// or a subpath map with exact keys and `*` patterns. `subpath` is "." or "./something".
    ///
    /// The condition SET comes from how the request was written, not from a fixed preference:
    /// an `import` sees {node, import, default} and a `require` sees {node, require, default},
    /// which is what makes a dual package hand each syntax its own build. The old fixed order
    /// tried "require" first for everyone, so an ESM importer got the CommonJS half — vite,
    /// whose CJS entry is a deprecated shim, is where that showed.
    private func exportsTarget(_ exports: Any?, subpath: String = ".", esm: Bool) -> String? {
        let syntax = esm ? "import" : "require"
        // Ordered most specific first. Node honours the object's own key order; JSON parsing
        // here does not preserve it, and this order matches what that rule yields in practice
        // (a platform condition wraps a syntax condition, and "default" is written last).
        let order = ["node", syntax, "default"]
        func target(_ value: Any?, _ star: String?) -> String? {
            if let text = value as? String {
                guard !text.isEmpty else { return nil }
                return star.map { text.replacingOccurrences(of: "*", with: $0) } ?? text
            }
            if let list = value as? [Any] {
                for item in list { if let found = target(item, star) { return found } }
                return nil
            }
            guard let object = value as? [String: Any] else { return nil }   // null = blocked
            for key in order { if let found = target(object[key], star) { return found } }
            return nil
        }

        guard let exports else { return nil }
        let map = exports as? [String: Any]
        let isSubpathMap = map?.keys.contains { $0 == "." || $0.hasPrefix("./") } ?? false

        if subpath == "." {
            if !isSubpathMap { return target(exports, nil) }     // string, array, or conditions
            return target(map?["."], nil)
        }
        guard isSubpathMap, let map else { return nil }
        if let exact = map[subpath] { return target(exact, nil) }
        // Pattern keys: the longest literal prefix before `*` wins, as node specifies.
        var best: (prefix: String, suffix: String, key: String)?
        for key in map.keys where key.contains("*") {
            let parts = key.components(separatedBy: "*")
            guard parts.count == 2 else { continue }
            let (prefix, suffix) = (parts[0], parts[1])
            guard subpath.hasPrefix(prefix), subpath.hasSuffix(suffix),
                  subpath.count >= prefix.count + suffix.count else { continue }
            if best == nil || prefix.count > best!.prefix.count { best = (prefix, suffix, key) }
        }
        guard let best else { return nil }
        let star = String(subpath.dropFirst(best.prefix.count).dropLast(best.suffix.count))
        return target(map[best.key], star)
    }

    // MARK: - require()

    private func makeRequire(fromDir: String, esm: Bool = false) -> JSValue {
        // `import()` resolves on the "import" condition WHATEVER the importing file is — node
        // keys the condition to the syntax, not to the file's format, and a CommonJS file
        // reaching an ESM-only package through import() is exactly how eslint loads @humanfs/node.
        let importBlock: @convention(block) (String) -> Any = { [weak self] request in
            guard let self else { return NSNull() }
            return self.requireModule(request, fromDir: fromDir, esm: true)
        }
        let requireBlock: @convention(block) (String) -> Any = { [weak self] request in
            guard let self else { return NSNull() }
            return self.requireModule(request, fromDir: fromDir, esm: esm)
        }
        let resolveBlock: @convention(block) (String) -> Any = { [weak self] request in
            guard let self else { return NSNull() }
            switch self.resolveModule(request, fromDir: fromDir, esm: esm) {
            case .core(let name): return "node:" + name
            case .file(let id), .json(let id), .addon(let id): return id
            case .notFound(let message): return ["__mouseRequireError": message]
            case .notExported(let message): return ["__mouseRequireError": message,
                                                    "__mouseRequireCode": "ERR_PACKAGE_PATH_NOT_EXPORTED"]
            }
        }
        // `require.resolve.paths(request)`: the directories that WOULD be searched. jest asks
        // for these to build its own module registry, so a missing one stops it at startup.
        // node returns null for a core module, the node_modules walk-up for a bare specifier,
        // and just the requiring directory for a relative one.
        let resolvePathsBlock: @convention(block) (String) -> Any = { [weak self] request in
            guard let self else { return NSNull() }
            var name = request
            if name.hasPrefix("node:") { name = String(name.dropFirst(5)) }
            if Self.coreModules.contains(name) { return NSNull() }
            if request.hasPrefix("./") || request.hasPrefix("../") || request == "." || request == ".." {
                return [fromDir.isEmpty ? "/" : fromDir]
            }
            var paths: [String] = []
            var dir = fromDir.isEmpty ? "/" : fromDir
            while true {
                paths.append(dir == "/" ? "/node_modules" : dir + "/node_modules")
                if dir == "/" || dir.isEmpty { break }
                dir = self.virtualDirname(dir)
            }
            return paths
        }
        // Errors must throw IN the requiring frame — a native block can't, so a JS wrapper
        // inspects the marker and throws there.
        let factory = context.evaluateScript("""
            (function(native, nativeResolve, nativeResolvePaths, nativeImport){
                function require(specifier){
                    const result = native(String(specifier));
                    if (result && result.__mouseRequireError) {
                        const error = new Error(result.__mouseRequireError);
                        error.code = result.__mouseRequireCode || 'MODULE_NOT_FOUND';
                        throw error;
                    }
                    if (result && result.__mouseRequireThrow) throw result.__mouseRequireThrow;
                    return result;
                }
                require.resolve = function(specifier){
                    const result = nativeResolve(String(specifier));
                    if (result && result.__mouseRequireError) {
                        const error = new Error(result.__mouseRequireError);
                        error.code = result.__mouseRequireCode || 'MODULE_NOT_FOUND';
                        throw error;
                    }
                    return result;
                };
                require.resolve.paths = function(specifier){
                    return nativeResolvePaths(String(specifier));
                };
                require.__importCondition = function(specifier){
                    const result = nativeImport(String(specifier));
                    if (result && result.__mouseRequireError) {
                        const error = new Error(result.__mouseRequireError);
                        error.code = result.__mouseRequireCode || 'ERR_MODULE_NOT_FOUND';
                        throw error;
                    }
                    if (result && result.__mouseRequireThrow) throw result.__mouseRequireThrow;
                    return result;
                };
                return require;
            })
            """)!
        return factory.call(withArguments: [JSValue(object: requireBlock, in: context)!,
                                            JSValue(object: resolveBlock, in: context)!,
                                            JSValue(object: resolvePathsBlock, in: context)!,
                                            JSValue(object: importBlock, in: context)!])!
    }

    private func requireModule(_ request: String, fromDir: String, esm: Bool = false) -> Any {
        // A query on a file: specifier is a cache-bust, not part of the filename — its whole
        // purpose is to force a fresh evaluation, so the cached copy has to go first.
        if request.lowercased().hasPrefix("file://"), request.contains("?"),
           case .file(let id) = resolveModule(request, fromDir: fromDir, esm: esm) {
            moduleCache.removeValue(forKey: id)
        }
        switch resolveModule(request, fromDir: fromDir, esm: esm) {
        case .core(let name):
            if let cached = moduleCache["core:" + name] { return cached }
            let value = context.evaluateScript("globalThis.__coreModule(\(jsString(name)))")!
            moduleCache["core:" + name] = value
            return value

        case .json(let id):
            if let cached = moduleCache[id] { return cached }
            guard let data = try? Data(contentsOf: realURL(id)),
                  let text = String(data: data, encoding: .utf8) else {
                return throwInJS("Cannot read '\(id)'")
            }
            let value = context.evaluateScript("(\(text))") ?? JSValue(nullIn: context)!
            moduleCache[id] = value
            return value

        case .file(let id):
            // A circular require during evaluation reads exports LIVE off the module object —
            // `module.exports = Class` before the cycle closes must be visible to the partner.
            if let inProgress = modulesInProgress[id] { return inProgress.forProperty("exports")! }
            if let cached = moduleCache[id] { return cached }
            guard let data = try? Data(contentsOf: realURL(id)),
                  var source = String(data: data, encoding: .utf8) else {
                return throwInJS("Cannot read '\(id)'")
            }
            if source.hasPrefix("#!") {   // strip before transpile — the prologue would bury it mid-source
                source = source.drop(while: { $0 != "\n" }).isEmpty ? "" : String(source.drop(while: { $0 != "\n" }))
            }
            switch typeScriptSource(id: id, source: source) {
            case .failed(let message): return throwInJS(message)
            case .compiled(let compiled): source = compiled
            case .notTypeScript: break
            }
            registerSourceMap(id: id, source: source)
            let esm = isESModule(id: id, source: source)
            if esm {
                source = transpileCached(source)
            } else if source.contains("import") {
                // Dynamic import() is legal in CJS too (prettier lazy-loads plugins with it).
                // JSC's native import has no module loader here — route through ours.
                source = Self.rewriteDynamicImport(source)
            }
            // ESM evaluates under an ASYNC wrapper (its imports may await a top-level-await
            // dependency); CJS stays a plain sync function.
            guard let function = wrapModule(source, async: esm, sourceURL: id) else {
                return throwInJS("Cannot parse '\(id)'" + (lastParseProblem.map { ": " + $0 } ?? ""))
            }
            let module = context.evaluateScript("({exports: {}})")!
            modulesInProgress[id] = module
            defer { modulesInProgress.removeValue(forKey: id) }
            let require = makeRequire(fromDir: virtualDirname(id), esm: esm)
            if esm {
                // Three sync-inspectable outcomes: done (body never suspended — exports are
                // ready now, the common case), thrown (evict, rethrow in the requiring
                // frame), or pending (real top-level await — requirers receive a promise of
                // the exports; transpiled importers await it, real ESM's infection).
                let trampoline = context.evaluateScript("""
                    (function(fn, exports, require, module, filename, dirname){
                        const promise = fn(exports, require, module, filename, dirname, require, filename);
                        if (module.__esmError !== undefined) {
                            promise.catch(function(){});
                            const e = module.__esmError;
                            return { thrown: { __mouseRequireThrow: e === null ? new Error('null thrown') : e } };
                        }
                        if (module.__esmDone) { promise.catch(function(){}); return { done: true }; }
                        return { pending: promise.then(function(){ return module.exports; }) };
                    })
                    """)!
                let outcome = trampoline.call(withArguments: [function, module.forProperty("exports")!, require, module, id, virtualDirname(id)])!
                if let thrown = outcome.forProperty("thrown"), !thrown.isUndefined {
                    moduleCache.removeValue(forKey: id)
                    return thrown
                }
                if let pending = outcome.forProperty("pending"), !pending.isUndefined {
                    moduleCache[id] = pending
                    return pending
                }
            } else {
                // A module that throws mid-evaluation must not linger as partial exports:
                // catch JS-side (so the exception never dissolves at the native boundary),
                // evict, and rethrow the ORIGINAL error in the requiring frame.
                let trampoline = context.evaluateScript("""
                    (function(fn, exports, require, module, filename, dirname){
                        try { fn(exports, require, module, filename, dirname, require, filename); return null; }
                        catch (e) { return { __mouseRequireThrow: e === undefined ? new Error('undefined thrown') : e }; }
                    })
                    """)!
                let outcome = trampoline.call(withArguments: [function, module.forProperty("exports")!, require, module, id, virtualDirname(id)])
                if let outcome, outcome.isObject, outcome.forProperty("__mouseRequireThrow")?.isUndefined == false {
                    moduleCache.removeValue(forKey: id)
                    return outcome
                }
            }
            let exports = module.forProperty("exports")!
            moduleCache[id] = exports
            return exports

        case .notFound(let message):
            return throwInJS(message)

        case .notExported(let message):
            return ["__mouseRequireError": message, "__mouseRequireCode": "ERR_PACKAGE_PATH_NOT_EXPORTED"]

        case .addon(let id):
            // The same sentence process.dlopen gives, because it is the same wall: node loads a
            // .node file BY calling dlopen, and this is that call.
            return ["__mouseRequireError": "Cannot load '\(id)': a .node addon is compiled machine "
                                         + "code, and iOS will not map new executable pages",
                    "__mouseRequireCode": "ERR_DLOPEN_FAILED"]
        }
    }

    // MARK: - ES modules (transpiled to CommonJS at load)

    /// .mjs is ESM, .cjs is CJS; .js follows the nearest package.json "type"; and a file
    /// with top-of-line import/export statements is ESM regardless (entry scripts).
    /// TypeScript, if this file is TypeScript. Returns nil when it is not, and throws the
    /// compiler's absence as a MESSAGE rather than a crash — "install typescript" is something
    /// the reader can act on, where a SyntaxError on a type annotation is not.
    private var tsAliasCache: [String: [(pattern: String, target: String)]] = [:]
    /// Resolving an alias needs typescript, and requiring typescript is itself a resolution —
    /// without this the first bare specifier in a TS project recurses until the stack gives out.
    private var resolvingAliases = false

    /// The `paths` map from the nearest tsconfig.json. `@/lib` is neither a package nor a path;
    /// it is an alias the project declared, and TS projects are full of them.
    private func typeScriptAliases(fromDir: String) -> [(pattern: String, target: String)] {
        if let cached = tsAliasCache[fromDir] { return cached }
        guard !resolvingAliases else { return [] }
        resolvingAliases = true
        defer { resolvingAliases = false }
        var pairs: [(pattern: String, target: String)] = []
        if let helper = context.objectForKeyedSubscript("__tsPathAliases"),
           let result = helper.call(withArguments: [(fromDir.isEmpty ? "/" : fromDir) + "/index.ts"]),
           !result.isNull, !result.isUndefined,
           let rows = result.toArray() as? [[String]] {
            pairs = rows.compactMap { $0.count == 2 ? (pattern: $0[0], target: $0[1]) : nil }
        }
        tsAliasCache[fromDir] = pairs
        return pairs
    }

    private enum TypeScript {
        case notTypeScript
        case compiled(String)
        case failed(String)
    }

    private func typeScriptSource(id: String, source: String) -> TypeScript {
        guard [".ts", ".tsx", ".mts", ".cts"].contains(where: { id.hasSuffix($0) }) else {
            return .notTypeScript
        }
        guard let helper = context.objectForKeyedSubscript("__transpileTypeScript"),
              let result = helper.call(withArguments: [source, id]) else {
            return .failed("Cannot compile '\(id)': the TypeScript bridge is missing")
        }
        if let problem = result.forProperty("error"), !problem.isUndefined, !problem.isNull {
            return .failed(problem.toString())
        }
        return .compiled(result.forProperty("text")?.toString() ?? source)
    }

    private func isESModule(id: String, source: String) -> Bool {
        if id.hasSuffix(".mjs") { return true }
        if id.hasSuffix(".cjs") { return false }
        if packageType(forDir: virtualDirname(id)) == "module" { return true }
        return source.range(of: #"(?m)^\s*(import\s+[\w{*'"]|import\s*\(|export\s+(default|const|let|var|function|class|\{|\*))"#,
                            options: .regularExpression) != nil
            && source.range(of: #"(?m)^\s*(module\.exports|exports\.)"#, options: .regularExpression) == nil
    }

    private func packageType(forDir dir: String) -> String {
        if let cached = packageTypeCache[dir] { return cached }
        var current = dir
        while true {
            if let data = try? Data(contentsOf: realURL(current + "/package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let type = json["type"] as? String ?? "commonjs"
                packageTypeCache[dir] = type
                return type
            }
            if current == "/" || current.isEmpty { break }
            current = virtualDirname(current)
        }
        packageTypeCache[dir] = "commonjs"
        return "commonjs"
    }

    /// ESM → CJS, statement-shaped: the rigid grammar of import/export declarations makes a
    /// regex transform reliable for real packages; expressions stay untouched. Named exports
    /// are assigned at EOF (function/class hoist; const/let are bound by then).
    /// Bumped whenever `transpileESM` changes: the cache is content-addressed by SOURCE, so
    /// without this a stale rewrite would be reused after an engine update.
    private static let transpilerVersion = 7

    /// Transpiling a big bundle is the dominant cost of launching a bundled CLI —
    /// claude-code's 9.3 MB takes ~1.85 s of the ~2.4 s load, every launch. The result is a
    /// pure function of the source, so it caches content-addressed (SHA-256) in the app's
    /// CACHES directory — deliberately NOT in the workspace, which is a git repo the user
    /// sees: cache files there would show up in `git status`. Small modules are transpiled
    /// directly; the file dance costs more than the rewrite below this size.
    private static let transpileCacheThreshold = 64 * 1024

    private static let transpileCacheDirectory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("MouseNodeTranspile", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private func transpileCached(_ source: String) -> String {
        guard source.utf8.count >= Self.transpileCacheThreshold,
              let directory = Self.transpileCacheDirectory else {
            return Self.transpileESM(source)
        }
        let digest = SHA256.hash(data: Data(source.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + "-v\(Self.transpilerVersion).cjs"
        let file = directory.appendingPathComponent(name)
        if let cached = try? String(contentsOf: file, encoding: .utf8) { return cached }
        let transpiled = Self.transpileESM(source)
        try? transpiled.write(to: file, atomically: true, encoding: .utf8)
        return transpiled
    }

    /// `import(spec)` → `__dynamicImport(__mouseRequire, spec)`. Applied to ESM (as part of
    /// the transpile) AND to CJS that contains it — dynamic import is legal in both, and
    /// JSC's native import has no module loader wired to our resolver.
    /// The two textual rewrites that must not touch STRINGS: `import.meta` and dynamic
    /// `import(`. A real bundle carries JavaScript inside string literals — vite ships the
    /// browser's own `import.meta.hot` and `import(…)` as template strings it serves to the
    /// client — so a blind replace edits code that was never ours, and it also leaves the
    /// genuine `import.meta` occurrences untouched in the forms nobody enumerated
    /// (`.filename`, `.dirname`, `.require`, or bare), where JSC refuses to parse the script
    /// at all: "import.meta is only valid inside modules".
    ///
    /// This is a scanner, not a parser. It tracks single- and double-quoted strings, template
    /// literals with `${}` nesting, both comment forms, and regex literals — the last of which
    /// is why a scanner is needed rather than a smarter regex: `/["']/` is a legal regex whose
    /// quote would otherwise open a string that never closes.
    /// In `mask` mode the same scan emits a copy in which every string, template chunk,
    /// comment and regex body has been blanked to spaces (newlines and non-ASCII bytes kept, so
    /// offsets and line structure survive exactly). Matching a statement pattern against THAT
    /// and slicing the original at the same offsets is what keeps `export default function …`
    /// inside one of vite's generated worker strings from being rewritten as if it were code.
    static func rewriteImportForms(_ source: String, meta: Bool, mask: Bool = false) -> (text: String, usedMeta: Bool) {
        if !mask, !source.contains("import") { return (source, false) }
        let bytes = Array(source.utf8)
        let count = bytes.count
        var out = [UInt8]()
        out.reserveCapacity(count + 64)
        var usedMeta = false
        var index = 0

        // Template state: a frame per `…` we are inside ('t') and per `${` inside one ('s').
        var frames: [(kind: UInt8, depth: Int)] = []
        var depth = 0
        var inTemplate = false
        // The last significant byte of code, and the last identifier, decide whether a '/'
        // opens a regex or divides — the one genuinely ambiguous character in the language.
        var lastCode: UInt8 = 0
        var lastWord = ""
        let regexKeywords: Set<String> = ["return", "typeof", "instanceof", "in", "of", "new",
                                          "delete", "void", "throw", "do", "else", "case",
                                          "yield", "await"]

        func isIdent(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x5f || byte == 0x24 || byte >= 0x80
        }
        func regexCanStart() -> Bool {
            if lastCode == 0 { return true }
            if isIdent(lastCode) { return regexKeywords.contains(lastWord) }
            return !(lastCode == 0x29 || lastCode == 0x5d)      // not after ')' or ']'
        }
        func emit(_ byte: UInt8) {
            out.append(byte)
            if byte > 0x20 { lastCode = byte }
        }
        /// A byte inside a string, comment or regex: kept as itself, or blanked in mask mode.
        func copy(_ byte: UInt8) {
            out.append(mask && byte != 0x0a && byte < 0x80 ? 0x20 : byte)
        }

        while index < count {
            let byte = bytes[index]

            if inTemplate {
                if byte == 0x5c {                                   // \ escape
                    copy(byte); index += 1
                    if index < count { copy(bytes[index]); index += 1 }
                    continue
                }
                if byte == 0x60 {                                   // ` closes the template
                    copy(byte); index += 1
                    if let frame = frames.popLast() { depth = frame.depth }
                    inTemplate = false
                    lastCode = 0x60; lastWord = ""
                    continue
                }
                if byte == 0x24, index + 1 < count, bytes[index + 1] == 0x7b {   // ${
                    out.append(byte); out.append(bytes[index + 1]); index += 2
                    frames.append((0x73, depth))
                    depth = 0
                    inTemplate = false
                    lastCode = 0x7b; lastWord = ""
                    continue
                }
                copy(byte); index += 1
                continue
            }

            if byte == 0x2f, index + 1 < count, bytes[index + 1] == 0x2f {       // //
                while index < count, bytes[index] != 0x0a { copy(bytes[index]); index += 1 }
                continue
            }
            if byte == 0x2f, index + 1 < count, bytes[index + 1] == 0x2a {       // /* */
                copy(byte); copy(bytes[index + 1]); index += 2
                while index < count {
                    if bytes[index] == 0x2a, index + 1 < count, bytes[index + 1] == 0x2f {
                        copy(bytes[index]); copy(bytes[index + 1]); index += 2
                        break
                    }
                    copy(bytes[index]); index += 1
                }
                continue
            }
            if byte == 0x22 || byte == 0x27 {                                   // " '
                // Kept verbatim even in mask mode: a quoted string cannot contain a real
                // newline, so a line-anchored pattern can never match inside one — and the
                // module specifier the import patterns have to READ is exactly here.
                out.append(byte); index += 1
                while index < count {
                    let inner = bytes[index]
                    out.append(inner); index += 1
                    if inner == 0x5c {
                        if index < count { out.append(bytes[index]); index += 1 }
                        continue
                    }
                    if inner == byte || inner == 0x0a { break }     // a newline ends a broken string
                }
                lastCode = 0x22; lastWord = ""
                continue
            }
            if byte == 0x60 {                                                   // ` opens
                copy(byte); index += 1
                frames.append((0x74, depth))
                depth = 0
                inTemplate = true
                continue
            }
            if byte == 0x2f, regexCanStart() {                                  // regex literal
                copy(byte); index += 1
                var inClass = false
                while index < count {
                    let inner = bytes[index]
                    copy(inner); index += 1
                    if inner == 0x5c {
                        if index < count { copy(bytes[index]); index += 1 }
                        continue
                    }
                    if inner == 0x5b { inClass = true; continue }
                    if inner == 0x5d { inClass = false; continue }
                    if inner == 0x0a { break }                      // not a regex after all
                    if inner == 0x2f && !inClass { break }
                }
                while index < count, isIdent(bytes[index]) { copy(bytes[index]); index += 1 }
                lastCode = 0x2f; lastWord = ""
                continue
            }
            if byte == 0x7b { depth += 1; emit(byte); index += 1; lastWord = ""; continue }
            if byte == 0x7d {
                if depth == 0, let frame = frames.last, frame.kind == 0x73 {     // closes ${…}
                    frames.removeLast()
                    depth = frame.depth
                    inTemplate = true
                    out.append(byte); index += 1
                    continue
                }
                depth -= 1
                emit(byte); index += 1; lastWord = ""
                continue
            }

            // An identifier — the only place `import` can start.
            if isIdent(byte) {
                var end = index
                while end < count, isIdent(bytes[end]) { end += 1 }
                let word = String(decoding: bytes[index..<end], as: UTF8.self)
                let precededByDot = lastCode == 0x2e
                if word == "import", !precededByDot, !mask {
                    var probe = end
                    while probe < count, bytes[probe] == 0x20 || bytes[probe] == 0x09
                            || bytes[probe] == 0x0a || bytes[probe] == 0x0d { probe += 1 }
                    if meta, probe < count, bytes[probe] == 0x2e {
                        var afterDot = probe + 1
                        while afterDot < count, bytes[afterDot] == 0x20 || bytes[afterDot] == 0x09 { afterDot += 1 }
                        var metaEnd = afterDot
                        while metaEnd < count, isIdent(bytes[metaEnd]) { metaEnd += 1 }
                        if String(decoding: bytes[afterDot..<metaEnd], as: UTF8.self) == "meta" {
                            out.append(contentsOf: Array("__mouseImportMeta".utf8))
                            usedMeta = true
                            index = metaEnd
                            lastCode = 0x61; lastWord = "__mouseImportMeta"
                            continue
                        }
                    }
                    if probe < count, bytes[probe] == 0x28 {                    // import(
                        out.append(contentsOf: Array("__dynamicImport(__mouseRequire, ".utf8))
                        index = probe + 1
                        depth += 0
                        lastCode = 0x28; lastWord = ""
                        continue
                    }
                }
                out.append(contentsOf: bytes[index..<end])
                lastCode = bytes[end - 1]
                lastWord = word
                index = end
                continue
            }

            emit(byte)
            index += 1
        }
        return (String(decoding: out, as: UTF8.self), usedMeta)
    }

    /// Dynamic `import()` in a CommonJS file — legal, and prettier lazy-loads plugins with it.
    static func rewriteDynamicImport(_ source: String) -> String {
        return rewriteImportForms(source, meta: false).text
    }

    static func transpileESM(_ source: String) -> String {
        var text = source
        // Emitted BEFORE the body: function declarations are hoisted, so a cycle reaching back
        // into this module finds them, and every export reads through a getter rather than
        // being frozen at end-of-module.
        var prologue: [String] = []
        var epilogue: [String] = []
        var counter = 0
        var maskCache: String?

        // The leading whitespace in every statement pattern is `[ \t]*`, not `\s*`: a `\s*`
        // reaching back across the newline made the replacement land on the PREVIOUS line, so
        // `const y = () => {}` followed by `export default y` became `}module.exports.default`,
        // which is a syntax error rather than the ASI the source relied on.
        // One pass per pattern: collect every match against the current text, then rebuild
        // the string ONCE. The old firstMatch+replacingCharacters loop recopied and
        // rescanned the whole source per match — O(n²), ~40 s on a 9 MB bundle. Matches are
        // statement-anchored and non-overlapping, and replacements never introduce new
        // import/export syntax, so a single pass is equivalent.
        // Every statement pattern is matched against a MASK of the current text — the same
        // bytes with strings, comments and regexes blanked — and then applied to the text at
        // those offsets. A bundle emits JavaScript as data: vite's worker shim is the literal
        // line `export default function WorkerWrapper(options) {` inside a template string, and
        // rewriting it both corrupted the code vite serves and left the epilogue assigning a
        // binding that does not exist. The mask is recomputed per pass because each pass
        // changes the text; scanning is linear and this is cached by content anyway.
        func replace(_ pattern: String, _ transform: (NSTextCheckingResult, NSString) -> String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let ns = text as NSString
            // Match the text itself first — most patterns miss entirely, and the mask is only
            // worth building when there is something to judge. A match is code when its OPENING
            // survives masking; testing the opening rather than the whole match keeps an import
            // with a comment inside its braces, which the mask blanks in the middle.
            let found = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !found.isEmpty else { return }
            if maskCache == nil { maskCache = rewriteImportForms(text, meta: false, mask: true).text }
            guard let maskText = maskCache, (maskText as NSString).length == ns.length else { return }
            let mask = maskText as NSString
            let matches = found.filter { match in
                // From the first non-space character, because a match anchored at `^` starts on
                // the INDENTATION — which is spaces in the source and spaces in the mask alike,
                // so comparing from the match start called every masked line code.
                var start = match.range.location
                let end = match.range.location + match.range.length
                while start < end, ns.character(at: start) == 0x20 || ns.character(at: start) == 0x09
                        || ns.character(at: start) == 0x0a || ns.character(at: start) == 0x0d { start += 1 }
                guard start < end else { return false }
                let head = NSRange(location: start, length: min(8, end - start))
                return mask.substring(with: head) == ns.substring(with: head)
            }
            guard !matches.isEmpty else { return }
            var result = ""
            result.reserveCapacity(ns.length)
            var cursor = 0
            for match in matches {
                let range = match.range
                if range.location > cursor {
                    result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
                }
                // A multi-line import becomes one line, and everything below it would move up
                // by the lines it swallowed — so the replacement carries them, at the end where
                // they change nothing but the count.
                let consumed = ns.substring(with: range)
                let newlines = consumed.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                result += transform(match, ns)
                if newlines > 0 { result += String(repeating: "\n", count: newlines) }
                cursor = range.location + range.length
            }
            if cursor < ns.length {
                result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            }
            text = result
            maskCache = nil                                          // the text moved under it
        }
        func group(_ match: NSTextCheckingResult, _ index: Int, _ ns: NSString) -> String? {
            guard index < match.numberOfRanges, match.range(at: index).location != NSNotFound else { return nil }
            return ns.substring(with: match.range(at: index))
        }
        func isIdentifier(_ text: String) -> Bool {
            guard let first = text.first, first.isLetter || first == "_" || first == "$" else { return false }
            return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
        }
        /// `a, b as c, // comment` → [(a, a), (b, c)] — comments stripped, whitespace-split,
        /// junk skipped.
        func bindings(_ clause: String) -> [(source: String, alias: String)] {
            var text = clause
            text = text.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            var result: [(String, String)] = []
            for piece in text.split(separator: ",") {
                let words = piece.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0 != "as" }
                guard let source = words.first, isIdentifier(source) else { continue }
                let alias = words.count > 1 ? words[1] : source
                guard isIdentifier(alias) else { continue }
                result.append((source, alias))
            }
            return result
        }
        func namedBindings(_ clause: String) -> String {
            bindings(clause).map { $0.source == $0.alias ? $0.source : "\($0.source): \($0.alias)" }
                .joined(separator: ", ")
        }

        // Every import site awaits ONLY a genuinely-pending (top-level-await) dependency:
        // `if (x instanceof Promise) x = await x`. A fully-sync dependency evaluates without
        // suspension, so sync modules stay sync under the async wrapper; a TLA dependency
        // suspends its importers — the same infection real ESM has.
        func requireSettled(_ temp: String, _ module: String) -> String {
            "let \(temp) = __mouseRequire('\(module)'); if (\(temp) instanceof Promise) \(temp) = await \(temp);"
        }
        // import defaultName, { a, b as c } from 'mod'  (all combinations) / import * as ns —
        // minified bundles drop every optional space (`import{x as y}from"m"`).
        replace(#"(?:^|(?<=[;}]))[ \t]*import\s*(?:([\w$]+)\s*,\s*)?(?:\{([^}]*)\}|\*\s*as\s+([\w$]+)|([\w$]+))\s*from\s*['"]([^'"]+)['"](?:\s*(?:with|assert)\s*\{[^}]*\})?\s*;?"#) { match, ns in
            counter += 1
            let temp = "__esm\(counter)"
            var lines = [requireSettled(temp, group(match, 5, ns)!)]
            if let defaultName = group(match, 1, ns) ?? group(match, 4, ns) {
                lines.append("const \(defaultName) = __esmDefault(\(temp));")
            }
            if let named = group(match, 2, ns) {
                // Read through __esmBinding, not destructured outright. In a CYCLE the exporting
                // module is still evaluating and its `const` is in TDZ — real ESM never reads it
                // there, because a binding is read where it is USED, and by then the cycle has
                // closed. Destructuring reads it at import time and turns a legal cycle into a
                // ReferenceError, which is what execa's send.js ↔ strict.js pair hit.
                for binding in bindings(named) {
                    lines.append("const \(binding.alias) = __esmBinding(\(temp), '\(binding.source)');")
                }
            }
            if let namespace = group(match, 3, ns) {
                lines.append("const \(namespace) = \(temp);")
            }
            return lines.joined(separator: " ")
        }
        // import 'mod'
        replace(#"(?:^|(?<=[;}]))[ \t]*import\s*['"]([^'"]+)['"](?:\s*(?:with|assert)\s*\{[^}]*\})?\s*;?"#) { match, ns in
            counter += 1
            return requireSettled("__esm\(counter)", group(match, 1, ns)!)
        }
        // export * as name from 'mod'   (ansi-escapes@7 re-exports its base this way —
        // must run before the bare `export * from` rule, whose pattern is a prefix of this)
        replace(#"(?:^|(?<=[;}]))[ \t]*export\s*\*\s*as\s+([\w$]+)\s+from\s*['"]([^'"]+)['"]\s*;?"#) { match, ns in
            counter += 1
            let temp = "__esm\(counter)"
            return requireSettled(temp, group(match, 2, ns)!) + " module.exports.\(group(match, 1, ns)!) = \(temp);"
        }
        // export * from 'mod'  /  export { a, b as c } from 'mod'
        // Star re-export excludes `default` and `__esModule` (spec semantics — yoga-layout's
        // `export * from './YGEnums.js'` must not clobber its own default export).
        replace(#"(?:^|(?<=[;}]))[ \t]*export\s*\*\s*from\s*['"]([^'"]+)['"]\s*;?"#) { match, ns in
            counter += 1
            let temp = "__esm\(counter)"
            return requireSettled(temp, group(match, 1, ns)!) + " __reexportStar(module.exports, \(temp));"
        }
        replace(#"(?:^|(?<=[;}]))[ \t]*export\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"](?:\s*(?:with|assert)\s*\{[^}]*\})?\s*;?"#) { match, ns in
            counter += 1
            let temp = "__esm\(counter)"
            var lines = [requireSettled(temp, group(match, 2, ns)!)]
            for binding in bindings(group(match, 1, ns)!) {
                lines.append("__mouseLive(module.exports, '\(binding.alias)', function(){ return \(temp).\(binding.source); });")
            }
            return lines.joined(separator: " ")
        }
        // export { X as 'module.exports' } — the ES2022 string-named-export idiom that dual
        // CJS/ESM packages (yargs, cliui, y18n) use to make `require()` return X directly.
        // Must run BEFORE the general clause rule, whose `[^}]*` would swallow it and then
        // drop the string alias. A general string-named export lands on module.exports[name].
        replace(#"(?:^|(?<=[;}]))[ \t]*export\s*\{\s*([\w$]+)\s+as\s+['"]module\.exports['"]\s*\}\s*;?"#) { match, ns in
            "module.exports = \(group(match, 1, ns)!);"
        }
        replace(#"(?:^|(?<=[;}]))[ \t]*export\s*\{\s*([\w$]+)\s+as\s+['"]([^'"]+)['"]\s*\}\s*;?"#) { match, ns in
            let name = group(match, 2, ns)!.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            return "__mouseLive(module.exports, '\(name)', function(){ return \(group(match, 1, ns)!); });"
        }
        // export { a, b as c };   — a trailing line comment must not defeat the match
        // (commander@15 ends one with "; // Deprecated").
        replace(#"(?:^|(?<=[;}]))[ \t]*export\s*\{([^}]*)\}\s*;?\s*(//[^\n]*)?$"#) { match, ns in
            bindings(group(match, 1, ns)!)
                .map { "__mouseLive(module.exports, '\($0.alias)', function(){ return \($0.source); });" }
                .joined(separator: " ")
        }
        // export default function name() / class Name — keep the declaration, alias at EOF.
        // Mid-line anchor: a preceding rule can leave `;export default` on one line when an
        // unterminated import (no semicolon, cliui) had its trailing newline consumed.
        replace(#"(?:^|(?<=[;}]))[ \t]*export\s+default\s+(function\s*\*?\s+([\w$]+)|class\s+([\w$]+))"#) { match, ns in
            let name = group(match, 2, ns) ?? group(match, 3, ns)!
            prologue.append("__mouseLive(module.exports, 'default', function(){ return \(name); });")
            return group(match, 1, ns)!
        }
        // export default <expression>
        replace(#"(?:^|(?<=[;}]))[ \t]*export\s+default\s+"#) { _, _ in "module.exports.default = " }
        // export const/let/var/function/class NAME — strip keyword, assign at EOF.
        /// The names a destructuring pattern BINDS, which is not the same as the identifiers in
        /// it: `{ a, b: c, d = 1, ...rest }` binds a, c, d and rest, and `b` is a key. Balanced
        /// scanning, because a regex cannot find the end of a pattern that nests.
        func destructuredNames(_ ns: NSString, _ start: Int, _ masked: NSString) -> (names: [String], end: Int) {
            var names: [String] = []
            var depth = 0
            var index = start
            var expectBinding = true            // at the start of an element, before any ':'
            var inArray: [Bool] = []
            while index < masked.length {
                let ch = Character(UnicodeScalar(masked.character(at: index))!)
                if ch == "{" || ch == "[" {
                    depth += 1
                    inArray.append(ch == "[")
                    expectBinding = true
                    index += 1
                    continue
                }
                if ch == "}" || ch == "]" {
                    depth -= 1
                    if !inArray.isEmpty { inArray.removeLast() }
                    index += 1
                    if depth == 0 { return (names, index) }
                    continue
                }
                if ch == "," { expectBinding = true; index += 1; continue }
                if ch == ":" { expectBinding = true; index += 1; continue }
                if ch == "=" {
                    // A default value: skip to the next comma or closing brace at this depth.
                    expectBinding = false
                    index += 1
                    continue
                }
                if ch.isLetter || ch == "_" || ch == "$" {
                    var end = index
                    while end < masked.length {
                        let next = Character(UnicodeScalar(masked.character(at: end))!)
                        guard next.isLetter || next.isNumber || next == "_" || next == "$" else { break }
                        end += 1
                    }
                    let word = ns.substring(with: NSRange(location: index, length: end - index))
                    // In an object pattern `a:` is a KEY, so only take it when nothing follows
                    // that makes it one; in an array pattern every identifier is a binding.
                    var lookahead = end
                    while lookahead < masked.length, masked.character(at: lookahead) == 0x20 { lookahead += 1 }
                    let followedByColon = lookahead < masked.length && masked.character(at: lookahead) == 0x3a
                    if expectBinding, !followedByColon { names.append(word) }
                    if followedByColon { expectBinding = true }
                    index = end
                    continue
                }
                index += 1
            }
            return (names, index)
        }

        // export const { a, b: c } = … / export const [x] = … — a destructuring declaration,
        // which signal-exit (under execa) uses, and which the NAME form below cannot match.
        replace(#"(?:^|(?<=[;}]))[ \t]*export\s+(const|let|var)\s*(?=[{\[])"#) { match, ns in
            let keyword = group(match, 1, ns)!
            let start = match.range.location + match.range.length
            let masked = (maskCache ?? (ns as String)) as NSString
            if masked.length == ns.length {
                let found = destructuredNames(ns, start, masked)
                for name in found.names {
                    prologue.append("__mouseLive(module.exports, '\(name)', function(){ return \(name); });")
                }
            }
            return keyword + " "
        }

        // The `*` is its own group because a generator is declared `function* name` — and
        // `export async function* _iterSSEMessages` is how the Anthropic SDK streams. Without
        // it the declaration kept its `export` keyword and the file would not parse.
        replace(#"(?:^|(?<=[;}]))[ \t]*export\s+(const|let|var|class|function|async\s+function)(\s*\*)?\s+([\w$]+)"#) { match, ns in
            let name = group(match, 3, ns)!
            prologue.append("__mouseLive(module.exports, '\(name)', function(){ return \(name); });")
            return "\(group(match, 1, ns)!)\(group(match, 2, ns) ?? "") \(name)"
        }
        // dynamic import() and import.meta, both code-only — see rewriteImportForms.
        let scanned = rewriteImportForms(text, meta: true)
        text = scanned.text
        // The whole of node's import.meta as one object, declared only where it is used.
        // __mouseFilename, not __filename: ESM files legitimately declare
        // `const __filename = fileURLToPath(import.meta.url)`, and substituting the param
        // name would make that line a TDZ self-reference (prettier's bundle).
        if scanned.usedMeta {
            text = "const __mouseImportMeta = { url: 'file://' + __mouseFilename, "
                 + "filename: __mouseFilename, "
                 + "dirname: __mouseFilename.replace(/[/][^/]*$/, '') || '/', "
                 + "resolve: __mouseRequire.resolve };\n" + text
        }

        // The body runs under an ASYNC wrapper (imports may await). The try/catch makes the
        // sync outcome inspectable the moment the wrapper call returns: __esmDone means the
        // whole body ran without suspending (the common case — requirers get exports
        // synchronously, as before); __esmError preserves throw-in-requiring-frame
        // semantics; neither means genuine top-level await in flight.
        // Non-enumerable: node's module namespace has no __esModule at all, so a plain
        // assignment put a phantom key into `Object.keys(ns)`, into a spread of it, and into
        // anything that walks a module's exports. Defined this way the interop check still
        // sees it and nothing that ENUMERATES does.
        // Everything before the body goes on ONE line and everything after it on the last, for
        // the same reason the wrapper does: a module's line 5 has to still be line 5. The
        // prologue was four lines of live-export getters, so an ESM stack pointed four lines
        // past the throw.
        return "Object.defineProperty(module.exports, '__esModule', { value: true }); try { "
            + prologue.joined(separator: " ") + " " + text + "\n;" + epilogue.joined(separator: " ")
            + " ;module.__esmDone = true; } catch (__esmThrown) { module.__esmError = __esmThrown; throw __esmThrown; }"
    }

    private func throwInJS(_ message: String) -> Any {
        return ["__mouseRequireError": message]
    }

    private func jsString(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    // MARK: - Bootstrap (the JavaScript half of the runtime)

    private static let bootstrap = #"""
    (function(){
      'use strict';
      const bridge = __mouse;
      globalThis.global = globalThis;

      // ---- Buffer (Uint8Array + encodings) ----
      function utf8Encode(str) {
        const bytes = [];
        for (let i = 0; i < str.length; i++) {
          let c = str.codePointAt(i);
          if (c > 0xffff) i++;
          if (c < 0x80) bytes.push(c);
          else if (c < 0x800) bytes.push(0xc0 | (c >> 6), 0x80 | (c & 63));
          else if (c < 0x10000) bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
          else bytes.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
        return bytes;
      }
      // LENIENT, like node's utf8 decoder: invalid bytes become U+FFFD instead of throwing.
      // (The strict version called String.fromCodePoint on unvalidated values, so decoding
      // BINARY data as utf8 — `buf.toString()` on a gzip block, which tar does — threw
      // "out of range of code points" instead of returning replacement characters.)
      function utf8Decode(bytes) {
        let out = '';
        for (let i = 0; i < bytes.length;) {
          const b = bytes[i];
          let c, extra;
          if (b < 0x80) { out += String.fromCharCode(b); i++; continue; }
          if (b < 0xc2 || b > 0xf4) { out += '�'; i++; continue; }   // stray/overlong/too-big lead
          if (b >= 0xf0) { c = b & 7; extra = 3; }
          else if (b >= 0xe0) { c = b & 15; extra = 2; }
          else { c = b & 31; extra = 1; }
          i++;
          let valid = true;
          for (let k = 0; k < extra; k++) {
            if (i >= bytes.length || (bytes[i] & 0xc0) !== 0x80) { valid = false; break; }
            c = (c << 6) | (bytes[i++] & 63);
          }
          if (!valid || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) { out += '�'; continue; }
          out += String.fromCodePoint(c);
        }
        return out;
      }
      const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      function b64Encode(bytes) {
        let out = '';
        for (let i = 0; i < bytes.length; i += 3) {
          const a = bytes[i], b = bytes[i+1], c = bytes[i+2];
          out += B64[a >> 2] + B64[((a & 3) << 4) | (b === undefined ? 0 : b >> 4)];
          out += b === undefined ? '=' : B64[((b & 15) << 2) | (c === undefined ? 0 : c >> 6)];
          out += c === undefined ? '=' : B64[c & 63];
        }
        return out;
      }
      function b64Decode(str) {
        // node's base64 decoder accepts the base64URL alphabet too, and real code relies on
        // that: `jwa` hands a base64url signature straight to Buffer.from(s, 'base64'). We
        // STRIPPED `-` and `_` instead of translating them, so those bytes vanished and a DER
        // signature arrived two bytes short — which surfaced as ecdsa-sig-formatter reporting
        // a bad sequence length, nowhere near the actual bug.
        str = String(str).replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/=]/g, '');
        const bytes = [];
        for (let i = 0; i < str.length; i += 4) {
          const n = (B64.indexOf(str[i]) << 18) | (B64.indexOf(str[i+1]) << 12) |
                    ((B64.indexOf(str[i+2]) & 63) << 6) | (B64.indexOf(str[i+3]) & 63);
          bytes.push((n >> 16) & 255);
          if (str[i+2] !== undefined && str[i+2] !== '=') bytes.push((n >> 8) & 255);
          if (str[i+3] !== undefined && str[i+3] !== '=') bytes.push(n & 255);
        }
        return bytes;
      }

      class Buffer extends Uint8Array {
        static from(value, encoding, length) {
          if (typeof value === 'string') {
            const named = encoding === undefined || encoding === null ? undefined
                                                                     : String(encoding).toLowerCase();
            if (named === 'base64') return new Buffer(b64Decode(value));
            // base64url was not supported AT ALL: the string was read as UTF-8, so
            // Buffer.from(token, 'base64url') silently produced the token's own bytes. JWTs are
            // made of base64url, which is how quietly wrong this could get.
            if (named === 'base64url') {
              return new Buffer(b64Decode(String(value).replace(/-/g, '+').replace(/_/g, '/')));
            }
            // utf16le/ucs2 were ignored too, so a UTF-16 encode produced UTF-8 bytes.
            if (named === 'utf16le' || named === 'utf-16le' || named === 'ucs2' || named === 'ucs-2') {
              const text = String(value);
              const bytes = new Uint8Array(text.length * 2);
              for (let i = 0; i < text.length; i++) {
                const unit = text.charCodeAt(i);
                bytes[i * 2] = unit & 0xff;
                bytes[i * 2 + 1] = (unit >> 8) & 0xff;
              }
              return new Buffer(bytes);
            }
            // node's `ascii` is ASYMMETRIC, which is easy to get wrong in the tidy direction:
            // ENCODING masks to 0xff (so it behaves like latin1 — 'é' becomes 0xe9), while
            // DECODING masks to 0x7f. Verified against node rather than assumed symmetric.
            if (named === 'ascii') {
              const text = String(value);
              const bytes = new Uint8Array(text.length);
              for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
              return new Buffer(bytes);
            }
            if (named === 'hex') {
              // node stops at the first thing that is not a full byte: 'abc' is one byte, not
              // one and a half, and a stray character ends the decode rather than becoming NaN.
              const bytes = [];
              for (let i = 0; i + 1 < value.length + 1; i += 2) {
                if (i + 1 >= value.length) break;
                const pair = value.substr(i, 2);
                if (!/^[0-9a-fA-F]{2}$/.test(pair)) break;
                bytes.push(parseInt(pair, 16));
              }
              return new Buffer(bytes);
            }
            if (named === 'latin1' || named === 'binary') {
              const bytes = new Uint8Array(value.length);
              for (let i = 0; i < value.length; i++) bytes[i] = value.charCodeAt(i) & 0xff;
              return new Buffer(bytes);
            }
            return new Buffer(utf8Encode(value));
          }
          // `Buffer.from(arrayBuffer[, byteOffset[, length]])` SHARES the memory — node
          // documents it as a view without copying, and wasm interop depends on exactly that:
          // webpack's hashes write into `WebAssembly.Memory.buffer` through such a Buffer and
          // read the result back out. Copying here made every wasm hash return the INPUT
          // padded with NULs, because the wasm function operated on memory nobody was reading.
          if (value instanceof ArrayBuffer ||
              (typeof SharedArrayBuffer !== 'undefined' && value instanceof SharedArrayBuffer)) {
            const offset = encoding === undefined ? 0 : Number(encoding) || 0;
            const count = length === undefined ? value.byteLength - offset : Number(length);
            return new Buffer(value, offset, count);
          }
          // NOT a byte-copy for other typed arrays: node copies their VALUES, each truncated
          // to a byte, so a Uint16Array of [0x0102, 0x0304] becomes two bytes [2, 4] rather
          // than four. Uint8Array's own constructor already does exactly that, so the default
          // path below is the correct one — measured against node, which corrected a guess.
          return new Buffer(value);
        }
        static alloc(size, fill, encoding) {
          const buffer = new Buffer(size);
          if (fill === undefined) return buffer;
          // A string fill is a PATTERN that repeats — `Buffer.alloc(6, 'ab')` is 'ababab', not
          // 'aaaaaa'. Taking only its first character quietly produced the wrong bytes, which is
          // the kind of wrong that shows up as corrupt output somewhere else entirely.
          if (typeof fill === 'string') {
            const pattern = Buffer.from(fill, encoding || 'utf8');
            if (!pattern.length) return buffer;
            for (let index = 0; index < size; index += 1) buffer[index] = pattern[index % pattern.length];
            return buffer;
          }
          if (Buffer.isBuffer(fill) || ArrayBuffer.isView(fill)) {
            const pattern = Buffer.isBuffer(fill) ? fill : Buffer.from(fill.buffer, fill.byteOffset, fill.byteLength);
            if (!pattern.length) return buffer;
            for (let index = 0; index < size; index += 1) buffer[index] = pattern[index % pattern.length];
            return buffer;
          }
          buffer.fill(fill);
          return buffer;
        }
        static allocUnsafe(size) { return new Buffer(size); }
        /// node's fill: a RANGE, and a string or buffer value repeats across it.
        fill(value, start, end, encoding) {
          if (typeof start === 'string') { encoding = start; start = 0; end = this.length; }
          else if (typeof end === 'string') { encoding = end; end = this.length; }
          start = start === undefined ? 0 : start | 0;
          end = end === undefined ? this.length : Math.min(this.length, end | 0);
          let pattern;
          if (typeof value === 'string') pattern = Buffer.from(value, encoding || 'utf8');
          else if (Buffer.isBuffer(value)) pattern = value;
          else if (ArrayBuffer.isView(value)) pattern = Buffer.from(value.buffer, value.byteOffset, value.byteLength);
          else { for (let index = start; index < end; index += 1) this[index] = Number(value) & 0xff; return this; }
          if (!pattern.length) return this;
          for (let index = start; index < end; index += 1) this[index] = pattern[(index - start) % pattern.length];
          return this;
        }
        static isBuffer(value) { return value instanceof Buffer; }
        static byteLength(value, encoding) {
          // The COST of encoding this string that way — not its utf8 length. A caller sizing a
          // buffer for base64 or utf16le with the utf8 answer allocates the wrong thing.
          if (typeof value !== 'string') return value.length;
          return Buffer.from(value, encoding || 'utf8').length;
        }
        static concat(list, total) {
          const length = total !== undefined ? total : list.reduce((n, b) => n + b.length, 0);
          const result = new Buffer(length);
          let offset = 0;
          for (const buffer of list) { result.set(buffer.subarray(0, Math.min(buffer.length, length - offset)), offset); offset += buffer.length; }
          return result;
        }
        // toString(encoding, start, end) — the RANGE form matters: tar's header parser reads
        // fixed-width fields out of a block with it.
        toString(encoding, start, end) {
          const from = start === undefined ? 0 : Math.max(0, start | 0);
          const to = end === undefined ? this.length : Math.min(this.length, end | 0);
          const bytes = Array.prototype.slice.call(this, from, to);
          const named = encoding === undefined || encoding === null ? undefined
                                                                   : String(encoding).toLowerCase();
          if (named === 'base64') return b64Encode(bytes);
          // base64url: -_ instead of +/, and no padding.
          if (named === 'base64url') {
            return b64Encode(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
          }
          if (named === 'utf16le' || named === 'utf-16le' || named === 'ucs2' || named === 'ucs-2') {
            let out = '';
            for (let i = 0; i + 1 < bytes.length; i += 2) {
              out += String.fromCharCode(bytes[i] | (bytes[i + 1] << 8));
            }
            return out;
          }
          if (named === 'ascii') {
            let out = '';
            for (const byte of bytes) out += String.fromCharCode(byte & 0x7f);
            return out;
          }
          if (named === 'hex') return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
          if (named === 'latin1' || named === 'binary') {
            let out = '';
            for (let i = 0; i < bytes.length; i += 8192) out += String.fromCharCode.apply(null, bytes.slice(i, i + 8192));
            return out;
          }
          return utf8Decode(bytes);
        }
        /// write(string, offset, length, encoding) — the argument shuffle node allows.
        write(string, offset, length, encoding) {
          if (typeof offset === 'string') { encoding = offset; offset = 0; length = undefined; }
          else if (typeof length === 'string') { encoding = length; length = undefined; }
          offset = offset === undefined ? 0 : offset | 0;
          const source = Buffer.from(String(string), encoding || 'utf8');
          const count = Math.min(length === undefined ? source.length : length | 0,
                                 source.length, this.length - offset);
          for (let i = 0; i < count; i++) this[offset + i] = source[i];
          return count;
        }
        copy(target, targetStart, sourceStart, sourceEnd) {
          targetStart = targetStart === undefined ? 0 : targetStart | 0;
          sourceStart = sourceStart === undefined ? 0 : sourceStart | 0;
          sourceEnd = sourceEnd === undefined ? this.length : Math.min(this.length, sourceEnd | 0);
          const count = Math.min(sourceEnd - sourceStart, target.length - targetStart);
          for (let i = 0; i < count; i++) target[targetStart + i] = this[sourceStart + i];
          return Math.max(0, count);
        }
        _view() { return new DataView(this.buffer, this.byteOffset, this.byteLength); }
        readUInt8(o) { return this[o | 0]; }
        writeUInt8(v, o) { this[o | 0] = v & 0xff; return (o | 0) + 1; }
        readInt8(o) { return this._view().getInt8(o | 0); }
        writeInt8(v, o) { this._view().setInt8(o | 0, v); return (o | 0) + 1; }
        readUInt16BE(o) { return this._view().getUint16(o | 0, false); }
        readUInt16LE(o) { return this._view().getUint16(o | 0, true); }
        writeUInt16BE(v, o) { this._view().setUint16(o | 0, v, false); return (o | 0) + 2; }
        writeUInt16LE(v, o) { this._view().setUint16(o | 0, v, true); return (o | 0) + 2; }
        readInt16BE(o) { return this._view().getInt16(o | 0, false); }
        readInt16LE(o) { return this._view().getInt16(o | 0, true); }
        // The 16-bit signed WRITERS were missing while their readers were present — the same
        // read-without-write asymmetry as writeFloat, and the shape sweep caught both.
        writeInt16BE(v, o) { this._view().setInt16(o | 0, v, false); return (o | 0) + 2; }
        writeInt16LE(v, o) { this._view().setInt16(o | 0, v, true); return (o | 0) + 2; }
        readUInt32BE(o) { return this._view().getUint32(o | 0, false); }
        readUInt32LE(o) { return this._view().getUint32(o | 0, true); }
        writeUInt32BE(v, o) { this._view().setUint32(o | 0, v, false); return (o | 0) + 4; }
        writeUInt32LE(v, o) { this._view().setUint32(o | 0, v, true); return (o | 0) + 4; }
        readInt32BE(o) { return this._view().getInt32(o | 0, false); }
        readInt32LE(o) { return this._view().getInt32(o | 0, true); }
        writeInt32BE(v, o) { this._view().setInt32(o | 0, v, false); return (o | 0) + 4; }
        writeInt32LE(v, o) { this._view().setInt32(o | 0, v, true); return (o | 0) + 4; }
        readBigUInt64BE(o) { return this._view().getBigUint64(o | 0, false); }
        readBigUInt64LE(o) { return this._view().getBigUint64(o | 0, true); }
        writeBigUInt64BE(v, o) { this._view().setBigUint64(o | 0, BigInt(v), false); return (o | 0) + 8; }
        writeBigUInt64LE(v, o) { this._view().setBigUint64(o | 0, BigInt(v), true); return (o | 0) + 8; }
        readDoubleBE(o) { return this._view().getFloat64(o | 0, false); }
        readDoubleLE(o) { return this._view().getFloat64(o | 0, true); }
        writeDoubleBE(v, o) { this._view().setFloat64(o | 0, v, false); return (o | 0) + 8; }
        writeDoubleLE(v, o) { this._view().setFloat64(o | 0, v, true); return (o | 0) + 8; }
        readFloatBE(o) { return this._view().getFloat32(o | 0, false); }
        readFloatLE(o) { return this._view().getFloat32(o | 0, true); }
        // Everything below was missing and is documented Buffer API — found by a sweep over
        // instance SHAPES rather than exports, which is the only way a missing method on the most
        // used object in Node shows up before a program needs it. writeFloat is the one that
        // stings: readFloat was here, so binary formats could be read and not written.
        writeFloatBE(v, o) { this._view().setFloat32(o | 0, v, false); return (o | 0) + 4; }
        writeFloatLE(v, o) { this._view().setFloat32(o | 0, v, true); return (o | 0) + 4; }
        readBigInt64BE(o) { return this._view().getBigInt64(o | 0, false); }
        readBigInt64LE(o) { return this._view().getBigInt64(o | 0, true); }
        writeBigInt64BE(v, o) { this._view().setBigInt64(o | 0, BigInt(v), false); return (o | 0) + 8; }
        writeBigInt64LE(v, o) { this._view().setBigInt64(o | 0, BigInt(v), true); return (o | 0) + 8; }
        /// The variable-width readers: any byte count from 1 to 6, which is what a wire format
        /// with 3- or 5-byte integers needs. Above 6 bytes the value would exceed the exact
        /// integer range, which is why node caps it there too.
        readUIntBE(offset, byteLength) {
          const at = offset | 0, size = byteLength | 0;
          if (size < 1 || size > 6) throw new RangeError('byteLength must be >= 1 and <= 6');
          let value = 0;
          for (let i = 0; i < size; i++) value = value * 256 + this[at + i];
          return value;
        }
        readUIntLE(offset, byteLength) {
          const at = offset | 0, size = byteLength | 0;
          if (size < 1 || size > 6) throw new RangeError('byteLength must be >= 1 and <= 6');
          let value = 0;
          for (let i = size - 1; i >= 0; i--) value = value * 256 + this[at + i];
          return value;
        }
        readIntBE(offset, byteLength) {
          const size = byteLength | 0;
          const value = this.readUIntBE(offset, size);
          // Sign extension: the top bit of the FIRST byte is the sign, so subtract the full range.
          const limit = Math.pow(2, size * 8 - 1);
          return value >= limit ? value - limit * 2 : value;
        }
        readIntLE(offset, byteLength) {
          const size = byteLength | 0;
          const value = this.readUIntLE(offset, size);
          const limit = Math.pow(2, size * 8 - 1);
          return value >= limit ? value - limit * 2 : value;
        }
        writeUIntBE(value, offset, byteLength) {
          const at = offset | 0, size = byteLength | 0;
          if (size < 1 || size > 6) throw new RangeError('byteLength must be >= 1 and <= 6');
          let rest = Math.floor(Number(value));
          for (let i = size - 1; i >= 0; i--) { this[at + i] = rest & 0xff; rest = Math.floor(rest / 256); }
          return at + size;
        }
        writeUIntLE(value, offset, byteLength) {
          const at = offset | 0, size = byteLength | 0;
          if (size < 1 || size > 6) throw new RangeError('byteLength must be >= 1 and <= 6');
          let rest = Math.floor(Number(value));
          for (let i = 0; i < size; i++) { this[at + i] = rest & 0xff; rest = Math.floor(rest / 256); }
          return at + size;
        }
        writeIntBE(value, offset, byteLength) {
          const size = byteLength | 0;
          const raw = Number(value) < 0 ? Number(value) + Math.pow(2, size * 8) : Number(value);
          return this.writeUIntBE(raw, offset, size);
        }
        writeIntLE(value, offset, byteLength) {
          const size = byteLength | 0;
          const raw = Number(value) < 0 ? Number(value) + Math.pow(2, size * 8) : Number(value);
          return this.writeUIntLE(raw, offset, size);
        }
        /// Byte-order swaps, in place, returning the same buffer as node does.
        swap16() {
          if (this.length % 2 !== 0) throw new RangeError('Buffer size must be a multiple of 16-bits');
          for (let i = 0; i < this.length; i += 2) {
            const a = this[i]; this[i] = this[i + 1]; this[i + 1] = a;
          }
          return this;
        }
        swap32() {
          if (this.length % 4 !== 0) throw new RangeError('Buffer size must be a multiple of 32-bits');
          for (let i = 0; i < this.length; i += 4) {
            let a = this[i]; this[i] = this[i + 3]; this[i + 3] = a;
            a = this[i + 1]; this[i + 1] = this[i + 2]; this[i + 2] = a;
          }
          return this;
        }
        swap64() {
          if (this.length % 8 !== 0) throw new RangeError('Buffer size must be a multiple of 64-bits');
          for (let i = 0; i < this.length; i += 8) {
            for (let j = 0; j < 4; j++) {
              const a = this[i + j]; this[i + j] = this[i + 7 - j]; this[i + 7 - j] = a;
            }
          }
          return this;
        }
        compare(other, targetStart, targetEnd, sourceStart, sourceEnd) {
          // The ranged form compares SLICES of each side; without it a caller checking one
          // field of two records was told the whole records differ.
          const target = targetStart === undefined && targetEnd === undefined
            ? other : other.subarray(targetStart | 0, targetEnd === undefined ? other.length : targetEnd | 0);
          const source = sourceStart === undefined && sourceEnd === undefined
            ? this : this.subarray(sourceStart | 0, sourceEnd === undefined ? this.length : sourceEnd | 0);
          const length = Math.min(source.length, target.length);
          for (let i = 0; i < length; i++) { if (source[i] !== target[i]) return source[i] < target[i] ? -1 : 1; }
          return source.length === target.length ? 0 : (source.length < target.length ? -1 : 1);
        }
        indexOf(value, byteOffset, encoding) {
          const needle = typeof value === 'number' ? Buffer.from([value & 0xff])
            : (Buffer.isBuffer(value) ? value : Buffer.from(String(value), encoding || 'utf8'));
          const start = byteOffset === undefined ? 0 : Math.max(0, byteOffset | 0);
          if (needle.length === 0) return start;
          outer: for (let i = start; i <= this.length - needle.length; i++) {
            for (let j = 0; j < needle.length; j++) { if (this[i + j] !== needle[j]) continue outer; }
            return i;
          }
          return -1;
        }
        includes(value, byteOffset, encoding) { return this.indexOf(value, byteOffset, encoding) !== -1; }
        /// The LAST occurrence, searched backwards from `byteOffset` (the end by default).
        lastIndexOf(value, byteOffset, encoding) {
          const needle = typeof value === 'number' ? Buffer.from([value & 0xff])
            : (Buffer.isBuffer(value) ? value : Buffer.from(String(value), encoding || 'utf8'));
          if (needle.length === 0) return this.length;
          let start = byteOffset === undefined ? this.length - needle.length : byteOffset | 0;
          if (start < 0) start = this.length + start;
          start = Math.min(start, this.length - needle.length);
          outer: for (let index = start; index >= 0; index -= 1) {
            for (let offset = 0; offset < needle.length; offset += 1) {
              if (this[index + offset] !== needle[offset]) continue outer;
            }
            return index;
          }
          return -1;
        }
        // node's slice is a VIEW over the same memory, not a copy — `buffer.slice(1,3)[0] = x`
        // changes the buffer. Uint8Array's own slice copies, so inheriting it lost every write
        // made through a slice, silently, which is how a parser that patches a header in place
        // ends up doing nothing at all.
        slice(start, end) { return this.subarray(start, end); }
        equals(other) { return this.length === other.length && this.every((b, i) => b === other[i]); }
        toJSON() { return { type: 'Buffer', data: Array.from(this) }; }
      }
      // node's Buffer statics are ENUMERABLE own properties, and `safe-buffer` — a
      // dependency of express, body-parser and hundreds of other packages — copies them with
      // `for (var key in src)`. Class statics are NON-enumerable, so that copy produced a
      // Buffer with no `isBuffer`, and express's `res.send()` died on
      // "Buffer.isBuffer is not a function" for every route. Re-declaring them enumerable
      // fixes the whole family at once; adding `allocUnsafeSlow` matters just as much,
      // because safe-buffer only takes its transparent fast path when all four allocators
      // are present, and otherwise builds the lossy copy above.
      const bufferStatics = {
        from: Buffer.from,
        alloc: Buffer.alloc,
        allocUnsafe: Buffer.allocUnsafe,
        allocUnsafeSlow: function(size) { return Buffer.allocUnsafe(size); },
        isBuffer: Buffer.isBuffer,
        byteLength: Buffer.byteLength,
        concat: Buffer.concat,
        of: function() { return Buffer.from(Array.prototype.slice.call(arguments)); },
        compare: function(a, b) {
          const length = Math.min(a.length, b.length);
          for (let i = 0; i < length; i++) { if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1; }
          return a.length === b.length ? 0 : (a.length < b.length ? -1 : 1);
        },
        isEncoding: function(name) {
          return ['utf8', 'utf-8', 'hex', 'base64', 'base64url', 'latin1', 'binary', 'ascii',
                  'ucs2', 'ucs-2', 'utf16le', 'utf-16le'].indexOf(String(name).toLowerCase()) >= 0;
        },
        poolSize: 8192,
      };
      for (const name of Object.keys(bufferStatics)) {
        // defineProperty, not assignment: assigning over an existing non-enumerable own
        // property keeps it non-enumerable, which is the whole bug.
        Object.defineProperty(Buffer, name, {
          value: bufferStatics[name], writable: true, enumerable: true, configurable: true,
        });
      }
      // node exposes a lowercase-`uint` alias for every UInt accessor (readUint16BE next to
      // readUInt16BE), and code written against the newer docs uses those spellings. Generated
      // from the real ones so the pair can never drift apart.
      for (const name of Object.getOwnPropertyNames(Buffer.prototype)) {
        if (name.indexOf('UInt') < 0 && name.indexOf('BigUInt') < 0) continue;
        const alias = name.replace('BigUInt', 'BigUint').replace(/(?<!Big)UInt/, 'Uint');
        if (alias !== name && !(alias in Buffer.prototype)) {
          Object.defineProperty(Buffer.prototype, alias, {
            value: Buffer.prototype[name], writable: true, enumerable: false, configurable: true,
          });
        }
      }
      // `Buffer.copyBytesFrom(view[, offset[, length]])` copies OUT of a typed array, and copies
      // by VALUE — the same distinction that made Buffer.from(typedArray) subtle.
      Object.defineProperty(Buffer, 'copyBytesFrom', {
        writable: true, enumerable: true, configurable: true,
        value: function(view, offset, length) {
          if (!ArrayBuffer.isView(view)) {
            throw Object.assign(new TypeError('The "view" argument must be an instance of TypedArray'),
                                { code: 'ERR_INVALID_ARG_TYPE' });
          }
          const start = offset === undefined ? 0 : Number(offset);
          const count = length === undefined ? view.length - start : Number(length);
          const slice = view.subarray(start, start + count);
          // Element VALUES, widened to bytes per element — not a reinterpretation of the memory.
          const out = Buffer.alloc(slice.length * view.BYTES_PER_ELEMENT);
          const target = new (view.constructor)(out.buffer, out.byteOffset, slice.length);
          target.set(slice);
          return out;
        },
      });
      globalThis.Buffer = Buffer;

      // ---- Web globals JSC doesn't ship (wasm/Emscripten glue expects them) ----
      globalThis.TextEncoder = class TextEncoder {
        get encoding() { return 'utf-8'; }
        encode(text) { return new Uint8Array(Buffer.from(String(text), 'utf8')); }
        /// Encode into a caller's array, reporting how much fit. Never splits a character: a
        /// destination too small for the next one stops rather than writing half of it.
        encodeInto(text, destination) {
          const source = String(text);
          let read = 0, written = 0;
          for (const character of source) {
            const bytes = Buffer.from(character, 'utf8');
            if (written + bytes.length > destination.length) break;
            for (let i = 0; i < bytes.length; i++) destination[written + i] = bytes[i];
            written += bytes.length;
            read += character.length;          // a surrogate pair counts as its two units
          }
          return { read: read, written: written };
        }
      };
      /// How many trailing bytes form an INCOMPLETE UTF-8 sequence, so a streaming decode can
      /// hold them back instead of emitting replacement characters. Without this, a multi-byte
      /// character split across two chunks is corrupted — which is the whole difference between
      /// decoding a stream and decoding each chunk.
      function incompleteTailLength(bytes) {
        const total = bytes.length;
        for (let back = 1; back <= 4 && back <= total; back++) {
          const byte = bytes[total - back];
          if (byte < 0x80) return 0;                    // ASCII: nothing pending
          if ((byte & 0xC0) === 0x80) continue;         // continuation byte: keep looking back
          const needed = (byte & 0xE0) === 0xC0 ? 2
                       : (byte & 0xF0) === 0xE0 ? 3
                       : (byte & 0xF8) === 0xF0 ? 4 : 1;
          return needed > back ? back : 0;
        }
        return 0;
      }

      globalThis.TextDecoder = class TextDecoder {
        constructor(encoding, options) {
          this.encoding = (encoding || 'utf-8').toLowerCase();
          options = options || {};
          this.fatal = !!options.fatal;
          this.ignoreBOM = !!options.ignoreBOM;
          this._carry = null;      // bytes held back mid-sequence between streaming calls
          this._sawBOM = false;
        }
        decode(view, options) {
          const streaming = !!(options && options.stream);
          let bytes = view === undefined ? Buffer.alloc(0)
            : Buffer.from(view.buffer ? new Uint8Array(view.buffer, view.byteOffset, view.byteLength) : view);
          if (this._carry && this._carry.length) {
            bytes = Buffer.concat([this._carry, bytes]);
            this._carry = null;
          }
          const utf16 = this.encoding === 'utf-16le';
          if (streaming && !utf16) {
            const pending = incompleteTailLength(bytes);
            if (pending > 0) {
              this._carry = bytes.slice(bytes.length - pending);
              bytes = bytes.slice(0, bytes.length - pending);
            }
          }
          let text = bytes.toString(utf16 ? 'utf16le' : 'utf8');
          // A leading BOM is dropped once unless the caller asked to keep it.
          if (!this.ignoreBOM && !this._sawBOM && text.charCodeAt(0) === 0xFEFF) {
            text = text.slice(1);
            this._sawBOM = true;
          } else if (text.length) {
            this._sawBOM = true;
          }
          if (!streaming) { this._carry = null; this._sawBOM = false; }
          return text;
        }
      };
      // The WHATWG stream forms, which is how a fetch body is read as text without buffering it
      // all: `response.body.pipeThrough(new TextDecoderStream())`.
      globalThis.TextDecoderStream = class TextDecoderStream {
        constructor(encoding, options) {
          const decoder = new globalThis.TextDecoder(encoding, options);
          this.encoding = decoder.encoding;
          this.fatal = decoder.fatal;
          this.ignoreBOM = decoder.ignoreBOM;
          const inner = new globalThis.TransformStream({
            transform: function(chunk, controller) {
              const text = decoder.decode(chunk, { stream: true });
              if (text) controller.enqueue(text);
            },
            flush: function(controller) {
              // The tail: whatever was held back, decoded now that no more is coming.
              const text = decoder.decode();
              if (text) controller.enqueue(text);
            },
          });
          this.readable = inner.readable;
          this.writable = inner.writable;
        }
      };
      globalThis.TextEncoderStream = class TextEncoderStream {
        constructor() {
          const encoder = new globalThis.TextEncoder();
          this.encoding = 'utf-8';
          const inner = new globalThis.TransformStream({
            transform: function(chunk, controller) {
              const bytes = encoder.encode(String(chunk));
              if (bytes.length) controller.enqueue(bytes);
            },
          });
          this.readable = inner.readable;
          this.writable = inner.writable;
        }
      };
      // timeOrigin is a WALL-clock instant by spec, but `now()` is an offset on the monotonic
      // clock — mixing the two sources is the point, not an oversight.
      globalThis.__perfStart = BigInt(bridge.monotonicNanos());
      globalThis.performance = {
        timeOrigin: Date.now(),
        now: function(){
          return Number(BigInt(bridge.monotonicNanos()) - globalThis.__perfStart) / 1e6;
        },
        mark: function(){}, measure: function(){},
      };
      // The Web Crypto global (distinct from the `crypto` module): nanoid, uuid, and browser-
      // targeted libraries reach for `crypto.getRandomValues` / `crypto.randomUUID`.
      globalThis.crypto = {
        getRandomValues: function(view){
          const bytes = Buffer.from(bridge.randomBytes(view.byteLength), 'base64');
          const out = new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
          for (let i = 0; i < out.length; i++) out[i] = bytes[i];
          return view;
        },
        randomUUID: function(){ return bridge.randomUUID(); },
      };
      // WHATWG streams — the subset vendored fetch/undici code touches. Queue-backed,
      // single-reader, promise-correct; no backpressure sizing.
      globalThis.ReadableStream = class ReadableStream {
        constructor(source) {
          this._queue = [];
          this._closed = false;
          this._error = null;
          this._waiters = [];
          this.locked = false;
          const stream = this;
          this._controller = {
            enqueue: function(chunk) { stream._queue.push(chunk); stream._wake(); },
            close: function() { stream._closed = true; stream._wake(); },
            error: function(e) { stream._error = e || new Error('stream errored'); stream._wake(); },
            get desiredSize() { return 1; },
          };
          this._source = source || {};
          if (this._source.start) this._source.start(this._controller);
        }
        _wake() { const waiters = this._waiters; this._waiters = []; for (const w of waiters) w(); }
        _next() {
          const stream = this;
          if (stream._error) return Promise.reject(stream._error);
          if (stream._queue.length) return Promise.resolve({ value: stream._queue.shift(), done: false });
          if (stream._closed) return Promise.resolve({ value: undefined, done: true });
          const pulled = stream._source.pull ? Promise.resolve(stream._source.pull(stream._controller)) : Promise.resolve();
          return pulled.then(function() {
            if (stream._queue.length || stream._closed || stream._error) return stream._next();
            return new Promise(function(resolve){ stream._waiters.push(resolve); }).then(function(){ return stream._next(); });
          });
        }
        getReader() {
          const stream = this;
          stream.locked = true;
          return {
            read: function() { return stream._next(); },
            releaseLock: function() { stream.locked = false; },
            cancel: function(reason) { stream.locked = false; return stream.cancel(reason); },
            get closed() { return new Promise(function(resolve){ (function check(){ if (stream._closed) resolve(); else stream._waiters.push(check); })(); }); },
          };
        }
        cancel(reason) {
          this._closed = true;
          if (this._source.cancel) try { this._source.cancel(reason); } catch (e) {}
          this._wake();
          return Promise.resolve();
        }
        pipeTo(destination) {
          const reader = this.getReader();
          const writer = destination.getWriter();
          function step() {
            return reader.read().then(function(result) {
              if (result.done) return writer.close();
              return Promise.resolve(writer.write(result.value)).then(step);
            });
          }
          return step();
        }
        pipeThrough(transform) { this.pipeTo(transform.writable); return transform.readable; }
        tee() {
          const chunks1 = [], chunks2 = [];
          const stream = this;
          function branch(buffer, other) {
            return new ReadableStream({ pull: function(controller) {
              if (buffer.length) { controller.enqueue(buffer.shift()); return; }
              return stream._next().then(function(result) {
                if (result.done) { controller.close(); return; }
                other.push(result.value);
                controller.enqueue(result.value);
              });
            } });
          }
          return [branch(chunks1, chunks2), branch(chunks2, chunks1)];
        }
        [Symbol.asyncIterator]() {
          const reader = this.getReader();
          return { next: function() { return reader.read(); }, [Symbol.asyncIterator]() { return this; } };
        }
        static from(iterable) {
          return new ReadableStream({ start: async function(controller) {
            for await (const item of iterable) controller.enqueue(item);
            controller.close();
          } });
        }
      };
      globalThis.WritableStream = class WritableStream {
        constructor(sink) { this._sink = sink || {}; this.locked = false; if (this._sink.start) this._sink.start(); }
        getWriter() {
          const stream = this;
          stream.locked = true;
          return {
            write: function(chunk) { return Promise.resolve(stream._sink.write ? stream._sink.write(chunk) : undefined); },
            close: function() { stream.locked = false; return Promise.resolve(stream._sink.close ? stream._sink.close() : undefined); },
            abort: function(reason) { stream.locked = false; return Promise.resolve(stream._sink.abort ? stream._sink.abort(reason) : undefined); },
            releaseLock: function() { stream.locked = false; },
            ready: Promise.resolve(),
          };
        }
        abort(reason) { return Promise.resolve(this._sink.abort ? this._sink.abort(reason) : undefined); }
      };
      globalThis.TransformStream = class TransformStream {
        constructor(transformer) {
          transformer = transformer || {};
          let readableController;
          this.readable = new ReadableStream({ start: function(controller) { readableController = controller; } });
          const wrapped = {
            enqueue: function(chunk) { readableController.enqueue(chunk); },
            close: function() { readableController.close(); },
            error: function(e) { readableController.error(e); },
          };
          if (transformer.start) transformer.start(wrapped);
          this.writable = new WritableStream({
            write: function(chunk) {
              if (transformer.transform) return transformer.transform(chunk, wrapped);
              wrapped.enqueue(chunk);
            },
            close: function() {
              const flushed = transformer.flush ? transformer.flush(wrapped) : undefined;
              return Promise.resolve(flushed).then(function(){ readableController.close(); });
            },
          });
        }
      };
      globalThis.CountQueuingStrategy = class CountQueuingStrategy { constructor(options) { this.highWaterMark = options && options.highWaterMark || 1; } };
      globalThis.ByteLengthQueuingStrategy = class ByteLengthQueuingStrategy { constructor(options) { this.highWaterMark = options && options.highWaterMark || 16384; } };
      // V8's stack-trace protocol: when Error.prepareStackTrace is set, captureStackTrace
      // hands it structured CallSite objects (depd — under express — walks them). JSC's
      // native captureStackTrace ignores the protocol, so emulate it from JSC stack lines
      // ("functionName@file:line:col").
      Error.captureStackTrace = function(target, constructorOpt) {
        const raw = (new Error().stack || '').split('\n').slice(1);
        if (typeof Error.prepareStackTrace === 'function') {
          const callSites = raw.map(function(line) {
            const at = line.lastIndexOf('@');
            const name = at >= 0 ? line.slice(0, at) : '';
            const match = (at >= 0 ? line.slice(at + 1) : line).match(/^(.*?):(\d+):(\d+)$/) || [];
            return {
              getFileName: function(){ return match[1] || null; },
              getLineNumber: function(){ return match[2] ? Number(match[2]) : null; },
              getColumnNumber: function(){ return match[3] ? Number(match[3]) : null; },
              getFunctionName: function(){ return name || null; },
              getMethodName: function(){ return name || null; },
              getTypeName: function(){ return null; },
              getEvalOrigin: function(){ return undefined; },
              getThis: function(){ return undefined; },
              isNative: function(){ return line.includes('[native code]'); },
              isToplevel: function(){ return !name; },
              isEval: function(){ return false; },
              isConstructor: function(){ return false; },
              isAsync: function(){ return false; },
              toString: function(){ return line; },
            };
          });
          target.stack = Error.prepareStackTrace(target, callSites);
        } else {
          target.stack = (target.name || 'Error') + (target.message ? ': ' + target.message : '') + '\n'
            + raw.map(function(l){ return '    at ' + l; }).join('\n');
        }
      };
      globalThis.atob = function(base64) { return Buffer.from(String(base64), 'base64').toString('binary'); };
      globalThis.btoa = function(binary) { return Buffer.from(String(binary), 'binary').toString('base64'); };
      // JSC's ASYNC wasm APIs never settle on a bare JSContext (their completion needs a
      // runloop the dispatch-queue thread doesn't run) — the sync constructors work, so the
      // async surface resolves through them on the microtask queue.
      if (typeof WebAssembly === 'object') {
        WebAssembly.instantiate = function(source, imports) {
          return new Promise(function(resolve, reject) {
            try {
              if (source instanceof WebAssembly.Module) {
                resolve(new WebAssembly.Instance(source, imports));
              } else {
                const module = new WebAssembly.Module(source);
                resolve({ module: module, instance: new WebAssembly.Instance(module, imports) });
              }
            } catch (e) { reject(e); }
          });
        };
        WebAssembly.compile = function(source) {
          return new Promise(function(resolve, reject) {
            try { resolve(new WebAssembly.Module(source)); } catch (e) { reject(e); }
          });
        };
      }
      globalThis.Event = class Event {
        constructor(type, options) {
          this.type = String(type);
          this.bubbles = !!(options && options.bubbles);
          this.cancelable = !!(options && options.cancelable);
          this.defaultPrevented = false;
          this.target = null;
        }
        preventDefault() { if (this.cancelable) this.defaultPrevented = true; }
        stopPropagation() {}
        stopImmediatePropagation() {}
      };
      globalThis.CustomEvent = class CustomEvent extends Event {
        constructor(type, options) { super(type, options); this.detail = options && options.detail; }
      };
      globalThis.EventTarget = class EventTarget {
        constructor() { this._listeners = {}; }
        addEventListener(type, listener, options) {
          const list = this._listeners[type] = this._listeners[type] || [];
          list.push({ listener: listener, once: !!(options && options.once) });
        }
        removeEventListener(type, listener) {
          const list = this._listeners[type] || [];
          const index = list.findIndex(function(entry){ return entry.listener === listener; });
          if (index >= 0) list.splice(index, 1);
        }
        dispatchEvent(event) {
          event.target = this;
          for (const entry of (this._listeners[event.type] || []).slice()) {
            if (entry.once) this.removeEventListener(event.type, entry.listener);
            (entry.listener.handleEvent || entry.listener).call(entry.listener, event);
          }
          return !event.defaultPrevented;
        }
      };
      // In node these globals ARE the worker_threads classes — `===` identical — and there is
      // one MessagePort with both surfaces rather than a web port and a module port that behave
      // differently. There were two here, so `receiveMessageOnPort` accepted the module's ports
      // and not the global ones. Lazily resolved, so requiring the module still builds them.
      for (const name of ['MessageChannel', 'MessagePort', 'BroadcastChannel']) {
        Object.defineProperty(globalThis, name, {
          configurable: true,
          get: function(){ return coreRequire('worker_threads')[name]; },
        });
      }
      globalThis.AbortSignal = class AbortSignal {
        constructor() { this.aborted = false; this.reason = undefined; this._listeners = []; this.onabort = null; }
        addEventListener(type, listener) { if (type === 'abort') this._listeners.push(listener); }
        removeEventListener(type, listener) {
          if (type !== 'abort') return;
          const index = this._listeners.indexOf(listener);
          if (index >= 0) this._listeners.splice(index, 1);
        }
        dispatchEvent() {}
        throwIfAborted() { if (this.aborted) throw this.reason; }
        _abort(reason) {
          if (this.aborted) return;
          this.aborted = true;
          this.reason = reason !== undefined ? reason : Object.assign(new Error('This operation was aborted'), { name: 'AbortError' });
          const event = { type: 'abort', target: this };
          if (this.onabort) this.onabort(event);
          for (const listener of this._listeners.slice()) (listener.handleEvent || listener).call(listener, event);
        }
        static abort(reason) { const signal = new AbortSignal(); signal._abort(reason); return signal; }
        static timeout(ms) {
          const signal = new AbortSignal();
          setTimeout(function(){ signal._abort(Object.assign(new Error('The operation was aborted due to timeout'), { name: 'TimeoutError' })); }, ms);
          return signal;
        }
        static any(signals) {
          const combined = new AbortSignal();
          for (const signal of signals) {
            if (signal.aborted) { combined._abort(signal.reason); break; }
            signal.addEventListener('abort', function(){ combined._abort(signal.reason); });
          }
          return combined;
        }
      };
      globalThis.AbortController = class AbortController {
        constructor() { this.signal = new AbortSignal(); }
        abort(reason) { this.signal._abort(reason); }
      };
      globalThis.DOMException = class DOMException extends Error {
        constructor(message, name) { super(message); this.name = name || 'Error'; }
      };
      globalThis.structuredClone = function(value) { return globalThis.__clone(value); };
      globalThis.queueMicrotask = globalThis.queueMicrotask || function(fn) { Promise.resolve().then(fn); };
      globalThis.URLSearchParams = class URLSearchParams {
        constructor(init) {
          this._pairs = [];
          if (typeof init === 'string') {
            for (const piece of init.replace(/^\?/, '').split('&')) {
              if (!piece) continue;
              const eq = piece.indexOf('=');
              const name = decodeURIComponent(eq < 0 ? piece : piece.slice(0, eq)).replace(/\+/g, ' ');
              const value = eq < 0 ? '' : decodeURIComponent(piece.slice(eq + 1).replace(/\+/g, ' '));
              this._pairs.push([name, value]);
            }
          } else if (init && typeof init[Symbol.iterator] === 'function') {
            for (const [name, value] of init) this._pairs.push([String(name), String(value)]);
          } else if (init && typeof init === 'object') {
            for (const name of Object.keys(init)) this._pairs.push([name, String(init[name])]);
          }
        }
        // A URL's searchParams is LIVE: mutating it rewrites the URL's search and href. The hook
        // is how the owning URL hears about it — eslint cache-busts an ESM config import by
        // appending an mtime and then reading `href`, which a detached copy would never show.
        _changed() { if (this._owner) this._owner(); }
        append(name, value) { this._pairs.push([String(name), String(value)]); this._changed(); }
        set(name, value) { this.delete(name); this.append(name, value); }
        get(name) { const found = this._pairs.find(p => p[0] === name); return found ? found[1] : null; }
        getAll(name) { return this._pairs.filter(p => p[0] === name).map(p => p[1]); }
        has(name) { return this._pairs.some(p => p[0] === name); }
        delete(name) { this._pairs = this._pairs.filter(p => p[0] !== name); this._changed(); }
        forEach(fn, thisArg) { for (const [name, value] of this._pairs.slice()) fn.call(thisArg, value, name, this); }
        keys() { return this._pairs.map(p => p[0])[Symbol.iterator](); }
        values() { return this._pairs.map(p => p[1])[Symbol.iterator](); }
        entries() { return this._pairs.map(p => [p[0], p[1]])[Symbol.iterator](); }
        [Symbol.iterator]() { return this.entries(); }
        get size() { return this._pairs.length; }
        toString() {
          return this._pairs.map(p => encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1])).join('&');
        }
        sort() { this._pairs.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0); this._changed(); }
      };
      if (typeof globalThis.URL === 'undefined') {
        // The slice Emscripten and fetch-y libraries touch: parse, href, protocol, pathname.
        // JSC gives us no URL, so this fallback IS the URL every http request is parsed with —
        // which is why relative resolution follows RFC 3986 §5.2 rather than trimming the base
        // after the last slash. That shortcut turned `new URL('/root', 'https://x/a/b')` into
        // "https://x/a//root", and `../` was never resolved at all.
        function removeDotSegments(path) {
          const out = [];
          for (const piece of String(path).split('/')) {
            if (piece === '.') continue;
            if (piece === '..') { if (out.length > 1) out.pop(); continue; }
            out.push(piece);
          }
          let joined = out.join('/');
          if (/\/\.\.?$/.test(path) && !joined.endsWith('/')) joined += '/';
          return joined;
        }
        globalThis.URL = class URL {
          constructor(input, base) {
            let text = String(input).trim();
            const hasScheme = /^[a-zA-Z][\w+.-]*:/.test(text);
            if (!hasScheme) {
              if (base === undefined || base === null) {
                throw Object.assign(new TypeError('Invalid URL: ' + input), { code: 'ERR_INVALID_URL', input: input });
              }
              const parent = base instanceof URL ? base : new URL(String(base && base.href ? base.href : base));
              // The base for resolution keeps the credentials; `origin` deliberately does not
              // (node reports origin without them, but carries them in href). The '//' is the
              // AUTHORITY marker, not a host: 'file:///a/b' has an empty authority and keeps it,
              // so keying this off `hostname` resolved every relative import inside a package to
              // 'file:/…' — the same mistake href itself was fixed for, at the other site.
              const root = parent.protocol + (parent._hierarchical ? '//' + parent._authority : '');
              if (text.startsWith('//')) {
                text = parent.protocol + text;                       // protocol-relative
              } else if (text.startsWith('/')) {
                text = root + removeDotSegments(text);                // origin-relative
              } else if (text.startsWith('?')) {
                text = root + parent.pathname + text;
              } else if (text.startsWith('#')) {
                text = root + parent.pathname + parent.search + text;
              } else if (!text) {
                text = root + parent.pathname + parent.search;
              } else {
                // Merge with the base's DIRECTORY, then resolve dot segments over the whole
                // path — the step the old version skipped.
                const directory = parent.pathname.replace(/[^/]*$/, '');
                text = root + removeDotSegments(directory + text);
              }
            }
            const match = text.match(/^([a-zA-Z][\w+.-]*:)(?:\/\/(?:([^/?#@]*)@)?([^/?#:]*)(?::(\d+))?)?([^?#]*)(\?[^#]*)?(#.*)?$/);
            if (!match) {
              throw Object.assign(new TypeError('Invalid URL: ' + input), { code: 'ERR_INVALID_URL', input: input });
            }
            this.protocol = match[1] || '';
            const credentials = match[2] || '';
            this.username = credentials ? credentials.split(':')[0] : '';
            this.password = credentials && credentials.indexOf(':') >= 0 ? credentials.slice(credentials.indexOf(':') + 1) : '';
            this.hostname = match[3] || '';
            this.port = match[4] || '';
            this.host = this.hostname + (this.port ? ':' + this.port : '');
            // A hierarchical URL always has a path; node reports '/' where the text has none.
            const hierarchical = text.indexOf('//') === this.protocol.length;
            this._hierarchical = hierarchical;
            // A path is percent-encoded text, not raw text. Existing '%' escapes are left alone
            // (re-encoding them would corrupt any URL that arrived already encoded); everything
            // in the path percent-encode set, plus controls and non-ASCII, gets encoded.
            const encodePath = function(text) {
              let out = '';
              for (const ch of text) {
                const code = ch.codePointAt(0);
                if (code <= 0x20 || code === 0x7f || code > 0x7e ||
                    ch === '"' || ch === '<' || ch === '>' || ch === '`' || ch === '{' || ch === '}') {
                  // A lone surrogate has no UTF-8 form; pass it through rather than throwing.
                  try { out += encodeURIComponent(ch); } catch (error) { out += ch; }
                } else out += ch;
              }
              return out;
            };
            this.pathname = encodePath(match[5] || (hierarchical ? '/' : ''));
            this.search = match[6] || '';
            this.hash = match[7] || '';
            // Without a host there is no tuple origin, and node reports the string 'null' —
            // for file: URLs and for opaque schemes like mailto: alike.
            this.origin = this.hostname ? this.protocol + '//' + this.host : 'null';
            this._authority = credentials ? credentials + '@' + this.host : this.host;
            this.searchParams = new URLSearchParams(this.search);
            // Re-derive search and href whenever the params are mutated.
            const url = this;
            this.searchParams._owner = function() {
              const query = url.searchParams.toString();
              url.search = query ? '?' + query : '';
              url.href = url.protocol + (hierarchical ? '//' + url._authority : '') +
                         url.pathname + url.search + url.hash;
            };
            // The '//' belongs to a hierarchical URL whether or not it has a host: 'file:///a'
            // keeps its empty authority. Keying this off `hostname` produced 'file:/a'.
            this.href = this.protocol + (hierarchical ? '//' + this._authority : '') +
                        this.pathname + this.search + this.hash;
          }
          toString() { return this.href; }
          toJSON() { return this.href; }
          static canParse(input, base) { try { new URL(input, base); return true; } catch (e) { return false; } }
        };
      }

      // ---- ESM interop (the transpiler emits these) ----
      // One coercion for "bytes a caller handed us": a Buffer, ANY view over bytes (a Uint8Array
      // from wasm, a DataView), an ArrayBuffer, or a string with its encoding. The shape this
      // replaces — `Buffer.isBuffer(x) ? x : Buffer.from(String(x))` — turns a Uint8Array of
      // [7,0,0,0] into the TEXT "7,0,0,0", which is exactly how esbuild's protocol packets and
      // Go's stdout writes were corrupted. Ten places had that shape.
      // Deep equality, shared by `assert` and `util.isDeepStrictEqual`. All three call sites used
      // to be `JSON.stringify(a) === JSON.stringify(b)`, which is wrong in every direction that
      // matters: key ORDER decided equality, NaN never equalled itself, Map/Set/Date/RegExp all
      // collapsed to {}, a key holding undefined vanished so `{a: undefined}` equalled `{}`, and
      // a circular structure threw instead of comparing.
      globalThis.__deepEqual = function(a, b, strict) {
        return (function compare(x, y, seen) {
          if (x === y) return true;
          // SameValueZero for the strict form, so NaN equals NaN as node has it.
          if (typeof x === 'number' && typeof y === 'number' && Number.isNaN(x) && Number.isNaN(y)) return true;
          if (x === null || y === null || typeof x !== 'object' || typeof y !== 'object') {
            return strict ? false : x == y;
          }
          // A pair already under comparison is taken as equal — the standard rule that lets two
          // self-referential structures compare without recursing forever.
          for (const pair of seen) if (pair[0] === x && pair[1] === y) return true;
          const nested = seen.concat([[x, y]]);

          if (strict && Object.getPrototypeOf(x) !== Object.getPrototypeOf(y)) return false;
          if (x instanceof Date || y instanceof Date) {
            return x instanceof Date && y instanceof Date && x.getTime() === y.getTime();
          }
          if (x instanceof RegExp || y instanceof RegExp) {
            return x instanceof RegExp && y instanceof RegExp && x.source === y.source && x.flags === y.flags;
          }
          if (ArrayBuffer.isView(x) || ArrayBuffer.isView(y)) {
            if (!ArrayBuffer.isView(x) || !ArrayBuffer.isView(y)) return false;
            const bx = new Uint8Array(x.buffer, x.byteOffset, x.byteLength);
            const by = new Uint8Array(y.buffer, y.byteOffset, y.byteLength);
            if (bx.length !== by.length) return false;
            for (let i = 0; i < bx.length; i++) if (bx[i] !== by[i]) return false;
            return true;
          }
          if (x instanceof Map || y instanceof Map) {
            if (!(x instanceof Map) || !(y instanceof Map) || x.size !== y.size) return false;
            for (const [key, value] of x) {
              // Keys may be objects, so `y.get(key)` would miss an equal-but-not-identical key.
              let found = false;
              for (const [otherKey, otherValue] of y) {
                if (compare(key, otherKey, nested) && compare(value, otherValue, nested)) { found = true; break; }
              }
              if (!found) return false;
            }
            return true;
          }
          if (x instanceof Set || y instanceof Set) {
            if (!(x instanceof Set) || !(y instanceof Set) || x.size !== y.size) return false;
            for (const value of x) {
              let found = false;
              for (const other of y) if (compare(value, other, nested)) { found = true; break; }
              if (!found) return false;
            }
            return true;
          }
          if (Array.isArray(x) !== Array.isArray(y)) return false;
          const keysX = Object.keys(x), keysY = Object.keys(y);
          if (keysX.length !== keysY.length) return false;
          for (const key of keysX) {
            if (!Object.prototype.hasOwnProperty.call(y, key)) return false;
            if (!compare(x[key], y[key], nested)) return false;
          }
          return true;
        })(a, b, []);
      };

      // The structured clone, in ONE place. Seven sites used `JSON.parse(JSON.stringify(x))`
      // or `JSON.stringify` for a structural job — v8.serialize, structuredClone, worker
      // postMessage (twice), workerData, and environmentData — and JSON silently drops a Map, a
      // Set, a Date, a typed array, `undefined`, a BigInt and every cycle. That is the defect
      // that hung jest, and it was already fixed once in deepStrictEqual before turning up
      // again here: the sweep has to follow the MECHANISM, not the word.
      // JavaScriptCore has Atomics — they work on an ordinary ArrayBuffer, measured — but no
      // SharedArrayBuffer constructor, and no option turns one on. The constructor's ABSENCE is
      // a separate thing from the sharing it names, and it was costing programs that never share:
      // tinypool allocates one per worker for its own signalling, so vitest could not start a
      // pool at all. So the constructor exists, backed by a real ArrayBuffer, and the SHARING is
      // where the refusal lives — a buffer that crosses to another engine throws rather than
      // silently arriving as an unrelated copy, which is the failure nobody would ever debug.
      if (typeof globalThis.SharedArrayBuffer === 'undefined') {
        const Shared = function SharedArrayBuffer(length) {
          const buffer = new ArrayBuffer(length);
          Object.defineProperty(buffer, '__mouseShared', { value: true });
          return buffer;
        };
        // The prototype IS ArrayBuffer's, because the object is one: code reads
        // `SharedArrayBuffer.prototype.byteLength`'s getter off it (jsdom and mongoose both do,
        // to tell buffer kinds apart), and a fresh empty prototype has no such accessor.
        Shared.prototype = ArrayBuffer.prototype;
        Object.defineProperty(Shared, Symbol.hasInstance, {
          value: function(value) { return !!(value && value.__mouseShared); },
        });
        globalThis.SharedArrayBuffer = Shared;
        // `Atomics.wait` on one of these is a program asking to BLOCK until another thread
        // writes the memory — and there is no other thread that can: a worker here is a separate
        // engine, and two engines cannot address one buffer. JavaScriptCore's own message names
        // SharedArrayBuffer, which reads like a type error and sends the reader to the wrong
        // question. esbuild's `buildSync` is exactly this call; its async form works.
        if (typeof Atomics !== 'undefined' && typeof Atomics.wait === 'function') {
          const realWait = Atomics.wait;
          Atomics.wait = function(typed, index, value, timeout) {
            if (typed && typed.buffer && typed.buffer.__mouseShared) {
              throw Object.assign(new Error(
                'Atomics.wait cannot block here: it waits for another thread to write shared '
                + 'memory, and a worker in this runtime is a separate JavaScriptCore engine that '
                + 'cannot address this buffer. The asynchronous form of whatever called this '
                + 'works — esbuild\'s build() rather than buildSync(), for instance.'),
                { code: 'ERR_ATOMICS_WAIT_UNAVAILABLE' });
            }
            return realWait.apply(this, arguments);
          };
        }
      }
      // node's child IPC defaults to `serialization: 'json'`, and only 'advanced' uses the
      // structured clone algorithm. The sweep that moved nine JSON sites onto the clone codec
      // moved this one too, which made the engine STRICTER than node: a message carrying a
      // function throws here where node quietly drops the property — and tinypool sends exactly
      // that to every worker it starts, so vitest could not begin. The wire stays the codec; the
      // difference is a JSON round-trip first, which is what 'json' mode means.
      globalThis.__ipcPrepare = function(message, advanced) {
        if (advanced) return message;
        const text = JSON.stringify(message);
        return text === undefined ? null : JSON.parse(text);
      };
      globalThis.__cloneEncode = function(root) {
        const heap = [], seen = new Map();
        function encode(value) {
          if (value === undefined) return { '#': 'u' };
          if (value === null) return null;
          const type = typeof value;
          if (type === 'string' || type === 'boolean') return value;
          if (type === 'number') {
            // JSON has no -0, Infinity or NaN; they survive as tags.
            if (Number.isFinite(value) && !Object.is(value, -0)) return value;
            return { '#': 'f', v: Object.is(value, -0) ? '-0' : String(value) };
          }
          if (type === 'bigint') return { '#': 'n', v: value.toString() };
          if (type === 'function' || type === 'symbol') {
            const error = new Error(String(value) + ' could not be cloned.');
            error.name = 'DataCloneError';
            throw error;
          }
          const existing = seen.get(value);
          if (existing !== undefined) return { '#': '@', i: existing };
          // The slot is claimed BEFORE the children are walked, so a cycle finds it.
          const index = heap.length;
          seen.set(value, index);
          heap.push(null);
          heap[index] = encodeContainer(value);
          return { '#': '@', i: index };
        }
        function encodeContainer(value) {
          if (value instanceof Date) return { '#': 'd', v: value.getTime() };
          if (value instanceof RegExp) return { '#': 'r', s: value.source, f: value.flags };
          if (value instanceof Map) {
            const pairs = [];
            for (const [k, v] of value) pairs.push([encode(k), encode(v)]);
            return { '#': 'm', v: pairs };
          }
          if (value instanceof Set) {
            const items = [];
            for (const item of value) items.push(encode(item));
            return { '#': 's', v: items };
          }
          if (Buffer.isBuffer(value)) return { '#': 'b', v: value.toString('base64') };
          if (ArrayBuffer.isView(value)) {
            return { '#': 't', k: value.constructor.name,
                     v: Buffer.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength)).toString('base64') };
          }
          if (value instanceof ArrayBuffer) {
            if (value.__mouseShared) {
              const error = new Error('A SharedArrayBuffer cannot be shared between workers here: '
                + 'a worker is a separate JavaScriptCore engine, and two engines cannot address '
                + 'the same memory. Within one engine it is a real buffer and Atomics work on it.');
              error.name = 'DataCloneError';
              throw error;
            }
            return { '#': 'ab', v: Buffer.from(new Uint8Array(value)).toString('base64') };
          }
          if (Array.isArray(value)) return { '#': 'a', v: value.map(encode) };
          const out = {};
          for (const key of Object.keys(value)) out[key] = encode(value[key]);
          return { '#': 'o', v: out };
        }
        const encoded = encode(root);
        return JSON.stringify({ heap: heap, root: encoded });
      }

      globalThis.__cloneDecode = function(buffer) {
        const parsed = JSON.parse(typeof buffer === 'string' ? buffer : __toBytes(buffer).toString('utf8'));
        const heap = parsed.heap, built = new Array(heap.length);
        // Shells first, so a cycle can point at a container that is not filled yet.
        for (let i = 0; i < heap.length; i++) {
          const node = heap[i];
          switch (node['#']) {
            case 'd': built[i] = new Date(node.v); break;
            case 'r': built[i] = new RegExp(node.s, node.f); break;
            case 'm': built[i] = new Map(); break;
            case 's': built[i] = new Set(); break;
            case 'a': built[i] = []; break;
            case 'b': built[i] = Buffer.from(node.v, 'base64'); break;
            case 'ab': built[i] = Buffer.from(node.v, 'base64').buffer.slice(0); break;
            case 't': {
              const bytes = Buffer.from(node.v, 'base64');
              const Kind = globalThis[node.k] || Uint8Array;
              built[i] = new Kind(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
              break;
            }
            default: built[i] = {};
          }
        }
        function decode(value) {
          if (value === null || typeof value !== 'object') return value;
          switch (value['#']) {
            case 'u': return undefined;
            case 'n': return BigInt(value.v);
            case 'f': return value.v === '-0' ? -0 : Number(value.v);
            case '@': return built[value.i];
          }
          return value;
        }
        for (let i = 0; i < heap.length; i++) {
          const node = heap[i];
          if (node['#'] === 'a') { for (const item of node.v) built[i].push(decode(item)); }
          else if (node['#'] === 'o') { for (const key of Object.keys(node.v)) built[i][key] = decode(node.v[key]); }
          else if (node['#'] === 'm') { for (const [k, v] of node.v) built[i].set(decode(k), decode(v)); }
          else if (node['#'] === 's') { for (const item of node.v) built[i].add(decode(item)); }
        }
        return decode(parsed.root);
      }


      // The in-memory form, which is what `structuredClone` and node's message copies are.
      globalThis.__clone = function(value) {
        return globalThis.__cloneDecode(globalThis.__cloneEncode(value));
      };

      // One shape for every compression coder class: `new X(opts)` and `createX(opts)` both
      // produce a stream that passes `instanceof X`, which node guarantees and callers branch
      // on. A global because the zlib factory and augmentCore are separate functions and both
      // need it — the brotli coders live in the second.
      globalThis.__coderClass = function(build, Base) {
        const Coder = function(options) {
          const stream = build(options);
          Object.setPrototypeOf(stream, Coder.prototype);
          return stream;
        };
        Coder.prototype = Object.create(Base.prototype);
        Coder.prototype.constructor = Coder;
        return Coder;
      };

      // ---- util.MIMEType / MIMEParams, parseEnv, getCallSites, diff ----
      // Named by the module-surface audit and left alone for a long time as "internals". They
      // are not: MIMEType and MIMEParams are documented classes, parseEnv is what `--env-file`
      // is built on, and getCallSites is how a logger reports where it was called from. The
      // underscore-prefixed neighbours in that same audit list ARE node internals and stay out.
      globalThis.__MIMEParams = class MIMEParams {
        constructor() { this._entries = []; }
        get(name) {
          const found = this._entries.find(pair => pair[0] === String(name));
          return found ? found[1] : null;
        }
        has(name) { return this._entries.some(pair => pair[0] === String(name)); }
        set(name, value) {
          const key = String(name), text = String(value);
          const found = this._entries.find(pair => pair[0] === key);
          if (found) found[1] = text; else this._entries.push([key, text]);
        }
        delete(name) { this._entries = this._entries.filter(pair => pair[0] !== String(name)); }
        entries() { return this._entries.map(pair => [pair[0], pair[1]])[Symbol.iterator](); }
        keys() { return this._entries.map(pair => pair[0])[Symbol.iterator](); }
        values() { return this._entries.map(pair => pair[1])[Symbol.iterator](); }
        [Symbol.iterator]() { return this.entries(); }
        toString() {
          return this._entries.map(function(pair) {
            // A value containing a separator has to come back quoted, or the reassembled type
            // would parse differently from the one that was read.
            const needsQuote = /[;=\s"]/.test(pair[1]);
            const value = needsQuote ? '"' + pair[1].replace(/(["\\])/g, '\\$1') + '"' : pair[1];
            return pair[0] + '=' + value;
          }).join(';');
        }
      };

      globalThis.__MIMEType = class MIMEType {
        constructor(input) {
          const text = String(input).trim();
          const semicolon = text.indexOf(';');
          const essence = (semicolon < 0 ? text : text.slice(0, semicolon)).trim();
          const slash = essence.indexOf('/');
          if (slash < 1 || slash === essence.length - 1) {
            throw new TypeError('The MIME syntax for a type in "' + input + '" is invalid');
          }
          this._type = essence.slice(0, slash).toLowerCase();
          this._subtype = essence.slice(slash + 1).toLowerCase();
          this.params = new globalThis.__MIMEParams();
          if (semicolon >= 0) {
            for (const piece of splitParameters(text.slice(semicolon + 1))) {
              const equals = piece.indexOf('=');
              if (equals < 0) continue;
              const name = piece.slice(0, equals).trim().toLowerCase();
              let value = piece.slice(equals + 1).trim();
              if (value.startsWith('"')) {
                value = value.slice(1, value.endsWith('"') ? -1 : undefined).replace(/\\(.)/g, '$1');
              }
              if (name) this.params.set(name, value);
            }
          }
        }
        get type() { return this._type; }
        set type(value) {
          const text = String(value).toLowerCase();
          if (!text || /[/;\s]/.test(text)) throw new TypeError('Invalid MIME type ' + value);
          this._type = text;
        }
        get subtype() { return this._subtype; }
        set subtype(value) {
          const text = String(value).toLowerCase();
          if (!text || /[/;\s]/.test(text)) throw new TypeError('Invalid MIME subtype ' + value);
          this._subtype = text;
        }
        get essence() { return this._type + '/' + this._subtype; }
        toString() {
          const parameters = this.params.toString();
          return this.essence + (parameters ? ';' + parameters : '');
        }
        toJSON() { return this.toString(); }
      };
      // A quoted value may contain the separator, so parameters cannot be split naively.
      function splitParameters(text) {
        const parts = [];
        let current = '', quoted = false;
        for (let i = 0; i < text.length; i++) {
          const ch = text[i];
          if (ch === '\\' && quoted) { current += ch + (text[++i] || ''); continue; }
          if (ch === '"') { quoted = !quoted; current += ch; continue; }
          if (ch === ';' && !quoted) { parts.push(current); current = ''; continue; }
          current += ch;
        }
        parts.push(current);
        return parts.filter(piece => piece.trim().length);
      }

      globalThis.__parseEnv = function(text) {
        const out = {};
        for (let line of String(text).split(/\r?\n/)) {
          line = line.trim();
          if (!line || line.startsWith('#')) continue;
          const equals = line.indexOf('=');
          if (equals < 0) continue;
          const key = line.slice(0, equals).trim();
          let value = line.slice(equals + 1).trim();
          if ((value.startsWith('"') && value.endsWith('"') && value.length > 1) ||
              (value.startsWith("'") && value.endsWith("'") && value.length > 1)) {
            value = value.slice(1, -1);
          }
          if (key) out[key] = value;
        }
        return out;
      };

      globalThis.__getCallSites = function(limit) {
        // Built from the stack rather than from V8's structured API, which JSC has no analogue
        // for. The fields are node's; the values come from parsing frames.
        const frames = String(new Error().stack || '').split('\n');
        const sites = [];
        for (const frame of frames) {
          const match = /^\s*(?:at\s+)?([^@(]*)[@(]?(.*?):(\d+):(\d+)\)?\s*$/.exec(frame);
          if (!match) continue;
          const name = match[1].trim();
          if (name === 'globalThis.__getCallSites' || /__getCallSites/.test(frame)) continue;
          sites.push({ functionName: name, scriptName: match[2], scriptId: '0',
                       lineNumber: Number(match[3]), column: Number(match[4]),
                       columnNumber: Number(match[4]) });
          if (typeof limit === 'number' && sites.length >= limit) break;
        }
        return sites;
      };

      // node's `util.diff`: [-1 removed, 0 same, 1 added] over lines or array entries.
      globalThis.__utilDiff = function(actual, expected) {
        const a = Array.isArray(actual) ? actual.map(String) : String(actual).split('');
        const b = Array.isArray(expected) ? expected.map(String) : String(expected).split('');
        // node short-circuits identical input to an EMPTY list rather than a run of unchanged
        // entries — "no difference" is expressed as nothing, not as everything matching.
        if (a.length === b.length && a.every((item, index) => item === b[index])) return [];
        const table = [];
        for (let i = 0; i <= a.length; i++) table.push(new Array(b.length + 1).fill(0));
        for (let i = a.length - 1; i >= 0; i--) {
          for (let j = b.length - 1; j >= 0; j--) {
            table[i][j] = a[i] === b[j] ? table[i + 1][j + 1] + 1
                                        : Math.max(table[i + 1][j], table[i][j + 1]);
          }
        }
        const out = [];
        let i = 0, j = 0;
        while (i < a.length && j < b.length) {
          if (a[i] === b[j]) { out.push([0, a[i]]); i++; j++; }
          else if (table[i + 1][j] >= table[i][j + 1]) { out.push([1, a[i]]); i++; }
          else { out.push([-1, b[j]]); j++; }
        }
        while (i < a.length) out.push([1, a[i++]]);
        while (j < b.length) out.push([-1, b[j++]]);
        return out;
      };

      // A form body is either urlencoded or multipart, and `formData()` reads both. The
      // multipart boundary comes from the Content-Type header rather than the body itself.
      globalThis.__parseFormBody = function(text, headers) {
        const form = new FormData();
        const type = (headers && typeof headers.get === 'function' && headers.get('content-type')) || '';
        const boundaryMatch = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(type);
        if (boundaryMatch) {
          const boundary = '--' + (boundaryMatch[1] || boundaryMatch[2]).trim();
          for (const part of text.split(boundary)) {
            const split = part.indexOf('\r\n\r\n');
            if (split < 0) continue;
            const nameMatch = /name="([^"]*)"/i.exec(part.slice(0, split));
            if (!nameMatch) continue;
            let value = part.slice(split + 4);
            if (value.endsWith('\r\n')) value = value.slice(0, -2);
            form.append(nameMatch[1], value);
          }
          return form;
        }
        for (const pair of new URLSearchParams(text)) form.append(pair[0], pair[1]);
        return form;
      };

      // RFC 7748 X448: a Montgomery ladder over p = 2^448 - 2^224 - 1. The refusal said "X448
      // has no system implementation", which is true of the SYSTEM and says nothing about
      // whether it can be written — the same shape as scrypt, refused as a missing primitive
      // and turning out to be arithmetic nobody had written. JSC's BigInt does the rest.
      globalThis.__x448 = (function(){
        const P = (1n << 448n) - (1n << 224n) - 1n;
        const A24 = 39081n;
        function decodeLE(bytes) {
          let value = 0n;
          for (let i = bytes.length - 1; i >= 0; i--) value = (value << 8n) | BigInt(bytes[i]);
          return value;
        }
        function encodeLE(value) {
          const out = Buffer.alloc(56);
          for (let i = 0; i < 56; i++) { out[i] = Number(value & 0xffn); value >>= 8n; }
          return out;
        }
        function invert(a) {
          let result = 1n, base = ((a % P) + P) % P, e = P - 2n;
          while (e > 0n) { if (e & 1n) result = result * base % P; base = base * base % P; e >>= 1n; }
          return result;
        }
        function scalarMult(scalarBytes, uBytes) {
          const k = Buffer.from(scalarBytes);
          k[0] &= 252; k[55] |= 128;   // RFC 7748 clamping
          const scalar = decodeLE(k);
          const u = decodeLE(uBytes) % P;
          let x1 = u, x2 = 1n, z2 = 0n, x3 = u, z3 = 1n, swap = 0n;
          for (let t = 447; t >= 0; t--) {
            const bit = (scalar >> BigInt(t)) & 1n;
            swap ^= bit;
            if (swap) { let s = x2; x2 = x3; x3 = s; s = z2; z2 = z3; z3 = s; }
            swap = bit;
            const A = (x2 + z2) % P, AA = A * A % P;
            const B = ((x2 - z2) % P + P) % P, BB = B * B % P;
            const E = ((AA - BB) % P + P) % P;
            const C = (x3 + z3) % P, D = ((x3 - z3) % P + P) % P;
            const DA = D * A % P, CB = C * B % P;
            x3 = (DA + CB) % P; x3 = x3 * x3 % P;
            z3 = ((DA - CB) % P + P) % P; z3 = z3 * z3 % P; z3 = x1 * z3 % P;
            x2 = AA * BB % P;
            z2 = E * ((AA + A24 * E) % P) % P;
          }
          if (swap) { let s = x2; x2 = x3; x3 = s; s = z2; z2 = z3; z3 = s; }
          return encodeLE(x2 * invert(z2) % P);
        }
        // The DER wrappers are fixed-shape, like Ed25519's and X25519's — only the OID differs
        // (1.3.101.111).
        const SPKI = Buffer.from('3042300506032b656f033900', 'hex');
        const PKCS8 = Buffer.from('3046020100300506032b656f043a0438', 'hex');
        const BASE = (function(){ const b = Buffer.alloc(56); b[0] = 5; return b; })();
        return {
          generate: function() {
            const secret = cryptoRandom(56);
            const pub = scalarMult(secret, BASE);
            return {
              privateKey: pemWrap(Buffer.concat([PKCS8, secret]), 'PRIVATE KEY'),
              publicKey: pemWrap(Buffer.concat([SPKI, pub]), 'PUBLIC KEY'),
            };
          },
          agree: function(privatePem, publicPem) {
            const priv = pemBody(privatePem);
            const pub = pemBody(publicPem);
            if (!priv || !pub || priv.length !== PKCS8.length + 56 || pub.length !== SPKI.length + 56) return null;
            return scalarMult(priv.slice(PKCS8.length), pub.slice(SPKI.length));
          },
          isPrivate: function(pem) {
            const body = pemBody(pem);
            return !!body && body.length === PKCS8.length + 56 && body.slice(0, PKCS8.length).equals(PKCS8);
          },
          isPublic: function(pem) {
            const body = pemBody(pem);
            return !!body && body.length === SPKI.length + 56 && body.slice(0, SPKI.length).equals(SPKI);
          },
        };
        function cryptoRandom(n) { return Buffer.from(bridge.randomBytes(n), 'base64'); }
        function pemBody(pem) {
          const text = String(pem || '');
          const match = /-----BEGIN [^-]+-----([\s\S]*?)-----END/.exec(text);
          if (!match) return null;
          return Buffer.from(match[1].replace(/\s+/g, ''), 'base64');
        }
        function pemWrap(der, label) {
          const base64 = der.toString('base64').replace(/(.{64})/g, '$1\n');
          return '-----BEGIN ' + label + '-----\n' + base64 + '\n-----END ' + label + '-----\n';
        }
      })();

      globalThis.__toBytes = function(value, encoding) {
        if (Buffer.isBuffer(value)) return value;
        if (ArrayBuffer.isView(value)) {
          return Buffer.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
        }
        if (value instanceof ArrayBuffer) return Buffer.from(new Uint8Array(value));
        return Buffer.from(String(value), encoding && encoding !== 'buffer' ? encoding : 'utf8');
      };
      // TypeScript, compiled by the project's OWN typescript package — the ts-node model, and
      // the only honest one available: type erasure is not a text substitution (enums, decorators,
      // parameter properties, `satisfies`) and a partial stripper would be wrong on real code.
      // Modules are left as ESM so the ordinary ESM→CJS path handles them, which keeps live
      // bindings and every other semantic identical to a .js file's.
      function loadTypeScriptCompiler(fileName) {
        if (globalThis.__tsCompiler === undefined) {
          try { globalThis.__tsCompiler = bridge.createRequire(fileName)('typescript'); }
          catch (error) { globalThis.__tsCompiler = null; }
        }
        return globalThis.__tsCompiler;
      }
      // The project's OWN tsconfig.json, parsed by the project's own typescript — which is the
      // only thing that reads JSON-with-comments and resolves `extends` correctly. A hardcoded
      // set of options is wrong the moment a project sets `jsx`, `target`, or decorators.
      // `module` is forced to ESNext regardless: the ordinary ESM→CJS path takes it from there,
      // so a .ts file gets exactly the semantics a .js file gets.
      function typeScriptConfig(fileName) {
        const compiler = loadTypeScriptCompiler(fileName);
        if (!compiler) return null;
        const fs = __coreModule('fs'), path = __coreModule('path');
        let dir = path.dirname(fileName);
        let configPath = null;
        while (true) {
          const candidate = path.join(dir, 'tsconfig.json');
          if (fs.existsSync(candidate)) { configPath = candidate; break; }
          const parent = path.dirname(dir);
          if (parent === dir) break;
          dir = parent;
        }
        if (globalThis.__tsConfigCache && globalThis.__tsConfigCache.path === configPath) {
          return globalThis.__tsConfigCache.value;
        }
        let value = { options: {}, base: dir };
        if (configPath) {
          try {
            const read = compiler.readConfigFile(configPath, (p) => fs.readFileSync(p, 'utf8'));
            const host = compiler.sys || {
              fileExists: fs.existsSync, readFile: (p) => fs.readFileSync(p, 'utf8'),
              readDirectory: () => [], useCaseSensitiveFileNames: true,
            };
            const parsed = compiler.parseJsonConfigFileContent(read.config || {}, host, path.dirname(configPath));
            value = { options: parsed.options || {}, base: path.dirname(configPath) };
          } catch (error) { value = { options: {}, base: path.dirname(configPath) }; }
        }
        globalThis.__tsConfigCache = { path: configPath, value: value };
        return value;
      }
      // The `paths` map, for the Swift resolver: `@/lib` is not a package and not a path, it is
      // an alias the project declared, and TS projects are full of them.
      globalThis.__tsPathAliases = function(fileName) {
        const config = typeScriptConfig(fileName);
        if (!config || !config.options.paths) return null;
        const path = __coreModule('path');
        const base = config.options.baseUrl || config.base;
        const out = [];
        for (const pattern of Object.keys(config.options.paths)) {
          for (const target of config.options.paths[pattern]) {
            out.push([pattern, path.isAbsolute(target) ? target : path.join(base, target)]);
          }
        }
        return out;
      };
      globalThis.__transpileTypeScript = function(source, fileName) {
        const compiler = loadTypeScriptCompiler(fileName);
        if (!compiler) {
          return { error: "Cannot run '" + fileName + "': TypeScript needs the typescript "
                          + "package, and this project has none installed" };
        }
        const config = typeScriptConfig(fileName) || { options: {} };
        const options = Object.assign({
          target: compiler.ScriptTarget.ES2022,
          jsx: compiler.JsxEmit.ReactJSX,
          esModuleInterop: true,
          useDefineForClassFields: true,
          experimentalDecorators: true,
        }, config.options, {
          module: compiler.ModuleKind.ESNext,
          moduleResolution: compiler.ModuleResolutionKind.Bundler,
          isolatedModules: true,
          verbatimModuleSyntax: false,
          declaration: false,
          noEmit: false,
          // A source map, because erasing types MOVES lines: an interface above a function is
          // four lines that stop existing, and without the map every stack trace in a TypeScript
          // project points that far above the throw.
          sourceMap: true,
          inlineSourceMap: false,
          outDir: undefined,
        });
        const output = compiler.transpileModule(source, {
          fileName: fileName,
          reportDiagnostics: false,
          compilerOptions: options,
        });
        if (output.sourceMapText) rememberSourceMap(fileName, output.sourceMapText);
        return { text: output.outputText };
      };
      // The map, decoded once per file into [generatedLine][segment]. VLQ is base64 with a
      // continuation bit, and its numbers are DELTAS that accumulate across the whole file —
      // which is the part that catches people who decode it segment by segment.
      const SOURCE_MAP_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      globalThis.__rememberSourceMap = function(fileName, text) { rememberSourceMap(fileName, text); };
      function rememberSourceMap(fileName, text) {
        let parsed;
        try { parsed = JSON.parse(text); } catch (error) { return; }
        if (!parsed || typeof parsed.mappings !== 'string') return;
        const lines = [];
        let sourceLine = 0, sourceColumn = 0, sourceIndex = 0;
        for (const group of parsed.mappings.split(';')) {
          const segments = [];
          let generatedColumn = 0;
          for (const piece of group.split(',')) {
            if (!piece) continue;
            const values = [];
            let shift = 0, value = 0;
            for (const character of piece) {
              const digit = SOURCE_MAP_ALPHABET.indexOf(character);
              if (digit < 0) break;
              value += (digit & 31) << shift;
              if (digit & 32) { shift += 5; continue; }
              const negative = value & 1;
              value >>= 1;
              values.push(negative ? -value : value);
              value = 0; shift = 0;
            }
            if (!values.length) continue;
            generatedColumn += values[0];
            if (values.length >= 4) {
              sourceIndex += values[1];
              sourceLine += values[2];
              sourceColumn += values[3];
              // The source INDEX matters as soon as the file is a bundle: one generated line
              // can come from any of a hundred inputs, and a position without its file names
              // the bundle, which is the thing the reader was trying to get out of.
              segments.push([generatedColumn, sourceIndex, sourceLine, sourceColumn]);
            }
          }
          lines.push(segments);
        }
        globalThis.__sourceMaps = globalThis.__sourceMaps || {};
        globalThis.__sourceMaps[fileName] = { lines: lines, sources: parsed.sources || [] };
      }
      /// Where a position in the COMPILED file was written in the source. "line:column", or an
      /// empty string for a file that was never compiled — which is most of them.
      /// "source|line|column" — the source is as the map names it, relative to the compiled
      /// file, and the caller resolves it. Empty for a file that was never compiled.
      globalThis.__mapPosition = function(fileName, line, column) {
        const maps = globalThis.__sourceMaps;
        const map = maps && maps[fileName];
        if (!map) return '';
        const segments = map.lines[line - 1];
        if (!segments || !segments.length) return '';
        let best = segments[0];
        for (const segment of segments) {
          if (segment[0] <= column - 1) best = segment; else break;
        }
        const source = map.sources[best[1]] || '';
        return source + '|' + (best[2] + 1) + '|' + (best[3] + 1);
      };
      globalThis.__esmDefault = function(m) { return m && m.__esModule ? m.default : m; };
      // An imported binding, read now if it can be. If the exporting module is mid-cycle its
      // export is still in TDZ, and real ESM would not have read it yet at all — the read
      // belongs at the USE. A forwarder gives exactly that for the case that occurs in practice
      // (a function called later), and this path is reached ONLY where the alternative is the
      // ReferenceError that a destructure throws today.
      globalThis.__esmBinding = function(module, key) {
        try { return module[key]; }
        catch (error) {
          const forward = function() { return module[key].apply(this, arguments); };
          try { Object.defineProperty(forward, 'name', { value: key, configurable: true }); } catch (ignored) {}
          return forward;
        }
      };
      // An ES module exports BINDINGS, not values: `export let count` seen by an importer
      // changes when the exporter changes it. Assigning at end-of-module made a snapshot, so a
      // mutable export read zero forever and a cycle saw `undefined` where node sees a hoisted
      // function. A getter defined BEFORE the body gives all three: liveness, the hoisted
      // function immediately, and a TDZ throw for a const read too early — which is node's
      // behaviour too. The setter is there because a later plain assignment to the same name
      // (our own passes do it, and so does the odd package) must still win.
      globalThis.__mouseLive = function(exports, name, get) {
        Object.defineProperty(exports, name, {
          get: get,
          set: function(value) {
            Object.defineProperty(exports, name, { value: value, writable: true, enumerable: true, configurable: true });
          },
          enumerable: true, configurable: true
        });
      };
      globalThis.__reexportStar = function(target, source) {
        for (const key of Object.keys(source)) {
          if (key === 'default' || key === '__esModule') continue;
          __mouseLive(target, key, function(){ return source[key]; });
        }
      };
      // `new Function("s", "return import(s)")` — the standard way to keep a dynamic import out
      // of a CommonJS transpile, and what tinypool uses, so vitest's every worker went through
      // it. Source compiled at RUNTIME never passes the loader's rewrite, and JSC's own
      // `import` has no module loader wired to our resolver: "No module loader provided."
      // So the Function constructor rewrites a body that contains one, exactly as the loader
      // would, and `__mouseRequire` exists globally as the referrer such code has no other way
      // to name — rooted at "/", which is what an absolute or bare specifier needs.
      globalThis.__mouseRequire = globalThis.__mouseRequire || bridge.createRequire('/');
      (function(){
        const RealFunction = Function;
        function MouseFunction() {
          const args = Array.prototype.slice.call(arguments);
          const last = args.length - 1;
          if (last >= 0 && typeof args[last] === 'string' && /\bimport\s*\(/.test(args[last])) {
            args[last] = bridge.rewriteImports(args[last]);
          }
          return RealFunction.apply(this, args);
        }
        MouseFunction.prototype = RealFunction.prototype;
        Object.defineProperty(RealFunction.prototype, 'constructor', { value: MouseFunction, writable: true, configurable: true });
        globalThis.Function = MouseFunction;
      })();
      globalThis.__dynamicImport = function(require, specifier) {
        // Promise flattening settles a pending (top-level-await) module before wrapping.
        const load = require.__importCondition || require;
        return Promise.resolve().then(function() { return load(specifier); }).then(function(m) {
          return m && m.__esModule ? m : Object.assign({ default: m }, m);
        });
      };

      // ---- inspect / format (console + util) ----
      // For a terminal IDE this is not cosmetic: console.log output IS what the user reads and
      // what gets pasted into a bug report. A formatting audit against node found Map, Set, Date,
      // RegExp and Promise all printing as `{}` — completely opaque — plus circular references
      // expanded three levels deep instead of marked, no truncation of long collections, class
      // names dropped, and GETTERS EVALUATED (a logger with side effects). Each of those is a
      // debugging session made worse.
      function quoteKey(key) {
        return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(key) ? key : "'" + key + "'";
      }
      function quoteString(text) {
        return "'" + text.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, '\\n') + "'";
      }
      /// node caps a collection at 100 entries and says how many it left out, which keeps a
      /// 10,000-element array from becoming a wall of text.
      function withLimit(items, total) {
        const limit = inspect._maxArrayLength === undefined ? 100 : inspect._maxArrayLength;
        if (total <= limit) return items;
        const left = total - limit;
        return items.slice(0, limit).concat(['... ' + left + ' more item' + (left === 1 ? '' : 's')]);
      }
      /// One line, or one entry per line — node breaks when the single-line form would pass
      /// `breakLength`, and `compact: false` always breaks.
      function joinEntries(open, entries, close, indent) {
        const single = entries.length ? open + ' ' + entries.join(', ') + ' ' + close : open + close;
        const breakLength = inspect._breakLength === undefined ? 128 : inspect._breakLength;
        if (inspect._compact !== false && single.length <= breakLength) return single;
        if (!entries.length) return open + close;
        const padding = '  '.repeat((indent || 0) + 1);
        return open + '\n' + entries.map(function(entry) { return padding + entry; }).join(',\n')
             + '\n' + '  '.repeat(indent || 0) + close;
      }
      function inspect(value, depth, seen) {
        // The outer call reports a cycle with `<ref *1>` so a reader knows the [Circular *1]
        // marker below refers to THIS object rather than something further out.
        if (seen === undefined) {
          inspect._sawCycle = false;
          const text = inspect(value, depth, []);
          return inspect._sawCycle ? '<ref *1> ' + text : text;
        }
        depth = depth === undefined ? 2 : depth;
        if (value === null) return 'null';
        if (value === undefined) return 'undefined';
        const type = typeof value;
        if (type === 'string') return quoteString(value);
        // -0 is not 0, and node shows the difference.
        if (type === 'number') return Object.is(value, -0) ? '-0' : String(value);
        if (type === 'boolean') return String(value);
        if (type === 'bigint') return String(value) + 'n';
        if (type === 'symbol') return String(value);
        if (type === 'function') {
          const isClass = /^class[\s{]/.test(String(value));
          if (isClass) return value.name ? '[class ' + value.name + ']' : '[class (anonymous)]';
          return value.name ? '[Function: ' + value.name + ']' : '[Function (anonymous)]';
        }
        if (value instanceof Error) {
          const stack = value.stack ? String(value.stack) : '';
          // JSC's stack does not begin with "Error: message" the way V8's does, so the header is
          // rebuilt rather than trusted.
          const header = (value.name || 'Error') + (value.message ? ': ' + value.message : '');
          return stack.startsWith(header) ? stack : (stack ? header + '\n    ' + stack.split('\n').join('\n    ') : header);
        }
        if (Buffer.isBuffer(value)) {
          const hex = Array.from(value.subarray(0, 50)).map(b => b.toString(16).padStart(2, '0')).join(' ');
          return '<Buffer ' + hex + (value.length > 50 ? ' ... ' + (value.length - 50) + ' more bytes' : '') + '>';
        }
        if (value instanceof Date) return isNaN(value.getTime()) ? 'Invalid Date' : value.toISOString();
        if (value instanceof RegExp) return String(value);
        // A cycle must be MARKED, not followed: expanding it three levels both misleads and can
        // produce enormous output.
        if (seen.indexOf(value) >= 0) { inspect._sawCycle = true; return '[Circular *1]'; }
        const nested = seen.concat([value]);

        if (Array.isArray(value)) {
          if (depth < 0) return '[Array]';
          const items = [];
          const shown = Math.min(value.length, 100);
          for (let i = 0; i < shown; i++) {
            // A HOLE is not undefined, and node counts consecutive holes together.
            if (!(i in value)) {
              let run = 0;
              while (i + run < shown && !((i + run) in value)) run += 1;
              items.push('<' + run + ' empty item' + (run === 1 ? '' : 's') + '>');
              i += run - 1;
              continue;
            }
            items.push(inspect(value[i], depth - 1, nested));
          }
          // Named properties on an array are shown after its elements.
          for (const key of Object.keys(value)) {
            if (/^\d+$/.test(key)) continue;
            items.push(quoteKey(key) + ': ' + inspect(value[key], depth - 1, nested));
          }
          // The cap is whatever `maxArrayLength` says, not a hardcoded 100 — withLimit knows it,
          // and gating the CALL on 100 meant a smaller cap was never consulted.
          const all = withLimit(items, value.length);
          return joinEntries('[', all, ']', 0);
        }
        if (ArrayBuffer.isView(value)) {
          const name = value.constructor && value.constructor.name || 'TypedArray';
          if (depth < 0) return '[' + name + ']';
          const items = withLimit(Array.from(value.subarray(0, 100)).map(String), value.length);
          return name + '(' + value.length + ') ' + (items.length ? '[ ' + items.join(', ') + ' ]' : '[]');
        }
        if (type === 'object') {
          if (value instanceof Map) {
            if (depth < 0) return '[Map]';
            const items = [];
            let count = 0;
            for (const [key, entry] of value) {
              if (count++ >= 100) break;
              items.push(inspect(key, depth - 1, nested) + ' => ' + inspect(entry, depth - 1, nested));
            }
            const all = withLimit(items, value.size);
            return 'Map(' + value.size + ') ' + (all.length ? '{ ' + all.join(', ') + ' }' : '{}');
          }
          if (value instanceof Set) {
            if (depth < 0) return '[Set]';
            const items = [];
            let count = 0;
            for (const entry of value) {
              if (count++ >= 100) break;
              items.push(inspect(entry, depth - 1, nested));
            }
            const all = withLimit(items, value.size);
            return 'Set(' + value.size + ') ' + (all.length ? '{ ' + all.join(', ') + ' }' : '{}');
          }
          if (typeof Promise === 'function' && value instanceof Promise) return 'Promise { <pending> }';
          if (value instanceof Number) return '[Number: ' + Number.prototype.valueOf.call(value) + ']';
          if (value instanceof String) return "[String: " + quoteString(String.prototype.valueOf.call(value)) + ']';
          if (value instanceof Boolean) return '[Boolean: ' + Boolean.prototype.valueOf.call(value) + ']';
          if (depth < 0) return '[Object]';

          // A class instance carries its constructor's name; a null prototype is called out,
          // because both change what the reader thinks they are looking at.
          const prototype = Object.getPrototypeOf(value);
          let prefix = '';
          if (prototype === null) prefix = '[Object: null prototype] ';
          else {
            const name = prototype.constructor && prototype.constructor.name;
            if (name && name !== 'Object') prefix = name + ' ';
          }
          const items = [];
          for (const key of Object.keys(value)) {
            // A getter is REPORTED, not called: invoking it here can have side effects, and a
            // logger must not change the program it is logging.
            const describe = Object.getOwnPropertyDescriptor(value, key);
            if (describe && describe.get) { items.push(quoteKey(key) + ': [Getter]'); continue; }
            items.push(quoteKey(key) + ': ' + inspect(value[key], depth - 1, nested));
          }
          for (const key of Object.getOwnPropertySymbols(value)) {
            if (!Object.getOwnPropertyDescriptor(value, key).enumerable) continue;
            items.push('[' + String(key) + ']: ' + inspect(value[key], depth - 1, nested));
          }
          return prefix + joinEntries('{', items, '}', 0);
        }
        return String(value);
      }
      function formatOne(value) { return typeof value === 'string' ? value : inspect(value); }
      function format() {
        const args = Array.from(arguments);
        // No substitution arguments means no processing at all: node returns '100%%' unchanged,
        // and only collapses '%%' when it is actually filling in a placeholder. Ours processed a
        // lone string, so `console.log('100%% off')` lost a percent sign.
        if (args.length > 1 && typeof args[0] === 'string' && /%[sdifjoOc%]/.test(args[0])) {
          let i = 1;
          let text = args[0].replace(/%([sdifjoOc%])/g, (match, spec) => {
            if (spec === '%') return '%';
            if (i >= args.length) return match;
            const value = args[i++];
            switch (spec) {
              case 's': return formatOne(value);
              // %d is Number, %i is parseInt — '42.9' prints 42.9 and 42 respectively.
              case 'd': return String(Number(value));
              case 'i': return String(parseInt(value, 10));
              case 'f': return String(parseFloat(value));
              case 'j': return JSON.stringify(value);
              // %c is a CSS hook for a browser's devtools: node CONSUMES the argument and
              // renders nothing, which a terminal has no better answer for either.
              case 'c': return '';
              default: return inspect(value);
            }
          });
          for (; i < args.length; i++) text += ' ' + formatOne(args[i]);
          return text;
        }
        return args.map(formatOne).join(' ');
      }

      // console.Console: a console over any pair of writable streams (ink's patchConsole
      // builds one to intercept logs while it owns the screen). ONE implementation backs both
      // this and the global console — they had drifted apart, and the class's group/count/time
      // were silent no-ops, which is the shape this repo refuses everywhere else.
      //
      // An audit found sixteen methods missing from the global console and `debug` routed to
      // STDERR, where node sends it to stdout. Routing is not cosmetic: a tool piping stdout
      // either loses output or gets noise mixed into its data.
      function makeConsole(writeOut, writeErr) {
        const state = { indent: '', counts: Object.create(null), timers: Object.create(null) };
        // Group indentation applies to every line of every message, including multi-line ones.
        const emit = function(write, text) {
          const prefixed = state.indent
            ? text.split('\n').map(function(line){ return line.length ? state.indent + line : line; }).join('\n')
            : text;
          write(prefixed + '\n');
        };
        const api = {
          log: function(){ emit(writeOut, format.apply(null, arguments)); },
          info: function(){ emit(writeOut, format.apply(null, arguments)); },
          // node's debug is an alias for log, on STDOUT.
          debug: function(){ emit(writeOut, format.apply(null, arguments)); },
          warn: function(){ emit(writeErr, format.apply(null, arguments)); },
          error: function(){ emit(writeErr, format.apply(null, arguments)); },
          trace: function(){ emit(writeErr, 'Trace: ' + format.apply(null, arguments)); },
          dir: function(value, options){ emit(writeOut, inspect(value, options && options.depth !== undefined ? (options.depth === null ? Infinity : options.depth) : 2)); },
          dirxml: function(){ emit(writeOut, format.apply(null, arguments)); },
          group: function() {
            if (arguments.length) emit(writeOut, format.apply(null, arguments));
            state.indent += '  ';
          },
          groupCollapsed: function(){ api.group.apply(null, arguments); },
          groupEnd: function(){ state.indent = state.indent.slice(0, -2); },
          count: function(label) {
            const key = label === undefined ? 'default' : String(label);
            state.counts[key] = (state.counts[key] || 0) + 1;
            emit(writeOut, key + ': ' + state.counts[key]);
          },
          countReset: function(label) {
            const key = label === undefined ? 'default' : String(label);
            delete state.counts[key];
          },
          time: function(label) {
            state.timers[label === undefined ? 'default' : String(label)] = Date.now();
          },
          timeLog: function(label) {
            const key = label === undefined ? 'default' : String(label);
            if (state.timers[key] === undefined) return;
            const rest = Array.prototype.slice.call(arguments, 1);
            emit(writeOut, key + ': ' + (Date.now() - state.timers[key]) + 'ms' +
                           (rest.length ? ' ' + rest.map(formatOne).join(' ') : ''));
          },
          timeEnd: function(label) {
            const key = label === undefined ? 'default' : String(label);
            if (state.timers[key] === undefined) return;
            emit(writeOut, key + ': ' + (Date.now() - state.timers[key]) + 'ms');
            delete state.timers[key];
          },
          assert: function(condition) {
            if (condition) return;
            const rest = Array.prototype.slice.call(arguments, 1);
            emit(writeErr, 'Assertion failed' + (rest.length ? ': ' + format.apply(null, rest) : ''));
          },
          clear: function(){},
          // node keeps these as no-ops without a profiler attached, and says so in its docs —
          // this is the one place a no-op is the correct behaviour rather than a lie.
          profile: function(){}, profileEnd: function(){}, timeStamp: function(){},
          table: function(data, columns) {
            if (data === null || typeof data !== 'object') { api.log(data); return; }
            // node's table: an (index) column, then the union of the rows' keys in first-seen
            // order — or a single "Values" column when the rows are primitives.
            const isArray = Array.isArray(data);
            const keys = isArray ? data.map(function(_, i){ return String(i); }) : Object.keys(data);
            const headers = [];
            let hasValues = false;
            for (const key of keys) {
              const row = data[key];
              if (row !== null && typeof row === 'object' && !Array.isArray(row)) {
                for (const column of Object.keys(row)) {
                  if (headers.indexOf(column) < 0) headers.push(column);
                }
              } else {
                hasValues = true;
              }
            }
            const chosen = columns ? columns.slice() : headers;
            const titles = ['(index)'].concat(chosen).concat(hasValues ? ['Values'] : []);
            const rows = keys.map(function(key) {
              const row = data[key];
              const cells = [key];
              for (const column of chosen) {
                cells.push(row !== null && typeof row === 'object' && column in row
                  ? inspect(row[column], 2) : '');
              }
              if (hasValues) {
                cells.push(row !== null && typeof row === 'object' && !Array.isArray(row)
                  ? '' : inspect(row, 2));
              }
              return cells;
            });
            const widths = titles.map(function(title, i) {
              return rows.reduce(function(width, cells) {
                return Math.max(width, cells[i] ? cells[i].length : 0);
              }, title.length);
            });
            const line = function(left, middle, right) {
              return left + widths.map(function(w){ return '─'.repeat(w + 2); }).join(middle) + right;
            };
            const rowText = function(cells) {
              return '│' + cells.map(function(cell, i) {
                return ' ' + (cell || '') + ' '.repeat(widths[i] - (cell ? cell.length : 0)) + ' ';
              }).join('│') + '│';
            };
            const lines = [line('┌', '┬', '┐'), rowText(titles), line('├', '┼', '┤')];
            for (const cells of rows) lines.push(rowText(cells));
            lines.push(line('└', '┴', '┘'));
            emit(writeOut, lines.join('\n'));
          },
        };
        return api;
      }
      function Console(stdout, stderr) {
        if (stdout && stdout.stdout) { stderr = stdout.stderr; stdout = stdout.stdout; }
        const errStream = stderr || stdout;
        const api = makeConsole(function(text){ stdout.write(text); },
                                function(text){ errStream.write(text); });
        for (const name of Object.keys(api)) this[name] = api[name];
      }
      globalThis.console = makeConsole(function(text){ bridge.stdout(text); },
                                       function(text){ bridge.stderr(text); });
      globalThis.console.Console = Console;

      // ---- process ----
      const tickQueue = [];
      globalThis.__drainTicks = function() {
        while (tickQueue.length) {
          const [fn, args] = tickQueue.shift();
          fn.apply(null, args);
        }
      };
      // Every host-invoked callback goes through here, and the reason is subtle: nextTick rides
      // the microtask queue below (there is no other way to schedule from JS), so it only beat a
      // promise when it happened to be registered first. Node's rule is absolute — the whole
      // nextTick queue drains before ANY promise reaction. Draining here, before the stack
      // unwinds to the host, is what makes that true: JSC only drains microtasks once the
      // outermost JS frame returns, so ticks queued inside a callback run first either way round.
      globalThis.__invoke = function(fn, args) {
        try { return fn.apply(null, args || []); }
        finally { globalThis.__drainTicks(); }
      };
      // For host callbacks the loop does not invoke itself. A bridge that calls JavaScript from
      // its own handler (dns completions, watch events) wraps the callback ONCE here, at
      // registration, so the handler can call it without knowing any of this.
      // Every API that takes an AbortSignal needs the same three things: the error node raises,
      // a way to notice an already-aborted signal, and a listener for a later abort. A class
      // sweep found EIGHT places that accepted a signal and ignored it — five of them turning a
      // cancellable wait into a permanent one — so this exists once rather than eight times.
      globalThis.__abortError = function() {
        const error = new Error('The operation was aborted');
        error.name = 'AbortError';
        error.code = 'ABORT_ERR';
        return error;
      };
      globalThis.__onAbort = function(signal, handler) {
        if (!signal) return function(){};
        if (signal.aborted) { handler(); return function(){}; }
        if (typeof signal.addEventListener === 'function') {
          signal.addEventListener('abort', handler);
          return function(){ if (signal.removeEventListener) signal.removeEventListener('abort', handler); };
        }
        if (typeof signal.once === 'function') {
          signal.once('abort', handler);
          return function(){ if (signal.off) signal.off('abort', handler); };
        }
        return function(){};
      };
      globalThis.__wrapInvoke = function(fn) {
        return function() {
          return globalThis.__invoke(fn, Array.prototype.slice.call(arguments));
        };
      };
      // ---- stdio streams (real TTY semantics when the host attached one) ----
      const signalHandlers = { SIGINT: [], SIGTERM: [], SIGWINCH: [] };
      // Non-signal process events ('warning', 'exit', 'beforeExit', …): registered and
      // introspectable; the host emits what it can.
      const processEvents = {};
      function makeOutputStream(sink, descriptor) {
        const listeners = {};
        const stream = {
          // Present on every other Writable here; a caller that guards on them should not have to
          // special-case stdout.
          destroy: function(){ this.destroyed = true; return this; },
          setDefaultEncoding: function(encoding){ this._defaultEncoding = String(encoding); return this; },
          destroyed: false,
          write: function(chunk, encoding, callback) {
            // Binary out through latin1 when this is a pipe: `Buffer.from(chunk).toString()`
            // is a UTF-8 decode, and it silently mangles every byte above 0x7f.
            sink(typeof chunk === 'string'
              ? (__stdioBinary ? Buffer.from(chunk, encoding && encoding !== 'buffer' ? encoding : 'utf8').toString('latin1') : chunk)
              : Buffer.from(chunk).toString(__stdioBinary ? 'latin1' : 'utf8'));
            if (typeof encoding === 'function') encoding();
            else if (typeof callback === 'function') callback();
            return true;
          },
          on: function(event, handler){ (listeners[event] = listeners[event] || []).push(handler); return this; },
          addListener: function(event, handler){ return this.on(event, handler); },
          once: function(event, handler){ return this.on(event, handler); },
          off: function(event, handler){
            const list = listeners[event] || [];
            const index = list.indexOf(handler);
            if (index >= 0) list.splice(index, 1);
            return this;
          },
          removeListener: function(event, handler){ return this.off(event, handler); },
          listenerCount: function(event){ return (listeners[event] || []).length; },
          setMaxListeners: function(){ return this; },
          emit: function(event){
            const args = Array.prototype.slice.call(arguments, 1);
            for (const handler of listeners[event] || []) handler.apply(null, args);
            return true;
          },
          end: function(){}, cork: function(){}, uncork: function(){},
          getColorDepth: function(){ return __isTTY ? 8 : 1; },
          hasColors: function(){ return __isTTY; },
          // TTY WriteStream cursor helpers (readline uses these on stdout; spinners/progress
          // bars — ora, cli-progress — call them directly). Each writes the CSI escape.
          cursorTo: function(x, y, callback){
            sink(y === undefined || y === null ? '\u001b[' + (x + 1) + 'G' : '\u001b[' + (y + 1) + ';' + (x + 1) + 'H');
            if (typeof y === 'function') y(); else if (typeof callback === 'function') callback();
            return true;
          },
          moveCursor: function(dx, dy, callback){
            let out = '';
            if (dx < 0) out += '\u001b[' + (-dx) + 'D'; else if (dx > 0) out += '\u001b[' + dx + 'C';
            if (dy < 0) out += '\u001b[' + (-dy) + 'A'; else if (dy > 0) out += '\u001b[' + dy + 'B';
            sink(out);
            if (typeof callback === 'function') callback();
            return true;
          },
          clearLine: function(dir, callback){
            sink(dir < 0 ? '\u001b[1K' : dir > 0 ? '\u001b[0K' : '\u001b[2K');
            if (typeof callback === 'function') callback();
            return true;
          },
          clearScreenDown: function(callback){
            sink('\u001b[0J');
            if (typeof callback === 'function') callback();
            return true;
          },
        };
        // node DEFINES isTTY/columns/rows only when the stream really is a terminal; when
        // output is a pipe or a file the properties are absent, not false. Both are falsy, so
        // `if (stream.isTTY)` behaves the same either way — but `'columns' in stream` does not,
        // and that is the check a layout-aware writer makes.
        Object.defineProperty(stream, 'fd', { value: descriptor, enumerable: true, configurable: true });
        if (!('writable' in stream)) stream.writable = true;
        if (!('readable' in stream)) stream.readable = false;
        if (__isTTY) {
          stream.isTTY = true;
          stream.columns = __ttyColumns;
          stream.rows = __ttyRows;
        }
        return stream;
      }
      function makeInputStream() {
        const listeners = {};
        let paused = false;
        let buffered = __stdin;
        // Piped stdin ENDS. node's emits 'end' when the writer closes the pipe, and without an
        // interactive terminal there is no writer here — so the seeded text is all there will
        // ever be. Leaving it open meant `for await (const chunk of process.stdin)` waited
        // forever for an EOF that could not arrive, and a program reading piped input produced
        // nothing at all. A live TTY is the opposite case: more can always come.
        const pipedStdinIsComplete = !!__stdinIsComplete;
        // A TTY with someone listening keeps the process alive, like node's ref'd stdin —
        // without this the event loop would see quiescence and end a program mid-wait.
        function updateLiveness() {
          // A pipe counts as much as a terminal here: a child waiting on stdin must keep its
          // loop alive, or it exits the moment it starts listening.
          if ((!__isTTY && !__stdioBinary) || !bridge.stdinActive) return;
          const listening = ['data', 'readable', 'keypress'].some(function(e){ return (listeners[e] || []).length; });
          bridge.stdinActive(listening && !paused);
        }
        const stream = {
          isTTY: __isTTY,
          isRaw: false,
          _encoding: null,
          setEncoding: function(value){ stream._encoding = value; return this; },
          setRawMode: function(raw){
            stream.isRaw = !!raw;
            if (bridge.setRawMode) bridge.setRawMode(!!raw);
            return this;
          },
          on: function(event, handler){
            (listeners[event] = listeners[event] || []).push(handler);
            // Piped stdin arrives once, like a closed pipe; a TTY streams as keys are typed.
            if (!__isTTY && event === 'data' && buffered.length) {
              const payload = buffered;
              buffered = '';
              setImmediate(function(){ stream.emit('data', stream._encoding ? payload : Buffer.from(payload)); });
              setImmediate(function(){ stream.emit('end'); });
            }
            updateLiveness();
            return this;
          },
          addListener: function(event, handler){ return this.on(event, handler); },
          prependListener: function(event, handler){
            (listeners[event] = listeners[event] || []).unshift(handler);
            updateLiveness();
            return this;
          },
          once: function(event, handler){ return this.on(event, handler); },
          off: function(event, handler){
            const list = listeners[event] || [];
            const index = list.indexOf(handler);
            if (index >= 0) list.splice(index, 1);
            updateLiveness();
            return this;
          },
          removeListener: function(event, handler){ return this.off(event, handler); },
          setMaxListeners: function(){ return this; },
          removeAllListeners: function(event){ if (event) delete listeners[event]; else for (const k of Object.keys(listeners)) delete listeners[k]; updateLiveness(); return this; },
          listenerCount: function(event){ return (listeners[event] || []).length; },
          emit: function(event){
            const args = Array.prototype.slice.call(arguments, 1);
            for (const handler of (listeners[event] || []).slice()) handler.apply(null, args);
            return true;
          },
          resume: function(){ paused = false; updateLiveness(); return this; },
          pause: function(){ paused = true; updateLiveness(); return this; },
          isPaused: function(){ return paused; },
          destroy: function(){ paused = true; stream.emit('close'); return this; },
          unpipe: function(){ return this; },
          get readableFlowing(){ return !paused; },
          get readable(){ return true; },
          read: function(){
            const value = buffered;
            buffered = '';
            if (!value.length) return null;
            return stream._encoding ? value : Buffer.from(value, __stdioBinary ? 'latin1' : 'utf8');
          },
          // A keystroke from the host: flowing listeners get 'data'; paused-mode consumers
          // (ink reads via 'readable' + read()) get the buffer filled and a 'readable' poke.
          _push: function(text){
            // The same transport in reverse: a pipe's bytes arrived as latin1.
            const asBuffer = function(value) { return Buffer.from(value, __stdioBinary ? 'latin1' : 'utf8'); };
            if ((listeners['data'] || []).length) {
              stream.emit('data', stream._encoding ? text : asBuffer(text));
              if ((listeners['readable'] || []).length) { buffered += text; stream.emit('readable'); }
            } else {
              buffered += text;
              stream.emit('readable');
            }
          },
          pipe: function(destination){ stream.on('data', c => destination.write(c)); return destination; },
          // `for await (const chunk of process.stdin)` is how a modern CLI reads piped input, and
          // it THREW here — stdin is hand-rolled rather than a real Readable, so it never gained
          // the iterator the stream classes have. A contract sweep across every stream-like
          // object the engine hands out is what surfaced it.
          [Symbol.asyncIterator]: function() {
            const self = this;
            return {
              next() {
                return new Promise(function(resolve, reject) {
                  if (buffered.length) {
                    const chunk = buffered;
                    buffered = '';
                    resolve({ value: __stdioBinary ? Buffer.from(chunk, 'latin1') : chunk, done: false });
                    return;
                  }
                  // Drained, and nothing more can come: a pipe with no writer is finished.
                  if (stream._ended || pipedStdinIsComplete) { resolve({ value: undefined, done: true }); return; }
                  const onData = function(chunk) { cleanup(); resolve({ value: chunk, done: false }); };
                  const onEnd = function() { cleanup(); resolve({ value: undefined, done: true }); };
                  const onError = function(error) { cleanup(); reject(error); };
                  const cleanup = function() {
                    stream.off('data', onData); stream.off('end', onEnd); stream.off('error', onError);
                  };
                  stream.on('data', onData); stream.on('end', onEnd); stream.on('error', onError);
                  if (stream.resume) stream.resume();
                });
              },
              return() { return Promise.resolve({ value: undefined, done: true }); },
              [Symbol.asyncIterator]() { return this; },
            };
          },
          push: function(chunk) {
            if (chunk === null) { stream._ended = true; stream.emit('end'); return false; }
            stream._push(Buffer.isBuffer(chunk) ? chunk.toString(__stdioBinary ? 'latin1' : 'utf8')
                                                : String(chunk));
            return true;
          },
          // Anything a synchronous reader could not take goes back to the front of the buffer.
          unshift: function(chunk){
            buffered = (Buffer.isBuffer(chunk) ? chunk.toString(__stdioBinary ? 'latin1' : 'utf8') : String(chunk)) + buffered;
          },
          _ended: false,
          unref: function(){ return this; }, ref: function(){ return this; },
        };
        if (pipedStdinIsComplete) {
          // Deliver what was piped, then END — which is what a closed pipe does in node, and what
          // `.on('end')` and `for await` both wait for.
          const flush = function() {
            if (!(listeners['data'] || []).length && !(listeners['end'] || []).length) return;
            if (buffered.length) {
              const chunk = buffered;
              buffered = '';
              stream.emit('data', __stdioBinary ? Buffer.from(chunk, 'latin1') : Buffer.from(chunk));
            }
            if (!stream._ended) { stream._ended = true; stream.emit('end'); }
          };
          const originalOn = stream.on;
          stream.on = function(event, handler) {
            const result = originalOn.call(this, event, handler);
            if (event === 'data' || event === 'end') process.nextTick(flush);
            return result;
          };
        }
        // node 17+'s operators, DELEGATED to the one implementation on Readable.prototype rather
        // than copied — copies are exactly how these two stream families drifted apart. Resolved
        // lazily because the stream module is built after stdio.
        for (const name of ['map', 'filter', 'flatMap', 'take', 'drop', 'forEach', 'toArray',
                            'reduce', 'some', 'every', 'find', 'iterator']) {
          stream[name] = function() {
            const shared = coreRequire('stream').Readable.prototype;
            return shared[name].apply(this, arguments);
          };
        }
        // `readable`/`writable` may already be accessors on these objects, and assigning over
        // an accessor without a setter throws. Only fill what is genuinely absent.
        Object.defineProperty(stream, 'fd', { value: 0, enumerable: true, configurable: true });
        if (!('readable' in stream)) stream.readable = true;
        if (!('writable' in stream)) stream.writable = false;
        return stream;
      }

      // Host → JS: one keystroke, delivered as data — never a signal. The host owns the
      // terminal discipline: cooked-mode ^C arrives via __mouseSigint instead.
      globalThis.__mouseDeliverInput = function(text) {
        process.stdin._push(text);
      };
      globalThis.__mouseEndInput = function() {
        process.stdin._ended = true;
        // EOF on stdin: a child reading to completion ends here, which is what `child.stdin.end()`
        // means on the other side of the pipe.
        if (process.stdin.push) process.stdin.push(null);
        process.stdin.emit('end');
      };
      globalThis.__mouseResize = function(rows, columns) {
        process.stdout.rows = rows; process.stdout.columns = columns;
        process.stderr.rows = rows; process.stderr.columns = columns;
        process.stdout.emit('resize');
        for (const handler of signalHandlers.SIGWINCH.slice()) handler('SIGWINCH');
      };
      /// Returns true when the program handles SIGINT itself (the host then leaves it running).
      globalThis.__mouseSigint = function() {
        if (!signalHandlers.SIGINT.length) return false;
        for (const handler of signalHandlers.SIGINT.slice()) handler('SIGINT');
        return true;
      };
      // The host routes an uncaught synchronous exception here. Returns true when a
      // 'uncaughtException' handler ran (node then does NOT exit 1); false means unhandled.
      // JSC calls this with (promise, reason) once a rejection reaches a microtask checkpoint
      // with no handler attached. node's precedence: an 'unhandledRejection' listener gets first
      // refusal and suppresses the exit; with no listener the rejection is fatal.
      //
      // A rejection handled LATER (in a timer, say) is still fatal — node decides at the end of
      // the turn, and so does this.
      globalThis.__mouseOnUnhandledRejection = function(promise, reason) {
        const handlers = processEvents.unhandledRejection;
        if (handlers && handlers.length) {
          for (const handler of handlers.slice()) handler(reason, promise);
          return;
        }
        let text;
        if (reason instanceof Error) {
          const stack = reason.stack;
          text = stack && String(stack).indexOf(reason.message) >= 0
            ? String(stack) : String(reason) + (stack ? '\n' + stack : '');
        } else {
          // node wraps a non-Error rejection rather than printing it bare.
          text = 'UnhandledPromiseRejection: This error originated either by throwing inside of ' +
                 'an async function without a catch block, or by rejecting a promise which was ' +
                 'not handled with .catch(). The promise rejected with the reason "' +
                 String(reason) + '".';
        }
        bridge.unhandledRejection(text);
      };

      // `beforeExit` fires when the loop has emptied but the process has NOT been told to
      // exit — a handler may schedule more work, and node will then drain again and re-emit.
      // It does not fire when `process.exit()` was called explicitly.
      globalThis.__mouseEmitBeforeExit = function(code) {
        const handlers = processEvents.beforeExit;
        if (!handlers || !handlers.length) return false;
        for (const handler of handlers.slice()) handler(code);
        return true;
      };
      // `exit` is the last thing that runs, synchronously, for every kind of exit. It is where
      // cleanup lives — flushing a log, writing coverage, removing a lockfile — so a process
      // that never emits it silently skips all of that.
      globalThis.__mouseEmitExit = function(code) {
        const handlers = processEvents.exit;
        if (!handlers || !handlers.length) return false;
        for (const handler of handlers.slice()) handler(code);
        return true;
      };
      globalThis.__mouseEmitUncaught = function(error) {
        // node runs the MONITOR first, always, and it cannot swallow the error — that is the
        // point of it: an error reporter observes every uncaught exception without changing
        // whether the process dies.
        const monitors = processEvents.uncaughtExceptionMonitor;
        if (monitors && monitors.length) {
          // A throwing monitor is NOT contained — node lets it propagate, and swallowing it
          // here would hide a broken error reporter behind the error it was reporting.
          for (const monitor of monitors.slice()) monitor(error, 'uncaughtException');
        }
        const handlers = processEvents.uncaughtException;
        if (!handlers || !handlers.length) return false;
        for (const handler of handlers.slice()) handler(error, 'uncaughtException');
        return true;
      };

      const process = {
        argv: __argv.slice(),
        env: Object.assign({}, __env),
        platform: 'darwin',
        arch: 'arm64',
        version: 'v20.19.0',
        versions: { node: '20.19.0', mouse: '1.0.0' },
        pid: 1,
        ppid: 0,
        execArgv: [],
        execPath: '/usr/local/bin/node',
        title: 'node',
        connected: false,
        allowedNodeEnvironmentFlags: new Set(),
        getuid: function(){ return 501; },
        getgid: function(){ return 20; },
        geteuid: function(){ return 501; },
        getegid: function(){ return 20; },
        umask: function(){ return 0o022; },
        cpuUsage: function(previous){
          const now = bridge.cpuUsage();
          const current = { user: Math.round(now.user), system: Math.round(now.system) };
          if (!previous) return current;
          return { user: current.user - previous.user, system: current.system - previous.system };
        },
        resourceUsage: function(){ return { userCPUTime: 0, systemCPUTime: 0, maxRSS: 0 }; },
        availableParallelism: function(){ return 1; },
        hasUncaughtExceptionCaptureCallback: function(){ return false; },
        setUncaughtExceptionCaptureCallback: function(){},
        report: { getReport: function(){ return {}; } },
        release: { name: 'node' },
        features: { inspector: false, tls: true },
        channel: undefined,
        send: undefined,
        disconnect: undefined,
        title: 'node',
        cwd: function(){ return __cwd; },
        chdir: function(){ throw new Error('process.chdir is not supported'); },
        // A bare `process.exit()` adopts whatever `process.exitCode` holds; only an explicit
        // argument overrides it.
        exit: function(code){
          if (code === undefined) {
            const recorded = process.exitCode;
            code = (recorded === undefined || recorded === null) ? 0 : recorded;
          }
          bridge.exit(code | 0);
          throw new Error('__mouse_exit__');
        },
        exitCode: undefined,
        nextTick: function(fn){
          tickQueue.push([fn, Array.prototype.slice.call(arguments, 1)]);
          // The tick queue outranks promise reactions: riding the FIRST microtask slot
          // preserves node's tick-before-promise ordering.
          if (tickQueue.length === 1) Promise.resolve().then(globalThis.__drainTicks);
        },
        // hrtime is a function that also CARRIES a `bigint` property. eslint destructures
        // `process.hrtime.bigint` and calls it unbound, so neither form may depend on `this`.
        hrtime: (function(){
          function nanos(){ return BigInt(bridge.monotonicNanos()); }
          const hrtime = function(prev){
            const total = nanos();
            let seconds = Number(total / 1000000000n), rest = Number(total % 1000000000n);
            if (prev) {
              seconds -= prev[0]; rest -= prev[1];
              // Borrow, so a smaller nanosecond field never surfaces as a negative component.
              if (rest < 0) { rest += 1000000000; seconds -= 1; }
            }
            return [seconds, rest];
          };
          hrtime.bigint = nanos;
          return hrtime;
        })(),
        memoryUsage: function(){ return { rss: 0, heapTotal: 0, heapUsed: 0, external: 0 }; },
        // Found by auditing process against real node's keys. `uptime` is the one packages
        // actually call (loggers, benchmarks, health endpoints); the rest are here so a
        // feature check does not read undefined and conclude something false.
        uptime: function(){ return (Date.now() - globalThis.hrtimeBase) / 1000; },
        // Named by the module-surface audit. The rest of what it lists for `process` is
        // underscore-prefixed node internals, which stay out deliberately.
        threadCpuUsage: function(previous) {
          // One engine per thread here, so a thread's CPU time IS the process's.
          const now = process.cpuUsage();
          if (!previous) return now;
          return { user: now.user - previous.user, system: now.system - previous.system };
        },
        // `process.assert` is deprecated in node but still present, and still throws.
        assert: function(value, message) {
          if (value) return;
          throw new Error(message === undefined ? 'AssertionError' : String(message));
        },
        finalization: (function(){
          // node's finalization registry ties a callback to an object's collection. JSC exposes
          // no FinalizationRegistry hook that fires deterministically here, so `register` keeps
          // the association without pretending the callback will run at collection time —
          // `registerBeforeExit` is the half that CAN be honoured exactly, and is the half
          // callers actually rely on for cleanup.
          const beforeExit = new Map();
          return {
            register: function(target, callback) { beforeExit.set(target, callback); },
            registerBeforeExit: function(target, callback) {
              beforeExit.set(target, callback);
              process.once('beforeExit', function(){
                const fn = beforeExit.get(target);
                if (fn) fn(target, 'beforeExit');
              });
            },
            unregister: function(target) { beforeExit.delete(target); },
          };
        })(),
        // Refusals with true reasons rather than silence.
        dlopen: function() {
          const error = new Error('process.dlopen is not available: a .node addon is compiled ' +
                                  'machine code, and iOS will not map new executable pages');
          error.code = 'ERR_DLOPEN_FAILED';
          throw error;
        },
        execve: function() {
          const error = new Error('process.execve is not available: iOS has no exec — a process ' +
                                  'cannot replace its own image, which is why child processes ' +
                                  'here are engines rather than fork/exec');
          error.code = 'ERR_METHOD_NOT_IMPLEMENTED';
          throw error;
        },
        emitWarning: function(warning, type, code) {
          const text = warning instanceof Error ? warning.message : String(warning);
          let options = null;
          if (type && typeof type === 'object') { options = type; type = options.type; code = options.code; }
          const label = (typeof type === 'string' ? type : 'Warning');
          // node EMITS a 'warning' event carrying a real Error, and only prints to stderr when
          // nobody is listening. Tooling attaches here to route or suppress warnings, and this
          // had been printing unconditionally while the event never fired at all.
          const error = warning instanceof Error ? warning : new Error(text);
          error.name = warning instanceof Error && type === undefined ? error.name : label;
          if (code !== undefined) error.code = code;
          if (options && options.detail !== undefined) error.detail = options.detail;
          // node emits AND prints: a listener observes warnings, it does not suppress them
          // (that is what --no-warnings is for). Emitting instead of printing would have made
          // every warning invisible to anyone who attached a listener to read them.
          const handlers = processEvents.warning;
          if (handlers && handlers.length) {
            for (const handler of handlers.slice()) handler(error);
          }
          process.stderr.write('(mouse:' + process.pid + ') ' +
            (code !== undefined ? '[' + code + '] ' : '') + label + ': ' + text + '\n');
        },
        argv0: 'node',
        // No process table to signal into: only this process exists, and killing it is what
        // exit() is for.
        kill: function(pid, signal) {
          if (Number(pid) === process.pid && (signal === 'SIGKILL' || signal === 'SIGTERM' || signal === undefined)) {
            process.exit(signal === 'SIGKILL' ? 137 : 143);
            return true;
          }
          const error = new Error('kill ESRCH: there is no other process on this device');
          error.code = 'ESRCH';
          throw error;
        },
        abort: function(){ process.exit(134); },
        reallyExit: function(code){ process.exit(code || 0); },
        getActiveResourcesInfo: function(){ return []; },
        // node 20's .env reader. Small, and it saves a dependency for anything that wants one.
        loadEnvFile: function(file) {
          const fs = coreRequire('fs');   // `require` is per-module; the bootstrap has coreRequire
          const text = fs.readFileSync(file === undefined ? '.env' : file, 'utf8');
          for (const line of String(text).split('\n')) {
            const trimmed = line.trim();
            if (!trimmed || trimmed[0] === '#') continue;
            const at = trimmed.indexOf('=');
            if (at < 0) continue;
            const name = trimmed.slice(0, at).trim();
            let value = trimmed.slice(at + 1).trim();
            if ((value[0] === '"' && value.endsWith('"')) || (value[0] === "'" && value.endsWith("'"))) {
              value = value.slice(1, -1);
            }
            if (process.env[name] === undefined) process.env[name] = value;
          }
        },
        openStdin: function(){ return process.stdin; },
        // Privilege changes in a single-user sandbox: there is no other user to become.
        setuid: function(){ throw refusal('setuid'); },
        setgid: function(){ throw refusal('setgid'); },
        seteuid: function(){ throw refusal('seteuid'); },
        setegid: function(){ throw refusal('setegid'); },
        setgroups: function(){ throw refusal('setgroups'); },
        initgroups: function(){ throw refusal('initgroups'); },
        getgroups: function(){ return []; },
        availableMemory: function(){ return 0; },
        constrainedMemory: function(){ return 0; },
        ref: function(){}, unref: function(){},
        setSourceMapsEnabled: function(){},
        sourceMapsEnabled: false,
        getBuiltinModule: function(name) {
          try { return coreRequire(String(name).replace(/^node:/, '')); } catch (error) { return undefined; }
        },
        mainModule: undefined,
        moduleLoadList: [],
        debugPort: 0,
        config: { target_defaults: {}, variables: {} },
        _exiting: false,
        _events: {},
        _eventsCount: 0,
        on: function(event, handler){
          const bucket = signalHandlers[event] || (processEvents[event] = processEvents[event] || []);
          bucket.push(handler);
          return process;
        },
        addListener: function(event, handler){ return process.on(event, handler); },
        prependListener: function(event, handler){
          const bucket = signalHandlers[event] || (processEvents[event] = processEvents[event] || []);
          bucket.unshift(handler);
          return process;
        },
        once: function(event, handler){ return process.on(event, handler); },
        // The public EventEmitter surface was one method short: node has this and code that
        // wants to run BEFORE existing handlers, exactly once, has nowhere else to go.
        prependOnceListener: function(event, handler){
          const wrapper = function(){
            process.off(event, wrapper);
            return handler.apply(this, arguments);
          };
          return process.prependListener(event, wrapper);
        },
        off: function(event, handler){
          const list = signalHandlers[event] || processEvents[event];
          if (list) { const i = list.indexOf(handler); if (i >= 0) list.splice(i, 1); }
          return process;
        },
        removeListener: function(event, handler){ return process.off(event, handler); },
        removeAllListeners: function(event){
          if (event === undefined) { for (const k of Object.keys(processEvents)) delete processEvents[k]; }
          else if (signalHandlers[event]) signalHandlers[event].length = 0;
          else delete processEvents[event];
          return process;
        },
        listeners: function(event){ return (signalHandlers[event] || processEvents[event] || []).slice(); },
        rawListeners: function(event){ return process.listeners(event); },
        listenerCount: function(event){ return (signalHandlers[event] || processEvents[event] || []).length; },
        eventNames: function(){
          return Object.keys(processEvents).concat(Object.keys(signalHandlers).filter(k => signalHandlers[k].length));
        },
        setMaxListeners: function(){ return process; },
        getMaxListeners: function(){ return Infinity; },
        emit: function(event){
          const args = Array.prototype.slice.call(arguments, 1);
          const list = (signalHandlers[event] || processEvents[event] || []).slice();
          for (const handler of list) handler.apply(process, args);
          return list.length > 0;
        },
        stdout: makeOutputStream(bridge.stdout, 1),
        stderr: makeOutputStream(bridge.stderr, 2),
        stdin: makeInputStream(),
      };
      function refusal(name) {
        const error = new Error('process.' + name + ' is not available: this is a single-user sandbox, there is no other user to become');
        error.code = 'EPERM';
        return error;
      }
      globalThis.process = process;
      // An uncaught throw inside a worker reached the parent as nothing but exit code 1 — the
      // message and stack were lost, so the parent knew a worker had died and not why. Reported
      // over the channel and then exited at once: deferring the exit so the send can "flush" is
      // what hangs, because the open channel is itself what holds the loop open.
      //
      // Installed HERE rather than in the worker_threads factory, which only runs if the worker
      // happens to import that module — and a worker that throws on its first line never does.
      if (__isWorker) {
        process.on('uncaughtException', function(error) {
          try {
            process.send({ __mouseWorkerError: {
              message: error && error.message !== undefined ? String(error.message) : String(error),
              name: error && error.name ? String(error.name) : 'Error',
              stack: error && error.stack ? String(error.stack) : undefined,
              code: error && error.code,
            } });
          } catch (ignored) { /* the channel is already gone */ }
          process.exit(1);
        });
      }
      // A forked child's channel. `process.send` is left UNDEFINED without one, because
      // `if (process.send)` is how a program asks whether it was forked — defining a stub would
      // make every worker library take its IPC path and then talk into nothing.
      if (__hasIPC) {
        // A 'message' listener is what says more work may arrive, so it — and not the channel's
        // existence — is what holds the loop open. node behaves this way: a forked child that
        // sends a result and listens for nothing exits on its own.
        (function(){
          const counted = function(){ bridge.ipcHold(process.listenerCount('message') > 0); };
          for (const method of ['on', 'addListener', 'once', 'prependListener', 'prependOnceListener']) {
            const original = process[method].bind(process);
            process[method] = function(event, handler) {
              const result = original(event, handler);
              if (event === 'message') counted();
              return result;
            };
          }
          for (const method of ['off', 'removeListener', 'removeAllListeners']) {
            const original = process[method].bind(process);
            process[method] = function(event, handler) {
              const result = original(event, handler);
              if (event === 'message' || event === undefined) counted();
              return result;
            };
          }
        })();
        process.send = function(message, sendHandle, options, callback) {
          const done = typeof callback === 'function' ? callback
                     : (typeof options === 'function' ? options
                     : (typeof sendHandle === 'function' ? sendHandle : null));
          // A WORKER's channel is not child_process IPC: worker_threads is defined in terms
          // of the structured clone algorithm and has no json mode, so a Map posted back from a
          // worker stays a Map. Only the fork channel takes the mode from the parent.
          const advanced = __isWorker
            || String(__env.__MOUSE_IPC_SERIALIZATION || '') === 'advanced';
          bridge.ipcSend(globalThis.__cloneEncode(
            globalThis.__ipcPrepare(message === undefined ? null : message, advanced)));
          if (done) process.nextTick(function(){ done(null); });
          return true;
        };
        process.connected = true;
        process.disconnect = function() {
          process.connected = false;
          bridge.ipcDisconnect();
          for (const handler of (processEvents.disconnect || []).slice()) handler();
        };
        process.channel = { ref: function(){}, unref: function(){} };
      }
      globalThis.__mouseDeliverMessage = function(json) {
        let message = null;
        try { message = globalThis.__cloneDecode(json); } catch (error) { message = json; }
        for (const handler of (processEvents.message || []).slice()) handler(message);
      };

      globalThis.hrtimeBase = Date.now();

      // ---- timers ----
      // Node returns Timeout OBJECTS (unref/ref chainable), not bare ids — CLIs call
      // .unref() on watchdogs. Primitive coercion keeps old-style numeric use working.
      function makeTimeout(id) {
        return {
          _id: id,
          unref: function(){ return this; },
          ref: function(){ return this; },
          hasRef: function(){ return true; },
          refresh: function(){ return this; },
          close: function(){ bridge.clearTimer(id); return this; },
          [Symbol.toPrimitive]: function(){ return id; },
        };
      }
      globalThis.setTimeout = function(fn, delay){
        return makeTimeout(bridge.setTimer(fn, delay || 0, false, Array.prototype.slice.call(arguments, 2)));
      };
      globalThis.setInterval = function(fn, delay){
        return makeTimeout(bridge.setTimer(fn, delay || 0, true, Array.prototype.slice.call(arguments, 2)));
      };
      globalThis.clearTimeout = function(handle){
        if (handle === undefined || handle === null) return;
        bridge.clearTimer(typeof handle === 'object' ? handle._id : handle | 0);
      };
      globalThis.clearInterval = globalThis.clearTimeout;
      globalThis.setImmediate = function(fn){
        bridge.setImmediate(fn, Array.prototype.slice.call(arguments, 1));
        return { unref: function(){ return this; }, ref: function(){ return this; }, hasRef: function(){ return true; } };
      };
      globalThis.clearImmediate = function(){};
      globalThis.queueMicrotask = globalThis.queueMicrotask || function(fn){ Promise.resolve().then(fn); };

      // ---- core modules (JS half) ----
      const coreCache = {};
      // node's process.stdout and stderr ARE Writables and stdin IS a Readable, and code
      // branches on `instanceof` — the same fault the zlib coder classes had. These objects are
      // built before the core module cache exists (so `coreRequire('stream')` inside them hits a
      // temporal dead zone), which is why the prototypes are attached here instead. Own
      // properties shadow every inherited method, so the read and write paths are untouched.
      globalThis.__linkStdioPrototypes = function() {
        const streams = coreRequire('stream');
        Object.setPrototypeOf(process.stdout, streams.Writable.prototype);
        Object.setPrototypeOf(process.stderr, streams.Writable.prototype);
        Object.setPrototypeOf(process.stdin, streams.Readable.prototype);
      };
      const coreFactories = {};

      // `node:wasi` — WASI preview1, the syscall surface a wasm module compiled for "the system"
      // expects to find. It is what stands between this engine and every napi-rs package's
      // portable build (rolldown, oxc, lightningcss all ship one), and it is ordinary work:
      // the calls are pointers into the instance's memory, and the file ones are our own fs.
      // ---- HPACK (RFC 7541): the header compression HTTP/2 speaks ----
      // Both tables are the RFC's own, transcribed from its appendices rather than typed out:
      // 257 Huffman codes (Appendix B) as "hex,bits" pairs, and the 61-entry static table
      // (Appendix A) as name-tab-value. A transcription can be checked; a retyping cannot.
      const HPACK_HUFFMAN_TABLE = '1ff8,13 7fffd8,23 fffffe2,28 fffffe3,28 fffffe4,28 fffffe5,28 fffffe6,28 fffffe7,28 fffffe8,28 ffffea,24 3ffffffc,30 fffffe9,28 fffffea,28 3ffffffd,30 fffffeb,28 fffffec,28 fffffed,28 fffffee,28 fffffef,28 ffffff0,28 ffffff1,28 ffffff2,28 3ffffffe,30 ffffff3,28 ffffff4,28 ffffff5,28 ffffff6,28 ffffff7,28 ffffff8,28 ffffff9,28 ffffffa,28 ffffffb,28 14,6 3f8,10 3f9,10 ffa,12 1ff9,13 15,6 f8,8 7fa,11 3fa,10 3fb,10 f9,8 7fb,11 fa,8 16,6 17,6 18,6 0,5 1,5 2,5 19,6 1a,6 1b,6 1c,6 1d,6 1e,6 1f,6 5c,7 fb,8 7ffc,15 20,6 ffb,12 3fc,10 1ffa,13 21,6 5d,7 5e,7 5f,7 60,7 61,7 62,7 63,7 64,7 65,7 66,7 67,7 68,7 69,7 6a,7 6b,7 6c,7 6d,7 6e,7 6f,7 70,7 71,7 72,7 fc,8 73,7 fd,8 1ffb,13 7fff0,19 1ffc,13 3ffc,14 22,6 7ffd,15 3,5 23,6 4,5 24,6 5,5 25,6 26,6 27,6 6,5 74,7 75,7 28,6 29,6 2a,6 7,5 2b,6 76,7 2c,6 8,5 9,5 2d,6 77,7 78,7 79,7 7a,7 7b,7 7ffe,15 7fc,11 3ffd,14 1ffd,13 ffffffc,28 fffe6,20 3fffd2,22 fffe7,20 fffe8,20 3fffd3,22 3fffd4,22 3fffd5,22 7fffd9,23 3fffd6,22 7fffda,23 7fffdb,23 7fffdc,23 7fffdd,23 7fffde,23 ffffeb,24 7fffdf,23 ffffec,24 ffffed,24 3fffd7,22 7fffe0,23 ffffee,24 7fffe1,23 7fffe2,23 7fffe3,23 7fffe4,23 1fffdc,21 3fffd8,22 7fffe5,23 3fffd9,22 7fffe6,23 7fffe7,23 ffffef,24 3fffda,22 1fffdd,21 fffe9,20 3fffdb,22 3fffdc,22 7fffe8,23 7fffe9,23 1fffde,21 7fffea,23 3fffdd,22 3fffde,22 fffff0,24 1fffdf,21 3fffdf,22 7fffeb,23 7fffec,23 1fffe0,21 1fffe1,21 3fffe0,22 1fffe2,21 7fffed,23 3fffe1,22 7fffee,23 7fffef,23 fffea,20 3fffe2,22 3fffe3,22 3fffe4,22 7ffff0,23 3fffe5,22 3fffe6,22 7ffff1,23 3ffffe0,26 3ffffe1,26 fffeb,20 7fff1,19 3fffe7,22 7ffff2,23 3fffe8,22 1ffffec,25 3ffffe2,26 3ffffe3,26 3ffffe4,26 7ffffde,27 7ffffdf,27 3ffffe5,26 fffff1,24 1ffffed,25 7fff2,19 1fffe3,21 3ffffe6,26 7ffffe0,27 7ffffe1,27 3ffffe7,26 7ffffe2,27 fffff2,24 1fffe4,21 1fffe5,21 3ffffe8,26 3ffffe9,26 ffffffd,28 7ffffe3,27 7ffffe4,27 7ffffe5,27 fffec,20 fffff3,24 fffed,20 1fffe6,21 3fffe9,22 1fffe7,21 1fffe8,21 7ffff3,23 3fffea,22 3fffeb,22 1ffffee,25 1ffffef,25 fffff4,24 fffff5,24 3ffffea,26 7ffff4,23 3ffffeb,26 7ffffe6,27 3ffffec,26 3ffffed,26 7ffffe7,27 7ffffe8,27 7ffffe9,27 7ffffea,27 7ffffeb,27 ffffffe,28 7ffffec,27 7ffffed,27 7ffffee,27 7ffffef,27 7fffff0,27 3ffffee,26 3fffffff,30';
      const HPACK_STATIC_TABLE = ':authority	|:method	GET|:method	POST|:path	/|:path	/index.html|:scheme	http|:scheme	https|:status	200|:status	204|:status	206|:status	304|:status	400|:status	404|:status	500|accept-charset	|accept-encoding	gzip, deflate|accept-language	|accept-ranges	|accept	|access-control-allow-origin	|age	|allow	|authorization	|cache-control	|content-disposition	|content-encoding	|content-language	|content-length	|content-location	|content-range	|content-type	|cookie	|date	|etag	|expect	|expires	|from	|host	|if-match	|if-modified-since	|if-none-match	|if-range	|if-unmodified-since	|last-modified	|link	|location	|max-forwards	|proxy-authenticate	|proxy-authorization	|range	|referer	|refresh	|retry-after	|server	|set-cookie	|strict-transport-security	|transfer-encoding	|user-agent	|vary	|via	|www-authenticate';
      const hpack = (function() {
        const codes = HPACK_HUFFMAN_TABLE.split(' ').map(function(pair) {
          const parts = pair.split(',');
          return [parseInt(parts[0], 16), Number(parts[1])];
        });
        const staticTable = [null].concat(HPACK_STATIC_TABLE.split('|').map(function(entry) {
          const parts = entry.split('\t');
          return [parts[0], parts[1] === undefined ? '' : parts[1]];
        }));

        // A decoding TREE, built once: walking bit by bit is what makes a canonical Huffman
        // code decodable without knowing where a symbol ends.
        let decodeTree = null;
        function buildTree() {
          const root = [null, null];
          for (let symbol = 0; symbol < codes.length; symbol += 1) {
            const code = codes[symbol][0], length = codes[symbol][1];
            let node = root;
            for (let bit = length - 1; bit >= 0; bit -= 1) {
              const side = (code >>> bit) & 1;
              if (!node[side]) node[side] = [null, null];
              node = node[side];
            }
            node.symbol = symbol;
          }
          return root;
        }

        function huffmanEncode(text) {
          const source = Buffer.from(text, 'utf8');
          const out = [];
          let current = 0, bits = 0;
          for (let index = 0; index < source.length; index += 1) {
            const entry = codes[source[index]];
            current = (current * Math.pow(2, entry[1])) + entry[0];
            bits += entry[1];
            while (bits >= 8) {
              bits -= 8;
              out.push(Math.floor(current / Math.pow(2, bits)) & 0xff);
              current = current % Math.pow(2, bits);
            }
          }
          // The remainder is padded with ONES — the prefix of EOS, which is what tells a
          // decoder the padding is padding and not another symbol.
          if (bits > 0) out.push(((current * Math.pow(2, 8 - bits)) | ((1 << (8 - bits)) - 1)) & 0xff);
          return Buffer.from(out);
        }

        function huffmanDecode(bytes) {
          if (!decodeTree) decodeTree = buildTree();
          const out = [];
          let node = decodeTree;
          for (let index = 0; index < bytes.length; index += 1) {
            for (let bit = 7; bit >= 0; bit -= 1) {
              node = node[(bytes[index] >>> bit) & 1];
              if (!node) throw new Error('HPACK: invalid Huffman code');
              if (node.symbol !== undefined) {
                if (node.symbol === 256) throw new Error('HPACK: EOS in a string literal');
                out.push(node.symbol);
                node = decodeTree;
              }
            }
          }
          return Buffer.from(out).toString('utf8');
        }

        /// The prefix integer: N bits in the first byte, then continuation bytes of 7 bits.
        function encodeInteger(value, prefixBits, firstByte) {
          const max = (1 << prefixBits) - 1;
          if (value < max) return [firstByte | value];
          const out = [firstByte | max];
          let rest = value - max;
          while (rest >= 128) { out.push((rest % 128) + 128); rest = Math.floor(rest / 128); }
          out.push(rest);
          return out;
        }
        function decodeInteger(bytes, offset, prefixBits) {
          const max = (1 << prefixBits) - 1;
          let value = bytes[offset] & max;
          offset += 1;
          if (value === max) {
            let shift = 0, byte;
            do {
              byte = bytes[offset++];
              value += (byte & 127) * Math.pow(2, shift);
              shift += 7;
            } while (byte & 128);
          }
          return { value: value, offset: offset };
        }

        function encodeString(text, useHuffman) {
          const raw = Buffer.from(text, 'utf8');
          const packed = useHuffman ? huffmanEncode(text) : null;
          // Huffman when it is NOT LONGER, not only when strictly shorter — the RFC's own
          // examples encode a three-byte value that Huffman leaves at three bytes, and an
          // encoder that requires an improvement disagrees with them.
          if (packed && packed.length <= raw.length) {
            return Buffer.concat([Buffer.from(encodeInteger(packed.length, 7, 0x80)), packed]);
          }
          return Buffer.concat([Buffer.from(encodeInteger(raw.length, 7, 0)), raw]);
        }

        /// A table of its own per connection and per direction: the peer's dynamic table is
        /// built by REPLAYING what it sent, so an encoder and a decoder must never share one.
        function Table(maxSize) {
          this.entries = [];
          this.size = 0;
          this.maxSize = maxSize === undefined ? 4096 : maxSize;
        }
        Table.prototype.add = function(name, value) {
          const cost = name.length + value.length + 32;
          this.entries.unshift([name, value, cost]);
          this.size += cost;
          this.evict();
        };
        Table.prototype.evict = function() {
          while (this.size > this.maxSize && this.entries.length) {
            this.size -= this.entries.pop()[2];
          }
        };
        Table.prototype.get = function(index) {
          if (index < staticTable.length) return staticTable[index];
          const entry = this.entries[index - staticTable.length];
          if (!entry) throw new Error('HPACK: index ' + index + ' is out of range');
          return entry;
        };
        Table.prototype.find = function(name, value) {
          for (let index = 1; index < staticTable.length; index += 1) {
            if (staticTable[index][0] === name && staticTable[index][1] === value) {
              return { index: index, full: true };
            }
          }
          for (let index = 0; index < this.entries.length; index += 1) {
            if (this.entries[index][0] === name && this.entries[index][1] === value) {
              return { index: index + staticTable.length, full: true };
            }
          }
          for (let index = 1; index < staticTable.length; index += 1) {
            if (staticTable[index][0] === name) return { index: index, full: false };
          }
          for (let index = 0; index < this.entries.length; index += 1) {
            if (this.entries[index][0] === name) return { index: index + staticTable.length, full: false };
          }
          return null;
        };

        function Encoder(maxSize) { this.table = new Table(maxSize); }
        Encoder.prototype.encode = function(headers, options) {
          const useHuffman = !options || options.huffman !== false;
          const neverIndex = (options && options.neverIndex) || [];
          const pieces = [];
          for (const pair of headers) {
            const name = String(pair[0]).toLowerCase(), value = String(pair[1]);
            if (neverIndex.indexOf(name) >= 0) {
              pieces.push(Buffer.from(encodeInteger(0, 4, 0x10)));
              pieces.push(encodeString(name, useHuffman));
              pieces.push(encodeString(value, useHuffman));
              continue;
            }
            const found = this.table.find(name, value);
            if (found && found.full) {
              pieces.push(Buffer.from(encodeInteger(found.index, 7, 0x80)));
              continue;
            }
            if (found) {
              pieces.push(Buffer.from(encodeInteger(found.index, 6, 0x40)));
            } else {
              pieces.push(Buffer.from(encodeInteger(0, 6, 0x40)));
              pieces.push(encodeString(name, useHuffman));
            }
            pieces.push(encodeString(value, useHuffman));
            this.table.add(name, value);
          }
          return Buffer.concat(pieces);
        };

        function Decoder(maxSize) { this.table = new Table(maxSize); }
        Decoder.prototype.decode = function(bytes) {
          const headers = [];
          let offset = 0;
          const readString = function(table) {
            const huffman = (bytes[offset] & 0x80) !== 0;
            const header = decodeInteger(bytes, offset, 7);
            offset = header.offset;
            const slice = bytes.slice(offset, offset + header.value);
            offset += header.value;
            return huffman ? huffmanDecode(slice) : slice.toString('utf8');
          };
          while (offset < bytes.length) {
            const first = bytes[offset];
            if (first & 0x80) {                                  // indexed
              const read = decodeInteger(bytes, offset, 7);
              offset = read.offset;
              const entry = this.table.get(read.value);
              headers.push([entry[0], entry[1]]);
              continue;
            }
            if ((first & 0xe0) === 0x20) {                        // dynamic table size update
              const read = decodeInteger(bytes, offset, 5);
              offset = read.offset;
              this.table.maxSize = read.value;
              this.table.evict();
              continue;
            }
            const indexed = (first & 0x40) !== 0;                 // incremental indexing
            const prefix = indexed ? 6 : 4;
            const read = decodeInteger(bytes, offset, prefix);
            offset = read.offset;
            let name;
            if (read.value === 0) { name = readString(this.table); }
            else { name = this.table.get(read.value)[0]; }
            const value = readString(this.table);
            headers.push([name, value]);
            if (indexed) this.table.add(name, value);
          }
          return headers;
        };

        return { Encoder: Encoder, Decoder: Decoder, huffmanEncode: huffmanEncode,
                 huffmanDecode: huffmanDecode, staticTable: staticTable };
      })();
      globalThis.__hpack = hpack;

      coreFactories.wasi = function() {
        const fs = coreRequire('fs');
        const pathModule = coreRequire('path');
        // preview1 errno, by its own numbering — a wrong number here is a wrong error there.
        const E = { success: 0, badf: 8, exist: 20, fault: 21, inval: 28, io: 29, isdir: 31,
                    loop: 32, nametoolong: 37, noent: 44, nomem: 48, nosys: 52, notdir: 54,
                    notempty: 55, notsup: 58, perm: 63, spipe: 70, notcapable: 76 };
        const FILETYPE = { unknown: 0, directory: 3, regular: 4, symlink: 7, character: 2 };
        const RIGHTS_ALL = 0xffffffffffffffffn;
        // Rights are the whole point of WASI: a descriptor carries the capabilities it was
        // opened with, and an operation outside them is refused with ENOTCAPABLE rather than
        // performed. Ignoring them makes a sandbox that is not one, and node enforces them.
        const RIGHT = {
          fd_datasync: 1n << 0n, fd_read: 1n << 1n, fd_seek: 1n << 2n, fd_sync: 1n << 4n,
          fd_tell: 1n << 5n, fd_write: 1n << 6n, fd_advise: 1n << 7n, fd_allocate: 1n << 8n,
          path_create_directory: 1n << 9n, path_create_file: 1n << 10n, path_open: 1n << 13n,
          fd_readdir: 1n << 14n, path_rename_source: 1n << 16n, path_filestat_get: 1n << 18n,
          fd_filestat_get: 1n << 21n, path_remove_directory: 1n << 25n, path_unlink_file: 1n << 26n,
        };

        function utf8(text) { return Buffer.from(String(text), 'utf8'); }

        class WASI {
          constructor(options) {
            options = options || {};
            const version = options.version || 'preview1';
            if (version !== 'preview1' && version !== 'unstable') {
              throw Object.assign(new TypeError("Unsupported WASI version '" + version + "'"),
                                  { code: 'ERR_INVALID_ARG_VALUE' });
            }
            this._args = (options.args || []).map(String);
            const env = options.env || {};
            this._env = Object.keys(env).filter((key) => env[key] !== undefined)
              .map((key) => key + '=' + env[key]);
            this._returnOnExit = options.returnOnExit !== false;
            this._exitCode = null;
            this._memory = null;
            this._instance = null;
            // 0,1,2 are the standard streams; a preopened directory gets the next descriptor,
            // which is the ONLY way a wasi module can reach the filesystem at all.
            this._table = new Map([
              [0, { kind: 'stdin' }], [1, { kind: 'stdout' }], [2, { kind: 'stderr' }],
            ]);
            this._next = 3;
            for (const virtual of Object.keys(options.preopens || {})) {
              this._table.set(this._next++, { kind: 'preopen', name: virtual,
                                              real: String(options.preopens[virtual]) });
            }
            this.wasiImport = this._buildImports();
          }

          get [Symbol.toStringTag]() { return 'WASI'; }

          getImportObject() { return { wasi_snapshot_preview1: this.wasiImport }; }

          _bind(instance) {
            this._instance = instance;
            const memory = instance && instance.exports && instance.exports.memory;
            if (!memory || typeof memory.buffer === 'undefined') {
              throw Object.assign(new TypeError('instance.exports.memory is not a WebAssembly.Memory'),
                                  { code: 'ERR_INVALID_ARG_TYPE' });
            }
            this._memory = memory;
          }

          start(instance) {
            this._bind(instance);
            const entry = instance.exports._start;
            if (typeof entry !== 'function') {
              throw Object.assign(new TypeError('instance.exports._start is not a function'),
                                  { code: 'ERR_INVALID_ARG_TYPE' });
            }
            if (typeof instance.exports._initialize === 'function') {
              throw Object.assign(new TypeError('instance.exports._initialize must not be a function'),
                                  { code: 'ERR_INVALID_ARG_TYPE' });
            }
            try { entry(); } catch (error) {
              if (error && error.__wasiExit !== undefined) return error.__wasiExit;
              throw error;
            }
            return this._exitCode === null ? 0 : this._exitCode;
          }

          initialize(instance) {
            this._bind(instance);
            const entry = instance.exports._initialize;
            if (typeof instance.exports._start === 'function') {
              throw Object.assign(new TypeError('instance.exports._start must not be a function'),
                                  { code: 'ERR_INVALID_ARG_TYPE' });
            }
            if (typeof entry === 'function') entry();
          }

          // --- memory helpers: the view is rebuilt per call because a module may grow it ---
          get _view() { return new DataView(this._memory.buffer); }
          get _bytes() { return new Uint8Array(this._memory.buffer); }
          _writeString(pointer, text) { this._bytes.set(utf8(text), pointer); }
          _readString(pointer, length) {
            return Buffer.from(this._bytes.subarray(pointer, pointer + length)).toString('utf8');
          }
          /// A path as the module gave it, resolved under the preopen it came through — a wasi
          /// module cannot name anything it was not handed a descriptor for.
          _resolve(fd, path) {
            const entry = this._table.get(fd);
            if (!entry || (entry.kind !== 'preopen' && entry.kind !== 'directory')) return null;
            const base = entry.real;
            const joined = pathModule.resolve(base, path);
            return joined;
          }

          _buildImports() {
            const wasi = this;
            function view() { return wasi._view; }
            function bytes() { return wasi._bytes; }
            function fdOf(fd) { return wasi._table.get(fd); }

            /// The iovec array every read and write is expressed in.
            function iovecs(pointer, count) {
              const out = [];
              const memory = view();
              for (let index = 0; index < count; index += 1) {
                const base = pointer + index * 8;
                out.push({ pointer: memory.getUint32(base, true), length: memory.getUint32(base + 4, true) });
              }
              return out;
            }

            /// The descriptor, if it carries this capability — otherwise the caller gets
            /// ENOTCAPABLE, which is a different answer from "no such file" and means it.
            function capable(entry, right) {
              return entry.rights === undefined || (entry.rights & right) !== 0n;
            }

            return {
              args_sizes_get(countPointer, sizePointer) {
                const memory = view();
                let size = 0;
                for (const argument of wasi._args) size += utf8(argument).length + 1;
                memory.setUint32(countPointer, wasi._args.length, true);
                memory.setUint32(sizePointer, size, true);
                return E.success;
              },
              args_get(pointersPointer, bufferPointer) {
                const memory = view();
                let cursor = bufferPointer;
                wasi._args.forEach((argument, index) => {
                  memory.setUint32(pointersPointer + index * 4, cursor, true);
                  const encoded = utf8(argument);
                  bytes().set(encoded, cursor);
                  bytes()[cursor + encoded.length] = 0;
                  cursor += encoded.length + 1;
                });
                return E.success;
              },
              environ_sizes_get(countPointer, sizePointer) {
                const memory = view();
                let size = 0;
                for (const pair of wasi._env) size += utf8(pair).length + 1;
                memory.setUint32(countPointer, wasi._env.length, true);
                memory.setUint32(sizePointer, size, true);
                return E.success;
              },
              environ_get(pointersPointer, bufferPointer) {
                const memory = view();
                let cursor = bufferPointer;
                wasi._env.forEach((pair, index) => {
                  memory.setUint32(pointersPointer + index * 4, cursor, true);
                  const encoded = utf8(pair);
                  bytes().set(encoded, cursor);
                  bytes()[cursor + encoded.length] = 0;
                  cursor += encoded.length + 1;
                });
                return E.success;
              },
              clock_res_get(id, pointer) {
                view().setBigUint64(pointer, 1000n, true);
                return E.success;
              },
              clock_time_get(id, precision, pointer) {
                // realtime is the wall clock; the monotonic ones come off the loop's own clock,
                // which is what a program timing itself must not see run backwards.
                const nanos = id === 0
                  ? BigInt(Date.now()) * 1000000n
                  : BigInt(globalThis.__monotonicNanos ? globalThis.__monotonicNanos() : Date.now() * 1e6);
                view().setBigUint64(pointer, nanos, true);
                return E.success;
              },
              random_get(pointer, length) {
                const random = coreRequire('crypto').randomBytes(length);
                bytes().set(random, pointer);
                return E.success;
              },
              fd_write(fd, iovsPointer, iovsCount, writtenPointer) {
                const entry = fdOf(fd);
                if (!entry) return E.badf;
                let written = 0;
                const chunks = [];
                for (const piece of iovecs(iovsPointer, iovsCount)) {
                  chunks.push(Buffer.from(bytes().subarray(piece.pointer, piece.pointer + piece.length)));
                  written += piece.length;
                }
                const payload = Buffer.concat(chunks);
                if (entry.kind === 'stdout') process.stdout.write(payload);
                else if (entry.kind === 'stderr') process.stderr.write(payload);
                else if (entry.kind === 'file') {
                  if (!capable(entry, RIGHT.fd_write)) return E.notcapable;
                  try {
                    fs.writeSync(entry.fd, payload, 0, payload.length, entry.position);
                    entry.position += payload.length;
                  } catch (error) { return E.io; }
                } else return E.badf;
                view().setUint32(writtenPointer, written, true);
                return E.success;
              },
              fd_read(fd, iovsPointer, iovsCount, readPointer) {
                const entry = fdOf(fd);
                if (!entry) return E.badf;
                if (entry.kind !== 'file') { view().setUint32(readPointer, 0, true); return E.success; }
                if (!capable(entry, RIGHT.fd_read)) return E.notcapable;
                let read = 0;
                for (const piece of iovecs(iovsPointer, iovsCount)) {
                  const buffer = Buffer.alloc(piece.length);
                  let count = 0;
                  try { count = fs.readSync(entry.fd, buffer, 0, piece.length, entry.position); }
                  catch (error) { return E.io; }
                  if (count > 0) {
                    bytes().set(buffer.subarray(0, count), piece.pointer);
                    entry.position += count;
                    read += count;
                  }
                  if (count < piece.length) break;
                }
                view().setUint32(readPointer, read, true);
                return E.success;
              },
              fd_close(fd) {
                const entry = fdOf(fd);
                if (!entry) return E.badf;
                if (entry.kind === 'file') { try { fs.closeSync(entry.fd); } catch (error) {} }
                wasi._table.delete(fd);
                return E.success;
              },
              fd_seek(fd, offset, whence, pointer) {
                const entry = fdOf(fd);
                if (!entry) return E.badf;
                if (entry.kind !== 'file') return E.spipe;
                if (!capable(entry, RIGHT.fd_seek)) return E.notcapable;
                const delta = Number(offset);
                if (whence === 0) entry.position = delta;
                else if (whence === 1) entry.position += delta;
                else if (whence === 2) {
                  try { entry.position = fs.fstatSync(entry.fd).size + delta; } catch (error) { return E.io; }
                } else return E.inval;
                view().setBigUint64(pointer, BigInt(entry.position), true);
                return E.success;
              },
              fd_tell(fd, pointer) {
                const entry = fdOf(fd);
                if (!entry) return E.badf;
                if (entry.kind !== 'file') return E.spipe;
                if (!capable(entry, RIGHT.fd_tell)) return E.notcapable;
                view().setBigUint64(pointer, BigInt(entry.position), true);
                return E.success;
              },
              fd_fdstat_get(fd, pointer) {
                const entry = fdOf(fd);
                if (!entry) return E.badf;
                const memory = view();
                const type = entry.kind === 'preopen' || entry.kind === 'directory' ? FILETYPE.directory
                           : entry.kind === 'file' ? FILETYPE.regular : FILETYPE.character;
                memory.setUint8(pointer, type);
                memory.setUint16(pointer + 2, 0, true);
                memory.setBigUint64(pointer + 8, RIGHTS_ALL, true);
                memory.setBigUint64(pointer + 16, RIGHTS_ALL, true);
                return E.success;
              },
              fd_fdstat_set_flags() { return E.success; },
              fd_prestat_get(fd, pointer) {
                const entry = fdOf(fd);
                if (!entry || entry.kind !== 'preopen') return E.badf;
                const memory = view();
                memory.setUint8(pointer, 0);                                   // tag: directory
                memory.setUint32(pointer + 4, utf8(entry.name).length, true);
                return E.success;
              },
              fd_prestat_dir_name(fd, pointer, length) {
                const entry = fdOf(fd);
                if (!entry || entry.kind !== 'preopen') return E.badf;
                const encoded = utf8(entry.name);
                if (encoded.length > length) return E.nametoolong;
                bytes().set(encoded, pointer);
                return E.success;
              },
              fd_filestat_get(fd, pointer) {
                const entry = fdOf(fd);
                if (!entry) return E.badf;
                if (!capable(entry, RIGHT.fd_filestat_get)) return E.notcapable;
                try {
                  const stat = entry.kind === 'file' ? fs.fstatSync(entry.fd)
                             : entry.real ? fs.statSync(entry.real) : null;
                  writeFilestat(view(), pointer, stat, entry);
                  return E.success;
                } catch (error) { return E.io; }
              },
              fd_readdir(fd, bufferPointer, bufferLength, cookie, usedPointer) {
                const entry = fdOf(fd);
                if (!entry || (entry.kind !== 'preopen' && entry.kind !== 'directory')) return E.badf;
                if (!capable(entry, RIGHT.fd_readdir)) return E.notcapable;
                let names;
                try { names = fs.readdirSync(entry.real); } catch (error) { return E.notdir; }
                const memory = view();
                let cursor = bufferPointer;
                let index = Number(cookie);
                while (index < names.length) {
                  const name = utf8(names[index]);
                  const needed = 24 + name.length;
                  if (cursor + needed > bufferPointer + bufferLength) break;
                  memory.setBigUint64(cursor, BigInt(index + 1), true);          // next cookie
                  memory.setBigUint64(cursor + 8, 0n, true);                     // inode
                  memory.setUint32(cursor + 16, name.length, true);
                  let type = FILETYPE.unknown;
                  try {
                    type = fs.statSync(pathModule.join(entry.real, names[index])).isDirectory()
                      ? FILETYPE.directory : FILETYPE.regular;
                  } catch (error) {}
                  memory.setUint8(cursor + 20, type);
                  bytes().set(name, cursor + 24);
                  cursor += needed;
                  index += 1;
                }
                memory.setUint32(usedPointer, cursor - bufferPointer, true);
                return E.success;
              },
              path_open(dirFd, dirFlags, pathPointer, pathLength, openFlags,
                        rightsBase, rightsInheriting, fdFlags, fdPointer) {
                const name = wasi._readString(pathPointer, pathLength);
                const target = wasi._resolve(dirFd, name);
                if (target === null) return E.badf;
                let stat = null;
                try { stat = fs.statSync(target); } catch (error) { stat = null; }
                const rights = BigInt(rightsBase);
                if (stat && stat.isDirectory()) {
                  const fd = wasi._next++;
                  wasi._table.set(fd, { kind: 'directory', real: target, name: name, rights: rights });
                  view().setUint32(fdPointer, fd, true);
                  return E.success;
                }
                // oflags: 1 = create, 2 = directory, 4 = exclusive, 8 = truncate.
                const create = (openFlags & 1) !== 0, exclusive = (openFlags & 4) !== 0;
                const truncate = (openFlags & 8) !== 0;
                if ((openFlags & 2) !== 0 && !stat) return E.noent;
                if (!stat && !create) return E.noent;
                if (stat && exclusive) return E.exist;
                // rights_base bit 6 is fd_write; anything asking for it opens for writing.
                const wants = (BigInt(rightsBase) & 0x40n) !== 0n;
                const mode = truncate ? 'w+' : (wants || create ? 'a+' : 'r');
                let handle;
                try { handle = fs.openSync(target, mode); } catch (error) { return E.noent; }
                const fd = wasi._next++;
                wasi._table.set(fd, { kind: 'file', fd: handle, position: 0, real: target, rights: rights });
                view().setUint32(fdPointer, fd, true);
                return E.success;
              },
              path_filestat_get(dirFd, flags, pathPointer, pathLength, pointer) {
                const target = wasi._resolve(dirFd, wasi._readString(pathPointer, pathLength));
                if (target === null) return E.badf;
                try {
                  writeFilestat(view(), pointer, fs.statSync(target), null);
                  return E.success;
                } catch (error) { return E.noent; }
              },
              path_create_directory(dirFd, pathPointer, pathLength) {
                const target = wasi._resolve(dirFd, wasi._readString(pathPointer, pathLength));
                if (target === null) return E.badf;
                try { fs.mkdirSync(target); return E.success; } catch (error) { return E.exist; }
              },
              path_remove_directory(dirFd, pathPointer, pathLength) {
                const target = wasi._resolve(dirFd, wasi._readString(pathPointer, pathLength));
                if (target === null) return E.badf;
                try { fs.rmdirSync(target); return E.success; } catch (error) { return E.notempty; }
              },
              path_unlink_file(dirFd, pathPointer, pathLength) {
                const target = wasi._resolve(dirFd, wasi._readString(pathPointer, pathLength));
                if (target === null) return E.badf;
                try { fs.unlinkSync(target); return E.success; } catch (error) { return E.noent; }
              },
              path_rename(oldFd, oldPointer, oldLength, newFd, newPointer, newLength) {
                const from = wasi._resolve(oldFd, wasi._readString(oldPointer, oldLength));
                const to = wasi._resolve(newFd, wasi._readString(newPointer, newLength));
                if (from === null || to === null) return E.badf;
                try { fs.renameSync(from, to); return E.success; } catch (error) { return E.noent; }
              },
              path_symlink() { return E.nosys; },
              path_readlink() { return E.inval; },
              path_link() { return E.nosys; },
              path_filestat_set_times() { return E.nosys; },
              fd_advise() { return E.success; },
              fd_allocate() { return E.nosys; },
              fd_datasync() { return E.success; },
              fd_sync() { return E.success; },
              fd_renumber(from, to) {
                const entry = fdOf(from);
                if (!entry) return E.badf;
                wasi._table.set(to, entry);
                wasi._table.delete(from);
                return E.success;
              },
              fd_pread() { return E.nosys; },
              fd_pwrite() { return E.nosys; },
              fd_filestat_set_size() { return E.nosys; },
              fd_filestat_set_times() { return E.nosys; },
              poll_oneoff(inPointer, outPointer, count, usedPointer) {
                // Nothing here blocks: a subscription is answered immediately, which is the
                // truthful answer for a single-threaded host with no pollable handles.
                view().setUint32(usedPointer, 0, true);
                return E.nosys;
              },
              proc_exit(code) {
                wasi._exitCode = code;
                if (wasi._returnOnExit) {
                  const stop = new Error('WASI exit');
                  stop.__wasiExit = code;
                  throw stop;
                }
                process.exit(code);
              },
              proc_raise() { return E.nosys; },
              sched_yield() { return E.success; },
              // A socket call on something that is not a socket: node answers EINVAL, and the
              // distinction matters — ENOSYS would say the host lacks the call rather than that
              // the descriptor is the wrong kind.
              sock_accept() { return E.inval; },
              sock_recv() { return E.inval; },
              sock_send() { return E.inval; },
              sock_shutdown() { return E.inval; },
            };
          }
        }

        function writeFilestat(memory, pointer, stat, entry) {
          const isDirectory = stat ? stat.isDirectory() : (entry && entry.kind !== 'file');
          const size = stat ? stat.size : 0;
          const time = stat && stat.mtimeMs ? BigInt(Math.round(stat.mtimeMs)) * 1000000n : 0n;
          memory.setBigUint64(pointer, 0n, true);                      // dev
          memory.setBigUint64(pointer + 8, 0n, true);                  // ino
          memory.setUint8(pointer + 16, isDirectory ? FILETYPE.directory : FILETYPE.regular);
          memory.setBigUint64(pointer + 24, 1n, true);                 // nlink
          memory.setBigUint64(pointer + 32, BigInt(size), true);
          memory.setBigUint64(pointer + 40, time, true);
          memory.setBigUint64(pointer + 48, time, true);
          memory.setBigUint64(pointer + 56, time, true);
        }

        return { WASI };
      };

      coreFactories.path = function() {
        function normalizeParts(path) {
          const absolute = path.startsWith('/');
          const parts = [];
          for (const piece of path.split('/')) {
            if (piece === '' || piece === '.') continue;
            if (piece === '..') {
              if (parts.length && parts[parts.length - 1] !== '..') parts.pop();
              else if (!absolute) parts.push('..');
              continue;
            }
            parts.push(piece);
          }
          return { absolute, parts };
        }
        const path = {
          sep: '/',
          // Refused on evidence rather than caution. `fs.glob` is real (same matcher, verified
          // against node on a real tree), but node's `path.matchesGlob` — which it marks
          // EXPERIMENTAL — disagrees with itself: literal compares are case-SENSITIVE
          // ('A.JS' vs 'a.js' is false) while a pattern containing '*' compares
          // case-INSENSITIVELY ('A.JS' vs '*.js' is true), and a trailing slash on the path is
          // stripped for a literal ('a/' matches 'a') but not for '**' ('a/' matches 'a/**'
          // where a bare 'a' does not). A 1824-case corpus put the disagreement at 17 cases in
          // exactly those two families. Matching that means encoding contradictions that may
          // vanish in any node release, so this says no and names why.
          matchesGlob: function() {
            throw Object.assign(
              new Error('path.matchesGlob is not available: node\'s own implementation is ' +
                        'experimental and self-inconsistent (case sensitivity depends on whether ' +
                        'the pattern contains *, and a trailing slash is stripped for literals ' +
                        'but not for **). fs.glob and fs.globSync are real and match node'),
              { code: 'ERR_METHOD_NOT_IMPLEMENTED' });
          },
          delimiter: ':',
          normalize: function(p) {
            if (!p.length) return '.';
            const { absolute, parts } = normalizeParts(p);
            let result = (absolute ? '/' : '') + parts.join('/');
            if (!result) result = absolute ? '/' : '.';
            // A trailing separator is KEPT: node's `normalize('/a/b/')` is '/a/b/', and the
            // difference is load-bearing for anything that joins onto the result — dropping it
            // turns "this is a directory" into "this is a file".
            if (p.endsWith('/') && !result.endsWith('/')) result += '/';
            return result;
          },
          join: function() {
            const pieces = Array.prototype.filter.call(arguments, s => s !== '');
            if (!pieces.length) return '.';
            return path.normalize(pieces.join('/'));
          },
          resolve: function() {
            let resolved = '';
            for (let i = arguments.length - 1; i >= 0 && !resolved.startsWith('/'); i--) {
              if (arguments[i]) resolved = arguments[i] + (resolved ? '/' + resolved : '');
            }
            if (!resolved.startsWith('/')) resolved = __cwd + '/' + resolved;
            // resolve STRIPS a trailing separator where normalize keeps it: it answers with a
            // canonical absolute path, and '/a/' and '/a' are the same one.
            const normalized = path.normalize(resolved) || '/';
            return normalized.length > 1 && normalized.endsWith('/')
              ? path._stripTrailing(normalized) : normalized;
          },
          // A trailing separator names the same place, so dirname and basename look past it:
          // node's `basename('/a/b/')` is 'b', not the empty string an unstripped lastIndexOf
          // gives.
          _stripTrailing: function(p) {
            let end = p.length;
            while (end > 1 && p.charCodeAt(end - 1) === 47) end -= 1;
            return p.slice(0, end);
          },
          dirname: function(p) {
            const trimmed = path._stripTrailing(String(p));
            const i = trimmed.lastIndexOf('/');
            if (i < 0) return '.';
            if (i === 0) return '/';
            return trimmed.slice(0, i);
          },
          basename: function(p, ext) {
            const trimmed = path._stripTrailing(String(p));
            const base = trimmed === '/' ? '' : trimmed.slice(trimmed.lastIndexOf('/') + 1);
            // An extension is only stripped when something is LEFT: node keeps '.txt' whole
            // rather than answering with the empty string.
            if (ext && base !== ext && base.endsWith(ext)) return base.slice(0, -ext.length);
            return base;
          },
          extname: function(p) {
            const base = path.basename(p);
            const dot = base.lastIndexOf('.');
            // A name that is all dots has no extension — '..' is a name, not '.' plus '.'.
            if (dot <= 0) return '';
            for (let index = 0; index < dot; index += 1) {
              if (base.charCodeAt(index) !== 46) return base.slice(dot);
            }
            return '';
          },
          isAbsolute: function(p) { return p.startsWith('/'); },
          relative: function(from, to) {
            const a = path.resolve(from).split('/').filter(Boolean);
            const b = path.resolve(to).split('/').filter(Boolean);
            let common = 0;
            while (common < a.length && common < b.length && a[common] === b[common]) common++;
            return a.slice(common).map(() => '..').concat(b.slice(common)).join('/');
          },
          parse: function(p) {
            const text = String(p);
            const base = path.basename(text), ext = path.extname(text);
            // `dir` is EMPTY when there is no directory part — node does not say '.' here, and
            // format() would then rebuild './c.txt' from what parse gave it.
            const trimmed = path._stripTrailing(text);
            const cut = trimmed.lastIndexOf('/');
            const dir = cut < 0 ? '' : (cut === 0 ? '/' : trimmed.slice(0, cut));
            return { root: text.startsWith('/') ? '/' : '', dir: dir, base: base, ext: ext,
                     name: base.slice(0, base.length - ext.length) };
          },
          format: function(parsed) {
            parsed = parsed || {};
            // node's precedence: `dir` wins over `root`, and `base` wins over `name` + `ext`.
            const directory = parsed.dir || parsed.root || '';
            // An `ext` without its dot gets one — node writes the separator, not the caller.
            const extension = parsed.ext ? (parsed.ext.startsWith('.') ? parsed.ext : '.' + parsed.ext) : '';
            const base = parsed.base || ((parsed.name || '') + extension);
            if (!directory) return base;
            return directory === (parsed.root || '') ? directory + base : directory + '/' + base;
          },
        };
        path.posix = path;
        // win32 is a real implementation, not posix wearing a different separator: a package
        // computing a Windows path (a cross-platform test, a config writer) gets backslashes
        // and drive-letter absoluteness or it gets nonsense. What it does NOT do is UNC and
        // drive-relative paths — those say so rather than guessing.
        const win32 = {
          sep: '\\',
          delimiter: ';',
          _toPosix: function(p) { return String(p).replace(/\\/g, '/'); },
          isAbsolute: function(p) {
            const text = String(p);
            return /^[\\/]/.test(text) || /^[a-zA-Z]:[\\/]/.test(text);
          },
          normalize: function(p) {
            const text = String(p);
            const drive = /^([a-zA-Z]:)([\\/].*)?$/.exec(text);
            if (drive) {
              const rest = path.normalize(win32._toPosix(drive[2] || '/'));
              return drive[1] + rest.replace(/\//g, '\\');
            }
            return path.normalize(win32._toPosix(text)).replace(/\//g, '\\');
          },
          join: function() {
            const pieces = Array.prototype.filter.call(arguments, function(piece) { return piece !== ''; });
            if (!pieces.length) return '.';
            return win32.normalize(pieces.join('\\'));
          },
          resolve: function() {
            const args = Array.prototype.map.call(arguments, win32._toPosix);
            return path.resolve.apply(path, args).replace(/\//g, '\\');
          },
          dirname: function(p) { return path.dirname(win32._toPosix(p)).replace(/\//g, '\\'); },
          basename: function(p, ext) { return path.basename(win32._toPosix(p), ext); },
          extname: function(p) { return path.extname(win32._toPosix(p)); },
          relative: function(from, to) {
            return path.relative(win32._toPosix(from), win32._toPosix(to)).replace(/\//g, '\\');
          },
          parse: function(p) {
            const drive = /^([a-zA-Z]:)/.exec(String(p));
            const parsed = path.parse(win32._toPosix(p));
            return { root: drive ? drive[1] + '\\' : (parsed.root ? '\\' : ''),
                     dir: parsed.dir.replace(/\//g, '\\'), base: parsed.base,
                     ext: parsed.ext, name: parsed.name };
          },
          format: function(parsed) { return path.format(parsed).replace(/\//g, '\\'); },
          toNamespacedPath: function(p) { return String(p); },
          matchesGlob: path.matchesGlob,
        };
        win32.win32 = win32;
        win32.posix = path;
        path.win32 = win32;
        return path;
      };

      coreFactories.events = function() {
        // node's EventEmitter is an ES5 CONSTRUCTOR FUNCTION, not a class — readable-stream
        // (under archiver and much of npm) does `EventEmitter.call(this, opts)`, which throws
        // "Cannot call a class constructor without |new|" on a class. Prototype assignment
        // also makes the methods enumerable, which express's
        // `Object.assign(app, EventEmitter.prototype)` mixin needs.
        // `_events` initializes LAZILY in every method: express mixes the prototype into a
        // plain function without ever calling the constructor, and node tolerates that.
        function EventEmitter() { this._events = {}; }
        const P = EventEmitter.prototype;
        P._bucket = function() { return this._events || (this._events = {}); };
        P.on = function(name, handler) { const ev = this._bucket(); (ev[name] = ev[name] || []).push(handler); return this; };
        P.addListener = function(name, handler) { return this.on(name, handler); };
        P.once = function(name, handler) {
          const self = this;
          const wrapper = function(...args) { self.off(name, wrapper); handler.apply(self, args); };
          wrapper.listener = handler;
          return this.on(name, wrapper);
        };
        P.off = function(name, handler) {
          const list = this._bucket()[name] || [];
          const index = list.findIndex(h => h === handler || h.listener === handler);
          if (index >= 0) list.splice(index, 1);
          return this;
        };
        P.removeListener = function(name, handler) { return this.off(name, handler); };
        P.removeAllListeners = function(name) { if (name) delete this._bucket()[name]; else this._events = {}; return this; };
        P.emit = function(name, ...args) {
          const list = (this._bucket()[name] || []).slice();
          // Node semantics: an 'error' with no listener THROWS — otherwise failures
          // dissolve into silence (and awaited events dangle forever).
          if (name === 'error' && list.length === 0) {
            throw args[0] instanceof Error ? args[0] : new Error('Unhandled error: ' + args[0]);
          }
          for (const handler of list) handler.apply(this, args);
          return list.length > 0;
        };
        P.listenerCount = function(name) { return (this._bucket()[name] || []).length; };
        P.listeners = function(name) { return (this._bucket()[name] || []).slice(); };
        P.rawListeners = function(name) { return (this._bucket()[name] || []).slice(); };
        P.eventNames = function() { return Object.keys(this._bucket()); };
        P.setMaxListeners = function() { return this; };
        P.getMaxListeners = function() { return Infinity; };
        P.prependListener = function(name, handler) { const ev = this._bucket(); (ev[name] = ev[name] || []).unshift(handler); return this; };
        P.prependOnceListener = function(name, handler) {
          const self = this;
          const wrapper = function(...args) { self.off(name, wrapper); handler.apply(self, args); };
          wrapper.listener = handler;
          return this.prependListener(name, wrapper);
        };
        EventEmitter.EventEmitter = EventEmitter;
        EventEmitter.default = EventEmitter;
        EventEmitter.once = function(emitter, name, options) {
          // An AbortSignal here has to reject the promise; ignored, `once` waits for an event
          // that may never come and the caller's cancellation does nothing.
          const signal = options && options.signal;
          if (signal) {
            return new Promise(function(resolve, reject) {
              const abortError = function() {
                const error = new Error('The operation was aborted');
                error.name = 'AbortError';
                error.code = 'ABORT_ERR';
                return error;
              };
              if (signal.aborted) { reject(abortError()); return; }
              let done = false;
              const onEvent = function() {
                if (done) return;
                done = true;
                resolve(Array.prototype.slice.call(arguments));
              };
              const onAbort = function() {
                if (done) return;
                done = true;
                if (emitter.off) emitter.off(name, onEvent);
                reject(abortError());
              };
              emitter.once(name, onEvent);
              if (typeof signal.addEventListener === 'function') signal.addEventListener('abort', onAbort);
              else if (typeof signal.once === 'function') signal.once('abort', onAbort);
            });
          }
          return EventEmitter._onceNoSignal(emitter, name);
        };
        EventEmitter._onceNoSignal = function(emitter, name) {
          return new Promise(function(resolve, reject) {
            emitter.once(name, function(){ resolve(Array.from(arguments)); });
            if (name !== 'error' && emitter.once) emitter.once('error', reject);
          });
        };
        // `for await (const [value] of events.on(emitter, 'data'))` — the modern way to read
        // an emitter, and it was missing entirely.
        EventEmitter.on = function(emitter, name, options) {
          const queue = [];
          let waiting = null;
          let failure = null;
          let finished = false;
          // An ignored signal here means the iterator waits for an event that may never come.
          globalThis.__onAbort(options && options.signal, function() {
            failure = globalThis.__abortError();
            finished = true;
            if (waiting) { const settle = waiting; waiting = null; settle.reject(failure); }
          });
          emitter.on(name, function() {
            const value = Array.from(arguments);
            if (waiting) { const settle = waiting; waiting = null; settle.resolve({ value: value, done: false }); }
            else queue.push(value);
          });
          emitter.on('error', function(error) {
            failure = error;
            if (waiting) { const settle = waiting; waiting = null; settle.reject(error); }
          });
          const iterator = {
            next: function() {
              if (queue.length) return Promise.resolve({ value: queue.shift(), done: false });
              if (failure) return Promise.reject(failure);
              if (finished) return Promise.resolve({ value: undefined, done: true });
              return new Promise(function(resolve, reject){ waiting = { resolve: resolve, reject: reject }; });
            },
            return: function() { finished = true; return Promise.resolve({ value: undefined, done: true }); },
            throw: function(error) { finished = true; return Promise.reject(error); },
            [Symbol.asyncIterator]: function() { return this; },
          };
          return iterator;
        };
        EventEmitter.errorMonitor = Symbol('events.errorMonitor');
        EventEmitter.captureRejectionSymbol = Symbol.for('nodejs.rejection');
        EventEmitter.captureRejections = false;
        EventEmitter.defaultMaxListeners = 10;
        EventEmitter.usingDomains = false;
        EventEmitter.init = function() {};
        EventEmitter.getEventListeners = function(emitter, name) { return emitter.listeners(name); };
        EventEmitter.setMaxListeners = function() {};
        // Named by the module-surface audit. `EventEmitterAsyncResource` pairs an emitter with
        // an async-resource handle; without async_hooks context propagation the handle is inert,
        // and the emitter half — which is what callers use it for — is fully real.
        EventEmitter.EventEmitterAsyncResource = class EventEmitterAsyncResource extends EventEmitter {
          constructor(options) {
            super(options);
            const name = (options && options.name) || 'EventEmitterAsyncResource';
            let destroyed = false;
            this.asyncResource = {
              // node leaves `type` undefined here; the name is carried by the resource itself.
              _name: name,
              asyncId: function() { return 0; },
              triggerAsyncId: function() { return 0; },
              emitDestroy: function() { destroyed = true; },
              bind: function(fn) { return fn; },
              runInAsyncScope: function(fn, thisArg) {
                return fn.apply(thisArg, Array.prototype.slice.call(arguments, 2));
              },
            };
            this.emitDestroy = function() { this.asyncResource.emitDestroy(); };
            this.asyncId = function() { return 0; };
            this.triggerAsyncId = function() { return 0; };
            Object.defineProperty(this, 'destroyed', { get: function() { return destroyed; } });
          }
        };
        EventEmitter.kMaxEventTargetListeners = Symbol('events.maxEventTargetListeners');
        EventEmitter.kMaxEventTargetListenersWarned = Symbol('events.maxEventTargetListenersWarned');
        return EventEmitter;
      };

      coreFactories.util = function() {
        return {
          format: format,
          // node takes an OPTIONS object here; only a positional depth was understood, so
          // `{depth: 0}` read as depth `undefined` and printed the whole tree.
          inspect: function(value, options) {
            if (options !== null && typeof options === 'object') {
              const depth = options.depth === null ? Infinity
                          : options.depth === undefined ? 2 : Number(options.depth);
              // `compact: false` and a small `breakLength` are how a caller asks for one entry
              // per line, and `maxArrayLength` is how it asks for less — all three were
              // accepted and ignored, which reads as a formatter that does not work.
              const previous = { break: inspect._breakLength, compact: inspect._compact,
                                 max: inspect._maxArrayLength };
              if (options.breakLength !== undefined) inspect._breakLength = Number(options.breakLength);
              if (options.compact !== undefined) inspect._compact = options.compact;
              if (options.maxArrayLength !== undefined) {
                inspect._maxArrayLength = options.maxArrayLength === null
                  ? Infinity : Number(options.maxArrayLength);
              }
              try { return inspect(value, depth); }
              finally {
                inspect._breakLength = previous.break;
                inspect._compact = previous.compact;
                inspect._maxArrayLength = previous.max;
              }
            }
            return inspect(value, options);
          },
          inherits: function(ctor, superCtor) {
            ctor.super_ = superCtor;
            Object.setPrototypeOf(ctor.prototype, superCtor.prototype);
          },
          promisify: function(fn) {
            // A function may carry its OWN promise version under util.promisify.custom, and node
            // hands that back untouched — the shape libraries use when the callback form is not
            // a plain (error, value).
            const custom = fn && fn[Symbol.for('nodejs.util.promisify.custom')];
            if (typeof custom === 'function') return custom;
            return function(...args) {
              return new Promise((resolve, reject) => {
                fn.call(this, ...args, (error, value) => error ? reject(error) : resolve(value));
              });
            };
          },
          types: {
            isDate: v => v instanceof Date,
            isRegExp: v => v instanceof RegExp,
            isNativeError: v => v instanceof Error,
            isPromise: v => v instanceof Promise,
            isProxy: () => false,
            isTypedArray: v => ArrayBuffer.isView(v) && !(v instanceof DataView),
          },
          deprecate: function(fn) { return fn; },
          debuglog: function(section) {
            const enabled = !!(__env.NODE_DEBUG && new RegExp('\\b' + section + '\\b', 'i').test(__env.NODE_DEBUG));
            const logger = enabled
              ? function(){ bridge.stderr(section.toUpperCase() + ': ' + format.apply(null, arguments) + '\n'); }
              : function(){};
            logger.enabled = enabled;
            return logger;
          },
          callbackify: function(fn) {
            return function(...args) {
              const callback = args.pop();
              fn.apply(this, args).then(value => callback(null, value), error => callback(error));
            };
          },
          styleText: function(format, text) {
            // Node semantics: unstyled unless the stream is a TTY (or FORCE_COLOR says so).
            const env = process.env;
            const colorize = env.FORCE_COLOR !== undefined ? env.FORCE_COLOR !== '0'
              : (!env.NO_COLOR && process.stdout && process.stdout.isTTY);
            if (!colorize) return String(text);
            const codes = {
              reset: [0, 0], bold: [1, 22], dim: [2, 22], italic: [3, 23], underline: [4, 24],
              blink: [5, 25], inverse: [7, 27], hidden: [8, 28], strikethrough: [9, 29],
              black: [30, 39], red: [31, 39], green: [32, 39], yellow: [33, 39], blue: [34, 39],
              magenta: [35, 39], cyan: [36, 39], white: [37, 39], gray: [90, 39], grey: [90, 39],
              redBright: [91, 39], greenBright: [92, 39], yellowBright: [93, 39], blueBright: [94, 39],
              magentaBright: [95, 39], cyanBright: [96, 39], whiteBright: [97, 39],
              bgBlack: [40, 49], bgRed: [41, 49], bgGreen: [42, 49], bgYellow: [43, 49],
              bgBlue: [44, 49], bgMagenta: [45, 49], bgCyan: [46, 49], bgWhite: [47, 49],
            };
            let out = String(text);
            const formats = Array.isArray(format) ? format : [format];
            for (const name of formats) {
              const pair = codes[name];
              if (!pair) throw new Error('Unknown format: ' + name);
              out = '\u001b[' + pair[0] + 'm' + out + '\u001b[' + pair[1] + 'm';
            }
            return out;
          },
          stripVTControlCharacters: function(text) {
            return String(text).replace(/\u001b\[[0-9;?]*[0-9A-Za-z]|\u001b\][^\u0007]*(\u0007|\u001b\\)|\u001b[^[\]]/g, '');
          },
          isArray: Array.isArray,
          isFunction: v => typeof v === 'function',
          isString: v => typeof v === 'string',
          isObject: v => v !== null && typeof v === 'object',
          isDeepStrictEqual: function(a, b) { return globalThis.__deepEqual(a, b, true); },
          // Named by the module-surface audit. Documented API, not internals.
          MIMEType: globalThis.__MIMEType,
          MIMEParams: globalThis.__MIMEParams,
          parseEnv: function(text) { return globalThis.__parseEnv(text); },
          getCallSites: function(limit) { return globalThis.__getCallSites(limit); },
          getCallSite: function(limit) { return globalThis.__getCallSites(limit); },
          diff: function(actual, expected) { return globalThis.__utilDiff(actual, expected); },
          // The deprecated-but-still-used type checks. Packages that support old node call
          // these directly, and an undefined one reads as "not that type".
          isBoolean: v => typeof v === 'boolean',
          isBuffer: v => Buffer.isBuffer(v),
          isDate: v => v instanceof Date,
          isError: v => v instanceof Error,
          isNull: v => v === null,
          isNullOrUndefined: v => v === null || v === undefined,
          isNumber: v => typeof v === 'number',
          isPrimitive: v => v === null || (typeof v !== 'object' && typeof v !== 'function'),
          isRegExp: v => v instanceof RegExp,
          isSymbol: v => typeof v === 'symbol',
          isUndefined: v => v === undefined,
          _extend: function(target, source) { return Object.assign(target, source); },
          toUSVString: function(text) { return String(text).replace(/[\uD800-\uDFFF]/g, '\uFFFD'); },
          log: function() {
            const stamp = new Date().toISOString();
            console.log.apply(console, [stamp].concat(Array.prototype.slice.call(arguments)));
          },
          // NOT `this.debug(section)`, which is what this was. A core module's functions get
          // destructured constantly — `const { debuglog } = require('node:util')` is the first
          // line of avvio, which is what fastify boots through — and a function that reaches
          // through `this` is undefined the moment it travels alone. The same shape as
          // process.hrtime, which eslint destructures.
          debug: function(section) {
            const enabled = String(process.env.NODE_DEBUG || '').split(/[ ,]/).indexOf(section) >= 0;
            const logger = enabled ? function() {
              console.error.apply(console, [section.toUpperCase() + ' ' + process.pid + ':']
                .concat(Array.prototype.slice.call(arguments)));
            } : function(){};
            logger.enabled = enabled;
            return logger;
          },
          get debuglog() { return this.debug; },
          getSystemErrorMap: function() { return new Map(); },
          getSystemErrorMessage: function(code) { return 'system error ' + code; },
          aborted: function(signal) {
            return new Promise(function(resolve){
              if (signal.aborted) { resolve(); return; }
              signal.addEventListener('abort', function(){ resolve(); });
            });
          },
          // node 18's argument parser. Increasingly what a CLI uses instead of a dependency.
          parseArgs: function(config) {
            config = config || {};
            const args = config.args || process.argv.slice(2);
            const options = config.options || {};
            const values = {};
            const positionals = [];
            for (const name of Object.keys(options)) {
              if (options[name].default !== undefined) values[name] = options[name].default;
            }
            function record(name, value) {
              const spec = options[name] || {};
              if (spec.multiple) (values[name] = values[name] || []).push(value);
              else values[name] = value;
            }
            for (let i = 0; i < args.length; i++) {
              const token = args[i];
              if (token === '--') { positionals.push.apply(positionals, args.slice(i + 1)); break; }
              if (token.startsWith('--')) {
                const at = token.indexOf('=');
                const name = at >= 0 ? token.slice(2, at) : token.slice(2);
                const spec = options[name];
                if (!spec && config.strict !== false) {
                  const error = new Error("Unknown option '--" + name + "'");
                  error.code = 'ERR_PARSE_ARGS_UNKNOWN_OPTION';
                  throw error;
                }
                if (spec && spec.type === 'string') record(name, at >= 0 ? token.slice(at + 1) : args[++i]);
                else record(name, at >= 0 ? token.slice(at + 1) !== 'false' : true);
                continue;
              }
              if (token.length > 1 && token[0] === '-') {
                for (const letter of token.slice(1)) {
                  const name = Object.keys(options).find(key => options[key].short === letter);
                  if (!name) {
                    if (config.strict === false) continue;
                    const error = new Error("Unknown option '-" + letter + "'");
                    error.code = 'ERR_PARSE_ARGS_UNKNOWN_OPTION';
                    throw error;
                  }
                  if (options[name].type === 'string') record(name, args[++i]);
                  else record(name, true);
                }
                continue;
              }
              if (config.allowPositionals !== false) positionals.push(token);
            }
            return { values: values, positionals: positionals };
          },
        };
      };

      coreFactories.os = function() {
        return {
          platform: function(){ return 'darwin'; },
          type: function(){ return 'Darwin'; },
          arch: function(){ return 'arm64'; },
          release: function(){ return '23.0.0'; },
          homedir: function(){ return '/'; },
          tmpdir: function(){ return '/tmp'; },
          hostname: function(){ return 'mouse'; },
          cpus: function(){ return [{ model: 'Apple', speed: 0, times: {} }]; },
          totalmem: function(){ return 4 * 1024 * 1024 * 1024; },
          freemem: function(){ return 1024 * 1024 * 1024; },
          EOL: '\n',
          userInfo: function(){ return { username: 'mouse', homedir: '/', shell: '/bin/msh' }; },
          endianness: function(){ return 'LE'; },
          uptime: function(){ return Math.floor(Date.now() / 1000) % 86400; },
          loadavg: function(){ return [0, 0, 0]; },
          networkInterfaces: function(){ return {}; },
          devNull: '/dev/null',
          // Process priority is not ours to change in a sandbox; 0 (default, unchangeable)
          // is the truth here rather than a guess.
          getPriority: function(){ return 0; },
          setPriority: function(){},
          constants: {
            signals: { SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGILL: 4, SIGTRAP: 5, SIGABRT: 6,
                       SIGFPE: 8, SIGKILL: 9, SIGBUS: 10, SIGSEGV: 11, SIGSYS: 12, SIGPIPE: 13,
                       SIGALRM: 14, SIGTERM: 15, SIGURG: 16, SIGSTOP: 17, SIGTSTP: 18, SIGCONT: 19,
                       SIGCHLD: 20, SIGTTIN: 21, SIGTTOU: 22, SIGIO: 23, SIGXCPU: 24, SIGXFSZ: 25,
                       SIGVTALRM: 26, SIGPROF: 27, SIGWINCH: 28, SIGINFO: 29, SIGUSR1: 30, SIGUSR2: 31 },
            errno: { EACCES: 13, EEXIST: 17, ENOENT: 2, ENOTDIR: 20, EPERM: 1, EPIPE: 32 },
          },
        };
      };

      coreFactories.fs = function() {
        const path = coreRequire('path');
        const EventEmitter = coreRequire('events');   // FSWatcher is one
        // Open file descriptors, declared before the API so every path-taking function can
        // accept an FD — node's `fs.writeFileSync(fd, data)` / `readFileSync(fd)` forms.
        // claude-code writes its config exactly that way (openSync 'w' → writeFileSync(fd));
        // treating the number as a path silently truncated the file and dropped the data.
        const fileDescriptors = {};
        let nextFd = 3;
        function resolvePath(p) {
          if (typeof p === 'number') {
            const entry = fileDescriptors[p];
            if (!entry) { const e = new Error('EBADF: bad file descriptor'); e.code = 'EBADF'; throw e; }
            return entry.path;
          }
          // fs accepts file:// URLs (strings or URL objects) like real node.
          let text = String(p && p.href ? p.href : p);
          if (text.startsWith('file://')) text = text.slice(7);
          return path.resolve(text);
        }
        function toEncoding(options) {
          if (typeof options === 'string') return options;
          return options && options.encoding ? options.encoding : null;
        }
        function statsFrom(raw) {
          if (!raw) return null;
          // node's full Stats. Libraries read these fields and draw conclusions from
          // undefined without complaining — chokidar gates every file on
          // `4 & parseInt(stats.mode)`, so a missing `mode` looked like "no read permission"
          // and silently hid every file in a watched directory.
          // A real Stats instance: `x instanceof fs.Stats` is a check libraries make.
          return Object.assign(new Stats(), {
            isFile: function(){ return !!raw.file; },
            isDirectory: function(){ return !!raw.dir; },
            isSymbolicLink: function(){ return !!raw.link; },
            isBlockDevice: function(){ return false; },
            isCharacterDevice: function(){ return false; },
            isFIFO: function(){ return false; },
            isSocket: function(){ return false; },
            dev: raw.dev, ino: raw.ino, mode: raw.mode, nlink: raw.nlink,
            uid: raw.uid, gid: raw.gid, rdev: raw.rdev,
            size: raw.size, blksize: raw.blksize, blocks: raw.blocks,
            atimeMs: raw.atimeMs, mtimeMs: raw.mtimeMs,
            ctimeMs: raw.ctimeMs, birthtimeMs: raw.birthtimeMs,
            atime: new Date(raw.atimeMs), mtime: new Date(raw.mtimeMs),
            ctime: new Date(raw.ctimeMs), birthtime: new Date(raw.birthtimeMs),
          });
        }
        // fs.watch: real, on kqueue (NodeWatch.swift). Every watching tool an IDE runs needs
        // it — `tsc --watch`, a dev server's HMR, nodemon — and a watcher is a ref'd handle,
        // so an open FSWatcher keeps the event loop alive exactly as in node.
        function FSWatcher(path, options, listener) {
          EventEmitter.call(this);
          options = options || {};
          this._closed = false;
          const self = this;
          this._id = bridge.fsWatch(resolvePath(path), !!options.recursive, function(event, name) {
            if (self._closed) return;
            // `encoding: 'buffer'` asks for the filename as bytes, which chokidar and friends
            // pass through unchanged.
            self.emit('change', event, options.encoding === 'buffer' ? Buffer.from(name) : name);
          });
          if (!this._id) {
            const error = Object.assign(new Error("ENOENT: no such file or directory, watch '" + path + "'"),
                                        { code: 'ENOENT', errno: -2, syscall: 'watch', path: path });
            // node throws synchronously for a missing path.
            throw error;
          }
          if (listener) this.on('change', listener);
        }
        FSWatcher.prototype = Object.create(EventEmitter.prototype);
        FSWatcher.prototype.constructor = FSWatcher;
        FSWatcher.prototype.close = function() {
          if (this._closed) return;
          this._closed = true;
          bridge.fsUnwatch(this._id);
          this.emit('close');
        };
        FSWatcher.prototype.ref = function() { return this; };
        FSWatcher.prototype.unref = function() { return this; };
        // node's async-iterator form: `for await (const event of fs.promises.watch(dir))`.
        FSWatcher.prototype[Symbol.asyncIterator] = function() {
          const queue = [];
          let waiting = null;
          let done = false;
          this.on('change', function(eventType, filename) {
            const value = { eventType: eventType, filename: filename };
            if (waiting) { const resolve = waiting; waiting = null; resolve({ value: value, done: false }); }
            else queue.push(value);
          });
          this.on('close', function() {
            done = true;
            if (waiting) { const resolve = waiting; waiting = null; resolve({ value: undefined, done: true }); }
          });
          const watcher = this;
          return {
            next: function() {
              if (queue.length) return Promise.resolve({ value: queue.shift(), done: false });
              if (done) return Promise.resolve({ value: undefined, done: true });
              return new Promise(function(resolve){ waiting = resolve; });
            },
            return: function() { watcher.close(); return Promise.resolve({ value: undefined, done: true }); },
            [Symbol.asyncIterator]: function() { return this; },
          };
        };

        function watch(path, options, listener) {
          if (typeof options === 'function') { listener = options; options = {}; }
          if (typeof options === 'string') options = { encoding: options };
          const watcher = new FSWatcher(path, options, listener);
          // node closes the watcher when the signal fires; without this it runs forever.
          globalThis.__onAbort(options && options.signal, function(){ watcher.close(); });
          return watcher;
        }

        // watchFile is node's OLDER, polling API, and it is polling in node too: an interval
        // that stats the file and reports previous/current Stats when they differ.
        const watchedFiles = new Map();
        function watchFile(path, options, listener) {
          if (typeof options === 'function') { listener = options; options = {}; }
          options = options || {};
          const interval = Number(options.interval) || 5007;   // node's default
          const key = resolvePath(path);
          let entry = watchedFiles.get(key);
          if (!entry) {
            entry = { listeners: [], previous: statSafely(key), timer: null, watcher: null };
            entry.timer = setInterval(function() {
              const current = statSafely(key);
              const changed = current.mtimeMs !== entry.previous.mtimeMs || current.size !== entry.previous.size;
              if (changed) {
                const previous = entry.previous;
                entry.previous = current;
                for (const fn of entry.listeners.slice()) fn(current, previous);
              }
            }, interval);
            if (entry.timer && entry.timer.unref && options.persistent === false) entry.timer.unref();
            watchedFiles.set(key, entry);
          }
          if (listener) entry.listeners.push(listener);
          // node returns a StatWatcher (measured: an object, and NOT the Stats — reading
          // `.mtimeMs` off it gives undefined). The Stats arrive through the listener's
          // (current, previous) pair.
          if (!entry.watcher) {
            entry.watcher = Object.assign(new EventEmitter(), {
              stop: function(){ unwatchFile(path); },
              ref: function(){ return this; },
              unref: function(){ return this; },
            });
          }
          return entry.watcher;
        }
        function unwatchFile(path, listener) {
          const key = resolvePath(path);
          const entry = watchedFiles.get(key);
          if (!entry) return;
          if (listener) {
            const at = entry.listeners.indexOf(listener);
            if (at >= 0) entry.listeners.splice(at, 1);
            if (entry.listeners.length) return;
          }
          clearInterval(entry.timer);
          watchedFiles.delete(key);
        }
        function statSafely(target) {
          const raw = bridge.stat(target, true);
          if (!raw) return { mtimeMs: 0, size: 0, isFile: function(){ return false; }, isDirectory: function(){ return false; } };
          return statsFrom(raw);
        }
        // A NUMBER as the file argument means an open fd — resolvePath maps it to the
        // path (node semantics: fs.writeFileSync(fd, data) is legal and common).
        // ---- the surface audit's findings, filled in ------------------------------------
        // Diffed against real node's `Object.keys(require('fs'))`: each of these is a member a
        // package can reach for, and an absent one is a wrong answer delivered quietly (the
        // `stats.mode` bug was exactly that). Grouped by what they are, not alphabetically.

        // Stats and Dirent as real CONSTRUCTORS: libraries check `instanceof fs.Stats`, and a
        // plain object literal fails that check while looking identical.
        function Stats() {}
        function Dirent() {}
        function Dir(path, entries) {
          this.path = path;
          this._entries = entries;
          this._at = 0;
          this._closed = false;
        }
        Dir.prototype.readSync = function() {
          if (this._closed || this._at >= this._entries.length) return null;
          return this._entries[this._at++];
        };
        Dir.prototype.read = function(callback) {
          const entry = this.readSync();
          if (callback) { process.nextTick(function(){ callback(null, entry); }); return; }
          return Promise.resolve(entry);
        };
        Dir.prototype.closeSync = function() { this._closed = true; };
        Dir.prototype.close = function(callback) {
          this._closed = true;
          if (callback) { process.nextTick(function(){ callback(null); }); return; }
          return Promise.resolve();
        };
        Dir.prototype[Symbol.asyncIterator] = function() {
          const dir = this;
          return {
            next: function() {
              const entry = dir.readSync();
              return Promise.resolve(entry ? { value: entry, done: false } : { value: undefined, done: true });
            },
            [Symbol.asyncIterator]: function() { return this; },
          };
        };

        // Recursive copy. Build tools reach for this constantly (node only grew it in 16, so
        // packages that target older node use their own — but the new ones use this).
        function cpSync(from, to, options) {
          options = options || {};
          const source = resolvePath(from);
          const target = resolvePath(to);
          const raw = bridge.stat(source, !!options.dereference);
          if (!raw) {
            const error = new Error("ENOENT: no such file or directory, cp '" + from + "'");
            error.code = 'ENOENT';
            throw error;
          }
          if (options.filter && !options.filter(source, target)) return;
          if (raw.dir) {
            if (!options.recursive) {
              const error = new Error("EISDIR: illegal operation on a directory, cp '" + from + "'");
              error.code = 'ERR_FS_EISDIR';
              throw error;
            }
            fs.mkdirSync(target, { recursive: true });
            for (const name of bridge.readdir(source) || []) {
              cpSync(source + '/' + name, target + '/' + name, options);
            }
            return;
          }
          const exists = !!bridge.stat(target, true);
          if (exists && options.errorOnExist && options.force === false) {
            const error = new Error("EEXIST: file already exists, cp '" + to + "'");
            error.code = 'EEXIST';
            throw error;
          }
          if (exists && options.force === false) return;
          fs.copyFileSync(source, target);
        }

        // Vectored I/O on a descriptor: one syscall in node, a loop here, same observable
        // result (bytesWritten and the buffers filled in order).
        function writevSync(fd, buffers, position) {
          let written = 0;
          let at = position;
          for (const buffer of buffers) {
            const count = fs.writeSync(fd, buffer, 0, buffer.length, at === undefined || at === null ? null : at + written);
            written += count;
          }
          return written;
        }
        function readvSync(fd, buffers, position) {
          let read = 0;
          let at = position;
          for (const buffer of buffers) {
            const count = fs.readSync(fd, buffer, 0, buffer.length, at === undefined || at === null ? null : at + read);
            read += count;
            if (count < buffer.length) break;
          }
          return read;
        }

        // A FileHandle is what fs.promises.open resolves to, and it is a distinct object from
        // a numeric fd: everything hangs off the handle.
        function FileHandle(fd, path) {
          this.fd = fd;
          this._path = path;
        }
        FileHandle.prototype.close = function() {
          const fd = this.fd;
          return new Promise(function(resolve, reject) {
            try { fs.closeSync(fd); resolve(); } catch (error) { reject(error); }
          });
        };
        FileHandle.prototype.readFile = function(options) {
          const fd = this.fd;
          return Promise.resolve().then(function(){ return fs.readFileSync(fd, options); });
        };
        FileHandle.prototype.writeFile = function(data, options) {
          const fd = this.fd;
          return Promise.resolve().then(function(){ return fs.writeFileSync(fd, data, options); });
        };
        FileHandle.prototype.appendFile = function(data, options) {
          const fd = this.fd;
          return Promise.resolve().then(function(){ return fs.appendFileSync(fd, data, options); });
        };
        FileHandle.prototype.read = function(buffer, offset, length, position) {
          const fd = this.fd;
          // node also accepts a single options object.
          if (buffer && !Buffer.isBuffer(buffer) && typeof buffer === 'object') {
            const options = buffer;
            buffer = options.buffer || Buffer.alloc(16384);
            offset = options.offset || 0;
            length = options.length === undefined ? buffer.length - offset : options.length;
            position = options.position;
          }
          return Promise.resolve().then(function(){
            const bytesRead = fs.readSync(fd, buffer, offset || 0,
                                          length === undefined ? buffer.length : length,
                                          position === undefined ? null : position);
            return { bytesRead: bytesRead, buffer: buffer };
          });
        };
        FileHandle.prototype.write = function(data, offset, length, position) {
          const fd = this.fd;
          return Promise.resolve().then(function(){
            const bytesWritten = fs.writeSync(fd, data, offset, length, position);
            return { bytesWritten: bytesWritten, buffer: data };
          });
        };
        FileHandle.prototype.writev = function(buffers, position) {
          const fd = this.fd;
          return Promise.resolve().then(function(){
            return { bytesWritten: writevSync(fd, buffers, position), buffers: buffers };
          });
        };
        FileHandle.prototype.readv = function(buffers, position) {
          const fd = this.fd;
          return Promise.resolve().then(function(){
            return { bytesRead: readvSync(fd, buffers, position), buffers: buffers };
          });
        };
        FileHandle.prototype.stat = function() {
          const fd = this.fd;
          return Promise.resolve().then(function(){ return fs.fstatSync(fd); });
        };
        FileHandle.prototype.truncate = function(length) {
          const fd = this.fd;
          return Promise.resolve().then(function(){ return fs.ftruncateSync(fd, length); });
        };
        FileHandle.prototype.sync = function() {
          const fd = this.fd;
          return Promise.resolve().then(function(){ return fs.fsyncSync(fd); });
        };
        FileHandle.prototype.datasync = function() {
          const fd = this.fd;
          return Promise.resolve().then(function(){ return fs.fdatasyncSync(fd); });
        };
        FileHandle.prototype.chmod = function(mode) {
          const fd = this.fd;
          return Promise.resolve().then(function(){ return fs.fchmodSync(fd, mode); });
        };
        FileHandle.prototype.utimes = function(atime, mtime) {
          const fd = this.fd;
          return Promise.resolve().then(function(){ return fs.futimesSync(fd, atime, mtime); });
        };
        FileHandle.prototype.createReadStream = function(options) {
          return fs.createReadStream(this._path, options);
        };
        FileHandle.prototype.createWriteStream = function(options) {
          return fs.createWriteStream(this._path, options);
        };

        const fs = {
          // Every fs error node raises carries a `code`, a `syscall` and a `path`, and real code
          // branches on all three. An audit found the syscall missing everywhere, two codes wrong,
          // and — worse — five operations that SUCCEEDED where node fails. A filesystem API that
          // silently does more than it was asked either destroys data or fabricates it.
          _fail: function(code, syscall, path, message) {
            throw Object.assign(new Error(code + ': ' + message + ", " + syscall + " '" + path + "'"),
                                { code: code, errno: -2, syscall: syscall, path: String(path) });
          },
          /// Does the containing directory exist? node refuses to write into a path whose parent
          /// is missing, rather than creating it.
          _parentExists: function(file) {
            const text = String(file);
            const cut = text.lastIndexOf('/');
            if (cut <= 0) return true;
            const parent = text.slice(0, cut);
            const raw = bridge.stat(resolvePath(parent), true);
            return !!(raw && raw.dir);
          },
          readFileSync: function(file, options) {
            // A directory is EISDIR, not ENOENT — code that distinguishes them takes the wrong
            // branch otherwise.
            if (typeof file === 'string') {
              const raw = bridge.stat(resolvePath(file), true);
              if (raw && raw.dir) fs._fail('EISDIR', 'read', file, 'illegal operation on a directory');
            }
            const base64 = bridge.readFile(resolvePath(file));
            if (base64 === null || base64 === undefined) {
              fs._fail('ENOENT', 'open', file, 'no such file or directory');
            }
            const buffer = Buffer.from(base64, 'base64');
            const encoding = toEncoding(options);
            return encoding ? buffer.toString(encoding) : buffer;
          },
          // `flag` and `mode` were accepted and dropped. Both mattered: flag:'a' TRUNCATED the
          // file it was asked to append to (silent data loss), and an ignored mode:0o600 left a
          // secret world-readable. A sweep for silently-ignored options found them.
          writeFileSync: function(file, data, options) {
            // A flag is a string OR a number here too — `{ flag: O_WRONLY | O_APPEND }` is
            // ordinary, and reading it as text made every numeric spelling mean "truncate".
            const rawFlag = options && options.flag !== undefined ? options.flag : 'w';
            const flag = typeof rawFlag === 'number'
              ? ((rawFlag & 8) ? 'a' : (rawFlag & 2048) ? 'wx' : 'w')
              : String(rawFlag);
            const buffer = __toBytes(data, typeof options === 'string' ? options
                                           : (options && options.encoding) || undefined);
            const path = resolvePath(file);
            // 'x' means exclusive: fail if the path is already there.
            if (flag.indexOf('x') >= 0 && fs.existsSync(file)) {
              throw Object.assign(new Error("EEXIST: file already exists, open '" + file + "'"),
                                  { code: 'EEXIST', syscall: 'open', path: file });
            }
            // A missing parent used to be created silently, so a mistyped path produced a phantom
            // tree and a program relying on ENOENT to notice never saw it.
            if (typeof file === 'string' && !fs._parentExists(file)) {
              fs._fail('ENOENT', 'open', file, 'no such file or directory');
            }
            const append = flag[0] === 'a';
            if (!bridge.writeFile(path, buffer.toString('base64'), append)) {
              throw new Error("EACCES: cannot write '" + file + "'");
            }
            if (options && options.mode !== undefined) bridge.chmodPath(path, Number(options.mode));
          },
          appendFileSync: function(file, data, options) {
            const buffer = __toBytes(data, typeof options === 'string' ? options
                                           : (options && options.encoding) || undefined);
            const path = resolvePath(file);
            if (!bridge.writeFile(path, buffer.toString('base64'), true)) {
              throw new Error("EACCES: cannot append '" + file + "'");
            }
            if (options && options.mode !== undefined) bridge.chmodPath(path, Number(options.mode));
          },
          existsSync: function(file) {
            try { return !!bridge.stat(resolvePath(file), true); } catch (error) { return false; }
          },
          statSync: function(file, options) {
            const raw = bridge.stat(resolvePath(file), true);
            if (!raw) {
              if (options && options.throwIfNoEntry === false) return undefined;
              fs._fail('ENOENT', 'stat', file, 'no such file or directory');
            }
            return statsFrom(raw);
          },
          lstatSync: function(file, options) {
            const raw = bridge.stat(resolvePath(file), false);   // does NOT follow the link
            if (!raw) {
              if (options && options.throwIfNoEntry === false) return undefined;
              const error = new Error("ENOENT: no such file or directory, lstat '" + file + "'");
              error.code = 'ENOENT';
              throw error;
            }
            return statsFrom(raw);
          },
          readdirSync: function(dir, options) {
            const parent = resolvePath(dir);
            const probe = bridge.stat(parent, true);
            if (probe && !probe.dir) fs._fail('ENOTDIR', 'scandir', dir, 'not a directory');
            const entries = bridge.readdir(parent);
            if (!entries) fs._fail('ENOENT', 'scandir', dir, 'no such file or directory');
            // `recursive` (node 20+) was ignored, so a deep tree listed only its top level.
            if (options && options.recursive) {
              const found = [];
              const walk = function(relative) {
                const absolute = relative ? parent + '/' + relative : parent;
                const names = bridge.readdir(absolute) || [];
                for (const name of names) {
                  const child = relative ? relative + '/' + name : name;
                  found.push(child);
                  const raw = bridge.stat(absolute + '/' + name, false);
                  if (raw && raw.dir) walk(child);
                }
              };
              walk('');
              if (!options.withFileTypes) return found;
            }
            if (!options || !options.withFileTypes) return entries;
            // Dirent objects — glob's path-scurry walks these; strings would silently match
            // nothing (isDirectory() undefined reads as "not a directory, not a file").
            return entries.map(function(name) {
              const raw = bridge.stat(parent + '/' + name, false);
              const isDir = !!(raw && raw.dir);
              return Object.assign(new Dirent(), {
                name: name,
                parentPath: parent,
                path: parent,
                isFile: function(){ return !isDir; },
                isDirectory: function(){ return isDir; },
                isSymbolicLink: function(){ return false; },
                isBlockDevice: function(){ return false; },
                isCharacterDevice: function(){ return false; },
                isFIFO: function(){ return false; },
                isSocket: function(){ return false; },
              });
            });
          },
          mkdirSync: function(dir, options) {
            const recursive = !!(options && typeof options === 'object' && options.recursive);
            if (!recursive) {
              // node makes ONE directory: an existing path is EEXIST, a missing parent is ENOENT.
              // Ours created the whole tree either way, which is `mkdir -p` behaviour nobody asked
              // for and hides a mistyped path.
              if (fs.existsSync(dir)) fs._fail('EEXIST', 'mkdir', dir, 'file already exists');
              if (!fs._parentExists(dir)) fs._fail('ENOENT', 'mkdir', dir, 'no such file or directory');
            }
            const path = resolvePath(dir);
            // node returns the FIRST path it had to create, and undefined when there was
            // nothing to do — which is how a caller learns whether it made the tree.
            // The answer is in the CALLER's terms: node hands back 'deep' for `mkdir('deep/deeper')`,
            // not the absolute path it resolved to — the caller is going to print it or join onto it.
            let firstCreated;
            if (recursive) {
              const given = String(dir);
              const pieces = given.split('/').filter(Boolean);
              let walked = given.startsWith('/') ? '' : '';
              for (const piece of pieces) {
                walked = walked ? walked + '/' + piece : (given.startsWith('/') ? '/' + piece : piece);
                if (!fs.existsSync(resolvePath(walked))) { firstCreated = walked; break; }
              }
            } else if (!fs.existsSync(path)) {
              firstCreated = String(dir);
            }
            bridge.mkdir(path);
            const mode = options && typeof options === 'object' ? options.mode : undefined;
            if (mode !== undefined) bridge.chmodPath(path, Number(mode));
            return recursive ? firstCreated : undefined;
          },
          rmdirSync: function(dir, options) {
            // Asked to remove a DIRECTORY and handed a file, this used to delete the file. node
            // raises ENOTDIR, which is the difference between a refusal and data loss.
            const raw = bridge.stat(resolvePath(dir), true);
            if (raw && !raw.dir) fs._fail('ENOTDIR', 'rmdir', dir, 'not a directory');
            if (!raw) fs._fail('ENOENT', 'rmdir', dir, 'no such file or directory');
            // node refuses a non-empty directory here; deleting one anyway is not a convenience.
            if (!(options && options.recursive)) {
              let entries = null;
              try { entries = bridge.readdir(resolvePath(dir)); } catch (error) { entries = null; }
              if (entries && entries.length) {
                throw Object.assign(new Error("ENOTEMPTY: directory not empty, rmdir '" + dir + "'"),
                                    { code: 'ENOTEMPTY', syscall: 'rmdir', path: dir });
              }
            }
            bridge.remove(resolvePath(dir));
          },
          rmSync: function(target, options) {
            const recursive = !!(options && options.recursive);
            const force = !!(options && options.force);
            const raw = bridge.stat(resolvePath(target), true);
            if (!raw) {
              if (force) return;                       // `force` silences a missing path
              throw Object.assign(new Error("ENOENT: no such file or directory, rm '" + target + "'"),
                                  { code: 'ENOENT', syscall: 'rm', path: target });
            }
            // Without `recursive`, node refuses a DIRECTORY outright — it does not quietly delete
            // the tree. This used to remove everything under it, which is the worst kind of
            // silently-ignored option: unasked-for destruction.
            if (raw.dir && !recursive) {
              throw Object.assign(new Error("ERR_FS_EISDIR: Path is a directory: rm '" + target + "'"),
                                  { code: 'ERR_FS_EISDIR', syscall: 'rm', path: target });
            }
            bridge.remove(resolvePath(target));
          },
          unlinkSync: function(file) {
            if (!bridge.remove(resolvePath(file))) {
              fs._fail('ENOENT', 'unlink', file, 'no such file or directory');
            }
          },
          renameSync: function(from, to) {
            if (!fs.existsSync(from)) fs._fail('ENOENT', 'rename', from, 'no such file or directory');
            bridge.rename(resolvePath(from), resolvePath(to));
          },
          copyFileSync: function(from, to) {
            if (!fs.existsSync(from)) fs._fail('ENOENT', 'copyfile', from, 'no such file or directory');
            fs.writeFileSync(to, fs.readFileSync(from));
          },
          realpathSync: function(file) { return resolvePath(file); },
          chmodSync: function() {},
          // node's full set, with THIS platform's values (dumped from real node on Darwin, not
          // guessed). Four of them is not "constants present": Go's wasm runtime reads
          // `constants.O_WRONLY` and friends directly, and an undefined there panics the whole
          // module with "call of Value.Int on undefined" — which is how esbuild-wasm died.
          constants: {
            COPYFILE_EXCL: 1, COPYFILE_FICLONE: 2, COPYFILE_FICLONE_FORCE: 4, F_OK: 0,
            O_APPEND: 8, O_CREAT: 512, O_DIRECTORY: 1048576, O_DSYNC: 4194304,
            O_EXCL: 2048, O_NOCTTY: 131072, O_NOFOLLOW: 256, O_NONBLOCK: 4,
            O_RDONLY: 0, O_RDWR: 2, O_SYMLINK: 2097152, O_SYNC: 128,
            O_TRUNC: 1024, O_WRONLY: 1, R_OK: 4, S_IFBLK: 24576,
            S_IFCHR: 8192, S_IFDIR: 16384, S_IFIFO: 4096, S_IFLNK: 40960,
            S_IFMT: 61440, S_IFREG: 32768, S_IFSOCK: 49152, S_IRGRP: 32,
            S_IROTH: 4, S_IRUSR: 256, S_IRWXG: 56, S_IRWXO: 7,
            S_IRWXU: 448, S_IWGRP: 16, S_IWOTH: 2, S_IWUSR: 128,
            S_IXGRP: 8, S_IXOTH: 1, S_IXUSR: 64, UV_DIRENT_BLOCK: 7,
            UV_DIRENT_CHAR: 6, UV_DIRENT_DIR: 2, UV_DIRENT_FIFO: 4, UV_DIRENT_FILE: 1,
            UV_DIRENT_LINK: 3, UV_DIRENT_SOCKET: 5, UV_DIRENT_UNKNOWN: 0, UV_FS_COPYFILE_EXCL: 1,
            UV_FS_COPYFILE_FICLONE: 2, UV_FS_COPYFILE_FICLONE_FORCE: 4, UV_FS_O_FILEMAP: 0,
            UV_FS_SYMLINK_DIR: 1, UV_FS_SYMLINK_JUNCTION: 2, W_OK: 2, X_OK: 1,
          },
          accessSync: function(file) {
            if (!fs.existsSync(file)) fs._fail('ENOENT', 'access', file, 'no such file or directory');
          },
        };
        // Callback forms wrap the sync forms through the event loop.
        for (const name of ['readFile', 'writeFile', 'appendFile', 'stat', 'lstat', 'readdir', 'mkdir', 'unlink', 'rename', 'copyFile', 'access', 'rm']) {
          fs[name] = function(...args) {
            const callback = typeof args[args.length - 1] === 'function' ? args.pop() : function(){};
            // An options bag may carry a signal; an already-aborted one must not do the work.
            const bag = args.length > 1 && args[args.length - 1] && typeof args[args.length - 1] === 'object'
              ? args[args.length - 1] : null;
            if (bag && bag.signal && bag.signal.aborted) {
              setImmediate(function(){ callback(globalThis.__abortError()); });
              return;
            }
            let cancelled = false;
            const stop = globalThis.__onAbort(bag && bag.signal, function() {
              cancelled = true;
              callback(globalThis.__abortError());
            });
            setImmediate(() => {
              if (cancelled) return;
              stop();
              try { callback(null, fs[name + 'Sync'].apply(null, args)); }
              catch (error) { callback(error); }
            });
          };
        }
        fs.exists = function(file, callback) { setImmediate(() => callback(fs.existsSync(file))); };
        // realpath + its `.native` variant (graceful-fs, which fs-extra layers on, patches it).
        fs.realpath = function(file, options, callback) {
          const cb = typeof options === 'function' ? options : callback;
          setImmediate(function(){ cb(null, resolvePath(file)); });
        };
        fs.realpath.native = fs.realpath;
        fs.realpathSync.native = fs.realpathSync;
        // The fd-based sync subset (log files, position reads). fd 1/2 write to the stdio.
        // (fileDescriptors/nextFd are declared above resolvePath so it can map fd → path.)
        function descriptor(fd) {
          const entry = fileDescriptors[fd];
          if (!entry) { const e = new Error('EBADF: bad file descriptor'); e.code = 'EBADF'; throw e; }
          return entry;
        }
        fs.openSync = function(file, flags, mode) {
          const path = resolvePath(file);
          // NUMERIC flags are how a syscall layer opens a file — Go's wasm runtime and every
          // WASI shim pass O_WRONLY|O_CREAT|O_TRUNC as a number, and `String(flags)` turned that
          // into "1537", which contains neither 'w' nor 'a' and so read as read-only. esbuild's
          // own output is written that way.
          let writable = false, append = false, truncate = false, create = false, exclusive = false;
          if (typeof flags === 'number') {
            writable = (flags & 3) !== 0;              // O_WRONLY | O_RDWR
            append = (flags & 8) !== 0;                // O_APPEND
            create = (flags & 512) !== 0;              // O_CREAT
            truncate = (flags & 1024) !== 0;           // O_TRUNC
            exclusive = (flags & 2048) !== 0;          // O_EXCL
          } else {
            const text = String(flags === undefined ? 'r' : flags);
            append = text.includes('a');
            truncate = text.includes('w');
            create = truncate || append;
            exclusive = text.includes('x');
            writable = create || text.includes('+');
          }
          const exists = fs.existsSync(path);
          if (exclusive && exists) fs._fail('EEXIST', 'open', file, 'file already exists');
          if (!exists) {
            if (!create) fs._fail('ENOENT', 'open', file, 'no such file or directory');
            fs.writeFileSync(path, '');
          } else if (truncate) {
            fs.writeFileSync(path, '');
          }
          const fd = nextFd++;
          // A descriptor keeps its own position, and an appending one starts at the end.
          fileDescriptors[fd] = {
            path: path, flags: flags, writable: writable, append: append,
            position: append && exists && !truncate ? fs.statSync(path).size : 0,
          };
          return fd;
        };
        // writeSync(fd, buffer[, offset[, length[, position]]]) — honor the slice, or a
        // program writing part of a scratch buffer would get the whole thing on disk.
        fs.writeSync = function(fd, data, offset, length, position) {
          // ANY view over bytes is legal here, not just our Buffer subclass: Go's wasm runtime
          // writes stdout through `fs.write(1, uint8Array, …)`, and `Buffer.isBuffer` is false
          // for a plain Uint8Array — so this used to stringify it ("7,0,0,0,…") and report that
          // string's length, which made Go panic with "invalid return from write".
          // node has TWO signatures here and they order their arguments differently:
          //   writeSync(fd, buffer, offset, length, position)
          //   writeSync(fd, string, position, encoding)
          // so for a string the third argument is the POSITION, not an offset into it. Reading a
          // string call with the buffer signature wrote at the wrong place, silently.
          if (typeof data === 'string') {
            const stringPosition = typeof offset === 'number' ? offset : null;
            const encodingName = typeof length === 'string' ? length : 'utf8';
            offset = undefined;
            length = undefined;
            position = stringPosition;
            data = Buffer.from(data, encodingName);
          }
          let buffer;
          if (Buffer.isBuffer(data)) buffer = data;
          else if (ArrayBuffer.isView(data)) buffer = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
          else buffer = Buffer.from(String(data));
          if (typeof offset === 'number') {
            const from = offset | 0;
            const count = typeof length === 'number' ? length | 0 : buffer.length - from;
            buffer = buffer.slice(from, from + count);
          }
          // A pipe carries bytes; latin1 is the transport that survives the String hop.
          const encoding = __stdioBinary ? 'latin1' : 'utf8';
          if (fd === 1) { bridge.stdout(buffer.toString(encoding)); return buffer.length; }
          if (fd === 2) { bridge.stderr(buffer.toString(encoding)); return buffer.length; }
          // A write goes AT a position — the one given, or the descriptor's own, which then
          // advances. Appending unconditionally made two writes to one descriptor produce the
          // content twice, and made a positional write land at the end instead.
          const entry = descriptor(fd);
          const at = typeof position === 'number' ? position
                   : (entry.append ? fs.statSync(entry.path).size : entry.position);
          const existing = fs.existsSync(entry.path) ? fs.readFileSync(entry.path) : Buffer.alloc(0);
          if (at >= existing.length) {
            // The ordinary case — writing at or past the end — stays a single append.
            const gap = at > existing.length ? Buffer.alloc(at - existing.length) : Buffer.alloc(0);
            fs.appendFileSync(entry.path, gap.length ? Buffer.concat([gap, buffer]) : buffer);
          } else {
            const tail = at + buffer.length < existing.length
              ? existing.slice(at + buffer.length) : Buffer.alloc(0);
            fs.writeFileSync(entry.path, Buffer.concat([existing.slice(0, at), buffer, tail]));
          }
          if (typeof position !== 'number') entry.position = at + buffer.length;
          return buffer.length;
        };
        fs.readSync = function(fd, buffer, offset, length, position) {
          // node 13 added `readSync(fd, buffer, { offset, length, position })`, and packages use
          // it — an engine that reads only the positional form returns nothing and says nothing.
          if (offset !== null && typeof offset === 'object') {
            const options = offset;
            position = options.position === undefined ? null : options.position;
            length = options.length === undefined ? buffer.length : options.length;
            offset = options.offset || 0;
          }
          // fd 0 is stdin, which is a pipe, not a file: serve it from whatever has arrived.
          if (fd === 0) {
            const pending = process.stdin.read();
            if (!pending || !pending.length) return 0;
            const bytes = Buffer.isBuffer(pending) ? pending : Buffer.from(String(pending), __stdioBinary ? 'latin1' : 'utf8');
            const count = Math.min(length === undefined ? bytes.length : length, bytes.length);
            for (let i = 0; i < count; i++) buffer[(offset || 0) + i] = bytes[i];
            // Anything that did not fit goes back, or it would be lost.
            if (count < bytes.length) process.stdin.unshift(bytes.slice(count));
            return count;
          }
          const entry = descriptor(fd);
          const content = fs.readFileSync(entry.path);
          const pos = position === null || position === undefined ? entry.position : position;
          const count = Math.max(0, Math.min(length, content.length - pos));
          for (let i = 0; i < count; i++) buffer[offset + i] = content[pos + i];
          if (position === null || position === undefined) entry.position += count;
          return count;
        };
        fs.closeSync = function(fd) { delete fileDescriptors[fd]; };
        fs.fsyncSync = function() {};
        fs.fdatasyncSync = function() {};
        fs.fstatSync = function(fd) { return fs.statSync(descriptor(fd).path); };
        fs.ftruncateSync = function(fd, length) { fs.truncateSync(descriptor(fd).path, length); };
        fs.truncateSync = function(file, length) {
          const target = resolvePath(file);
          const content = fs.readFileSync(target);
          fs.writeFileSync(target, content.slice(0, length === undefined ? 0 : length | 0));
        };
        // Times and ownership aren't tracked by the workspace bridge — accept and ignore,
        // like chmod. (tar extract calls these; failing would abort an otherwise fine
        // extraction. Recorded in system.md rather than silently pretended to work.)
        fs.utimesSync = function() {};
        fs.futimesSync = function() {};
        fs.lutimesSync = function() {};
        fs.chownSync = function() {};
        fs.fchownSync = function() {};
        fs.lchownSync = function() {};
        fs.fchmodSync = function() {};
        fs.lchmodSync = function() {};
        fs.mkdtempSync = function(prefix) {
          const suffix = Math.floor(Math.random() * 0x100000000).toString(36)
            + Math.floor(Math.random() * 0x100000000).toString(36);
          const dir = String(prefix) + suffix.slice(0, 6);
          fs.mkdirSync(dir);
          return dir;
        };
        // Symlinks have no bridge primitive: say so instead of pretending.
        function unsupported(name, code) {
          return function() {
            const error = new Error(code + ": " + name + " is not supported on this filesystem");
            error.code = code;
            throw error;
          };
        }
        fs.symlinkSync = unsupported('symlink', 'EPERM');
        fs.linkSync = unsupported('link', 'EPERM');
        fs.readlinkSync = function(file) {
          // node throws EINVAL when the target exists but isn't a link — ours never are.
          const target = resolvePath(file);
          const code = fs.existsSync(target) ? 'EINVAL' : 'ENOENT';
          const error = new Error(code + ": " + (code === 'EINVAL' ? 'invalid argument' : 'no such file or directory') + ", readlink '" + file + "'");
          error.code = code;
          throw error;
        };
        // Every remaining sync primitive gets its ASYNC callback twin, mechanically: node's
        // async forms are (…args, callback) and hand (error, value). tar and friends use the
        // callback forms (fs.open/read/close/lstat/readlink) as much as the sync ones.
        for (const name of ['open', 'read', 'write', 'close', 'fstat', 'fsync', 'fdatasync',
                            'ftruncate', 'truncate', 'chmod', 'fchmod', 'lchmod', 'chown',
                            'fchown', 'lchown', 'utimes', 'futimes', 'lutimes', 'mkdtemp',
                            'readlink', 'symlink', 'link', 'rmdir', 'realpath']) {
          if (fs[name] || !fs[name + 'Sync']) continue;
          fs[name] = (function(sync) {
            return function(...args) {
              const callback = typeof args[args.length - 1] === 'function' ? args.pop() : function(){};
              setImmediate(function() {
                try { callback(null, sync.apply(fs, args)); }
                catch (error) { callback(error); }
              });
            };
          })(fs[name + 'Sync']);
        }
        // fd 0's async read waits for bytes instead of reporting EOF. Go's wasm runtime reads
        // stdin this way, and a 0-byte answer tells it the pipe closed — which ended esbuild's
        // service the moment it started listening.
        const stdinRead = function(fd, buffer, offset, length, position, callback) {
          if (typeof offset === 'function') { callback = offset; offset = 0; length = buffer.length; }
          else if (typeof position === 'function') { callback = position; position = null; }
          // EXACTLY ONE callback per read, and both waiting listeners removed when either
          // fires. Waiting on 'readable' AND 'end' without this called back several times for
          // one read, which a caller reads as several reads — enough to desync any protocol.
          let settled = false;
          const attempt = function() {
            if (settled) return;
            let count = 0;
            try { count = fs.readSync(0, buffer, offset || 0, length === undefined ? buffer.length : length, null); }
            catch (error) { settled = true; done(); callback(error); return; }
            if (count > 0) { settled = true; done(); callback(null, count, buffer); return; }
            if (process.stdin._ended) { settled = true; done(); callback(null, 0, buffer); return; }
            process.stdin.once('readable', attempt);
            process.stdin.once('end', attempt);
          };
          const done = function() {
            if (process.stdin.off) {
              process.stdin.off('readable', attempt);
              process.stdin.off('end', attempt);
            }
          };
          attempt();
        };
        // read/write hand the BUFFER back as the third callback argument (node's contract:
        // (err, bytesRead, buffer) / (err, bytesWritten, buffer)) — the generic wrapper
        // above only passes two, and callers like tar read that third slot.
        for (const name of ['read', 'write']) {
          const sync = fs[name + 'Sync'];
          fs[name] = function(...args) {
            const callback = typeof args[args.length - 1] === 'function' ? args.pop() : function(){};
            const buffer = args[1];
            // Reading stdin is the one case that must WAIT rather than answer immediately.
            if (name === 'read' && args[0] === 0) {
              stdinRead(0, buffer, args[2], args[3], args[4], callback);
              return;
            }
            setImmediate(function() {
              try { callback(null, sync.apply(fs, args), buffer); }
              catch (error) { callback(error); }
            });
          };
        }
        // File streams ride the real stream module: a read stream pushes 64 KiB chunks
        // through the event loop; a write stream appends per chunk after an open truncate.
        fs.createReadStream = function(file, options) {
          const { Readable } = coreRequire('stream');
          const encoding = toEncoding(options);
          const stream = new Readable({ encoding: encoding });
          stream.path = file;
          stream.fd = null;
          stream.bytesRead = 0;
          stream.close = function(callback) { stream.destroy(); if (callback) callback(); return stream; };
          setImmediate(() => {
            let content;
            try { content = fs.readFileSync(file); }
            catch (error) {
              // node emits 'error' then 'close'. Without the close, a caller that releases its
              // resources there waits forever for a stream that already failed.
              stream.emit('error', error);
              process.nextTick(function() {
                if (!stream._closeEmitted) { stream._closeEmitted = true; stream.emit('close'); }
              });
              return;
            }
            stream.fd = 3;
            stream.emit('open', 3);
            stream.emit('ready');
            // `start`/`end` select a byte RANGE, inclusive of end — tar readers and HTTP range
            // responses depend on it, and ignoring them returned the whole file, which is wrong
            // DATA rather than an error.
            const from = options && options.start !== undefined ? Number(options.start) : 0;
            const to = options && options.end !== undefined ? Number(options.end) + 1 : content.length;
            content = content.slice(Math.max(0, from), Math.min(content.length, to));
            const CHUNK = options && options.highWaterMark ? Number(options.highWaterMark) : 65536;
            let offset = 0;
            const pushNext = () => {
              if (offset >= content.length) { stream.push(null); return; }
              stream.push(content.slice(offset, offset + CHUNK));
              offset += CHUNK;
              setImmediate(pushNext);
            };
            pushNext();
          });
          return stream;
        };
        fs.createWriteStream = function(file, options) {
          const { Writable } = coreRequire('stream');
          const append = options && (options.flags === 'a' || options.flags === 'a+');
          let opened = false;
          let announced = false;
          // 'open'/'ready' must precede the writes (node opens the fd first). Announcing from
          // a timer alone let a synchronous write beat them, producing the wrong order:
          // finish,close,open,ready. ensureOpen() runs at whichever comes first.
          function ensureOpen(stream) {
            if (!opened) {
              opened = true;
              if (!append) fs.writeFileSync(file, '');
              else if (!fs.existsSync(file)) fs.writeFileSync(file, '');
            }
            if (!announced) {
              announced = true;
              stream.fd = 3;
              stream.emit('open', 3);
              stream.emit('ready');
            }
          }
          const stream = new Writable({
            write(chunk, encoding, callback) {
              try {
                ensureOpen(stream);
                fs.appendFileSync(file, chunk);
                callback();
              } catch (error) { callback(error); }
            },
          });
          stream.path = file;
          // fs streams carry a handle surface (fd/close/bytesWritten) — tar's writers call
          // stream.close() and read .fd; a plain Writable would be missing them.
          stream.fd = null;
          stream.bytesWritten = 0;
          stream.close = function(callback) {
            stream.end(function(){ if (callback) callback(); });
            return stream;
          };
          const baseWrite = stream.write.bind(stream);
          stream.write = function(chunk, encoding, callback) {
            stream.bytesWritten += (chunk && chunk.length) ? chunk.length : 0;
            return baseWrite(chunk, encoding, callback);
          };
          setImmediate(() => {
            try { ensureOpen(stream); } catch (e) { stream.emit('error', e); }
          });
          return stream;
        };
        fs.watch = watch;
        fs.watchFile = watchFile;
        fs.unwatchFile = unwatchFile;
        // The class exports (instanceof checks) and the access-mode constants, which node
        // exposes BOTH on fs.constants and at the top level — `fs.access(p, fs.R_OK)` is the
        // form most code uses.
        fs.Stats = Stats;
        fs.Dirent = Dirent;
        fs.Dir = Dir;
        fs.F_OK = fs.constants.F_OK;
        fs.R_OK = fs.constants.R_OK;
        fs.W_OK = fs.constants.W_OK;
        fs.X_OK = fs.constants.X_OK;
        fs.cpSync = cpSync;
        fs.cp = function(from, to, options, callback) {
          if (typeof options === 'function') { callback = options; options = {}; }
          try { cpSync(from, to, options); if (callback) process.nextTick(function(){ callback(null); }); }
          catch (error) { if (callback) process.nextTick(function(){ callback(error); }); else throw error; }
        };
        fs.writevSync = writevSync;
        fs.readvSync = readvSync;
        fs.writev = function(fd, buffers, position, callback) {
          if (typeof position === 'function') { callback = position; position = null; }
          try {
            const written = writevSync(fd, buffers, position);
            process.nextTick(function(){ callback(null, written, buffers); });
          } catch (error) { process.nextTick(function(){ callback(error); }); }
        };
        fs.readv = function(fd, buffers, position, callback) {
          if (typeof position === 'function') { callback = position; position = null; }
          try {
            const read = readvSync(fd, buffers, position);
            process.nextTick(function(){ callback(null, read, buffers); });
          } catch (error) { process.nextTick(function(){ callback(error); }); }
        };
        fs.opendirSync = function(target, options) {
          const entries = fs.readdirSync(target, { withFileTypes: true });
          return new Dir(resolvePath(target), entries);
        };
        fs.opendir = function(target, options, callback) {
          if (typeof options === 'function') { callback = options; options = {}; }
          try {
            const dir = fs.opendirSync(target, options);
            if (callback) { process.nextTick(function(){ callback(null, dir); }); return; }
            return Promise.resolve(dir);
          } catch (error) {
            if (callback) { process.nextTick(function(){ callback(error); }); return; }
            return Promise.reject(error);
          }
        };
        fs.statfsSync = function(target) {
          const raw = bridge.statfs(resolvePath(target));
          if (!raw) {
            const error = new Error("ENOENT: no such file or directory, statfs '" + target + "'");
            error.code = 'ENOENT';
            throw error;
          }
          return raw;
        };
        fs.statfs = function(target, options, callback) {
          if (typeof options === 'function') { callback = options; options = {}; }
          try {
            const info = fs.statfsSync(target);
            process.nextTick(function(){ callback(null, info); });
          } catch (error) { process.nextTick(function(){ callback(error); }); }
        };
        fs.openAsBlob = function(target, options) {
          return Promise.resolve().then(function(){
            const data = fs.readFileSync(target);
            return new Blob([data], { type: (options && options.type) || '' });
          });
        };
        // The stream classes, so `instanceof fs.ReadStream` works. FileReadStream /
        // FileWriteStream are node's legacy aliases for the same things.
        fs.ReadStream = function ReadStream(target, options) { return fs.createReadStream(target, options); };
        fs.WriteStream = function WriteStream(target, options) { return fs.createWriteStream(target, options); };
        fs.FileReadStream = fs.ReadStream;
        fs.FileWriteStream = fs.WriteStream;
        // fs.glob is node 22's built-in matcher. Not implemented rather than
        // half-implemented: glob semantics (**, braces, character classes, negation) are a
        // corpus of edge cases, and the `glob` package already runs correctly on this engine.
        // Glob matching. The refusal here said a partial matcher would be worse than none, which
        // is a fair judgement about risk rather than a claim of impossibility — so it is settled
        // the way this repo settles that question elsewhere (msh against /bin/sh, the screen
        // against pyte): build it, then prove it on a corpus big enough that "partial" is a
        // measured claim. Every rule below was read off real node, including the ones that
        // surprised me: matching is CASE-INSENSITIVE on darwin, `**` refuses dot segments, and
        // `a/**` does not match a bare `a`.
        function expandBraces(pattern) {
          const open = pattern.indexOf('{');
          if (open < 0) return [pattern];
          // Find this brace's partner, skipping nested groups.
          let depth = 0, close = -1;
          for (let i = open; i < pattern.length; i++) {
            if (pattern[i] === '\\') { i += 1; continue; }
            if (pattern[i] === '{') depth += 1;
            else if (pattern[i] === '}') { depth -= 1; if (depth === 0) { close = i; break; } }
          }
          if (close < 0) return [pattern];        // unbalanced: a literal brace
          const head = pattern.slice(0, open), tail = pattern.slice(close + 1);
          const body = pattern.slice(open + 1, close);
          const parts = [];
          let depth2 = 0, current = '';
          for (let i = 0; i < body.length; i++) {
            const ch = body[i];
            if (ch === '\\') { current += ch + (body[i + 1] || ''); i += 1; continue; }
            if (ch === '{') depth2 += 1;
            if (ch === '}') depth2 -= 1;
            if (ch === ',' && depth2 === 0) { parts.push(current); current = ''; continue; }
            current += ch;
          }
          parts.push(current);
          const out = [];
          for (const part of parts) {
            for (const expanded of expandBraces(head + part + tail)) out.push(expanded);
          }
          return out;
        }

        /// One path segment's pattern as a regex body. `atStart` carries the dot rule: a wildcard
        /// at the start of a segment must not match a leading dot.
        function segmentRegex(segment) {
          let out = '';
          let index = 0;
          let sawWildcardFirst = false;
          while (index < segment.length) {
            const ch = segment[index];
            if (ch === '\\') {
              const next = segment[index + 1];
              if (next === undefined) { out += '\\\\'; index += 1; continue; }
              out += next.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
              index += 2;
              continue;
            }
            if (ch === '*') {
              if (index === 0) sawWildcardFirst = true;
              out += '[^/]*';
              index += 1;
              continue;
            }
            if (ch === '?') {
              if (index === 0) sawWildcardFirst = true;
              out += '[^/]';
              index += 1;
              continue;
            }
            if (ch === '[') {
              // A class: ! or ^ negates, and a ] immediately after those is literal.
              let cursor = index + 1;
              let negated = false;
              if (segment[cursor] === '!' || segment[cursor] === '^') { negated = true; cursor += 1; }
              let body = '';
              if (segment[cursor] === ']') { body += '\\]'; cursor += 1; }
              while (cursor < segment.length && segment[cursor] !== ']') {
                const inner = segment[cursor];
                if (inner === '\\') { body += '\\' + (segment[cursor + 1] || ''); cursor += 2; continue; }
                // A '-' keeps its meaning inside a class; everything else that matters is escaped.
                body += inner === '-' ? '-' : inner.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
                cursor += 1;
              }
              if (cursor >= segment.length) {
                // Unterminated: a literal '['.
                out += '\\[';
                index += 1;
                continue;
              }
              if (index === 0) sawWildcardFirst = true;
              out += '[' + (negated ? '^' : '') + body + ']';
              index = cursor + 1;
              continue;
            }
            out += ch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            index += 1;
          }
          // The dot rule, and only when the segment can match something: `*` never matches
          // `.hidden`, but the literal `.hidden` does.
          return (sawWildcardFirst ? '(?!\\.)' : '') + out;
        }

        // One or more segments, none of them starting with a dot.
        const deepSegments = '(?:(?!\\.)[^/]+/)*(?!\\.)[^/]+';

        function globRegex(pattern) {
          const segments = String(pattern).split('/');
          let body = '';
          for (let i = 0; i < segments.length; i++) {
            const segment = segments[i];
            const last = i === segments.length - 1;
            if (segment === '**') {
              if (last) {
                // A TRAILING ** also matches nothing at all, so `src/**` includes `src` itself —
                // node's glob does that, and the optional leading slash is what expresses it.
                if (body.endsWith('/')) body = body.slice(0, -1);
                body += body.length ? '(?:/' + deepSegments + ')?' : deepSegments;
                continue;
              }
              // Consuming the following slash is what lets `**/b` match a bare `b`.
              body += '(?:(?!\\.)[^/]+/)*';
              continue;
            }
            body += segmentRegex(segment);
            if (!last) body += '/';
          }
          return new RegExp('^' + body + '$');
        }

        const globCache = {};
        function matchesGlob(target, pattern) {
          const key = String(pattern);
          if (!globCache[key]) {
            globCache[key] = expandBraces(key).map(globRegex);
          }
          const text = String(target);
          return globCache[key].some(function(expression){ return expression.test(text); });
        }
        globalThis.__matchesGlob = matchesGlob;

        /// fs.glob walks the tree under cwd and reports the paths that match, which is node's
        /// shape: results are relative to cwd unless `options.cwd` says otherwise.
        function globWalk(pattern, options) {
          options = options || {};
          const root = options.cwd ? String(options.cwd) : process.cwd();
          // `exclude` is refused rather than guessed: node hands the callback a bare entry NAME
          // for some entries ('c.js', 'e.js', 'deep') and a relative PATH for others ('src/deep',
          // 'lib'), depending on where the walk is. A filter that silently disagrees about which
          // files it saw is worse than one that says it cannot.
          if (options.exclude !== undefined) {
            throw Object.assign(
              new Error('fs.glob\'s `exclude` option is not available: node passes it a bare ' +
                        'entry name for nested entries and a relative path for others, so a ' +
                        'filter here would disagree about what it was shown. Filter the ' +
                        'returned list instead'),
              { code: 'ERR_METHOD_NOT_IMPLEMENTED' });
          }
          const found = [];
          const walk = function(relative) {
            const absolute = relative ? (root.replace(/\/$/, '') + '/' + relative) : root;
            let entries;
            try { entries = fs.readdirSync(absolute, { withFileTypes: true }); }
            catch (error) { return; }
            for (const entry of entries) {
              const child = relative ? relative + '/' + entry.name : entry.name;
              if (matchesGlob(child, pattern)) found.push(child);
              if (entry.isDirectory()) walk(child);
            }
          };
          walk('');
          return found;
        }

        fs.globSync = function(pattern, options) { return globWalk(pattern, options); };
        fs.glob = function(pattern, options, callback) {
          if (typeof options === 'function') { callback = options; options = undefined; }
          let found, failure = null;
          try { found = globWalk(pattern, options); } catch (error) { failure = error; }
          process.nextTick(function(){ callback(failure, failure ? undefined : found); });
        };
        function refuseHere(name) {
          return function() {
            const error = new Error('fs.' + name + ' is not available: glob semantics are a corpus of edge cases and a partial matcher would be worse than none — the `glob` package works on this engine');
            error.code = 'ERR_METHOD_NOT_IMPLEMENTED';
            throw error;
          };
        }
        // Deliberately NOT exporting FSWatcher: real node 22 does not (measured), and a
        // surface we invent is a surface that diverges.
        fs.promises = {};
        // fs.promises.watch is the async-iterator form, not a promise of a watcher.
        fs.promises.watch = function(target, options) { return watch(target, options); };
        fs.promises.constants = fs.constants;
        fs.promises.open = function(target, flags, mode) {
          return Promise.resolve().then(function(){
            const fd = fs.openSync(target, flags === undefined ? 'r' : flags, mode);
            return new FileHandle(fd, target);
          });
        };
        fs.promises.opendir = function(target, options) { return fs.opendir(target, options); };
        fs.promises.cp = function(from, to, options) {
          return Promise.resolve().then(function(){ return cpSync(from, to, options); });
        };
        fs.promises.statfs = function(target) {
          return Promise.resolve().then(function(){ return fs.statfsSync(target); });
        };
        fs.promises.glob = fs.glob;
        // Everything with a *Sync twin gets promisified, which is what node's promises API is.
        for (const name of ['readFile', 'writeFile', 'appendFile', 'stat', 'lstat', 'readdir',
                            'mkdir', 'unlink', 'rename', 'copyFile', 'access', 'rm', 'rmdir',
                            'realpath', 'readlink', 'symlink', 'link', 'chmod', 'chown',
                            'lchmod', 'lchown', 'utimes', 'lutimes', 'mkdtemp', 'truncate']) {
          fs.promises[name] = function(...args) {
            return new Promise((resolve, reject) => {
              const bag = args.length > 1 && args[args.length - 1] && typeof args[args.length - 1] === 'object'
                ? args[args.length - 1] : null;
              if (bag && bag.signal && bag.signal.aborted) { reject(globalThis.__abortError()); return; }
              let cancelled = false;
              const stop = globalThis.__onAbort(bag && bag.signal, function() {
                cancelled = true;
                reject(globalThis.__abortError());
              });
              try {
                const value = fs[name + 'Sync'].apply(null, args);
                if (!cancelled) { stop(); resolve(value); }
              } catch (error) { if (!cancelled) { stop(); reject(error); } }
            });
          };
        }
        return fs;
      };
      coreFactories['fs/promises'] = function() { return coreRequire('fs').promises; };
      coreFactories['path/posix'] = function() { return coreRequire('path').posix; };
      coreFactories['path/win32'] = function() { return coreRequire('path').win32; };

      coreFactories.tty = function() {
        return {
          isatty: function(fd){ return __isTTY && (fd === 0 || fd === 1 || fd === 2); },
          ReadStream: function(){ return process.stdin; },
          WriteStream: function(){ return process.stdout; },
        };
      };

      coreFactories.assert = function() {
        // CallTracker and partialDeepStrictEqual, from the audit. CallTracker is how node's
        // own tests assert a function ran N times; partialDeepStrictEqual checks a subset.
        function CallTracker() {
          const tracked = [];
          this.calls = function(fn, exact) {
            if (typeof fn === 'number') { exact = fn; fn = function(){}; }
            if (exact === undefined) exact = 1;
            const record = { fn: fn, exact: exact, actual: 0 };
            tracked.push(record);
            return function() { record.actual += 1; return fn.apply(this, arguments); };
          };
          this.report = function() {
            return tracked.filter(r => r.actual !== r.exact).map(r => ({
              message: 'Expected the function to be called ' + r.exact + ' times but it was called ' + r.actual + ' times.',
              actual: r.actual, expected: r.exact, operator: r.fn.name || 'calls',
            }));
          };
          this.getCalls = function(fn) { return tracked.filter(r => r.fn === fn); };
          this.verify = function() {
            const problems = this.report();
            if (problems.length) throw Object.assign(new Error(problems.map(p => p.message).join('\n')),
                                                     { code: 'ERR_ASSERTION' });
          };
        }
        function partialMatch(actual, expected) {
          if (expected === null || typeof expected !== 'object') return actual === expected;
          if (actual === null || typeof actual !== 'object') return false;
          if (Array.isArray(expected)) {
            if (!Array.isArray(actual) || actual.length < expected.length) return false;
            return expected.every((item, index) => partialMatch(actual[index], item));
          }
          return Object.keys(expected).every(key => partialMatch(actual[key], expected[key]));
        }
        // node's assert throws an AssertionError, not an Error, and test runners READ its
        // fields: mocha renders its diff from `actual`/`expected`, and tools classify by
        // `code === 'ERR_ASSERTION'`. Every assertion here used to throw a bare Error with a
        // message like "not deeply equal", which names no value and locates nothing.
        class AssertionError extends Error {
          constructor(options) {
            super(options.message);
            this.name = 'AssertionError';
            this.code = 'ERR_ASSERTION';
            this.actual = options.actual;
            this.expected = options.expected;
            this.operator = options.operator;
            this.generatedMessage = options.generatedMessage;
          }
        }
        // A caller's `message` always wins, and marks the message as not generated.
        function fail(options, message) {
          if (message instanceof Error) throw message;
          throw new AssertionError({
            message: message === undefined || message === null ? options.message : String(message),
            actual: options.actual, expected: options.expected, operator: options.operator,
            // node reports these as NOT generated even when it wrote them itself — the
            // missing-exception family is fixed text, not a rendering of the values.
            generatedMessage: options.generated === false
              ? false : (message === undefined || message === null),
          });
        }
        // node inspects with `compact: false` in these messages, so every entry sits on its own
        // line — which is what makes the deep-equal diff readable line by line.
        function expand(value, indent) {
          const pad = ' '.repeat(indent), inner = ' '.repeat(indent + 2);
          if (value === null || typeof value !== 'object') return inspect(value);
          if (value instanceof Date || value instanceof RegExp) return inspect(value);
          if (ArrayBuffer.isView(value)) return inspect(value);
          if (Array.isArray(value)) {
            if (!value.length) return '[]';
            return '[\n' + value.map(item => inner + expand(item, indent + 2)).join(',\n') + '\n' + pad + ']';
          }
          if (value instanceof Map) {
            if (!value.size) return 'Map(0) {}';
            const parts = [];
            for (const [key, item] of value) parts.push(inner + expand(key, indent + 2) + ' => ' + expand(item, indent + 2));
            return 'Map(' + value.size + ') {\n' + parts.join(',\n') + '\n' + pad + '}';
          }
          if (value instanceof Set) {
            if (!value.size) return 'Set(0) {}';
            const parts = [];
            for (const item of value) parts.push(inner + expand(item, indent + 2));
            return 'Set(' + value.size + ') {\n' + parts.join(',\n') + '\n' + pad + '}';
          }
          const keys = Object.keys(value);
          if (!keys.length) return '{}';
          return '{\n' + keys.map(key => inner + quoteKey(key) + ': ' + expand(value[key], indent + 2)).join(',\n') +
                 '\n' + pad + '}';
        }
        // The +/- body of a strict deep-equal failure: both values expanded, then a line diff.
        // Common lines carry a two-space prefix, so a marker replaces it without shifting text.
        function diffLines(actual, expected, label) {
          // `label` renders node's "Comparison { … }" — the pseudo-object it diffs when an
          // expected-error matcher fails, holding only the keys the matcher named.
          const head = text => label ? text.replace(/^\{/, label + '{') : text;
          const a = head(expand(actual, 0)).split('\n'), b = head(expand(expected, 0)).split('\n');
          // Longest common subsequence over lines — the sequences here are small.
          const table = [];
          for (let i = 0; i <= a.length; i++) table.push(new Array(b.length + 1).fill(0));
          for (let i = a.length - 1; i >= 0; i--) {
            for (let j = b.length - 1; j >= 0; j--) {
              table[i][j] = a[i] === b[j] ? table[i + 1][j + 1] + 1
                                          : Math.max(table[i + 1][j], table[i][j + 1]);
            }
          }
          const out = [];
          let i = 0, j = 0;
          while (i < a.length && j < b.length) {
            if (a[i] === b[j]) { out.push('  ' + a[i]); i++; j++; }
            else if (table[i + 1][j] >= table[i][j + 1]) { out.push('+ ' + a[i]); i++; }
            else { out.push('- ' + b[j]); j++; }
          }
          while (i < a.length) out.push('+ ' + a[i++]);
          while (j < b.length) out.push('- ' + b[j++]);
          return out.join('\n');
        }
        function assert(value, message) {
          if (value) return;
          fail({ message: 'The expression evaluated to a falsy value:\n\n  assert.ok(' + inspect(value) + ')\n',
                 actual: value, expected: true, operator: '==' }, message);
        }
        assert.ok = assert;
        assert.AssertionError = AssertionError;
        assert.equal = function(a, b, message) {
          if (a == b) return;
          fail({ message: inspect(a) + ' == ' + inspect(b), actual: a, expected: b, operator: '==' }, message);
        };
        assert.notEqual = function(a, b, message) {
          if (a != b) return;
          fail({ message: inspect(a) + ' != ' + inspect(b), actual: a, expected: b, operator: '!=' }, message);
        };
        assert.strictEqual = function(a, b, message) {
          if (Object.is(a, b)) return;
          fail({ message: 'Expected values to be strictly equal:\n\n' + inspect(a) + ' !== ' + inspect(b) + '\n',
                 actual: a, expected: b, operator: 'strictEqual' }, message);
        };
        assert.notStrictEqual = function(a, b, message) {
          if (!Object.is(a, b)) return;
          fail({ message: 'Expected "actual" to be strictly unequal to: ' + inspect(b),
                 actual: a, expected: b, operator: 'notStrictEqual' }, message);
        };
        assert.deepStrictEqual = function(a, b, message) {
          if (globalThis.__deepEqual(a, b, true)) return;
          fail({ message: 'Expected values to be strictly deep-equal:\n+ actual - expected\n\n' +
                          diffLines(a, b) + '\n',
                 actual: a, expected: b, operator: 'deepStrictEqual' }, message);
        };
        assert.notDeepStrictEqual = function(a, b, message) {
          if (!globalThis.__deepEqual(a, b, true)) return;
          fail({ message: 'Expected "actual" not to be strictly deep-equal to:\n\n' + expand(a, 0) + '\n',
                 actual: a, expected: b, operator: 'notDeepStrictEqual' }, message);
        };
        assert.deepEqual = function(a, b, message) {
          if (globalThis.__deepEqual(a, b, false)) return;
          fail({ message: 'Expected values to be loosely deep-equal:\n\n' + expand(a, 0) +
                          '\n\nshould loosely deep-equal\n\n' + expand(b, 0),
                 actual: a, expected: b, operator: 'deepEqual' }, message);
        };
        assert.notDeepEqual = function(a, b, message) {
          if (!globalThis.__deepEqual(a, b, false)) return;
          fail({ message: 'Expected "actual" not to be loosely deep-equal to:\n\n' + expand(a, 0) + '\n',
                 actual: a, expected: b, operator: 'notDeepEqual' }, message);
        };
        assert.fail = function(message) {
          if (message instanceof Error) throw message;
          fail({ message: 'Failed', actual: undefined, expected: undefined, operator: 'fail' }, message);
        };
        assert.ifError = function(value) {
          if (!value) return;
          const described = value instanceof Error ? value.message : inspect(value);
          throw new AssertionError({ message: 'ifError got unwanted exception: ' + described,
                                     actual: value, expected: null, operator: 'ifError',
                                     generatedMessage: false });
        };
        // The expected-error argument was IGNORED, so `assert.throws(fn, RangeError)` passed on
        // any throw at all — a test asserting a specific failure silently accepted the wrong one.
        function errorMatches(error, expected) {
          if (expected instanceof RegExp) return expected.test(String(error));
          if (typeof expected === 'function') {
            // A class to instantiate against, or a predicate returning true.
            if (expected.prototype !== undefined && error instanceof expected) return true;
            return expected(error) === true;
          }
          if (expected && typeof expected === 'object') {
            return Object.keys(expected).every(key => {
              const want = expected[key];
              if (want instanceof RegExp) return want.test(String(error[key]));
              return globalThis.__deepEqual(error[key], want, true);
            });
          }
          return true;
        }
        function describeExpected(expected) {
          if (typeof expected === 'function' && expected.name) return expected.name;
          return inspect(expected);
        }
        assert.throws = function(fn, expected, message) {
          if (typeof expected === 'string' && message === undefined) { message = expected; expected = undefined; }
          let thrown, threw = false;
          try { fn(); } catch (error) { thrown = error; threw = true; }
          if (!threw) {
            fail({ message: 'Missing expected exception.', generated: false, actual: undefined, expected: expected,
                   operator: 'throws' }, message);
          }
          if (expected === undefined || errorMatches(thrown, expected)) return;
          if (expected instanceof RegExp) {
            fail({ message: 'The input did not match the regular expression ' + expected +
                            '. Input:\n\n' + inspect(String(thrown)) + '\n',
                   actual: thrown, expected: expected, operator: 'throws' }, message);
          }
          if (expected && typeof expected === 'object') {
            // Only the keys the matcher named are compared, so the diff shows the properties
            // that were actually asserted rather than the whole error.
            const comparison = {};
            for (const key of Object.keys(expected)) comparison[key] = thrown ? thrown[key] : undefined;
            fail({ message: 'Expected values to be strictly deep-equal:\n+ actual - expected\n\n' +
                            diffLines(comparison, expected, 'Comparison ') + '\n',
                   actual: comparison, expected: expected, operator: 'throws' }, message);
          }
          fail({ message: 'The error is expected to be an instance of "' + describeExpected(expected) +
                          '". Received "' + (thrown && thrown.name ? thrown.name : inspect(thrown)) +
                          '"\n\nError message:\n\n' + (thrown && thrown.message !== undefined ? thrown.message : ''),
                 actual: thrown, expected: expected, operator: 'throws' }, message);
        };
        assert.doesNotThrow = function(fn, expected, message) {
          if (typeof expected === 'string' && message === undefined) { message = expected; expected = undefined; }
          try { fn(); } catch (error) {
            if (expected !== undefined && !errorMatches(error, expected)) throw error;
            fail({ message: 'Got unwanted exception.\nActual message: "' +
                            (error && error.message !== undefined ? error.message : String(error)) + '"',
                   actual: error, expected: expected, generated: false, operator: 'doesNotThrow' }, message);
          }
        };
        // The async halves. `rejects` takes a promise or a function returning one.
        assert.rejects = async function(target, expected, message) {
          if (typeof expected === 'string' && message === undefined) { message = expected; expected = undefined; }
          let thrown, threw = false;
          try { await (typeof target === 'function' ? target() : target); }
          catch (error) { thrown = error; threw = true; }
          if (!threw) {
            fail({ message: 'Missing expected rejection.', generated: false, actual: undefined, expected: expected,
                   operator: 'rejects' }, message);
          }
          if (expected === undefined || errorMatches(thrown, expected)) return;
          fail({ message: 'The error is expected to be an instance of "' + describeExpected(expected) +
                          '". Received "' + (thrown && thrown.name ? thrown.name : inspect(thrown)) + '"',
                 actual: thrown, expected: expected, operator: 'rejects' }, message);
        };
        assert.doesNotReject = async function(target, expected, message) {
          if (typeof expected === 'string' && message === undefined) { message = expected; expected = undefined; }
          try { await (typeof target === 'function' ? target() : target); }
          catch (error) {
            if (expected !== undefined && !errorMatches(error, expected)) throw error;
            fail({ message: 'Got unwanted rejection.\nActual message: "' +
                            (error && error.message !== undefined ? error.message : String(error)) + '"',
                   actual: error, expected: expected, generated: false, operator: 'doesNotReject' }, message);
          }
        };
        assert.match = function(value, regexp, message) {
          if (regexp.test(value)) return;
          fail({ message: 'The input did not match the regular expression ' + regexp + '. Input:\n\n' +
                          inspect(value) + '\n',
                 actual: value, expected: regexp, operator: 'match' }, message);
        };
        assert.doesNotMatch = function(value, regexp, message) {
          if (!regexp.test(value)) return;
          fail({ message: 'The input was expected to not match the regular expression ' + regexp +
                          '. Input:\n\n' + inspect(value) + '\n',
                 actual: value, expected: regexp, operator: 'doesNotMatch' }, message);
        };
        assert.strict = assert;
        assert.CallTracker = CallTracker;
        assert.Assert = function Assert(){ return assert; };
        assert.partialDeepStrictEqual = function(actual, expected, message) {
          if (!partialMatch(actual, expected)) {
            throw Object.assign(new Error(message || 'Expected actual to partially match expected'),
                                { code: 'ERR_ASSERTION', actual: actual, expected: expected,
                                  operator: 'partialDeepStrictEqual' });
          }
        };
        return assert;
      };

      coreFactories.string_decoder = function() {
        // node validates the encoding name and throws ERR_UNKNOWN_ENCODING otherwise.
        // A UTF-8 lead byte announces how many bytes the character occupies.
        function utf8SequenceLength(lead) {
          if (lead >= 0xF0) return 4;
          if (lead >= 0xE0) return 3;
          if (lead >= 0xC0) return 2;
          return 1;
        }
        function StringDecoder(encoding) {
          const name = encoding === undefined || encoding === null ? 'utf8' : String(encoding).toLowerCase();
          const known = ['utf8', 'utf-8', 'ucs2', 'ucs-2', 'utf16le', 'utf-16le', 'latin1',
                         'binary', 'base64', 'base64url', 'hex', 'ascii'];
          if (!known.includes(name)) {
            const error = new TypeError('Unknown encoding: ' + encoding);
            error.code = 'ERR_UNKNOWN_ENCODING';
            throw error;
          }
          this.encoding = name === 'utf-8' ? 'utf8' : name;
          // node exposes the HELD state directly, and libraries read it to decide whether a
          // chunk boundary is safe to cut on. Views onto the same carry, not a second copy.
          Object.defineProperties(this, {
            lastChar: { get: function(){
              const held = this._carry || Buffer.alloc(0);
              const room = Buffer.alloc(4);
              held.copy(room);
              return room;
            }, configurable: true },
            lastNeed: { get: function(){ return this._carryNeed || 0; }, configurable: true },
            lastTotal: { get: function(){ return this._carryTotal || 0; }, configurable: true },
          });
        }
        // Holding an incomplete character across writes is the ONE thing a StringDecoder is for,
        // and this had none of it: `write` was a bare toString, so a multi-byte character split
        // across chunks decoded to replacement characters. Same defect TextDecoder had, in the
        // module whose entire purpose is to not have it.
        StringDecoder.prototype.write = function(buffer) {
          if (!buffer || !buffer.length) return '';
          let bytes = Buffer.from(buffer);
          if (this._carry && this._carry.length) {
            bytes = Buffer.concat([this._carry, bytes]);
            this._carry = null;
            this._carryNeed = 0;
            this._carryTotal = 0;
          }
          let hold = 0;
          if (this.encoding === 'utf8') {
            hold = incompleteTailLength(bytes);
          } else if (this.encoding === 'utf16le' || this.encoding === 'ucs2' || this.encoding === 'ucs-2') {
            // An odd trailing byte is half a code unit; a trailing HIGH surrogate is half a
            // character and has to wait for its pair.
            hold = bytes.length % 2;
            const usable = bytes.length - hold;
            if (usable >= 2) {
              const lastUnit = bytes[usable - 2] | (bytes[usable - 1] << 8);
              if (lastUnit >= 0xD800 && lastUnit <= 0xDBFF) hold += 2;
            }
          } else if (this.encoding === 'base64' || this.encoding === 'base64url') {
            hold = bytes.length % 3;         // base64 works in groups of three bytes
          }
          if (hold > 0) {
            this._carry = bytes.slice(bytes.length - hold);
            // How many more bytes this character wants, and how wide it is in total — node
            // reports both, and they are exactly what the hold computation already knows.
            this._carryTotal = this.encoding === 'utf8' ? utf8SequenceLength(this._carry[0]) : hold;
            this._carryNeed = Math.max(0, this._carryTotal - this._carry.length);
            bytes = bytes.slice(0, bytes.length - hold);
          }
          return bytes.length ? bytes.toString(this.encoding) : '';
        };
        StringDecoder.prototype.end = function(buffer) {
          // Whatever is left is emitted as-is: at the end there is no more input to complete it.
          let tail = this._carry || Buffer.alloc(0);
          if (buffer && buffer.length) tail = Buffer.concat([tail, Buffer.from(buffer)]);
          this._carry = null;
          return tail.length ? tail.toString(this.encoding) : '';
        };
        return { StringDecoder };
      };

      coreFactories.stream = function() {
        const EventEmitter = coreRequire('events');
        // The legacy Stream base carries the classic `pipe` — packages that extend Stream
        // directly (mute-stream under inquirer) call `super.pipe`.
        function Stream() { EventEmitter.call(this); }
        Stream.prototype = Object.create(EventEmitter.prototype);
        Stream.prototype.constructor = Stream;
        Stream.prototype.pipe = function pipe(dest, options) {
            const source = this;
            function onData(chunk) {
              if (dest.write && dest.write(chunk) === false && source.pause) source.pause();
            }
            source.on('data', onData);
            function onDrain() { if (source.resume) source.resume(); }
            if (dest.on) dest.on('drain', onDrain);
            if (!options || options.end !== false) {
              source.on('end', function(){ if (dest.end) dest.end(); });
            }
            if (dest.emit) dest.emit('pipe', source);
            return dest;
        };

        // Real Readable semantics: an internal buffer, paused vs flowing modes, 'readable'
        // in paused mode, _read pull, async iteration, and pipe with backpressure.
        // Constructor FUNCTIONS, not classes: the dominant legacy stream idiom in npm is
        // `util.inherits(MyStream, Readable); Readable.call(this, opts)`, and a class
        // constructor throws when called without `new` — the same reason EventEmitter is a
        // function here. Methods live on the prototype so util.inherits chains find them.
        // 'close' is emitted ONCE PER STREAM, not once per side. A Duplex whose readable side
        // ended AND whose writable side finished reached both close paths and emitted twice —
        // which any `let done = 0; if (++done === n)` counter reads as double the work
        // finishing (found on a net fixture where 5 connections reported 5 closes after 3).
        function emitCloseOnce(stream) {
          // A socket's 'close' means THE FILE DESCRIPTOR is gone, not "this stream's sides
          // finished": net.Socket sets `_hostOwnsClose` and emits it from the host event
          // instead. Letting the writable side emit it made `client.end()` announce a close
          // while the fd was still open — a fixture that called `server.close()` from the
          // client's 'close' handler then shut the listener down mid-exchange and both ends
          // waited forever.
          if (stream._closeEmitted || stream._hostOwnsClose) return;
          stream._closeEmitted = true;
          stream.emit('close');
        }
        // node's streams carry `_readableState` / `_writableState`, and real packages READ
        // them — `ws` decides how to finish a closing handshake from
        // `socket._readableState.endEmitted` and `receiver._writableState.finished`, so with
        // these missing its close handler threw and a WebSocket never emitted 'close'. They
        // are exposed as LIVE VIEWS over the fields we already keep, not as a second copy of
        // the truth: every property is a getter, and the few libraries write to are mapped
        // back onto the real field.
        function defineStateView(prototype, name, describe) {
          Object.defineProperty(prototype, name, {
            configurable: true,
            get: function() {
              const hidden = '_' + name + 'View';
              if (!this[hidden]) {
                const view = {};
                const spec = describe(this);
                for (const key of Object.keys(spec)) {
                  const entry = spec[key];
                  Object.defineProperty(view, key, {
                    enumerable: true, configurable: true,
                    get: entry.get,
                    set: entry.set || function(){},   // writes libraries make but we derive
                  });
                }
                Object.defineProperty(this, hidden, { value: view, writable: true, enumerable: false });
              }
              return this[hidden];
            },
          });
        }
        function readableStateSpec(stream) {
          return {
            objectMode: { get: () => !!stream._objectMode },
            highWaterMark: { get: () => 16384 },
            buffer: { get: () => stream._buf || [] },
            length: { get: () => (stream._buf || []).reduce((n, c) => n + (c.length || 1), 0) },
            pipes: { get: () => [] },
            flowing: { get: () => (stream._flowing ? true : (stream._everFlowed ? false : null)) },
            ended: { get: () => !!stream._sawEOF, set: (v) => { stream._sawEOF = !!v; } },
            endEmitted: { get: () => !!stream._endEmitted, set: (v) => { stream._endEmitted = !!v; } },
            reading: { get: () => false },
            constructed: { get: () => true },
            sync: { get: () => false },
            needReadable: { get: () => !stream._buf || !stream._buf.length },
            emittedReadable: { get: () => false },
            readableListening: { get: () => stream.listenerCount('readable') > 0 },
            resumeScheduled: { get: () => !!stream._draining },
            closed: { get: () => !!stream._closeEmitted },
            closeEmitted: { get: () => !!stream._closeEmitted },
            destroyed: { get: () => !!stream.destroyed, set: (v) => { stream.destroyed = !!v; } },
            errored: { get: () => stream._errored || null },
            errorEmitted: { get: () => !!stream._errored },
            encoding: { get: () => stream._readableEncoding || null },
            autoDestroy: { get: () => true },
            awaitDrainWriters: { get: () => null },
          };
        }
        function writableStateSpec(stream) {
          return {
            objectMode: { get: () => !!stream._writableObjectMode },
            highWaterMark: { get: () => 16384 },
            length: { get: () => (stream._wbuf || []).reduce((n, entry) => n + ((entry[0] && entry[0].length) || 1), 0) },
            corked: { get: () => stream._corked || 0 },
            writing: { get: () => !!stream._writing },
            needDrain: { get: () => !!stream._needDrain },
            ending: { get: () => !!stream._writableEnded, set: (v) => { stream._writableEnded = !!v; } },
            ended: { get: () => !!stream._writableEnded, set: (v) => { stream._writableEnded = !!v; } },
            finished: { get: () => !!stream._finishEmitted, set: (v) => { stream._finishEmitted = !!v; } },
            prefinished: { get: () => !!stream._finishEmitted },
            bufferedRequestCount: { get: () => (stream._wbuf || []).length },
            pendingcb: { get: () => (stream._wbuf || []).length },
            constructed: { get: () => true },
            sync: { get: () => false },
            closed: { get: () => !!stream._closeEmitted },
            closeEmitted: { get: () => !!stream._closeEmitted },
            destroyed: { get: () => !!stream.destroyed, set: (v) => { stream.destroyed = !!v; } },
            errored: { get: () => stream._errored || null },
            errorEmitted: { get: () => !!stream._errored },
            autoDestroy: { get: () => true },
          };
        }
        function initReadable(self, options) {
          options = options || {};
          self._buf = [];
          self._flowing = false;
          self._sawEOF = false;
          self._endEmitted = false;
          self._draining = false;
          self._readableEncoding = options.encoding || null;
          // Remembered so `readableHighWaterMark` reports what the stream was actually built
          // with rather than a constant.
          self._readableHighWaterMark = options.highWaterMark !== undefined
            ? Number(options.highWaterMark)
            : (options.objectMode ? 16 : 16384);
          self.readable = true;
          self.destroyed = false;
          if (options.read) self._read = options.read;
          if (options.destroy) self._destroy = options.destroy;
          self._objectMode = !!options.objectMode;
        }
        function Readable(options) { Stream.call(this); initReadable(this, options); }
        Readable.prototype = Object.create(Stream.prototype);
        Readable.prototype.constructor = Readable;
        // node's observable stream STATE. Libraries branch on these to decide whether a
        // stream finished (readable-stream, pump, get-stream, and every "is it done yet"
        // helper) — 10 of the 11 were missing, so those checks silently read undefined.
        Object.defineProperties(Readable.prototype, {
          readableEnded: { get: function(){ return !!this._endEmitted; }, configurable: true },
          // node reports null before flowing starts, then true/false.
          readableFlowing: { get: function(){ return this._flowing ? true : (this._everFlowed ? false : null); }, configurable: true },
          readableLength: { get: function(){ return (this._buf || []).reduce(function(n, c){ return n + (c.length || 1); }, 0); }, configurable: true },
          readableHighWaterMark: {
            get: function(){ return this._readableHighWaterMark === undefined ? 16384 : this._readableHighWaterMark; },
            configurable: true,
          },
          // null when no encoding is set, which is how node reports "you get Buffers".
          readableEncoding: { get: function(){ return this._readableEncoding || null; }, configurable: true },
          readableObjectMode: { get: function(){ return !!this._objectMode; }, configurable: true },
          closed: { get: function(){ return !!this._closeEmitted; }, configurable: true },
          errored: { get: function(){ return this._errored || null; }, configurable: true },
          // Destroyed BEFORE the stream ended: node's way of saying the read was cut short
          // rather than completed, which is how a consumer tells a truncated body from a whole
          // one. `readableDidRead` answers "did anything ever come out of this?".
          readableAborted: {
            get: function(){ return !!this.destroyed && !this._endEmitted; },
            configurable: true,
          },
          readableDidRead: { get: function(){ return !!this._didRead; }, configurable: true },
        });
        Object.assign(Readable.prototype, {
          _read: function() {},
          _coerce: function(chunk) {
            if (this._objectMode) return chunk;
            if (this._readableEncoding) return typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString(this._readableEncoding);
            return typeof chunk === 'string' ? Buffer.from(chunk) : chunk;
          },
          push: function(chunk) {
            if (chunk === null) {
              this._sawEOF = true;
              this._maybeEnd();
              return false;
            }
            this._buf.push(chunk);
            if (this._flowing) this._drain();
            else this.emit('readable');
            return true;
          },
          _drain: function() {
            if (this._draining) return;
            this._draining = true;
            process.nextTick(() => {
              this._draining = false;
              while (this._flowing && this._buf.length) {
                this._didRead = true;   // backs `readableDidRead`
                this.emit('data', this._coerce(this._buf.shift()));
              }
              if (this._flowing && !this._sawEOF && !this._buf.length) this._read(16384);
              this._maybeEnd();
            });
          },
          _maybeEnd: function() {
            if (this._sawEOF && !this._buf.length && !this._endEmitted) {
              this._endEmitted = true;
              process.nextTick(() => {
                this.readable = false;
                this.emit('end');
                // node's autoDestroy (its default since v14): a finished stream destroys itself,
                // which is how `stream.destroyed` becomes the reliable "done with this" flag that
                // callers actually test. A DUPLEX waits for both halves — destroying it when only
                // the readable side ended would kill a writable half still in use.
                const duplex = typeof this._write === 'function' && this._wbuf !== undefined;
                if (this._autoDestroy !== false && (!duplex || this._finishEmitted)) {
                  this.destroy();
                }
                process.nextTick(() => emitCloseOnce(this));
              });
            }
          },
          on: function(event, handler) {
            Stream.prototype.on.call(this, event, handler);
            if (event === 'data') this.resume();
            else if (event === 'readable' && this._buf.length) process.nextTick(() => this.emit('readable'));
            return this;
          },
          read: function(size) {
            if (!this._buf.length) { if (!this._sawEOF) this._read(size || 16384); if (!this._buf.length) { this._maybeEnd(); return null; } }
            if (this._objectMode) return this._buf.shift();
            // Concatenate as BYTES. This used to decode each chunk as UTF-8 into a string, join,
            // and re-encode — which corrupts anything that is not UTF-8 text (a digest, a gzip
            // member, an image) and ignored WHICH encoding setEncoding had asked for, so
            // setEncoding('hex') returned mojibake. The 'data' path was always correct via
            // _coerce; only read() was wrong, which is why it survived until a hash was piped.
            const joined = Buffer.concat(this._buf.map(function(chunk) {
              return typeof chunk === 'string' ? Buffer.from(chunk, 'utf8') : Buffer.from(chunk);
            }));
            // `read(n)` asks for exactly n bytes and leaves the rest — a framed protocol reads
            // its header that way and then its body. Handing back everything made the second
            // read return null, which reads as "the stream ended".
            const wanted = typeof size === 'number' && size > 0 ? size : joined.length;
            if (wanted < joined.length) {
              const taken = joined.slice(0, wanted);
              this._buf = [joined.slice(wanted)];
              return this._readableEncoding && this._readableEncoding !== 'buffer'
                ? taken.toString(this._readableEncoding) : taken;
            }
            this._buf = [];
            this._maybeEnd();
            if (this._readableEncoding && this._readableEncoding !== 'buffer') {
              return joined.toString(this._readableEncoding);
            }
            return joined;
          },
          resume: function() { if (!this._flowing) { this._flowing = true; this._everFlowed = true; this._drain(); } return this; },
          pause: function() { this._flowing = false; return this; },
          isPaused: function() { return !this._flowing; },
          setEncoding: function(enc) { this._readableEncoding = enc; return this; },
          unshift: function(chunk) { if (chunk !== null && chunk !== undefined) this._buf.unshift(chunk); return this; },
          destroy: function(err) {
            if (this.destroyed) return this;
            this.destroyed = true;
            // A destroyed stream is neither readable nor writable, and code guards on those
            // before touching it. Leaving them true invites a write to a dead stream.
            this.readable = false;
            if (this._wbuf) this.writable = false;
            const done = (e) => { if (e) this.emit('error', e); process.nextTick(() => emitCloseOnce(this)); };
            if (this._destroy) this._destroy(err || null, done); else done(err);
            return this;
          },
          pipe: function(dest, options) {
            const end = !options || options.end !== false;
            // The wiring is REMEMBERED so unpipe can undo exactly it. Without this, a pipe could
            // be started but never stopped, and real code stops one mid-flight — proxying, tar,
            // aborting a download.
            const onData = chunk => { if (dest.write(chunk) === false && this.pause) { this.pause(); } };
            const onDrain = () => this.resume();
            const onEnd = () => { if (end && dest.end) dest.end(); };
            this.on('data', onData);
            if (dest.on) dest.on('drain', onDrain);
            this.on('end', onEnd);
            this._pipes = this._pipes || [];
            this._pipes.push({ dest: dest, onData: onData, onDrain: onDrain, onEnd: onEnd });
            if (dest.emit) dest.emit('pipe', this);
            return dest;
          },
          /// Detach one destination, or every destination when called bare. node emits 'unpipe'
          /// on each one it detaches.
          unpipe: function(dest) {
            const pipes = this._pipes || [];
            const remaining = [];
            for (const entry of pipes) {
              if (dest !== undefined && entry.dest !== dest) { remaining.push(entry); continue; }
              this.off('data', entry.onData);
              this.off('end', entry.onEnd);
              if (entry.dest.off) entry.dest.off('drain', entry.onDrain);
              if (entry.dest.emit) entry.dest.emit('unpipe', this);
            }
            this._pipes = remaining;
            // With nothing left listening, node stops flowing rather than discarding data.
            if (!remaining.length && this.listenerCount('data') === 0) this._flowing = false;
            return this;
          },
          /// node's legacy adapter for an old-style (pre-streams2) emitter. It is short because
          /// the contract is small: forward data, end and error onto this stream.
          wrap: function(old) {
            const self = this;
            old.on('data', function(chunk){ if (!self.push(chunk) && old.pause) old.pause(); });
            old.on('end', function(){ self.push(null); });
            if (old.on) old.on('error', function(error){ self.emit('error', error); });
            this._read = function(){ if (old.resume) old.resume(); };
            return this;
          },
          /// `readable.compose(transform)` — pipe through and hand back the far end.
          compose: function(transform) {
            if (typeof transform === 'function') return transform(this);
            this.pipe(transform);
            return transform;
          },
          [Symbol.asyncIterator]: function() {
            const self = this;
            return {
              next() {
                return new Promise((resolve, reject) => {
                  const chunk = self._objectMode || self._buf.length === 0 ? null : self.read();
                  if (chunk !== null && chunk !== undefined) return resolve({ value: chunk, done: false });
                  if (self._buf.length) return resolve({ value: self._coerce(self._buf.shift()), done: false });
                  if (self._endEmitted || (self._sawEOF && !self._buf.length)) { self._maybeEnd(); return resolve({ value: undefined, done: true }); }
                  const onData = (c) => { cleanup(); self.pause(); resolve({ value: c, done: false }); };
                  const onEnd = () => { cleanup(); resolve({ value: undefined, done: true }); };
                  const onError = (e) => { cleanup(); reject(e); };
                  const cleanup = () => { self.off('data', onData); self.off('end', onEnd); self.off('error', onError); };
                  self.on('data', onData); self.on('end', onEnd); self.on('error', onError);
                  self.resume();
                });
              },
              return() { self.destroy(); return Promise.resolve({ value: undefined, done: true }); },
              [Symbol.asyncIterator]() { return this; },
            };
          },
          // node 17+'s stream operators. Every one is expressible over async iteration, which
          // already worked here — the gap was the surface, not the machinery. The ones returning
          // a stream return an OBJECT-MODE Readable, as node's do, so a mapper may yield anything.
          iterator: function(options) {
            const iterable = this[Symbol.asyncIterator]();
            // `destroyOnReturn: false` keeps the source alive after a partial read, which is what
            // `for await ... break` needs when the caller still wants the stream.
            if (options && options.destroyOnReturn === false) {
              return { next: iterable.next.bind(iterable),
                       return() { return Promise.resolve({ value: undefined, done: true }); },
                       [Symbol.asyncIterator]() { return this; } };
            }
            return iterable;
          },
          map: function(fn, options) {
            const self = this;
            let index = 0;
            return Readable.from((async function* () {
              for await (const value of self) yield await fn(value, index++);
            })(), options);
          },
          filter: function(fn, options) {
            const self = this;
            let index = 0;
            return Readable.from((async function* () {
              for await (const value of self) if (await fn(value, index++)) yield value;
            })(), options);
          },
          flatMap: function(fn, options) {
            const self = this;
            let index = 0;
            return Readable.from((async function* () {
              for await (const value of self) {
                const produced = await fn(value, index++);
                // A mapper may return one value or something iterable; node flattens one level.
                if (produced && typeof produced[Symbol.asyncIterator] === 'function') {
                  for await (const inner of produced) yield inner;
                } else if (produced && typeof produced[Symbol.iterator] === 'function' &&
                           typeof produced !== 'string') {
                  for (const inner of produced) yield inner;
                } else {
                  yield produced;
                }
              }
            })(), options);
          },
          take: function(count, options) {
            const self = this;
            let left = Number(count);
            return Readable.from((async function* () {
              if (left <= 0) return;
              for await (const value of self) {
                yield value;
                if (--left <= 0) return;
              }
            })(), options);
          },
          drop: function(count, options) {
            const self = this;
            let left = Number(count);
            return Readable.from((async function* () {
              for await (const value of self) {
                if (left > 0) { left -= 1; continue; }
                yield value;
              }
            })(), options);
          },
          forEach: async function(fn) {
            let index = 0;
            for await (const value of this) await fn(value, index++);
          },
          toArray: async function() {
            const out = [];
            for await (const value of this) out.push(value);
            return out;
          },
          reduce: async function(fn, initial) {
            let accumulator = initial;
            let seeded = arguments.length > 1;
            let index = 0;
            for await (const value of this) {
              // Unseeded, the FIRST value becomes the accumulator rather than being folded in.
              if (!seeded) { accumulator = value; seeded = true; index += 1; continue; }
              accumulator = await fn(accumulator, value, index++);
            }
            if (!seeded) {
              throw Object.assign(new TypeError('Reduce of an empty stream requires an initial value'),
                                  { code: 'ERR_INVALID_ARG_TYPE' });
            }
            return accumulator;
          },
          some: async function(fn) {
            let index = 0;
            for await (const value of this) if (await fn(value, index++)) return true;
            return false;
          },
          every: async function(fn) {
            let index = 0;
            for await (const value of this) if (!await fn(value, index++)) return false;
            return true;
          },
          find: async function(fn) {
            let index = 0;
            for await (const value of this) if (await fn(value, index++)) return value;
            return undefined;
          },
        });

        Readable.from = function(iterable) {
            const readable = new Readable({ objectMode: true });
            process.nextTick(async () => {
              try {
                for await (const item of iterable) readable.push(item);
                readable.push(null);
              } catch (e) { readable.emit('error', e); }
            });
            return readable;
        };

        // Writable init + methods live free-standing so Duplex/Transform can graft them
        // onto a Readable ancestry (JS has one prototype chain).
        function initWritable(self, options) {
          options = options || {};
          self._wbuf = [];
          self._writing = false;
          self._writableEnded = false;
          self._finishEmitted = false;
          self._finalCb = null;
          self.writable = true;
          if (options.write) self._write = options.write;
          if (options.final) self._final = options.final;
          if (options.destroy && !self._destroy) self._destroy = options.destroy;
          self._writableObjectMode = !!options.objectMode;
          // `highWaterMark` was accepted and dropped: write() compared against a hardcoded 16,
          // so a stream configured for backpressure never reported any. node counts BYTES outside
          // object mode (default 16384) and objects inside it (default 16).
          self._writableHighWaterMark = options.highWaterMark !== undefined
            ? Number(options.highWaterMark)
            : (options.objectMode ? 16 : 16384);
        }
        const writableMethods = {
          _write(chunk, encoding, callback) { callback(); },
          write(chunk, encoding, callback) {
            if (typeof encoding === 'function') { callback = encoding; encoding = null; }
            if (this._writableEnded) { this.emit('error', new Error('write after end')); return false; }
            // A string is DECODED here, by the encoding given or the stream's default, and
            // `_write` is then told 'buffer' — node's `decodeStrings` behaviour, and the reason
            // `write(text, 'hex')` means bytes rather than the characters "68690a". Passing the
            // string through with its encoding name made every non-utf8 write wrong.
            if (typeof chunk === 'string' && !this._writableObjectMode && this._decodeStrings !== false) {
              chunk = Buffer.from(chunk, encoding || this._defaultEncoding || 'utf8');
              encoding = 'buffer';
            }
            this._wbuf.push([chunk, encoding || (this._writableObjectMode ? null : 'utf8'), callback]);
            // Measured BEFORE flushing, because _flushWrites shifts the entry out as soon as it
            // hands it to _write — the write is still in flight at that point, so measuring after
            // reports an empty buffer and never signals backpressure.
            const mark = this._writableHighWaterMark === undefined ? 16 : this._writableHighWaterMark;
            let buffered;
            if (this._writableObjectMode) {
              buffered = this._wbuf.length;
            } else {
              buffered = 0;
              for (const entry of this._wbuf) {
                const value = entry[0];
                buffered += value && value.length !== undefined ? value.length : 1;
              }
            }
            // At or above the mark means "stop writing until 'drain'", which is what returning
            // false tells the caller.
            const ok = buffered < mark;
            if (!ok) this._needDrain = true;
            this._flushWrites();
            return ok;
          },
          // cork/uncork: node buffers writes while corked so a caller can coalesce several
          // into one packet. `ws` corks around every frame (header + payload + mask), so
          // without these a WebSocket send throws before a single byte goes out.
          /// The encoding used for a string written without one of its own.
          setDefaultEncoding(encoding) { this._defaultEncoding = String(encoding); return this; },
          cork() { this._corked = (this._corked || 0) + 1; },
          uncork() {
            if (!this._corked) return;
            this._corked -= 1;
            if (!this._corked) this._flushWrites();
          },
          _flushWrites() {
            if (this._writing || this._corked) return;
            const step = () => {
              if (!this._wbuf.length) {
                this._writing = false;
                if (this._needDrain) { this._needDrain = false; this.emit('drain'); }
                this._maybeFinish();
                return;
              }
              const [chunk, encoding, callback] = this._wbuf.shift();
              // A chunk handed to _write is no longer in the buffer but IS still outstanding, so
              // it has to keep counting towards writableLength — otherwise a caller watching
              // backpressure sees an empty queue while bytes are in flight.
              this._writingLength = chunk && chunk.length !== undefined ? chunk.length : 1;
              this._write(chunk, encoding, (err) => {
                this._writingLength = 0;
                if (callback) callback(err);
                if (err) { this._writing = false; this.emit('error', err); return; }
                step();
              });
            };
            this._writing = true;
            step();
          },
          end(chunk, encoding, callback) {
            if (typeof chunk === 'function') { callback = chunk; chunk = undefined; }
            else if (typeof encoding === 'function') { callback = encoding; encoding = null; }
            if (chunk !== undefined && chunk !== null) this.write(chunk, encoding);
            this._corked = 0;           // end() implies uncork, as in node
            this._flushWrites();
            this._writableEnded = true;
            if (callback) this.once('finish', callback);
            this._maybeFinish();
            return this;
          },
          _maybeFinish() {
            if (!this._writableEnded || this._writing || this._wbuf.length || this._finishEmitted) return;
            this._finishEmitted = true;
            const finish = () => {
              this.writable = false;
              this.emit('finish');
              // autoDestroy, on the path a PLAIN Writable takes — there are three finish paths
              // here (plain, Duplex, Transform) and patching one is not patching the others.
              const duplex = typeof this._read === 'function';
              if (this._autoDestroy !== false && !duplex) process.nextTick(() => this.destroy());
              process.nextTick(() => emitCloseOnce(this));
            };
            if (this._final) this._final((err) => { if (err) this.emit('error', err); finish(); });
            else finish();
          },
          destroy(err) {
            if (this.destroyed) return this;
            this.destroyed = true;
            // The writable half of the same rule as Readable.destroy: a destroyed stream is
            // neither writable nor readable, and callers guard on those before touching it.
            this.writable = false;
            if (this._buf) this.readable = false;
            const done = (e) => { if (e) this.emit('error', e); process.nextTick(() => emitCloseOnce(this)); };
            if (this._destroy) this._destroy(err || null, done); else done(err);
            return this;
          },
        };

        function Writable(options) { Stream.call(this); this.destroyed = false; initWritable(this, options); }
        Writable.prototype = Object.create(Stream.prototype);
        Writable.prototype.constructor = Writable;
        Object.assign(Writable.prototype, writableMethods);
        // Same for the writable side; defined once and re-applied to Duplex/Transform below.
        const writableState = {
          writableCorked: { get: function(){ return this._corked || 0; }, configurable: true },
          writableEnded: { get: function(){ return !!this._writableEnded; }, configurable: true },
          writableFinished: { get: function(){ return !!this._finishEmitted; }, configurable: true },
          // Destroyed before finishing: the write was cut short rather than completed.
          writableAborted: {
            get: function(){ return !!this.destroyed && !this._finishEmitted; },
            configurable: true,
          },
          // node counts BYTES outside object mode, not entries — a caller watching backpressure
          // compares this against writableHighWaterMark, so the units have to agree.
          writableLength: {
            get: function() {
              const buffered = this._wbuf || [];
              if (this._writableObjectMode) return buffered.length + (this._writingLength ? 1 : 0);
              let total = this._writingLength || 0;
              for (const entry of buffered) {
                const value = entry[0];
                total += value && value.length !== undefined ? value.length : 1;
              }
              return total;
            },
            configurable: true,
          },
          writableHighWaterMark: {
            get: function(){ return this._writableHighWaterMark === undefined ? 16384 : this._writableHighWaterMark; },
            configurable: true,
          },
          writableNeedDrain: { get: function(){ return !!this._needDrain; }, configurable: true },
          writableObjectMode: { get: function(){ return !!this._writableObjectMode; }, configurable: true },
          closed: { get: function(){ return !!this._closeEmitted; }, configurable: true },
          errored: { get: function(){ return this._errored || null; }, configurable: true },
        };
        Object.defineProperties(Writable.prototype, writableState);

        // Duplex inherits Readable's prototype and GRAFTS the writable methods on — JS gives
        // one prototype chain, and node does the same thing.
        function Duplex(options) { Readable.call(this, options); initWritable(this, options); }
        Duplex.prototype = Object.create(Readable.prototype);
        Duplex.prototype.constructor = Duplex;
        Object.assign(Duplex.prototype, writableMethods);
        Object.defineProperties(Duplex.prototype, writableState);

        defineStateView(Readable.prototype, '_readableState', readableStateSpec);
        defineStateView(Writable.prototype, '_writableState', writableStateSpec);
        defineStateView(Duplex.prototype, '_readableState', readableStateSpec);
        defineStateView(Duplex.prototype, '_writableState', writableStateSpec);

        function Transform(options) {
          options = options || {};
          Duplex.call(this, Object.assign({}, options, {
            objectMode: options.objectMode || options.readableObjectMode || options.writableObjectMode,
          }));
          if (options.transform) this._transform = options.transform;
          if (options.flush) this._flush = options.flush;
        }
        Transform.prototype = Object.create(Duplex.prototype);
        Transform.prototype.constructor = Transform;
        Object.assign(Transform.prototype, {
          _transform: function(chunk, encoding, callback) { callback(null, chunk); },
          _write: function(chunk, encoding, callback) {
            const self = this;
            this._transform(chunk, encoding, function(err, out) {
              if (err) return callback(err);
              if (out !== undefined && out !== null) self.push(out);
              callback();
            });
          },
          _maybeFinish: function() {
            if (!this._writableEnded || this._writing || this._wbuf.length || this._finishEmitted) return;
            this._finishEmitted = true;
            const self = this;
            const finish = function() {
              self.writable = false;
              self.push(null);
              self.emit('finish');
              // The writable half of the same rule; a Duplex waits for its readable side.
              // "Is this a duplex?" is decided by whether a READ side was initialised, not by the
              // presence of _buf — the writable methods are grafted onto a Readable ancestry, so
              // _buf can exist on a plain Writable.
              const duplex = typeof self._read === 'function';
              if (self._autoDestroy !== false && (!duplex || self._endEmitted)) {
                process.nextTick(function(){ self.destroy(); });
              }
            };
            if (this._flush) this._flush(function(err, out) {
              if (err) { self.emit('error', err); return; }
              if (out !== undefined && out !== null) self.push(out);
              finish();
            });
            else finish();
          },
        });
        function PassThrough(options) { Transform.call(this, options); }
        PassThrough.prototype = Object.create(Transform.prototype);
        PassThrough.prototype.constructor = PassThrough;

        function finished(stream, options, callback) {
          if (typeof options === 'function') { callback = options; options = undefined; }
          const stop = globalThis.__onAbort(options && options.signal, function() {
            const error = globalThis.__abortError();
            if (callback) callback(error);
            callback = null;
          });
          const wrapped = callback;
          callback = function(error) { stop(); if (wrapped) wrapped(error); };
          return _finishedInner(stream, callback);
        }
        function _finishedInner(stream, callback) {
          let done = false;
          const wrap = (err) => { if (!done) { done = true; callback(err || null); } };
          stream.once('error', wrap);
          stream.once('end', () => wrap());
          stream.once('finish', () => wrap());
          stream.once('close', () => wrap());
        }
        function pipeline() {
          const parts = Array.prototype.slice.call(arguments);
          const callback = typeof parts[parts.length - 1] === 'function' ? parts.pop() : function(){};
          // A trailing options object carries the signal; stream/promises always passes one.
          let options = null;
          const tail = parts[parts.length - 1];
          if (tail && typeof tail === 'object' && typeof tail.pipe !== 'function' &&
              typeof tail.write !== 'function' && typeof tail[Symbol.asyncIterator] !== 'function' &&
              !Array.isArray(tail)) {
            options = parts.pop();
          }
          let failed = false;
          const fail = (err) => { if (!failed) { failed = true; stopAbort(); callback(err); } };
          const stopAbort = globalThis.__onAbort(options && options.signal, function() {
            for (const part of parts) { try { part && part.destroy && part.destroy(); } catch (ignored) {} }
            fail(globalThis.__abortError());
          });
          for (const part of parts) part.once('error', fail);
          for (let i = 0; i + 1 < parts.length; i++) parts[i].pipe(parts[i + 1]);
          const last = parts[parts.length - 1];
          finished(last, (err) => { if (err) fail(err); else if (!failed) callback(null); });
          return last;
        }

        Stream.Readable = Readable;
        Stream.Writable = Writable;
        Stream.Duplex = Duplex;
        Stream.Transform = Transform;
        Stream.PassThrough = PassThrough;
        Stream.Stream = Stream;
        Stream.finished = finished;
        Stream.pipeline = pipeline;
        // Helpers real libraries reach for: `compose` chains streams, `duplexPair` is how
        // in-memory pipes get built, and the underscore ones are node internals that
        // readable-stream and its dependents call directly.
        Stream.compose = function() {
          const parts = Array.prototype.slice.call(arguments);
          if (!parts.length) throw new Error('stream.compose needs at least one stream');
          let current = parts[0];
          for (let i = 1; i < parts.length; i++) current = current.pipe(parts[i]);
          return current;
        };
        Stream.duplexPair = function() {
          const left = new Duplex({ read: function(){}, write: function(chunk, encoding, callback){ right.push(chunk); callback(); } });
          const right = new Duplex({ read: function(){}, write: function(chunk, encoding, callback){ left.push(chunk); callback(); } });
          return [left, right];
        };
        Stream.isDisturbed = function(stream) {
          return !!(stream && (stream._everFlowed || stream._endEmitted || stream.destroyed));
        };
        Stream._isArrayBufferView = function(value) { return ArrayBuffer.isView(value); };
        Stream._isUint8Array = function(value) { return value instanceof Uint8Array; };
        Stream._uint8ArrayToBuffer = function(value) { return Buffer.from(value); };
        Stream.promises = {
          pipeline: function() {
            const parts = Array.prototype.slice.call(arguments);
            return new Promise((resolve, reject) => {
              pipeline.apply(null, parts.concat([(err) => err ? reject(err) : resolve()]));
            });
          },
          finished: function(stream) {
            return new Promise((resolve, reject) => finished(stream, (err) => err ? reject(err) : resolve()));
          },
        };
        return Stream;
      };
      coreFactories['stream/promises'] = function() { return coreRequire('stream').promises; };

      coreFactories.constants = function() { return {}; };
      coreFactories.querystring = function() {
        return {
          unescapeBuffer: function(text) { return Buffer.from(decodeURIComponent(String(text))); },
          parse: function(text, sep, eq, options) {
            const result = {};
            const separator = sep || '&';
            const equals = eq || '=';
            // `maxKeys` caps how much of a hostile query string is parsed; 0 means no limit.
            const maxKeys = options && options.maxKeys !== undefined ? Number(options.maxKeys) : 1000;
            for (const pair of String(text).split(separator)) {
              if (!pair) continue;
              if (maxKeys > 0 && Object.keys(result).length >= maxKeys) break;
              const at = pair.indexOf(equals);
              const rawKey = at < 0 ? pair : pair.slice(0, at);
              const rawValue = at < 0 ? '' : pair.slice(at + equals.length);
              // A '+' is a space in a query string, and a malformed escape must not throw —
              // node leaves an undecodable sequence as-is rather than rejecting the whole
              // string, which is what a hostile or truncated query would otherwise do.
              const decode = function(part) {
                const plussed = String(part).replace(/\+/g, ' ');
                try { return decodeURIComponent(plussed); } catch (error) { return plussed; }
              };
              const key = decode(rawKey), value = decode(rawValue);
              // A repeated key becomes an ARRAY. Overwriting instead silently discarded every
              // value but the last, which is data loss in the shape most likely to be a filter
              // list or a multi-select.
              if (Object.prototype.hasOwnProperty.call(result, key)) {
                if (Array.isArray(result[key])) result[key].push(value);
                else result[key] = [result[key], value];
              } else {
                result[key] = value;
              }
            }
            return result;
          },
          stringify: function(object, sep, eq) {
            const separator = sep || '&';
            const equals = eq || '=';
            // node's escaping is percent-encoding throughout — a space is %20, never '+'.
            const encode = function(value) {
              if (value === null || value === undefined) return '';
              if (typeof value === 'object') return '';
              return encodeURIComponent(String(value));
            };
            const parts = [];
            for (const key of Object.keys(object || {})) {
              const encodedKey = encodeURIComponent(key);
              const value = object[key];
              // An array REPEATS the key; joining with commas produced one value that no
              // parser would split back apart.
              if (Array.isArray(value)) {
                for (const item of value) parts.push(encodedKey + equals + encode(item));
              } else {
                parts.push(encodedKey + equals + encode(value));
              }
            }
            return parts.join(separator);
          },
        };
      };
      coreFactories.url = function() {
        return {
          URL: globalThis.URL || function(){ throw new Error('URL is not available'); },
          // The legacy parser, which older packages still use — and which this had been
          // approximating with one regex that assumed every input was `scheme://host/path`.
          // A bare path came back as '/', losing it entirely; `user:pass@host` put the user in
          // hostname and the rest in pathname; and `host`, `hash` and `path` were simply absent.
          parse: function(text, parseQueryString) {
            const input = String(text);
            const result = { protocol: null, slashes: null, auth: null, host: null, port: null,
                             hostname: null, hash: null, search: null, query: null,
                             pathname: null, path: null, href: input };
            let rest = input;

            const protocolMatch = /^([a-zA-Z][a-zA-Z0-9.+-]*:)/.exec(rest);
            if (protocolMatch) { result.protocol = protocolMatch[1].toLowerCase(); rest = rest.slice(protocolMatch[1].length); }

            // A host section follows only after `//`. Without a protocol, node's default leaves
            // `//h/p` as a PATH rather than reading a host from it.
            const slashed = ['http:', 'https:', 'ftp:', 'gopher:', 'file:', 'ws:', 'wss:'];
            const hasSlashes = rest.slice(0, 2) === '//';
            // Without a protocol the `//` is NOT consumed: node leaves `//h/p` as a path
            // unless the caller opts into slashesDenoteHost, which this signature does not.
            const readsHost = !!result.protocol && (hasSlashes ||
                              slashed.indexOf(result.protocol) >= 0 ||
                              // `mailto:a@b.com` — a non-slashed protocol still names a host.
                              (rest.indexOf('/') < 0 && rest.length > 0));
            if (hasSlashes && readsHost) { result.slashes = true; rest = rest.slice(2); }

            const hash = rest.indexOf('#');
            if (hash >= 0) { result.hash = rest.slice(hash); rest = rest.slice(0, hash); }

            if (readsHost) {
              let authority = rest;
              const slash = authority.search(/[/?]/);
              if (slash >= 0) { rest = authority.slice(slash); authority = authority.slice(0, slash); }
              else rest = '';
              const at = authority.lastIndexOf('@');
              if (at >= 0) { result.auth = authority.slice(0, at); authority = authority.slice(at + 1); }
              // An IPv6 literal keeps its brackets in `host` and loses them in `hostname`.
              const portMatch = /:(\d*)$/.exec(authority);
              if (portMatch && authority[0] !== '[' || (portMatch && authority.indexOf(']') >= 0 && authority.lastIndexOf(']') < authority.lastIndexOf(':'))) {
                result.port = portMatch[1] || null;
                authority = authority.slice(0, authority.length - portMatch[0].length);
              }
              result.host = authority + (result.port ? ':' + result.port : '');
              result.hostname = authority[0] === '[' && authority[authority.length - 1] === ']'
                ? authority.slice(1, -1) : authority;
              result.hostname = result.hostname.toLowerCase();
              result.host = result.host.toLowerCase();
            }

            const question = rest.indexOf('?');
            if (question >= 0) { result.search = rest.slice(question); rest = rest.slice(0, question); }
            if (rest.length) result.pathname = rest;
            else if (readsHost && result.host !== null && result.protocol && slashed.indexOf(result.protocol) >= 0) {
              result.pathname = '/';
            }
            if (result.pathname !== null || result.search !== null) {
              result.path = (result.pathname || '') + (result.search || '');
            }
            result.query = parseQueryString
              ? Object.fromEntries(new URLSearchParams(result.search || ''))
              : (result.search ? result.search.slice(1) : null);
            return result;
          },
          // These two were stubs — string surgery that happened to round-trip plain ASCII paths
          // and lost on everything else. A path is not a URL: '#' and '?' start a fragment and a
          // query, '%' starts an escape, and a space is illegal. eslint reaches for the real
          // contract, appending an mtime to `searchParams` to cache-bust an ESM config import,
          // which needs an actual URL object rather than a bare { href }.
          fileURLToPath: function(url) {
            const href = typeof url === 'string' ? url : String((url && url.href) || url);
            if (!/^file:\/\//i.test(href)) {
              const error = new TypeError('The URL must be of scheme file');
              error.code = 'ERR_INVALID_URL_SCHEME';
              throw error;
            }
            // Query and fragment are URL structure, never part of the path.
            let rest = href.slice('file://'.length).replace(/[?#][\s\S]*$/, '');
            // An authority is allowed only when it is empty or localhost.
            if (rest[0] !== '/') {
              const slash = rest.indexOf('/');
              const host = slash === -1 ? rest : rest.slice(0, slash);
              if (host.toLowerCase() !== 'localhost') {
                const error = new TypeError('File URL host must be "localhost" or empty');
                error.code = 'ERR_INVALID_FILE_URL_HOST';
                throw error;
              }
              rest = slash === -1 ? '/' : rest.slice(slash);
            }
            try { return decodeURIComponent(rest); } catch (error) { return rest; }
          },
          pathToFileURL: function(p) {
            const path = String(p);
            // Encode what the URL parser would otherwise read as structure. '%' goes first, so
            // the escapes introduced below are not themselves re-encoded. The parser handles
            // the remainder (a space becomes %20).
            // Brackets are encoded here rather than by the parser: node encodes them when a path
            // becomes a file URL, but leaves them alone in a URL parsed from text.
            const encoded = path.replace(/%/g, '%25').replace(/#/g, '%23').replace(/\?/g, '%3F')
                                .replace(/\n/g, '%0A').replace(/\r/g, '%0D').replace(/\t/g, '%09')
                                .replace(/\[/g, '%5B').replace(/\]/g, '%5D');
            return new URL('file://' + encoded);
          },
          URLSearchParams: globalThis.URLSearchParams,
          // The legacy url API. Deprecated in node, still imported by older packages.
          Url: function Url() {},
          format: function(input) {
            if (typeof input === 'string') return input;
            if (input && input.href) return input.href;
            const parts = input || {};
            // This dropped the PORT whenever the object carried `hostname` rather than `host`,
            // and follow-redirects builds its redirect target with exactly that shape — so a
            // 302 from a server on any port sent the next hop to port 80. It also emitted `//`
            // unconditionally, which is wrong for a non-slashed protocol like mailto:.
            const protocol = parts.protocol || '';
            const slashed = parts.slashes === true ||
              ['http:', 'https:', 'ftp:', 'gopher:', 'file:', 'ws:', 'wss:'].indexOf(protocol) >= 0;
            const host = parts.host !== undefined && parts.host !== null && parts.host !== ''
              ? parts.host
              : (parts.hostname || '') +
                (parts.port !== undefined && parts.port !== null && parts.port !== ''
                  ? ':' + parts.port : '');
            const auth = parts.auth ? parts.auth + '@' : '';
            // node uses `pathname`, never `path` — an options object carrying `path` formats
            // to the origin alone, which is what the redirect resolver then resolves against.
            let search = parts.search || '';
            if (!search && parts.query && typeof parts.query === 'object') {
              const encoded = new URLSearchParams(parts.query).toString();
              if (encoded) search = '?' + encoded;
            }
            if (search && search[0] !== '?') search = '?' + search;
            let hash = parts.hash || '';
            if (hash && hash[0] !== '#') hash = '#' + hash;
            return protocol + (slashed ? '//' : '') + auth + host +
                   (parts.pathname || '') + search + hash;
          },
          resolve: function(from, to) {
            try { return new URL(to, from).href; } catch (error) { /* base has no scheme */ }
            // A base that is only a PATH cannot go through the URL constructor, and node still
            // resolves it — `url.resolve('/base/path', 'sub')` is '/base/sub'. Resolve against
            // a placeholder origin and strip it back off.
            try {
              const base = String(from);
              if (base[0] === '/' || base.indexOf(':') < 0) {
                const resolved = new URL(String(to), 'resolve-base:///' + base.replace(/^\/+/, ''));
                return resolved.pathname + resolved.search + resolved.hash;
              }
            } catch (error) { /* fall through */ }
            return to;
          },
          resolveObject: function(from, to) {
            try { return new URL(to, from); } catch (error) { return null; }
          },
          // IDNA needs a Unicode table we do not carry; ASCII names pass through unchanged,
          // and a non-ASCII one says so rather than returning mojibake.
          domainToASCII: function(name) {
            const text = String(name);
            if (/^[\x00-\x7F]*$/.test(text)) return text.toLowerCase();
            return '';
          },
          domainToUnicode: function(name) { return String(name); },
          fileURLToPathBuffer: function(url) { return Buffer.from(String(url).replace('file://', '')); },
          // This is how a WHATWG URL becomes http.request options, so a missing field is a
          // request that goes somewhere else. node reports hash, search and pathname as well as
          // path; carries auth across when the URL has credentials; and gives port as a NUMBER,
          // omitting the key entirely when there is none.
          urlToHttpOptions: function(url) {
            const options = {
              protocol: url.protocol,
              hostname: typeof url.hostname === 'string' && url.hostname.startsWith('[')
                ? url.hostname.slice(1, -1) : url.hostname,
              hash: url.hash,
              search: url.search,
              pathname: url.pathname,
              path: (url.pathname || '') + (url.search || ''),
              href: url.href,
            };
            if (url.port !== '') options.port = Number(url.port);
            if (url.username || url.password) {
              options.auth = decodeURIComponent(url.username) + ':' + decodeURIComponent(url.password);
            }
            return options;
          },
        };
      };
      coreFactories.process = function() { return process; };
      coreFactories.timers = function() {
        return { setTimeout: setTimeout, clearTimeout: clearTimeout, setInterval: setInterval,
                 clearInterval: clearInterval, setImmediate: setImmediate, clearImmediate: clearImmediate,
                 // node hangs the promises API off the module too, not just 'timers/promises'.
                 promises: coreRequire('timers/promises'),
                 active: function(){}, unenroll: function(){}, enroll: function(){},
                 _unrefActive: function(){} };
      };
      coreFactories['timers/promises'] = function() {
        return {
          setTimeout: function(delay, value, options) {
            return new Promise(function(resolve, reject) {
              const timer = setTimeout(function(){ stop(); resolve(value); }, delay);
              const stop = globalThis.__onAbort(options && options.signal, function() {
                clearTimeout(timer);
                reject(globalThis.__abortError());
              });
            });
          },
          setImmediate: function(value, options) {
            return new Promise(function(resolve, reject) {
              let cancelled = false;
              const stop = globalThis.__onAbort(options && options.signal, function() {
                cancelled = true;
                reject(globalThis.__abortError());
              });
              setImmediate(function(){ if (!cancelled) { stop(); resolve(value); } });
            });
          },
          setInterval: function(delay, value) {
            return { [Symbol.asyncIterator]() {
              return { next() { return new Promise(function(resolve){ setTimeout(function(){ resolve({ value: value, done: false }); }, delay); }); } };
            } };
          },
          scheduler: { wait: function(delay) { return new Promise(function(resolve){ setTimeout(resolve, delay); }); } },
        };
      };
      coreFactories.module = function() {
        // This was three keys where node has forty. A module RUNNER — jest is the clearest
        // case — does not just require things: it builds its own registry on top of node's,
        // reading `_extensions` to learn which files are loadable, `_nodeModulePaths` to walk
        // the same directories, and `_cache` to evict between test files. Missing internals
        // stop such a tool at startup rather than degrading it.
        const builtins = ['assert', 'async_hooks', 'buffer', 'child_process', 'cluster',
                          'console', 'constants', 'crypto', 'dgram', 'diagnostics_channel',
                          'dns', 'domain', 'events', 'fs', 'http', 'http2', 'https', 'inspector',
                          'module', 'net', 'os', 'path', 'perf_hooks', 'process', 'querystring',
                          'readline', 'stream', 'string_decoder', 'timers', 'tls', 'tty', 'url',
                          'util', 'v8', 'vm', 'worker_threads', 'zlib'];
        const rootRequire = bridge.createRequire('/');

        function Module(id, parent) {
          this.id = id === undefined ? '' : id;
          this.path = id ? String(id).replace(/[/][^/]*$/, '') || '/' : '';
          this.exports = {};
          this.parent = parent === undefined ? null : parent;
          this.filename = id || null;
          this.loaded = false;
          this.children = [];
          this.paths = id ? Module._nodeModulePaths(this.path) : [];
        }
        Module.prototype.require = function(request) {
          return bridge.createRequire(this.filename || '/')(String(request));
        };
        Module.prototype.load = function(filename) {
          this.filename = filename;
          this.paths = Module._nodeModulePaths(String(filename).replace(/[/][^/]*$/, '') || '/');
          const extension = /\.[^./]+$/.exec(String(filename));
          const handler = Module._extensions[extension ? extension[0] : '.js'] || Module._extensions['.js'];
          handler(this, filename);
          this.loaded = true;
        };
        Module.prototype._compile = function(content, filename) {
          // node compiles the text itself; here the engine owns compilation, so the honest
          // equivalent is to load the file that text came from.
          this.exports = bridge.createRequire(String(filename))(String(filename));
          return this.exports;
        };
        Module.prototype.isPreloading = false;

        Module._cache = {};
        Module._pathCache = {};
        Module._extensions = {
          '.js': function(module, filename) { module.exports = rootRequire(String(filename)); },
          '.json': function(module, filename) { module.exports = rootRequire(String(filename)); },
          '.node': function(module, filename) {
            const error = new Error('Cannot load native addon ' + filename +
                                    ': a .node binary is compiled machine code, which iOS will ' +
                                    'not map executable');
            error.code = 'ERR_DLOPEN_FAILED';
            throw error;
          },
        };
        Module._nodeModulePaths = function(from) {
          let dir = String(from || '/');
          if (!dir.startsWith('/')) dir = '/' + dir;
          const paths = [];
          for (;;) {
            if (!/[/]node_modules$/.test(dir)) paths.push(dir === '/' ? '/node_modules' : dir + '/node_modules');
            if (dir === '/' || dir === '') break;
            dir = dir.replace(/[/][^/]*$/, '') || '/';
          }
          return paths;
        };
        Module._resolveFilename = function(request, parent) {
          const from = parent && parent.filename ? parent.filename : '/';
          return bridge.createRequire(String(from)).resolve(String(request));
        };
        Module._resolveLookupPaths = function(request, parent) {
          const from = parent && parent.path ? parent.path : '/';
          return Module._nodeModulePaths(from);
        };
        Module._load = function(request, parent) {
          const from = parent && parent.filename ? parent.filename : '/';
          return bridge.createRequire(String(from))(String(request));
        };
        Module.globalPaths = [];
        // node exposes the exact wrapper text; tools splice around it.
        Module.wrapper = ['(function (exports, require, module, __filename, __dirname) { ', '\n});'];
        Module.wrap = function(script) { return Module.wrapper[0] + script + Module.wrapper[1]; };
        Module.builtinModules = builtins;
        Module.isBuiltin = function(name) { return builtins.includes(String(name).replace(/^node:/, '')); };
        Module.createRequire = function(from) {
          return bridge.createRequire(String(from && from.href ? from.href : from));
        };
        Module.syncBuiltinESMExports = function() {};
        Module.Module = Module;
        Module.constants = { compileCacheStatus: { FAILED: 0, ENABLED: 1, ALREADY_ENABLED: 2, DISABLED: 3 } };
        return Module;
      };
      coreFactories.buffer = function() {
        return {
          Buffer: Buffer,
          SlowBuffer: Buffer,
          kMaxLength: 0x7fffffff,
          INSPECT_MAX_BYTES: 50,
          constants: { MAX_LENGTH: 0x7fffffff, MAX_STRING_LENGTH: 0x1fffffe8 },
          atob: globalThis.atob,
          btoa: globalThis.btoa,
          // These live as globals already; node exports them from the module too, and a
          // library that imports them from here would otherwise get undefined.
          Blob: globalThis.Blob,
          File: globalThis.File,
          kStringMaxLength: 0x1fffffe8,
          isUtf8: function(value) {
            try { return Buffer.from(value).toString('utf8').indexOf('\uFFFD') < 0; }
            catch (error) { return false; }
          },
          isAscii: function(value) {
            const bytes = Buffer.from(value);
            for (let i = 0; i < bytes.length; i++) if (bytes[i] > 127) return false;
            return true;
          },
          resolveObjectURL: function() { return undefined; },
          transcode: function(source, from, to) { return Buffer.from(source.toString(from), to); },
        };
      };

      // ---- child_process → msh (the bridge no other Node-on-iOS has) ----
      coreFactories.child_process = function() {
        function shellQuote(text) { return "'" + String(text).replace(/'/g, "'\\''") + "'"; }
        function runShell(command) { return bridge.shellExec(String(command)); }
        function failure(command, r) {
          const error = new Error('Command failed: ' + command + (r.stderr ? '\n' + r.stderr : ''));
          error.status = r.status;
          error.code = r.status;
          error.stdout = Buffer.from(r.stdout);
          error.stderr = Buffer.from(r.stderr);
          return error;
        }
        function normalizeExecArgs(options, callback) {
          if (typeof options === 'function') return { options: {}, callback: options };
          return { options: options || {}, callback: callback || function(){} };
        }
        const child_process = {
          execSync: function(command, options) {
            const r = runShell(command);
            if (r.status !== 0) throw failure(command, r);
            const encoding = options && options.encoding;
            return encoding && encoding !== 'buffer' ? r.stdout : Buffer.from(r.stdout);
          },
          exec: function(command, options, callback) {
            const args = normalizeExecArgs(options, callback);
            setImmediate(function() {
              const r = runShell(command);
              args.callback(r.status !== 0 ? failure(command, r) : null, r.stdout, r.stderr);
            });
            return { on: function(){ return this; }, stdout: { on: function(){ return this; } }, stderr: { on: function(){ return this; } } };
          },
          spawnSync: function(command, argv, options) {
            options = options || {};
            // These cannot be honoured on the msh path — there is no live child to feed, kill or
            // measure, because a synchronous run reports what the command PRODUCED. Saying so
            // beats accepting them: an ignored `input` leaves a program waiting for output that
            // depends on stdin it thinks it sent, and an ignored `timeout` never fires.
            for (const unsupported of ['input', 'timeout', 'maxBuffer', 'killSignal']) {
              if (options[unsupported] !== undefined) {
                throw Object.assign(
                  new Error("child_process.spawnSync's `" + unsupported + "` option is not " +
                            'available: a synchronous run goes through msh, which reports what a ' +
                            'command produced rather than handing back a live process. Use spawn() ' +
                            'for a child you need to feed, time out or kill'),
                  { code: 'ERR_METHOD_NOT_IMPLEMENTED' });
              }
            }
            const prefix = options.cwd ? 'cd ' + shellQuote(String(options.cwd)) + ' && ' : '';
            const parts = [command].concat((argv || []).map(shellQuote));
            const r = runShell(prefix + parts.join(' '));
            // `encoding` decides strings versus Buffers, and 'buffer' explicitly means Buffers.
            const encoding = options.encoding;
            const shape = encoding && encoding !== 'buffer'
              ? function(text){ return Buffer.from(text).toString(encoding); }
              : function(text){ return Buffer.from(text); };
            return { status: r.status, signal: null, pid: 1,
                     stdout: shape(r.stdout), stderr: shape(r.stderr),
                     output: [null, shape(r.stdout), shape(r.stderr)] };
          },
          execFileSync: function(command, argv, options) {
            const result = child_process.spawnSync(command, argv, options);
            if (result.status !== 0) throw failure(command, { status: result.status, stdout: result.stdout.toString(), stderr: result.stderr.toString() });
            const encoding = options && options.encoding;
            return encoding && encoding !== 'buffer' ? result.stdout.toString() : result.stdout;
          },
          // A NODE child is a live process: its own engine, its own event loop, real pipes.
          // Anything else runs through msh and reports what it produced, which is the right
          // shape for `git status` and the only shape msh can offer.
          spawn: function(command, argv, options) {
            argv = argv || [];
            options = options || {};
            const isNode = /(^|\/)node$/.test(String(command)) || String(command) === process.execPath;
            return isNode ? spawnNodeChild(argv, options) : spawnThroughShell(command, argv, options);
          },
          // fork() is spawn of a node script by definition; the IPC channel is what we cannot
          // give it, so it says so rather than handing back a child whose .send() vanishes.
          // fork() is spawn of a node script WITH a message channel — which is the only thing
          // that distinguishes it, and the thing worker libraries detect.
          fork: function(modulePath, argv, options) {
            if (!Array.isArray(argv)) { options = argv || {}; argv = []; }
            return spawnNodeChild([String(modulePath)].concat(argv.map(String)),
                                  Object.assign({}, options, { ipc: true }));
          },
        };

        function spawnEvalChild(code, argv, options, printResult) {
          // `-p` prints the expression's value, which is `-e` with a console.log wrapped round it.
          const source = printResult ? 'console.log(' + code + ')' : code;
          return spawnNodeChild(['\u0000eval', source].concat(argv), options);
        }

        function spawnThroughShell(command, argv, options) {
          const EventEmitter = coreRequire('events');
          const child = new EventEmitter();
          child.stdout = new EventEmitter();
          child.stderr = new EventEmitter();
          child.stdin = { write: function(){ return true; }, end: function(){}, on: function(){} };
          child.pid = 1;
          child.kill = function(){};
          setImmediate(function() {
            const parts = [command].concat((argv || []).map(shellQuote));
            const probe = runShell(parts.join(' '));
            // A command that does not exist is not a command that FAILED. node reports it as an
            // ENOENT 'error' with no 'spawn' and no exit code, because the exec never happened —
            // and code that checks for a missing binary listens for exactly that. Reporting
            // exit 127 instead made "not installed" indistinguishable from "ran and failed".
            // Only a genuine "command not found" is ENOENT. "No shell attached" is a fact
            // about the HOST, not about the command, and folding the two together would let a
            // missing shell masquerade as a missing binary — the same conflation that made an
            // earlier version of this check appear verified when it was measuring the wrong
            // condition entirely.
            if (probe.status === 127 && /(not found|No such file)/i.test(String(probe.stderr || ''))) {
              const error = new Error('spawn ' + command + ' ENOENT');
              Object.assign(error, { code: 'ENOENT', errno: -2, syscall: 'spawn ' + command, path: command,
                                     spawnargs: (argv || []).slice() });
              child.emit('error', error);
              // node still closes, with a null code and the negative errno.
              process.nextTick(function(){ child.emit('close', -2, null); });
              return;
            }
            // node emits 'spawn' once the child is running, before any output. A consumer that
            // waits for it — and several do — otherwise waits forever.
            child.emit('spawn');
            const r = probe;
            if (r.stdout) child.stdout.emit('data', Buffer.from(r.stdout));
            if (r.stderr) child.stderr.emit('data', Buffer.from(r.stderr));
            child.stdout.emit('end');
            child.stderr.emit('end');
            // 'exit' fires when the process is gone, 'close' once its stdio has drained — in
            // that order. These were reversed, so anything keying off the pair saw the wrong
            // sequence, and code that waits on 'exit' after seeing 'close' never resumed.
            child.exitCode = r.status;
            child.emit('exit', r.status, null);
            process.nextTick(function(){ child.emit('close', r.status, null); });
          });
          return child;
        }

        function spawnNodeChild(argv, options) {
          const EventEmitter = coreRequire('events');
          const { Readable, Writable } = coreRequire('stream');
          let script = String(argv[0] || '');
          let rest = argv.slice(1).map(String);
          // `node -e 'code'` and `--eval`: the code IS the program, not a path to one.
          if (script === '-e' || script === '--eval' || script === '-p' || script === '--print') {
            return spawnEvalChild(String(argv[1] || ''), argv.slice(2).map(String), options,
                                  script === '-p' || script === '--print');
          }
          const child = new EventEmitter();
          child.stdout = new Readable({ read: function(){} });
          child.stderr = new Readable({ read: function(){} });
          child.exitCode = null;
          child.signalCode = null;
          child.killed = false;
          child.spawnfile = 'node';
          child.spawnargs = ['node'].concat(argv.map(String));
          const wantsIPC = !!(options && options.ipc);
          // node: 'json' unless asked otherwise, and the child has to agree with the parent.
          const advancedIPC = String((options && options.serialization) || 'json') === 'advanced';
          // The eval marker is a sentinel argv[0] the recursive call above sets — it can never
          // collide with a real path.
          let isEval = false;
          if (script === '\u0000eval') { isEval = true; script = rest.shift() || ''; }
          const wantsWorker = !!(options && options.worker);
          const mode = (isEval ? 'eval' : '') + (wantsIPC ? (isEval ? '-ipc' : 'ipc') : '') +
                       (wantsWorker ? '-worker' : '');
          const id = bridge.spawnNode(script, rest, String((options && options.cwd) || '/'),
                                      mode, String((options && options.workerData) || ''),
                                      // node REPLACES the environment when `env` is given; the
                                      // caller spreads process.env in if it wants inheritance.
                                      // The child must serialise the way the parent does, and a
                                      // child is a fresh engine with only its environment to
                                      // learn from.
                                      JSON.stringify(Object.assign(
                                        options && options.env ? Object.assign({}, options.env) : Object.assign({}, __env),
                                        advancedIPC ? { __MOUSE_IPC_SERIALIZATION: 'advanced' } : {})),
                                      function(event, payload) {
            // latin1 both ways: the child wrote bytes, and these are those bytes.
            if (event === 'stdout') { child.stdout.push(Buffer.from(String(payload), 'latin1')); return; }
            if (event === 'stderr') { child.stderr.push(Buffer.from(String(payload), 'latin1')); return; }
            if (event === 'message') {
              let message = null;
              try { message = globalThis.__cloneDecode(String(payload)); } catch (error) { message = payload; }
              child.emit('message', message);
              return;
            }
            if (event === 'exit') {
              child.exitCode = payload;
              child.connected = false;
              child.stdout.push(null);
              child.stderr.push(null);
              // node emits 'exit' first, then 'close' once the stdio is drained.
              child.emit('exit', payload, null);
              process.nextTick(function(){ child.emit('close', payload, null); });
            }
          });
          child.pid = id;
          // Same 'spawn' announcement the shell path makes: the child exists and is running.
          setImmediate(function(){ child.emit('spawn'); });
          child.stdin = new Writable({
            write: function(chunk, encoding, callback) {
              // A protocol writes Uint8Arrays; stringifying one is how the packets died.
              const bytes = __toBytes(chunk, encoding);
              bridge.spawnWrite(id, bytes.toString('latin1'));
              callback();
            },
            final: function(callback) { bridge.spawnEnd(id); callback(); },
          });
          child.kill = function(signal) {
            child.killed = true;
            child.signalCode = signal || 'SIGTERM';
            bridge.spawnKill(id);
            return true;
          };
          if (wantsIPC) {
            child.connected = true;
            child.send = function(message, sendHandle, options, callback) {
              const done = typeof callback === 'function' ? callback
                         : (typeof options === 'function' ? options
                         : (typeof sendHandle === 'function' ? sendHandle : null));
              bridge.spawnMessage(id, globalThis.__cloneEncode(
                globalThis.__ipcPrepare(message === undefined ? null : message, advancedIPC)));
              if (done) process.nextTick(function(){ done(null); });
              return true;
            };
            child.channel = { ref: function(){}, unref: function(){} };
          }
          child.unref = function(){ bridge.spawnRef(id, false); return child; };
          child.ref = function(){ bridge.spawnRef(id, true); return child; };
          child.disconnect = function(){ child.connected = false; child.emit('disconnect'); };
          return child;
        }
        return child_process;
      };

      // ---- HTTP: fetch (the modern surface) + https.get/request over it ----
      function rawRequest(url, method, headers, bodyBase64) {
        return new Promise(function(resolve, reject) {
          bridge.httpRequest(String(url), method, headers, bodyBase64, function(result) {
            if (result.error) reject(new Error(result.error));
            else resolve(result);
          });
        });
      }
      // ---- the fetch API family (Headers/Blob/File/FormData/Request/Response) ----
      // Agent CLIs call model APIs through fetch and read `response.headers.get(...)`,
      // iterate headers, and stream `response.body.getReader()`. The old fetch returned a
      // hand-rolled literal with a two-method headers stub and no body stream, so all of
      // that failed. These are the real shapes, built on our ReadableStream.
      globalThis.Headers = class Headers {
        constructor(init) {
          this._pairs = [];
          if (init instanceof Headers) { this._pairs = init._pairs.map(p => [p[0], p[1]]); }
          else if (Array.isArray(init)) { for (const [k, v] of init) this.append(k, v); }
          else if (init && typeof init === 'object') { for (const k of Object.keys(init)) this.append(k, init[k]); }
        }
        append(name, value) { this._pairs.push([String(name).toLowerCase(), String(value)]); }
        set(name, value) { this.delete(name); this.append(name, value); }
        get(name) {
          const key = String(name).toLowerCase();
          const hits = this._pairs.filter(p => p[0] === key).map(p => p[1]);
          return hits.length ? hits.join(', ') : null;
        }
        getSetCookie() { return this._pairs.filter(p => p[0] === 'set-cookie').map(p => p[1]); }
        has(name) { const key = String(name).toLowerCase(); return this._pairs.some(p => p[0] === key); }
        delete(name) { const key = String(name).toLowerCase(); this._pairs = this._pairs.filter(p => p[0] !== key); }
        forEach(fn, thisArg) { for (const [k, v] of this.entries()) fn.call(thisArg, v, k, this); }
        keys() { return this._names()[Symbol.iterator](); }
        values() { return this._names().map(n => this.get(n))[Symbol.iterator](); }
        entries() { return this._names().map(n => [n, this.get(n)])[Symbol.iterator](); }
        [Symbol.iterator]() { return this.entries(); }
        _names() { const seen = []; for (const [k] of this._pairs) if (!seen.includes(k)) seen.push(k); return seen.sort(); }
      };
      globalThis.Blob = class Blob {
        constructor(parts, options) {
          const chunks = [];
          for (const part of parts || []) {
            if (part instanceof Blob) chunks.push(part._bytes);
            else if (Buffer.isBuffer(part)) chunks.push(part);
            else if (part instanceof Uint8Array) chunks.push(Buffer.from(part));
            else if (part instanceof ArrayBuffer) chunks.push(Buffer.from(new Uint8Array(part)));
            else chunks.push(Buffer.from(String(part)));
          }
          this._bytes = Buffer.concat(chunks);
          this.type = (options && options.type) || '';
        }
        get size() { return this._bytes.length; }
        text() { return Promise.resolve(this._bytes.toString()); }
        bytes() { return Promise.resolve(new Uint8Array(this._bytes)); }
        arrayBuffer() {
          const copy = Buffer.from(this._bytes);
          return Promise.resolve(copy.buffer.slice(copy.byteOffset, copy.byteOffset + copy.length));
        }
        slice(start, end, type) { return new Blob([this._bytes.slice(start, end)], { type: type || this.type }); }
        stream() {
          const bytes = this._bytes;
          return new ReadableStream({ start: function(controller) { if (bytes.length) controller.enqueue(bytes); controller.close(); } });
        }
      };
      globalThis.File = class File extends Blob {
        constructor(parts, name, options) {
          super(parts, options);
          this.name = String(name);
          this.lastModified = (options && options.lastModified) || Date.now();
        }
      };
      globalThis.FormData = class FormData {
        constructor() { this._pairs = []; }
        append(name, value, filename) { this._pairs.push([String(name), value, filename]); }
        set(name, value, filename) { this.delete(name); this.append(name, value, filename); }
        get(name) { const hit = this._pairs.find(p => p[0] === String(name)); return hit ? hit[1] : null; }
        getAll(name) { return this._pairs.filter(p => p[0] === String(name)).map(p => p[1]); }
        has(name) { return this._pairs.some(p => p[0] === String(name)); }
        delete(name) { this._pairs = this._pairs.filter(p => p[0] !== String(name)); }
        forEach(fn, thisArg) { for (const [k, v] of this._pairs) fn.call(thisArg, v, k, this); }
        keys() { return this._pairs.map(p => p[0])[Symbol.iterator](); }
        values() { return this._pairs.map(p => p[1])[Symbol.iterator](); }
        entries() { return this._pairs.map(p => [p[0], p[1]])[Symbol.iterator](); }
        [Symbol.iterator]() { return this.entries(); }
      };
      // A body mixin shared by Request and Response.
      function defineBody(target, bytes) {
        target._bytes = bytes;
        target.bodyUsed = false;
        Object.defineProperty(target, 'body', {
          configurable: true,
          get: function() {
            // A one-shot stream over bytes already in hand. A response that is still ARRIVING
            // uses defineStreamBody instead, which hands over the live stream.
            return new ReadableStream({ start: function(controller) {
              if (bytes.length) controller.enqueue(new Uint8Array(bytes));
              controller.close();
            } });
          },
        });
        target.text = function() { target.bodyUsed = true; return Promise.resolve(bytes.toString()); };
        target.json = function() { target.bodyUsed = true; return Promise.resolve(JSON.parse(bytes.toString())); };
        // The body readers are a SET — text, json, arrayBuffer, blob, bytes and formData. Only
        // this one was missing, so a handler reading a posted form got "not a function".
        target.formData = function() {
          target.bodyUsed = true;
          return Promise.resolve(globalThis.__parseFormBody(bytes.toString(), target.headers));
        };
        target.bytes = function() { target.bodyUsed = true; return Promise.resolve(new Uint8Array(bytes)); };
        target.arrayBuffer = function() {
          target.bodyUsed = true;
          const copy = Buffer.from(bytes);
          return Promise.resolve(copy.buffer.slice(copy.byteOffset, copy.byteOffset + copy.length));
        };
        target.blob = function() { target.bodyUsed = true; return Promise.resolve(new Blob([bytes])); };
      }
      // A body that is still arriving: `body` IS the live stream, and the one-shot readers
      // (text/json/bytes) drain it — once, like node, since a stream cannot be read twice.
      function defineStreamBody(target, stream) {
        target.bodyUsed = false;
        target._streaming = true;
        let drained = null;
        Object.defineProperty(target, 'body', {
          configurable: true,
          get: function() { return stream; },
        });
        function drain() {
          if (drained) return drained;
          target.bodyUsed = true;
          const reader = stream.getReader();
          const chunks = [];
          drained = (function pump() {
            return reader.read().then(function(result) {
              if (result.done) return Buffer.concat(chunks);
              chunks.push(Buffer.isBuffer(result.value) ? result.value : Buffer.from(result.value));
              return pump();
            });
          })();
          return drained;
        }
        target.text = function() { return drain().then(function(bytes){ return bytes.toString(); }); };
        target.json = function() { return drain().then(function(bytes){ return JSON.parse(bytes.toString()); }); };
        target.formData = function() {
          return drain().then(function(bytes){
            return globalThis.__parseFormBody(bytes.toString(), target.headers);
          });
        };
        target.bytes = function() { return drain().then(function(bytes){ return new Uint8Array(bytes); }); };
        target.arrayBuffer = function() {
          return drain().then(function(bytes) {
            const copy = Buffer.from(bytes);
            return copy.buffer.slice(copy.byteOffset, copy.byteOffset + copy.length);
          });
        };
        target.blob = function() { return drain().then(function(bytes){ return new Blob([bytes]); }); };
      }
      globalThis.Request = class Request {
        constructor(input, options) {
          options = options || {};
          this.url = input instanceof Request ? input.url : String(input);
          this.method = String(options.method || (input instanceof Request ? input.method : 'GET')).toUpperCase();
          this.headers = new Headers(options.headers || (input instanceof Request ? input.headers : undefined));
          this.signal = options.signal || (input instanceof Request ? input.signal : undefined);
          this.redirect = options.redirect || 'follow';
          // The rest of the fetch Request surface. Browser concepts that node still reports
          // with fixed defaults, and libraries read them — an absent field reads as undefined
          // and fails a comparison that node would pass.
          this.mode = options.mode || 'cors';
          this.credentials = options.credentials || 'same-origin';
          this.cache = options.cache || 'default';
          this.referrer = options.referrer === undefined ? 'about:client' : options.referrer;
          this.referrerPolicy = options.referrerPolicy || '';
          this.integrity = options.integrity || '';
          this.keepalive = !!options.keepalive;
          this.destination = '';
          // node reports 'half' — a request body streams one way only.
          this.duplex = options.duplex || 'half';
          this.isHistoryNavigation = false;
          this.isReloadNavigation = false;
          const body = options.body !== undefined ? options.body : (input instanceof Request ? input._bytes : undefined);
          defineBody(this, body === undefined || body === null ? Buffer.alloc(0)
                     : (Buffer.isBuffer(body) ? body : Buffer.from(String(body))));
        }
        clone() { return new Request(this, {}); }
      };
      globalThis.Response = class Response {
        constructor(body, options) {
          options = options || {};
          this.status = options.status === undefined ? 200 : options.status;
          this.statusText = options.statusText === undefined ? '' : String(options.statusText);
          this.headers = new Headers(options.headers);
          this.url = options.url || '';
          this.redirected = !!options.redirected;
          this.type = options.type || 'default';
          // A ReadableStream body stays a stream — that is what makes a streaming response
          // readable as it arrives instead of after it finishes.
          if (body && typeof body.getReader === 'function') { defineStreamBody(this, body); return; }
          defineBody(this, body === undefined || body === null ? Buffer.alloc(0)
                     : (Buffer.isBuffer(body) ? body : Buffer.from(String(body))));
        }
        get ok() { return this.status >= 200 && this.status < 300; }
        clone() {
          if (this._streaming) {
            // node tees the stream here; teeing needs a tee, which our ReadableStream does not
            // have. Saying so beats handing back a response whose body is already spent.
            throw Object.assign(new Error('cannot clone a response whose body is still streaming: read it once, or buffer it with text()/arrayBuffer() first'),
                                { code: 'ERR_INVALID_STATE' });
          }
          return new Response(this._bytes, { status: this.status, statusText: this.statusText,
                                             headers: this.headers, url: this.url });
        }
        static json(data, options) {
          const response = new Response(JSON.stringify(data), options);
          if (!response.headers.has('content-type')) response.headers.set('content-type', 'application/json');
          return response;
        }
        static error() { return new Response(null, { status: 0, type: 'error' }); }
        static redirect(url, status) { return new Response(null, { status: status || 302, headers: { location: String(url) } }); }
      };
      // ---- the WebSocket global -------------------------------------------------------
      // node 22 exposes `WebSocket` globally, and browser-shaped libraries reach for it. Ours
      // rides URLSession's WebSocket task, which is the ONLY path to `wss://` on this device —
      // TLS is a handshake we cannot put on a raw socket. Plain `ws://` also works through the
      // `ws` package on our own sockets; this is the standard API, and the encrypted one.
      globalThis.WebSocket = class WebSocket {
        constructor(url, protocols) {
          this.url = String(url);
          this.readyState = WebSocket.CONNECTING;
          this.binaryType = 'blob';       // the WHATWG default; node uses 'nodebuffer'
          this.protocol = '';
          this.extensions = '';
          this.bufferedAmount = 0;
          this.onopen = null;
          this.onmessage = null;
          this.onclose = null;
          this.onerror = null;
          this._listeners = {};
          const list = protocols === undefined ? []
            : (Array.isArray(protocols) ? protocols.map(String) : [String(protocols)]);
          const self = this;
          this._id = bridge.wsOpen(this.url, list, function(event, payload) {
            if (event === 'open') {
              self.readyState = WebSocket.OPEN;
              self._fire('open', { type: 'open' });
              return;
            }
            if (event === 'message') {
              const data = payload.binary
                ? (self.binaryType === 'arraybuffer'
                    ? (function(b){ return b.buffer.slice(b.byteOffset, b.byteOffset + b.length); })(Buffer.from(payload.data, 'base64'))
                    : Buffer.from(payload.data, 'base64'))
                : payload.data;
              self._fire('message', { type: 'message', data: data });
              return;
            }
            if (event === 'error') {
              self._fire('error', { type: 'error', message: payload });
              return;
            }
            if (event === 'close') {
              self.readyState = WebSocket.CLOSED;
              self._fire('close', { type: 'close', code: payload.code, reason: payload.reason,
                                    wasClean: payload.code === 1000 });
            }
          });
          if (!this._id) {
            throw Object.assign(new TypeError('Invalid WebSocket URL: ' + this.url), { code: 'ERR_INVALID_URL' });
          }
        }
        _fire(name, event) {
          const handler = this['on' + name];
          if (typeof handler === 'function') handler.call(this, event);
          for (const listener of (this._listeners[name] || []).slice()) listener.call(this, event);
        }
        addEventListener(name, listener) {
          (this._listeners[name] = this._listeners[name] || []).push(listener);
        }
        removeEventListener(name, listener) {
          const list = this._listeners[name] || [];
          const at = list.indexOf(listener);
          if (at >= 0) list.splice(at, 1);
        }
        send(data) {
          if (this.readyState !== WebSocket.OPEN) {
            throw Object.assign(new Error('WebSocket is not open'), { code: 'ERR_WEBSOCKET_NOT_OPEN' });
          }
          if (typeof data === 'string') { bridge.wsSend(this._id, data, true); return; }
          const bytes = __toBytes(data);
          bridge.wsSend(this._id, bytes.toString('base64'), false);
        }
        close(code, reason) {
          if (this.readyState === WebSocket.CLOSED || this.readyState === WebSocket.CLOSING) return;
          this.readyState = WebSocket.CLOSING;
          bridge.wsClose(this._id, code === undefined ? 1000 : Number(code), String(reason || ''));
        }
        ping() {}   // node's extension; the system task keeps the connection alive itself
      };
      globalThis.WebSocket.CONNECTING = 0;
      globalThis.WebSocket.OPEN = 1;
      globalThis.WebSocket.CLOSING = 2;
      globalThis.WebSocket.CLOSED = 3;
      // The event classes node exports alongside it.
      globalThis.CloseEvent = class CloseEvent {
        constructor(type, options) {
          options = options || {};
          this.type = type;
          this.code = options.code === undefined ? 1000 : options.code;
          this.reason = options.reason || '';
          this.wasClean = !!options.wasClean;
        }
      };
      globalThis.MessageEvent = class MessageEvent {
        constructor(type, options) {
          options = options || {};
          this.type = type;
          this.data = options.data;
          this.origin = options.origin || '';
          this.lastEventId = options.lastEventId || '';
        }
      };
      globalThis.navigator = globalThis.navigator || {
        userAgent: 'Mouse/1.0 (iOS; JavaScriptCore)',
        platform: 'iPhone',
        hardwareConcurrency: 1,
        language: 'en-US',
      };
      // Now that zlib codes incrementally, the web compression streams are real.
      globalThis.CompressionStream = class CompressionStream {
        constructor(format) {
          const zlib = coreRequire('zlib');
          const mode = format === 'deflate' ? 'deflate' : (format === 'deflate-raw' ? 'deflateRaw' : 'gzip');
          const coder = new zlib[mode[0].toUpperCase() + mode.slice(1)]();
          this.readable = coder;
          this.writable = coder;
        }
      };
      globalThis.DecompressionStream = class DecompressionStream {
        constructor(format) {
          const zlib = coreRequire('zlib');
          const mode = format === 'deflate' ? 'inflate' : (format === 'deflate-raw' ? 'inflateRaw' : 'gunzip');
          const coder = new zlib[mode[0].toUpperCase() + mode.slice(1)]();
          this.readable = coder;
          this.writable = coder;
        }
      };

      globalThis.fetch = function(input, options) {
        options = options || {};
        const request = input instanceof Request && !options.method && !options.body && !options.headers
          ? input : new Request(input, options);
        const headers = {};
        request.headers.forEach(function(value, name) { headers[name] = value; });
        const bodyBase64 = request._bytes.length ? request._bytes.toString('base64') : '';
        const signal = request.signal;
        if (signal && signal.aborted) {
          return Promise.reject(signal.reason || Object.assign(new Error('This operation was aborted'), { name: 'AbortError' }));
        }
        // The response settles when the HEAD arrives, not when the body finishes: that is the
        // whole point of a stream, and it is what lets an SSE reader see tokens as they are
        // sent instead of all at once when the connection ends.
        const inFlight = new Promise(function(resolve, reject) {
          let controller = null;
          let settled = false;
          const pending = [];
          const stream = new ReadableStream({
            start: function(c) {
              controller = c;
              for (const chunk of pending) controller.enqueue(chunk);
              pending.length = 0;
            },
          });
          bridge.httpStream(request.url, request.method, headers, bodyBase64, function(event, payload) {
            if (event === 'head') {
              settled = true;
              resolve(new Response(stream, {
                status: payload.status,
                statusText: String(payload.status),
                headers: payload.headers,
                url: request.url,
              }));
              return;
            }
            if (event === 'data') {
              const chunk = Buffer.from(payload, 'base64');
              if (controller) controller.enqueue(chunk); else pending.push(chunk);
              return;
            }
            if (event === 'end') {
              if (controller) controller.close();
              return;
            }
            // An error before the head fails the fetch; after it, the stream is what fails.
            const error = Object.assign(new Error('fetch failed: ' + payload), { cause: new Error(String(payload)) });
            if (!settled) reject(error);
            else if (controller) controller.error(error);
          });
        });
        if (!signal) return inFlight;
        // An abort mid-flight rejects the caller; the request itself still completes in the
        // bridge (no cancellation primitive there yet — recorded, not pretended).
        return new Promise(function(resolve, reject) {
          signal.addEventListener('abort', function() {
            reject(signal.reason || Object.assign(new Error('This operation was aborted'), { name: 'AbortError' }));
          });
          inFlight.then(resolve, reject);
        });
      };
      function makeHttpModule(defaultProtocol) {
        // https keeps riding URLSession: TLS is a handshake we cannot put on a raw socket, and
        // the system already owns a correct one. Its response STREAMS now (the delegate form of
        // the transport), so the remaining difference from the plaintext path is upgrades —
        // there is no 101 handover through URLSession.
        function tlsRequest(url, options, callback) {
          const EventEmitter = coreRequire('events');
          const clientRequest = new EventEmitter();
          let body = '';
          clientRequest.write = function(chunk) { body += chunk; return true; };
          clientRequest.setHeader = function(name, value) { (options.headers = options.headers || {})[name] = value; };
          clientRequest.getHeader = function(name) { return (options.headers || {})[name]; };
          clientRequest.removeHeader = function(name) { delete (options.headers || {})[name]; };
          clientRequest.setTimeout = function(){ return clientRequest; };
          clientRequest.abort = function(){};
          clientRequest.destroy = function(){};
          clientRequest.end = function(chunk) {
            if (chunk) body += chunk;
            const headers = {};
            for (const key of Object.keys(options.headers || {})) headers[key] = String(options.headers[key]);
            let response = null;
            let encoding = null;
            bridge.httpStream(url, options.method || 'GET', headers,
                              body ? Buffer.from(body).toString('base64') : '',
                              function(event, payload) {
              if (event === 'head') {
                const { Readable } = coreRequire('stream');
                response = new Readable({ read: function(){} });
                response.statusCode = payload.status;
                response.statusMessage = '';
                response.headers = payload.headers;
                response.rawHeaders = Object.keys(payload.headers)
                  .reduce(function(all, key){ all.push(key, payload.headers[key]); return all; }, []);
                response.httpVersion = '1.1';
                response.complete = false;
                response.req = clientRequest;   // node's back-reference; follow-redirects reads it
                response.setEncoding = function(name) { encoding = name; response._readableEncoding = name; return response; };
                if (callback) callback(response);
                clientRequest.emit('response', response);
                return;
              }
              if (!response) return;
              if (event === 'data') { response.push(Buffer.from(payload, 'base64')); return; }
              if (event === 'end') { response.complete = true; response.push(null); return; }
              response.destroy(new Error(String(payload)));
            });
          };
          return clientRequest;
        }

        const EventEmitter = coreRequire('events');
        const { Readable, Writable } = coreRequire('stream');
        const net = coreRequire('net');
        class OutgoingMessage extends Writable {}
        // ---- the connection pool -------------------------------------------------------
        // node's Agent keeps finished sockets and hands them to the next request for the same
        // host:port, which is why node sends several requests down one connection. Without it
        // we opened a connection per request — correct HTTP, but a visible difference and a
        // handshake per call. A pooled socket is UNREF'd while idle, exactly as node does, so a
        // warm pool never keeps a program alive.
        function Agent(options) {
          EventEmitter.call(this);
          options = options || {};
          this.options = options;
          // node 19+ defaults keepAlive to true.
          this.keepAlive = options.keepAlive !== false;
          this.keepAliveMsecs = options.keepAliveMsecs === undefined ? 1000 : options.keepAliveMsecs;
          this.maxSockets = options.maxSockets || Infinity;
          this.maxFreeSockets = options.maxFreeSockets === undefined ? 256 : options.maxFreeSockets;
          this.scheduling = options.scheduling || 'lifo';
          this.sockets = {};          // in use, by name
          this.freeSockets = {};      // idle and reusable, by name
          this.requests = {};
          // Reported state node exposes and subclasses read.
          this.defaultPort = options.defaultPort || 80;
          this.protocol = options.protocol || 'http:';
          this.maxTotalSockets = options.maxTotalSockets || Infinity;
        }
        Agent.prototype = Object.create(EventEmitter.prototype);
        Agent.prototype.constructor = Agent;
        Agent.prototype.getName = function(options) {
          options = options || {};
          return (options.host || options.hostname || 'localhost') + ':' + (options.port || 80);
        };
        /// An idle socket for this destination, or null. Dead ones are discarded on the way.
        Agent.prototype._take = function(name) {
          const free = this.freeSockets[name];
          if (!free || !free.length) return null;
          while (free.length) {
            // 'lifo' — node's default, and the warm socket is the most likely to still be up.
            const socket = this.scheduling === 'fifo' ? free.shift() : free.pop();
            if (socket && !socket.destroyed && socket.writable && !socket._sawEOF) {
              // The idle watchers below belong to the POOL, not to the request about to run.
              socket.removeAllListeners('end');
              socket.removeAllListeners('error');
              socket.removeAllListeners('close');
              socket.ref();
              (this.sockets[name] = this.sockets[name] || []).push(socket);
              return socket;
            }
          }
          return null;
        };
        Agent.prototype._claim = function(name, socket) {
          (this.sockets[name] = this.sockets[name] || []).push(socket);
        };
        /// A finished socket goes back to the pool, or is closed when it cannot be reused.
        Agent.prototype._release = function(name, socket, reusable) {
          const inUse = this.sockets[name] || [];
          const at = inUse.indexOf(socket);
          if (at >= 0) inUse.splice(at, 1);
          if (!inUse.length) delete this.sockets[name];
          const free = this.freeSockets[name] = this.freeSockets[name] || [];
          if (!this.keepAlive || !reusable || socket.destroyed || !socket.writable ||
              free.length >= this.maxFreeSockets) {
            socket.end();
            return;
          }
          // The next request installs its own handlers; anything left from this one would see
          // the next response.
          socket.removeAllListeners('data');
          socket.removeAllListeners('end');
          socket.removeAllListeners('error');
          socket.removeAllListeners('close');
          const self = this;
          const evict = function() {
            const list = self.freeSockets[name] || [];
            const index = list.indexOf(socket);
            if (index >= 0) list.splice(index, 1);
          };
          socket.once('close', evict);
          // A server that closes an idle keep-alive connection is ordinary — the peer may also
          // simply be gone. Either way the socket must leave the pool: handing out a socket
          // whose peer has hung up turns the next request into a wait for a reply that cannot
          // come. Found by cluster's test, where killing a worker left its connections in the
          // primary's pool and the next request hung until the watchdog fired.
          socket.once('end', function(){ socket._sawEOF = true; evict(); socket.destroy(); });
          socket.once('error', function(){ socket._sawEOF = true; evict(); socket.destroy(); });
          // Idle sockets must not hold the event loop open — node unrefs them too.
          socket.unref();
          free.push(socket);
        };
        Agent.prototype.destroy = function() {
          for (const name of Object.keys(this.freeSockets)) {
            for (const socket of this.freeSockets[name]) socket.destroy();
          }
          this.freeSockets = {};
        };
        Agent.prototype.createConnection = function(options) {
          return net.connect(options);
        };
        // The lifecycle hooks node calls and subclasses override. Each is called from the
        // client rather than merely present — a hook nothing invokes is decoration.
        Agent.prototype.keepSocketAlive = function(socket) {
          if (socket && socket.setKeepAlive) socket.setKeepAlive(true, this.keepAliveMsecs);
          return true;
        };
        Agent.prototype.reuseSocket = function() {};
        Agent.prototype.removeSocket = function(socket, options) {
          const name = this.getName(options || {});
          for (const bucket of [this.sockets, this.freeSockets]) {
            const list = bucket[name];
            if (!list) continue;
            const index = list.indexOf(socket);
            if (index >= 0) list.splice(index, 1);
            if (!list.length) delete bucket[name];
          }
        };
        Agent.prototype.createSocket = function(request, options, callback) {
          const socket = this.createConnection(options);
          if (typeof callback === 'function') callback(null, socket);
          return socket;
        };
        Object.defineProperty(Agent.prototype, 'totalSocketCount', {
          get: function() {
            let total = 0;
            for (const bucket of [this.sockets, this.freeSockets]) {
              for (const name of Object.keys(bucket)) total += (bucket[name] || []).length;
            }
            return total;
          },
          configurable: true,
        });
        // -- the HTTP/1.1 SERVER, on top of real net ------------------------------------
        // Wire behavior is matched to real node's, measured with a raw-socket client rather
        // than assumed: user headers keep insertion order, then Date, then
        // Connection/Keep-Alive, then framing. `res.end(body)` with no prior write sends
        // Content-Length (not chunked) — node's one-shot path, and the difference is visible
        // on the wire.
        const STATUS_CODES = {
          100: 'Continue', 101: 'Switching Protocols', 200: 'OK', 201: 'Created',
          202: 'Accepted', 204: 'No Content', 206: 'Partial Content',
          301: 'Moved Permanently', 302: 'Found', 303: 'See Other', 304: 'Not Modified',
          307: 'Temporary Redirect', 308: 'Permanent Redirect', 400: 'Bad Request',
          401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found',
          405: 'Method Not Allowed', 406: 'Not Acceptable', 408: 'Request Timeout',
          409: 'Conflict', 410: 'Gone', 411: 'Length Required',
          413: 'Payload Too Large', 414: 'URI Too Long', 415: 'Unsupported Media Type',
          416: 'Range Not Satisfiable', 418: "I'm a Teapot", 422: 'Unprocessable Entity',
          426: 'Upgrade Required', 429: 'Too Many Requests', 431: 'Request Header Fields Too Large',
          500: 'Internal Server Error', 501: 'Not Implemented', 502: 'Bad Gateway',
          503: 'Service Unavailable', 504: 'Gateway Timeout', 505: 'HTTP Version Not Supported',
        };

        function IncomingMessage(socket) {
          Readable.call(this);
          this.socket = socket;
          this.connection = socket;
          this.httpVersion = '1.1';
          this.httpVersionMajor = 1;
          this.httpVersionMinor = 1;
          this.method = null;
          this.url = null;
          this.headers = {};
          this.rawHeaders = [];
          this.trailers = {};
          this.rawTrailers = [];
          this.complete = false;
          this.statusCode = null;
          this.statusMessage = null;
          this.aborted = false;
        }
        IncomingMessage.prototype = Object.create(Readable.prototype);
        IncomingMessage.prototype.constructor = IncomingMessage;
        IncomingMessage.prototype.setTimeout = function(ms, callback) {
          if (this.socket) this.socket.setTimeout(ms, callback);
          return this;
        };
        IncomingMessage.prototype._read = function() {};

        function ServerResponse(socket, options) {
          Writable.call(this);
          options = options || {};
          this.socket = socket;
          this.connection = socket;
          this.statusCode = 200;
          this.statusMessage = undefined;
          this.headersSent = false;
          this.sendDate = true;
          this.finished = false;
          this._order = [];             // [lowercased, name, value] in insertion order
          this._chunked = false;
          this._wroteBody = false;
          this._httpVersion = options.httpVersion || '1.1';
          this._keepAlive = options.keepAlive !== false;
          this._bodyless = !!options.bodyless;   // HEAD, and 204/304 responses
          this._hostOwnsClose = true;            // the socket owns 'close'
        }
        ServerResponse.prototype = Object.create(Writable.prototype);
        ServerResponse.prototype.constructor = ServerResponse;

        ServerResponse.prototype._slot = function(name) {
          const key = String(name).toLowerCase();
          for (let i = 0; i < this._order.length; i++) if (this._order[i][0] === key) return this._order[i];
          return null;
        };
        ServerResponse.prototype.setHeader = function(name, value) {
          if (this.headersSent) throw Object.assign(new Error('Cannot set headers after they are sent to the client'),
                                                    { code: 'ERR_HTTP_HEADERS_SENT' });
          const slot = this._slot(name);
          if (slot) { slot[1] = name; slot[2] = value; }
          else this._order.push([String(name).toLowerCase(), name, value]);
          return this;
        };
        ServerResponse.prototype.appendHeader = function(name, value) {
          const slot = this._slot(name);
          if (!slot) return this.setHeader(name, value);
          const existing = Array.isArray(slot[2]) ? slot[2] : [slot[2]];
          slot[2] = existing.concat(value);
          return this;
        };
        ServerResponse.prototype.getHeader = function(name) {
          const slot = this._slot(name);
          return slot ? slot[2] : undefined;
        };
        ServerResponse.prototype.getHeaders = function() {
          const out = {};
          for (const [key, , value] of this._order) out[key] = value;
          return out;
        };
        ServerResponse.prototype.getHeaderNames = function() { return this._order.map(h => h[0]); };
        ServerResponse.prototype.hasHeader = function(name) { return !!this._slot(name); };
        ServerResponse.prototype.removeHeader = function(name) {
          const key = String(name).toLowerCase();
          this._order = this._order.filter(h => h[0] !== key);
          return this;
        };
        ServerResponse.prototype.writeHead = function(status, message, headers) {
          if (typeof message === 'object' && message !== null) { headers = message; message = undefined; }
          this.statusCode = status;
          if (message !== undefined) this.statusMessage = message;
          if (headers) {
            if (Array.isArray(headers)) {
              for (let i = 0; i < headers.length; i += 2) this.setHeader(headers[i], headers[i + 1]);
            } else {
              for (const name of Object.keys(headers)) this.setHeader(name, headers[name]);
            }
          }
          // writeHead COMMITS the framing, which is observable: node answers
          // `writeHead(404, {...}); res.end('nope')` with Transfer-Encoding: chunked, not the
          // Content-Length its one-shot path would have deduced. Sending the header bytes
          // here is what reproduces that (node buffers them to coalesce one packet, which
          // changes segmentation, not the byte stream).
          this._sendHeaders();
          return this;
        };

        // The exact byte layout node produces. `oneShotLength` is set when end(body) can
        // frame the whole response with Content-Length.
        ServerResponse.prototype._sendHeaders = function(oneShotLength) {
          if (this.headersSent) return;
          this.headersSent = true;
          const message = this.statusMessage !== undefined ? this.statusMessage
                        : (STATUS_CODES[this.statusCode] || 'unknown');
          const lines = ['HTTP/1.1 ' + this.statusCode + ' ' + message];
          let sawConnection = false, sawLength = false, sawEncoding = false, sawDate = false;
          for (const [key, name, value] of this._order) {
            if (key === 'connection') sawConnection = true;
            if (key === 'content-length') sawLength = true;
            if (key === 'transfer-encoding') sawEncoding = true;
            if (key === 'date') sawDate = true;
            const values = Array.isArray(value) ? value : [value];
            for (const one of values) lines.push(name + ': ' + one);
          }
          if (this.sendDate && !sawDate) lines.push('Date: ' + new Date().toUTCString());
          if (!sawConnection) {
            if (this._keepAlive && this._httpVersion === '1.1') {
              lines.push('Connection: keep-alive');
              lines.push('Keep-Alive: timeout=5');
            } else {
              lines.push('Connection: close');
            }
          } else {
            // An explicit `Connection: close` from the handler decides the socket's fate.
            const value = String(this.getHeader('connection') || '').toLowerCase();
            if (value.indexOf('close') >= 0) this._keepAlive = false;
          }
          // A body-less response carries NO framing header — measured: node answers 204 with
          // neither Content-Length nor Transfer-Encoding, and the same goes for 304 and 1xx.
          // For HTTP/1.0 node frames with the CLOSE rather than a deduced Content-Length.
          const bodyless = this._bodyless || this.statusCode === 204 || this.statusCode === 304 ||
                           (this.statusCode >= 100 && this.statusCode < 200);
          this._bodyless = bodyless;
          if (!sawLength && !sawEncoding && !bodyless) {
            if (this._httpVersion !== '1.1') this._keepAlive = false;
            else if (oneShotLength !== undefined) lines.push('Content-Length: ' + oneShotLength);
            else { lines.push('Transfer-Encoding: chunked'); this._chunked = true; }
          } else if (sawEncoding && String(this.getHeader('transfer-encoding')).toLowerCase().indexOf('chunked') >= 0) {
            this._chunked = true;
          }
          this.socket.write(lines.join('\r\n') + '\r\n\r\n');
        };
        ServerResponse.prototype.flushHeaders = function() { this._sendHeaders(); };

        ServerResponse.prototype._write = function(chunk, encoding, callback) {
          const buffer = __toBytes(chunk, encoding);
          // A first write() means the length isn't known up front: headers go out framed
          // chunked, exactly as node does.
          if (!this.headersSent) this._sendHeaders();
          this._wroteBody = true;
          if (this._bodyless) { callback(); return; }
          if (this._chunked) {
            if (buffer.length) this.socket.write(buffer.length.toString(16) + '\r\n');
            if (buffer.length) this.socket.write(buffer);
            if (buffer.length) this.socket.write('\r\n');
          } else if (buffer.length) {
            this.socket.write(buffer);
          }
          callback();
        };

        ServerResponse.prototype.end = function(chunk, encoding, callback) {
          if (typeof chunk === 'function') { callback = chunk; chunk = undefined; }
          else if (typeof encoding === 'function') { callback = encoding; encoding = null; }
          if (this.finished) return this;
          // The one-shot path: nothing written yet and the whole body in hand, so the
          // response can be framed with Content-Length instead of chunked.
          if (!this.headersSent && !this._wroteBody) {
            const buffer = chunk === undefined || chunk === null ? Buffer.alloc(0)
              : __toBytes(chunk, encoding);
            this._sendHeaders(this._bodyless ? undefined : buffer.length);
            if (buffer.length && !this._bodyless) this.socket.write(buffer);
          } else {
            if (chunk !== undefined && chunk !== null) this.write(chunk, encoding);
            if (this._chunked && !this._bodyless) this.socket.write('0\r\n\r\n');
          }
          this.finished = true;
          this.writable = false;
          if (callback) this.once('finish', callback);
          const self = this;
          process.nextTick(function(){
            self._finishEmitted = true;
            self.emit('finish');
            if (self._onDone) self._onDone();
          });
          return this;
        };
        ServerResponse.prototype.writeContinue = function() { this.socket.write('HTTP/1.1 100 Continue\r\n\r\n'); };
        ServerResponse.prototype.setTimeout = function(ms, callback) {
          if (this.socket) this.socket.setTimeout(ms, callback);
          return this;
        };

        // One connection's request stream: headers, then a body framed by Content-Length or
        // chunked encoding, then (keep-alive) the next request in the same buffer.
        function serveConnection(server, socket) {
          let buffer = Buffer.alloc(0);
          let phase = 'head';
          let message = null;
          let remaining = 0;
          let chunkState = 'size';
          let closing = false;
          let idleTimer = null;

          socket.on('data', function(chunk) {
            buffer = Buffer.concat([buffer, chunk]);
            pump();
          });
          socket.on('end', function() {
            if (message && !message.complete) { message.aborted = true; message.emit('aborted'); }
          });
          socket.on('error', function(error) { server.emit('clientError', error, socket); });
          socket.on('close', clearKeepAliveTimeout);

          function pump() {
            while (true) {
              if (closing) return;
              if (phase === 'head') {
                const end = buffer.indexOf('\r\n\r\n');
                if (end < 0) return;
                const head = buffer.slice(0, end).toString('latin1');
                buffer = buffer.slice(end + 4);
                if (!startMessage(head)) return;
                continue;
              }
              if (phase === 'length') {
                if (!buffer.length) return;
                const take = Math.min(remaining, buffer.length);
                message.push(buffer.slice(0, take));
                buffer = buffer.slice(take);
                remaining -= take;
                if (remaining === 0) { finishMessage(); continue; }
                return;
              }
              if (phase === 'chunked') {
                if (chunkState === 'size') {
                  const at = buffer.indexOf('\r\n');
                  if (at < 0) return;
                  const size = parseInt(buffer.slice(0, at).toString('latin1').split(';')[0], 16);
                  buffer = buffer.slice(at + 2);
                  if (!size) {
                    // Trailers, if any, end at the blank line.
                    const trailerEnd = buffer.indexOf('\r\n');
                    if (trailerEnd === 0) buffer = buffer.slice(2);
                    finishMessage();
                    continue;
                  }
                  remaining = size;
                  chunkState = 'data';
                  continue;
                }
                if (buffer.length < remaining + 2) return;
                message.push(buffer.slice(0, remaining));
                buffer = buffer.slice(remaining + 2);
                chunkState = 'size';
                continue;
              }
              return;   // a response is in flight; the next request waits in `buffer`
            }
          }

          function startMessage(head) {
            socket._idleBetweenRequests = false;
            clearKeepAliveTimeout();
            const lines = head.split('\r\n');
            const parts = lines[0].split(' ');
            // A malformed request line was accepted and turned into a message with a nonsense
            // method. node rejects it: 'clientError' is emitted, and with no listener the
            // default is a 400 and a closed socket. Accepting garbage is worse than refusing
            // it — the peer learns nothing and the connection leaks.
            const METHODS = ['GET','POST','PUT','DELETE','HEAD','OPTIONS','PATCH','TRACE',
                             'CONNECT','PROPFIND','PROPPATCH','MKCOL','COPY','MOVE','LOCK',
                             'UNLOCK','REPORT','MKACTIVITY','CHECKOUT','MERGE','SEARCH','PURGE'];
            if (parts.length < 2 || METHODS.indexOf(parts[0]) < 0 ||
                (parts[2] !== undefined && parts[2].slice(0, 5) !== 'HTTP/')) {
              const error = new Error('Parse Error: Invalid method encountered');
              error.code = parts.length >= 2 && METHODS.indexOf(parts[0]) < 0
                ? 'HPE_INVALID_METHOD' : 'HPE_INVALID_CONSTANT';
              error.rawPacket = Buffer.from(head);
              const listeners = server.listenerCount ? server.listenerCount('clientError') : 0;
              if (listeners > 0) {
                server.emit('clientError', error, socket);
              } else {
                // node's default: answer 400 and close, so the peer is told rather than left
                // waiting on a connection that will never reply.
                try { socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); } catch (ignored) {}
                socket.destroy();
              }
              buffer = '';
              return;
            }
            message = new IncomingMessage(socket);
            message.method = parts[0];
            message.url = parts[1] || '/';
            const version = (parts[2] || 'HTTP/1.1').replace('HTTP/', '');
            message.httpVersion = version;
            message.httpVersionMajor = Number(version.split('.')[0]) || 1;
            message.httpVersionMinor = Number(version.split('.')[1]) || 1;
            for (let i = 1; i < lines.length; i++) {
              const at = lines[i].indexOf(':');
              if (at < 0) continue;
              const name = lines[i].slice(0, at).trim();
              const value = lines[i].slice(at + 1).trim();
              const key = name.toLowerCase();
              message.rawHeaders.push(name, value);
              // node's rules: set-cookie accumulates, most others keep the first, and a few
              // comma-join.
              if (key === 'set-cookie') (message.headers[key] = message.headers[key] || []).push(value);
              else if (message.headers[key] === undefined) message.headers[key] = value;
              else if (key === 'cookie') message.headers[key] += '; ' + value;
              else if (['age','authorization','content-length','content-type','etag','expires',
                        'from','host','if-modified-since','if-unmodified-since','last-modified',
                        'location','max-forwards','proxy-authorization','referer','retry-after',
                        'server','user-agent'].indexOf(key) < 0) message.headers[key] += ', ' + value;
            }

            const keepAlive = wantsKeepAlive(message);
            const bodyless = message.method === 'HEAD';
            const response = new ServerResponse(socket, {
              httpVersion: message.httpVersion, keepAlive: keepAlive, bodyless: bodyless,
            });
            response._onDone = function() { responseDone(response, keepAlive); };

            // An upgrade (WebSocket's handshake) hands the raw socket to the listener and
            // this connection stops being HTTP.
            if (message.headers.upgrade && server.listenerCount('upgrade')) {
              phase = 'upgrade';
              closing = true;
              const head = buffer;
              buffer = Buffer.alloc(0);
              server.emit('upgrade', message, socket, head);
              return false;
            }

            if (String(message.headers.expect || '').toLowerCase() === '100-continue') {
              if (server.listenerCount('checkContinue')) {
                setBodyFraming(message);
                server.emit('checkContinue', message, response);
                return true;
              }
              socket.write('HTTP/1.1 100 Continue\r\n\r\n');
            }

            setBodyFraming(message);
            server.emit('request', message, response);
            return true;
          }

          function setBodyFraming(msg) {
            const encoding = String(msg.headers['transfer-encoding'] || '').toLowerCase();
            if (encoding.indexOf('chunked') >= 0) { phase = 'chunked'; chunkState = 'size'; return; }
            const length = Number(msg.headers['content-length'] || 0);
            if (length > 0) { phase = 'length'; remaining = length; return; }
            phase = 'idle';
            finishMessage();
          }

          function finishMessage() {
            if (!message || message.complete) { phase = 'idle'; return; }
            message.complete = true;
            phase = 'idle';
            message.push(null);
          }

          function responseDone(response, keepAlive) {
            if (!keepAlive) { closing = true; socket.end(); return; }
            message = null;
            phase = 'head';
            // An idle keep-alive connection must eventually be dropped, or `server.close()`
            // waits on a peer that has no reason to speak again. node enforces exactly this
            // with keepAliveTimeout; without it a POOLING client (which never closes its end)
            // left the server waiting forever.
            armKeepAliveTimeout();
            // A pipelined request may already be sitting in the buffer.
            if (buffer.length) process.nextTick(pump);
          }
          function armKeepAliveTimeout() {
            socket._idleBetweenRequests = true;
            clearKeepAliveTimeout();
            const wait = server.keepAliveTimeout;
            if (!wait) return;
            idleTimer = setTimeout(function() {
              idleTimer = null;
              closing = true;
              socket.end();
            }, wait);
          }
          function clearKeepAliveTimeout() {
            if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
          }

          function wantsKeepAlive(msg) {
            const value = String(msg.headers.connection || '').toLowerCase();
            if (value.indexOf('close') >= 0) return false;
            if (msg.httpVersionMajor === 1 && msg.httpVersionMinor === 0) return value.indexOf('keep-alive') >= 0;
            // NOT `server.keepAlive`: node uses that name for a reported OPTION whose default
            // is false, while this is the protocol behaviour whose default is ON. Sharing the
            // name meant adding node's property silently disabled keep-alive on every server.
            return server._keepAliveDisabled !== true;
          }
        }

        function Server(options, handler) {
          if (typeof options === 'function') { handler = options; options = {}; }
          options = options || {};
          net.Server.call(this, options);
          this.timeout = 0;
          this.keepAliveTimeout = 5000;
          this.headersTimeout = 60000;
          this.requestTimeout = 300000;
          this.maxHeadersCount = null;
          // Protocol options node keeps on the server. `undefined` where node leaves it
          // undefined rather than inventing a value — an honest default is still a default.
          this.httpAllowHalfOpen = !!options.httpAllowHalfOpen;
          this.maxRequestsPerSocket = options.maxRequestsPerSocket || 0;
          this.requireHostHeader = options.requireHostHeader === undefined ? true : !!options.requireHostHeader;
          this.rejectNonStandardBodyWrites = !!options.rejectNonStandardBodyWrites;
          this.connectionsCheckingInterval = options.connectionsCheckingInterval === undefined
            ? 30000 : options.connectionsCheckingInterval;
          this.maxHeaderSize = options.maxHeaderSize;
          this.insecureHTTPParser = options.insecureHTTPParser;
          this.joinDuplicateHeaders = options.joinDuplicateHeaders;
          if (handler) this.on('request', handler);
          const self = this;
          this.on('connection', function(socket) { serveConnection(self, socket); });
        }
        Server.prototype = Object.create(net.Server.prototype);
        Server.prototype.constructor = Server;
        Server.prototype.setTimeout = function(ms, callback) {
          this.timeout = ms;
          if (callback) this.on('timeout', callback);
          return this;
        };

        // -- the HTTP/1.1 CLIENT, over raw sockets --------------------------------------
        // Plaintext http rides `net` rather than URLSession, for three things URLSession
        // cannot do: deliver a response body INCREMENTALLY (it handed us the complete body,
        // so a streaming endpoint could not be read chunk by chunk), stream a request body,
        // and hand the socket over on a 101 — which is exactly what a WebSocket client needs.
        // https stays on URLSession, because TLS is a handshake we cannot put on a raw socket.
        //
        // The wire format was measured against real node, not assumed: user headers in
        // insertion order, then Host, then Connection, then framing; `end(body)` with nothing
        // written yet sends Content-Length; write()-then-end() is chunked; and GET/HEAD/
        // DELETE/OPTIONS/TRACE/CONNECT get NO framing header at all (node writes a body for
        // those raw, unframed, if you insist on sending one).
        const framelessMethods = ['GET', 'HEAD', 'DELETE', 'OPTIONS', 'TRACE', 'CONNECT'];

        function ClientRequest(options, callback) {
          Writable.call(this);
          const self = this;
          this._hostOwnsClose = true;
          this.method = String(options.method || 'GET').toUpperCase();
          this.path = options.path || '/';
          this._host = options.hostname || options.host || 'localhost';
          if (this._host.indexOf(':') >= 0 && !options.port) {
            const split = this._host.lastIndexOf(':');
            this.port = Number(this._host.slice(split + 1));
            this._host = this._host.slice(0, split);
          } else {
            this.port = Number(options.port) || 80;
          }
          this._order = [];
          this._headersSent = false;
          this._chunked = false;
          this._wroteBody = false;
          this._finished = false;
          this._upgraded = false;
          this._responded = false;
          if (options.headers) {
            for (const name of Object.keys(options.headers)) {
              if (options.headers[name] !== undefined) this.setHeader(name, options.headers[name]);
            }
          }
          if (options.auth) {
            this.setHeader('Authorization', 'Basic ' + Buffer.from(String(options.auth)).toString('base64'));
          }
          if (callback) this.once('response', callback);

          // Reuse a pooled connection when the agent has one for this destination; `agent:
          // false` opts out, which is how node spells "no pooling".
          // A CUSTOM agent was being discarded here: the test was `agent._release`, an internal
          // of this engine's own Agent, so any subclass — which is what every proxy agent is —
          // silently fell back to the global one. Any object offering an agent's interface is
          // an agent.
          this._agent = options.agent === false ? null : (options.agent || globalAgent);
          this._poolName = this._agent && this._agent.getName
            ? this._agent.getName({ host: this._host, port: this.port }) : '';
          const reused = this._agent && this._agent._take ? this._agent._take(this._poolName) : null;
          this.reusedSocket = !!reused;
          if (reused) {
            // node tells the agent a socket is being reused, so a subclass can re-arm whatever
            // state it keeps per request.
            if (this._agent.reuseSocket) this._agent.reuseSocket(reused, this);
            this.socket = reused;
          } else if (this._agent && typeof this._agent.createConnection === 'function'
                     && this._agent.createConnection !== Agent.prototype.createConnection) {
            // Only when the agent OVERRIDES it. The base implementation is equivalent to the
            // path below, and routing every ordinary request through it would change the
            // default connect sequence for no gain — a bigger behavioural change than the fix
            // this is meant to be. Overriding it is how a proxy agent works: the socket it
            // returns goes somewhere else entirely, and nothing here called it, so every such
            // agent was inert.
            const supplied = this._agent.createConnection(Object.assign({}, options, {
              host: this._host, port: this.port, servername: this._host,
            }));
            this._socketFromAgent = !!supplied;
            this.socket = supplied || new net.Socket();
          } else {
            this.socket = new net.Socket();
          }
          this.connection = this.socket;
          this.socket.on('error', function(error) { self.emit('error', error); });
          this.socket.on('close', function() {
            // A response framed by EOF ends here; anything else already ended.
            if (self._parser) self._parser.finish();
            // Node turns "connection went away before it answered" into ECONNRESET rather than
            // leaving the caller waiting. Without this the request emits neither 'response' nor
            // 'error' and simply never finishes — a hang, which is the worst possible shape for
            // a network failure and impossible for a caller to recover from.
            if (!self._responded && !self.destroyed) {
              self.emit('error', Object.assign(new Error('socket hang up'), { code: 'ECONNRESET' }));
            }
            if (!self._closeEmitted) { self._closeEmitted = true; self.emit('close'); }
          });
          this._parser = makeResponseParser(this);
          this.socket.on('data', function(chunk) { self._parser.push(chunk); });
          if (reused) {
            // Already connected: nothing will fire 'connect', so the queued bytes go now.
            process.nextTick(function(){ self.emit('socket', self.socket); self._flushPending(); });
          } else {
            if (this._agent && this._agent._claim) this._agent._claim(this._poolName, this.socket);
            // A socket the AGENT supplied is already connecting — or already connected, in
            // which case its 'connect' event has fired and a listener attached now would wait
            // forever. Only a socket this client made itself needs connecting.
            if (this._socketFromAgent) {
              if (this.socket.connecting || this.socket.pending) {
                this.socket.on('connect', function() {
                  self.emit('socket', self.socket);
                  self._flushPending();
                });
              } else {
                process.nextTick(function(){ self.emit('socket', self.socket); self._flushPending(); });
              }
            } else {
              this.socket.on('connect', function() {
                self.emit('socket', self.socket);
                self._flushPending();
              });
              this.socket.connect(this.port, this._host);
            }
          }
          if (options.timeout) this.setTimeout(options.timeout);
          // An AbortSignal was accepted and dropped, which is the worst possible shape for this
          // particular option: a caller that relies on it to cancel gets a request that can
          // never be cancelled, so the abort silently becomes a permanent wait.
          if (options.signal) {
            const signal = options.signal;
            const onAbort = () => {
              if (self._responded || self.destroyed) return;
              const error = new Error('The operation was aborted');
              error.name = 'AbortError';
              error.code = 'ABORT_ERR';
              self.emit('error', error);
              try { self.socket && self.socket.destroy(); } catch (ignored) {}
              self.destroy();
            };
            if (signal.aborted) process.nextTick(onAbort);
            else if (typeof signal.addEventListener === 'function') signal.addEventListener('abort', onAbort);
            else if (typeof signal.once === 'function') signal.once('abort', onAbort);
          }
        }
        ClientRequest.prototype = Object.create(Writable.prototype);
        ClientRequest.prototype.constructor = ClientRequest;

        ClientRequest.prototype._slot = function(name) {
          const key = String(name).toLowerCase();
          for (let i = 0; i < this._order.length; i++) if (this._order[i][0] === key) return this._order[i];
          return null;
        };
        ClientRequest.prototype.setHeader = function(name, value) {
          const slot = this._slot(name);
          if (slot) { slot[1] = name; slot[2] = value; }
          else this._order.push([String(name).toLowerCase(), name, value]);
          return this;
        };
        ClientRequest.prototype.getHeader = function(name) {
          const slot = this._slot(name);
          return slot ? slot[2] : undefined;
        };
        ClientRequest.prototype.getHeaders = function() {
          const out = {};
          for (const [key, , value] of this._order) out[key] = value;
          return out;
        };
        ClientRequest.prototype.getHeaderNames = function() { return this._order.map(h => h[0]); };
        ClientRequest.prototype.hasHeader = function(name) { return !!this._slot(name); };
        ClientRequest.prototype.removeHeader = function(name) {
          const key = String(name).toLowerCase();
          this._order = this._order.filter(h => h[0] !== key);
          return this;
        };

        ClientRequest.prototype._headerBytes = function(oneShotLength) {
          const lines = [this.method + ' ' + this.path + ' HTTP/1.1'];
          let sawHost = false, sawConnection = false, sawLength = false, sawEncoding = false;
          for (const [key, name, value] of this._order) {
            if (key === 'host') sawHost = true;
            if (key === 'connection') sawConnection = true;
            if (key === 'content-length') sawLength = true;
            if (key === 'transfer-encoding') sawEncoding = true;
            const values = Array.isArray(value) ? value : [value];
            for (const one of values) lines.push(name + ': ' + one);
          }
          if (!sawHost) {
            // Record it as a real header, not just a line on the wire: node's implicit Host is
            // readable through getHeader, and follow-redirects rebuilds the redirect target
            // from exactly that — reading undefined there sent the next hop to port 80.
            const host = this._host + (this.port === 80 ? '' : ':' + this.port);
            this._order.push(['host', 'Host', host]);
            lines.push('Host: ' + host);
          }
          if (!sawConnection) lines.push('Connection: keep-alive');
          else this._sentClose = String(this.getHeader('connection')).toLowerCase().indexOf('close') >= 0;
          if (!sawLength && !sawEncoding && framelessMethods.indexOf(this.method) < 0) {
            if (oneShotLength !== undefined) lines.push('Content-Length: ' + oneShotLength);
            else { lines.push('Transfer-Encoding: chunked'); this._chunked = true; }
          } else if (sawEncoding && String(this.getHeader('transfer-encoding')).toLowerCase().indexOf('chunked') >= 0) {
            this._chunked = true;
          }
          return lines.join('\r\n') + '\r\n\r\n';
        };

        // Writes queue until the socket is connected — a request built synchronously after
        // `http.request(...)` would otherwise write into a socket mid-handshake.
        ClientRequest.prototype._queue = function(data) {
          if (this.socket.connecting || this.socket.pending) {
            (this._pending = this._pending || []).push(data);
            return;
          }
          this.socket.write(data);
        };
        ClientRequest.prototype._flushPending = function() {
          const pending = this._pending;
          this._pending = null;
          if (pending) for (const data of pending) this.socket.write(data);
        };
        ClientRequest.prototype._sendHeaders = function(oneShotLength) {
          if (this._headersSent) return;
          this._headersSent = true;
          this._queue(this._headerBytes(oneShotLength));
        };
        ClientRequest.prototype.flushHeaders = function() { this._sendHeaders(); };
        Object.defineProperty(ClientRequest.prototype, 'headersSent', {
          get: function() { return !!this._headersSent; }, configurable: true,
        });

        ClientRequest.prototype._write = function(chunk, encoding, callback) {
          const buffer = __toBytes(chunk, encoding);
          this._sendHeaders();
          this._wroteBody = true;
          if (buffer.length) {
            if (this._chunked) {
              this._queue(buffer.length.toString(16) + '\r\n');
              this._queue(buffer);
              this._queue('\r\n');
            } else {
              this._queue(buffer);
            }
          }
          callback();
        };
        ClientRequest.prototype.end = function(chunk, encoding, callback) {
          if (typeof chunk === 'function') { callback = chunk; chunk = undefined; }
          else if (typeof encoding === 'function') { callback = encoding; encoding = null; }
          if (this._finished) return this;
          if (!this._headersSent && !this._wroteBody) {
            const buffer = chunk === undefined || chunk === null ? Buffer.alloc(0)
              : __toBytes(chunk, encoding);
            this._sendHeaders(framelessMethods.indexOf(this.method) < 0 ? buffer.length : undefined);
            if (buffer.length) this._queue(buffer);
          } else {
            if (chunk !== undefined && chunk !== null) this.write(chunk, encoding);
            if (this._chunked) this._queue('0\r\n\r\n');
          }
          this._finished = true;
          this.writable = false;
          if (callback) process.nextTick(callback);
          const self = this;
          process.nextTick(function(){ self.emit('finish'); });
          return this;
        };

        ClientRequest.prototype.abort = function() { this.destroy(); };
        ClientRequest.prototype.destroy = function(error) {
          if (this._destroyed) return this;
          this._destroyed = true;
          this.aborted = true;
          this.socket.destroy();
          if (error) this.emit('error', error);
          return this;
        };
        ClientRequest.prototype.setTimeout = function(ms, callback) {
          const self = this;
          this.socket.setTimeout(ms, function(){ self.emit('timeout'); });
          if (callback) this.once('timeout', callback);
          return this;
        };
        ClientRequest.prototype.setNoDelay = function(on) { this.socket.setNoDelay(on); return this; };
        ClientRequest.prototype.setSocketKeepAlive = function(on, delay) {
          this.socket.setKeepAlive(on, delay);
          return this;
        };

        // The response side: a status line, headers, then a body framed by Content-Length,
        // chunked encoding, or the close. Chunks reach the IncomingMessage as they arrive.
        function makeResponseParser(request) {
          let buffer = Buffer.alloc(0);
          let phase = 'head';
          let message = null;
          let remaining = 0;
          let chunkState = 'size';

          function push(chunk) {
            if (phase === 'done' || phase === 'upgraded') return;
            buffer = Buffer.concat([buffer, chunk]);
            pump();
          }

          function pump() {
            while (true) {
              if (phase === 'head') {
                const end = buffer.indexOf('\r\n\r\n');
                if (end < 0) return;
                const head = buffer.slice(0, end).toString('latin1');
                buffer = buffer.slice(end + 4);
                if (!startResponse(head)) return;
                continue;
              }
              if (phase === 'length') {
                if (!buffer.length) return;
                const take = Math.min(remaining, buffer.length);
                message.push(buffer.slice(0, take));
                buffer = buffer.slice(take);
                remaining -= take;
                if (remaining === 0) { complete(); return; }
                return;
              }
              if (phase === 'chunked') {
                if (chunkState === 'size') {
                  const at = buffer.indexOf('\r\n');
                  if (at < 0) return;
                  const size = parseInt(buffer.slice(0, at).toString('latin1').split(';')[0], 16);
                  buffer = buffer.slice(at + 2);
                  if (!size) {
                    if (buffer.indexOf('\r\n') === 0) buffer = buffer.slice(2);
                    complete();
                    return;
                  }
                  remaining = size;
                  chunkState = 'data';
                  continue;
                }
                if (buffer.length < remaining + 2) return;
                message.push(buffer.slice(0, remaining));
                buffer = buffer.slice(remaining + 2);
                chunkState = 'size';
                continue;
              }
              if (phase === 'eof') {
                if (buffer.length) { message.push(buffer); buffer = Buffer.alloc(0); }
                return;
              }
              return;
            }
          }

          function startResponse(head) {
            const lines = head.split('\r\n');
            const status = lines[0].split(' ');
            message = new IncomingMessage(request.socket);
            message.httpVersion = (status[0] || 'HTTP/1.1').replace('HTTP/', '');
            message.httpVersionMajor = Number(message.httpVersion.split('.')[0]) || 1;
            message.httpVersionMinor = Number(message.httpVersion.split('.')[1]) || 1;
            message.statusCode = Number(status[1]) || 0;
            message.statusMessage = status.slice(2).join(' ');
            for (let i = 1; i < lines.length; i++) {
              const at = lines[i].indexOf(':');
              if (at < 0) continue;
              const name = lines[i].slice(0, at).trim();
              const value = lines[i].slice(at + 1).trim();
              const key = name.toLowerCase();
              message.rawHeaders.push(name, value);
              if (key === 'set-cookie') (message.headers[key] = message.headers[key] || []).push(value);
              else if (message.headers[key] === undefined) message.headers[key] = value;
              else message.headers[key] += ', ' + value;
            }

            // 101: the protocol changes and the socket stops being ours. This is the path a
            // WebSocket client takes, and the reason this client had to leave URLSession.
            if (message.statusCode === 101) {
              phase = 'upgraded';
              const head = buffer;
              buffer = Buffer.alloc(0);
              request._upgraded = true;
              request.emit('upgrade', message, request.socket, head);
              return false;
            }
            if (message.statusCode === 100) {
              phase = 'head';          // an interim response; the real one follows
              request.emit('continue');
              return true;
            }

            request._responded = true;
            // node points the response back at the request that produced it, and libraries use
            // it: follow-redirects reads `response.req.getHeader(...)` to carry headers onto the
            // redirected request, so without this a 302 fails instead of being followed.
            message.req = request;
            request.emit('response', message);

            const encoding = String(message.headers['transfer-encoding'] || '').toLowerCase();
            const bodyless = request.method === 'HEAD' || message.statusCode === 204 ||
                             message.statusCode === 304;
            if (bodyless) { complete(); return true; }
            if (encoding.indexOf('chunked') >= 0) { phase = 'chunked'; chunkState = 'size'; return true; }
            if (message.headers['content-length'] !== undefined) {
              remaining = Number(message.headers['content-length']);
              if (!remaining) { complete(); return true; }
              phase = 'length';
              return true;
            }
            phase = 'eof';   // framed by the close
            return true;
          }

          function complete() {
            if (!message || message.complete) return;
            message.complete = true;
            phase = 'done';
            message.push(null);
            // Whether this connection can carry another request: the response must say so, and
            // its body must have been framed (an EOF-framed body ends WITH the connection).
            const connection = String(message.headers.connection || '').toLowerCase();
            const framed = message.headers['content-length'] !== undefined ||
                           String(message.headers['transfer-encoding'] || '').indexOf('chunked') >= 0 ||
                           request.method === 'HEAD' || message.statusCode === 204 || message.statusCode === 304;
            const reusable = framed && connection.indexOf('close') < 0 &&
                             message.httpVersionMajor === 1 && message.httpVersionMinor >= 1 &&
                             !request._sentClose;
            if (request._agent && request._agent._release) {
              // node asks the agent whether a socket may stay alive; a subclass returning false
              // means "close it", which is how an agent opts a connection out of pooling.
              const keep = reusable && (!request._agent.keepSocketAlive
                || request._agent.keepSocketAlive(request.socket) !== false);
              request._agent._release(request._poolName, request.socket, keep);
            } else if (request._agent && request._agent.removeSocket) {
              // A custom agent without this engine's pool still gets told the socket is done.
              request._agent.removeSocket(request.socket, { host: request._host, port: request.port });
            }
            else request.socket.end();
            // node closes the REQUEST after its response has ENDED — not when the socket does
            // (with keep-alive the socket outlives the exchange, so 'close' never fired at all),
            // and not merely when the body is parsed, which would put it BEFORE the response's
            // own 'end' and invert the order a caller sees.
            const closeRequest = function() {
              if (!request._closeEmitted) { request._closeEmitted = true; request.emit('close'); }
            };
            if (message._endEmitted) process.nextTick(closeRequest);
            else message.once('end', function(){ process.nextTick(closeRequest); });
          }

          return {
            push: push,
            finish: function() {
              // The socket closed: an EOF-framed body ends here, anything else is already done.
              if (phase === 'eof' && message) { phase = 'done'; message.complete = true; message.push(null); }
            },
          };
        }

        // node's default agent pools with keepAlive since v19.
        // The module's own scheme, so `https.globalAgent` reports https:/443 rather than
        // inheriting the plaintext defaults — node keeps a separate agent per protocol and
        // callers read these to decide a default port.
        const isSecure = defaultProtocol === 'https:';
        const globalAgent = new Agent({
          keepAlive: true, scheduling: 'lifo',
          protocol: defaultProtocol, defaultPort: isSecure ? 443 : 80,
        });

        // One entry point, two transports: plaintext over our own sockets, TLS over URLSession.
        function request(url, options, callback) {
          if (typeof url === 'string' || (typeof URL === 'function' && url instanceof URL)) {
            if (typeof options === 'function') { callback = options; options = {}; }
            const parsed = new URL(String(url));
            options = Object.assign({}, options, {
              protocol: options.protocol || parsed.protocol,
              hostname: options.hostname || parsed.hostname,
              port: options.port || (parsed.port || (parsed.protocol === 'https:' ? 443 : 80)),
              path: options.path || (parsed.pathname + (parsed.search || '')),
            });
            if (parsed.username) options.auth = parsed.username + ':' + parsed.password;
          } else {
            if (typeof options === 'function') { callback = options; }
            options = Object.assign({}, url);
          }
          const protocol = options.protocol || defaultProtocol;
          if (protocol === 'https:') {
            const authority = options.hostname || options.host || 'localhost';
            const port = options.port && Number(options.port) !== 443 ? ':' + options.port : '';
            const full = 'https://' + authority + port + (options.path || '/');
            return tlsRequest(full, options, callback);
          }
          return new ClientRequest(options, callback);
        }

        return {
          request: request,
          get: function(url, options, callback) {
            const clientRequest = request(url, options, callback);
            clientRequest.end();
            return clientRequest;
          },
          Agent: Agent,
          globalAgent: globalAgent,
          IncomingMessage: IncomingMessage,
          ServerResponse: ServerResponse,
          OutgoingMessage: OutgoingMessage,
          ClientRequest: ClientRequest,
          Server: Server,
          // https needs TLS, which this device gives us only inside URLSession — there is no
          // handshake we can put on a raw socket, so an https server says so instead of
          // serving plaintext under an https name.
          createServer: defaultProtocol === 'https:'
            ? function() { throw new Error('https servers are not available: TLS needs a handshake we cannot put on a raw socket (http.createServer is real)'); }
            : function(options, handler) { return new Server(options, handler); },
          maxHeaderSize: 16384,
          WebSocket: globalThis.WebSocket,
          CloseEvent: globalThis.CloseEvent,
          MessageEvent: globalThis.MessageEvent,
          setMaxIdleHTTPParsers: function(){},
          _connectionListener: function(socket) { serveConnection(this, socket); },
          STATUS_CODES: STATUS_CODES,
          METHODS: ['ACL', 'BIND', 'CHECKOUT', 'CONNECT', 'COPY', 'DELETE', 'GET', 'HEAD',
                    'LINK', 'LOCK', 'M-SEARCH', 'MERGE', 'MKACTIVITY', 'MKCALENDAR', 'MKCOL',
                    'MOVE', 'NOTIFY', 'OPTIONS', 'PATCH', 'POST', 'PROPFIND', 'PROPPATCH',
                    'PURGE', 'PUT', 'REBIND', 'REPORT', 'SEARCH', 'SOURCE', 'SUBSCRIBE',
                    'TRACE', 'UNBIND', 'UNLINK', 'UNLOCK', 'UNSUBSCRIBE'],
        };
      }
      coreFactories.http = function() { return makeHttpModule('http:'); };
      coreFactories.https = function() { return makeHttpModule('https:'); };
      // http2: libraries import it for the constants and gate actual use behind feature
      // checks — the constants are real, sessions say what's missing.
      coreFactories.http2 = function() {
        const net = coreRequire('net');
        const { EventEmitter } = coreRequire('events');
        const hpack = globalThis.__hpack;

        const TYPE = { DATA: 0, HEADERS: 1, PRIORITY: 2, RST_STREAM: 3, SETTINGS: 4,
                       PUSH_PROMISE: 5, PING: 6, GOAWAY: 7, WINDOW_UPDATE: 8, CONTINUATION: 9 };
        const FLAG = { END_STREAM: 0x1, ACK: 0x1, END_HEADERS: 0x4, PADDED: 0x8, PRIORITY: 0x20 };
        // The connection preface a client sends before anything else: bytes chosen to make an
        // HTTP/1.1 server fail immediately rather than misread what follows.
        const PREFACE = Buffer.from('PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n', 'latin1');

        function frame(type, flags, streamId, payload) {
          const body = payload || Buffer.alloc(0);
          const header = Buffer.alloc(9);
          header.writeUIntBE(body.length, 0, 3);
          header[3] = type;
          header[4] = flags;
          header.writeUInt32BE(streamId >>> 0, 5);
          return Buffer.concat([header, body]);
        }

        /// A session over one socket: the frame reader, the two HPACK tables, and the streams.
        function ServerSession(socket, server) {
          EventEmitter.call(this);
          this.socket = socket;
          this.server = server;
          this.decoder = new hpack.Decoder(4096);
          this.encoder = new hpack.Encoder(4096);
          this.streams = new Map();
          this.buffer = Buffer.alloc(0);
          this.sawPreface = false;
          // A header block can be split across CONTINUATION frames, and nothing else may come
          // between them — so the pieces are held until END_HEADERS says the block is whole.
          this.pendingHeaders = null;
          const self = this;
          socket.on('data', function(chunk) { self._receive(chunk); });
          socket.on('error', function(error) { self.emit('error', error); });
          socket.on('close', function() { self.emit('close'); });
          // Our own SETTINGS go out immediately; the client's arrive when they arrive.
          socket.write(frame(TYPE.SETTINGS, 0, 0, Buffer.alloc(0)));
        }
        ServerSession.prototype = Object.create(EventEmitter.prototype);
        ServerSession.prototype.constructor = ServerSession;

        ServerSession.prototype._receive = function(chunk) {
          this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
          if (!this.sawPreface) {
            if (this.buffer.length < PREFACE.length) return;
            if (!this.buffer.slice(0, PREFACE.length).equals(PREFACE)) {
              this.socket.destroy();
              return;
            }
            this.sawPreface = true;
            this.buffer = this.buffer.slice(PREFACE.length);
          }
          while (this.buffer.length >= 9) {
            const length = this.buffer.readUIntBE(0, 3);
            if (this.buffer.length < 9 + length) return;
            const type = this.buffer[3], flags = this.buffer[4];
            const streamId = this.buffer.readUInt32BE(5) & 0x7fffffff;
            const payload = this.buffer.slice(9, 9 + length);
            this.buffer = this.buffer.slice(9 + length);
            try { this._frame(type, flags, streamId, payload); }
            catch (error) { this.emit('error', error); this.socket.destroy(); return; }
          }
        };

        ServerSession.prototype._frame = function(type, flags, streamId, payload) {
          const self = this;
          if (type === TYPE.SETTINGS) {
            if (!(flags & FLAG.ACK)) this.socket.write(frame(TYPE.SETTINGS, FLAG.ACK, 0));
            return;
          }
          if (type === TYPE.PING) {
            if (!(flags & FLAG.ACK)) this.socket.write(frame(TYPE.PING, FLAG.ACK, 0, payload));
            return;
          }
          if (type === TYPE.WINDOW_UPDATE || type === TYPE.PRIORITY) return;
          if (type === TYPE.GOAWAY) { this.socket.end(); return; }
          if (type === TYPE.RST_STREAM) {
            const stream = this.streams.get(streamId);
            if (stream) { stream.emit('aborted'); this.streams.delete(streamId); }
            return;
          }
          if (type === TYPE.HEADERS || type === TYPE.CONTINUATION) {
            let block = payload;
            if (type === TYPE.HEADERS) {
              let offset = 0, end = payload.length;
              if (flags & FLAG.PADDED) { end -= payload[0]; offset = 1; }
              if (flags & FLAG.PRIORITY) offset += 5;
              block = payload.slice(offset, end);
              this.pendingHeaders = { streamId: streamId, pieces: [block],
                                      endStream: !!(flags & FLAG.END_STREAM) };
            } else if (this.pendingHeaders) {
              this.pendingHeaders.pieces.push(block);
            }
            if (!(flags & FLAG.END_HEADERS)) return;
            const pending = this.pendingHeaders;
            this.pendingHeaders = null;
            // ONE decoder per connection, fed every block in order: the dynamic table is a
            // shared history, so skipping or reordering a block corrupts everything after it.
            const list = this.decoder.decode(Buffer.concat(pending.pieces));
            const headers = {};
            for (const pair of list) {
              const name = pair[0];
              if (headers[name] === undefined) headers[name] = pair[1];
              else if (Array.isArray(headers[name])) headers[name].push(pair[1]);
              else headers[name] = [headers[name], pair[1]];
            }
            const stream = new ServerStream(this, pending.streamId);
            this.streams.set(pending.streamId, stream);
            if (pending.endStream) { stream._endReceived(); }
            this.emit('stream', stream, headers, flags);
            if (this.server) this.server.emit('stream', stream, headers, flags);
            return;
          }
          if (type === TYPE.DATA) {
            const stream = this.streams.get(streamId);
            let body = payload;
            if (flags & FLAG.PADDED) body = payload.slice(1, payload.length - payload[0]);
            if (stream && body.length) stream.emit('data', body);
            // The window is credited back immediately: this end does not buffer, so holding
            // the sender back would only stall a transfer nobody is waiting on.
            if (body.length) {
              const credit = Buffer.alloc(4);
              credit.writeUInt32BE(body.length);
              this.socket.write(frame(TYPE.WINDOW_UPDATE, 0, 0, credit));
              if (stream) this.socket.write(frame(TYPE.WINDOW_UPDATE, 0, streamId, credit));
            }
            if (stream && (flags & FLAG.END_STREAM)) stream._endReceived();
            return;
          }
        };

        ServerSession.prototype.close = function(callback) {
          const payload = Buffer.alloc(8);
          payload.writeUInt32BE(0, 0);
          payload.writeUInt32BE(0, 4);
          this.socket.write(frame(TYPE.GOAWAY, 0, 0, payload));
          this.socket.end();
          if (callback) callback();
        };

        function ServerStream(session, id) {
          EventEmitter.call(this);
          this.session = session;
          this.id = id;
          this.headersSent = false;
          this.closed = false;
        }
        ServerStream.prototype = Object.create(EventEmitter.prototype);
        ServerStream.prototype.constructor = ServerStream;
        ServerStream.prototype._endReceived = function() {
          const self = this;
          process.nextTick(function() { self.emit('end'); });
        };
        ServerStream.prototype.respond = function(headers, options) {
          const list = [];
          const status = (headers && headers[':status']) || 200;
          list.push([':status', String(status)]);
          for (const name of Object.keys(headers || {})) {
            if (name === ':status') continue;
            const value = headers[name];
            if (Array.isArray(value)) { for (const item of value) list.push([name.toLowerCase(), String(item)]); }
            else list.push([name.toLowerCase(), String(value)]);
          }
          const block = this.session.encoder.encode(list);
          const endStream = !!(options && options.endStream);
          this.session.socket.write(frame(TYPE.HEADERS, FLAG.END_HEADERS | (endStream ? FLAG.END_STREAM : 0),
                                          this.id, block));
          this.headersSent = true;
          if (endStream) this.closed = true;
        };
        ServerStream.prototype.write = function(chunk, encoding, callback) {
          if (typeof encoding === 'function') { callback = encoding; encoding = undefined; }
          if (!this.headersSent) this.respond({ ':status': 200 });
          const body = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk), encoding || 'utf8');
          // Frames are capped at the peer's max frame size; 16384 is the value every
          // implementation must accept, so a body is cut to it rather than negotiated up.
          for (let offset = 0; offset < body.length; offset += 16384) {
            this.session.socket.write(frame(TYPE.DATA, 0, this.id, body.slice(offset, offset + 16384)));
          }
          if (callback) process.nextTick(callback);
          return true;
        };
        ServerStream.prototype.end = function(chunk, encoding, callback) {
          if (typeof chunk === 'function') { callback = chunk; chunk = undefined; }
          if (typeof encoding === 'function') { callback = encoding; encoding = undefined; }
          if (!this.headersSent) this.respond({ ':status': 200 });
          if (chunk !== undefined && chunk !== null) this.write(chunk, encoding);
          this.session.socket.write(frame(TYPE.DATA, FLAG.END_STREAM, this.id, Buffer.alloc(0)));
          this.closed = true;
          const self = this;
          process.nextTick(function() { self.emit('close'); if (callback) callback(); });
          return this;
        };
        ServerStream.prototype.close = function() { this.closed = true; };

        /// The client half. The frame layer is the same; what differs is who opens streams
        /// (odd ids, from the client, counting up) and who waits for whom.
        function ClientSession(authority, options) {
          EventEmitter.call(this);
          const url = new URL(String(authority));
          this.decoder = new hpack.Decoder(4096);
          this.encoder = new hpack.Encoder(4096);
          this.streams = new Map();
          this.buffer = Buffer.alloc(0);
          this.nextId = 1;
          this.pings = [];
          this.authority = url.host;
          this.scheme = url.protocol === 'https:' ? 'https' : 'http';
          this.closed = false;
          const self = this;
          // The session owns its outbox rather than trusting write ordering: the preface must be
          // the FIRST bytes on the connection and SETTINGS the first frame, and a caller that
          // requests before the socket is up would otherwise put a HEADERS frame in front of
          // both — which a real peer answers with GOAWAY, as node's did.
          this._ready = false;
          this._outbox = [];
          this.socket = net.connect({ port: Number(url.port || 80), host: url.hostname }, function() {
            self.socket.write(PREFACE);
            self.socket.write(frame(TYPE.SETTINGS, 0, 0, Buffer.alloc(0)));
            self._ready = true;
            for (const pending of self._outbox) self.socket.write(pending);
            self._outbox = [];
            self.emit('connect', self);
          });
          this.socket.on('data', function(chunk) { self._receive(chunk); });
          this.socket.on('error', function(error) { self.emit('error', error); });
          this.socket.on('close', function() { self.closed = true; self.emit('close'); });
        }
        ClientSession.prototype = Object.create(EventEmitter.prototype);
        ClientSession.prototype.constructor = ClientSession;

        ClientSession.prototype._send = function(bytes) {
          if (this._ready) this.socket.write(bytes); else this._outbox.push(bytes);
        };
        ClientSession.prototype._receive = function(chunk) {
          this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
          while (this.buffer.length >= 9) {
            const length = this.buffer.readUIntBE(0, 3);
            if (this.buffer.length < 9 + length) return;
            const type = this.buffer[3], flags = this.buffer[4];
            const streamId = this.buffer.readUInt32BE(5) & 0x7fffffff;
            const payload = this.buffer.slice(9, 9 + length);
            this.buffer = this.buffer.slice(9 + length);
            try { this._frame(type, flags, streamId, payload); }
            catch (error) { this.emit('error', error); this.socket.destroy(); return; }
          }
        };

        ClientSession.prototype._frame = function(type, flags, streamId, payload) {
          if (type === TYPE.SETTINGS) {
            if (!(flags & FLAG.ACK)) this._send(frame(TYPE.SETTINGS, FLAG.ACK, 0));
            return;
          }
          if (type === TYPE.PING) {
            if (flags & FLAG.ACK) { const waiting = this.pings.shift(); if (waiting) waiting(null); }
            else this._send(frame(TYPE.PING, FLAG.ACK, 0, payload));
            return;
          }
          if (type === TYPE.WINDOW_UPDATE || type === TYPE.PRIORITY) return;
          if (type === TYPE.GOAWAY) { this.socket.end(); return; }
          if (type === TYPE.RST_STREAM) {
            const stream = this.streams.get(streamId);
            if (stream) { stream.emit('aborted'); this.streams.delete(streamId); }
            return;
          }
          if (type === TYPE.HEADERS || type === TYPE.CONTINUATION) {
            let block = payload;
            if (type === TYPE.HEADERS) {
              let offset = 0, end = payload.length;
              if (flags & FLAG.PADDED) { end -= payload[0]; offset = 1; }
              if (flags & FLAG.PRIORITY) offset += 5;
              block = payload.slice(offset, end);
              this.pendingHeaders = { streamId: streamId, pieces: [block],
                                      endStream: !!(flags & FLAG.END_STREAM) };
            } else if (this.pendingHeaders) {
              this.pendingHeaders.pieces.push(block);
            }
            if (!(flags & FLAG.END_HEADERS)) return;
            const pending = this.pendingHeaders;
            this.pendingHeaders = null;
            const list = this.decoder.decode(Buffer.concat(pending.pieces));
            const headers = {};
            for (const pair of list) {
              if (headers[pair[0]] === undefined) headers[pair[0]] = pair[1];
              else if (Array.isArray(headers[pair[0]])) headers[pair[0]].push(pair[1]);
              else headers[pair[0]] = [headers[pair[0]], pair[1]];
            }
            const stream = this.streams.get(pending.streamId);
            if (stream) {
              // A trailer block arrives AFTER the body: the first one is the response.
              if (stream._sawResponse) stream.emit('trailers', headers);
              else { stream._sawResponse = true; stream.emit('response', headers); }
              if (pending.endStream) { stream.push(null); this.streams.delete(pending.streamId); }
            }
            return;
          }
          if (type === TYPE.DATA) {
            const stream = this.streams.get(streamId);
            let body = payload;
            if (flags & FLAG.PADDED) body = payload.slice(1, payload.length - payload[0]);
            if (stream && body.length) stream.push(body);
            if (body.length) {
              const credit = Buffer.alloc(4);
              credit.writeUInt32BE(body.length);
              this._send(frame(TYPE.WINDOW_UPDATE, 0, 0, credit));
              if (stream) this._send(frame(TYPE.WINDOW_UPDATE, 0, streamId, credit));
            }
            if (stream && (flags & FLAG.END_STREAM)) { stream.push(null); this.streams.delete(streamId); }
            return;
          }
        };

        ClientSession.prototype.request = function(headers, options) {
          const { Readable } = coreRequire('stream');
          const id = this.nextId;
          this.nextId += 2;                                   // client streams are ODD
          const session = this;
          // A real Readable, so `setEncoding`, `for await` and `pipe` all work the way a caller
          // expects of node's ClientHttp2Stream.
          const stream = new Readable({ read: function(){} });
          stream.id = id;
          stream.session = session;
          stream._sawResponse = false;
          this.streams.set(id, stream);

          const list = [];
          const given = headers || {};
          list.push([':method', String(given[':method'] || 'GET')]);
          list.push([':path', String(given[':path'] || '/')]);
          list.push([':scheme', String(given[':scheme'] || session.scheme)]);
          list.push([':authority', String(given[':authority'] || session.authority)]);
          for (const name of Object.keys(given)) {
            if (name.charAt(0) === ':') continue;
            const value = given[name];
            if (Array.isArray(value)) { for (const item of value) list.push([name.toLowerCase(), String(item)]); }
            else list.push([name.toLowerCase(), String(value)]);
          }
          const block = session.encoder.encode(list);
          const endStream = !!(options && options.endStream);
          session._send(frame(TYPE.HEADERS, FLAG.END_HEADERS | (endStream ? FLAG.END_STREAM : 0), id, block));

          stream.write = function(chunk, encoding) {
            const body = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk), encoding || 'utf8');
            for (let offset = 0; offset < body.length; offset += 16384) {
              session._send(frame(TYPE.DATA, 0, id, body.slice(offset, offset + 16384)));
            }
            return true;
          };
          stream.end = function(chunk, encoding) {
            if (chunk !== undefined && chunk !== null && typeof chunk !== 'function') stream.write(chunk, encoding);
            session._send(frame(TYPE.DATA, FLAG.END_STREAM, id, Buffer.alloc(0)));
            return stream;
          };
          stream.close = function() { session.streams.delete(id); };
          return stream;
        };

        ClientSession.prototype.ping = function(payload, callback) {
          if (typeof payload === 'function') { callback = payload; payload = undefined; }
          const body = payload && payload.length === 8 ? payload : Buffer.alloc(8);
          this.pings.push(callback || function(){});
          this._send(frame(TYPE.PING, 0, 0, body));
          return true;
        };
        ClientSession.prototype.close = function(callback) {
          const payload = Buffer.alloc(8);
          this._send(frame(TYPE.GOAWAY, 0, 0, payload));
          this.socket.end();
          this.closed = true;
          if (callback) callback();
        };
        ClientSession.prototype.destroy = function() { this.socket.destroy(); this.closed = true; };

        function Http2Server(options, handler) {
          EventEmitter.call(this);
          const self = this;
          this.sessions = new Set();
          this._server = net.createServer(function(socket) {
            const session = new ServerSession(socket, self);
            self.sessions.add(session);
            session.on('close', function() { self.sessions.delete(session); });
            self.emit('session', session);
          });
          if (typeof handler === 'function') this.on('stream', handler);
        }
        Http2Server.prototype = Object.create(EventEmitter.prototype);
        Http2Server.prototype.constructor = Http2Server;
        Http2Server.prototype.listen = function() {
          this._server.listen.apply(this._server, arguments);
          return this;
        };
        Http2Server.prototype.address = function() { return this._server.address(); };
        Http2Server.prototype.close = function(callback) {
          for (const session of this.sessions) session.socket.destroy();
          this._server.close(callback);
          return this;
        };

        return {
          constants: {
            HTTP2_HEADER_METHOD: ':method', HTTP2_HEADER_PATH: ':path',
            HTTP2_HEADER_STATUS: ':status', HTTP2_HEADER_AUTHORITY: ':authority',
            HTTP2_HEADER_SCHEME: ':scheme', HTTP2_HEADER_CONTENT_TYPE: 'content-type',
            HTTP2_HEADER_CONTENT_LENGTH: 'content-length',
            NGHTTP2_CANCEL: 8, NGHTTP2_NO_ERROR: 0,
          },
          createServer: function(options, handler) {
            if (typeof options === 'function') { handler = options; options = {}; }
            return new Http2Server(options || {}, handler);
          },
          // TLS is the wall, not the protocol: h2 over TLS needs ALPN on a socket this device
          // will not give us. Cleartext h2c is real above.
          createSecureServer: function() {
            throw Object.assign(new Error('http2.createSecureServer is not available: h2 over TLS needs ALPN negotiation on a raw socket, which this platform does not expose. http2.createServer (cleartext h2c) is real'),
                                { code: 'ERR_METHOD_NOT_IMPLEMENTED' });
          },
          connect: function(authority, options, listener) {
            if (typeof options === 'function') { listener = options; options = {}; }
            const session = new ClientSession(authority, options || {});
            if (typeof listener === 'function') session.on('connect', listener);
            return session;
          },
        };
      };
      // The feature-detect tail: bundled CLIs import these and gate real use behind checks.
      // Each surface is import-safe and says the truth when actually exercised.
      // dns: real name resolution, because the socket layer's getaddrinfo is exactly what
      // `dns.lookup` is. Record types getaddrinfo cannot answer (MX, TXT, SRV, NS…) need a
      // resolver library talking to a DNS server directly, which this device does not give
      // us — those say so rather than pretending to be empty.
      coreFactories.dns = function() {
        function notFound(host, syscall) {
          return Object.assign(new Error((syscall || 'getaddrinfo') + ' ENOTFOUND ' + host),
                               { code: 'ENOTFOUND', errno: -3008, syscall: syscall || 'getaddrinfo', hostname: host });
        }
        function isIPv4(text) {
          const parts = String(text).split('.');
          return parts.length === 4 && parts.every(function(p){ return /^\d{1,3}$/.test(p) && Number(p) <= 255; });
        }
        function lookup(host, options, callback) {
          if (typeof options === 'function') { callback = options; options = {}; }
          if (typeof options === 'number') options = { family: options };
          options = options || {};
          const family = Number(options.family) || 0;
          // An IP literal is not a query — node answers it without touching a resolver.
          if (isIPv4(host) || String(host).indexOf(':') >= 0) {
            const literal = { address: String(host), family: isIPv4(host) ? 4 : 6 };
            setImmediate(function(){
              if (options.all) callback(null, [literal]);
              else callback(null, literal.address, literal.family);
            });
            return;
          }
          bridge.netResolve(String(host), family, function(found, code) {
            if (code || !found.length) { callback(notFound(host)); return; }
            if (options.all) { callback(null, found); return; }
            callback(null, found[0].address, found[0].family);
          });
        }
        function resolveFamily(host, family, callback) {
          bridge.netResolve(String(host), family, function(found, code) {
            if (code || !found.length) { callback(notFound(host, 'queryA')); return; }
            callback(null, found.map(function(entry){ return entry.address; }));
          });
        }
        // Real record lookups now. `dns.lookup` is getaddrinfo; these ask a DNS SERVER through
        // the system resolver, which is the thing that used to be missing. Each type reshapes the
        // parsed record into node's exact return value, and those shapes differ per type more
        // than the docs suggest — TXT keeps its chunks SEPARATE, SOA is one object rather than an
        // array, and CAA names its property after the tag.
        function queryError(host, type, code) {
          return Object.assign(new Error('query' + type + ' ' + code + ' ' + host),
                               { code: code, syscall: 'query' + type, hostname: host });
        }
        function resolver(type, shape) {
          return function(host, callback) {
            const done = typeof callback === 'function' ? callback : arguments[arguments.length - 1];
            bridge.dnsResolve(String(host), type, function(records, code) {
              bridge.dnsDone();
              if (code) { done(queryError(host, type, code)); return; }
              done(null, shape(records));
            });
          };
        }
        const plainValues = function(records){ return records.map(function(r){ return r.value; }); };
        function promisify(fn, arity) {
          return function() {
            const args = Array.prototype.slice.call(arguments);
            return new Promise(function(resolve, reject) {
              fn.apply(null, args.concat([function(error, a, b) {
                if (error) { reject(error); return; }
                resolve(arity === 2 && b !== undefined ? { address: a, family: b } : a);
              }]));
            });
          };
        }
        const dns = {
          lookup: lookup,
          resolve4: function(host, options, callback) {
            if (typeof options === 'function') { callback = options; }
            resolveFamily(host, 4, callback);
          },
          resolve6: function(host, options, callback) {
            if (typeof options === 'function') { callback = options; }
            resolveFamily(host, 6, callback);
          },
          resolve: function(host, type, callback) {
            if (typeof type === 'function') { callback = type; type = 'A'; }
            const kind = String(type).toUpperCase();
            // `resolve` returns the same shape the type's own resolver would.
            const byType = { A: 'resolve4', AAAA: 'resolve6', MX: 'resolveMx', TXT: 'resolveTxt',
                             NS: 'resolveNs', CNAME: 'resolveCname', PTR: 'resolvePtr',
                             SOA: 'resolveSoa', SRV: 'resolveSrv', NAPTR: 'resolveNaptr',
                             CAA: 'resolveCaa', TLSA: 'resolveTlsa' };
            const method = byType[kind];
            if (!method) {
              const error = Object.assign(
                new Error("dns.resolve: unsupported record type '" + kind + "': A, AAAA, CNAME, " +
                          'MX, NAPTR, NS, PTR, SOA, SRV, TLSA, TXT and CAA are available'),
                { code: 'ENOTIMP', syscall: 'query' + kind, hostname: host });
              setImmediate(function(){ callback(error); });
              return;
            }
            return dns[method](host, callback);
          },
          // Each shape is node's, and they are less uniform than they look.
          resolveMx: resolver('Mx', function(records) {
            return records.map(function(r){ return { exchange: r.exchange, priority: r.priority }; });
          }),
          // TXT chunks stay separate: a record split across strings is an ARRAY in node, not a
          // joined string, and DKIM/SPF records rely on that.
          resolveTxt: resolver('Txt', function(records) {
            return records.map(function(r){ return r.chunks; });
          }),
          resolveNs: resolver('Ns', plainValues),
          resolveCname: resolver('Cname', plainValues),
          resolvePtr: resolver('Ptr', plainValues),
          // SOA is a single object, not an array — the one resolver that is not a list.
          resolveSoa: resolver('Soa', function(records) {
            const r = records[0] || {};
            return { nsname: r.nsname, hostmaster: r.hostmaster, serial: r.serial,
                     refresh: r.refresh, retry: r.retry, expire: r.expire, minttl: r.minttl };
          }),
          resolveSrv: resolver('Srv', function(records) {
            return records.map(function(r) {
              return { name: r.name, port: r.port, priority: r.priority, weight: r.weight };
            });
          }),
          resolveNaptr: resolver('Naptr', function(records) {
            return records.map(function(r) {
              return { flags: r.flags, service: r.service, regexp: r.regexp,
                       replacement: r.replacement, order: r.order, preference: r.preference };
            });
          }),
          // CAA names its property after the TAG, so an `issue` record becomes {critical, issue}.
          resolveCaa: resolver('Caa', function(records) {
            return records.map(function(r) {
              const entry = { critical: r.critical };
              entry[r.tag] = r.value;
              return entry;
            });
          }),
          resolveAny: function(host, callback) {
            // node asks for ANY; most resolvers refuse to answer it, so this asks for the types
            // it can and merges — which is what the result is FOR.
            const types = [['A', 'resolve4'], ['AAAA', 'resolve6'], ['MX', 'resolveMx'],
                           ['TXT', 'resolveTxt'], ['NS', 'resolveNs'], ['SOA', 'resolveSoa']];
            const found = [];
            let left = types.length;
            types.forEach(function(pair) {
              dns[pair[1]](host, function(error, result) {
                if (!error && result) {
                  if (pair[0] === 'A' || pair[0] === 'AAAA') {
                    result.forEach(function(address){ found.push({ type: pair[0], address: address }); });
                  } else if (pair[0] === 'MX') {
                    result.forEach(function(r){ found.push(Object.assign({ type: 'MX' }, r)); });
                  } else if (pair[0] === 'TXT') {
                    result.forEach(function(chunks){ found.push({ type: 'TXT', entries: chunks }); });
                  } else if (pair[0] === 'NS') {
                    result.forEach(function(v){ found.push({ type: 'NS', value: v }); });
                  } else if (pair[0] === 'SOA' && result.nsname) {
                    found.push(Object.assign({ type: 'SOA' }, result));
                  }
                }
                if (--left === 0) callback(null, found);
              });
            });
          },
          // The refusal here said TLSA needs a TLS stack. That is true of USING the record — a
          // DANE check compares this hash against the certificate a handshake presented — and
          // says nothing about RESOLVING it. On the wire it is three bytes and a blob, no
          // harder than CAA. A constraint attached to the wrong half of the job.
          resolveTlsa: resolver('Tlsa', function(records) {
            return records.map(function(r) {
              return { certUsage: r.certUsage, selector: r.selector, match: r.match,
                       // node hands back the association data as an ArrayBuffer.
                       data: Uint8Array.from(r.data || []).buffer };
            });
          }),
          reverse: function(address, callback) {
            bridge.dnsReverse(String(address), function(names, code) {
              bridge.dnsDone();
              if (code) { callback(queryError(address, 'Reverse', code)); return; }
              callback(null, names);
            });
          },
          lookupService: function(address, port, callback) {
            bridge.dnsService(String(address), Number(port), function(host, service, code) {
              bridge.dnsDone();
              if (code) { callback(queryError(address, 'Service', code)); return; }
              callback(null, host, service);
            });
          },
          getServers: function() { return []; },
          setServers: function() {},
          setDefaultResultOrder: function() {},
          getDefaultResultOrder: function() { return 'verbatim'; },
          ADDRCONFIG: 1024, V4MAPPED: 2048, ALL: 4096,
          // node exposes c-ares' error names as string constants; code compares
          // `error.code === dns.NOTFOUND` rather than typing the literal.
          NOTFOUND: 'ENOTFOUND', NODATA: 'ENODATA', BADFAMILY: 'EBADFAMILY',
          FORMERR: 'EFORMERR', SERVFAIL: 'ESERVFAIL', NOTIMP: 'ENOTIMP',
          REFUSED: 'EREFUSED', BADQUERY: 'EBADQUERY', BADNAME: 'EBADNAME',
          BADRESP: 'EBADRESP', CONNREFUSED: 'ECONNREFUSED', TIMEOUT: 'ETIMEOUT',
          EOF: 'EOF', FILE: 'EFILE', NOMEM: 'ENOMEM', DESTRUCTION: 'EDESTRUCTION',
          BADSTR: 'EBADSTR', BADFLAGS: 'EBADFLAGS', NONAME: 'ENONAME',
          BADHINTS: 'EBADHINTS', NOTINITIALIZED: 'ENOTINITIALIZED',
          LOADIPHLPAPI: 'ELOADIPHLPAPI', ADDRGETNETWORKPARAMS: 'EADDRGETNETWORKPARAMS',
          CANCELLED: 'ECANCELLED',
        };
        dns.promises = {
          lookup: promisify(lookup, 2),
          resolve4: promisify(dns.resolve4, 1),
          resolve6: promisify(dns.resolve6, 1),
          resolve: promisify(dns.resolve, 1),
          getServers: function() { return Promise.resolve([]); },
        };
        for (const name of ['resolveMx', 'resolveTxt', 'resolveSrv', 'resolveNs', 'resolveCname',
                            'resolvePtr', 'resolveSoa', 'resolveNaptr', 'reverse',
                            'resolveAny', 'resolveCaa', 'resolveTlsa', 'lookupService']) {
          dns.promises[name] = promisify(dns[name], 1);
        }
        // node's Resolver class, for libraries that construct their own.
        dns.Resolver = function Resolver() {};
        dns.Resolver.prototype = Object.create(Object.prototype);
        for (const name of Object.keys(dns)) {
          if (typeof dns[name] === 'function') dns.Resolver.prototype[name] = dns[name];
        }
        return dns;
      };
      // worker_threads, on the same machinery as a forked child: a second engine on its own
      // queue, talking over the message channel. What separate JSContexts cannot share is
      // MEMORY, so SharedArrayBuffer-based APIs refuse by name rather than pretending — an
      // Atomics-based pool would otherwise deadlock instead of failing.
      coreFactories.worker_threads = function() {
        const EventEmitter = coreRequire('events');
        let nextThreadId = 1;

        // environmentData: a snapshot the parent hands down at SPAWN time, which is node's rule —
        // a key set after a worker starts is invisible to it (verified). Refused here as needing
        // "memory both engines can see", which was the fourth wrong refusal of the same shape:
        // inherited-at-spawn data travels perfectly well as JSON, exactly like workerData.
        // Pairs rather than an object so a non-string key behaves as node's does.
        const environmentData = [];
        function envSlot(key) {
            const wanted = globalThis.__cloneEncode(key === undefined ? null : key);
            for (const pair of environmentData) if (pair.k === wanted) return pair;
            return null;
        }

        // Who the hub can reach. Kept here rather than derived from the child table because a
        // worker that has exited must stop receiving broadcasts.
        const liveWorkers = [];

        function Worker(script, options) {
          EventEmitter.call(this);
          options = options || {};
          const self = this;
          this.threadId = nextThreadId++;
          const child_process = coreRequire('child_process');
          // eval: true is node's "the string IS the program" form, same as `node -e`.
          const argv = options.eval ? ['-e', String(script)] : [String(script)];
          this._child = child_process.spawn('node', argv, {
            ipc: true, worker: true,
            // One envelope for everything inherited at spawn: the worker's data and the
            // environmentData snapshot as it stands NOW.
            workerData: globalThis.__cloneEncode({
              d: options.workerData === undefined ? null : options.workerData,
              e: environmentData,
            }),
            cwd: options.cwd,
          });
          this._child.on('message', function(message) {
            if (message && typeof message === 'object' && message[WIRE]) {
              broadcastIn(message[WIRE], self);
              return;
            }
            if (message && typeof message === 'object' && message.__mouseWorkerError) {
              const detail = message.__mouseWorkerError;
              const error = new Error(detail.message);
              error.name = detail.name || 'Error';
              if (detail.stack) error.stack = detail.stack;
              if (detail.code !== undefined) error.code = detail.code;
              self.emit('error', error);
              return;
            }
            self.emit('message', message);
          });
          liveWorkers.push(this);
          this._child.on('exit', function(code) {
            const at = liveWorkers.indexOf(self);
            if (at >= 0) liveWorkers.splice(at, 1);
            self.emit('exit', code);
          });
          this._child.on('error', function(error){ self.emit('error', error); });
          this.stdout = this._child.stdout;
          this.stderr = this._child.stderr;
          this.stdin = this._child.stdin;
        }
        Worker.prototype = Object.create(EventEmitter.prototype);
        Worker.prototype.constructor = Worker;
        Worker.prototype.postMessage = function(message) { this._child.send(message); };
        Worker.prototype.terminate = function() {
          this._child.kill();
          return Promise.resolve(0);
        };
        Worker.prototype.ref = function(){ this._child.ref(); return this; };
        Worker.prototype.unref = function(){ this._child.unref(); return this; };
        Worker.prototype.getHeapSnapshot = function() {
          return Promise.reject(refuseWorker('getHeapSnapshot', 'heap snapshots need a V8 API JSC does not expose'));
        };

        // A port pair WITHIN one engine — no threads involved, so this is exact.
        function MessagePort() {
          EventEmitter.call(this);
          // node's MessagePort has NO own enumerable properties — its whole surface is on the
          // prototype — and real code SPREADS an object carrying one: tinypool relays every
          // worker message as `{ ...message, source: 'port' }`. With our internals enumerable
          // that spread dragged in the peer pointer, and a message that points back at its own
          // port is cyclic, which no serializer can carry. So they are hidden, and the ones
          // assigned later are declared here to keep the descriptor when they are.
          for (const key of Object.keys(this)) {
            Object.defineProperty(this, key, { value: this[key], writable: true, enumerable: false, configurable: true });
          }
          for (const key of ['_peer', '_started', '_refed', '_queue', '_scheduled', '_onmessage',
                             '_closed', 'onmessageerror']) {
            if (!Object.getOwnPropertyDescriptor(this, key)) {
              Object.defineProperty(this, key, { value: undefined, writable: true, enumerable: false, configurable: true });
            }
          }
          this._peer = null;
          this._started = false;
          this._refed = false;   // node reports hasRef() false until the port is started
          this.onmessageerror = null;
        }
        MessagePort.prototype = Object.create(EventEmitter.prototype);
        MessagePort.prototype.constructor = MessagePort;
        MessagePort.prototype.postMessage = function(message) {
          const peer = this._peer;
          if (!peer) return;
          // Structured clone, as far as JSON reaches: the same limit the child channel has.
          const copy = message === undefined ? undefined : globalThis.__clone(message);
          // Queue rather than dispatch: a port with nobody listening HOLDS its messages in node,
          // which is what makes receiveMessageOnPort able to drain them synchronously later.
          peer._queue = peer._queue || [];
          peer._queue.push(copy);
          peer._schedule();
        };
        /// One delivery per port per loop turn, in the PORT PHASE. Not nextTick and not a
        /// microtask: node runs port deliveries after both, which is observable — a nextTick
        /// queued after a postMessage still runs first.
        MessagePort.prototype._schedule = function() {
          if (this._scheduled) return;
          this._scheduled = true;
          const self = this;
          bridge.portDeliver(function(){ self._scheduled = false; self._drain(); });
        };
        /// Is anyone listening, on EITHER surface? If not the messages stay queued, which is
        /// what receiveMessageOnPort drains.
        MessagePort.prototype._listening = function() {
          return this._started || this.listenerCount('message') > 0 ||
                 typeof this._onmessage === 'function' ||
                 (this._webListeners && this._webListeners.length > 0);
        };
        MessagePort.prototype._drain = function() {
          if (!this._queue || !this._queue.length) return;
          if (!this._listening()) return;
          const pending = this._queue;
          this._queue = [];
          for (const value of pending) {
            // All three surfaces fire for one message, which is what node does: EventEmitter
            // listeners get the raw value, web-style listeners get an event carrying `.data`.
            this.emit('message', value);
            if (typeof this._onmessage === 'function' || (this._webListeners && this._webListeners.length)) {
              const event = { data: value, type: 'message', target: this };
              if (typeof this._onmessage === 'function') this._onmessage(event);
              for (const listener of (this._webListeners || []).slice()) {
                if (listener.type === 'message') listener.fn.call(this, event);
              }
            }
          }
        };
        // Adding a listener is what starts a port in node; anything already queued arrives then.
        const portOn = MessagePort.prototype.on;
        MessagePort.prototype.on = MessagePort.prototype.addListener = function(type, listener) {
          const result = portOn.call(this, type, listener);
          if (type === 'message') this._schedule();
          return result;
        };
        // The web surface, so ONE class can be both the worker_threads MessagePort and the
        // global one — which is what node has (they are `===` identical).
        MessagePort.prototype.addEventListener = function(type, fn) {
          this._webListeners = this._webListeners || [];
          this._webListeners.push({ type: String(type), fn: fn });
          if (String(type) === 'message') this._schedule();
        };
        MessagePort.prototype.removeEventListener = function(type, fn) {
          if (!this._webListeners) return;
          const at = this._webListeners.findIndex(function(l){ return l.type === String(type) && l.fn === fn; });
          if (at >= 0) this._webListeners.splice(at, 1);
        };
        MessagePort.prototype.dispatchEvent = function(event) {
          if (!event) return false;
          if (typeof this['_on' + event.type] === 'function') this['_on' + event.type](event);
          for (const listener of (this._webListeners || []).slice()) {
            if (listener.type === event.type) listener.fn.call(this, event);
          }
          this.emit(event.type, event);
          return true;
        };
        // Assigning onmessage starts the port in node, so it has to be an accessor.
        Object.defineProperty(MessagePort.prototype, 'onmessage', {
          configurable: true,
          get: function(){ return this._onmessage || null; },
          set: function(fn) { this._onmessage = fn; if (typeof fn === 'function') this._schedule(); },
        });
        MessagePort.prototype.start = function(){ this._started = true; this._schedule(); };
        MessagePort.prototype.close = function(){ this.emit('close'); if (this._peer) this._peer.emit('close'); };
        MessagePort.prototype.ref = function(){ return this; };
        MessagePort.prototype.unref = function(){ this._refed = false; return this; };
        // node reports whether the port is currently holding the loop open, and exposes the
        // error-event handler slot alongside onmessage.
        MessagePort.prototype.hasRef = function(){ return !!this._refed; };
        function MessageChannel() {
          this.port1 = new MessagePort();
          this.port2 = new MessagePort();
          this.port1._peer = this.port2;
          this.port2._peer = this.port1;
        }

        function refuseWorker(name, reason) {
          const error = new Error('worker_threads.' + name + ' is not available: ' + reason);
          error.code = 'ERR_METHOD_NOT_IMPLEMENTED';
          return error;
        }

        // ---- BroadcastChannel: a registry and a fan-out, not shared memory ----------------
        // The refusal here said "it needs a shared registry across threads", which reads like a
        // shared-memory claim and is not one. BroadcastChannel is message passing: post to a
        // name, every OTHER channel object with that name hears it. The registry only has to be
        // reachable, not shared — and the main engine already talks to every worker over a JSON
        // channel, so it can BE the hub. Same mistake shape as cluster's second refusal:
        // borrowing real node's implementation constraint without checking that it applies.
        const WIRE = '__mouseBroadcast';
        const localChannels = {};        // name -> live channel objects in THIS engine

        function deliverLocally(name, data, except) {
            const list = localChannels[name];
            if (!list) return;
            // A copy per listener, and taken before delivery: a handler that closes a channel
            // must not change who else hears this message.
            for (const channel of list.slice()) {
                if (channel === except || channel._closed) continue;
                const event = { data: data, type: 'message', target: channel };
                process.nextTick(function() {
                    if (channel._closed) return;
                    if (typeof channel.onmessage === 'function') channel.onmessage(event);
                    channel.emit('message', event);
                });
            }
        }

        // Every engine sends what it originates to the hub, which is the only party that can
        // reach the others. In the main engine `broadcastOut` fans out directly; in a worker it
        // goes up the parent channel and the main engine fans it out from there.
        function broadcastOut(name, data, origin) {
            if (__isWorker) {
                if (process.send) process.send({ [WIRE]: { name: name, data: data } });
                return;
            }
            for (const worker of liveWorkers) {
                if (worker === origin) continue;
                try { worker._child.send({ [WIRE]: { name: name, data: data } }); } catch (error) { /* gone */ }
            }
        }

        function BroadcastChannel(name) {
            EventEmitter.call(this);
            this.name = String(name);
            this.onmessage = null;
            this.onmessageerror = null;
            this._closed = false;
            // An open channel keeps the process alive in node — verified: a script that only
            // constructs one never exits. Without the hold, a program waiting for a broadcast
            // would exit before it arrived.
            this._holding = true;
            bridge.loopHold(true);
            (localChannels[this.name] = localChannels[this.name] || []).push(this);
        }
        BroadcastChannel.prototype = Object.create(EventEmitter.prototype);
        BroadcastChannel.prototype.constructor = BroadcastChannel;
        BroadcastChannel.prototype.postMessage = function(message) {
            if (this._closed) {
                throw Object.assign(new Error('BroadcastChannel is closed'), { name: 'InvalidStateError' });
            }
            const data = message === undefined ? undefined : globalThis.__clone(message);
            deliverLocally(this.name, data, this);   // never the sender itself, as node does
            broadcastOut(this.name, data, null);
        };
        BroadcastChannel.prototype.close = function() {
            if (this._closed) return;
            this._closed = true;
            const list = localChannels[this.name] || [];
            const at = list.indexOf(this);
            if (at >= 0) list.splice(at, 1);
            if (!list.length) delete localChannels[this.name];
            if (this._holding) { this._holding = false; bridge.loopHold(false); }
        };
        BroadcastChannel.prototype.ref = function() {
            if (!this._closed && !this._holding) { this._holding = true; bridge.loopHold(true); }
            return this;
        };
        BroadcastChannel.prototype.unref = function() {
            if (this._holding) { this._holding = false; bridge.loopHold(false); }
            return this;
        };

        /// A broadcast arriving from elsewhere: deliver to every local channel of that name (no
        /// sender to exclude — it is in another engine), and, in the hub, relay to the others.
        function broadcastIn(body, origin) {
            if (!body || typeof body.name !== 'string') return false;
            deliverLocally(body.name, body.data, null);
            if (!__isWorker) broadcastOut(body.name, body.data, origin);
            return true;
        }
        globalThis.__broadcastIn = broadcastIn;

        // The worker's own end of the channel, which exists only inside a worker.
        let parentPort = null;
        if (__isWorker) {
          parentPort = new EventEmitter();
          parentPort.postMessage = function(message) {
            if (process.send) process.send(message);
          };
          parentPort.start = function(){};
          parentPort.close = function(){ if (process.disconnect) process.disconnect(); };
          parentPort.ref = function(){ return parentPort; };
          parentPort.unref = function(){ return parentPort; };
          process.on('message', function(message) {
            // Reserved envelope: a broadcast is not a message to this worker's port.
            if (message && typeof message === 'object' && message[WIRE]) {
              broadcastIn(message[WIRE], null);
              return;
            }
            parentPort.emit('message', message);
          });
        }
        let parsedWorkerData = null;
        if (__isWorker && __workerData) {
          try {
            const envelope = globalThis.__cloneDecode(__workerData);
            parsedWorkerData = envelope && 'd' in envelope ? envelope.d : null;
            if (envelope && Array.isArray(envelope.e)) {
              for (const pair of envelope.e) environmentData.push(pair);
            }
          } catch (error) { parsedWorkerData = null; }
        }

        return {
          isMainThread: !__isWorker,
          threadId: __isWorker ? 1 : 0,
          parentPort: parentPort,
          workerData: parsedWorkerData,
          Worker: Worker,
          MessageChannel: MessageChannel,
          MessagePort: MessagePort,
          BroadcastChannel: BroadcastChannel,
          // Everything below needs SHARED MEMORY between contexts, which two JSContexts do not
          // have. Refusing by name beats an Atomics wait that never wakes.
          // receiveMessageOnPort was in that list by association and did not belong: it does not
          // WAIT for anything. It pops a message a port has already queued, and returns
          // undefined when there is none — a local queue, not shared memory.
          receiveMessageOnPort: function(port) {
            if (!port || typeof port._drain !== 'function') {
              throw Object.assign(new TypeError('The "port" argument must be a MessagePort instance'),
                                  { code: 'ERR_INVALID_ARG_TYPE' });
            }
            if (!port._queue || !port._queue.length) return undefined;
            return { message: port._queue.shift() };
          },
          // The refusal here read "contexts are separate engines with no shared memory", which
          // was true when a vm context WAS another engine. It is not any more: a context is a
          // second JSContext in this engine's virtual machine, so values cross freely and a
          // port can simply be given a face inside it. The reason expired when vm contexts
          // became real; nothing about this was ever impossible.
          moveMessagePortToContext: function(port, context) {
            if (!port || typeof port.postMessage !== 'function') {
              const error = new TypeError('The "port" argument must be a MessagePort instance');
              error.code = 'ERR_INVALID_ARG_TYPE';
              throw error;
            }
            // Hand the real port to the context, then build its counterpart there. node returns
            // the WEB-shaped port — postMessage and onmessage, no EventEmitter surface.
            context.__mouseMovedPort = port;
            const moved = globalThis.__vmRunIn(context, `(function(){
              const source = __mouseMovedPort;
              // A web-shaped port stays CLOSED until started: assigning onmessage is not
              // enough, and messages that arrive first wait rather than being dropped. Node
              // behaves this way and a plausible guess (deliver as soon as a handler exists)
              // does not — measured, not assumed.
              let started = false;
              const waiting = [];
              const port = {
                onmessage: null,
                onmessageerror: null,
                postMessage: function(message) { source.postMessage(message); },
                close: function() { source.close(); },
                start: function() {
                  started = true;
                  while (waiting.length) {
                    const message = waiting.shift();
                    if (typeof port.onmessage === 'function') port.onmessage({ data: message });
                  }
                },
                ref: function() {}, unref: function() {},
                hasRef: function() { return false; },
              };
              source.on('message', function(message) {
                if (!started) { waiting.push(message); return; }
                if (typeof port.onmessage === 'function') port.onmessage({ data: message });
              });
              return port;
            })()`);
            delete context.__mouseMovedPort;
            return moved;
          },
          markAsUntransferable: function(){},
          isMarkedAsUntransferable: function(){ return false; },
          setEnvironmentData: function(key, value) {
            const slot = envSlot(key);
            // node DELETES the entry when the value is omitted.
            if (value === undefined) {
              if (slot) environmentData.splice(environmentData.indexOf(slot), 1);
              return;
            }
            const copy = globalThis.__clone(value);
            if (slot) slot.v = copy;
            else environmentData.push({ k: globalThis.__cloneEncode(key === undefined ? null : key), v: copy });
          },
          getEnvironmentData: function(key) {
            const slot = envSlot(key);
            return slot ? slot.v : undefined;
          },
          SHARE_ENV: Symbol('nodejs.worker_threads.SHARE_ENV'),
          resourceLimits: {},
        };
      };
      coreFactories.async_hooks = function() {
        // Synchronous continuation-local storage: real for sync flows, does not survive
        // suspension across awaits — the honest subset a single-threaded loop can give.
        class AsyncLocalStorage {
          constructor() { this._store = undefined; }
          run(store, fn, ...args) {
            const previous = this._store;
            this._store = store;
            let result;
            try { result = fn(...args); }
            catch (e) { this._store = previous; throw e; }
            // An async body keeps its store until it settles — inquirer's hook context lives
            // across awaits. Correct for non-interleaved flows (one prompt at a time);
            // interleaved async contexts would still share, the single-thread honest limit.
            if (result && typeof result.then === 'function') {
              const self = this;
              return result.then(
                function(value){ self._store = previous; return value; },
                function(error){ self._store = previous; throw error; });
            }
            this._store = previous;
            return result;
          }
          getStore() { return this._store; }
          enterWith(store) { this._store = store; }
          disable() { this._store = undefined; }
          exit(fn, ...args) { return this.run(undefined, fn, ...args); }
        }
        return {
          AsyncLocalStorage: AsyncLocalStorage,
          AsyncResource: class AsyncResource {
            constructor() {}
            runInAsyncScope(fn, thisArg, ...args) { return fn.apply(thisArg, args); }
            emitDestroy() { return this; }
            static bind(fn) { return fn; }
          },
          createHook: function() { return { enable: function(){ return this; }, disable: function(){ return this; } }; },
          executionAsyncId: function() { return 1; },
          triggerAsyncId: function() { return 0; },
        };
      };
      coreFactories.v8 = function() {
        // `serialize` was `JSON.stringify`, which is the same defect that was swept out of
        // deepStrictEqual and isDeepStrictEqual: JSON cannot carry a Map, a Set, a Date, a
        // typed array, undefined, a BigInt or a cycle. It does not FAIL on them either — a Map
        // stringifies to `{}` — so the round trip silently returns a structurally valid,
        // empty-where-it-matters object. jest's haste map is mostly Maps and Sets, and reading
        // that cache back is what made jest hang: it believed it had a warm cache and had not.
        //
        // This is a structured clone, not V8's wire format, so a cache written by real node is
        // not readable here and vice versa. That is fine for the purpose — a process serializes
        // for ITSELF — and honest about what it is.
        return {
          getHeapStatistics: function() { return { total_heap_size: 0, used_heap_size: 0, heap_size_limit: 0 }; },
          serialize: function(value) { return Buffer.from(globalThis.__cloneEncode(value), 'utf8'); },
          deserialize: function(buffer) { return globalThis.__cloneDecode(buffer); },
          Serializer: class Serializer {
            constructor() { this._value = undefined; }
            writeValue(value) { this._value = value; }
            releaseBuffer() { return Buffer.from(globalThis.__cloneEncode(this._value), 'utf8'); }
          },
          Deserializer: class Deserializer {
            constructor(buffer) { this._buffer = buffer; }
            readValue() { return globalThis.__cloneDecode(this._buffer); }
          },
        };
      };
      coreFactories.vm = function() {
        // A contextified sandbox is a SECOND JSContext in the engine's virtual machine: its own
        // global, its own built-ins, none of this engine's globals visible inside, and values
        // crossing freely because the two contexts share a VM. The sandbox's keys are live
        // accessors on the guest global, so a read sees the current value and a write lands on
        // the object — node's semantics, not a copy at the boundary.
        //
        // This module used to be half real and half a lie: `createContext` handed back the
        // sandbox unchanged so a feature check passed, and `runInContext` was simply absent.
        const handles = new WeakMap();
        function handleFor(contextObject, name) {
          const handle = handles.get(contextObject);
          if (handle === undefined) {
            const error = new TypeError('The "contextifiedObject" argument must be a vm.Context');
            error.code = 'ERR_INVALID_ARG_TYPE';
            throw error;
          }
          return handle;
        }
        function run(handle, code, options) {
          const filename = (options && (options.filename || options.name)) || 'evalmachine.<anonymous>';
          const result = bridge.vmRun(handle, String(code), String(filename));
          // A throw inside the guest crosses as a marker; rethrowing here puts it in the
          // caller's frame, where a try/catch around runInContext expects it.
          if (result && typeof result === 'object' && result.__vmThrow !== undefined) {
            throw result.__vmThrow;
          }
          return result;
        }
        // worker_threads needs to build an object INSIDE a context (moveMessagePortToContext),
        // and the two live in separate factories.
        globalThis.__vmRunIn = function(contextObject, code) {
          const handle = handles.get(contextObject);
          if (handle === undefined) {
            const error = new TypeError('The "contextifiedObject" argument must be a vm.Context');
            error.code = 'ERR_INVALID_ARG_TYPE';
            throw error;
          }
          return run(handle, code, { filename: 'moveMessagePortToContext' });
        };
        function createContext(sandbox) {
          const target = sandbox === undefined || sandbox === null ? {} : sandbox;
          if (handles.has(target)) return target;
          const handle = bridge.vmCreate(target);
          if (!handle) throw new Error('vm: could not create a context');
          handles.set(target, handle);
          return target;
        }
        class Script {
          constructor(code, options) {
            this._code = String(code);
            this._options = options || {};
          }
          runInThisContext() { return (0, eval)(this._code); }
          runInContext(contextObject, options) {
            return run(handleFor(contextObject), this._code, options || this._options);
          }
          runInNewContext(sandbox, options) {
            const context = createContext(sandbox);
            return run(handles.get(context), this._code, options || this._options);
          }
        }
        return {
          createContext: createContext,
          isContext: function(value) { return handles.has(value); },
          runInThisContext: function(code) { return (0, eval)(String(code)); },
          runInContext: function(code, contextObject, options) {
            return run(handleFor(contextObject), code, options);
          },
          runInNewContext: function(code, sandbox, options) {
            const context = createContext(sandbox);
            return run(handles.get(context), code, options);
          },
          compileFunction: function(code, params, options) {
            // node compiles the body into a function, optionally inside a parsing context.
            const names = (params || []).map(String).join(', ');
            const source = '(function anonymous(' + names + '\n) {\n' + String(code) + '\n})';
            if (options && options.parsingContext) {
              return run(handleFor(options.parsingContext), source, options);
            }
            return (0, eval)(source);
          },
          measureMemory: function() {
            return Promise.resolve({ total: { jsMemoryEstimate: 0, jsMemoryRange: [0, 0] } });
          },
          Script: Script,
          constants: { USE_MAIN_CONTEXT_DEFAULT_LOADER: 0 },
        };
      };
      coreFactories.perf_hooks = function() {
        return {
          performance: globalThis.performance,
          monitorEventLoopDelay: function() { return { enable: function(){}, disable: function(){}, mean: 0, percentile: function(){ return 0; } }; },
          PerformanceObserver: class PerformanceObserver { observe() {} disconnect() {} },
        };
      };
      coreFactories.inspector = function() {
        // A refusal with no reason is not honest, it is just terse.
        const inspectorReason = 'inspector is not available: it speaks the V8 Inspector Protocol, and this engine is JavaScriptCore — JSC has its own debugger interface, not that one';
        return {
          url: function() { return undefined; },
          open: function() { throw Object.assign(new Error(inspectorReason), { code: 'ERR_METHOD_NOT_IMPLEMENTED' }); },
          close: function() {},
          waitForDebugger: function() { throw Object.assign(new Error(inspectorReason), { code: 'ERR_METHOD_NOT_IMPLEMENTED' }); },
          Session: class Session { connect() { throw Object.assign(new Error(inspectorReason), { code: 'ERR_METHOD_NOT_IMPLEMENTED' }); } },
          console: {},
        };
      };
      coreFactories.dgram = function() {
        // UDP, on the datagram table the socket layer grew. The refusal here used to say
        // "not available yet"; it is available now, and a datagram is genuinely simpler than a
        // stream — every packet arrives whole, with its sender, and nothing needs reassembling.
        const EventEmitter = coreRequire('events');
        function Socket(options) {
          EventEmitter.call(this);
          options = options || {};
          this._type = typeof options === 'string' ? options : (options.type || 'udp4');
          this._broadcast = false;
          this._id = 0;
          this._bound = null;
        }
        Socket.prototype = Object.create(EventEmitter.prototype);
        Socket.prototype.constructor = Socket;
        Socket.prototype.bind = function(port, address, callback) {
          if (typeof port === 'function') { callback = port; port = 0; address = undefined; }
          else if (typeof port === 'object' && port !== null) {
            const options = port;
            callback = typeof address === 'function' ? address : callback;
            address = options.address;
            port = options.port || 0;
          }
          if (typeof address === 'function') { callback = address; address = undefined; }
          const self = this;
          if (callback) this.once('listening', callback);
          this._id = bridge.dgramBind(String(address || (this._type === 'udp6' ? '::' : '0.0.0.0')),
                                      Number(port) || 0, this._broadcast, function(id, event, payload) {
            if (event === 'listening') {
              self._bound = { address: payload.address, family: payload.family, port: payload.port };
              self.emit('listening');
              return;
            }
            if (event === 'datagram') {
              const bytes = Buffer.from(payload.data, 'base64');
              // node's rinfo: where it came from and how big it was.
              self.emit('message', bytes, { address: payload.from.address, family: payload.from.family,
                                            port: payload.from.port, size: bytes.length });
              return;
            }
            if (event === 'error') {
              self.emit('error', Object.assign(new Error(payload.message), { code: payload.code }));
              return;
            }
            if (event === 'close') self.emit('close');
          });
          return this;
        };
        Socket.prototype.send = function(message, offset, length, port, address, callback) {
          // node's overloads: (msg, port[, address][, cb]) and (msg, offset, length, port[, address][, cb]).
          let bytes;
          if (typeof offset === 'number' && typeof length === 'number') {
            bytes = __toBytes(message).slice(offset, offset + length);
          } else {
            bytes = Array.isArray(message)
              ? Buffer.concat(message.map(function(part){ return __toBytes(part); }))
              : __toBytes(message);
            callback = typeof address === 'function' ? address : (typeof port === 'function' ? port : callback);
            address = typeof length === 'string' ? length : undefined;
            port = offset;
          }
          if (typeof address === 'function') { callback = address; address = undefined; }
          const self = this;
          const deliver = function() {
            bridge.dgramSend(self._id, bytes.toString('base64'),
                             String(address || '127.0.0.1'), Number(port) || 0, function(code) {
              if (code) {
                const error = Object.assign(new Error('send ' + code), { code: code });
                if (callback) callback(error); else self.emit('error', error);
                return;
              }
              if (callback) callback(null, bytes.length);
            });
          };
          // node binds implicitly on the first send; so does this.
          if (!this._id) this.bind(0, undefined, deliver); else deliver();
          return this;
        };
        Socket.prototype.address = function() {
          if (!this._bound) {
            throw Object.assign(new Error('bind() first: an unbound socket has no address'), { code: 'ERR_SOCKET_DGRAM_NOT_RUNNING' });
          }
          return this._bound;
        };
        Socket.prototype.close = function(callback) {
          if (callback) this.once('close', callback);
          if (this._id) { bridge.netDestroy(this._id); this._id = 0; }
          const self = this;
          process.nextTick(function(){ self.emit('close'); });
          return this;
        };
        Socket.prototype.setBroadcast = function(on) { this._broadcast = !!on; return this; };
        Socket.prototype.ref = function(){ if (this._id) bridge.netRef(this._id, true); return this; };
        Socket.prototype.unref = function(){ if (this._id) bridge.netRef(this._id, false); return this; };
        Socket.prototype.setTTL = function(){ return this; };
        Socket.prototype.setMulticastTTL = function(ttl) {
          this._requireBound('setMulticastTTL');
          bridge.dgramOption(this._id, Number(ttl), -1, '');
          return this;
        };
        Socket.prototype.setMulticastLoopback = function(on) {
          this._requireBound('setMulticastLoopback');
          bridge.dgramOption(this._id, -1, on ? 1 : 0, '');
          return this;
        };
        Socket.prototype.setMulticastInterface = function(address) {
          this._requireBound('setMulticastInterface');
          bridge.dgramOption(this._id, -1, -1, String(address || ''));
          return this;
        };
        Socket.prototype._requireBound = function(name) {
          if (!this._id) {
            throw Object.assign(new Error('bind() before ' + name + ': the option applies to a socket, and there is none yet'),
                                { code: 'ERR_SOCKET_DGRAM_NOT_RUNNING' });
          }
        };
        // Multicast, which used to refuse: IP_ADD_MEMBERSHIP on the bound socket.
        Socket.prototype.addMembership = function(group, iface) {
          this._requireBound('addMembership');
          const problem = bridge.dgramMembership(this._id, String(group), String(iface || ''), true);
          if (problem) {
            throw Object.assign(new Error('addMembership ' + problem + ' ' + group),
                                { code: problem });
          }
          return this;
        };
        Socket.prototype.dropMembership = function(group, iface) {
          this._requireBound('dropMembership');
          const problem = bridge.dgramMembership(this._id, String(group), String(iface || ''), false);
          if (problem) {
            throw Object.assign(new Error('dropMembership ' + problem + ' ' + group), { code: problem });
          }
          return this;
        };
        return {
          createSocket: function(options, listener) {
            const socket = new Socket(options);
            if (typeof options === 'object' && options && typeof options.recvBufferSize === 'number') { /* advisory */ }
            if (typeof listener === 'function') socket.on('message', listener);
            return socket;
          },
          Socket: Socket,
        };
      };
      coreFactories.diagnostics_channel = function() {
        const channels = {};
        class Channel {
          constructor(name) { this.name = name; this._subs = []; }
          get hasSubscribers() { return this._subs.length > 0; }
          subscribe(fn) { this._subs.push(fn); }
          unsubscribe(fn) { const i = this._subs.indexOf(fn); if (i >= 0) this._subs.splice(i, 1); return i >= 0; }
          publish(message) { for (const fn of this._subs.slice()) fn(message, this.name); }
        }
        function channel(name) { return channels[name] = channels[name] || new Channel(name); }
        return {
          channel: channel,
          hasSubscribers: function(name) { return !!channels[name] && channels[name].hasSubscribers; },
          subscribe: function(name, fn) { channel(name).subscribe(fn); },
          unsubscribe: function(name, fn) { return !!channels[name] && channels[name].unsubscribe(fn); },
          tracingChannel: function(name) {
            return { start: channel(name + ':start'), end: channel(name + ':end'), error: channel(name + ':error'),
                     asyncStart: channel(name + ':asyncStart'), asyncEnd: channel(name + ':asyncEnd'),
                     subscribe: function(){}, unsubscribe: function(){},
                     traceSync: function(fn, ctx, thisArg, ...args) { return fn.apply(thisArg, args); },
                     tracePromise: function(fn, ctx, thisArg, ...args) { return fn.apply(thisArg, args); } };
          },
        };
      };
      coreFactories['util/types'] = function() { return coreRequire('util').types; };
      coreFactories.console = function() {
        const consoleModule = Object.assign({}, globalThis.console);
        consoleModule.Console = globalThis.console.Console;
        consoleModule.default = consoleModule;
        return consoleModule;
      };
      coreFactories.domain = function() {
        const EventEmitter = coreRequire('events');
        class Domain extends EventEmitter {
          run(fn, ...args) { return fn(...args); }
          add() {} remove() {} bind(fn) { return fn; } intercept(fn) { return fn; }
          enter() {} exit() {}
        }
        return { create: function() { return new Domain(); }, Domain: Domain };
      };
      // cluster: workers that share one listening socket. The refusal here was wrong twice —
      // first "single process", then "a JSON channel cannot pass descriptors" — and the second
      // mistake is the instructive one. It borrowed real node's constraint without checking
      // whether it applies: a worker here is another ENGINE inside ONE OS process, so an
      // accepted descriptor is already valid in the worker and only its NUMBER has to travel.
      // JSON carries a number perfectly. Being one process removes cluster's hard part.
      //
      // So the primary owns the listening socket in handoff mode, accepts, and round-robins the
      // raw descriptor to a worker, which adopts it as an ordinary connected socket. That is
      // node's default SCHED_RR, and it is the honest shape here rather than an imitation of it.
      coreFactories.cluster = function() {
        const EventEmitter = coreRequire('events');
        const cluster = new EventEmitter();
        const workerID = process.env.NODE_UNIQUE_ID;
        cluster.isWorker = !!workerID;
        cluster.isPrimary = cluster.isMaster = !workerID;
        cluster.workers = {};
        cluster.SCHED_NONE = 1;
        cluster.SCHED_RR = 2;
        cluster.schedulingPolicy = 2;
        cluster.settings = { exec: process.argv[1], args: process.argv.slice(2), silent: false,
                             execArgv: [], cwd: process.cwd() };

        // Internal traffic rides the same channel as user messages, under one reserved key so a
        // user's own {cmd:...} object can never be mistaken for cluster's.
        const WIRE = '__mouseCluster';
        function wire(body) { const m = {}; m[WIRE] = body; return m; }
        function unwire(message) {
          return (message && typeof message === 'object' && message[WIRE]) || null;
        }

        if (cluster.isWorker) {
          const self = { id: Number(workerID), process: process, exitedAfterDisconnect: false };
          const worker = new EventEmitter();
          Object.assign(worker, self);
          worker.isDead = function(){ return false; };
          worker.isConnected = function(){ return !!process.connected; };
          worker.send = function(message, cb){ return process.send(message, cb); };
          worker.disconnect = function(){ process.disconnect(); return worker; };
          worker.kill = worker.destroy = function(signal){ process.exit(0); };
          cluster.worker = worker;

          // Servers waiting on the primary, and the ones it has answered, keyed by address.
          const claimed = {};

          globalThis.__clusterListen = function(server, host, port, backlog) {
            const key = String(host) + ':' + String(port);
            claimed[key] = server;
            server._clusterKey = key;
            process.send(wire({ cmd: 'queryServer', key: key, host: String(host),
                                port: Number(port), backlog: Number(backlog) }));
            return true;
          };

          process.on('message', function(message) {
            const body = unwire(message);
            if (!body) { worker.emit('message', message); cluster.emit('message', worker, message); return; }
            if (body.cmd === 'served') {
              const server = claimed[body.key];
              if (!server) return;
              server.listening = true;
              server._address = body.address;
              server.emit('listening');
              return;
            }
            if (body.cmd === 'connection') {
              const server = claimed[body.key];
              // No server for this key means it closed between the primary's accept and now;
              // the descriptor must still be closed or it leaks for the life of the process.
              if (!server || server._closing) { bridge.netDiscard(Number(body.fd)); return; }
              server._adoptConnection(Number(body.fd));
              return;
            }
            if (body.cmd === 'disconnect') { process.disconnect(); return; }
          });

          process.send(wire({ cmd: 'online' }));
          cluster.fork = function() {
            throw Object.assign(new Error('cluster.fork is not available in a worker'),
                                { code: 'ERR_INVALID_ARG_TYPE' });
          };
          cluster.disconnect = function(cb){ process.disconnect(); if (cb) cb(); };
          cluster.setupPrimary = cluster.setupMaster = function(){};
          return cluster;
        }

        // ---- primary ----
        const childProcess = coreRequire('child_process');
        let nextID = 0;
        // One listening socket per address, shared by every worker that asked for it.
        const listeners = {};

        function distribute(key, fd) {
          const listener = listeners[key];
          const live = listener ? listener.workers.filter(function(id) {
            const w = cluster.workers[id];
            return w && !w._dead && w.isConnected();
          }) : [];
          if (!live.length) { bridge.netDiscard(fd); return; }
          listener.next = (listener.next + 1) % live.length;
          const worker = cluster.workers[live[listener.next]];
          worker.send(wire({ cmd: 'connection', key: key, fd: fd }));
        }

        function ensureListener(key, body, worker) {
          let listener = listeners[key];
          if (!listener) {
            listener = { workers: [], next: -1, address: null, pending: [], sid: 0 };
            listeners[key] = listener;
            listener.sid = bridge.netListenHandoff(body.host, body.port, body.backlog,
                                                   function(id, event, payload) {
              if (event === 'listening') {
                listener.address = { address: payload.address, family: payload.family, port: payload.port };
                const waiting = listener.pending;
                listener.pending = [];
                waiting.forEach(function(w) { answer(key, w); });
                return;
              }
              if (event === 'handoff') { distribute(key, Number(payload.fd)); return; }
              if (event === 'error') {
                const error = Object.assign(new Error(payload.message), { code: payload.code });
                // A bind failure is the primary's to report: no worker can recover from it.
                if (!cluster.emit('error', error)) throw error;
              }
            });
          }
          if (listener.workers.indexOf(worker.id) < 0) listener.workers.push(worker.id);
          if (listener.address) answer(key, worker);
          else listener.pending.push(worker);
        }

        function answer(key, worker) {
          if (!worker.isConnected()) return;
          worker.send(wire({ cmd: 'served', key: key, address: listeners[key].address }));
          worker.emit('listening', listeners[key].address);
          cluster.emit('listening', worker, listeners[key].address);
        }

        cluster.fork = function(env) {
          const id = ++nextID;
          const childEnv = Object.assign({}, process.env, env || {}, { NODE_UNIQUE_ID: String(id) });
          const child = childProcess.fork(cluster.settings.exec, cluster.settings.args,
                                          { env: childEnv, cwd: cluster.settings.cwd,
                                            silent: cluster.settings.silent });
          const worker = new EventEmitter();
          worker.id = id;
          worker.process = child;
          worker.exitedAfterDisconnect = false;
          worker._dead = false;
          worker.isDead = function(){ return worker._dead; };
          worker.isConnected = function(){ return !worker._dead && child.connected !== false; };
          worker.send = function(message, cb){ return child.send(message, cb); };
          worker.disconnect = function() {
            worker.exitedAfterDisconnect = true;
            if (child.connected !== false) child.send(wire({ cmd: 'disconnect' }));
            return worker;
          };
          worker.kill = worker.destroy = function(signal) {
            worker.exitedAfterDisconnect = true;
            child.kill(signal);
            return worker;
          };
          cluster.workers[id] = worker;

          child.on('message', function(message) {
            const body = unwire(message);
            if (!body) { worker.emit('message', message); cluster.emit('message', worker, message); return; }
            if (body.cmd === 'online') { worker.emit('online'); cluster.emit('online', worker); return; }
            if (body.cmd === 'queryServer') { ensureListener(body.key, body, worker); return; }
          });
          child.on('disconnect', function(){ worker.emit('disconnect'); cluster.emit('disconnect', worker); });
          child.on('exit', function(code, signal) {
            worker._dead = true;
            delete cluster.workers[id];
            // Drop it from every listener, or round-robin keeps dealing connections to a corpse.
            Object.keys(listeners).forEach(function(key) {
              const at = listeners[key].workers.indexOf(id);
              if (at >= 0) listeners[key].workers.splice(at, 1);
            });
            worker.emit('exit', code, signal);
            cluster.emit('exit', worker, code, signal);
          });
          cluster.emit('fork', worker);
          return worker;
        };

        cluster.disconnect = function(callback) {
          const ids = Object.keys(cluster.workers);
          let left = ids.length;
          if (!left) { if (callback) process.nextTick(callback); return; }
          ids.forEach(function(id) {
            const worker = cluster.workers[id];
            worker.once('exit', function(){ if (--left === 0 && callback) callback(); });
            worker.disconnect();
          });
        };

        cluster.setupPrimary = cluster.setupMaster = function(settings) {
          Object.assign(cluster.settings, settings || {});
          cluster.emit('setup', cluster.settings);
        };
        return cluster;
      };
      // tls: like net — imported for types/feature checks; URLSession owns real TLS here.
      coreFactories.tls = function() {
        const net = coreRequire('net');
        class TLSSocket extends net.Socket {}
        return {
          TLSSocket: TLSSocket,
          connect: function() { return new TLSSocket().connect(); },
          createServer: function() { return new net.Server(); },
          rootCertificates: [],
          DEFAULT_MIN_VERSION: 'TLSv1.2',
          DEFAULT_MAX_VERSION: 'TLSv1.3',
        };
      };

      // Real readline: line assembly over any Readable. On a TTY it takes raw mode and does
      // its own editing (echo, backspace, ^C→SIGINT) — the cooked-mode discipline a real
      // terminal driver would provide; non-TTY input just splits lines as they flow.
      coreFactories.readline = function() {
        const EventEmitter = coreRequire('events');
        class Interface extends EventEmitter {
          constructor(options) {
            super();
            this.input = options.input || process.stdin;
            this.output = options.output !== undefined ? options.output : process.stdout;
            this.terminal = options.terminal !== undefined ? !!options.terminal : !!(this.input && this.input.isTTY);
            this._prompt = options.prompt !== undefined ? options.prompt : '> ';
            this._line = '';
            this._questionCb = null;
            this._lastWasCR = false;
            this.closed = false;
            // node closes the interface on abort; ignored, a prompt waits for input forever.
            globalThis.__onAbort(options.signal, () => { if (!this.closed) this.close(); });
            this._onData = (chunk) => this._feed(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString());
            this._onEnd = () => {
              if (this._line.length) { const line = this._line; this._line = ''; this._deliver(line); }
              this.close();
            };
            this.input.on('data', this._onData);
            if (this.input.once) this.input.once('end', this._onEnd);
            if (this.terminal && this.input.setRawMode) this.input.setRawMode(true);
            // Real node wires keypress decoding automatically for terminal interfaces —
            // inquirer listens for 'keypress' without ever calling emitKeypressEvents.
            if (this.terminal) wireKeypress(this.input);
            if (this.input.resume) this.input.resume();
          }
          _echo(text) { if (this.terminal && this.output) this.output.write(text); }
          _deliver(line) {
            if (this._questionCb) { const cb = this._questionCb; this._questionCb = null; cb(line); }
            else this.emit('line', line);
          }
          _feed(text) {
            for (const ch of text) {
              if (ch === '\n' && this._lastWasCR) { this._lastWasCR = false; continue; }
              this._lastWasCR = ch === '\r';
              if (ch === '\r' || ch === '\n') {
                this._echo('\r\n');
                const line = this._line;
                this._line = '';
                this._deliver(line);
              } else if (ch === '\u0003' && this.terminal) {
                if (this.listenerCount('SIGINT')) this.emit('SIGINT');
                else { this.close(); process.exit(130); }
              } else if ((ch === '\u007f' || ch === '\b') && this.terminal) {
                if (this._line.length) { this._line = this._line.slice(0, -1); this._echo('\b \b'); }
              } else {
                this._line += ch;
                this._echo(ch);
              }
            }
          }
          question(query, options, callback) {
            if (typeof options === 'function') callback = options;
            if (this.output) this.output.write(query);
            this._questionCb = callback;
          }
          prompt() { if (this.output) this.output.write(this._prompt); }
          setPrompt(prompt) { this._prompt = prompt; return this; }
          getPrompt() { return this._prompt; }
          get line() { return this._line; }
          get cursor() { return this._line.length; }
          getCursorPos() {
            const columns = (this.output && this.output.columns) || 80;
            const total = this._prompt.length + this._line.length;
            return { rows: Math.floor(total / columns), cols: total % columns };
          }
          write(data) { if (data) this._feed(String(data)); }
          pause() { if (this.input.pause) this.input.pause(); return this; }
          resume() { if (this.input.resume) this.input.resume(); return this; }
          close() {
            if (this.closed) return;
            this.closed = true;
            if (this.input.off) { this.input.off('data', this._onData); this.input.off('end', this._onEnd); }
            if (this.terminal && this.input.setRawMode) this.input.setRawMode(false);
            this.emit('close');
          }
        }
        function toStream(stream) { return stream || process.stdout; }
        // Byte stream → (str, key) pairs, the contract prompt libraries (prompts, inquirer,
        // ink) actually consume. Covers printables, ctrl-letters, and the CSI key set.
        function wireKeypress(stream) {
          if (stream.__keypressWired) return;
          stream.__keypressWired = true;
          const csiNames = { A: 'up', B: 'down', C: 'right', D: 'left', H: 'home', F: 'end' };
          const tildeNames = { 1: 'home', 3: 'delete', 4: 'end', 5: 'pageup', 6: 'pagedown' };
          stream.on('data', function(chunk) {
            const text = typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString();
            let i = 0;
            while (i < text.length) {
              let sequence, str, name, ctrl = false, meta = false, shift = false;
              const ch = text[i];
              if (ch === '\u001b' && (text[i + 1] === '[' || text[i + 1] === 'O')) {
                let j = i + 2;
                while (j < text.length && !/[A-Za-z~]/.test(text[j])) j += 1;
                sequence = text.slice(i, j + 1);
                const body = text.slice(i + 2, j).split(';');
                const final = text[j];
                if (csiNames[final]) name = csiNames[final];
                else if (final === '~') name = tildeNames[body[0]];
                const modifier = parseInt(body[1] || '1', 10) - 1;
                shift = !!(modifier & 1); meta = !!(modifier & 2); ctrl = !!(modifier & 4);
                i = j + 1;
              } else if (ch === '\u001b' && i + 1 < text.length) {
                sequence = text.slice(i, i + 2);
                meta = true;
                name = text[i + 1].toLowerCase();
                i += 2;
              } else {
                sequence = ch;
                i += 1;
                const code = ch.charCodeAt(0);
                if (ch === '\r') name = 'return';
                else if (ch === '\n') name = 'enter';
                else if (ch === '\t') name = 'tab';
                else if (ch === '\u007f' || ch === '\b') name = 'backspace';
                else if (ch === '\u001b') name = 'escape';
                else if (ch === ' ') { name = 'space'; str = ch; }
                else if (code < 27) { name = String.fromCharCode(code + 96); ctrl = true; }
                else { str = ch; name = ch.toLowerCase(); shift = ch !== name && ch.toUpperCase() === ch; }
              }
              stream.emit('keypress', str, { sequence: sequence, name: name, ctrl: ctrl, meta: meta, shift: shift });
            }
          });
        }
        const readline = {
          Interface: Interface,
          createInterface: function(options) { return new Interface(options || {}); },
          emitKeypressEvents: function(stream) { if (stream) wireKeypress(stream); },
          cursorTo: function(stream, x, y, callback) {
            toStream(stream).write(y === undefined || y === null ? '\u001b[' + (x + 1) + 'G' : '\u001b[' + (y + 1) + ';' + (x + 1) + 'H');
            if (callback) callback();
            return true;
          },
          moveCursor: function(stream, dx, dy, callback) {
            let out = '';
            if (dx < 0) out += '\u001b[' + (-dx) + 'D'; else if (dx > 0) out += '\u001b[' + dx + 'C';
            if (dy < 0) out += '\u001b[' + (-dy) + 'A'; else if (dy > 0) out += '\u001b[' + dy + 'B';
            toStream(stream).write(out);
            if (callback) callback();
            return true;
          },
          clearLine: function(stream, dir, callback) {
            toStream(stream).write(dir < 0 ? '\u001b[1K' : dir > 0 ? '\u001b[0K' : '\u001b[2K');
            if (callback) callback();
            return true;
          },
          clearScreenDown: function(stream, callback) {
            toStream(stream).write('\u001b[0J');
            if (callback) callback();
            return true;
          },
        };
        return readline;
      };
      coreFactories['readline/promises'] = function() {
        const readline = coreRequire('readline');
        class PromisesInterface extends readline.Interface {
          question(query) {
            return new Promise((resolve) => readline.Interface.prototype.question.call(this, query, resolve));
          }
        }
        return Object.assign({}, readline, {
          Interface: PromisesInterface,
          createInterface: function(options) { return new PromisesInterface(options || {}); },
        });
      };

      coreFactories.crypto = function() {
      // ---- finite-field Diffie-Hellman and primality, on native BigInt ----
      // The refusal here said this family "needs a bignum implementation". JavaScriptCore has
      // had arbitrary-precision BigInt the whole time — a 2048-bit modular exponentiation takes
      // about 2 ms in the engine's own code. The missing piece was never a primitive; it was
      // this file. Same shape as scrypt, which was refused as a missing primitive and turned out
      // to be arithmetic nobody had written.
      //
      // The MODP groups are RFC 2409 (1, 2) and RFC 3526 (5, 14-18), transcribed from node so
      // the bytes are identical rather than recomputed from the defining formula.
      const MODP_GROUPS = {
          modp1:
            'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A0879' +
            '8E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A3620' +
            'FFFFFFFFFFFFFFFF',
          modp2:
            'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A0879' +
            '8E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B' +
            '0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF',
          modp5:
            'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A0879' +
            '8E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B' +
            '0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA4836' +
            '1C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804' +
            'F1746C08CA237327FFFFFFFFFFFFFFFF',
          modp14:
            'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A0879' +
            '8E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B' +
            '0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA4836' +
            '1C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804' +
            'F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6' +
            '955817183995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF',
          modp15:
            'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A0879' +
            '8E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B' +
            '0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA4836' +
            '1C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804' +
            'F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6' +
            '955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64' +
            'ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D226' +
            '1AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2' +
            '08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF',
          modp16:
            'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A0879' +
            '8E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B' +
            '0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA4836' +
            '1C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804' +
            'F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6' +
            '955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64' +
            'ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D226' +
            '1AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2' +
            '08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D788719A10BDBA5B2699C32718' +
            '6AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D' +
            '99B2964FA090C3A2233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA993B4EA98' +
            '8D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF',
          modp17:
            'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A0879' +
            '8E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B' +
            '0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA4836' +
            '1C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804' +
            'F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6' +
            '955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64' +
            'ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D226' +
            '1AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2' +
            '08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D788719A10BDBA5B2699C32718' +
            '6AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D' +
            '99B2964FA090C3A2233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA993B4EA98' +
            '8D8FDDC186FFB7DC90A6C08F4DF435C93402849236C3FAB4D27C7026C1D4DCB2602646DEC9751E763DBA37BD' +
            'F8FF9406AD9E530EE5DB382F413001AEB06A53ED9027D831179727B0865A8918DA3EDBEBCF9B14ED44CE6CBA' +
            'CED4BB1BDB7F1447E6CC254B332051512BD7AF426FB8F401378CD2BF5983CA01C64B92ECF032EA15D1721D03' +
            'F482D7CE6E74FEF6D55E702F46980C82B5A84031900B1C9E59E7C97FBEC7E8F323A97A7E36CC88BE0F1D45B7' +
            'FF585AC54BD407B22B4154AACC8F6D7EBF48E1D814CC5ED20F8037E0A79715EEF29BE32806A1D58BB7C5DA76' +
            'F550AA3D8A1FBFF0EB19CCB1A313D55CDA56C9EC2EF29632387FE8D76E3C0468043E8F663F4860EE12BF2D5B' +
            '0B7474D6E694F91E6DCC4024FFFFFFFFFFFFFFFF',
          modp18:
            'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A0879' +
            '8E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B' +
            '0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA4836' +
            '1C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804' +
            'F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6' +
            '955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64' +
            'ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D226' +
            '1AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2' +
            '08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D788719A10BDBA5B2699C32718' +
            '6AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D' +
            '99B2964FA090C3A2233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA993B4EA98' +
            '8D8FDDC186FFB7DC90A6C08F4DF435C93402849236C3FAB4D27C7026C1D4DCB2602646DEC9751E763DBA37BD' +
            'F8FF9406AD9E530EE5DB382F413001AEB06A53ED9027D831179727B0865A8918DA3EDBEBCF9B14ED44CE6CBA' +
            'CED4BB1BDB7F1447E6CC254B332051512BD7AF426FB8F401378CD2BF5983CA01C64B92ECF032EA15D1721D03' +
            'F482D7CE6E74FEF6D55E702F46980C82B5A84031900B1C9E59E7C97FBEC7E8F323A97A7E36CC88BE0F1D45B7' +
            'FF585AC54BD407B22B4154AACC8F6D7EBF48E1D814CC5ED20F8037E0A79715EEF29BE32806A1D58BB7C5DA76' +
            'F550AA3D8A1FBFF0EB19CCB1A313D55CDA56C9EC2EF29632387FE8D76E3C0468043E8F663F4860EE12BF2D5B' +
            '0B7474D6E694F91E6DBE115974A3926F12FEE5E438777CB6A932DF8CD8BEC4D073B931BA3BC832B68D9DD300' +
            '741FA7BF8AFC47ED2576F6936BA424663AAB639C5AE4F5683423B4742BF1C978238F16CBE39D652DE3FDB8BE' +
            'FC848AD922222E04A4037C0713EB57A81A23F0C73473FC646CEA306B4BCBC8862F8385DDFA9D4B7FA2C087E8' +
            '79683303ED5BDD3A062B3CF5B3A278A66D2A13F83F44F82DDF310EE074AB6A364597E899A0255DC164F31CC5' +
            '0846851DF9AB48195DED7EA1B1D510BD7EE74D73FAF36BC31ECFA268359046F4EB879F924009438B481C6CD7' +
            '889A002ED5EE382BC9190DA6FC026E479558E4475677E9AA9E3050E2765694DFC81F56E880B96E7160C980DD' +
            '98EDD3DFFFFFFFFFFFFFFFFF',
      };

      function bytesToBig(bytes) {
        const buffer = __toBytes(bytes);
        if (!buffer.length) return 0n;
        return BigInt('0x' + buffer.toString('hex'));
      }
      // Fixed-width, because a DH value is a field element: node pads every public key and
      // shared secret to the prime's byte length rather than trimming leading zeros.
      function bigToBytes(value, length) {
        let hex = value.toString(16);
        if (hex.length % 2) hex = '0' + hex;
        const buffer = Buffer.from(hex, 'hex');
        if (length === undefined || buffer.length === length) return buffer;
        if (buffer.length > length) return buffer.slice(buffer.length - length);
        return Buffer.concat([Buffer.alloc(length - buffer.length), buffer]);
      }
      function modPow(base, exponent, modulus) {
        let result = 1n;
        base %= modulus;
        if (base < 0n) base += modulus;
        while (exponent > 0n) {
          if (exponent & 1n) result = result * base % modulus;
          base = base * base % modulus;
          exponent >>= 1n;
        }
        return result;
      }
      function randomBig(bits) {
        const bytes = Math.ceil(bits / 8);
        const buffer = crypto.randomBytes(bytes);
        let value = bytesToBig(buffer);
        // Trim to exactly `bits`, then force the top bit so the value really is that wide.
        const excess = BigInt(bytes * 8 - bits);
        value >>= excess;
        return value | (1n << BigInt(bits - 1));
      }
      const SMALL_PRIMES = [2n, 3n, 5n, 7n, 11n, 13n, 17n, 19n, 23n, 29n, 31n, 37n, 41n, 43n,
                            47n, 53n, 59n, 61n, 67n, 71n, 73n, 79n, 83n, 89n, 97n];
      // Miller-Rabin. `checks` bases, each a random witness — the same test OpenSSL runs, so
      // the ANSWER matches node even though the internals differ.
      function isProbablePrime(n, checks) {
        if (n < 2n) return false;
        for (const small of SMALL_PRIMES) {
          if (n === small) return true;
          if (n % small === 0n) return false;
        }
        let d = n - 1n, r = 0n;
        while ((d & 1n) === 0n) { d >>= 1n; r += 1n; }
        const bits = n.toString(2).length;
        for (let i = 0; i < checks; i++) {
          // A witness in [2, n-2].
          let a = randomBig(bits) % (n - 3n);
          if (a < 2n) a += 2n;
          let x = modPow(a, d, n);
          if (x === 1n || x === n - 1n) continue;
          let composite = true;
          for (let j = 1n; j < r; j++) {
            x = x * x % n;
            if (x === n - 1n) { composite = false; break; }
          }
          if (composite) return false;
        }
        return true;
      }
      function primeChecks(bits) {
        // node's default effort scales down as the modulus grows, exactly as OpenSSL's does.
        if (bits >= 3747) return 3;
        if (bits >= 1345) return 4;
        if (bits >= 476) return 5;
        if (bits >= 400) return 6;
        if (bits >= 347) return 7;
        if (bits >= 308) return 8;
        return 40;
      }

      class DiffieHellman {
        constructor(prime, generator) {
          this._prime = prime;
          this._generator = generator === undefined ? 2n : generator;
          this._length = bigToBytes(prime).length;
          this.verifyError = 0;
        }
        generateKeys() {
          // A private exponent the width of the prime; node does the same.
          this._private = randomBig(this._length * 8 - 1);
          this._public = modPow(this._generator, this._private, this._prime);
          return this.getPublicKey();
        }
        computeSecret(other) {
          const theirs = typeof other === 'bigint' ? other : bytesToBig(other);
          if (this._private === undefined) {
            const error = new Error('No private key - please generate one first');
            error.code = 'ERR_CRYPTO_INVALID_STATE';
            throw error;
          }
          return bigToBytes(modPow(theirs, this._private, this._prime), this._length);
        }
        getPrime(encoding) { return encode(bigToBytes(this._prime, this._length), encoding); }
        getGenerator(encoding) { return encode(bigToBytes(this._generator), encoding); }
        getPublicKey(encoding) { return encode(bigToBytes(this._public, this._length), encoding); }
        getPrivateKey(encoding) { return encode(bigToBytes(this._private, this._length), encoding); }
        setPublicKey(key) { this._public = bytesToBig(key); return this; }
        setPrivateKey(key) { this._private = bytesToBig(key); return this; }
      }
      function encode(buffer, encoding) {
        return encoding === undefined || encoding === null || encoding === 'buffer'
          ? buffer : buffer.toString(encoding);
      }
        function toBuf(data, encoding) {
          if (Buffer.isBuffer(data)) return data;
          if (data instanceof Uint8Array) return Buffer.from(data);
          // A KeyObject is legal wherever key material is, and jsonwebtoken relies on it:
          // it wraps the secret with createSecretKey before calling createHmac, so stringifying
          // the object here hashed with "[object Object]" and produced a signature nothing else
          // could verify. Found by a real package; every direct HMAC test passed.
          if (data && data._keyObject) return Buffer.from(data._material);
          if (data && typeof data === 'object' && data.key !== undefined) return toBuf(data.key, encoding);
          return Buffer.from(String(data), encoding || 'utf8');
        }
        function finishDigest(base64, encoding) {
          if (base64 === null || base64 === undefined) throw new Error('Digest method not supported');
          const buffer = Buffer.from(base64, 'base64');
          return encoding ? buffer.toString(encoding) : buffer;
        }
        // A Hash IS a Transform in node, and that is not decoration: `fs.createReadStream(f)
        // .pipe(hash)` is the ordinary way to hash a file, and it could not work while these were
        // plain objects. Write side accumulates, flush pushes the digest — so both APIs, the
        // classic update()/digest() and the stream, work on the same object as node's do.
        const CryptoTransform = coreRequire('stream').Transform;

        function finalizedError() {
          return Object.assign(new Error('Digest already called'),
                               { code: 'ERR_CRYPTO_HASH_FINALIZED' });
        }

        class Hash extends CryptoTransform {
          constructor(algorithm, options) {
            super(options);
            this._algorithm = String(algorithm).toLowerCase().replace('-', '');
            this._chunks = [];
            this._finalized = false;
          }
          update(data, encoding) {
            // node reports a reused hash rather than quietly producing a second digest.
            if (this._finalized) throw finalizedError();
            this._chunks.push(toBuf(data, encoding));
            return this;
          }
          copy() {
            const twin = new Hash(this._algorithm);
            twin._chunks = this._chunks.slice();
            return twin;
          }
          digest(encoding) {
            if (this._finalized) throw finalizedError();
            this._finalized = true;
            return finishDigest(bridge.cryptoHash(this._algorithm,
                                                  Buffer.concat(this._chunks).toString('base64')),
                                encoding);
          }
          _transform(chunk, encoding, callback) {
            try { this._chunks.push(toBuf(chunk, encoding)); callback(); }
            catch (error) { callback(error); }
          }
          _flush(callback) {
            try { this.push(this.digest()); callback(); }
            catch (error) { callback(error); }
          }
        }
        class Hmac extends CryptoTransform {
          constructor(algorithm, key, options) {
            super(options);
            this._algorithm = String(algorithm).toLowerCase().replace('-', '');
            this._key = toBuf(key);
            this._chunks = [];
            this._finalized = false;
          }
          update(data, encoding) {
            if (this._finalized) throw finalizedError();
            this._chunks.push(toBuf(data, encoding));
            return this;
          }
          digest(encoding) {
            if (this._finalized) throw finalizedError();
            this._finalized = true;
            return finishDigest(bridge.cryptoHmac(this._algorithm, this._key.toString('base64'),
                                                  Buffer.concat(this._chunks).toString('base64')),
                                encoding);
          }
          _transform(chunk, encoding, callback) {
            try { this._chunks.push(toBuf(chunk, encoding)); callback(); }
            catch (error) { callback(error); }
          }
          _flush(callback) {
            try { this.push(this.digest()); callback(); }
            catch (error) { callback(error); }
          }
        }
        // ---- ciphers, KDFs and key objects ----------------------------------------------
        // AEAD modes (GCM, ChaCha20-Poly1305) ride CryptoKit; CBC/CTR/ECB ride CommonCrypto.
        // A Cipher is node-shaped — update() then final() — but the bytes are produced in ONE
        // call at final(), which is the honest shape for an AEAD: the tag does not exist until
        // the last byte is in. update() therefore returns empty and final() returns everything,
        // which is a legal (if unusual) streaming pattern that node itself uses for GCM.
        const cipherNames = ['aes-128-cbc', 'aes-192-cbc', 'aes-256-cbc',
                             'aes-128-ctr', 'aes-192-ctr', 'aes-256-ctr',
                             'aes-128-ecb', 'aes-192-ecb', 'aes-256-ecb',
                             'aes-128-gcm', 'aes-192-gcm', 'aes-256-gcm',
                             'chacha20-poly1305'];
        function isAEAD(algorithm) {
          return /-gcm$/.test(algorithm) || algorithm === 'chacha20-poly1305';
        }
        function keyBytes(key) {
          if (key && key._keyObject) return key._material;
          if (Buffer.isBuffer(key)) return key;
          if (typeof key === 'string') return Buffer.from(key, 'utf8');
          if (key && key.key) return keyBytes(key.key);
          return Buffer.from(key || []);
        }
        function unsupportedCipher(algorithm) {
          const error = new Error("Unsupported cipher '" + algorithm + "': this device provides AES (CBC/CTR/ECB/GCM) and ChaCha20-Poly1305 through CryptoKit and CommonCrypto, and nothing else");
          error.code = 'ERR_CRYPTO_UNKNOWN_CIPHER';
          return error;
        }

        function Cipher(algorithm, key, iv, options) {
          // A Cipher is a Transform in node, so `readable.pipe(cipher).pipe(file)` works. The
          // bytes still appear at final() rather than per chunk, which is the honest shape for an
          // AEAD (the tag does not exist until the last byte is in) and produces the same output.
          CryptoTransform.call(this, options);
          this._algorithm = String(algorithm).toLowerCase();
          if (cipherNames.indexOf(this._algorithm) < 0) throw unsupportedCipher(algorithm);
          this._key = keyBytes(key);
          this._iv = iv ? keyBytes(iv) : Buffer.alloc(0);
          this._chunks = [];
          this._aad = Buffer.alloc(0);
          this._tag = null;
          this._done = false;
          this._autoPad = true;
          // GCM tags may be shorter than the full 16 bytes, and a protocol that specifies 12
          // rejects a 16-byte one. The option was accepted and ignored.
          this._authTagLength = options && options.authTagLength !== undefined
            ? Number(options.authTagLength) : undefined;
        }
        Cipher.prototype = Object.create(CryptoTransform.prototype);
        Cipher.prototype.constructor = Cipher;
        Cipher.prototype._transform = function(chunk, encoding, callback) {
          try { this.update(chunk, encoding); callback(); }
          catch (error) { callback(error); }
        };
        Cipher.prototype._flush = function(callback) {
          try {
            const out = this.final();
            if (out && out.length) this.push(out);
            callback();
          } catch (error) { callback(error); }
        };
        Cipher.prototype.setAAD = function(aad) {
          this._aad = keyBytes(aad);
          return this;
        };
        Cipher.prototype.setAutoPadding = function(on) { this._autoPad = on !== false; return this; };
        Cipher.prototype.update = function(data, inputEncoding, outputEncoding) {
          const chunk = __toBytes(data, inputEncoding);
          this._chunks.push(chunk);
          const empty = Buffer.alloc(0);
          return outputEncoding ? empty.toString(outputEncoding) : empty;
        };
        Cipher.prototype.final = function(outputEncoding) {
          if (this._done) throw Object.assign(new Error('Cipher already finalized'), { code: 'ERR_CRYPTO_INVALID_STATE' });
          this._done = true;
          const plain = Buffer.concat(this._chunks);
          const result = bridge.cipherSeal(this._algorithm, this._key.toString('base64'),
                                           this._iv.toString('base64'), plain.toString('base64'),
                                           this._aad.toString('base64'));
          if (!result) throw Object.assign(new Error('Cipher failed: check the key and IV lengths for ' + this._algorithm),
                                           { code: 'ERR_CRYPTO_OPERATION_FAILED' });
          if (result.tag) {
            const full = Buffer.from(result.tag, 'base64');
            // Truncating from the FRONT is what the GCM spec says a shortened tag is.
            this._tag = this._authTagLength !== undefined && this._authTagLength < full.length
              ? full.slice(0, this._authTagLength) : full;
          }
          const out = Buffer.from(result.data, 'base64');
          return outputEncoding ? out.toString(outputEncoding) : out;
        };
        Cipher.prototype.getAuthTag = function() {
          if (!isAEAD(this._algorithm)) {
            throw Object.assign(new Error('getAuthTag is only for authenticated ciphers'), { code: 'ERR_CRYPTO_INVALID_STATE' });
          }
          if (!this._tag) throw Object.assign(new Error('getAuthTag must be called after final()'), { code: 'ERR_CRYPTO_INVALID_STATE' });
          return this._tag;
        };

        function Decipher(algorithm, key, iv, options) {
          Cipher.call(this, algorithm, key, iv, options);
          this._expectedTag = Buffer.alloc(0);
        }
        Decipher.prototype = Object.create(Cipher.prototype);
        Decipher.prototype.constructor = Decipher;
        Decipher.prototype.setAuthTag = function(tag) { this._expectedTag = keyBytes(tag); return this; };
        Decipher.prototype.final = function(outputEncoding) {
          if (this._done) throw Object.assign(new Error('Decipher already finalized'), { code: 'ERR_CRYPTO_INVALID_STATE' });
          this._done = true;
          const body = Buffer.concat(this._chunks);
          const result = bridge.cipherOpen(this._algorithm, this._key.toString('base64'),
                                            this._iv.toString('base64'), body.toString('base64'),
                                            this._expectedTag.toString('base64'),
                                            this._aad.toString('base64'));
          if (result === null || result === undefined) {
            // For an AEAD this is the tag check failing, which is the whole point of one.
            const error = new Error(isAEAD(this._algorithm)
              ? 'Unsupported state or unable to authenticate data'
              : 'error:1C800064:Provider routines::bad decrypt');
            error.code = isAEAD(this._algorithm) ? 'ERR_CRYPTO_INVALID_AUTH_TAG' : 'ERR_OSSL_BAD_DECRYPT';
            throw error;
          }
          const out = Buffer.from(result, 'base64');
          return outputEncoding ? out.toString(outputEncoding) : out;
        };

        // A KeyObject wraps raw material so it can travel without being a bare Buffer, which
        // is what modern code passes to createCipheriv/createHmac.
        function SecretKeyObject(material) {
          this._keyObject = true;
          this._material = keyBytes(material);
          this.type = 'secret';
          this.symmetricKeySize = this._material.length;
          this.asymmetricKeyType = undefined;
        }
        SecretKeyObject.prototype.export = function(options) {
          if (options && options.format === 'jwk') {
            return { kty: 'oct', k: this._material.toString('base64url') };
          }
          return Buffer.from(this._material);
        };
        SecretKeyObject.prototype.equals = function(other) {
          return !!other && other._keyObject === true && this._material.equals(other._material);
        };

        // ---- asymmetric: EC and Ed25519 -------------------------------------------------
        // What the device can actually do: ECDSA over P-256/384/521 and Ed25519, through
        // CryptoKit. RSA needs SecKey plumbing and still refuses by name. Keys travel as PEM
        // because that is what CryptoKit imports and what node's callers already hold.
        function AsymmetricKeyObject(pem, kind) {
          this._keyObject = true;
          this._pem = String(pem);
          this.type = kind;                       // 'private' | 'public'
          const identity = bridge.keyIdentify(this._pem);
          this.asymmetricKeyType = identity.type;
          this.asymmetricKeyDetails = identity.curve ? { namedCurve: identity.curve } : {};
          if (identity.type === 'unknown') {
            throw Object.assign(new Error('Failed to read the key: expected a PKCS#8 or SPKI PEM for EC (P-256/384/521) or Ed25519'),
                                { code: 'ERR_CRYPTO_INVALID_KEY_OBJECT_TYPE' });
          }
          if (identity.type === 'rsa') {
            this.asymmetricKeyDetails = { modulusLength: identity.modulusLength, publicExponent: 65537n };
          }
        }
        AsymmetricKeyObject.prototype.export = function(options) {
          options = options || {};
          if (options.format === 'der') {
            const body = this._pem.split('\n').filter(line => line.indexOf('-----') < 0).join('');
            return Buffer.from(body, 'base64');
          }
          return this._pem;
        };
        AsymmetricKeyObject.prototype.equals = function(other) {
          return !!other && other._pem === this._pem;
        };

        function keyPem(key, expected) {
          if (key && key._pem) return key._pem;
          if (typeof key === 'string') return key;
          if (Buffer.isBuffer(key)) return key.toString('utf8');
          if (key && key.key) return keyPem(key.key, expected);
          throw Object.assign(new Error('Invalid key: pass a PEM string, a Buffer, or a KeyObject'),
                              { code: 'ERR_INVALID_ARG_TYPE' });
        }
        function dsaIsRaw(key) {
          return !!(key && typeof key === 'object' && key.dsaEncoding === 'ieee-p1363');
        }
        // node's padding constants for RSA, and PSS is selected per call.
        function rsaOptions(key) {
          const options = (key && typeof key === 'object' && !key._keyObject) ? key : {};
          const padding = options.padding === undefined ? 1 : Number(options.padding);   // PKCS1v15
          return { pss: padding === 6, padding: padding };
        }
        function signWith(algorithm, data, key) {
          const pem = keyPem(key);
          const identity = bridge.keyIdentify(pem);
          if (identity.type === 'rsa') {
            const signature = bridge.rsaSign(pem, Buffer.from(data).toString('base64'),
                                             String(algorithm || 'sha256'), rsaOptions(key).pss);
            if (!signature) {
              throw Object.assign(new Error('RSA signing failed: the key must be an RSA private key and the digest one of sha1/sha256/sha384/sha512'),
                                  { code: 'ERR_CRYPTO_OPERATION_FAILED' });
            }
            return Buffer.from(signature, 'base64');
          }
          if (identity.type === 'ed25519' && algorithm) {
            // node: Ed25519 signs the message itself, so naming a digest is an error.
            throw Object.assign(new Error('Ed25519 signs the message directly; pass null as the algorithm'),
                                { code: 'ERR_OSSL_INVALID_DIGEST' });   // node's code, measured
          }
          const signature = bridge.keySign(pem, Buffer.from(data).toString('base64'),
                                           String(algorithm || 'sha256'), dsaIsRaw(key));
          if (!signature) {
            throw Object.assign(new Error('Signing failed: the key must be an EC (P-256/384/521) or Ed25519 private key, and the digest one of sha1/sha256/sha384/sha512'),
                                { code: 'ERR_CRYPTO_OPERATION_FAILED' });
          }
          return Buffer.from(signature, 'base64');
        }
        function verifyWith(algorithm, data, key, signature) {
          const pem = keyPem(key);
          const identity = bridge.keyIdentify(pem);
          if (identity.type === 'rsa') {
            return !!bridge.rsaVerify(pem, Buffer.from(data).toString('base64'),
                                      Buffer.from(signature).toString('base64'),
                                      String(algorithm || 'sha256'), rsaOptions(key).pss);
          }
          if (identity.type === 'ed25519' && algorithm) {
            throw Object.assign(new Error('Ed25519 verifies the message directly; pass null as the algorithm'),
                                { code: 'ERR_OSSL_INVALID_DIGEST' });
          }
          return !!bridge.keyVerify(pem, Buffer.from(data).toString('base64'),
                                    Buffer.from(signature).toString('base64'),
                                    String(algorithm || 'sha256'), dsaIsRaw(key));
        }

        // The streaming shape: update() until sign()/verify(), which is how node's own API and
        // every JWT library drive it.
        function Signer(algorithm) {
          this._algorithm = algorithm;
          this._chunks = [];
        }
        Signer.prototype.update = function(data, encoding) {
          this._chunks.push(__toBytes(data, encoding));
          return this;
        };
        Signer.prototype.sign = function(key, outputEncoding) {
          const signature = signWith(this._algorithm, Buffer.concat(this._chunks), key);
          return outputEncoding ? signature.toString(outputEncoding) : signature;
        };
        function Verifier(algorithm) {
          this._algorithm = algorithm;
          this._chunks = [];
        }
        Verifier.prototype.update = Signer.prototype.update;
        Verifier.prototype.verify = function(key, signature, encoding) {
          const bytes = Buffer.isBuffer(signature) ? signature : Buffer.from(String(signature), encoding || 'hex');
          return verifyWith(this._algorithm, Buffer.concat(this._chunks), key, bytes);
        };

        function generateSecretKeySync(type, options) {
          const length = ((options && options.length) || 256) / 8;
          return new SecretKeyObject(Buffer.from(bridge.randomBytes(length), 'base64'));
        }
        function generateKeyPairSync(type, options) {
          options = options || {};
          // node raises ERR_INVALID_ARG_TYPE for a missing type, and refusal language here made a
          // surface sweep read "no key type given" as "this feature is unavailable".
          if (typeof type !== 'string') {
            throw Object.assign(
              new TypeError('The "type" argument must be of type string. Received ' +
                            (type === undefined ? 'undefined' : typeof type)),
              { code: 'ERR_INVALID_ARG_TYPE' });
          }
          const kind = String(type).toLowerCase();
          if (kind !== 'ec' && kind !== 'ed25519' && kind !== 'x25519' && kind !== 'x448' && kind !== 'rsa') {
            throw Object.assign(new Error("Key type '" + type + "' is not available: this device generates RSA through SecKey and EC (P-256/384/521), Ed25519 and X25519 through CryptoKit; DSA has no system implementation"),
                                { code: 'ERR_CRYPTO_OPERATION_NOT_SUPPORTED' });
          }
          // X448 is computed here rather than by the bridge — it is arithmetic, not a system
          // key type — but it produces the same PEM pair, so it joins the common path.
          const pair = kind === 'x448' ? globalThis.__x448.generate()
            : kind === 'rsa' ? bridge.rsaGenerate(Number(options.modulusLength) || 2048)
            : bridge.keyGenerate(kind, String(options.namedCurve || ''));
          if (!pair) {
            throw Object.assign(new Error("Unsupported curve '" + options.namedCurve + "': P-256 (prime256v1), P-384 (secp384r1) and P-521 (secp521r1) are available"),
                                { code: 'ERR_CRYPTO_INVALID_CURVE' });
          }
          // node returns PEM strings when encodings are given and KeyObjects otherwise.
          const wantPublicPem = options.publicKeyEncoding && options.publicKeyEncoding.format === 'pem';
          const wantPrivatePem = options.privateKeyEncoding && options.privateKeyEncoding.format === 'pem';
          return {
            publicKey: wantPublicPem ? pair.publicKey : new AsymmetricKeyObject(pair.publicKey, 'public'),
            privateKey: wantPrivatePem ? pair.privateKey : new AsymmetricKeyObject(pair.privateKey, 'private'),
          };
        }
        function refuseCrypto(name, reason) {
          return function() {
            const error = new Error('crypto.' + name + ' is not available: ' + reason);
            error.code = 'ERR_CRYPTO_OPERATION_NOT_SUPPORTED';
            throw error;
          };
        }
        function scryptSync(password, salt, keylen, options) {
          options = options || {};
          // node accepts both spellings of every parameter, and its defaults are N=16384, r=8, p=1.
          const n = options.N !== undefined ? options.N : (options.cost !== undefined ? options.cost : 16384);
          const r = options.r !== undefined ? options.r : (options.blockSize !== undefined ? options.blockSize : 8);
          const p = options.p !== undefined ? options.p : (options.parallelization !== undefined ? options.parallelization : 1);
          const maxmem = options.maxmem !== undefined ? options.maxmem : 32 * 1024 * 1024;
          const invalid = function() {
            return Object.assign(new Error('Invalid scrypt params'),
                                 { code: 'ERR_CRYPTO_INVALID_SCRYPT_PARAMS' });
          };
          // The memory bound is node's own: 128 * N * r must fit in maxmem. Checked here because
          // exceeding it means allocating hundreds of megabytes before finding out.
          if (128 * n * r > maxmem) throw invalid();
          const derived = bridge.scrypt(keyBytes(password).toString('base64'),
                                        keyBytes(salt).toString('base64'),
                                        n, r, p, keylen);
          if (derived === null || derived === undefined) throw invalid();
          return Buffer.from(String(derived), 'base64');
        }

        function pbkdf2Sync(password, salt, iterations, keylen, digest) {
          const derived = bridge.pbkdf2(keyBytes(password).toString('base64'),
                                        keyBytes(salt).toString('base64'),
                                        Number(iterations), Number(keylen),
                                        String(digest || 'sha1'));
          if (!derived) {
            const error = new Error('Unsupported digest for pbkdf2: ' + digest);
            error.code = 'ERR_CRYPTO_INVALID_DIGEST';
            throw error;
          }
          return Buffer.from(derived, 'base64');
        }
        function hkdfSync(digest, key, salt, info, keylen) {
          const derived = bridge.hkdf(String(digest), keyBytes(key).toString('base64'),
                                      keyBytes(salt).toString('base64'),
                                      keyBytes(info).toString('base64'), Number(keylen));
          if (!derived) {
            const error = new Error('Unsupported digest for hkdf: ' + digest);
            error.code = 'ERR_CRYPTO_INVALID_DIGEST';
            throw error;
          }
          // node's hkdf resolves an ArrayBuffer, not a Buffer.
          const bytes = Buffer.from(derived, 'base64');
          return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length);
        }
        const crypto = {
          createHash: function(algorithm) { return new Hash(algorithm); },
          createHmac: function(algorithm, key) { return new Hmac(algorithm, key); },
          // Real symmetric crypto, from the audit's biggest gap.
          createCipheriv: function(algorithm, key, iv, options) { return new Cipher(algorithm, key, iv, options); },
          createDecipheriv: function(algorithm, key, iv, options) { return new Decipher(algorithm, key, iv, options); },
          Cipheriv: Cipher, Decipheriv: Decipher, Cipher: Cipher, Decipher: Decipher,
          getCiphers: function() { return cipherNames.slice(); },
          getCipherInfo: function(name) {
            const algorithm = String(name).toLowerCase();
            if (cipherNames.indexOf(algorithm) < 0) return undefined;
            const bits = algorithm === 'chacha20-poly1305' ? 256 : Number(algorithm.split('-')[1]);
            const mode = algorithm === 'chacha20-poly1305' ? 'stream' : algorithm.split('-')[2];
            // node reports OpenSSL's canonical name, which for AES-GCM is `id-aes256-gcm`
            // rather than the name you passed in (measured).
            const canonical = /^aes-(\d+)-gcm$/.test(algorithm)
              ? 'id-aes' + algorithm.split('-')[1] + '-gcm' : algorithm;
            return { name: canonical, blockSize: mode === 'stream' ? 1 : 16,
                     ivLength: isAEAD(algorithm) ? 12 : (mode === 'ecb' ? 0 : 16),
                     keyLength: bits / 8, mode: mode };
          },
          pbkdf2Sync: pbkdf2Sync,
          pbkdf2: function(password, salt, iterations, keylen, digest, callback) {
            try {
              const derived = pbkdf2Sync(password, salt, iterations, keylen, digest);
              process.nextTick(function(){ callback(null, derived); });
            } catch (error) { process.nextTick(function(){ callback(error); }); }
          },
          hkdfSync: hkdfSync,
          hkdf: function(digest, key, salt, info, keylen, callback) {
            try {
              const derived = hkdfSync(digest, key, salt, info, keylen);
              process.nextTick(function(){ callback(null, derived); });
            } catch (error) { process.nextTick(function(){ callback(error); }); }
          },
          createSecretKey: function(material, encoding) {
            return new SecretKeyObject(typeof material === 'string' ? Buffer.from(material, encoding || 'utf8') : material);
          },
          KeyObject: SecretKeyObject,
          secureHeapUsed: function() { return { total: 0, min: 0, used: 0, utilization: 0 }; },
          getFips: function() { return 0; },
          setFips: function() {},
          fips: false,
          // node 21's one-shot digest, and the algorithm lists.
          hash: function(algorithm, data, outputEncoding) {
            const digest = new Hash(algorithm);
            digest.update(data);
            return digest.digest(outputEncoding === undefined ? 'hex' : outputEncoding);
          },
          getHashes: function() { return ['md5', 'sha1', 'sha256', 'sha384', 'sha512']; },
          // What CryptoKit actually carries. Listing curves we cannot use would be a lie a
          // library then acts on.
          getCurves: function() { return ['prime256v1', 'secp384r1', 'secp521r1', 'ed25519']; },
          // The asymmetric family. Every one of these needs key parsing, ASN.1 and padding
          // modes that this device exposes only through Security framework's SecKey — real
          // work, not a shim, and it is honest to say so rather than half-do it. A caller gets
          // a clear error naming what is missing instead of `undefined is not a function`.
          // Real signing: ECDSA over P-256/384/521 and Ed25519, through CryptoKit. RSA is the
          // part that still needs SecKey, and it refuses by name from inside these.
          createSign: function(algorithm) { return new Signer(algorithm); },
          createVerify: function(algorithm) { return new Verifier(algorithm); },
          sign: function(algorithm, data, key) { return signWith(algorithm, data, key); },
          verify: function(algorithm, data, key, signature) { return verifyWith(algorithm, data, key, signature); },
          Sign: Signer,
          Verify: Verifier,
          generateKeyPairSync: generateKeyPairSync,
          generateKeyPair: function(type, options, callback) {
            if (typeof options === 'function') { callback = options; options = {}; }
            try {
              const pair = generateKeyPairSync(type, options);
              process.nextTick(function(){ callback(null, pair.publicKey, pair.privateKey); });
            } catch (error) { process.nextTick(function(){ callback(error); }); }
          },
          generateKeySync: generateSecretKeySync,
          generateKey: function(type, options, callback) {
            try {
              const key = generateSecretKeySync(type, options);
              process.nextTick(function(){ callback(null, key); });
            } catch (error) { process.nextTick(function(){ callback(error); }); }
          },
          createPrivateKey: function(key) { return new AsymmetricKeyObject(keyPem(key), 'private'); },
          createPublicKey: function(key) {
            const pem = keyPem(key);
            // node accepts a PRIVATE key here and derives the public half; CryptoKit does the
            // same when the signer needs it, so the object records what it was given.
            return new AsymmetricKeyObject(pem, pem.indexOf('PRIVATE') >= 0 ? 'private' : 'public');
          },
          // Real ECDH. node's public keys are the uncompressed point, which is what CryptoKit
          // calls x963Representation — the same bytes, so the two interoperate directly.
          createECDH: function(curve) {
            const name = String(curve);
            const state = { curve: name, privateKey: null, publicKey: null };
            const ecdh = {
              generateKeys: function(encoding, format) {
                const pair = bridge.ecdhGenerate(name);
                if (!pair) {
                  throw Object.assign(new Error("Unsupported curve '" + name + "': prime256v1, secp384r1, secp521r1 and x25519 are available through CryptoKit"),
                                      { code: 'ERR_CRYPTO_INVALID_CURVE' });
                }
                state.privateKey = Buffer.from(pair.privateKey, 'base64');
                state.publicKey = Buffer.from(pair.publicKey, 'base64');
                return encoding ? state.publicKey.toString(encoding) : state.publicKey;
              },
              getPublicKey: function(encoding, format) {
                if (!state.publicKey) throw Object.assign(new Error('call generateKeys() first'), { code: 'ERR_CRYPTO_INVALID_STATE' });
                return encoding ? state.publicKey.toString(encoding) : state.publicKey;
              },
              getPrivateKey: function(encoding) {
                if (!state.privateKey) throw Object.assign(new Error('call generateKeys() first'), { code: 'ERR_CRYPTO_INVALID_STATE' });
                return encoding ? state.privateKey.toString(encoding) : state.privateKey;
              },
              setPrivateKey: function(key, encoding) {
                state.privateKey = typeof key === 'string' ? Buffer.from(key, encoding || 'hex') : __toBytes(key);
                // The public half follows from the private one, but CryptoKit only derives it
                // when asked — so it is recomputed on the next getPublicKey via a round trip.
                state.publicKey = null;
                return ecdh;
              },
              computeSecret: function(peer, inputEncoding, outputEncoding) {
                if (!state.privateKey) throw Object.assign(new Error('call generateKeys() first'), { code: 'ERR_CRYPTO_INVALID_STATE' });
                const other = typeof peer === 'string' ? Buffer.from(peer, inputEncoding || 'hex') : __toBytes(peer);
                const secret = bridge.ecdhCompute(name, state.privateKey.toString('base64'), other.toString('base64'));
                if (!secret) {
                  throw Object.assign(new Error('computeSecret failed: the peer key must be an uncompressed point on ' + name),
                                      { code: 'ERR_CRYPTO_ECDH_INVALID_PUBLIC_KEY' });
                }
                const bytes = Buffer.from(secret, 'base64');
                return outputEncoding ? bytes.toString(outputEncoding) : bytes;
              },
              setPublicKey: function() {
                throw refuseCrypto('setPublicKey', 'node deprecated it and CryptoKit derives the public half from the private key')();
              },
            };
            return ecdh;
          },
          createDiffieHellman: function(prime, primeEncoding, generator, generatorEncoding) {
            // Two shapes: a bit LENGTH (generate a fresh safe prime) or an actual prime.
            if (typeof prime === 'number') {
              const bits = prime;
              const g = typeof primeEncoding === 'number' ? primeEncoding : 2;
              let candidate;
              do { candidate = bytesToBig(crypto.generatePrimeSync(bits, { safe: true })); }
              while (candidate.toString(2).length !== bits);
              return new DiffieHellman(candidate, BigInt(g));
            }
            const p = typeof prime === 'string' && typeof primeEncoding === 'string'
              ? bytesToBig(Buffer.from(prime, primeEncoding)) : bytesToBig(prime);
            let g = 2n;
            if (typeof generator === 'number') g = BigInt(generator);
            else if (generator !== undefined && generator !== null) {
              g = typeof generator === 'string' && typeof generatorEncoding === 'string'
                ? bytesToBig(Buffer.from(generator, generatorEncoding)) : bytesToBig(generator);
            } else if (typeof primeEncoding === 'number') g = BigInt(primeEncoding);
            return new DiffieHellman(p, g);
          },
          createDiffieHellmanGroup: function(name) { return crypto.getDiffieHellman(name); },
          getDiffieHellman: function(name) {
            const hex = MODP_GROUPS[name];
            if (!hex) {
              const error = new Error('Unknown group: ' + name);
              error.code = 'ERR_CRYPTO_UNKNOWN_DH_GROUP';
              throw error;
            }
            return new DiffieHellman(BigInt('0x' + hex), 2n);
          },
          DiffieHellman: DiffieHellman,
          DiffieHellmanGroup: DiffieHellman,
          // Key-object agreement: X25519 and the EC curves, all of which CryptoKit does. The
          // finite-field API (createDiffieHellman) is the one that needs a bignum, and it is a
          // different function — the old refusal here named that one by mistake.
          diffieHellman: function(options) {
            options = options || {};
            const privatePem = keyPem(options.privateKey);
            const publicPem = keyPem(options.publicKey);
            // X448 agreement is the same scalar multiplication as its key generation, so it
            // is handled here rather than by the bridge, which has no such key type.
            if (privatePem && publicPem &&
                globalThis.__x448.isPrivate(privatePem) && globalThis.__x448.isPublic(publicPem)) {
              const shared = globalThis.__x448.agree(privatePem, publicPem);
              if (shared) return shared;
            }
            if (!privatePem || !publicPem) {
              throw Object.assign(new TypeError('The "options.privateKey" and ' +
                                                '"options.publicKey" properties are required'),
                                  { code: 'ERR_INVALID_ARG_TYPE' });
            }
            const secret = bridge.keyAgree(privatePem, publicPem);
            if (secret === null || secret === undefined) {
              throw Object.assign(
                new Error('crypto.diffieHellman failed: this key pair is not an X25519 or EC ' +
                          'pair (X448 and finite-field groups are not available here)'),
                { code: 'ERR_CRYPTO_OPERATION_FAILED' });
            }
            return Buffer.from(String(secret), 'base64');
          },
          ECDH: { convertKey: refuseCrypto('ECDH.convertKey', 'point compression conversion is not exposed by CryptoKit') },
          DiffieHellman: refuseCrypto('DiffieHellman', 'finite-field DH needs a bignum implementation'),
          DiffieHellmanGroup: refuseCrypto('DiffieHellmanGroup', 'finite-field DH needs a bignum implementation'),
          // RSA encryption. node's default padding for these is OAEP (4) with SHA-1.
          publicEncrypt: function(key, buffer) {
            const options = (key && typeof key === 'object' && !key._keyObject) ? key : {};
            const padding = options.padding === undefined ? 4 : Number(options.padding);
            const digest = String(options.oaepHash || 'sha1');
            const sealed = bridge.rsaEncrypt(keyPem(key), Buffer.from(buffer).toString('base64'), padding, digest);
            if (!sealed) {
              throw Object.assign(new Error('publicEncrypt failed: needs an RSA key, OAEP (padding 4) or PKCS1 (padding 1), and a payload that fits the modulus'),
                                  { code: 'ERR_CRYPTO_OPERATION_FAILED' });
            }
            return Buffer.from(sealed, 'base64');
          },
          privateDecrypt: function(key, buffer) {
            const options = (key && typeof key === 'object' && !key._keyObject) ? key : {};
            const padding = options.padding === undefined ? 4 : Number(options.padding);
            const digest = String(options.oaepHash || 'sha1');
            const plain = bridge.rsaDecrypt(keyPem(key), Buffer.from(buffer).toString('base64'), padding, digest);
            if (plain === null || plain === undefined) {
              throw Object.assign(new Error('privateDecrypt failed: wrong key, wrong padding, or corrupt ciphertext'),
                                  { code: 'ERR_OSSL_RSA_OAEP_DECODING_ERROR' });
            }
            return Buffer.from(plain, 'base64');
          },
          // The signing-with-the-private-key direction of raw RSA. SecKey exposes encryption
          // for the public key and decryption for the private one, which is the useful pair;
          // the reversed forms are legacy and stay honest about their absence.
          // The refusal here claimed SecKey has no reversed direction. True of its PADDED
          // algorithms, false of the RAW ones: `.rsaSignatureRaw` is a private-key exponentiation
          // over caller-padded data, which is what privateEncrypt is, and `.rsaEncryptionRaw`
          // with the public key is the other half. Only the PKCS#1 type 1 padding was missing.
          privateEncrypt: function(key, buffer) {
            const sealed = bridge.rsaPrivateEncrypt(keyPem(key), __toBytes(buffer).toString('base64'));
            if (sealed === null || sealed === undefined) {
              throw Object.assign(new Error('privateEncrypt failed: the key must be RSA and the ' +
                                            'data at most modulusLength - 11 bytes'),
                                  { code: 'ERR_CRYPTO_OPERATION_FAILED' });
            }
            return Buffer.from(String(sealed), 'base64');
          },
          publicDecrypt: function(key, buffer) {
            const opened = bridge.rsaPublicDecrypt(keyPem(key), __toBytes(buffer).toString('base64'));
            if (opened === null || opened === undefined) {
              throw Object.assign(new Error('publicDecrypt failed: this is not a PKCS#1 type 1 ' +
                                            'block sealed with the matching private key'),
                                  { code: 'ERR_CRYPTO_OPERATION_FAILED' });
            }
            return Buffer.from(String(opened), 'base64');
          },
          scrypt: function(password, salt, keylen, options, callback) {
            if (typeof options === 'function') { callback = options; options = undefined; }
            // Parameter validation is SYNCHRONOUS in node even in the async form — bad params
            // throw at the call site rather than arriving at the callback. Verified against it.
            const derived = scryptSync(password, salt, keylen, options);
            process.nextTick(function(){ callback(null, derived); });
          },
          scryptSync: scryptSync,
          checkPrimeSync: function(candidate, options) {
            const value = typeof candidate === 'bigint' ? candidate : bytesToBig(candidate);
            const checks = options && options.checks !== undefined
              ? options.checks : primeChecks(value.toString(2).length);
            return isProbablePrime(value, checks || primeChecks(value.toString(2).length));
          },
          checkPrime: function(candidate, options, callback) {
            if (typeof options === 'function') { callback = options; options = {}; }
            let result, error = null;
            try { result = crypto.checkPrimeSync(candidate, options); }
            catch (e) { error = e; }
            queueMicrotask(() => callback(error, result));
          },
          generatePrimeSync: function(size, options) {
            options = options || {};
            const add = options.add === undefined ? null
              : (typeof options.add === 'bigint' ? options.add : bytesToBig(options.add));
            const rem = options.rem === undefined ? null
              : (typeof options.rem === 'bigint' ? options.rem : bytesToBig(options.rem));
            const checks = primeChecks(size);
            for (;;) {
              let candidate = randomBig(size) | 1n;   // odd, and exactly `size` bits
              if (add) {
                // node's contract: candidate % add === rem (default rem 1 for safe primes).
                const target = rem === null ? (options.safe ? 3n : 1n) : rem;
                candidate = candidate - (candidate % add) + target;
                if (candidate.toString(2).length !== size) continue;
              }
              if (!isProbablePrime(candidate, checks)) continue;
              // A SAFE prime is one where (p-1)/2 is also prime.
              if (options.safe && !isProbablePrime((candidate - 1n) / 2n, checks)) continue;
              if (options.bigint) return candidate;
              const bytes = bigToBytes(candidate, Math.ceil(size / 8));
              return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
            }
          },
          generatePrime: function(size, options, callback) {
            if (typeof options === 'function') { callback = options; options = {}; }
            let result, error = null;
            try { result = crypto.generatePrimeSync(size, options); }
            catch (e) { error = e; }
            queueMicrotask(() => callback(error, result));
          },
          Certificate: refuseCrypto('Certificate', 'certificate handling needs Security framework plumbing'),
          X509Certificate: refuseCrypto('X509Certificate', 'certificate parsing needs Security framework plumbing'),
          setEngine: function() {},
          prng: function(size) { return Buffer.from(bridge.randomBytes(size), 'base64'); },
          rng: function(size) { return Buffer.from(bridge.randomBytes(size), 'base64'); },
          pseudoRandomBytes: function(size) { return Buffer.from(bridge.randomBytes(size), 'base64'); },
          constants: { RSA_PKCS1_PADDING: 1, RSA_NO_PADDING: 3, RSA_PKCS1_OAEP_PADDING: 4,
                       RSA_PKCS1_PSS_PADDING: 6, RSA_PSS_SALTLEN_DIGEST: -1,
                       RSA_PSS_SALTLEN_MAX_SIGN: -2, RSA_PSS_SALTLEN_AUTO: -2,
                       defaultCoreCipherList: '', defaultCipherList: '' },
          getRandomValues: function(target) {
            const bytes = Buffer.from(bridge.randomBytes(target.length), 'base64');
            for (let i = 0; i < target.length; i++) target[i] = bytes[i];
            return target;
          },
          randomFillSync: function(target, offset, size) {
            offset = offset || 0;
            size = size === undefined ? target.length - offset : size;
            const bytes = Buffer.from(bridge.randomBytes(size), 'base64');
            for (let i = 0; i < size; i++) target[offset + i] = bytes[i];
            return target;
          },
          randomFill: function(target, offset, size, callback) {
            if (typeof offset === 'function') { callback = offset; offset = 0; size = target.length; }
            else if (typeof size === 'function') { callback = size; size = target.length - offset; }
            const self = this;
            process.nextTick(function(){
              try { callback(null, self.randomFillSync(target, offset, size)); }
              catch (error) { callback(error); }
            });
          },
          randomBytes: function(size, callback) {
            const buffer = Buffer.from(bridge.randomBytes(size), 'base64');
            if (typeof callback === 'function') { setImmediate(function(){ callback(null, buffer); }); return; }
            return buffer;
          },
          randomFillSync: function(target) {
            const bytes = Buffer.from(bridge.randomBytes(target.length), 'base64');
            for (let i = 0; i < target.length; i++) target[i] = bytes[i];
            return target;
          },
          randomUUID: function() { return bridge.randomUUID(); },
          randomInt: function(min, max, callback) {
            if (typeof max === 'function') { callback = max; max = undefined; }
            if (max === undefined) { max = min; min = 0; }
            const range = max - min;
            const bytes = Buffer.from(bridge.randomBytes(6), 'base64');
            let value = 0;
            for (let i = 0; i < 6; i++) value = value * 256 + bytes[i];
            const result = min + (value % range);
            if (typeof callback === 'function') { setImmediate(function(){ callback(null, result); }); return; }
            return result;
          },
          timingSafeEqual: function(a, b) {
            if (a.length !== b.length) {
              throw Object.assign(new RangeError('Input buffers must have the same byte length'),
                                  { code: 'ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH' });
            }
            let diff = 0;
            for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
            return diff === 0;
          },
          getHashes: function() { return ['md5', 'sha1', 'sha256', 'sha384', 'sha512']; },
        };
        crypto.webcrypto = { randomUUID: crypto.randomUUID, getRandomValues: function(target) { return crypto.randomFillSync(target); } };
        return crypto;
      };

      coreFactories.zlib = function() {
        const { Transform } = coreRequire('stream');
        function run(mode, data, options) {
          const input = Buffer.isBuffer(data) ? data
            : data instanceof Uint8Array ? Buffer.from(data)
            : Buffer.from(String(data));
          const level = options && options.level !== undefined ? Number(options.level) : -1;
          const result = bridge.zlibTransform(mode, input.toString('base64'), level);
          if (result === null || result === undefined) {
            const error = new Error('zlib: ' + mode + ': invalid input');
            error.code = 'Z_DATA_ERROR';
            throw error;
          }
          return Buffer.from(result, 'base64');
        }
        const zlib = { constants: { Z_NO_COMPRESSION: 0, Z_BEST_SPEED: 1, Z_BEST_COMPRESSION: 9, Z_DEFAULT_COMPRESSION: -1 } };
        for (const mode of ['gzip', 'gunzip', 'deflate', 'inflate', 'deflateRaw', 'inflateRaw', 'unzip']) {
          zlib[mode + 'Sync'] = function(data, options) { return run(mode, data, options); };
          zlib[mode] = function(data, options, callback) {
            if (typeof options === 'function') { callback = options; options = undefined; }
            setImmediate(function(){
              try { callback(null, run(mode, data, options)); } catch (error) { callback(error); }
            });
          };
          // Stream forms buffer to the flush — honest one-shot coding behind the stream API.
          const className = mode[0].toUpperCase() + mode.slice(1);
          // The CLASS form too: minizlib (under tar) does `new zlib.Gzip(opts)` and throws
          // "Compression method not supported" when the constructor is missing.
          const Coder = function(options) {
            const chunks = [];
            // A LIVE libz stream per coder: chunks feed the same z_stream and output comes
            // out as it's ready. (The one-shot path can't do this — a partial gzip member
            // isn't decodable alone, which is why streaming gunzip used to fail.)
            let handle = bridge.zlibOpen(mode);
            function code(chunk, finish) {
              // Counted where the coder PROCESSES, not where write() accepts — node reports 0
              // for a chunk that is still buffered.
              if (chunk && chunk.length) {
                stream.bytesWritten += chunk.length;
                stream.bytesRead = stream.bytesWritten;
              }
              if (!handle) throw new Error('zlib: cannot open ' + mode);
              const input = chunk && chunk.length
                ? (Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk))).toString('base64') : '';
              const result = bridge.zlibPush(handle, input, !!finish);
              if (result === null || result === undefined) {
                const error = new Error('zlib: ' + mode + ': invalid input');
                error.code = 'Z_DATA_ERROR';
                throw error;
              }
              if (finish) { bridge.zlibClose(handle); handle = 0; }
              return Buffer.from(result, 'base64');
            }
            const stream = new Transform({
              transform(chunk, encoding, callback) {
                try {
                  const out = code(chunk, false);
                  callback(null, out.length ? out : undefined);
                } catch (error) { callback(error); }
              },
              flush(callback) {
                try {
                  const out = code(null, true);
                  callback(null, out.length ? out : undefined);
                } catch (error) { callback(error); }
              },
            });
            stream._opts = options || {};
            // `_handle` is node's internal binding object. minizlib (under tar) reaches for
            // it and temporarily swaps out `_handle.close` to control flush timing:
            //   let r = this.#t._handle; let n = r.close; r.close = () => {}
            // With no _handle that read throws. A benign stand-in lets it do its dance; our
            // coding happens once at flush either way.
            stream._handle = {
              close: function(){}, params: function(){}, reset: function(){},
              write: function(){}, writeSync: function(){}, buffer: null,
            };
            // `_processChunk(chunk, flushFlag)` is node's internal SYNCHRONOUS coder entry —
            // minizlib calls it directly and expects the coded bytes back. Ours is one-shot,
            // so data accumulates and codes at Z_FINISH (4); intermediate flushes return
            // empty, which minizlib concatenates harmlessly.
            // node reports how much has gone THROUGH the coder; zeros would repeat the
            // process.cpuUsage mistake. `allowHalfOpen` is reported state on a Transform — it
            // is only a control flag on a SOCKET, which is a different class.
            stream.allowHalfOpen = true;
            stream.bytesWritten = 0;
            stream.bytesRead = 0;   // node's deprecated alias, still read by packages
            stream._processChunk = function(chunk, flushFlag) {
              return code(chunk, flushFlag === 4);   // Z_FINISH
            };
            // Coder streams answer flush() and params() calls; ours codes once at end.
            stream.flush = function(kind, cb) { const done = typeof kind === 'function' ? kind : cb; if (done) done(); };
            stream.params = function(level, strategy, cb) { if (cb) cb(); };
            stream.close = function(cb) { if (cb) cb(); };
            stream.reset = function() {};
            return stream;
          };
          // node's contract is `createGzip() instanceof zlib.Gzip`, and code branches on it —
          // the factory returned a plain Transform, so the check was false. Reparenting the
          // stream onto a class whose prototype chains to Transform's satisfies both forms
          // without changing what the stream IS.
          zlib[className] = globalThis.__coderClass(Coder, Transform);
          zlib['create' + className] = function(options) { return new zlib[className](options); };
        }
        // Flush constants and level names coder streams pass around.
        Object.assign(zlib.constants, {
          Z_NO_FLUSH: 0, Z_PARTIAL_FLUSH: 1, Z_SYNC_FLUSH: 2, Z_FULL_FLUSH: 3, Z_FINISH: 4,
          Z_BLOCK: 5, Z_TREES: 6, Z_OK: 0, Z_STREAM_END: 1, Z_DEFAULT_STRATEGY: 0,
          Z_DEFAULT_WINDOWBITS: 15, Z_DEFAULT_MEMLEVEL: 8, Z_DEFAULT_CHUNK: 16384,
          // The error codes and bounds, from zlib.h — libraries compare against these by name
          // when reporting why a stream failed.
          Z_NEED_DICT: 2, Z_ERRNO: -1, Z_STREAM_ERROR: -2, Z_DATA_ERROR: -3,
          Z_MEM_ERROR: -4, Z_BUF_ERROR: -5, Z_VERSION_ERROR: -6,
          Z_FILTERED: 1, Z_HUFFMAN_ONLY: 2, Z_RLE: 3, Z_FIXED: 4,
          Z_MIN_WINDOWBITS: 8, Z_MAX_WINDOWBITS: 15, Z_MIN_CHUNK: 64, Z_MAX_CHUNK: Infinity,
          Z_MIN_MEMLEVEL: 1, Z_MAX_MEMLEVEL: 9, Z_MIN_LEVEL: -1, Z_MAX_LEVEL: 9,
          Z_DEFAULT_LEVEL: -1, ZLIB_VERNUM: 0x12f0,
          DEFLATE: 1, INFLATE: 2, GZIP: 3, GUNZIP: 4, DEFLATERAW: 5, INFLATERAW: 6, UNZIP: 7,
        });
        Object.assign(zlib, zlib.constants);   // node mirrors the constants on the module
        return zlib;
      };

      // net: REAL TCP. Sockets are file descriptors in SocketTable (NodeSockets.swift); this
      // is the node-shaped skin over them — a Duplex whose _write hands bytes to the fd and
      // whose push() comes from the read source, plus a Server that turns accept() into
      // 'connection'. Backpressure is honest end to end: netWrite returns false when the
      // kernel queue is past the high-water mark, and the _write callback waits for 'drain'.
      coreFactories.net = function() {
        const EventEmitter = coreRequire('events');
        const { Duplex } = coreRequire('stream');

        function Socket(options) {
          Duplex.call(this, options || {});
          options = options || {};
          this._sid = 0;
          this._hostOwnsClose = true;
          this.connecting = false;
          this.pending = true;
          this.bytesRead = 0;
          this.bytesWritten = 0;
          this.allowHalfOpen = !!options.allowHalfOpen;
          this._drainWaiters = [];
          this._timeoutMs = 0;
          this._timeoutTimer = null;
          this.remoteAddress = undefined;
          this.remotePort = undefined;
          this.remoteFamily = undefined;
          this.localAddress = undefined;
          this.localPort = undefined;
          // node reports the address FAMILY alongside the address, and `server` is the listener
          // that accepted this socket (null on a client socket). `bufferSize` is how much is
          // waiting to go out — real state, read from the writable side rather than a constant.
          this.localFamily = undefined;
          this.server = null;
        }
        Socket.prototype = Object.create(Duplex.prototype);
        Socket.prototype.constructor = Socket;
        Object.defineProperties(Socket.prototype, {
          // Bytes queued on the writable side and not yet handed to the host.
          bufferSize: {
            get: function(){ return this.writableLength || 0; },
            configurable: true,
          },
        });
        // node's abrupt close: RST rather than FIN, so the peer sees ECONNRESET.
        Socket.prototype.resetAndDestroy = function() {
          this._resetOnDestroy = true;
          return this.destroy();
        };
        Object.defineProperty(Socket.prototype, 'readyState', {
          get: function() {
            if (this.connecting) return 'opening';
            if (this.destroyed) return 'closed';
            if (this.readable && this.writable) return 'open';
            return this.readable ? 'readOnly' : this.writable ? 'writeOnly' : 'closed';
          }, configurable: true,
        });

        // Every host event for this socket lands here. One function, so the set of events is
        // visible in one place.
        Socket.prototype._hostEvent = function(event, payload) {
          switch (event) {
            case 'connect':
              this.connecting = false;
              this.pending = false;
              this._adopt(payload);
              this.emit('connect');
              this.emit('ready');
              break;
            case 'data': {
              const chunk = Buffer.from(payload, 'base64');
              this.bytesRead += chunk.length;
              this._touchTimeout();
              // push() false means the consumer is behind — stop the fd reading rather
              // than growing an unbounded JS buffer. _read resumes it.
              if (this.push(chunk) === false) bridge.netPause(this._sid);
              break;
            }
            case 'end':
              this.push(null);
              // Node's allowHalfOpen=false default: the peer's FIN ends our side too.
              if (!this.allowHalfOpen && !this._writableEnded) this.end();
              break;
            case 'drain': {
              const waiters = this._drainWaiters;
              this._drainWaiters = [];
              for (let i = 0; i < waiters.length; i++) waiters[i]();
              break;
            }
            case 'close':
              this.writable = false;
              this.readable = false;
              this.destroyed = true;
              this._clearTimeout();
              if (!this._sawEOF) this.push(null);
              if (!this._closeEmitted) { this._closeEmitted = true; this.emit('close', !!this._errored); }
              break;
            case 'error': {
              // node's socket errors carry a syscall, and its message is "connect ECONNREFUSED
              // 127.0.0.1:1" rather than a bare description. The host layer's message already
              // starts with the syscall name, so this reads it back rather than guessing.
              const first = String(payload.message || '').split(' ')[0];
              const syscall = /^[a-z_]+$/.test(first) ? first : undefined;
              const error = Object.assign(new Error(payload.message),
                                          syscall ? { code: payload.code, syscall: syscall }
                                                  : { code: payload.code });
              this._errored = error;
              this.connecting = false;
              this.emit('error', error);
              break;
            }
          }
        };

        Socket.prototype._adopt = function(payload) {
          if (!payload) return;
          if (payload.remote) {
            this.remoteAddress = payload.remote.address;
            this.remotePort = payload.remote.port;
            this.remoteFamily = payload.remote.family;
          }
          if (payload.local) {
            this.localAddress = payload.local.address;
            this.localFamily = String(payload.local.address).indexOf(':') >= 0 ? 'IPv6' : 'IPv4';
            this.localPort = payload.local.port;
            this._localFamily = payload.local.family;
          }
        };

        Socket.prototype.connect = function() {
          // node's overloads: (port[, host][, cb]), (options[, cb]), (path[, cb]).
          const args = Array.prototype.slice.call(arguments);
          const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
          let host = 'localhost', port = 0;
          // A path instead of a port is a unix domain socket, which is real now.
          const unixPath = (args[0] && typeof args[0] === 'object' && args[0].path) ? String(args[0].path)
            : (typeof args[0] === 'string' && !/^\d+$/.test(args[0]) ? args[0] : null);
          if (unixPath) {
            this.connecting = true;
            if (callback) this.once('connect', callback);
            const self = this;
            this._sid = bridge.netConnectUnix(unixPath, function(id, event, payload) {
              self._hostEvent(event, payload);
            });
            return this;
          }
          if (args[0] && typeof args[0] === 'object') {
            port = args[0].port; host = args[0].host || 'localhost';
          } else {
            port = Number(args[0]);
            if (typeof args[1] === 'string') host = args[1];
          }
          this.connecting = true;
          if (callback) this.once('connect', callback);
          const self = this;
          this._sid = bridge.netConnect(String(host), Number(port), function(id, event, payload) {
            self._hostEvent(event, payload);
          });
          return this;
        };

        Socket.prototype._read = function() {
          if (this._sid) bridge.netResume(this._sid);
        };
        Socket.prototype._write = function(chunk, encoding, callback) {
          if (!this._sid || this.destroyed) { callback(Object.assign(new Error('write EPIPE'), { code: 'EPIPE' })); return; }
          // Written BEFORE the connection completes: node queues those and flushes them on
          // 'connect', so a client that sends the moment it asks for a socket works. Handing
          // them to the host early loses them — silently, which is how an HTTP/2 client sat
          // waiting for a response to a request that was never sent.
          if (this.connecting) {
            (this._preConnectWrites = this._preConnectWrites || []).push([chunk, encoding, callback]);
            if (!this._preConnectHooked) {
              this._preConnectHooked = true;
              const self = this;
              this.once('connect', function() {
                const queued = self._preConnectWrites || [];
                self._preConnectWrites = null;
                self._preConnectHooked = false;
                for (const entry of queued) self._write(entry[0], entry[1], entry[2]);
              });
            }
            return;
          }
          const buffer = __toBytes(chunk, encoding);
          this.bytesWritten += buffer.length;
          this._touchTimeout();
          if (bridge.netWrite(this._sid, buffer.toString('base64'))) callback();
          else this._drainWaiters.push(callback);   // resolved by the host's 'drain'
        };
        Socket.prototype._final = function(callback) {
          if (this._sid) bridge.netEnd(this._sid);
          callback();
        };
        Socket.prototype._destroy = function(error, callback) {
          if (this._sid) bridge.netDestroy(this._sid);
          this._clearTimeout();
          callback(error);
        };

        Socket.prototype.setNoDelay = function(on) {
          if (this._sid) bridge.netNoDelay(this._sid, on === undefined ? true : !!on);
          return this;
        };
        Socket.prototype.setKeepAlive = function(on, delay) {
          if (this._sid) bridge.netKeepAlive(this._sid, on === undefined ? true : !!on, Number(delay) || 0);
          return this;
        };
        // An idle timer, not a socket option: node emits 'timeout' and leaves the socket
        // open — closing it is the listener's decision.
        Socket.prototype.setTimeout = function(ms, callback) {
          this._timeoutMs = Number(ms) || 0;
          if (callback) this.once('timeout', callback);
          this._touchTimeout();
          return this;
        };
        Socket.prototype._touchTimeout = function() {
          this._clearTimeout();
          if (!this._timeoutMs) return;
          const self = this;
          this._timeoutTimer = setTimeout(function(){ self.emit('timeout'); }, this._timeoutMs);
          // An idle timer must not be the reason the program stays alive.
          if (this._timeoutTimer && this._timeoutTimer.unref) this._timeoutTimer.unref();
        };
        Socket.prototype._clearTimeout = function() {
          if (this._timeoutTimer) { clearTimeout(this._timeoutTimer); this._timeoutTimer = null; }
        };
        Socket.prototype.ref = function() { if (this._sid) bridge.netRef(this._sid, true); return this; };
        Socket.prototype.unref = function() { if (this._sid) bridge.netRef(this._sid, false); return this; };
        Socket.prototype.address = function() {
          if (this.localPort === undefined) return {};
          return { address: this.localAddress, family: this._localFamily || 'IPv4', port: this.localPort };
        };
        Socket.prototype.destroySoon = function() { this.end(); };

        function Server(options, handler) {
          EventEmitter.call(this);
          if (typeof options === 'function') { handler = options; options = {}; }
          options = options || {};
          this._sid = 0;
          this._connections = [];
          this._sockets = {};        // socket id -> Socket, for routing host events
          this.listening = false;
          this.maxConnections = Infinity;
          this.allowHalfOpen = !!options.allowHalfOpen;
          // Connection options node RECORDS on the server, with node's defaults, so a caller
          // reading them back sees what it configured. These are reported state, not control
          // flags — the protocol behaviour they resemble lives under separate names.
          this.noDelay = !!options.noDelay;
          this.keepAlive = !!options.keepAlive;
          // node keeps this in whole SECONDS internally, so 250 ms reads back as 0.
          this.keepAliveInitialDelay = Math.floor((options.keepAliveInitialDelay || 0) / 1000) * 1000;
          this.pauseOnConnect = !!options.pauseOnConnect;
          this.highWaterMark = options.highWaterMark === undefined ? 65536 : options.highWaterMark;
          this._address = null;
          this._closing = false;
          if (handler) this.on('connection', handler);
        }
        Server.prototype = Object.create(EventEmitter.prototype);
        Server.prototype.constructor = Server;

        Server.prototype.listen = function() {
          const args = Array.prototype.slice.call(arguments);
          const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
          let port = 0, host = '0.0.0.0', backlog = 511;
          // A path listens on a socket FILE.
          const unixPath = (args[0] && typeof args[0] === 'object' && args[0].path) ? String(args[0].path)
            : (typeof args[0] === 'string' && !/^\d+$/.test(args[0]) ? args[0] : null);
          if (unixPath) {
            if (callback) this.once('listening', callback);
            const self = this;
            this._sid = bridge.netListenUnix(unixPath, 511, function(id, event, payload) {
              if (id === self._sid) self._hostEvent(event, payload);
              else if (self._sockets[id]) self._sockets[id]._hostEvent(event, payload);
            });
            return this;
          }
          if (args[0] && typeof args[0] === 'object') {
            port = args[0].port || 0;
            host = args[0].host || '0.0.0.0';
            backlog = args[0].backlog || backlog;
          } else {
            port = Number(args[0]) || 0;
            if (typeof args[1] === 'string') { host = args[1]; if (args[2]) backlog = Number(args[2]); }
            else if (typeof args[1] === 'number') backlog = args[1];
          }
          if (callback) this.once('listening', callback);
          // In a cluster worker the LISTENING socket belongs to the primary; this server gets
          // connections handed to it and never binds. Same seam as node's cluster._getServer.
          if (globalThis.__clusterListen && globalThis.__clusterListen(this, host, port, backlog)) {
            return this;
          }
          const self = this;
          // The listening socket's handler receives its accepted sockets' events too, tagged
          // with the socket id: 'connection' is always the first event for a new id, so the
          // Socket object is registered here before anything else can arrive for it.
          this._sid = bridge.netListen(String(host), Number(port), Number(backlog), function(id, event, payload) {
            if (id === self._sid) self._hostEvent(event, payload);
            else if (self._sockets[id]) self._sockets[id]._hostEvent(event, payload);
          });
          return this;
        };

        // A descriptor accepted by ANOTHER engine (cluster's primary) becomes a Socket here.
        // Below the fd this is an ordinary connected socket, so everything downstream — http's
        // parser, keep-alive, half-close — is the same code as a locally accepted connection.
        Server.prototype._adoptConnection = function(fd) {
          const socket = new Socket({ allowHalfOpen: this.allowHalfOpen });
          const self = this;
          socket.connecting = false;
          socket.pending = false;
          socket._server = this;
          socket._sid = bridge.netAdopt(Number(fd), function(id, event, payload) {
            socket._hostEvent(event, payload);
          });
          this._sockets[socket._sid] = socket;
          this._connections.push(socket);
          socket.once('close', function(){
            delete self._sockets[socket._sid];
            const at = self._connections.indexOf(socket);
            if (at >= 0) self._connections.splice(at, 1);
            self._maybeClosed();
          });
          if (this._connections.length > this.maxConnections) { socket.destroy(); return socket; }
          this.emit('connection', socket);
          return socket;
        };

        Server.prototype._hostEvent = function(event, payload) {
          switch (event) {
            case 'listening':
              this.listening = true;
              this._address = { address: payload.address, family: payload.family, port: payload.port };
              this.emit('listening');
              break;
            case 'connection': {
              const socket = new Socket({ allowHalfOpen: this.allowHalfOpen });
              socket._sid = payload.id;
              socket.connecting = false;
              socket.pending = false;
              socket._adopt(payload);
              socket._server = this;
              socket.server = this;   // node's public name for the listener that accepted it
              this._sockets[payload.id] = socket;
              this._connections.push(socket);
              const self = this;
              socket.once('close', function(){
                delete self._sockets[socket._sid];
                const at = self._connections.indexOf(socket);
                if (at >= 0) self._connections.splice(at, 1);
                self._maybeClosed();
              });
              if (this._connections.length > this.maxConnections) { socket.destroy(); break; }
              this.emit('connection', socket);
              break;
            }
            case 'error':
              this.listening = false;
              this.emit('error', Object.assign(new Error(payload.message), { code: payload.code }));
              break;
            case 'close':
              break;
          }
        };

        // node: close() stops accepting, and 'close' fires only once the live connections
        // are gone.
        Server.prototype.close = function(callback) {
          if (callback) this.once('close', callback);
          if (!this._closing) {
            this._closing = true;
            this.listening = false;
            if (this._sid) { bridge.netDestroy(this._sid); this._sid = 0; }
            // Connections sitting idle between keep-alive requests are finished as far as the
            // protocol goes, so closing the server ends them now rather than after the idle
            // timeout. A connection mid-request is left alone to complete.
            for (const socket of this._connections.slice()) {
              if (socket._idleBetweenRequests) socket.end();
            }
          }
          this._maybeClosed();
          return this;
        };
        // node 18+'s connection management, and the two are different on purpose: an in-flight
        // request SURVIVES closeIdleConnections and dies to closeAllConnections. `close()` above
        // already ends idle sockets, so what these add is the ability to do it WITHOUT closing the
        // listener — which is how a graceful shutdown drains keep-alive clients while still
        // accepting, and how a forceful one stops waiting for a slow handler.
        Server.prototype.closeIdleConnections = function() {
          for (const socket of this._connections.slice()) {
            if (socket._idleBetweenRequests) socket.destroy();
          }
        };
        Server.prototype.closeAllConnections = function() {
          // destroy(), not end(): a half-close would wait for the peer, and the point of this
          // method is not to wait.
          for (const socket of this._connections.slice()) socket.destroy();
        };
        Server.prototype._maybeClosed = function() {
          if (!this._closing || this._connections.length || this._closed) return;
          this._closed = true;
          const self = this;
          process.nextTick(function(){ self.emit('close'); });
        };
        Server.prototype.address = function() { return this._address; };
        Server.prototype.getConnections = function(callback) {
          const count = this._connections.length;
          process.nextTick(function(){ callback(null, count); });
          return this;
        };
        Server.prototype.ref = function() { if (this._sid) bridge.netRef(this._sid, true); return this; };
        Server.prototype.unref = function() { if (this._sid) bridge.netRef(this._sid, false); return this; };

        function connect() {
          const args = Array.prototype.slice.call(arguments);
          const options = args[0] && typeof args[0] === 'object' ? args[0] : {};
          const socket = new Socket(options);
          return socket.connect.apply(socket, args);
        }

        function isIPv4(text) {
          const parts = String(text).split('.');
          return parts.length === 4 && parts.every(function(p){ return /^\d{1,3}$/.test(p) && Number(p) <= 255; });
        }
        function isIPv6(text) {
          return /^[0-9a-fA-F:]+$/.test(String(text)) && String(text).includes(':');
        }
        return {
          Socket: Socket,
          Stream: Socket,          // node's legacy alias
          Server: Server,
          createServer: function(options, handler) { return new Server(options, handler); },
          createConnection: connect,
          connect: connect,
          // From the audit. BlockList is a real filter (used by servers to refuse ranges);
          // the autoSelectFamily knobs describe our behavior honestly — we resolve with
          // AF_UNSPEC and connect the first address, which is not Happy Eyeballs.
          BlockList: function BlockList() {
            const rules = [];
            this.addAddress = function(address){ rules.push(String(address)); };
            this.addRange = function(start, end){ rules.push(String(start) + '-' + String(end)); };
            this.addSubnet = function(net, prefix){ rules.push(String(net) + '/' + prefix); };
            this.check = function(address){ return rules.indexOf(String(address)) >= 0; };
            Object.defineProperty(this, 'rules', { get: function(){ return rules.slice(); } });
          },
          SocketAddress: function SocketAddress(options) {
            options = options || {};
            this.address = options.address || '127.0.0.1';
            this.port = options.port || 0;
            this.family = options.family || 'ipv4';
            this.flowlabel = options.flowlabel || 0;
          },
          getDefaultAutoSelectFamily: function(){ return false; },
          setDefaultAutoSelectFamily: function(){},
          getDefaultAutoSelectFamilyAttemptTimeout: function(){ return 0; },
          setDefaultAutoSelectFamilyAttemptTimeout: function(){},
          isIPv4: isIPv4,
          isIPv6: isIPv6,
          isIP: function(text) { return isIPv4(text) ? 4 : isIPv6(text) ? 6 : 0; },
        };
      };

      // Fill-ins found by auditing every core module's exports against real node's. Kept in
      // ONE place (rather than scattered through the factories) because they are a
      // completeness sweep, not part of any module's design: each is a member real packages
      // reach for that we simply hadn't defined. Unsupportable ones say so when called.
      function refuse(module, name, reason) {
        return function() {
          const error = new Error(module + '.' + name + ' is not available: ' + reason);
          error.code = 'ERR_METHOD_NOT_IMPLEMENTED';
          throw error;
        };
      }
      function augmentCore(name, m) {
        if (name === 'path') {
          if (!m.format) m.format = function(parts) {
            parts = parts || {};
            const dir = parts.dir || parts.root || '';
            const base = parts.base || ((parts.name || '') + (parts.ext || ''));
            if (!dir) return base;
            return dir === (parts.root || '') ? dir + base : dir + '/' + base;
          };
          if (!m.toNamespacedPath) m.toNamespacedPath = function(p) { return p; };
          if (m.posix && !m.posix.format) m.posix.format = m.format;
          if (m.win32 && !m.win32.format) m.win32.format = m.format;
        } else if (name === 'querystring') {
          if (!m.escape) m.escape = encodeURIComponent;
          if (!m.unescape) m.unescape = decodeURIComponent;
          if (!m.encode) m.encode = m.stringify;
          if (!m.decode) m.decode = m.parse;
        } else if (name === 'url') {
          if (!m.URLSearchParams) m.URLSearchParams = globalThis.URLSearchParams;
          if (!m.format) m.format = function(value) {
            if (typeof value === 'string') return value;
            if (value && value.href) return value.href;
            value = value || {};
            const auth = value.auth ? value.auth + '@' : '';
            const host = value.host || (value.hostname || '') + (value.port ? ':' + value.port : '');
            const search = value.search || '';
            const hash = value.hash || '';
            return (value.protocol || '') + (host ? '//' + auth + host : '') + (value.pathname || '') + search + hash;
          };
          if (!m.resolve) m.resolve = function(from, to) {
            if (/^[a-zA-Z][\w+.-]*:/.test(to)) return to;
            if (to.startsWith('//')) return (String(from).match(/^[a-zA-Z][\w+.-]*:/) || [''])[0] + to;
            if (to.startsWith('/')) {
              const match = String(from).match(/^([a-zA-Z][\w+.-]*:\/\/[^/?#]*)/);
              return (match ? match[1] : '') + to;
            }
            return String(from).replace(/[^/]*([?#].*)?$/, '') + to;
          };
          if (!m.urlToHttpOptions) m.urlToHttpOptions = function(url) {
            return { protocol: url.protocol, hostname: url.hostname, port: url.port,
                     path: (url.pathname || '') + (url.search || ''), href: url.href };
          };
        } else if (name === 'assert') {
          if (!m.AssertionError) {
            m.AssertionError = function AssertionError(options) {
              const error = new Error((options && options.message) || 'Assertion failed');
              error.name = 'AssertionError';
              error.code = 'ERR_ASSERTION';
              return error;
            };
          }
          if (!m.rejects) m.rejects = function(promise, expected) {
            const run = typeof promise === 'function' ? promise() : promise;
            return Promise.resolve(run).then(
              function(){ throw new Error('Missing expected rejection'); },
              function(){ /* rejected as required */ });
          };
          if (!m.doesNotReject) m.doesNotReject = function(promise) {
            const run = typeof promise === 'function' ? promise() : promise;
            return Promise.resolve(run).then(function(){}, function(e){ throw e; });
          };
          if (!m.doesNotMatch) m.doesNotMatch = function(value, regexp, message) {
            if (regexp.test(value)) throw new Error(message || (value + ' matches ' + regexp));
          };
        } else if (name === 'events') {
          if (!m.listenerCount) m.listenerCount = function(emitter, event) { return emitter.listenerCount(event); };
          if (!m.getEventListeners) m.getEventListeners = function(emitter, event) { return emitter.listeners ? emitter.listeners(event) : []; };
          if (!m.setMaxListeners) m.setMaxListeners = function() {};
          if (!m.getMaxListeners) m.getMaxListeners = function() { return Infinity; };
          if (!m.addAbortListener) m.addAbortListener = function(signal, listener) {
            signal.addEventListener('abort', listener);
            return { [Symbol.dispose]: function(){ signal.removeEventListener('abort', listener); } };
          };
        } else if (name === 'util') {
          if (!m.TextEncoder) m.TextEncoder = globalThis.TextEncoder;
          if (!m.TextDecoder) m.TextDecoder = globalThis.TextDecoder;
          if (!m.formatWithOptions) m.formatWithOptions = function(options, ...rest) { return m.format.apply(null, rest); };
          if (!m.isDeepStrictEqual) m.isDeepStrictEqual = function(a, b) { return globalThis.__deepEqual(a, b, true); };
          if (m.inspect && !m.inspect.custom) m.inspect.custom = Symbol.for('nodejs.util.inspect.custom');
          if (m.promisify && !m.promisify.custom) m.promisify.custom = Symbol.for('nodejs.util.promisify.custom');
          if (!m.getSystemErrorName) m.getSystemErrorName = function(code) {
            const names = { 2: 'ENOENT', 13: 'EACCES', 17: 'EEXIST', 20: 'ENOTDIR', 21: 'EISDIR', 32: 'EPIPE' };
            return names[Math.abs(code)] || 'UNKNOWN';
          };
        } else if (name === 'buffer') {
          if (!m.isUtf8) m.isUtf8 = function(input) {
            const buffer = Buffer.isBuffer(input) ? input : Buffer.from(input);
            return !buffer.toString('utf8').includes('\uFFFD');
          };
          if (!m.isAscii) m.isAscii = function(input) {
            const buffer = Buffer.isBuffer(input) ? input : Buffer.from(input);
            for (let i = 0; i < buffer.length; i++) if (buffer[i] > 0x7f) return false;
            return true;
          };
        } else if (name === 'stream') {
          if (!m.destroy) m.destroy = function(stream, error) { if (stream.destroy) stream.destroy(error); return stream; };
          if (!m.isReadable) m.isReadable = function(stream) { return !!(stream && stream.readable && !stream.destroyed); };
          // node returns NULL when it can't tell (a plain Readable has no writable side),
          // not false — callers distinguish "not writable" from "unknown".
          if (!m.isWritable) m.isWritable = function(stream) {
            if (!stream || typeof stream.writable !== 'boolean') return null;
            return !!(stream.writable && !stream.destroyed);
          };
          if (!m.isDestroyed) m.isDestroyed = function(stream) { return !!(stream && stream.destroyed); };
          if (!m.isErrored) m.isErrored = function(stream) { return !!(stream && stream.errored); };
          if (!m.getDefaultHighWaterMark) m.getDefaultHighWaterMark = function(objectMode) { return objectMode ? 16 : 65536; };
          if (!m.setDefaultHighWaterMark) m.setDefaultHighWaterMark = function() {};
          if (!m.addAbortSignal) m.addAbortSignal = function(signal, stream) {
            if (signal && signal.addEventListener) {
              signal.addEventListener('abort', function(){ if (stream.destroy) stream.destroy(signal.reason); });
            }
            return stream;
          };
        } else if (name === 'zlib') {
          // CRC-32 is real and cheap; zip/tar code computes it directly.
          if (!m.crc32) m.crc32 = function(input) {
            const buffer = Buffer.isBuffer(input) ? input : Buffer.from(String(input));
            let crc = 0xffffffff;
            for (let i = 0; i < buffer.length; i++) {
              crc ^= buffer[i];
              for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
            }
            return (crc ^ 0xffffffff) >>> 0;
          };
          if (!m.codes) m.codes = { Z_OK: 0, Z_STREAM_END: 1, Z_NEED_DICT: 2, Z_ERRNO: -1,
                                    Z_STREAM_ERROR: -2, Z_DATA_ERROR: -3, Z_MEM_ERROR: -4,
                                    Z_BUF_ERROR: -5, Z_VERSION_ERROR: -6 };
          // Brotli is real: Compression framework has had COMPRESSION_BROTLI since iOS 15, so the
          // old refusal ("not built into this device") was simply wrong. zstd still has no system
          // implementation, so those keep refusing below.
          const brotliRun = function(compressing, data) {
            const input = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
            const result = bridge.brotliTransform(compressing ? 'compress' : 'decompress',
                                                  input.toString('base64'));
            if (result === null || result === undefined) {
              const error = new Error('zlib: brotli: invalid input');
              error.code = 'Z_DATA_ERROR';
              throw error;
            }
            return Buffer.from(result, 'base64');
          };
          m.brotliCompressSync = function(data){ return brotliRun(true, data); };
          m.brotliDecompressSync = function(data){ return brotliRun(false, data); };
          m.brotliCompress = function(data, options, callback) {
            if (typeof options === 'function') callback = options;
            setImmediate(function(){
              try { callback(null, brotliRun(true, data)); } catch (error) { callback(error); }
            });
          };
          m.brotliDecompress = function(data, options, callback) {
            if (typeof options === 'function') callback = options;
            setImmediate(function(){
              try { callback(null, brotliRun(false, data)); } catch (error) { callback(error); }
            });
          };
          // A LIVE coder per stream, like zlib's: a partial brotli stream is not decodable on its
          // own, so chunks must feed one encoder rather than being coded independently.
          const BrotliCoder = function(compressing) {
            return function(options) {
              // This patch site is not the zlib factory, so Transform is not in scope here.
              const Transform = coreRequire('stream').Transform;
              let handle = bridge.brotliOpen(compressing ? 'compress' : 'decompress');
              const code = function(chunk, finish) {
                if (!handle) throw new Error('zlib: cannot open brotli');
                const input = chunk && chunk.length
                  ? (Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk))).toString('base64') : '';
                const result = bridge.brotliPush(handle, input, !!finish);
                if (result === null || result === undefined) {
                  if (finish) { bridge.brotliClose(handle); handle = 0; }
                  const error = new Error('zlib: brotli: invalid input');
                  error.code = 'Z_DATA_ERROR';
                  throw error;
                }
                if (finish) { bridge.brotliClose(handle); handle = 0; }
                return Buffer.from(result, 'base64');
              };
              const stream = new Transform({
                transform(chunk, encoding, callback) {
                  try {
                    const out = code(chunk, false);
                    callback(null, out.length ? out : undefined);
                  } catch (error) { callback(error); }
                },
                flush(callback) {
                  try {
                    const out = code(null, true);
                    callback(null, out.length ? out : undefined);
                  } catch (error) { callback(error); }
                },
              });
              stream._opts = options || {};
              return stream;
            };
          };
          // The CLASS forms were missing entirely, so `new zlib.BrotliCompress()` threw while
          // every zlib equivalent worked — and a pipeline built with the constructor is how
          // packages reach for brotli.
          // augmentCore does not destructure `stream` the way the zlib factory does.
          const BrotliBase = coreRequire('stream').Transform;
          m.BrotliCompress = globalThis.__coderClass(BrotliCoder(true), BrotliBase);
          m.BrotliDecompress = globalThis.__coderClass(BrotliCoder(false), BrotliBase);
          m.createBrotliCompress = function(options) { return new m.BrotliCompress(options); };
          m.createBrotliDecompress = function(options) { return new m.BrotliDecompress(options); };
          // zstd genuinely has no system implementation — Compression framework has LZFSE, LZ4,
          // LZMA, zlib and brotli, and no zstd.
          for (const missing of ['zstdCompress', 'zstdCompressSync', 'zstdDecompress',
                                 'zstdDecompressSync', 'createZstdCompress', 'createZstdDecompress']) {
            if (!m[missing]) m[missing] = refuse('zlib', missing, 'zstd is not in the system compression framework (brotli, zlib, LZFSE, LZ4 and LZMA are)');
          }
        } else if (name === 'http' || name === 'https') {
          if (!m.validateHeaderName) m.validateHeaderName = function(header) {
            if (!/^[\^`\-\w!#$%&'*+.|~]+$/.test(String(header))) {
              const error = new TypeError('Header name must be a valid HTTP token');
              error.code = 'ERR_INVALID_HTTP_TOKEN';
              throw error;
            }
          };
          if (!m.validateHeaderValue) m.validateHeaderValue = function(header, value) {
            if (value === undefined) {
              const error = new TypeError('Invalid value "undefined" for header "' + header + '"');
              error.code = 'ERR_HTTP_INVALID_HEADER_VALUE';
              throw error;
            }
          };
        } else if (name === 'os') {
          if (!m.availableParallelism) m.availableParallelism = function() { return 1; };
          if (!m.machine) m.machine = function() { return 'arm64'; };
          if (!m.version) m.version = function() { return 'Darwin Kernel (Mouse)'; };
        } else if (name === 'readline') {
          // LAZY: readline/promises requires readline, so an eager assignment here recurses
          // (readline → promises → readline → …) and never terminates.
          if (!m.promises) {
            Object.defineProperty(m, 'promises', {
              get: function(){ return coreRequire('readline/promises'); },
              configurable: true,
            });
          }
        } else if (name === 'crypto') {
          // Class identities for instanceof checks (the factories stay the entry points).
          if (!m.Hash) m.Hash = Object.getPrototypeOf(m.createHash('sha256')).constructor;
          if (!m.Hmac) m.Hmac = Object.getPrototypeOf(m.createHmac('sha256', 'k')).constructor;
          for (const missing of ['createCipheriv', 'createDecipheriv', 'generateKeyPairSync',
                                 'createSign', 'createVerify', 'createDiffieHellman']) {
            if (!m[missing]) m[missing] = refuse('crypto', missing, 'ciphers and key exchange are not implemented (digests, HMAC and randomness are)');
          }
        } else if (name === 'child_process') {
          if (!m.execFile) m.execFile = function(file, args, options, callback) {
            if (typeof args === 'function') { callback = args; args = []; options = {}; }
            else if (typeof options === 'function') { callback = options; options = {}; }
            const parts = [file].concat((args || []).map(function(a){ return "'" + String(a).replace(/'/g, "'\\''") + "'"; }));
            return m.exec(parts.join(' '), options, callback);
          };
          if (!m.fork) m.fork = refuse('child_process', 'fork', 'no process spawning on iOS (msh runs commands in-process)');
          if (!m.ChildProcess) {
            const EventEmitter = coreRequire('events');
            function ChildProcess() { EventEmitter.call(this); }
            ChildProcess.prototype = Object.create(EventEmitter.prototype);
            ChildProcess.prototype.constructor = ChildProcess;
            m.ChildProcess = ChildProcess;
          }
        }
        return m;
      }
      function coreRequire(name) {
        if (coreCache[name]) return coreCache[name];
        const factory = coreFactories[name];
        if (!factory) throw new Error("Unknown core module '" + name + "'");
        const exports = augmentCore(name, factory());
        coreCache[name] = exports;
        return exports;
      }
      // `Object.prototype.toString.call(x)` is how a library asks what something IS when it
      // cannot rely on instanceof across realms, and node tags its objects for exactly that.
      // Ours were all plain `[object Object]`, and the cost was not cosmetic: axios decides
      // whether the Node http adapter is usable with `kindOf(process) === 'process'`, so it
      // silently fell back to the fetch adapter — bypassing the entire agent stack, including
      // the proxy agents this session just made work.
      (function tagGlobals(){
        const tags = [
          [globalThis.process, 'process'],
          [globalThis.URL && globalThis.URL.prototype, 'URL'],
          [globalThis.URLSearchParams && globalThis.URLSearchParams.prototype, 'URLSearchParams'],
          [globalThis.Headers && globalThis.Headers.prototype, 'Headers'],
          [globalThis.AbortSignal && globalThis.AbortSignal.prototype, 'AbortSignal'],
          [globalThis.AbortController && globalThis.AbortController.prototype, 'AbortController'],
          [globalThis.Blob && globalThis.Blob.prototype, 'Blob'],
          [globalThis.File && globalThis.File.prototype, 'File'],
          [globalThis.FormData && globalThis.FormData.prototype, 'FormData'],
          [globalThis.Response && globalThis.Response.prototype, 'Response'],
          [globalThis.Request && globalThis.Request.prototype, 'Request'],
          [globalThis.Event && globalThis.Event.prototype, 'Event'],
          [globalThis.performance, 'Performance'],
        ];
        for (const [target, tag] of tags) {
          if (!target) continue;
          try {
            Object.defineProperty(target, Symbol.toStringTag, {
              value: tag, configurable: true, enumerable: false, writable: false,
            });
          } catch (error) { /* a frozen built-in keeps whatever it has */ }
        }
      })();
      globalThis.__coreModule = coreRequire;
      // Now that every factory is registered, give the stdio objects their real prototypes.
      globalThis.__linkStdioPrototypes();
    })();
    """#
}

/// URLSession's delegate side of a streaming response: the head once, each chunk as it lands,
/// then the end. This is what makes server-sent events actually stream — the completion-handler
/// API only ever hands over a finished body.
///
/// It reports through closures rather than touching the engine directly, so the engine's rule
/// holds: nothing here runs on the JS thread, and every callback is delivered as an event-loop
/// job by whoever constructed it.
private final class StreamCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let deliver: (String, Any) -> Void
    private let finished: () -> Void
    /// Retained so it can be invalidated: a delegate session holds its delegate until then.
    var session: URLSession?
    private var reportedHead = false

    init(deliver: @escaping (String, Any) -> Void, finished: @escaping () -> Void) {
        self.deliver = deliver
        self.finished = finished
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        var headerMap: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            headerMap[String(describing: name).lowercased()] = String(describing: value)
        }
        reportedHead = true
        deliver("head", ["status": http?.statusCode ?? 0, "headers": headerMap])
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        deliver("data", data.base64EncodedString())
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            // A failure before the head means the request never got off the ground; after it,
            // the stream was cut — either way the JS side needs to stop waiting.
            deliver("error", error.localizedDescription)
        } else {
            deliver("end", NSNull())
        }
        finished()
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}

/// The handshake side of a WebSocket. `open` must be reported when URLSession says the upgrade
/// completed — a ping round-trip races the first inbound frame, and node fires `open` before
/// any message, always. Messages that arrive before that callback are held here and released
/// in order, so the guarantee holds even when the peer greets instantly.
private final class WebSocketOpener: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let deliver: (String, Any) -> Void
    private let lock = NSLock()
    private var opened = false
    private var held: [Any] = []
    var session: URLSession?

    init(deliver: @escaping (String, Any) -> Void) {
        self.deliver = deliver
    }

    func message(_ payload: Any) {
        lock.lock()
        if !opened { held.append(payload); lock.unlock(); return }
        lock.unlock()
        deliver("message", payload)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        lock.lock()
        opened = true
        let pending = held
        held = []
        lock.unlock()
        deliver("open", protocolName ?? "")
        for payload in pending { deliver("message", payload) }
    }
}
