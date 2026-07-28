import Foundation
import JavaScriptCore

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

    private let root: URL
    private let env: [String: String]
    private let shell: ShellBridge?
    private let queue = DispatchQueue(label: "mouse.node", qos: .userInitiated)
    private var context: JSContext!
    private var out = ""
    private var err = ""
    private var exitCode: Int32? = nil
    private var moduleCache: [String: JSValue] = [:]
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

    init(root: URL, env: [String: String], shell: ShellBridge? = nil) {
        self.root = root
        self.env = env
        self.shell = shell
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
        context.exceptionHandler = { [weak self] _, exception in
            guard let self, self.exitCode == nil else { return }
            let text = exception?.toString() ?? "unknown error"
            if text.contains("__mouse_exit__") { return }
            let stack = exception?.forProperty("stack")?.toString() ?? text
            fatal = stack.contains(text) ? stack : text + "\n" + stack
        }

        installNativeBridge(argv: argv, cwd: cwd, stdin: stdin)
        context.evaluateScript(Self.bootstrap)

        let dir = virtualDirname(path)
        if isESModule(id: normalize(path), source: source) {
            source = Self.transpileESM(source)
        }
        let wrapped = wrapModule(source)
        if let function = wrapped {
            let module = context.evaluateScript("({exports: {}})")!
            let require = makeRequire(fromDir: dir)
            function.call(withArguments: [module.forProperty("exports")!, require, module, path, dir])
        }
        if let fatal, exitCode == nil {
            err += fatal.hasSuffix("\n") ? fatal : fatal + "\n"
            exitCode = 1
        }

        runEventLoop()

        return Result(out: out, err: err, status: exitCode ?? 0)
    }

    private func wrapModule(_ source: String) -> JSValue? {
        var body = source
        if body.hasPrefix("#!") {
            body = String(body.drop(while: { $0 != "\n" }))
        }
        let wrapped = "(function(exports, require, module, __filename, __dirname){\n" + body + "\n})"
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
            if next == nil, outstanding == 0 { break }
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

        let stdoutWrite: @convention(block) (String) -> Void = { [weak self] text in self?.out += text }
        let stderrWrite: @convention(block) (String) -> Void = { [weak self] text in self?.err += text }
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

        context.setObject(bridge, forKeyedSubscript: "__mouse" as NSString)
        context.setObject(argv, forKeyedSubscript: "__argv" as NSString)
        context.setObject(env, forKeyedSubscript: "__env" as NSString)
        context.setObject(cwd, forKeyedSubscript: "__cwd" as NSString)
        context.setObject(stdin, forKeyedSubscript: "__stdin" as NSString)
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
        "readline", "string_decoder", "constants", "querystring", "fs/promises", "process",
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
        // Errors must throw IN the requiring frame — a native block can't, so a JS wrapper
        // inspects the marker and throws there.
        let factory = context.evaluateScript("""
            (function(native){ return function require(specifier){
                const result = native(String(specifier));
                if (result && result.__mouseRequireError) {
                    const error = new Error(result.__mouseRequireError);
                    error.code = 'MODULE_NOT_FOUND';
                    throw error;
                }
                return result;
            }; })
            """)!
        return factory.call(withArguments: [JSValue(object: requireBlock, in: context)!])!
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
            if let cached = moduleCache[id] { return cached }
            guard let data = try? Data(contentsOf: realURL(id)),
                  var source = String(data: data, encoding: .utf8) else {
                return throwInJS("Cannot read '\(id)'")
            }
            if isESModule(id: id, source: source) {
                source = Self.transpileESM(source)
            }
            guard let function = wrapModule(source) else {
                return throwInJS("Cannot parse '\(id)'")
            }
            let module = context.evaluateScript("({exports: {}})")!
            moduleCache[id] = module.forProperty("exports")
            let require = makeRequire(fromDir: virtualDirname(id))
            function.call(withArguments: [module.forProperty("exports")!, require, module, id, virtualDirname(id)])
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
    static func transpileESM(_ source: String) -> String {
        var text = source
        var epilogue: [String] = []
        var counter = 0

        func replace(_ pattern: String, _ transform: (NSTextCheckingResult, NSString) -> String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            while true {
                let ns = text as NSString
                guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { break }
                let replacement = transform(match, ns)
                text = ns.replacingCharacters(in: match.range, with: replacement)
            }
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

        // import defaultName, { a, b as c } from 'mod'  (all combinations) / import * as ns
        replace(#"^\s*import\s+(?:(\w+)\s*,\s*)?(?:\{([^}]*)\}|\*\s*as\s+(\w+)|(\w+))\s+from\s*['"]([^'"]+)['"]\s*;?"#) { match, ns in
            counter += 1
            let temp = "__esm\(counter)"
            let module = group(match, 5, ns)!
            var lines = ["const \(temp) = require('\(module)');"]
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
        replace(#"^\s*import\s*['"]([^'"]+)['"]\s*;?"#) { match, ns in
            "require('\(group(match, 1, ns)!)');"
        }
        // export * from 'mod'  /  export { a, b as c } from 'mod'
        replace(#"^\s*export\s*\*\s*from\s*['"]([^'"]+)['"]\s*;?"#) { match, ns in
            "Object.assign(module.exports, require('\(group(match, 1, ns)!)'));"
        }
        replace(#"^\s*export\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]\s*;?"#) { match, ns in
            counter += 1
            let temp = "__esm\(counter)"
            let module = group(match, 2, ns)!
            var lines = ["const \(temp) = require('\(module)');"]
            for binding in bindings(group(match, 1, ns)!) {
                lines.append("module.exports.\(binding.alias) = \(temp).\(binding.source);")
            }
            return lines.joined(separator: " ")
        }
        // export { a, b as c };
        replace(#"^\s*export\s*\{([^}]*)\}\s*;?\s*$"#) { match, ns in
            bindings(group(match, 1, ns)!)
                .map { "module.exports.\($0.alias) = \($0.source);" }
                .joined(separator: " ")
        }
        // export default function name() / class Name — keep the declaration, alias at EOF.
        replace(#"^\s*export\s+default\s+(function\s+(\w+)|class\s+(\w+))"#) { match, ns in
            let name = group(match, 2, ns) ?? group(match, 3, ns)!
            epilogue.append("module.exports.default = \(name);")
            return group(match, 1, ns)!
        }
        // export default <expression>
        replace(#"^\s*export\s+default\s+"#) { _, _ in "module.exports.default = " }
        // export const/let/var/function/class NAME — strip keyword, assign at EOF.
        replace(#"^\s*export\s+(const|let|var|function|class|async\s+function)\s+(\w+)"#) { match, ns in
            let name = group(match, 2, ns)!
            epilogue.append("module.exports.\(name) = \(name);")
            return "\(group(match, 1, ns)!) \(name)"
        }
        // dynamic import() and import.meta.url
        text = text.replacingOccurrences(of: "import.meta.url", with: "('file://' + __filename)")
        if let regex = try? NSRegularExpression(pattern: #"\bimport\s*\("#) {
            let ns = text as NSString
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                  withTemplate: "__dynamicImport(require, ")
        }

        return "module.exports.__esModule = true;\n" + text + "\n;" + epilogue.joined(separator: "\n")
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
        toString(encoding) {
          const bytes = Array.from(this);
          if (encoding === 'base64') return b64Encode(bytes);
          if (encoding === 'hex') return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
          return utf8Decode(bytes);
        }
        slice(start, end) { return new Buffer(super.slice(start, end)); }
        equals(other) { return this.length === other.length && this.every((b, i) => b === other[i]); }
        toJSON() { return { type: 'Buffer', data: Array.from(this) }; }
      }
      globalThis.Buffer = Buffer;

      // ---- ESM interop (the transpiler emits these) ----
      globalThis.__esmDefault = function(m) { return m && m.__esModule ? m.default : m; };
      globalThis.__dynamicImport = function(require, specifier) {
        return Promise.resolve().then(function() {
          const m = require(specifier);
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

      globalThis.console = {
        log: function(){ bridge.stdout(format.apply(null, arguments) + '\n'); },
        info: function(){ bridge.stdout(format.apply(null, arguments) + '\n'); },
        warn: function(){ bridge.stderr(format.apply(null, arguments) + '\n'); },
        error: function(){ bridge.stderr(format.apply(null, arguments) + '\n'); },
        debug: function(){ bridge.stderr(format.apply(null, arguments) + '\n'); },
        trace: function(){ bridge.stderr('Trace: ' + format.apply(null, arguments) + '\n'); },
      };

      // ---- process ----
      const tickQueue = [];
      globalThis.__drainTicks = function() {
        while (tickQueue.length) {
          const [fn, args] = tickQueue.shift();
          fn.apply(null, args);
        }
      };
      const process = {
        argv: __argv.slice(),
        env: Object.assign({}, __env),
        platform: 'darwin',
        arch: 'arm64',
        version: 'v20.19.0',
        versions: { node: '20.19.0', mouse: '1.0.0' },
        pid: 1,
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
        on: function(){ return process; },
        once: function(){ return process; },
        off: function(){ return process; },
        removeListener: function(){ return process; },
        emit: function(){ return false; },
        stdout: {
          isTTY: false,
          write: function(chunk){ bridge.stdout(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString()); return true; },
          columns: 80, rows: 24,
          on: function(){ return this; }, once: function(){ return this; }, end: function(){},
        },
        stderr: {
          isTTY: false,
          write: function(chunk){ bridge.stderr(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString()); return true; },
          columns: 80, rows: 24,
          on: function(){ return this; }, once: function(){ return this; }, end: function(){},
        },
        stdin: {
          isTTY: false,
          setEncoding: function(){ return this; },
          on: function(event, handler){
            if (event === 'data' && __stdin.length) setImmediate(() => handler(Buffer.from(__stdin)));
            if (event === 'end') setImmediate(() => handler());
            return this;
          },
          once: function(event, handler){ return this.on(event, handler); },
          resume: function(){ return this; }, pause: function(){ return this; },
          read: function(){ return __stdin.length ? __stdin : null; },
        },
      };
      globalThis.process = process;
      globalThis.hrtimeBase = Date.now();

      // ---- timers ----
      globalThis.setTimeout = function(fn, delay){
        return bridge.setTimer(fn, delay || 0, false, Array.prototype.slice.call(arguments, 2));
      };
      globalThis.setInterval = function(fn, delay){
        return bridge.setTimer(fn, delay || 0, true, Array.prototype.slice.call(arguments, 2));
      };
      globalThis.clearTimeout = function(id){ bridge.clearTimer(id | 0); };
      globalThis.clearInterval = globalThis.clearTimeout;
      globalThis.setImmediate = function(fn){
        bridge.setImmediate(fn, Array.prototype.slice.call(arguments, 1));
        return 0;
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
        return path;
      };

      coreFactories.events = function() {
        class EventEmitter {
          constructor() { this._events = {}; }
          on(name, handler) { (this._events[name] = this._events[name] || []).push(handler); return this; }
          addListener(name, handler) { return this.on(name, handler); }
          once(name, handler) {
            const wrapper = (...args) => { this.off(name, wrapper); handler.apply(this, args); };
            wrapper.listener = handler;
            return this.on(name, wrapper);
          }
          off(name, handler) {
            const list = this._events[name] || [];
            const index = list.findIndex(h => h === handler || h.listener === handler);
            if (index >= 0) list.splice(index, 1);
            return this;
          }
          removeListener(name, handler) { return this.off(name, handler); }
          removeAllListeners(name) { if (name) delete this._events[name]; else this._events = {}; return this; }
          emit(name, ...args) {
            const list = (this._events[name] || []).slice();
            for (const handler of list) handler.apply(this, args);
            return list.length > 0;
          }
          listenerCount(name) { return (this._events[name] || []).length; }
          listeners(name) { return (this._events[name] || []).slice(); }
        }
        EventEmitter.EventEmitter = EventEmitter;
        EventEmitter.default = EventEmitter;
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
          types: { isDate: v => v instanceof Date, isRegExp: v => v instanceof RegExp },
          deprecate: function(fn) { return fn; },
          isArray: Array.isArray,
          isFunction: v => typeof v === 'function',
          isString: v => typeof v === 'string',
          isObject: v => v !== null && typeof v === 'object',
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
        };
      };

      coreFactories.fs = function() {
        const path = coreRequire('path');
        function resolvePath(p) { return path.resolve(String(p)); }
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
          readdirSync: function(dir) {
            const entries = bridge.readdir(resolvePath(dir));
            if (!entries) {
              const error = new Error("ENOENT: no such file or directory, scandir '" + dir + "'");
              error.code = 'ENOENT';
              throw error;
            }
            return entries;
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

      coreFactories.tty = function() {
        return { isatty: function(){ return false; } };
      };

      coreFactories.assert = function() {
        function assert(value, message) {
          if (!value) throw new Error(message || 'Assertion failed');
        }
        assert.ok = assert;
        assert.equal = function(a, b, message) { if (a != b) throw new Error(message || (a + ' != ' + b)); };
        assert.strictEqual = function(a, b, message) { if (a !== b) throw new Error(message || (a + ' !== ' + b)); };
        assert.notEqual = function(a, b, message) { if (a == b) throw new Error(message || (a + ' == ' + b)); };
        assert.deepStrictEqual = function(a, b, message) {
          if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(message || 'not deeply equal');
        };
        assert.deepEqual = assert.deepStrictEqual;
        assert.throws = function(fn, message) {
          try { fn(); } catch (e) { return; }
          throw new Error(message || 'Missing expected exception');
        };
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
        class Stream extends EventEmitter {
          pipe(dest) { this.on('data', chunk => dest.write(chunk)); this.on('end', () => dest.end && dest.end()); return dest; }
        }
        class Readable extends Stream {
          constructor() { super(); }
          push(chunk) { if (chunk === null) this.emit('end'); else this.emit('data', chunk); }
          setEncoding() { return this; }
          resume() { return this; }
          pause() { return this; }
        }
        class Writable extends Stream {
          constructor(options) { super(); this._options = options || {}; }
          write(chunk) { if (this._options.write) this._options.write(chunk, 'utf8', function(){}); this.emit('data', chunk); return true; }
          end(chunk) { if (chunk !== undefined) this.write(chunk); this.emit('finish'); }
        }
        Stream.Readable = Readable;
        Stream.Writable = Writable;
        Stream.PassThrough = Writable;
        Stream.Transform = Writable;
        return Stream;
      };

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
      coreFactories.buffer = function() { return { Buffer: Buffer }; };

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
        return {
          request: request,
          get: function(url, options, callback) {
            const clientRequest = request(url, options, callback);
            clientRequest.end();
            return clientRequest;
          },
        };
      }
      coreFactories.http = function() { return makeHttpModule('http:'); };
      coreFactories.https = function() { return makeHttpModule('https:'); };

      for (const missing of ['net', 'crypto', 'zlib', 'readline']) {
        coreFactories[missing] = (function(name){
          return function() {
            const stub = {};
            const explain = function(){
              throw new Error("The '" + name + "' module is not available yet (system.md phase G scope)");
            };
            return new Proxy(stub, { get: function(target, property) {
              if (property === 'then' || typeof property === 'symbol') return undefined;
              return explain;
            }});
          };
        })(missing);
      }

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
