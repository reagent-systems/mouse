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
/// microtask queue). `http`/`net` and `child_process` are stubs that say what's missing.
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
        context = JSContext()!
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
        context.evaluateScript(Self.bootstrap)

        let dir = virtualDirname(path)
        let entryIsESM = isESModule(id: normalize(path), source: source)
        if entryIsESM {
            source = Self.transpileESM(source)
        } else if source.contains("import") {
            source = Self.rewriteDynamicImport(source)
        }
        if let function = wrapModule(source, async: entryIsESM) {
            let module = context.evaluateScript("({exports: {}})")!
            let require = makeRequire(fromDir: dir)
            if entryIsESM {
                // The entry may hold a real top-level await (directly or through an import).
                // The event loop drives it; settle/reject arrives as a microtask.
                let entrySettled: @convention(block) (JSValue?) -> Void = { [weak self] error in
                    guard let self else { return }
                    self.entryPending = false
                    if let error, !error.isUndefined, !error.isNull, self.exitCode == nil {
                        let text = error.toString() ?? "unknown error"
                        let stack = error.forProperty("stack")?.toString() ?? text
                        self.err += (stack.contains(text) ? stack : text + "\n" + stack) + "\n"
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
                err += fatal.hasSuffix("\n") ? fatal : fatal + "\n"
                exitCode = 1
            }
        }

        runEventLoop()

        return Result(out: out, err: err, status: exitCode ?? 0)
    }

    private func wrapModule(_ source: String, async: Bool = false) -> JSValue? {
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
        let wrapped = "(\(keyword)(exports, require, module, __filename, __dirname, __mouseRequire, __mouseFilename){\n" + body + "\n})"
        let function = context.evaluateScript(wrapped)
        guard let function, function.isObject else { return nil }
        return function
    }


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

            if !immediates.isEmpty {
                let batch = immediates
                immediates = []
                for (callback, arguments) in batch {
                    guard exitCode == nil else { break }
                    callback.call(withArguments: arguments)
                }
                continue
            }

            let next = timers.min(by: { $0.due < $1.due })
            if next == nil, outstanding == 0, !stdinActive {
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
                next.callback.call(withArguments: next.arguments)
            } else {
                // Only in-flight I/O remains: sleep until a completion signals.
                _ = wakeup.wait(timeout: .now() + 60)
            }
        }
        drainTicks()
    }

    private func drainTicks() {
        guard exitCode == nil else { return }
        context.evaluateScript("globalThis.__drainTicks && globalThis.__drainTicks()")
    }

    // MARK: - Native bridge

    private func installNativeBridge(argv: [String], cwd: String, stdin: String) {
        let bridge = JSValue(newObjectIn: context)!

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
        let statFile: @convention(block) (String) -> Any = { [weak self] path in
            guard let self else { return NSNull() }
            let url = self.realURL(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return NSNull() }
            let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.doubleValue ?? 0
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return ["dir": isDirectory.boolValue, "size": size, "mtimeMs": mtime * 1000] as [String: Any]
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
            case .notFound(let message): return ["kind": "error", "message": message]
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
        expose("shellExec", shellExec)

        // -- HTTP over URLSession: fire on any thread, complete as an event-loop job --
        let httpRequest: @convention(block) (String, String, [String: String], String, JSValue) -> Void = { [weak self] urlText, method, headers, bodyBase64, callback in
            guard let self else { return }
            guard let url = URL(string: urlText) else {
                self.enqueueJob { callback.call(withArguments: [["error": "invalid URL: \(urlText)"]]) }
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if !bodyBase64.isEmpty { request.httpBody = Data(base64Encoded: bodyBase64) }
            self.outstanding += 1
            URLSession.shared.dataTask(with: request) { data, response, error in
                self.enqueueJob {
                    self.outstanding -= 1
                    if let error {
                        callback.call(withArguments: [["error": error.localizedDescription]])
                        return
                    }
                    let http = response as? HTTPURLResponse
                    var headerMap: [String: String] = [:]
                    for (name, value) in http?.allHeaderFields ?? [:] {
                        headerMap[String(describing: name).lowercased()] = String(describing: value)
                    }
                    callback.call(withArguments: [[
                        "status": http?.statusCode ?? 0,
                        "headers": headerMap,
                        "body": (data ?? Data()).base64EncodedString(),
                    ]])
                }
            }.resume()
        }
        expose("httpRequest", httpRequest)

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
        let zlibTransform: @convention(block) (String, String) -> String? = { mode, base64 in
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
            return Self.zlibCode(input, deflating: deflating, windowBits: windowBits)?.base64EncodedString()
        }
        expose("zlibTransform", zlibTransform)
        let createRequireBlock: @convention(block) (String) -> Any = { [weak self] fromPath in
            guard let self else { return NSNull() }
            var from = fromPath
            if from.hasPrefix("file://") { from = String(from.dropFirst(7)) }
            return self.makeRequire(fromDir: self.virtualDirname(self.normalize(from)))
        }
        expose("createRequire", createRequireBlock)

        context.setObject(bridge, forKeyedSubscript: "__mouse" as NSString)
        context.setObject(argv, forKeyedSubscript: "__argv" as NSString)
        context.setObject(env, forKeyedSubscript: "__env" as NSString)
        context.setObject(cwd, forKeyedSubscript: "__cwd" as NSString)
        context.setObject(stdin, forKeyedSubscript: "__stdin" as NSString)
        context.setObject(tty != nil, forKeyedSubscript: "__isTTY" as NSString)
        context.setObject(tty?.rows ?? 24, forKeyedSubscript: "__ttyRows" as NSString)
        context.setObject(tty?.columns ?? 80, forKeyedSubscript: "__ttyColumns" as NSString)
    }

    /// One-shot deflate or inflate with explicit windowBits (15=zlib, 15+16=gzip, -15=raw,
    /// 15+32=auto-detect on inflate). libz, not Compression — same reason as GitCore.
    private static func zlibCode(_ input: Data, deflating: Bool, windowBits: Int32) -> Data? {
        var stream = z_stream()
        let streamSize = Int32(MemoryLayout<z_stream>.size)
        let initStatus = deflating
            ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, zlibVersion(), streamSize)
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
    }

    static let coreModules: Set<String> = [
        "fs", "path", "os", "util", "events", "buffer", "tty", "assert", "url",
        "child_process", "http", "https", "net", "crypto", "stream", "zlib",
        "readline", "readline/promises", "string_decoder", "constants", "querystring",
        "fs/promises", "stream/promises", "process", "module", "timers", "timers/promises",
        "path/posix", "path/win32", "http2", "tls", "dns", "worker_threads", "async_hooks",
        "v8", "vm", "perf_hooks", "inspector", "dgram", "cluster", "diagnostics_channel",
        "console", "util/types", "domain",
    ]

    private func resolveModule(_ rawRequest: String, fromDir: String) -> Resolution {
        var request = rawRequest
        if request.hasPrefix("node:") { request = String(request.dropFirst(5)) }
        if Self.coreModules.contains(request) { return .core(request) }

        // "#name": the package.json "imports" field of the requiring package.
        if request.hasPrefix("#") {
            var dir = fromDir
            while true {
                let packageJSON = realURL(dir + "/package.json")
                if let data = try? Data(contentsOf: packageJSON),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let imports = json["imports"] as? [String: Any] {
                    if let target = exportsTarget(imports[request]) ?? (imports[request] as? String) {
                        if let found = loadAsFileOrDirectory(normalize(dir + "/" + target)) { return found }
                    }
                    break
                }
                if dir == "/" || dir.isEmpty { break }
                dir = virtualDirname(dir)
            }
            return .notFound("Cannot find module '\(rawRequest)'")
        }

        if request.hasPrefix("./") || request.hasPrefix("../") || request.hasPrefix("/") {
            let base = request.hasPrefix("/") ? request : fromDir + "/" + request
            if let found = loadAsFileOrDirectory(normalize(base)) { return found }
            return .notFound("Cannot find module '\(rawRequest)'")
        }

        // Bare specifier: walk node_modules upward from the requiring directory.
        var dir = fromDir
        while true {
            let candidate = normalize(dir + "/node_modules/" + request)
            if let found = loadAsFileOrDirectory(candidate) { return found }
            if dir == "/" || dir.isEmpty { break }
            dir = virtualDirname(dir)
        }
        return .notFound("Cannot find module '\(rawRequest)'")
    }

    private func loadAsFileOrDirectory(_ path: String) -> Resolution? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false

        func fileResolution(_ virtual: String) -> Resolution {
            virtual.hasSuffix(".json") ? .json(virtual) : .file(virtual)
        }

        if fm.fileExists(atPath: realURL(path).path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return fileResolution(path)
        }
        for suffix in [".js", ".cjs", ".json"] {
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
            if let target = exportsTarget(json["exports"]) {
                let candidate = normalize(path + "/" + target)
                if let found = loadAsFileOrDirectory(candidate) { return found }
            }
            if let main = json["main"] as? String, !main.isEmpty {
                if let found = loadAsFileOrDirectory(normalize(path + "/" + main)) { return found }
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

    /// The subset of "exports" real packages use for their root: a string, or a "." entry
    /// that is a string or a conditions object (require/node/import/default).
    private func exportsTarget(_ exports: Any?) -> String? {
        func fromConditions(_ value: Any?) -> String? {
            if let text = value as? String { return text }
            guard let object = value as? [String: Any] else { return nil }
            for key in ["require", "node", "import", "default"] {
                if let found = fromConditions(object[key]) { return found }
            }
            return nil
        }
        if let text = exports as? String { return text }
        guard let object = exports as? [String: Any] else { return nil }
        if let dot = object["."] { return fromConditions(dot) }
        // A conditions object with no "." ({"require": …}).
        if object.keys.contains(where: { $0.hasPrefix("./") }) == false { return fromConditions(object) }
        return nil
    }

    // MARK: - require()

    private func makeRequire(fromDir: String) -> JSValue {
        let requireBlock: @convention(block) (String) -> Any = { [weak self] request in
            guard let self else { return NSNull() }
            return self.requireModule(request, fromDir: fromDir)
        }
        let resolveBlock: @convention(block) (String) -> Any = { [weak self] request in
            guard let self else { return NSNull() }
            switch self.resolveModule(request, fromDir: fromDir) {
            case .core(let name): return "node:" + name
            case .file(let id), .json(let id): return id
            case .notFound(let message): return ["__mouseRequireError": message]
            }
        }
        // Errors must throw IN the requiring frame — a native block can't, so a JS wrapper
        // inspects the marker and throws there.
        let factory = context.evaluateScript("""
            (function(native, nativeResolve){
                function require(specifier){
                    const result = native(String(specifier));
                    if (result && result.__mouseRequireError) {
                        const error = new Error(result.__mouseRequireError);
                        error.code = 'MODULE_NOT_FOUND';
                        throw error;
                    }
                    if (result && result.__mouseRequireThrow) throw result.__mouseRequireThrow;
                    return result;
                }
                require.resolve = function(specifier){
                    const result = nativeResolve(String(specifier));
                    if (result && result.__mouseRequireError) {
                        const error = new Error(result.__mouseRequireError);
                        error.code = 'MODULE_NOT_FOUND';
                        throw error;
                    }
                    return result;
                };
                return require;
            })
            """)!
        return factory.call(withArguments: [JSValue(object: requireBlock, in: context)!,
                                            JSValue(object: resolveBlock, in: context)!])!
    }

    private func requireModule(_ request: String, fromDir: String) -> Any {
        switch resolveModule(request, fromDir: fromDir) {
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
            let esm = isESModule(id: id, source: source)
            if esm {
                source = Self.transpileESM(source)
            } else if source.contains("import") {
                // Dynamic import() is legal in CJS too (prettier lazy-loads plugins with it).
                // JSC's native import has no module loader here — route through ours.
                source = Self.rewriteDynamicImport(source)
            }
            // ESM evaluates under an ASYNC wrapper (its imports may await a top-level-await
            // dependency); CJS stays a plain sync function.
            guard let function = wrapModule(source, async: esm) else {
                return throwInJS("Cannot parse '\(id)'")
            }
            let module = context.evaluateScript("({exports: {}})")!
            modulesInProgress[id] = module
            defer { modulesInProgress.removeValue(forKey: id) }
            let require = makeRequire(fromDir: virtualDirname(id))
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
        }
    }

    // MARK: - ES modules (transpiled to CommonJS at load)

    /// .mjs is ESM, .cjs is CJS; .js follows the nearest package.json "type"; and a file
    /// with top-of-line import/export statements is ESM regardless (entry scripts).
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
    /// `import(spec)` → `__dynamicImport(__mouseRequire, spec)`. Applied to ESM (as part of
    /// the transpile) AND to CJS that contains it — dynamic import is legal in both, and
    /// JSC's native import has no module loader wired to our resolver.
    static func rewriteDynamicImport(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\bimport\s*\("#) else { return source }
        let ns = source as NSString
        return regex.stringByReplacingMatches(in: source, range: NSRange(location: 0, length: ns.length),
                                              withTemplate: "__dynamicImport(__mouseRequire, ")
    }

    static func transpileESM(_ source: String) -> String {
        var text = source
        var epilogue: [String] = []
        var counter = 0

        // One pass per pattern: collect every match against the current text, then rebuild
        // the string ONCE. The old firstMatch+replacingCharacters loop recopied and
        // rescanned the whole source per match — O(n²), ~40 s on a 9 MB bundle. Matches are
        // statement-anchored and non-overlapping, and replacements never introduce new
        // import/export syntax, so a single pass is equivalent.
        func replace(_ pattern: String, _ transform: (NSTextCheckingResult, NSString) -> String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return }
            var result = ""
            result.reserveCapacity(ns.length)
            var cursor = 0
            for match in matches {
                let range = match.range
                if range.location > cursor {
                    result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
                }
                result += transform(match, ns)
                cursor = range.location + range.length
            }
            if cursor < ns.length {
                result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            }
            text = result
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
        replace(#"(?:^|(?<=[;}]))\s*import\s*(?:([\w$]+)\s*,\s*)?(?:\{([^}]*)\}|\*\s*as\s+([\w$]+)|([\w$]+))\s*from\s*['"]([^'"]+)['"](?:\s*(?:with|assert)\s*\{[^}]*\})?\s*;?"#) { match, ns in
            counter += 1
            let temp = "__esm\(counter)"
            var lines = [requireSettled(temp, group(match, 5, ns)!)]
            if let defaultName = group(match, 1, ns) ?? group(match, 4, ns) {
                lines.append("const \(defaultName) = __esmDefault(\(temp));")
            }
            if let named = group(match, 2, ns) {
                lines.append("const { \(namedBindings(named)) } = \(temp);")
            }
            if let namespace = group(match, 3, ns) {
                lines.append("const \(namespace) = \(temp);")
            }
            return lines.joined(separator: " ")
        }
        // import 'mod'
        replace(#"(?:^|(?<=[;}]))\s*import\s*['"]([^'"]+)['"](?:\s*(?:with|assert)\s*\{[^}]*\})?\s*;?"#) { match, ns in
            counter += 1
            return requireSettled("__esm\(counter)", group(match, 1, ns)!)
        }
        // export * as name from 'mod'   (ansi-escapes@7 re-exports its base this way —
        // must run before the bare `export * from` rule, whose pattern is a prefix of this)
        replace(#"(?:^|(?<=[;}]))\s*export\s*\*\s*as\s+([\w$]+)\s+from\s*['"]([^'"]+)['"]\s*;?"#) { match, ns in
            counter += 1
            let temp = "__esm\(counter)"
            return requireSettled(temp, group(match, 2, ns)!) + " module.exports.\(group(match, 1, ns)!) = \(temp);"
        }
        // export * from 'mod'  /  export { a, b as c } from 'mod'
        // Star re-export excludes `default` and `__esModule` (spec semantics — yoga-layout's
        // `export * from './YGEnums.js'` must not clobber its own default export).
        replace(#"(?:^|(?<=[;}]))\s*export\s*\*\s*from\s*['"]([^'"]+)['"]\s*;?"#) { match, ns in
            counter += 1
            let temp = "__esm\(counter)"
            return requireSettled(temp, group(match, 1, ns)!) + " __reexportStar(module.exports, \(temp));"
        }
        replace(#"(?:^|(?<=[;}]))\s*export\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"](?:\s*(?:with|assert)\s*\{[^}]*\})?\s*;?"#) { match, ns in
            counter += 1
            let temp = "__esm\(counter)"
            var lines = [requireSettled(temp, group(match, 2, ns)!)]
            for binding in bindings(group(match, 1, ns)!) {
                lines.append("module.exports.\(binding.alias) = \(temp).\(binding.source);")
            }
            return lines.joined(separator: " ")
        }
        // export { X as 'module.exports' } — the ES2022 string-named-export idiom that dual
        // CJS/ESM packages (yargs, cliui, y18n) use to make `require()` return X directly.
        // Must run BEFORE the general clause rule, whose `[^}]*` would swallow it and then
        // drop the string alias. A general string-named export lands on module.exports[name].
        replace(#"(?:^|(?<=[;}]))\s*export\s*\{\s*([\w$]+)\s+as\s+['"]module\.exports['"]\s*\}\s*;?"#) { match, ns in
            "module.exports = \(group(match, 1, ns)!);"
        }
        replace(#"(?:^|(?<=[;}]))\s*export\s*\{\s*([\w$]+)\s+as\s+['"]([^'"]+)['"]\s*\}\s*;?"#) { match, ns in
            let name = group(match, 2, ns)!.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            return "module.exports['\(name)'] = \(group(match, 1, ns)!);"
        }
        // export { a, b as c };   — a trailing line comment must not defeat the match
        // (commander@15 ends one with "; // Deprecated").
        replace(#"(?:^|(?<=[;}]))\s*export\s*\{([^}]*)\}\s*;?\s*(//[^\n]*)?$"#) { match, ns in
            bindings(group(match, 1, ns)!)
                .map { "module.exports.\($0.alias) = \($0.source);" }
                .joined(separator: " ")
        }
        // export default function name() / class Name — keep the declaration, alias at EOF.
        // Mid-line anchor: a preceding rule can leave `;export default` on one line when an
        // unterminated import (no semicolon, cliui) had its trailing newline consumed.
        replace(#"(?:^|(?<=[;}]))\s*export\s+default\s+(function\s+([\w$]+)|class\s+([\w$]+))"#) { match, ns in
            let name = group(match, 2, ns) ?? group(match, 3, ns)!
            epilogue.append("module.exports.default = \(name);")
            return group(match, 1, ns)!
        }
        // export default <expression>
        replace(#"(?:^|(?<=[;}]))\s*export\s+default\s+"#) { _, _ in "module.exports.default = " }
        // export const/let/var/function/class NAME — strip keyword, assign at EOF.
        replace(#"(?:^|(?<=[;}]))\s*export\s+(const|let|var|function|class|async\s+function)\s+([\w$]+)"#) { match, ns in
            let name = group(match, 2, ns)!
            epilogue.append("module.exports.\(name) = \(name);")
            return "\(group(match, 1, ns)!) \(name)"
        }
        // dynamic import() and import.meta.*
        text = text.replacingOccurrences(of: "import.meta.resolve", with: "__mouseRequire.resolve")
        // __mouseFilename, not __filename: ESM files legitimately declare
        // `const __filename = fileURLToPath(import.meta.url)`, and substituting the param
        // name would make that line a TDZ self-reference (prettier's bundle).
        text = text.replacingOccurrences(of: "import.meta.url", with: "('file://' + __mouseFilename)")
        text = rewriteDynamicImport(text)

        // The body runs under an ASYNC wrapper (imports may await). The try/catch makes the
        // sync outcome inspectable the moment the wrapper call returns: __esmDone means the
        // whole body ran without suspending (the common case — requirers get exports
        // synchronously, as before); __esmError preserves throw-in-requiring-frame
        // semantics; neither means genuine top-level await in flight.
        return "module.exports.__esModule = true;\ntry {\n" + text + "\n;" + epilogue.joined(separator: "\n")
            + "\n;module.__esmDone = true;\n} catch (__esmThrown) { module.__esmError = __esmThrown; throw __esmThrown; }"
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
      function utf8Decode(bytes) {
        let out = '';
        for (let i = 0; i < bytes.length;) {
          const b = bytes[i];
          let c, extra;
          if (b < 0x80) { c = b; extra = 0; }
          else if (b >= 0xf0) { c = b & 7; extra = 3; }
          else if (b >= 0xe0) { c = b & 15; extra = 2; }
          else { c = b & 31; extra = 1; }
          i++;
          while (extra-- > 0 && i < bytes.length) { c = (c << 6) | (bytes[i++] & 63); }
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
        str = String(str).replace(/[^A-Za-z0-9+/]/g, '');
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
        static from(value, encoding) {
          if (typeof value === 'string') {
            if (encoding === 'base64') return new Buffer(b64Decode(value));
            if (encoding === 'hex') {
              const bytes = [];
              for (let i = 0; i < value.length; i += 2) bytes.push(parseInt(value.substr(i, 2), 16));
              return new Buffer(bytes);
            }
            if (encoding === 'latin1' || encoding === 'binary') {
              const bytes = new Uint8Array(value.length);
              for (let i = 0; i < value.length; i++) bytes[i] = value.charCodeAt(i) & 0xff;
              return new Buffer(bytes);
            }
            return new Buffer(utf8Encode(value));
          }
          if (value instanceof ArrayBuffer) return new Buffer(new Uint8Array(value));
          return new Buffer(value);
        }
        static alloc(size, fill) {
          const buffer = new Buffer(size);
          if (fill !== undefined) buffer.fill(typeof fill === 'string' ? fill.charCodeAt(0) : fill);
          return buffer;
        }
        static allocUnsafe(size) { return new Buffer(size); }
        static isBuffer(value) { return value instanceof Buffer; }
        static byteLength(value) { return typeof value === 'string' ? utf8Encode(value).length : value.length; }
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
          if (encoding === 'base64') return b64Encode(bytes);
          if (encoding === 'hex') return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
          if (encoding === 'latin1' || encoding === 'binary') {
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
        compare(other) {
          const length = Math.min(this.length, other.length);
          for (let i = 0; i < length; i++) { if (this[i] !== other[i]) return this[i] < other[i] ? -1 : 1; }
          return this.length === other.length ? 0 : (this.length < other.length ? -1 : 1);
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
        slice(start, end) { return new Buffer(super.slice(start, end)); }
        equals(other) { return this.length === other.length && this.every((b, i) => b === other[i]); }
        toJSON() { return { type: 'Buffer', data: Array.from(this) }; }
      }
      globalThis.Buffer = Buffer;

      // ---- Web globals JSC doesn't ship (wasm/Emscripten glue expects them) ----
      globalThis.TextEncoder = class TextEncoder {
        get encoding() { return 'utf-8'; }
        encode(text) { return new Uint8Array(Buffer.from(String(text), 'utf8')); }
      };
      globalThis.TextDecoder = class TextDecoder {
        constructor(encoding) { this.encoding = (encoding || 'utf-8').toLowerCase(); }
        decode(view) {
          if (view === undefined) return '';
          const buffer = Buffer.from(view.buffer ? new Uint8Array(view.buffer, view.byteOffset, view.byteLength) : view);
          return buffer.toString(this.encoding === 'utf-16le' ? 'utf16le' : 'utf8');
        }
      };
      globalThis.performance = {
        timeOrigin: Date.now(),
        now: function(){ return Date.now() - globalThis.performance.timeOrigin; },
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
      globalThis.MessageChannel = class MessageChannel {
        constructor() {
          const makePort = function() {
            const port = new EventTarget();
            port.onmessage = null;
            port.postMessage = function(data) {
              const twin = port._twin;
              setImmediate(function() {
                const event = new Event('message');
                event.data = data;
                if (twin.onmessage) twin.onmessage(event);
                twin.dispatchEvent(event);
              });
            };
            port.start = function(){};
            port.close = function(){};
            port.unref = function(){ return port; };
            port.ref = function(){ return port; };
            return port;
          };
          this.port1 = makePort();
          this.port2 = makePort();
          this.port1._twin = this.port2;
          this.port2._twin = this.port1;
        }
      };
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
      globalThis.structuredClone = function(value) { return JSON.parse(JSON.stringify(value)); };
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
        append(name, value) { this._pairs.push([String(name), String(value)]); }
        set(name, value) { this.delete(name); this.append(name, value); }
        get(name) { const found = this._pairs.find(p => p[0] === name); return found ? found[1] : null; }
        getAll(name) { return this._pairs.filter(p => p[0] === name).map(p => p[1]); }
        has(name) { return this._pairs.some(p => p[0] === name); }
        delete(name) { this._pairs = this._pairs.filter(p => p[0] !== name); }
        forEach(fn, thisArg) { for (const [name, value] of this._pairs.slice()) fn.call(thisArg, value, name, this); }
        keys() { return this._pairs.map(p => p[0])[Symbol.iterator](); }
        values() { return this._pairs.map(p => p[1])[Symbol.iterator](); }
        entries() { return this._pairs.map(p => [p[0], p[1]])[Symbol.iterator](); }
        [Symbol.iterator]() { return this.entries(); }
        get size() { return this._pairs.length; }
        toString() {
          return this._pairs.map(p => encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1])).join('&');
        }
        sort() { this._pairs.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0); }
      };
      if (typeof globalThis.URL === 'undefined') {
        // The slice Emscripten and fetch-y libraries touch: parse, href, protocol, pathname.
        globalThis.URL = class URL {
          constructor(input, base) {
            let text = String(input);
            if (base && !/^[a-zA-Z][\w+.-]*:/.test(text)) {
              const baseText = String(base && base.href ? base.href : base);
              text = baseText.replace(/[^/]*$/, '') + text;
            }
            this.href = text;
            const match = text.match(/^([a-zA-Z][\w+.-]*:)(?:\/\/([^/?#:]*)(?::(\d+))?)?([^?#]*)(\?[^#]*)?(#.*)?$/) || [];
            this.protocol = match[1] || '';
            this.hostname = match[2] || '';
            this.port = match[3] || '';
            this.host = this.hostname + (this.port ? ':' + this.port : '');
            this.pathname = match[4] || '';
            this.search = match[5] || '';
            this.hash = match[6] || '';
            this.origin = this.protocol + (this.hostname ? '//' + this.host : '');
            this.searchParams = new URLSearchParams(this.search);
            this.username = '';
            this.password = '';
          }
          toString() { return this.href; }
          toJSON() { return this.href; }
          static canParse(input, base) { try { new URL(input, base); return true; } catch (e) { return false; } }
        };
      }

      // ---- ESM interop (the transpiler emits these) ----
      globalThis.__esmDefault = function(m) { return m && m.__esModule ? m.default : m; };
      globalThis.__reexportStar = function(target, source) {
        for (const key of Object.keys(source)) {
          if (key === 'default' || key === '__esModule') continue;
          target[key] = source[key];
        }
      };
      globalThis.__dynamicImport = function(require, specifier) {
        // Promise flattening settles a pending (top-level-await) module before wrapping.
        return Promise.resolve().then(function() { return require(specifier); }).then(function(m) {
          return m && m.__esModule ? m : Object.assign({ default: m }, m);
        });
      };

      // ---- inspect / format (console + util) ----
      function inspect(value, depth) {
        depth = depth === undefined ? 2 : depth;
        if (value === null) return 'null';
        if (value === undefined) return 'undefined';
        const type = typeof value;
        if (type === 'string') return "'" + value.replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'";
        if (type === 'number' || type === 'boolean' || type === 'bigint') return String(value);
        if (type === 'function') {
          const name = value.name ? ': ' + value.name : ' (anonymous)';
          return (String(value).startsWith('class') ? '[class' : '[Function') + name + ']';
        }
        if (value instanceof Error) return value.stack || String(value);
        if (Buffer.isBuffer(value)) {
          const hex = Array.from(value.subarray(0, 50)).map(b => b.toString(16).padStart(2, '0')).join(' ');
          return '<Buffer ' + hex + (value.length > 50 ? ' ... ' + (value.length - 50) + ' more bytes' : '') + '>';
        }
        if (Array.isArray(value)) {
          if (depth < 0) return '[Array]';
          const items = value.map(v => inspect(v, depth - 1));
          return items.length === 0 ? '[]' : '[ ' + items.join(', ') + ' ]';
        }
        if (type === 'object') {
          if (depth < 0) return '[Object]';
          const keys = Object.keys(value);
          if (keys.length === 0) return '{}';
          const items = keys.map(k => (/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(k) ? k : "'" + k + "'") + ': ' + inspect(value[k], depth - 1));
          return '{ ' + items.join(', ') + ' }';
        }
        return String(value);
      }
      function formatOne(value) { return typeof value === 'string' ? value : inspect(value); }
      function format() {
        const args = Array.from(arguments);
        if (typeof args[0] === 'string' && /%[sdifjoO%]/.test(args[0])) {
          let i = 1;
          let text = args[0].replace(/%([sdifjoO%])/g, (match, spec) => {
            if (spec === '%') return '%';
            if (i >= args.length) return match;
            const value = args[i++];
            switch (spec) {
              case 's': return formatOne(value);
              case 'd': case 'i': return String(parseInt(value, 10));
              case 'f': return String(parseFloat(value));
              case 'j': return JSON.stringify(value);
              default: return inspect(value);
            }
          });
          for (; i < args.length; i++) text += ' ' + formatOne(args[i]);
          return text;
        }
        return args.map(formatOne).join(' ');
      }

      // console.Console: a console over any pair of writable streams (ink's patchConsole
      // builds one to intercept logs while it owns the screen).
      function Console(stdout, stderr) {
        if (stdout && stdout.stdout) { stderr = stdout.stderr; stdout = stdout.stdout; }
        const errStream = stderr || stdout;
        this.log = function(){ stdout.write(format.apply(null, arguments) + '\n'); };
        this.info = this.log;
        this.warn = function(){ errStream.write(format.apply(null, arguments) + '\n'); };
        this.error = this.warn;
        this.debug = this.warn;
        this.trace = function(){ errStream.write('Trace: ' + format.apply(null, arguments) + '\n'); };
        this.dir = this.log;
        this.assert = function(condition){ if (!condition) errStream.write('Assertion failed\n'); };
        this.table = this.log;
        this.group = this.log; this.groupEnd = function(){}; this.groupCollapsed = this.log;
        this.count = function(){}; this.countReset = function(){};
        this.time = function(){}; this.timeEnd = function(){}; this.timeLog = function(){};
      }
      globalThis.console = {
        log: function(){ bridge.stdout(format.apply(null, arguments) + '\n'); },
        info: function(){ bridge.stdout(format.apply(null, arguments) + '\n'); },
        warn: function(){ bridge.stderr(format.apply(null, arguments) + '\n'); },
        error: function(){ bridge.stderr(format.apply(null, arguments) + '\n'); },
        debug: function(){ bridge.stderr(format.apply(null, arguments) + '\n'); },
        trace: function(){ bridge.stderr('Trace: ' + format.apply(null, arguments) + '\n'); },
        Console: Console,
      };

      // ---- process ----
      const tickQueue = [];
      globalThis.__drainTicks = function() {
        while (tickQueue.length) {
          const [fn, args] = tickQueue.shift();
          fn.apply(null, args);
        }
      };
      // ---- stdio streams (real TTY semantics when the host attached one) ----
      const signalHandlers = { SIGINT: [], SIGTERM: [], SIGWINCH: [] };
      // Non-signal process events ('warning', 'exit', 'beforeExit', …): registered and
      // introspectable; the host emits what it can.
      const processEvents = {};
      function makeOutputStream(sink) {
        const listeners = {};
        return {
          isTTY: __isTTY,
          columns: __ttyColumns,
          rows: __ttyRows,
          write: function(chunk, encoding, callback) {
            sink(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString());
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
      }
      function makeInputStream() {
        const listeners = {};
        let paused = false;
        let buffered = __stdin;
        // A TTY with someone listening keeps the process alive, like node's ref'd stdin —
        // without this the event loop would see quiescence and end a program mid-wait.
        function updateLiveness() {
          if (!__isTTY || !bridge.stdinActive) return;
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
            return stream._encoding ? value : Buffer.from(value);
          },
          // A keystroke from the host: flowing listeners get 'data'; paused-mode consumers
          // (ink reads via 'readable' + read()) get the buffer filled and a 'readable' poke.
          _push: function(text){
            if ((listeners['data'] || []).length) {
              stream.emit('data', stream._encoding ? text : Buffer.from(text));
              if ((listeners['readable'] || []).length) { buffered += text; stream.emit('readable'); }
            } else {
              buffered += text;
              stream.emit('readable');
            }
          },
          pipe: function(destination){ stream.on('data', c => destination.write(c)); return destination; },
          unref: function(){ return this; }, ref: function(){ return this; },
        };
        return stream;
      }

      // Host → JS: one keystroke, delivered as data — never a signal. The host owns the
      // terminal discipline: cooked-mode ^C arrives via __mouseSigint instead.
      globalThis.__mouseDeliverInput = function(text) {
        process.stdin._push(text);
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
      globalThis.__mouseEmitUncaught = function(error) {
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
        cpuUsage: function(){ return { user: 0, system: 0 }; },
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
        exit: function(code){ bridge.exit(code === undefined ? 0 : code | 0); throw new Error('__mouse_exit__'); },
        exitCode: undefined,
        nextTick: function(fn){
          tickQueue.push([fn, Array.prototype.slice.call(arguments, 1)]);
          // The tick queue outranks promise reactions: riding the FIRST microtask slot
          // preserves node's tick-before-promise ordering.
          if (tickQueue.length === 1) Promise.resolve().then(globalThis.__drainTicks);
        },
        hrtime: function(prev){
          const now = Date.now();
          const seconds = Math.floor(now / 1000), nanos = (now % 1000) * 1e6;
          if (prev) return [seconds - prev[0], nanos - prev[1]];
          return [seconds, nanos];
        },
        memoryUsage: function(){ return { rss: 0, heapTotal: 0, heapUsed: 0, external: 0 }; },
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
        stdout: makeOutputStream(bridge.stdout),
        stderr: makeOutputStream(bridge.stderr),
        stdin: makeInputStream(),
      };
      globalThis.process = process;
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
      const coreFactories = {};

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
          delimiter: ':',
          normalize: function(p) {
            if (!p.length) return '.';
            const { absolute, parts } = normalizeParts(p);
            let result = (absolute ? '/' : '') + parts.join('/');
            if (!result) result = absolute ? '/' : '.';
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
            return path.normalize(resolved) || '/';
          },
          dirname: function(p) {
            const i = p.lastIndexOf('/');
            if (i < 0) return '.';
            if (i === 0) return '/';
            return p.slice(0, i);
          },
          basename: function(p, ext) {
            const base = p.slice(p.lastIndexOf('/') + 1);
            return ext && base.endsWith(ext) ? base.slice(0, -ext.length) : base;
          },
          extname: function(p) {
            const base = p.slice(p.lastIndexOf('/') + 1);
            const dot = base.lastIndexOf('.');
            return dot > 0 ? base.slice(dot) : '';
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
            const dir = path.dirname(p), base = path.basename(p), ext = path.extname(p);
            return { root: p.startsWith('/') ? '/' : '', dir, base, ext, name: base.slice(0, base.length - ext.length) };
          },
        };
        path.posix = path;
        // win32 delegates to the posix logic — this device has no Windows paths; only the
        // separators differ for display.
        path.win32 = Object.assign({}, path, { sep: '\\', delimiter: ';' });
        return path;
      };

      coreFactories.events = function() {
        // `_events` initializes LAZILY in every method, not just the constructor: express
        // mixes EventEmitter.prototype into a plain function without ever calling the
        // constructor, and real node's emitter tolerates exactly that.
        class EventEmitter {
          constructor() { this._events = {}; }
          _bucket() { return this._events || (this._events = {}); }
          on(name, handler) { const ev = this._bucket(); (ev[name] = ev[name] || []).push(handler); return this; }
          addListener(name, handler) { return this.on(name, handler); }
          once(name, handler) {
            const wrapper = (...args) => { this.off(name, wrapper); handler.apply(this, args); };
            wrapper.listener = handler;
            return this.on(name, wrapper);
          }
          off(name, handler) {
            const list = this._bucket()[name] || [];
            const index = list.findIndex(h => h === handler || h.listener === handler);
            if (index >= 0) list.splice(index, 1);
            return this;
          }
          removeListener(name, handler) { return this.off(name, handler); }
          removeAllListeners(name) { if (name) delete this._bucket()[name]; else this._events = {}; return this; }
          emit(name, ...args) {
            const list = (this._bucket()[name] || []).slice();
            // Node semantics: an 'error' with no listener THROWS — otherwise failures
            // dissolve into silence (and awaited events dangle forever).
            if (name === 'error' && list.length === 0) {
              throw args[0] instanceof Error ? args[0] : new Error('Unhandled error: ' + args[0]);
            }
            for (const handler of list) handler.apply(this, args);
            return list.length > 0;
          }
          listenerCount(name) { return (this._bucket()[name] || []).length; }
          listeners(name) { return (this._bucket()[name] || []).slice(); }
          rawListeners(name) { return (this._bucket()[name] || []).slice(); }
          eventNames() { return Object.keys(this._bucket()); }
          setMaxListeners() { return this; }
          getMaxListeners() { return Infinity; }
          prependListener(name, handler) { const ev = this._bucket(); (ev[name] = ev[name] || []).unshift(handler); return this; }
          prependOnceListener(name, handler) {
            const wrapper = (...args) => { this.off(name, wrapper); handler.apply(this, args); };
            wrapper.listener = handler;
            return this.prependListener(name, wrapper);
          }
        }
        // Real node assigns its emitter methods onto the prototype as ENUMERABLE properties
        // — express's `Object.assign(app, EventEmitter.prototype)` mixin depends on it.
        // Class methods are non-enumerable by default; flip them.
        for (const key of Object.getOwnPropertyNames(EventEmitter.prototype)) {
          if (key === 'constructor') continue;
          const descriptor = Object.getOwnPropertyDescriptor(EventEmitter.prototype, key);
          descriptor.enumerable = true;
          Object.defineProperty(EventEmitter.prototype, key, descriptor);
        }
        EventEmitter.EventEmitter = EventEmitter;
        EventEmitter.default = EventEmitter;
        EventEmitter.once = function(emitter, name) {
          return new Promise(function(resolve){ emitter.once(name, function(){ resolve(Array.from(arguments)); }); });
        };
        return EventEmitter;
      };

      coreFactories.util = function() {
        return {
          format: format,
          inspect: inspect,
          inherits: function(ctor, superCtor) {
            ctor.super_ = superCtor;
            Object.setPrototypeOf(ctor.prototype, superCtor.prototype);
          },
          promisify: function(fn) {
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
          isDeepStrictEqual: function(a, b) { return JSON.stringify(a) === JSON.stringify(b); },
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
          return {
            isDirectory: function(){ return raw.dir; },
            isFile: function(){ return !raw.dir; },
            isSymbolicLink: function(){ return false; },
            size: raw.size,
            mtimeMs: raw.mtimeMs,
            mtime: new Date(raw.mtimeMs),
          };
        }
        // A NUMBER as the file argument means an open fd — resolvePath maps it to the
        // path (node semantics: fs.writeFileSync(fd, data) is legal and common).
        const fs = {
          readFileSync: function(file, options) {
            const base64 = bridge.readFile(resolvePath(file));
            if (base64 === null || base64 === undefined) {
              const error = new Error("ENOENT: no such file or directory, open '" + file + "'");
              error.code = 'ENOENT';
              throw error;
            }
            const buffer = Buffer.from(base64, 'base64');
            const encoding = toEncoding(options);
            return encoding ? buffer.toString(encoding) : buffer;
          },
          writeFileSync: function(file, data, options) {
            const buffer = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
            if (!bridge.writeFile(resolvePath(file), buffer.toString('base64'), false)) {
              throw new Error("EACCES: cannot write '" + file + "'");
            }
          },
          appendFileSync: function(file, data) {
            const buffer = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
            if (!bridge.writeFile(resolvePath(file), buffer.toString('base64'), true)) {
              throw new Error("EACCES: cannot append '" + file + "'");
            }
          },
          existsSync: function(file) { return bridge.stat(resolvePath(file)) !== null && bridge.stat(resolvePath(file)) !== undefined; },
          statSync: function(file, options) {
            const raw = bridge.stat(resolvePath(file));
            if (!raw) {
              if (options && options.throwIfNoEntry === false) return undefined;
              const error = new Error("ENOENT: no such file or directory, stat '" + file + "'");
              error.code = 'ENOENT';
              throw error;
            }
            return statsFrom(raw);
          },
          lstatSync: function(file, options) { return fs.statSync(file, options); },
          readdirSync: function(dir, options) {
            const parent = resolvePath(dir);
            const entries = bridge.readdir(parent);
            if (!entries) {
              const error = new Error("ENOENT: no such file or directory, scandir '" + dir + "'");
              error.code = 'ENOENT';
              throw error;
            }
            if (!options || !options.withFileTypes) return entries;
            // Dirent objects — glob's path-scurry walks these; strings would silently match
            // nothing (isDirectory() undefined reads as "not a directory, not a file").
            return entries.map(function(name) {
              const raw = bridge.stat(parent + '/' + name);
              const isDir = !!(raw && raw.dir);
              return {
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
              };
            });
          },
          mkdirSync: function(dir) { bridge.mkdir(resolvePath(dir)); },
          rmdirSync: function(dir) { bridge.remove(resolvePath(dir)); },
          rmSync: function(target) { bridge.remove(resolvePath(target)); },
          unlinkSync: function(file) {
            if (!bridge.remove(resolvePath(file))) {
              const error = new Error("ENOENT: no such file or directory, unlink '" + file + "'");
              error.code = 'ENOENT';
              throw error;
            }
          },
          renameSync: function(from, to) { bridge.rename(resolvePath(from), resolvePath(to)); },
          copyFileSync: function(from, to) {
            fs.writeFileSync(to, fs.readFileSync(from));
          },
          realpathSync: function(file) { return resolvePath(file); },
          chmodSync: function() {},
          constants: { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 },
          accessSync: function(file) {
            if (!fs.existsSync(file)) {
              const error = new Error("ENOENT: no such file or directory, access '" + file + "'");
              error.code = 'ENOENT';
              throw error;
            }
          },
        };
        // Callback forms wrap the sync forms through the event loop.
        for (const name of ['readFile', 'writeFile', 'appendFile', 'stat', 'lstat', 'readdir', 'mkdir', 'unlink', 'rename', 'copyFile', 'access', 'rm']) {
          fs[name] = function(...args) {
            const callback = typeof args[args.length - 1] === 'function' ? args.pop() : function(){};
            setImmediate(() => {
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
          flags = String(flags === undefined ? 'r' : flags);
          const path = resolvePath(file);
          if (flags.includes('w')) fs.writeFileSync(path, '');
          else if (flags.includes('a')) { if (!fs.existsSync(path)) fs.writeFileSync(path, ''); }
          else if (!fs.existsSync(path)) {
            const e = new Error("ENOENT: no such file or directory, open '" + file + "'");
            e.code = 'ENOENT';
            throw e;
          }
          const fd = nextFd++;
          fileDescriptors[fd] = { path: path, flags: flags, position: 0 };
          return fd;
        };
        fs.writeSync = function(fd, data) {
          const buffer = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
          if (fd === 1) { bridge.stdout(buffer.toString()); return buffer.length; }
          if (fd === 2) { bridge.stderr(buffer.toString()); return buffer.length; }
          fs.appendFileSync(descriptor(fd).path, buffer);
          return buffer.length;
        };
        fs.readSync = function(fd, buffer, offset, length, position) {
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
        fs.fstatSync = function(fd) { return fs.statSync(descriptor(fd).path); };
        fs.close = function(fd, callback) { fs.closeSync(fd); if (callback) setImmediate(callback); };
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
            catch (error) { stream.emit('error', error); return; }
            stream.fd = 3;
            stream.emit('open', 3);
            stream.emit('ready');
            const CHUNK = 65536;
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
          const stream = new Writable({
            write(chunk, encoding, callback) {
              try {
                if (!opened) { opened = true; if (append) fs.appendFileSync(file, chunk); else fs.writeFileSync(file, chunk); }
                else fs.appendFileSync(file, chunk);
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
            if (!opened && !append) { try { fs.writeFileSync(file, ''); opened = true; } catch (e) { stream.emit('error', e); return; } }
            stream.fd = 3;
            stream.emit('open', 3);
            stream.emit('ready');
          });
          return stream;
        };
        fs.promises = {};
        for (const name of ['readFile', 'writeFile', 'appendFile', 'stat', 'lstat', 'readdir', 'mkdir', 'unlink', 'rename', 'copyFile', 'access', 'rm']) {
          fs.promises[name] = function(...args) {
            return new Promise((resolve, reject) => {
              try { resolve(fs[name + 'Sync'].apply(null, args)); }
              catch (error) { reject(error); }
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
        function assert(value, message) {
          if (!value) throw new Error(message || 'Assertion failed');
        }
        assert.ok = assert;
        assert.equal = function(a, b, message) { if (a != b) throw new Error(message || (a + ' != ' + b)); };
        assert.strictEqual = function(a, b, message) { if (a !== b) throw new Error(message || (a + ' !== ' + b)); };
        assert.notEqual = function(a, b, message) { if (a == b) throw new Error(message || (a + ' == ' + b)); };
        assert.notStrictEqual = function(a, b, message) { if (a === b) throw new Error(message || (a + ' === ' + b)); };
        assert.deepStrictEqual = function(a, b, message) {
          if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(message || 'not deeply equal');
        };
        assert.deepEqual = assert.deepStrictEqual;
        assert.notDeepStrictEqual = function(a, b, message) {
          if (JSON.stringify(a) === JSON.stringify(b)) throw new Error(message || 'unexpectedly deeply equal');
        };
        assert.notDeepEqual = assert.notDeepStrictEqual;
        assert.fail = function(message) { throw new Error(message instanceof Error ? message.message : (message || 'Failed')); };
        assert.ifError = function(value) { if (value) throw (value instanceof Error ? value : new Error('ifError got ' + value)); };
        assert.throws = function(fn, message) {
          try { fn(); } catch (e) { return; }
          throw new Error(message || 'Missing expected exception');
        };
        assert.doesNotThrow = function(fn, message) {
          try { fn(); } catch (e) { throw new Error(message || 'Got unwanted exception'); }
        };
        assert.match = function(value, regexp, message) {
          if (!regexp.test(value)) throw new Error(message || (value + ' does not match ' + regexp));
        };
        assert.strict = assert;
        return assert;
      };

      coreFactories.string_decoder = function() {
        class StringDecoder {
          constructor(encoding) { this.encoding = encoding || 'utf8'; }
          write(buffer) { return buffer.toString(this.encoding); }
          end(buffer) { return buffer ? buffer.toString(this.encoding) : ''; }
        }
        return { StringDecoder };
      };

      coreFactories.stream = function() {
        const EventEmitter = coreRequire('events');
        // The legacy Stream base carries the classic `pipe` — packages that extend Stream
        // directly (mute-stream under inquirer) call `super.pipe`.
        class Stream extends EventEmitter {
          pipe(dest, options) {
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
          }
        }

        // Real Readable semantics: an internal buffer, paused vs flowing modes, 'readable'
        // in paused mode, _read pull, async iteration, and pipe with backpressure.
        class Readable extends Stream {
          constructor(options) {
            super();
            options = options || {};
            this._buf = [];
            this._flowing = false;
            this._sawEOF = false;
            this._endEmitted = false;
            this._draining = false;
            this._readableEncoding = options.encoding || null;
            this.readable = true;
            this.destroyed = false;
            if (options.read) this._read = options.read;
            if (options.destroy) this._destroy = options.destroy;
            this._objectMode = !!options.objectMode;
          }
          _read() {}
          _coerce(chunk) {
            if (this._objectMode) return chunk;
            if (this._readableEncoding) return typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString(this._readableEncoding);
            return typeof chunk === 'string' ? Buffer.from(chunk) : chunk;
          }
          push(chunk) {
            if (chunk === null) {
              this._sawEOF = true;
              this._maybeEnd();
              return false;
            }
            this._buf.push(chunk);
            if (this._flowing) this._drain();
            else this.emit('readable');
            return true;
          }
          _drain() {
            if (this._draining) return;
            this._draining = true;
            process.nextTick(() => {
              this._draining = false;
              while (this._flowing && this._buf.length) this.emit('data', this._coerce(this._buf.shift()));
              if (this._flowing && !this._sawEOF && !this._buf.length) this._read(16384);
              this._maybeEnd();
            });
          }
          _maybeEnd() {
            if (this._sawEOF && !this._buf.length && !this._endEmitted) {
              this._endEmitted = true;
              process.nextTick(() => {
                this.readable = false;
                this.emit('end');
                process.nextTick(() => this.emit('close'));
              });
            }
          }
          on(event, handler) {
            super.on(event, handler);
            if (event === 'data') this.resume();
            else if (event === 'readable' && this._buf.length) process.nextTick(() => this.emit('readable'));
            return this;
          }
          read(size) {
            if (!this._buf.length) { if (!this._sawEOF) this._read(size || 16384); if (!this._buf.length) { this._maybeEnd(); return null; } }
            if (this._objectMode) return this._buf.shift();
            let out = this._buf.map(c => typeof c === 'string' ? c : Buffer.from(c).toString()).join('');
            this._buf = [];
            this._maybeEnd();
            return this._readableEncoding ? out : Buffer.from(out);
          }
          resume() { if (!this._flowing) { this._flowing = true; this._drain(); } return this; }
          pause() { this._flowing = false; return this; }
          isPaused() { return !this._flowing; }
          setEncoding(enc) { this._readableEncoding = enc; return this; }
          unshift(chunk) { if (chunk !== null && chunk !== undefined) this._buf.unshift(chunk); return this; }
          destroy(err) {
            if (this.destroyed) return this;
            this.destroyed = true;
            const done = (e) => { if (e) this.emit('error', e); process.nextTick(() => this.emit('close')); };
            if (this._destroy) this._destroy(err || null, done); else done(err);
            return this;
          }
          pipe(dest, options) {
            const end = !options || options.end !== false;
            this.on('data', chunk => { if (dest.write(chunk) === false && this.pause) { this.pause(); } });
            if (dest.on) dest.on('drain', () => this.resume());
            this.on('end', () => { if (end && dest.end) dest.end(); });
            if (dest.emit) dest.emit('pipe', this);
            return dest;
          }
          [Symbol.asyncIterator]() {
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
          }
          static from(iterable) {
            const readable = new Readable({ objectMode: true });
            process.nextTick(async () => {
              try {
                for await (const item of iterable) readable.push(item);
                readable.push(null);
              } catch (e) { readable.emit('error', e); }
            });
            return readable;
          }
        }

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
        }
        const writableMethods = {
          _write(chunk, encoding, callback) { callback(); },
          write(chunk, encoding, callback) {
            if (typeof encoding === 'function') { callback = encoding; encoding = null; }
            if (this._writableEnded) { this.emit('error', new Error('write after end')); return false; }
            this._wbuf.push([chunk, encoding || 'utf8', callback]);
            this._flushWrites();
            const ok = this._wbuf.length < 16;
            if (!ok) this._needDrain = true;
            return ok;
          },
          _flushWrites() {
            if (this._writing) return;
            const step = () => {
              if (!this._wbuf.length) {
                this._writing = false;
                if (this._needDrain) { this._needDrain = false; this.emit('drain'); }
                this._maybeFinish();
                return;
              }
              const [chunk, encoding, callback] = this._wbuf.shift();
              this._write(chunk, encoding, (err) => {
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
              process.nextTick(() => this.emit('close'));
            };
            if (this._final) this._final((err) => { if (err) this.emit('error', err); finish(); });
            else finish();
          },
          destroy(err) {
            if (this.destroyed) return this;
            this.destroyed = true;
            const done = (e) => { if (e) this.emit('error', e); process.nextTick(() => this.emit('close')); };
            if (this._destroy) this._destroy(err || null, done); else done(err);
            return this;
          },
        };

        class Writable extends Stream {
          constructor(options) { super(); this.destroyed = false; initWritable(this, options); }
        }
        Object.assign(Writable.prototype, writableMethods);

        class Duplex extends Readable {
          constructor(options) { super(options); initWritable(this, options); }
        }
        Object.assign(Duplex.prototype, writableMethods, {
          destroy: writableMethods.destroy,
        });

        class Transform extends Duplex {
          constructor(options) {
            options = options || {};
            super(Object.assign({}, options, { objectMode: options.objectMode || options.readableObjectMode || options.writableObjectMode }));
            if (options.transform) this._transform = options.transform;
            if (options.flush) this._flush = options.flush;
          }
          _transform(chunk, encoding, callback) { callback(null, chunk); }
          _write(chunk, encoding, callback) {
            this._transform(chunk, encoding, (err, out) => {
              if (err) return callback(err);
              if (out !== undefined && out !== null) this.push(out);
              callback();
            });
          }
          _maybeFinish() {
            if (!this._writableEnded || this._writing || this._wbuf.length || this._finishEmitted) return;
            this._finishEmitted = true;
            const finish = () => {
              this.writable = false;
              this.push(null);
              this.emit('finish');
            };
            if (this._flush) this._flush((err, out) => {
              if (err) { this.emit('error', err); return; }
              if (out !== undefined && out !== null) this.push(out);
              finish();
            });
            else finish();
          }
        }
        class PassThrough extends Transform {}

        function finished(stream, callback) {
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
          let failed = false;
          const fail = (err) => { if (!failed) { failed = true; callback(err); } };
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
          parse: function(text) {
            const result = {};
            for (const pair of String(text).split('&')) {
              if (!pair) continue;
              const [key, value] = pair.split('=');
              result[decodeURIComponent(key)] = decodeURIComponent(value || '');
            }
            return result;
          },
          stringify: function(object) {
            return Object.keys(object).map(k => encodeURIComponent(k) + '=' + encodeURIComponent(object[k])).join('&');
          },
        };
      };
      coreFactories.url = function() {
        return {
          URL: globalThis.URL || function(){ throw new Error('URL is not available'); },
          parse: function(text) {
            const match = String(text).match(/^(\w+:)?\/\/([^/:]+)(:(\d+))?([^?#]*)(\?[^#]*)?/) || [];
            return { protocol: match[1] || null, hostname: match[2] || null, port: match[4] || null,
                     pathname: match[5] || '/', search: match[6] || null, href: text };
          },
          fileURLToPath: function(url) { return String(url).replace('file://', ''); },
          pathToFileURL: function(p) { return { href: 'file://' + p }; },
        };
      };
      coreFactories.process = function() { return process; };
      coreFactories.timers = function() {
        return { setTimeout: setTimeout, clearTimeout: clearTimeout, setInterval: setInterval,
                 clearInterval: clearInterval, setImmediate: setImmediate, clearImmediate: clearImmediate };
      };
      coreFactories['timers/promises'] = function() {
        return {
          setTimeout: function(delay, value) { return new Promise(function(resolve){ setTimeout(function(){ resolve(value); }, delay); }); },
          setImmediate: function(value) { return new Promise(function(resolve){ setImmediate(function(){ resolve(value); }); }); },
          setInterval: function(delay, value) {
            return { [Symbol.asyncIterator]() {
              return { next() { return new Promise(function(resolve){ setTimeout(function(){ resolve({ value: value, done: false }); }, delay); }); } };
            } };
          },
          scheduler: { wait: function(delay) { return new Promise(function(resolve){ setTimeout(resolve, delay); }); } },
        };
      };
      coreFactories.module = function() {
        const builtins = ['fs', 'path', 'os', 'util', 'events', 'buffer', 'tty', 'assert', 'url',
                          'child_process', 'http', 'https', 'stream', 'zlib', 'readline', 'crypto',
                          'string_decoder', 'constants', 'querystring', 'module'];
        const moduleExports = {
          createRequire: function(from) { return bridge.createRequire(String(from && from.href ? from.href : from)); },
          builtinModules: builtins,
          isBuiltin: function(name) { return builtins.includes(String(name).replace(/^node:/, '')); },
        };
        moduleExports.Module = moduleExports;
        return moduleExports;
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
            const parts = [command].concat((argv || []).map(shellQuote));
            const r = runShell(parts.join(' '));
            return { status: r.status, signal: null, pid: 1,
                     stdout: Buffer.from(r.stdout), stderr: Buffer.from(r.stderr),
                     output: [null, Buffer.from(r.stdout), Buffer.from(r.stderr)] };
          },
          execFileSync: function(command, argv, options) {
            const result = child_process.spawnSync(command, argv, options);
            if (result.status !== 0) throw failure(command, { status: result.status, stdout: result.stdout.toString(), stderr: result.stderr.toString() });
            const encoding = options && options.encoding;
            return encoding && encoding !== 'buffer' ? result.stdout.toString() : result.stdout;
          },
          spawn: function(command, argv, options) {
            const EventEmitter = coreRequire('events');
            const child = new EventEmitter();
            child.stdout = new EventEmitter();
            child.stderr = new EventEmitter();
            child.pid = 1;
            child.kill = function(){};
            setImmediate(function() {
              const parts = [command].concat((argv || []).map(shellQuote));
              const r = runShell(parts.join(' '));
              if (r.stdout) child.stdout.emit('data', Buffer.from(r.stdout));
              if (r.stderr) child.stderr.emit('data', Buffer.from(r.stderr));
              child.stdout.emit('end');
              child.emit('close', r.status, null);
              child.emit('exit', r.status, null);
            });
            return child;
          },
        };
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
      globalThis.fetch = function(url, options) {
        options = options || {};
        const headers = {};
        if (options.headers) {
          for (const key of Object.keys(options.headers)) headers[key] = String(options.headers[key]);
        }
        let bodyBase64 = '';
        if (options.body !== undefined && options.body !== null) {
          bodyBase64 = (Buffer.isBuffer(options.body) ? options.body : Buffer.from(String(options.body))).toString('base64');
        }
        return rawRequest(url, options.method || 'GET', headers, bodyBase64).then(function(result) {
          const bodyBuffer = Buffer.from(result.body || '', 'base64');
          return {
            ok: result.status >= 200 && result.status < 300,
            status: result.status,
            statusText: String(result.status),
            url: String(url),
            headers: { get: function(name) { return result.headers[String(name).toLowerCase()] || null; },
                       has: function(name) { return String(name).toLowerCase() in result.headers; } },
            text: function() { return Promise.resolve(bodyBuffer.toString()); },
            json: function() { return Promise.resolve(JSON.parse(bodyBuffer.toString())); },
            arrayBuffer: function() { return Promise.resolve(bodyBuffer.buffer.slice(bodyBuffer.byteOffset, bodyBuffer.byteOffset + bodyBuffer.length)); },
          };
        });
      };
      function makeHttpModule(defaultProtocol) {
        function request(url, options, callback) {
          if (typeof url === 'object') { callback = options; options = url; url = (options.protocol || defaultProtocol) + '//' + options.hostname + (options.port ? ':' + options.port : '') + (options.path || '/'); }
          if (typeof options === 'function') { callback = options; options = {}; }
          options = options || {};
          const EventEmitter = coreRequire('events');
          const clientRequest = new EventEmitter();
          let body = '';
          clientRequest.write = function(chunk) { body += chunk; return true; };
          clientRequest.setHeader = function(name, value) { (options.headers = options.headers || {})[name] = value; };
          clientRequest.end = function(chunk) {
            if (chunk) body += chunk;
            const headers = {};
            for (const key of Object.keys(options.headers || {})) headers[key] = String(options.headers[key]);
            rawRequest(url, options.method || 'GET', headers, body ? Buffer.from(body).toString('base64') : '')
              .then(function(result) {
                const response = new EventEmitter();
                response.statusCode = result.status;
                response.headers = result.headers;
                response.setEncoding = function(){ return response; };
                if (callback) callback(response);
                clientRequest.emit('response', response);
                setImmediate(function() {
                  const buffer = Buffer.from(result.body || '', 'base64');
                  if (buffer.length) response.emit('data', buffer);
                  response.emit('end');
                });
              })
              .catch(function(error) { clientRequest.emit('error', error); });
          };
          clientRequest.abort = function(){};
          clientRequest.on = EventEmitter.prototype.on.bind(clientRequest);
          return clientRequest;
        }
        const EventEmitter = coreRequire('events');
        const { Readable, Writable } = coreRequire('stream');
        // The extendable class surface: HTTP client libraries subclass Agent and touch the
        // message classes for instanceof checks.
        class Agent extends EventEmitter {
          constructor(options) { super(); this.options = options || {}; this.sockets = {}; this.requests = {}; }
          destroy() {}
        }
        class IncomingMessage extends Readable {}
        class OutgoingMessage extends Writable {}
        class ClientRequest extends OutgoingMessage {}
        class ServerResponse extends OutgoingMessage {}
        return {
          request: request,
          get: function(url, options, callback) {
            const clientRequest = request(url, options, callback);
            clientRequest.end();
            return clientRequest;
          },
          Agent: Agent,
          globalAgent: new Agent(),
          IncomingMessage: IncomingMessage,
          OutgoingMessage: OutgoingMessage,
          ClientRequest: ClientRequest,
          ServerResponse: ServerResponse,
          createServer: function() { throw new Error('http servers are not available yet (the dev-server engine is on the roadmap)'); },
          STATUS_CODES: { 200: 'OK', 201: 'Created', 204: 'No Content', 301: 'Moved Permanently', 302: 'Found',
                          304: 'Not Modified', 400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden',
                          404: 'Not Found', 409: 'Conflict', 429: 'Too Many Requests',
                          500: 'Internal Server Error', 502: 'Bad Gateway', 503: 'Service Unavailable' },
          METHODS: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'],
        };
      }
      coreFactories.http = function() { return makeHttpModule('http:'); };
      coreFactories.https = function() { return makeHttpModule('https:'); };
      // http2: libraries import it for the constants and gate actual use behind feature
      // checks — the constants are real, sessions say what's missing.
      coreFactories.http2 = function() {
        return {
          constants: {
            HTTP2_HEADER_METHOD: ':method', HTTP2_HEADER_PATH: ':path',
            HTTP2_HEADER_STATUS: ':status', HTTP2_HEADER_AUTHORITY: ':authority',
            HTTP2_HEADER_SCHEME: ':scheme', HTTP2_HEADER_CONTENT_TYPE: 'content-type',
            HTTP2_HEADER_CONTENT_LENGTH: 'content-length',
            NGHTTP2_CANCEL: 8, NGHTTP2_NO_ERROR: 0,
          },
          connect: function() { throw new Error('http2 sessions are not available (fetch/https cover HTTP on this device)'); },
          createServer: function() { throw new Error('http2 servers are not available (the dev-server engine is on the roadmap)'); },
        };
      };
      // The feature-detect tail: bundled CLIs import these and gate real use behind checks.
      // Each surface is import-safe and says the truth when actually exercised.
      coreFactories.dns = function() {
        function notFound(host) { return Object.assign(new Error('getaddrinfo ENOTFOUND ' + host), { code: 'ENOTFOUND', hostname: host }); }
        const dns = {
          lookup: function(host, options, callback) {
            if (typeof options === 'function') callback = options;
            // URLSession resolves names internally — standalone lookups have no resolver here.
            setImmediate(function(){ callback(notFound(host)); });
          },
          resolve: function(host, type, callback) {
            if (typeof type === 'function') callback = type;
            setImmediate(function(){ callback(notFound(host)); });
          },
          promises: {
            lookup: function(host) { return Promise.reject(notFound(host)); },
            resolve: function(host) { return Promise.reject(notFound(host)); },
          },
        };
        return dns;
      };
      coreFactories.worker_threads = function() {
        return {
          isMainThread: true,
          threadId: 0,
          parentPort: null,
          workerData: null,
          Worker: function() { throw new Error('worker_threads are not available (single JS thread on this device)'); },
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
        return {
          getHeapStatistics: function() { return { total_heap_size: 0, used_heap_size: 0, heap_size_limit: 0 }; },
          serialize: function(value) { return Buffer.from(JSON.stringify(value)); },
          deserialize: function(buffer) { return JSON.parse(buffer.toString()); },
        };
      };
      coreFactories.vm = function() {
        return {
          runInThisContext: function(code) { return (0, eval)(code); },
          createContext: function(sandbox) { return sandbox || {}; },
          Script: class Script {
            constructor(code) { this._code = code; }
            runInThisContext() { return (0, eval)(this._code); }
          },
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
        return { url: function() { return undefined; }, open: function() { throw new Error('inspector is not available'); }, Session: class Session { connect() { throw new Error('inspector is not available'); } } };
      };
      coreFactories.dgram = function() {
        return { createSocket: function() { throw new Error('UDP sockets are not available yet'); } };
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
      coreFactories.cluster = function() {
        return { isPrimary: true, isMaster: true, isWorker: false, fork: function() { throw new Error('cluster is not available (single process)'); }, workers: {} };
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
        function toBuf(data, encoding) {
          if (Buffer.isBuffer(data)) return data;
          if (data instanceof Uint8Array) return Buffer.from(data);
          return Buffer.from(String(data), encoding || 'utf8');
        }
        function finishDigest(base64, encoding) {
          if (base64 === null || base64 === undefined) throw new Error('Digest method not supported');
          const buffer = Buffer.from(base64, 'base64');
          return encoding ? buffer.toString(encoding) : buffer;
        }
        class Hash {
          constructor(algorithm) { this._algorithm = String(algorithm).toLowerCase().replace('-', ''); this._chunks = []; }
          update(data, encoding) { this._chunks.push(toBuf(data, encoding)); return this; }
          copy() { const twin = new Hash(this._algorithm); twin._chunks = this._chunks.slice(); return twin; }
          digest(encoding) {
            return finishDigest(bridge.cryptoHash(this._algorithm, Buffer.concat(this._chunks).toString('base64')), encoding);
          }
        }
        class Hmac {
          constructor(algorithm, key) {
            this._algorithm = String(algorithm).toLowerCase().replace('-', '');
            this._key = toBuf(key);
            this._chunks = [];
          }
          update(data, encoding) { this._chunks.push(toBuf(data, encoding)); return this; }
          digest(encoding) {
            return finishDigest(bridge.cryptoHmac(this._algorithm, this._key.toString('base64'),
                                                  Buffer.concat(this._chunks).toString('base64')), encoding);
          }
        }
        const crypto = {
          createHash: function(algorithm) { return new Hash(algorithm); },
          createHmac: function(algorithm, key) { return new Hmac(algorithm, key); },
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
            if (a.length !== b.length) throw new RangeError('Input buffers must have the same byte length');
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
        function run(mode, data) {
          const input = Buffer.isBuffer(data) ? data
            : data instanceof Uint8Array ? Buffer.from(data)
            : Buffer.from(String(data));
          const result = bridge.zlibTransform(mode, input.toString('base64'));
          if (result === null || result === undefined) {
            const error = new Error('zlib: ' + mode + ': invalid input');
            error.code = 'Z_DATA_ERROR';
            throw error;
          }
          return Buffer.from(result, 'base64');
        }
        const zlib = { constants: { Z_NO_COMPRESSION: 0, Z_BEST_SPEED: 1, Z_BEST_COMPRESSION: 9, Z_DEFAULT_COMPRESSION: -1 } };
        for (const mode of ['gzip', 'gunzip', 'deflate', 'inflate', 'deflateRaw', 'inflateRaw', 'unzip']) {
          zlib[mode + 'Sync'] = function(data) { return run(mode, data); };
          zlib[mode] = function(data, options, callback) {
            if (typeof options === 'function') callback = options;
            setImmediate(function(){
              try { callback(null, run(mode, data)); } catch (error) { callback(error); }
            });
          };
          // Stream forms buffer to the flush — honest one-shot coding behind the stream API.
          const className = mode[0].toUpperCase() + mode.slice(1);
          // The CLASS form too: minizlib (under tar) does `new zlib.Gzip(opts)` and throws
          // "Compression method not supported" when the constructor is missing.
          const Coder = function(options) {
            const chunks = [];
            const stream = new Transform({
              transform(chunk, encoding, callback) {
                chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
                callback();
              },
              flush(callback) {
                try { callback(null, run(mode, Buffer.concat(chunks))); } catch (error) { callback(error); }
              },
            });
            stream._opts = options || {};
            // Coder streams answer flush() and params() calls; ours codes once at end.
            stream.flush = function(kind, cb) { const done = typeof kind === 'function' ? kind : cb; if (done) done(); };
            stream.params = function(level, strategy, cb) { if (cb) cb(); };
            stream.close = function(cb) { if (cb) cb(); };
            stream.reset = function() {};
            return stream;
          };
          zlib[className] = Coder;
          zlib['create' + className] = function(options) { return new Coder(options); };
        }
        // Flush constants and level names coder streams pass around.
        Object.assign(zlib.constants, {
          Z_NO_FLUSH: 0, Z_PARTIAL_FLUSH: 1, Z_SYNC_FLUSH: 2, Z_FULL_FLUSH: 3, Z_FINISH: 4,
          Z_BLOCK: 5, Z_TREES: 6, Z_OK: 0, Z_STREAM_END: 1, Z_DEFAULT_STRATEGY: 0,
          Z_DEFAULT_WINDOWBITS: 15, Z_DEFAULT_MEMLEVEL: 8, Z_DEFAULT_CHUNK: 16384,
        });
        Object.assign(zlib, zlib.constants);   // node mirrors the constants on the module
        return zlib;
      };

      // net: the address helpers are real; sockets carry the sandbox's truth — nothing
      // listens in-process and there is no server engine yet, so connects refuse and
      // listens error (the dev-server phase makes these real).
      coreFactories.net = function() {
        const EventEmitter = coreRequire('events');
        const { Duplex } = coreRequire('stream');
        function fail(target, code, syscall) {
          setImmediate(function(){
            target.emit('error', Object.assign(new Error(syscall + ' ' + code), { code: code, syscall: syscall }));
          });
        }
        class Socket extends Duplex {
          constructor() { super(); this.connecting = false; this.destroyed = false; }
          connect() {
            this.connecting = true;
            fail(this, 'ECONNREFUSED', 'connect');
            return this;
          }
          setNoDelay() { return this; }
          setKeepAlive() { return this; }
          setTimeout() { return this; }
          ref() { return this; }
          unref() { return this; }
          address() { return {}; }
        }
        class Server extends EventEmitter {
          listen() {
            const callback = typeof arguments[arguments.length - 1] === 'function' ? arguments[arguments.length - 1] : null;
            if (callback) this.once('listening', callback);
            fail(this, 'EPERM', 'listen');
            return this;
          }
          close(callback) { if (callback) setImmediate(callback); return this; }
          address() { return null; }
          ref() { return this; }
          unref() { return this; }
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
          Server: Server,
          createServer: function(handler) {
            const server = new Server();
            if (typeof handler === 'function') server.on('connection', handler);
            return server;
          },
          createConnection: function() { return new Socket().connect(); },
          connect: function() { return new Socket().connect(); },
          isIPv4: isIPv4,
          isIPv6: isIPv6,
          isIP: function(text) { return isIPv4(text) ? 4 : isIPv6(text) ? 6 : 0; },
        };
      };

      function coreRequire(name) {
        if (coreCache[name]) return coreCache[name];
        const factory = coreFactories[name];
        if (!factory) throw new Error("Unknown core module '" + name + "'");
        const exports = factory();
        coreCache[name] = exports;
        return exports;
      }
      globalThis.__coreModule = coreRequire;
    })();
    """#
}
