import CryptoKit
import Darwin
import Foundation
#if os(iOS)
import os   // os_proc_available_memory (free's "available to the app")
#endif

/// `msh` — Mouse's shell, written from scratch for platforms with no fork/exec (the a-Shell
/// model). It speaks the everyday subset of POSIX shell grammar people's fingers expect:
///
///   quoting        'literal'  "expands $VARS"  \escapes
///   variables      $NAME  ${NAME}  $?   export NAME=value   env / unset
///   tilde & globs  ~  *  ?  [abc]   (globs match against the workspace)
///   pipelines      cat file | grep x | wc -l
///   redirection    cmd > file   cmd >> file   cmd < file
///   sequencing     a ; b     a && b     a || b
///   history        history   !!   !3
///
/// Commands are Swift built-ins running against the workspace tree; stdout/stderr are strings
/// flowing between them, so pipes and redirection are exact. Paths are clamped to the
/// workspace root — `..` cannot escape it. Everything is synchronous and main-thread (a
/// command is a keystroke's worth of work); engines that need processes (ssh, the system
/// shell on Android) plug in beside msh as separate `TerminalSession` engines, not here.
@MainActor
final class MouseShell {

    /// Wiring to the app: filesystem root plus the side effects a shell can cause.
    struct Context {
        let root: URL
        var markModified: (String) -> Void = { _ in }
        var openFile: (String) -> Void = { _ in }
        var clear: () -> Void = {}
        /// Incremental output from STREAMING commands (ping's once-a-second lines). Streaming
        /// happens only when a command runs solo — pipelines collect instead, so `ping -c 3 x
        /// | grep seq` still works as strings.
        var emit: (Output) -> Void = { _ in }
        /// `git checkout` rewrote the worktree: viewers must reload their files.
        var reloadTree: () -> Void = {}
        /// `git commit`/`branch` changed local history: the graph should refresh.
        var historyChanged: () -> Void = {}
        /// GitHub identity for `git push` (auto-create + auth); nil when signed out.
        var githubToken: () -> String? = { nil }
        var githubLogin: () -> String? = { nil }
        /// Hand the terminal a full-screen interactive program (`less`, `top`). nil when the
        /// shell runs headless — those builtins then fall back to transcript behavior.
        var launchProgram: (@MainActor (TerminalProgram) -> Void)? = nil
    }

    struct Output {
        let text: String
        let isError: Bool
    }

    /// Current directory, relative to the root ("" = root). The prompt renders it.
    private(set) var cwd = ""
    private(set) var lastStatus: Int32 = 0
    private(set) var history: [String] = []
    private var env: [String: String] = ["HOME": "/", "USER": "mouse", "SHELL": "msh", "PWD": "/"]

    // MARK: - Entry

    /// Run one input line; returns what to print. `echoExpansion` is set when history
    /// expansion (`!!`) rewrote the line, so the session can echo what actually ran.
    func execute(_ rawLine: String, context: Context) async -> (outputs: [Output], echoExpansion: String?) {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return ([], nil) }

        var echo: String? = nil
        if let expanded = expandHistory(line) {
            guard expanded.ok else { return ([Output(text: expanded.text, isError: true)], nil) }
            line = expanded.text
            echo = line
        }
        history.append(line)
        if history.count > 200 { history.removeFirst(history.count - 200) }

        return (await runProgram(line, context: context, interactive: true), echo)
    }

    /// Parse and evaluate a full program — a prompt line or an entire script. `interactive`
    /// gates full-screen program launches and streaming; scripts and command substitutions
    /// run with it off.
    func runProgram(_ source: String, context: Context, interactive: Bool) async -> [Output] {
        let program: ShellNode
        do {
            program = try ShellParser.parse(source)
        } catch let error as ShellParseError {
            lastStatus = 2
            return [Output(text: "msh: \(error.message)", isError: true)]
        } catch {
            lastStatus = 2
            return [Output(text: "msh: parse error", isError: true)]
        }
        let sink = Sink()
        let state = EvalState(context: context, sink: sink, interactiveAllowed: interactive)
        do {
            try await evaluate(program, state: state)
        } catch let control as Control {
            switch control {
            case .exitShell(let status), .returnStatus(let status): lastStatus = status
            case .breakLoop, .continueLoop: break   // break/continue outside a loop: ignored, like sh
            }
        } catch let error as ShellParseError {
            lastStatus = 2
            sink.commandErr("msh: \(error.message)\n")
        } catch {
            lastStatus = 1
            sink.commandErr("msh: \(error.localizedDescription)\n")
        }
        return sink.outputs
    }

    // MARK: - History expansion (!! and !n)

    private func expandHistory(_ line: String) -> (text: String, ok: Bool)? {
        guard line.hasPrefix("!") else { return nil }
        if line == "!!" {
            guard let last = history.last else { return ("msh: no history yet", false) }
            return (last, true)
        }
        if let n = Int(line.dropFirst()), n >= 1, n <= history.count {
            return (history[n - 1], true)
        }
        return ("msh: no such history entry: \(line)", false)
    }

    // MARK: - Evaluation

    /// Defined functions, by name; the body is the parsed AST.
    private var functions: [String: ShellNode] = [:]
    /// Positional parameters: a stack — scripts and function calls push, `$1…$#` read the top.
    private var positionals: [[String]] = []
    /// `$0` for the innermost running script.
    private var scriptNames: [String] = []
    /// `local` bookkeeping: per-function saved values, restored on return.
    private var localScopes: [[String: String?]] = []
    // set -e / -x / -o pipefail
    private var optionExitOnError = false
    private var optionTrace = false
    private var optionPipefail = false

    /// Where pipeline output lands. The display sink turns each pipeline's stdout into one
    /// scrollback Output (trailing newline trimmed, terminal-style); a capture sink (command
    /// substitution, functions, compounds in pipelines) collects raw stdout and bubbles
    /// stderr up to the display.
    private final class Sink {
        var outputs: [Output] = []
        var captureBuffer: String? = nil
        var errSink: Sink? = nil

        static func capture(errorsTo parent: Sink) -> Sink {
            let sink = Sink()
            sink.captureBuffer = ""
            sink.errSink = parent
            return sink
        }

        func commandOut(_ raw: String) {
            if captureBuffer != nil { captureBuffer! += raw; return }
            let trimmed = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
            if !trimmed.isEmpty { outputs.append(Output(text: trimmed, isError: false)) }
        }

        func commandErr(_ raw: String) {
            if let errSink { errSink.commandErr(raw); return }
            let trimmed = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
            if !trimmed.isEmpty { outputs.append(Output(text: trimmed, isError: true)) }
        }
    }

    /// stdin as scripts see it: a cursor over text, so `read` consumes it line by line.
    private final class StdinBuffer {
        private var remaining: Substring
        init(_ text: String) { remaining = text[...] }

        func readLine() -> String? {
            guard !remaining.isEmpty else { return nil }
            if let newline = remaining.firstIndex(of: "\n") {
                let line = String(remaining[..<newline])
                remaining = remaining[remaining.index(after: newline)...]
                return line
            }
            let line = String(remaining)
            remaining = ""
            return line
        }
    }

    private final class EvalState {
        let context: Context
        let sink: Sink
        let stdin: StdinBuffer?
        let interactiveAllowed: Bool
        var depth = 0

        init(context: Context, sink: Sink, interactiveAllowed: Bool, stdin: StdinBuffer? = nil) {
            self.context = context
            self.sink = sink
            self.interactiveAllowed = interactiveAllowed
            self.stdin = stdin
        }

        func child(sink: Sink? = nil, stdin: StdinBuffer?? = .none, interactive: Bool? = nil) -> EvalState {
            let state = EvalState(context: context,
                                  sink: sink ?? self.sink,
                                  interactiveAllowed: interactive ?? interactiveAllowed,
                                  stdin: stdin ?? self.stdin)
            state.depth = depth + 1
            return state
        }
    }

    /// Non-local exits: `break`/`continue` unwind to their loop, `return` to its function,
    /// `exit` to the program (or the enclosing `sh` script).
    private enum Control: Error {
        case breakLoop(Int)
        case continueLoop(Int)
        case returnStatus(Int32)
        case exitShell(Int32)
    }

    private func evaluate(_ node: ShellNode, state: EvalState, asCondition: Bool = false) async throws {
        if Task.isCancelled { throw Control.exitShell(130) }
        switch node {
        case .list(let nodes):
            for child in nodes {
                try await evaluate(child, state: state, asCondition: asCondition)
            }

        case .andOr(let first, let rest):
            try await evaluate(first, state: state, asCondition: true)
            for (op, node) in rest {
                if (op == "&&" && lastStatus == 0) || (op == "||" && lastStatus != 0) {
                    try await evaluate(node, state: state, asCondition: true)
                }
            }
            try errExitCheck(asCondition: asCondition)

        case .pipeline(let commands, let negated):
            try await runPipelineNode(commands, negated: negated, state: state)
            try errExitCheck(asCondition: asCondition)

        case .simple(let assignments, let words, let redirects):
            let out = try await runSimple(assignments: assignments, words: words, redirects: redirects,
                                          stdin: "", pipelinePosition: .solo, state: state)
            state.sink.commandOut(out)
            try errExitCheck(asCondition: asCondition)

        case .ifClause(let branches, let elseBody):
            for branch in branches {
                try await evaluate(branch.condition, state: state, asCondition: true)
                if lastStatus == 0 {
                    try await evaluate(branch.body, state: state, asCondition: asCondition)
                    return
                }
            }
            if let elseBody {
                try await evaluate(elseBody, state: state, asCondition: asCondition)
            } else {
                lastStatus = 0
            }

        case .whileClause(let condition, let body, let until, let redirects):
            try await withRedirects(redirects, state: state) { state in
                var bodyStatus: Int32 = 0
                var iterations = 0
                loop: while true {
                    if Task.isCancelled { throw Control.exitShell(130) }
                    iterations += 1
                    if iterations % 32 == 0 { await Task.yield() }   // keep the UI breathing
                    try await self.evaluate(condition, state: state, asCondition: true)
                    let proceed = until ? self.lastStatus != 0 : self.lastStatus == 0
                    guard proceed else { break }
                    do {
                        try await self.evaluate(body, state: state)
                        bodyStatus = self.lastStatus
                    } catch let control as Control {
                        switch control {
                        case .breakLoop(let n):
                            if n > 1 { throw Control.breakLoop(n - 1) }
                            break loop
                        case .continueLoop(let n):
                            if n > 1 { throw Control.continueLoop(n - 1) }
                            continue loop
                        default: throw control
                        }
                    }
                }
                self.lastStatus = bodyStatus
            }

        case .forClause(let variable, let words, let body, let redirects):
            let items: [String]
            if let words {
                var expanded: [String] = []
                for word in words { expanded.append(contentsOf: try await expandWord(word, state: state)) }
                items = expanded
            } else {
                items = currentParams
            }
            try await withRedirects(redirects, state: state) { state in
                var bodyStatus: Int32 = 0
                loop: for item in items {
                    if Task.isCancelled { throw Control.exitShell(130) }
                    self.env[variable] = item
                    do {
                        try await self.evaluate(body, state: state)
                        bodyStatus = self.lastStatus
                    } catch let control as Control {
                        switch control {
                        case .breakLoop(let n):
                            if n > 1 { throw Control.breakLoop(n - 1) }
                            break loop
                        case .continueLoop(let n):
                            if n > 1 { throw Control.continueLoop(n - 1) }
                            continue loop
                        default: throw control
                        }
                    }
                }
                self.lastStatus = bodyStatus
            }

        case .caseClause(let subject, let items):
            let value = try await expandNoSplit(subject, state: state)
            lastStatus = 0
            for item in items {
                for pattern in item.patterns {
                    let expanded = try await expandNoSplit(pattern, state: state)
                    if fnmatch(expanded, value, 0) == 0 {
                        try await evaluate(item.body, state: state, asCondition: asCondition)
                        return
                    }
                }
            }

        case .functionDef(let name, let body):
            functions[name] = body
            lastStatus = 0

        case .braceGroup(let body, let redirects):
            try await withRedirects(redirects, state: state) { state in
                try await self.evaluate(body, state: state, asCondition: asCondition)
            }
        }
    }

    private func errExitCheck(asCondition: Bool) throws {
        if optionExitOnError, !asCondition, lastStatus != 0 { throw Control.exitShell(lastStatus) }
    }

    /// Applies compound-command redirects: `< file` becomes the stdin buffer `read` consumes;
    /// `> file` captures the compound's stdout and writes it at the end.
    private func withRedirects(_ redirects: [ShellRedirect], state: EvalState,
                               body: @MainActor (EvalState) async throws -> Void) async throws {
        var state = state
        var outFile: (path: String, append: Bool)? = nil
        var captureSink: Sink? = nil
        for redirect in redirects {
            let target = try await expandNoSplit(redirect.target, state: state)
            switch redirect.kind {
            case .stdinRead:
                guard let resolved = resolve(target, context: state.context),
                      let text = try? String(contentsOf: resolved.url, encoding: .utf8) else {
                    state.sink.commandErr("msh: can't read \(target)\n")
                    lastStatus = 1
                    return
                }
                state = state.child(stdin: StdinBuffer(text))
            case .stdoutWrite, .stdoutAppend:
                let sink = Sink.capture(errorsTo: state.sink)
                captureSink = sink
                outFile = (target, redirect.kind == .stdoutAppend)
                state = state.child(sink: sink, interactive: false)
            }
        }
        try await body(state)
        if let outFile, let captureSink {
            if let failure = write(captureSink.captureBuffer ?? "", to: outFile.path,
                                   append: outFile.append, context: state.context) {
                state.sink.commandErr(failure + "\n")
                lastStatus = 1
            }
        }
    }

    private enum PipelinePosition { case solo, first, middle, last }

    private func runPipelineNode(_ commands: [ShellNode], negated: Bool, state: EvalState) async throws {
        var pipe = ""
        var statuses: [Int32] = []
        for (index, command) in commands.enumerated() {
            let isLast = index == commands.count - 1
            let position: PipelinePosition = commands.count == 1 ? .solo : (isLast ? .last : (index == 0 ? .first : .middle))
            switch command {
            case .simple(let assignments, let words, let redirects):
                let out = try await runSimple(assignments: assignments, words: words, redirects: redirects,
                                              stdin: pipe, pipelinePosition: position, state: state)
                if isLast { state.sink.commandOut(out); pipe = "" } else { pipe = out }
            default:
                // A compound in a pipeline: the pipe is its stdin, its stdout is captured.
                let sink = Sink.capture(errorsTo: state.sink)
                let child = state.child(sink: sink, stdin: StdinBuffer(pipe), interactive: false)
                try await evaluate(command, state: child)
                if isLast { state.sink.commandOut(sink.captureBuffer ?? "") } else { pipe = sink.captureBuffer ?? "" }
            }
            statuses.append(lastStatus)
        }
        var status = statuses.last ?? 0
        if optionPipefail, let failed = statuses.last(where: { $0 != 0 }) { status = failed }
        if negated { status = status == 0 ? 1 : 0 }
        lastStatus = status
    }

    /// One command: expand, apply redirects and scoped assignments, run. Returns raw stdout
    /// (the caller decides whether it feeds a pipe, a capture, or the scrollback).
    private func runSimple(assignments: [(name: String, value: ShellWord)], words: [ShellWord],
                           redirects: [ShellRedirect], stdin pipedIn: String,
                           pipelinePosition: PipelinePosition, state: EvalState) async throws -> String {
        guard state.depth < 48 else { throw ShellParseError(message: "recursion too deep") }

        var expandedAssignments: [(String, String)] = []
        for assignment in assignments {
            expandedAssignments.append((assignment.name, try await expandNoSplit(assignment.value, state: state)))
        }

        var argv: [String] = []
        for word in words {
            argv.append(contentsOf: try await expandWord(word, state: state))
        }

        guard !argv.isEmpty else {
            // Assignments alone are permanent; a command's are scoped to it (below).
            for (name, value) in expandedAssignments { env[name] = value }
            lastStatus = 0
            return ""
        }

        if optionTrace {
            state.sink.commandErr("+ \(argv.joined(separator: " "))\n")
        }

        var stdin = pipedIn
        var stdoutFile: (path: String, append: Bool)? = nil
        for redirect in redirects {
            let target = try await expandNoSplit(redirect.target, state: state)
            switch redirect.kind {
            case .stdinRead:
                guard let resolved = resolve(target, context: state.context),
                      let text = try? String(contentsOf: resolved.url, encoding: .utf8) else {
                    state.sink.commandErr("msh: can't read \(target)\n")
                    lastStatus = 1
                    return ""
                }
                stdin = text
            case .stdoutWrite: stdoutFile = (target, false)
            case .stdoutAppend: stdoutFile = (target, true)
            }
        }

        var saved: [(String, String?)] = []
        for (name, value) in expandedAssignments {
            saved.append((name, env[name]))
            env[name] = value
        }
        defer { for (name, value) in saved.reversed() { env[name] = value } }

        let io = try await runCommand(argv, stdin: stdin, redirectedOut: stdoutFile != nil,
                                      pipelinePosition: pipelinePosition, state: state)
        if !io.err.isEmpty { state.sink.commandErr(io.err) }
        lastStatus = io.status
        if let stdoutFile {
            if let failure = write(io.out, to: stdoutFile.path, append: stdoutFile.append, context: state.context) {
                state.sink.commandErr(failure + "\n")
                lastStatus = 1
            }
            return ""
        }
        return io.out
    }

    /// Language builtins → functions → scripts → the builtin table.
    private func runCommand(_ argv: [String], stdin: String, redirectedOut: Bool,
                            pipelinePosition: PipelinePosition, state: EvalState) async throws -> IO {
        let name = argv[0]
        let args = Array(argv.dropFirst())
        switch name {
        case "break": throw Control.breakLoop(max(1, Int(args.first ?? "1") ?? 1))
        case "continue": throw Control.continueLoop(max(1, Int(args.first ?? "1") ?? 1))
        case "return": throw Control.returnStatus(Int32(args.first ?? "") ?? lastStatus)
        case "exit": throw Control.exitShell(Int32(args.first ?? "") ?? lastStatus)
        case "shift":
            let count = Int(args.first ?? "1") ?? 1
            guard !positionals.isEmpty else { return IO() }
            guard count <= positionals[positionals.count - 1].count else {
                return IO(err: "msh: shift: not enough arguments\n", status: 1)
            }
            positionals[positionals.count - 1].removeFirst(count)
            return IO()
        case "local":
            for arg in args {
                let pieces = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let varName = String(pieces[0])
                if !localScopes.isEmpty, localScopes[localScopes.count - 1].index(forKey: varName) == nil {
                    localScopes[localScopes.count - 1][varName] = env[varName]
                }
                env[varName] = pieces.count > 1 ? String(pieces[1]) : ""
            }
            return IO()
        case "set":
            return setCmd(args)
        case "read":
            return readCmd(args, stdin: stdin, state: state)
        case "eval", "source", ".", "sh", "bash":
            return try await runScriptCommand(name: name, args: args, stdin: stdin, state: state)
        default:
            break
        }

        if let body = functions[name] {
            return try await callFunction(body: body, args: args, stdin: stdin, state: state)
        }

        let clean = !redirectedOut && state.sink.captureBuffer == nil
        let interactive = clean && state.interactiveAllowed
            && (pipelinePosition == .solo || pipelinePosition == .last)

        // ./script.sh, path/to/script.sh: a file in the workspace runs as a script.
        if name.contains("/") || name.hasSuffix(".sh") {
            if let resolved = resolve(name, context: state.context),
               FileManager.default.fileExists(atPath: resolved.url.path),
               let source = try? String(contentsOf: resolved.url, encoding: .utf8) {
                // Every extension the engine runs, not just ".js": a `./tool.mjs` or `./app.ts`
                // was being handed to the SHELL, which then tried to run JavaScript as sh.
                let runsOnNode = [".js", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"].contains { name.hasSuffix($0) }
                if runsOnNode || source.hasPrefix("#!") && source.prefix(while: { $0 != "\n" }).contains("node") {
                    return await runNode(source: source, path: "/" + resolved.rel, args: args, stdin: stdin,
                                         context: state.context, title: name, interactive: interactive)
                }
                return try await runScript(source: source, name: name, args: args, stdin: stdin, state: state)
            }
        }

        // Installed package bins are commands: run them on the Node layer.
        if let manifest = PackageManager.readManifest(root: state.context.root),
           let binPath = manifest.bins[name] {
            return await runInstalledBin(binPath, args: args, stdin: stdin, context: state.context,
                                         title: name, interactive: interactive)
        }

        return await dispatch(argv, stdin: stdin, context: state.context,
                              streaming: clean && pipelinePosition == .solo,
                              interactive: interactive)
    }

    private func callFunction(body: ShellNode, args: [String], stdin: String, state: EvalState) async throws -> IO {
        positionals.append(args)
        localScopes.append([:])
        defer {
            for (name, oldValue) in localScopes.removeLast() { env[name] = oldValue }
            positionals.removeLast()
        }
        let sink = Sink.capture(errorsTo: state.sink)
        let child = state.child(sink: sink, stdin: StdinBuffer(stdin), interactive: false)
        do {
            try await evaluate(body, state: child)
        } catch let control as Control {
            if case .returnStatus(let status) = control {
                lastStatus = status
            } else {
                // exit (or an outer break) unwinds through the call — what the function
                // already wrote must still reach the terminal, like a real process's
                // flushed stdout.
                state.sink.commandOut(sink.captureBuffer ?? "")
                throw control
            }
        }
        return IO(out: sink.captureBuffer ?? "", status: lastStatus)
    }

    /// `eval` and `source`/`.` run in the current scope; `sh`/`bash` get their own
    /// positional frame and contain `exit`. `curl url | sh` runs the piped text.
    private func runScriptCommand(name: String, args: [String], stdin: String, state: EvalState) async throws -> IO {
        switch name {
        case "eval":
            return try await runScript(source: args.joined(separator: " "), name: nil, args: [], stdin: stdin, state: state)
        case "source", ".":
            guard let file = args.first else { return IO(err: "\(name): usage: \(name) <file>\n", status: 2) }
            guard let resolved = resolve(file, context: state.context),
                  let text = try? String(contentsOf: resolved.url, encoding: .utf8) else {
                return IO(err: "\(name): can't read \(file)\n", status: 1)
            }
            let extra = Array(args.dropFirst())
            return try await runScript(source: text, name: extra.isEmpty ? nil : file,
                                       args: extra, stdin: stdin, state: state)
        default:   // sh, bash
            let flags = args.prefix(while: { $0.hasPrefix("-") })
            let rest = Array(args.dropFirst(flags.count))
            if flags.contains("-c") {
                guard let source = rest.first else { return IO(err: "\(name): -c needs a command\n", status: 2) }
                return try await runScript(source: source, name: name, args: Array(rest.dropFirst()), stdin: stdin, state: state)
            }
            if let file = rest.first {
                guard let resolved = resolve(file, context: state.context),
                      let text = try? String(contentsOf: resolved.url, encoding: .utf8) else {
                    return IO(err: "\(name): can't read \(file)\n", status: 1)
                }
                return try await runScript(source: text, name: file, args: Array(rest.dropFirst()), stdin: stdin, state: state)
            }
            if !stdin.isEmpty {
                return try await runScript(source: stdin, name: name, args: [], stdin: "", state: state)
            }
            return IO(err: "\(name): usage: \(name) <script> | -c <command>\n", status: 2)
        }
    }

    /// The script runner. `name` non-nil pushes a positional frame ($0/$1…) and contains
    /// `exit`; nil (eval, plain source) runs in the caller's frame.
    private func runScript(source: String, name: String?, args: [String], stdin: String, state: EvalState) async throws -> IO {
        var body = source
        if body.hasPrefix("#!") {
            let firstLine = String(body.prefix(while: { $0 != "\n" }))
            let interpreter = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if interpreter.contains("node") {
                return await runNode(source: source, path: "/" + (name ?? "script.js"), args: args,
                                     stdin: stdin, context: state.context)
            }
            let isShell = interpreter.hasSuffix("sh") || interpreter.contains("sh ") || interpreter.hasSuffix("bash")
            guard isShell else {
                return IO(err: "msh: no interpreter for \(interpreter)\n", status: 126)
            }
            body = String(body.dropFirst(firstLine.count))
        }
        let program: ShellNode
        do {
            program = try ShellParser.parse(body)
        } catch let error as ShellParseError {
            return IO(err: "msh: \(error.message)\n", status: 2)
        }
        if name != nil {
            positionals.append(args)
            scriptNames.append(name ?? "msh")
        }
        defer {
            if name != nil {
                positionals.removeLast()
                scriptNames.removeLast()
            }
        }
        let sink = Sink.capture(errorsTo: state.sink)
        let child = state.child(sink: sink, stdin: stdin.isEmpty ? .none : StdinBuffer(stdin), interactive: false)
        do {
            try await evaluate(program, state: child)
        } catch let control as Control {
            switch control {
            case .exitShell(let status) where name != nil: lastStatus = status
            case .returnStatus(let status): lastStatus = status
            default:
                state.sink.commandOut(sink.captureBuffer ?? "")
                throw control
            }
        }
        return IO(out: sink.captureBuffer ?? "", status: lastStatus)
    }

    private func setCmd(_ args: [String]) -> IO {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                setPositionals(Array(args[(index + 1)...]))
                return IO()
            }
            if arg == "-o" || arg == "+o" {
                if index + 1 < args.count, args[index + 1] == "pipefail" { optionPipefail = arg == "-o" }
                index += 2
                continue
            }
            guard arg.hasPrefix("-") || arg.hasPrefix("+") else {
                setPositionals(Array(args[index...]))
                return IO()
            }
            let enable = arg.hasPrefix("-")
            for flag in arg.dropFirst() {
                switch flag {
                case "e": optionExitOnError = enable
                case "x": optionTrace = enable
                default: break   // -u, -f and friends: accepted, not enforced
                }
            }
            index += 1
        }
        return IO()
    }

    private func setPositionals(_ params: [String]) {
        if positionals.isEmpty { positionals.append(params) } else { positionals[positionals.count - 1] = params }
    }

    private func readCmd(_ args: [String], stdin: String, state: EvalState) -> IO {
        let names = args.filter { !$0.hasPrefix("-") }
        var line: String? = nil
        if !stdin.isEmpty {
            line = stdin.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        } else if let buffer = state.stdin {
            line = buffer.readLine()
        }
        guard let line else {
            for name in names { env[name] = "" }
            return IO(status: 1)
        }
        guard !names.isEmpty else { return IO() }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for (index, name) in names.enumerated() {
            if index == names.count - 1 {
                env[name] = index < fields.count ? fields[index...].joined(separator: " ") : ""
            } else {
                env[name] = index < fields.count ? fields[index] : ""
            }
        }
        return IO()
    }

    // MARK: - test / [

    private func testCmd(_ rawArgs: [String], bracket: Bool, context: Context) -> IO {
        var args = rawArgs
        if bracket {
            guard args.last == "]" || args.last == "]]" else { return IO(err: "[: missing ]\n", status: 2) }
            args.removeLast()
        }
        return IO(status: evaluateTest(args, context: context) ? 0 : 1)
    }

    private func evaluateTest(_ args: [String], context: Context) -> Bool {
        // -a / -o bind loosest, left to right.
        if let index = args.lastIndex(of: "-o"), index > 0, index < args.count - 1 {
            return evaluateTest(Array(args[..<index]), context: context)
                || evaluateTest(Array(args[(index + 1)...]), context: context)
        }
        if let index = args.lastIndex(of: "-a"), index > 0, index < args.count - 1 {
            return evaluateTest(Array(args[..<index]), context: context)
                && evaluateTest(Array(args[(index + 1)...]), context: context)
        }
        if args.first == "!" { return !evaluateTest(Array(args.dropFirst()), context: context) }
        switch args.count {
        case 0: return false
        case 1: return !args[0].isEmpty
        case 2:
            let value = args[1]
            switch args[0] {
            case "-z": return value.isEmpty
            case "-n": return !value.isEmpty
            case "-e", "-f", "-d", "-s", "-r", "-w", "-x":
                guard let resolved = resolve(value, context: context) else { return false }
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory)
                switch args[0] {
                case "-e", "-r", "-w": return exists
                case "-f": return exists && !isDirectory.boolValue
                case "-d": return exists && isDirectory.boolValue
                case "-x": return exists && FileManager.default.isExecutableFile(atPath: resolved.url.path)
                case "-s":
                    let size = (try? FileManager.default.attributesOfItem(atPath: resolved.url.path)[.size] as? NSNumber)?.intValue ?? 0
                    return exists && size > 0
                default: return false
                }
            default: return false
            }
        case 3:
            let (lhs, op, rhs) = (args[0], args[1], args[2])
            switch op {
            case "=", "==": return lhs == rhs
            case "!=": return lhs != rhs
            case "-eq": return (Int(lhs) ?? 0) == (Int(rhs) ?? 0)
            case "-ne": return (Int(lhs) ?? 0) != (Int(rhs) ?? 0)
            case "-lt": return (Int(lhs) ?? 0) < (Int(rhs) ?? 0)
            case "-le": return (Int(lhs) ?? 0) <= (Int(rhs) ?? 0)
            case "-gt": return (Int(lhs) ?? 0) > (Int(rhs) ?? 0)
            case "-ge": return (Int(lhs) ?? 0) >= (Int(rhs) ?? 0)
            case "<": return lhs < rhs
            case ">": return lhs > rhs
            default: return false
            }
        default:
            return false
        }
    }

    // MARK: - Expansion

    private enum Fragment {
        /// splittable: field-splits on whitespace (unquoted expansion results).
        /// globbable: its metacharacters may glob (anything unquoted).
        case text(String, splittable: Bool, globbable: Bool)
        /// "$@": each parameter is its own word.
        case separateWords([String])
    }

    private var currentParams: [String] { positionals.last ?? [] }

    private func lookupParameter(_ name: String) -> String? {
        switch name {
        case "?": return String(lastStatus)
        case "#": return String(currentParams.count)
        case "$": return String(getpid())
        case "*", "@": return currentParams.joined(separator: " ")
        default:
            if name.allSatisfy(\.isNumber), let index = Int(name) {
                if index == 0 { return scriptNames.last ?? "msh" }
                return index <= currentParams.count ? currentParams[index - 1] : ""
            }
            return env[name]
        }
    }

    /// Word → argv: expansion, field splitting, globbing, tilde. One word can become many
    /// (splitting, "$@", globs) or none (an unquoted empty expansion).
    private func expandWord(_ word: ShellWord, state: EvalState) async throws -> [String] {
        let fragments = try await expandFragments(word, state: state)
        // A word containing any quoted part survives even when empty ("" is one empty arg) —
        // except a lone "$@", whose emptiness means zero words.
        let sawQuoted = word.contains { part in
            switch part.quote {
            case .single, .double: return part.text != "$@"
            case .commandSub(let quoted), .arithmetic(let quoted): return quoted
            case .none: return false
            }
        }

        var words: [(text: String, hasGlob: Bool)] = []
        var current = ""
        var currentGlob = false
        func flush() {
            if !current.isEmpty || currentGlob {
                words.append((current, currentGlob))
                current = ""
                currentGlob = false
            }
        }
        for fragment in fragments {
            switch fragment {
            case .separateWords(let params):
                for (index, param) in params.enumerated() {
                    if index > 0 {
                        words.append((current, currentGlob))
                        current = ""
                        currentGlob = false
                    }
                    current += param
                }
            case .text(let text, let splittable, let globbable):
                if !splittable {
                    if globbable, text.contains(where: { "*?[".contains($0) }) { currentGlob = true }
                    current += text
                } else {
                    for ch in text {
                        if ch == " " || ch == "\t" || ch == "\n" {
                            flush()
                        } else {
                            if globbable, "*?[".contains(ch) { currentGlob = true }
                            current.append(ch)
                        }
                    }
                }
            }
        }
        if !current.isEmpty || currentGlob || (words.isEmpty && sawQuoted) {
            words.append((current, currentGlob))
        }

        var results: [String] = []
        for (text, hasGlob) in words {
            if hasGlob {
                let matches = glob(text, context: state.context)
                if !matches.isEmpty {
                    results.append(contentsOf: matches)
                    continue
                }
            }
            results.append(text)
        }
        return results
    }

    /// Word → one string: expansion without field splitting or globbing (assignments, case
    /// subjects and patterns, redirect targets).
    private func expandNoSplit(_ word: ShellWord, state: EvalState) async throws -> String {
        let fragments = try await expandFragments(word, state: state)
        var result = ""
        for fragment in fragments {
            switch fragment {
            case .text(let text, _, _): result += text
            case .separateWords(let params): result += params.joined(separator: " ")
            }
        }
        return result
    }

    private func expandFragments(_ word: ShellWord, state: EvalState) async throws -> [Fragment] {
        var fragments: [Fragment] = []
        for (index, part) in word.enumerated() {
            switch part.quote {
            case .single:
                fragments.append(.text(part.text, splittable: false, globbable: false))
            case .none:
                if part.text == "$@" {
                    fragments.append(.separateWords(currentParams))
                    continue
                }
                var text = part.text
                if index == 0, text.hasPrefix("~") {
                    text = "/" + text.dropFirst()   // ~ is the workspace root
                }
                fragments.append(contentsOf: try await parseDollars(text, quoted: false, state: state))
            case .double:
                if part.text == "$@" {
                    fragments.append(.separateWords(currentParams))
                    continue
                }
                fragments.append(contentsOf: try await parseDollars(part.text, quoted: true, state: state))
            case .commandSub(let quoted):
                var result = try await commandSubstitution(part.text, state: state)
                while result.hasSuffix("\n") { result.removeLast() }
                fragments.append(.text(result, splittable: !quoted, globbable: !quoted))
            case .arithmetic:
                let value = try ShellArithmetic.evaluate(part.text, lookup: { self.lookupParameter($0) })
                fragments.append(.text(String(value), splittable: false, globbable: false))
            }
        }
        return fragments
    }

    /// Scans `$NAME`, `${…}`, `$1`, `$?`, `$#`, `$$`, `$*` out of literal text.
    private func parseDollars(_ text: String, quoted: Bool, state: EvalState) async throws -> [Fragment] {
        var fragments: [Fragment] = []
        var literal = ""
        let chars = Array(text)
        var i = 0

        func flushLiteral() {
            if !literal.isEmpty {
                fragments.append(.text(literal, splittable: false, globbable: !quoted))
                literal = ""
            }
        }
        func emit(_ value: String) {
            flushLiteral()
            fragments.append(.text(value, splittable: !quoted, globbable: !quoted))
        }

        while i < chars.count {
            guard chars[i] == "$", i + 1 < chars.count else {
                literal.append(chars[i]); i += 1; continue
            }
            let next = chars[i + 1]
            if next == "{" {
                var depth = 1
                var j = i + 2
                var inner = ""
                while j < chars.count {
                    if chars[j] == "{" { depth += 1 }
                    if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                    inner.append(chars[j])
                    j += 1
                }
                guard depth == 0 else { literal.append(chars[i]); i += 1; continue }
                flushLiteral()
                emit(try await expandBraced(inner, state: state))
                i = j + 1
            } else if next == "@" || next == "*" {
                emit(currentParams.joined(separator: " "))
                i += 2
            } else if next == "?" || next == "#" || next == "$" {
                emit(lookupParameter(String(next)) ?? "")
                i += 2
            } else if next.isNumber {
                emit(lookupParameter(String(next)) ?? "")
                i += 2
            } else if next.isLetter || next == "_" {
                var j = i + 1
                var name = ""
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    name.append(chars[j])
                    j += 1
                }
                emit(lookupParameter(name) ?? "")
                i = j
            } else {
                literal.append(chars[i])
                i += 1
            }
        }
        flushLiteral()
        return fragments
    }

    /// `${…}` bodies: `${#NAME}`, `${NAME}`, and the `:-  -  :=  =  :+  +  :?  ?  #  ##  %  %%`
    /// operators. The operator's word is itself expanded (it may hold `$VAR` or `$(cmd)`).
    private func expandBraced(_ inner: String, state: EvalState) async throws -> String {
        if inner.hasPrefix("#"), inner.count > 1 {
            return String((lookupParameter(String(inner.dropFirst())) ?? "").count)
        }
        let chars = Array(inner)
        var i = 0
        var name = ""
        if i < chars.count, chars[i].isNumber || "?#$*@".contains(chars[i]) {
            name = String(chars[i]); i += 1
            while i < chars.count, chars[i].isNumber, chars[0].isNumber { name.append(chars[i]); i += 1 }
        } else {
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                name.append(chars[i]); i += 1
            }
        }
        guard i < chars.count else { return lookupParameter(name) ?? "" }

        let operators = [":-", ":=", ":+", ":?", "##", "%%", "-", "=", "+", "?", "#", "%"]
        var op = ""
        for candidate in operators where String(chars[i...]).hasPrefix(candidate) {
            op = candidate
            break
        }
        guard !op.isEmpty else { return lookupParameter(name) ?? "" }
        let wordText = String(chars[(i + op.count)...])
        let value = lookupParameter(name)
        let isUnset = value == nil
        let isEmpty = (value ?? "").isEmpty

        func word() async throws -> String { try await expandMiniWord(wordText, state: state) }

        switch op {
        case ":-": return isEmpty ? try await word() : value!
        case "-": return isUnset ? try await word() : value!
        case ":=":
            if isEmpty { let text = try await word(); env[name] = text; return text }
            return value!
        case "=":
            if isUnset { let text = try await word(); env[name] = text; return text }
            return value!
        case ":+": return isEmpty ? "" : try await word()
        case "+": return isUnset ? "" : try await word()
        case ":?", "?":
            if isEmpty {
                let message = wordText.isEmpty ? "parameter not set" : try await word()
                throw ShellParseError(message: "\(name): \(message)")
            }
            return value!
        case "#", "##":
            return stripPattern(value ?? "", pattern: try await word(), prefix: true, longest: op == "##")
        case "%", "%%":
            return stripPattern(value ?? "", pattern: try await word(), prefix: false, longest: op == "%%")
        default:
            return value ?? ""
        }
    }

    private func stripPattern(_ value: String, pattern: String, prefix: Bool, longest: Bool) -> String {
        let chars = Array(value)
        // Candidate lengths run shortest-first; `longest` (##, %%) reverses.
        var lengths = Array(0...chars.count)
        if longest { lengths.reverse() }
        for length in lengths {
            let candidate = prefix ? String(chars[0..<length]) : String(chars[(chars.count - length)...])
            if fnmatch(pattern, candidate, 0) == 0 {
                return prefix ? String(chars[length...]) : String(chars[0..<(chars.count - length)])
            }
        }
        return value
    }

    /// A `${X:-word}` word or `${X#pattern}` pattern: re-lex and expand without splitting.
    private func expandMiniWord(_ text: String, state: EvalState) async throws -> String {
        guard !text.isEmpty else { return "" }
        let tokens = (try? ShellLexer.lex(text)) ?? []
        var pieces: [String] = []
        for token in tokens {
            if case .word(let parts) = token {
                pieces.append(try await expandNoSplit(parts, state: state))
            }
        }
        return pieces.joined(separator: " ")
    }

    private func commandSubstitution(_ source: String, state: EvalState) async throws -> String {
        guard state.depth < 48 else { throw ShellParseError(message: "recursion too deep") }
        let program: ShellNode
        do {
            program = try ShellParser.parse(source)
        } catch let error as ShellParseError {
            state.sink.commandErr("msh: \(error.message)\n")
            lastStatus = 2
            return ""
        }
        let sink = Sink.capture(errorsTo: state.sink)
        let child = state.child(sink: sink, interactive: false)
        do {
            try await evaluate(program, state: child)
        } catch let control as Control {
            if case .exitShell(let status) = control { lastStatus = status } else { throw control }
        }
        return sink.captureBuffer ?? ""
    }

    private func glob(_ pattern: String, context: Context) -> [String] {
        let dirPattern: String
        let namePattern: String
        if let slash = pattern.lastIndex(of: "/") {
            dirPattern = String(pattern[..<slash])
            namePattern = String(pattern[pattern.index(after: slash)...])
        } else {
            dirPattern = "."
            namePattern = pattern
        }
        guard let dir = resolve(dirPattern.isEmpty ? "/" : dirPattern, context: context),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.url.path) else { return [] }
        let prefix = dirPattern == "." ? "" : dirPattern + "/"
        return entries
            .filter { fnmatch(namePattern, $0, 0) == 0 && !$0.hasPrefix(".") }
            .sorted()
            .map { prefix + $0 }
    }

    // MARK: - Command I/O

    private struct IO {
        var out = ""
        var err = ""
        var status: Int32 = 0
    }

    private func write(_ text: String, to file: String, append: Bool, context: Context) -> String? {
        guard let target = resolve(file, context: context), !target.rel.isEmpty else {
            return "msh: bad redirect target: \(file)"
        }
        let existing = append ? ((try? String(contentsOf: target.url, encoding: .utf8)) ?? "") : ""
        do {
            try (existing + text).write(to: target.url, atomically: true, encoding: .utf8)
            context.markModified(target.rel)
            return nil
        } catch {
            return "msh: write failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Built-ins

    /// `interactive` is true when this command ends the pipeline with nowhere to redirect —
    /// the one position where a builtin may take over the screen as a full-screen program.
    private func dispatch(_ argv: [String], stdin: String, context: Context, streaming: Bool = false, interactive: Bool = false) async -> IO {
        let name = argv[0]
        let args = Array(argv.dropFirst())
        switch name {
        case "help": return IO(out: Self.helpText, status: 0)
        case "clear": context.clear(); return IO()
        case "pwd": return IO(out: "/" + cwd + "\n")
        case "cd": return cd(args, context: context)
        case "ls": return ls(args, context: context)
        case "cat": return cat(args, stdin: stdin, context: context)
        case "echo":
            let newline = args.first != "-n"
            let body = (args.first == "-n" ? Array(args.dropFirst()) : args).joined(separator: " ")
            return IO(out: body + (newline ? "\n" : ""))
        case "printf": return printfCmd(args)
        case "mkdir": return mkdir(args, context: context)
        case "touch": return touch(args, context: context)
        case "rm": return rm(args, context: context)
        case "mv": return moveOrCopy(args, copy: false, context: context)
        case "cp": return moveOrCopy(args.filter { $0 != "-r" }, copy: true, context: context)
        case "head": return headTail(args, stdin: stdin, fromStart: true, context: context)
        case "tail": return headTail(args, stdin: stdin, fromStart: false, context: context)
        case "wc": return wc(args, stdin: stdin, context: context)
        case "sort": return sortCmd(args, stdin: stdin, context: context)
        case "uniq": return uniq(args, stdin: stdin, context: context)
        case "tr": return tr(args, stdin: stdin)
        case "cut": return cut(args, stdin: stdin, context: context)
        case "seq": return seq(args)
        case "grep": return grep(args, stdin: stdin, context: context)
        case "find": return find(args, context: context)
        case "date": return IO(out: ISO8601DateFormatter().string(from: Date()) + "\n")
        case "whoami": return IO(out: "mouse\n")
        case "true": return IO(status: 0)
        case "false": return IO(status: 1)
        case ":": return IO()
        case "test": return testCmd(args, bracket: false, context: context)
        case "[", "[[": return testCmd(args, bracket: true, context: context)
        case "env": return IO(out: joinLines(env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }))
        case "export": return export(args)
        case "unset": args.forEach { env.removeValue(forKey: $0) }; return IO()
        case "history": return IO(out: joinLines(history.enumerated().map { "\($0.offset + 1)  \($0.element)" }))
        case "which": return which(args)
        case "basename": return IO(out: (args.first.map { ($0 as NSString).lastPathComponent } ?? "") + "\n")
        case "dirname": return IO(out: (args.first.map { ($0 as NSString).deletingLastPathComponent.isEmpty ? "." : ($0 as NSString).deletingLastPathComponent } ?? "") + "\n")
        case "open": return open(args, context: context)
        case "sleep": return await sleepCmd(args)
        case "ping": return await ping(args, context: context, streaming: streaming)
        case "curl", "wget": return await curl(args, context: context)
        case "tee": return tee(args, stdin: stdin, context: context)
        case "xargs": return await xargs(args, stdin: stdin, context: context)
        case "rev": return IO(out: joinLines(splitLines(input(args, stdin: stdin, context: context)).map { String($0.reversed()) }))
        case "tac": return IO(out: joinLines(splitLines(input(args, stdin: stdin, context: context)).reversed()))
        case "nl": return nl(args, stdin: stdin, context: context)
        case "base64": return base64Cmd(args, stdin: stdin, context: context)
        case "md5sum", "md5": return checksum(args, stdin: stdin, context: context, sha: false)
        case "sha256sum", "shasum": return checksum(args, stdin: stdin, context: context, sha: true)
        case "sed": return sed(args, stdin: stdin, context: context)
        case "diff": return diff(args, context: context)
        case "git": return await git(args, context: context)
        // A real pager when the terminal can host one; cat into the scrollback when headless
        // or mid-pipeline. The Viewer stays the editor.
        case "less", "more":
            let content = cat(args, stdin: stdin, context: context)
            guard interactive, let launch = context.launchProgram, content.err.isEmpty else { return content }
            launch(PagerProgram(text: content.out, title: argv.joined(separator: " ")))
            return IO()
        case "nano", "vi", "vim": return open(args, context: context)
        // System information — real, from the device (not simulated).
        case "uname": return unameCmd(args)
        case "lsb_release": return IO(out: "Mouse msh on \(ProcessInfo.processInfo.operatingSystemVersionString)\n")
        case "df": return df(context: context)
        case "free": return freeCmd()
        case "uptime": return IO(out: "up \(Self.uptimeString())\n")
        case "ps": return psCmd()
        case "top", "htop":
            guard interactive, let launch = context.launchProgram else { return topCmd() }
            launch(TopProgram(snapshot: { [weak self] in self?.topLines() ?? [] }))
            return IO()
        case "ip", "ifconfig": return ipCmd()
        case "chmod": return chmod(args, context: context)
        // There is no root: the app user is the only user, so sudo simply runs the command.
        case "sudo":
            guard !args.isEmpty else { return IO(err: "sudo: you already are the only user", status: 1) }
            return await dispatch(args, stdin: stdin, context: context, streaming: streaming, interactive: interactive)
        // Honesty for what iOS forbids: state the fact, never fake the feature.
        case "apt", "apt-get", "dpkg", "brew":
            return IO(err: "\(name): no system packages on iOS; npm installs JavaScript packages", status: 1)
        case "npm", "pnpm", "yarn":
            return await npmCmd(tool: name, args, context: context, interactive: interactive)
        case "npx": return await npxCmd(args, stdin: stdin, context: context, interactive: interactive)
        case "node": return await nodeCmd(args, stdin: stdin, context: context, interactive: interactive)
        case "pkg": return await pkgCmd(args, context: context)
        case "kill", "killall":
            return IO(err: "\(name): no processes on iOS (any keypress stops a running command)", status: 1)
        case "ss", "netstat":
            // This claim used to be "nothing is listening", which stopped being true when
            // `net` became real sockets: a node server started here DOES listen. What is
            // still true is that the kernel's socket table belongs to the process, and a
            // listening server only exists while its program runs in this terminal.
            return IO(err: "\(name): sockets belong to the running program, not the shell — a `node` server listens only while it runs here (its port is printed by the program; `ifconfig` has the LAN address)", status: 1)
        case "systemctl", "service":
            return IO(err: "\(name): no systemd on iOS", status: 1)
        case "chown":
            return IO(err: "chown: single-user sandbox, ownership is fixed", status: 1)
        case "passwd":
            return IO(err: "passwd: no user accounts on iOS", status: 1)
        default:
            // Language runtimes dispatch from the catalog, not from case labels — `python` here
            // is data, and language N+1 is a catalog entry, not a Swift edit. The catalog knows
            // an UNINSTALLED runtime's commands too, so its command before `pkg install <name>`
            // answers "not installed" (inside runtimeCmd) rather than lying with "command not
            // found".
            if let entry = RuntimeCatalog.entry(command: name) {
                return await runtimeCmd(entry, args, stdin: stdin, context: context, interactive: interactive)
            }
            if let manifest = PackageManager.readManifest(root: context.root), let binPath = manifest.bins[name] {
                return await runInstalledBin(binPath, args: args, stdin: stdin, context: context,
                                             title: name, interactive: interactive)
            }
            return IO(err: "msh: command not found: \(name) (type help)", status: 127)
        }
    }

    // MARK: - node (the phase-G engine behind `node`, bins, and npx)

    private func nodeCmd(_ args: [String], stdin: String, context: Context, interactive: Bool) async -> IO {
        if args.first == "-v" || args.first == "--version" { return IO(out: "v22.22.3\n") }
        if args.first == "-e" || args.first == "--eval" {
            guard args.count >= 2 else { return IO(err: "node: -e needs code\n", status: 2) }
            return await runNode(source: args[1], path: "/[eval].js", args: Array(args.dropFirst(2)),
                                 stdin: stdin, context: context, title: "node -e",
                                 interactive: interactive, isEval: true)
        }
        // `node -p` is `-e` that PRINTS the expression's value — the form every quick check and
        // half the shell scripts in a package's bin directory use. It was unimplemented, so it
        // fell through to "can't read -p", which reads as a missing file rather than a missing
        // flag. The expression is wrapped rather than post-processed so that its value goes
        // through the engine's own console.log, exactly as node's does.
        if args.first == "-p" || args.first == "--print" {
            guard args.count >= 2 else { return IO(err: "node: -p needs code\n", status: 2) }
            let printed = "console.log((function(){ return eval(" + Self.jsStringLiteral(args[1]) + "); })())"
            return await runNode(source: printed, path: "/[eval].js", args: Array(args.dropFirst(2)),
                                 stdin: stdin, context: context, title: "node -p",
                                 interactive: interactive, isEval: true)
        }
        guard let file = args.first else { return IO(err: "node: usage: node <file> | -e <code>\n", status: 2) }
        guard let resolved = resolve(file, context: context),
              let source = try? String(contentsOf: resolved.url, encoding: .utf8) else {
            return IO(err: "node: can't read \(file)\n", status: 1)
        }
        return await runNode(source: source, path: "/" + resolved.rel, args: Array(args.dropFirst()),
                             stdin: stdin, context: context, title: "node \(file)", interactive: interactive)
    }

    // MARK: - Language runtimes (pkg)

    /// Every installed runtime, visible to every program at a stable path (`/usr/lib/<name>`).
    /// Mounting unconditionally rather than per-command is deliberate: a runtime is part of the
    /// environment, and a filesystem whose shape depends on which command is running is a
    /// filesystem nobody can reason about. The mount is the whole `usr` directory (the store
    /// mirrors the usr/lib layout on disk) so that /usr and /usr/lib are real directories —
    /// interpreters that canonicalize their load paths walk those ancestors, and a path that
    /// exists only as a mount prefix answers ENOENT.
    private var runtimeMounts: [(prefix: String, url: URL)] {
        RuntimeStore.installedNames().isEmpty ? [] : [(prefix: "/usr", url: RuntimeStore.usr)]
    }

    private func pkgCmd(_ args: [String], context: Context) async -> IO {
        let action = args.first ?? "list"
        switch action {
        case "list", "ls":
            var lines: [String] = []
            for entry in RuntimeCatalog.all {
                let mark = RuntimeStore.installed(entry.name) != nil ? "installed" : "available"
                lines.append("\(entry.name) \(entry.version)  \(mark)  — \(entry.summary)")
            }
            return IO(out: lines.joined(separator: "\n") + "\n")
        case "install", "add":
            guard args.count >= 2 else { return IO(err: "pkg: install what? (`pkg list`)\n", status: 2) }
            let name = args[1]
            guard let entry = RuntimeCatalog.entry(named: name) else {
                let known = RuntimeCatalog.all.map(\.name).joined(separator: ", ")
                return IO(err: "pkg: no runtime called \(name) (have: \(known))\n", status: 1)
            }
            if RuntimeStore.installed(name) != nil {
                return IO(out: "\(entry.name) \(entry.version) is already installed\n")
            }
            do {
                // A multi-megabyte download with a silent terminal is indistinguishable from a
                // hang, so each line lands in the scrollback as it happens.
                for try await note in RuntimeStore.install(entry) {
                    context.emit(Output(text: note, isError: false))
                }
            } catch {
                return IO(err: "pkg: \(error)\n", status: 1)
            }
            return IO()
        case "remove", "rm", "uninstall":
            guard args.count >= 2 else { return IO(err: "pkg: remove what? (`pkg list`)\n", status: 2) }
            guard RuntimeStore.remove(args[1]) else {
                return IO(err: "pkg: \(args[1]) is not installed\n", status: 1)
            }
            return IO(out: "removed \(args[1])\n")
        default:
            return IO(err: "pkg: \(action)? (list, install, remove)\n", status: 2)
        }
    }

    /// A language runtime, run as a WebAssembly module through the engine's own WASI. There is
    /// no exec on iOS: what happens here is that msh writes a small bootstrap, hands it to the
    /// node engine, and the engine instantiates a multi-megabyte interpreter — the same path
    /// that runs esbuild and rollup, with a much larger passenger.
    ///
    /// ONE code path for every language: which interpreter, what environment it needs, and
    /// whether its script arguments get rewritten all come from the catalog entry. Nothing in
    /// here knows a language by name.
    private func runtimeCmd(_ entry: RuntimeCatalog.Entry, _ args: [String], stdin: String,
                            context: Context, interactive: Bool) async -> IO {
        guard RuntimeStore.installed(entry.name) != nil else {
            return IO(err: "\(entry.name): not installed — `pkg install \(entry.name)`\n", status: 127)
        }
        let mount = "/usr/lib/" + entry.name
        // A bare script name means a file in the current directory, and the interpreter has no
        // cwd of its own — every WASI path is absolute. Anything that names a real file is
        // rewritten to its absolute virtual path; everything else (flags, -c code) is untouched.
        let argv: [String] = [entry.name] + args.map { argument in
            guard entry.rewriteScriptPaths, !argument.hasPrefix("-") else { return argument }
            guard let resolved = resolve(argument, context: context) else { return argument }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return argument }
            return "/" + resolved.rel
        }
        let environment = entry.env.mapValues {
            $0.replacingOccurrences(of: "{root}", with: mount)
        }
        let bootstrap = """
        const fs = require('fs');
        const { WASI } = require('node:wasi');
        const wasi = new WASI({
          version: 'preview1',
          args: \(Self.jsJSON(argv)),
          env: \(Self.jsJSON(environment)),
          preopens: { '/': '/' },
          returnOnExit: true,
        });
        const instance = new WebAssembly.Instance(
          new WebAssembly.Module(fs.readFileSync('\(mount)/\(entry.wasm)')), wasi.getImportObject());
        const code = wasi.start(instance);
        if (code) process.exitCode = code;
        """
        return await runNode(source: bootstrap, path: "/[\(entry.name)].js", args: [], stdin: stdin,
                             context: context, title: entry.name, interactive: interactive, isEval: true)
    }

    /// A JSON literal for embedding a Swift value in generated JavaScript. JSON is a subset of
    /// JS expression syntax, so this is also valid source.
    static func jsJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        // U+2028/2029 are ordinary in JSON and statement-ending in JavaScript.
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                   .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// A JS source-level string literal for arbitrary text. JSON escaping covers quotes,
    /// backslashes and controls; U+2028/2029 are added because they are line terminators in
    /// JavaScript but ordinary characters in JSON, and an unescaped one ends the statement.
    static func jsStringLiteral(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private func runInstalledBin(_ binPath: String, args: [String], stdin: String, context: Context,
                                 title: String, interactive: Bool = false) async -> IO {
        let url = context.root.appendingPathComponent(binPath)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return IO(err: "msh: missing bin file: \(binPath)\n", status: 127)
        }
        return await runNode(source: source, path: "/" + binPath, args: args, stdin: stdin,
                             context: context, title: title, interactive: interactive)
    }

    /// node → sh → node … recursion (a JS tool exec-ing itself) stops here, not in a stack
    /// overflow.
    private var nodeDepth = 0

    /// `isEval`: `node -e` has no script path, so its argv is `["node", …extra]` — argv[1] is
    /// the first extra argument, not the program. npm scripts are full of `node -e "…" value`,
    /// and with a phantom path in the way every one of them read the wrong argument.
    private func runNode(source: String, path: String, args: [String], stdin: String, context: Context,
                         title: String = "node", interactive: Bool = false, isEval: Bool = false) async -> IO {
        guard nodeDepth < 8 else { return IO(err: "node: recursion too deep\n", status: 1) }
        let bridge = NodeEngine.ShellBridge { @MainActor [weak self] command in
            guard let self else { return ("", "msh: shell gone\n", 1) }
            let outputs = await self.runProgram(command, context: context, interactive: false)
            var out = outputs.filter { !$0.isError }.map(\.text).joined(separator: "\n")
            var err = outputs.filter { $0.isError }.map(\.text).joined(separator: "\n")
            if !out.isEmpty { out += "\n" }
            if !err.isEmpty { err += "\n" }
            return (out, err, self.lastStatus)
        }
        // A terminal to stand on: the program owns stdin, decides transcript vs screen, and
        // the command returns now — like every full-screen launch (less, top).
        if interactive, stdin.isEmpty, let launch = context.launchProgram {
            let engine = NodeEngine(root: context.root, env: env, shell: bridge, mounts: runtimeMounts)
            let program = NodeProgram(
                title: title, source: source, path: path, argv: ["node"] + (isEval ? [] : [path]) + args,
                cwd: "/" + cwd, engine: engine,
                transcript: { line, isError in context.emit(Output(text: line, isError: isError)) },
                clearTranscript: { context.clear() },
                onExit: { context.reloadTree() })
            launch(program)
            return IO()
        }
        nodeDepth += 1
        defer { nodeDepth -= 1 }
        let engine = NodeEngine(root: context.root, env: env, shell: bridge, mounts: runtimeMounts)
        let result = await engine.run(source: source, path: path, argv: ["node"] + (isEval ? [] : [path]) + args,
                                      cwd: "/" + cwd, stdin: stdin)
        context.reloadTree()   // scripts write files
        return IO(out: result.out, err: result.err, status: result.status)
    }

    // MARK: - npm / pnpm / npx

    private static func splitSpec(_ spec: String) -> (name: String, requirement: String) {
        // name[@range], where @scope/name keeps its leading @.
        if let at = spec.dropFirst().lastIndex(of: "@"), at != spec.startIndex {
            return (String(spec[..<at]), String(spec[spec.index(after: at)...]))
        }
        return (spec, "latest")
    }

    private func npmCmd(tool: String, _ args: [String], context: Context, interactive: Bool) async -> IO {
        let sub = args.first ?? "install"
        let specs = args.dropFirst().filter { !$0.hasPrefix("-") }
        switch sub {
        case "install", "i", "add", "ci", "update":
            var requirements: [String: String] = [:]
            if specs.isEmpty {
                // The package.json governing THIS directory, as npm reads it — a scaffolded
                // project sits in its own folder, and `cd app && npm install` is how anyone
                // fills it in. node_modules still lands at the workspace root, where the
                // resolver's walk-up finds it from any depth and where the bin manifest lives.
                guard let found = nearestPackage(context: context) else {
                    return IO(err: "\(tool): no package.json here", status: 1)
                }
                let json = found.json
                for key in ["dependencies", "devDependencies"] {
                    for (depName, range) in json[key] as? [String: String] ?? [:] { requirements[depName] = range }
                }
                guard !requirements.isEmpty else { return IO(out: "up to date\n") }
            } else {
                for spec in specs {
                    let (depName, range) = Self.splitSpec(spec)
                    requirements[depName] = range
                }
            }
            do {
                let report = try await PackageManager.install(requirements: requirements, into: context.root)
                if !specs.isEmpty {
                    let existing = nearestPackage(context: context)
                    var json = existing?.json ?? ["name": context.root.lastPathComponent, "version": "1.0.0"]
                    var dependencies = json["dependencies"] as? [String: String] ?? [:]
                    for spec in specs {
                        let (depName, _) = Self.splitSpec(spec)
                        if let placement = report.placements.first(where: { $0.package.name == depName && $0.atRoot }) {
                            dependencies[depName] = "^" + placement.package.version
                        }
                    }
                    json["dependencies"] = dependencies
                    // Back to the package.json it came from, which is not always the root's.
                    try PackageManager.writePackageJSON(json, root: existing?.directory
                        ?? (cwd.isEmpty ? context.root : context.root.appendingPathComponent(cwd)))
                }
                context.reloadTree()
                var out = "added \(report.placements.count) packages\n"
                if !report.bins.isEmpty {
                    out += "bin: " + report.bins.keys.sorted().joined(separator: " ") + "\n"
                }
                return IO(out: out)
            } catch {
                return IO(err: "\(tool): \(error.localizedDescription)", status: 1)
            }
        // `npm create vite@latest my-app` is how a project BEGINS: npm's `create <name>` runs
        // the package `create-<name>`, and `init <name>` is the same thing under its older name.
        case "create", "init", "innit":
            guard let target = specs.first else {
                if sub == "init" { return npmInit(tool: tool, args: args, context: context) }
                return IO(err: "\(tool): usage: \(tool) create <starter> [args]", status: 2)
            }
            let (name, requirement) = Self.splitSpec(target)
            // `create vite` → `create-vite`; a scope keeps its shape (`@scope/create-x`), and a
            // name that already says create is left alone.
            let starter: String
            if name.hasPrefix("@") {
                let pieces = name.split(separator: "/", maxSplits: 1).map(String.init)
                let bare = pieces.count > 1 ? pieces[1] : ""
                starter = bare.hasPrefix("create-") || bare.isEmpty ? name : pieces[0] + "/create-" + bare
            } else {
                starter = name.hasPrefix("create-") ? name : "create-" + name
            }
            let spec = requirement == "latest" ? starter : starter + "@" + requirement
            // npm consumes the `--` separator itself; passing it through makes a scaffolder
            // read it as the project name.
            var rest = Array(args.dropFirst()).filter { $0 != target }
            if let separator = rest.firstIndex(of: "--") { rest.remove(at: separator) }
            return await npxCmd([spec] + rest, stdin: "", context: context, interactive: interactive)
        // `npm run dev` is how a project is actually started — every README's first line.
        case "run", "run-script", "start", "test", "stop", "restart":
            return await npmRun(tool: tool, sub: sub, args: Array(args.dropFirst()),
                                context: context, interactive: interactive)
        case "ls", "list":
            guard let manifest = PackageManager.readManifest(root: context.root), !manifest.packages.isEmpty else {
                return IO(out: "no packages installed\n")
            }
            let lines = manifest.packages.sorted { $0.key < $1.key }.map { path, version in
                "\(path.split(separator: "/").dropFirst().joined(separator: "/"))@\(version)"
            }
            return IO(out: joinLines(lines))
        default:
            return IO(err: "\(tool): supported: install create run ls", status: 1)
        }
    }

    /// `npm init` with no starter: the package.json npm writes, with this directory's name.
    private func npmInit(tool: String, args: [String], context: Context) -> IO {
        guard let here = resolve(".", context: context) else {
            return IO(err: "\(tool): cannot resolve this directory", status: 1)
        }
        let file = here.url.appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: file.path) {
            return IO(err: "\(tool): package.json already exists here", status: 1)
        }
        let name = here.url.lastPathComponent.isEmpty ? "app" : here.url.lastPathComponent
        let json: [String: Any] = ["name": name, "version": "1.0.0", "private": true,
                                   "type": "module", "scripts": ["test": "echo no tests yet"]]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: file)) != nil else {
            return IO(err: "\(tool): could not write package.json", status: 1)
        }
        context.reloadTree()
        return IO(out: "wrote \(here.rel.isEmpty ? "" : here.rel + "/")package.json\n")
    }

    /// `npm run <script>` — the package.json script, run as an ordinary msh program so that a
    /// script's `&&`, pipes and env prefixes behave, and so a long-running one (`vite`) takes
    /// the terminal the same way it does when typed by hand. Installed bins already resolve by
    /// name here, which is what `node_modules/.bin` on PATH buys elsewhere.
    /// The package.json that governs the CURRENT directory — the one you are in, then upward.
    /// A project in `app/` has its own scripts and the workspace root's are not them, which is
    /// exactly the layout `npm run dev` is typed in.
    private func nearestPackage(context: Context) -> (json: [String: Any], directory: URL)? {
        var directory = cwd.isEmpty ? context.root : context.root.appendingPathComponent(cwd)
        while true {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (json, directory)
            }
            if directory.path == context.root.path { return nil }
            directory.deleteLastPathComponent()
        }
    }

    private func npmRun(tool: String, sub: String, args: [String], context: Context,
                        interactive: Bool) async -> IO {
        guard let found = nearestPackage(context: context) else {
            return IO(err: "\(tool): no package.json here", status: 1)
        }
        let json = found.json
        let scripts = json["scripts"] as? [String: String] ?? [:]
        var name = sub
        var extra = args
        if sub == "run" || sub == "run-script" {
            guard let first = extra.first else {
                // Bare `npm run` lists what there is to run, as npm does.
                guard !scripts.isEmpty else { return IO(out: "no scripts in package.json\n") }
                let lines = scripts.sorted { $0.key < $1.key }.flatMap { ["  \($0.key)", "    \($0.value)"] }
                return IO(out: joinLines(["Scripts available:"] + lines))
            }
            name = first
            extra = Array(extra.dropFirst())
        }
        if extra.first == "--" { extra.removeFirst() }

        guard let main = scripts[name] else {
            // npm's one legacy default: `npm start` with no start script runs server.js.
            if name == "start", resolve("server.js", context: context).map({ FileManager.default.fileExists(atPath: $0.url.path) }) == true {
                return await runNamedScript("node server.js", as: name, extra: extra, json: json,
                                            context: context, interactive: interactive)
            }
            return IO(err: "\(tool): Missing script: \"\(name)\"", status: 1)
        }

        // pre and post hooks, which real projects use for builds and migrations.
        var out = "", err = ""
        for (phase, command) in [("pre" + name, scripts["pre" + name]), (name, main), ("post" + name, scripts["post" + name])] {
            guard let command else { continue }
            let isMain = phase == name
            let result = await runNamedScript(command, as: phase, extra: isMain ? extra : [],
                                              json: json, context: context, interactive: interactive)
            out += result.out
            err += result.err
            if result.status != 0 { return IO(out: out, err: err, status: result.status) }
        }
        return IO(out: out, err: err, status: 0)
    }

    private func runNamedScript(_ command: String, as name: String, extra: [String],
                                json: [String: Any], context: Context, interactive: Bool) async -> IO {
        let line = extra.isEmpty ? command : command + " " + extra.map(Self.quoteForShell).joined(separator: " ")
        // The environment npm gives a script. Set on the shell rather than as a command prefix,
        // because a prefix reaches only the FIRST command and scripts are routinely `a && b`.
        let saved = env
        env["npm_lifecycle_event"] = name
        env["npm_lifecycle_script"] = command
        if let packageName = json["name"] as? String { env["npm_package_name"] = packageName }
        if let version = json["version"] as? String { env["npm_package_version"] = version }
        defer { env = saved }
        let outputs = await runProgram(line, context: context, interactive: interactive)
        let text = outputs.filter { !$0.isError }.map(\.text).joined(separator: "\n")
        let problems = outputs.filter(\.isError).map(\.text).joined(separator: "\n")
        return IO(out: text.isEmpty ? "" : text + "\n",
                  err: problems.isEmpty ? "" : problems + "\n",
                  status: lastStatus)
    }

    /// Single-quote for a shell word, closing and reopening around any quote inside.
    static func quoteForShell(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func npxCmd(_ args: [String], stdin: String, context: Context, interactive: Bool = false) async -> IO {
        guard let spec = args.first(where: { !$0.hasPrefix("-") }) else {
            return IO(err: "npx: usage: npx <package>", status: 2)
        }
        let extraArgs = Array(args.drop(while: { $0 != spec }).dropFirst())
        let (name, requirement) = Self.splitSpec(spec)
        let short = name.split(separator: "/").last.map(String.init) ?? name
        var manifest = PackageManager.readManifest(root: context.root)
        if manifest?.bins[short] == nil {
            do {
                _ = try await PackageManager.install(requirements: [name: requirement], into: context.root)
            } catch {
                return IO(err: "npx: \(error.localizedDescription)", status: 1)
            }
            context.reloadTree()
            manifest = PackageManager.readManifest(root: context.root)
        }
        guard let binPath = manifest?.bins[short]
                ?? manifest.flatMap({ $0.bins.count == 1 ? $0.bins.first?.value : nil }) else {
            return IO(err: "npx: \(name) installs no executables", status: 1)
        }
        return await runInstalledBin(binPath, args: extraArgs, stdin: stdin, context: context,
                                     title: short, interactive: interactive)
    }

    static let builtinNames: Set<String> = [
        "help", "clear", "pwd", "cd", "ls", "cat", "echo", "printf", "mkdir", "touch", "rm",
        "mv", "cp", "head", "tail", "wc", "sort", "uniq", "tr", "cut", "seq", "grep", "find",
        "date", "whoami", "true", "false", "env", "export", "unset", "history", "which",
        "basename", "dirname", "open", "sleep", "ping", "curl", "wget", "tee", "xargs",
        "rev", "tac", "nl", "base64", "md5sum", "md5", "sha256sum", "shasum", "sed", "diff",
        "git", "less", "more", "nano", "vi", "vim", "uname", "lsb_release", "df", "free",
        "uptime", "ps", "top", "htop", "ip", "ifconfig", "chmod", "chown", "passwd", "sudo",
        "apt", "apt-get", "dpkg", "brew", "kill", "killall", "ss", "netstat", "systemctl",
        "service",
    ]

    // One command per line: the terminal wraps and scrolls vertically, so a single column
    // reads cleanly on a phone where multi-column layouts fold into noise.
    private static let helpText = """
    msh — built-ins:
      ls [-la] [path]
      cd [path]
      pwd
      cat [file…]
      echo [-n]
      printf <format> [args…]
      mkdir <dir>
      touch <file>
      rm [-r] <path>
      mv <a> <b>
      cp [-r] <a> <b>
      head [-n N] [file]
      tail [-n N] [file]
      wc [-l -w -c]
      sort [-r]
      uniq [-c]
      tr <set1> <set2>
      cut -d X -f N
      seq [a] b
      grep [-i] <pattern> [file…]
      find <name>
      date
      whoami
      env
      export NAME=value
      unset NAME
      history (!!, !N)
      which <name>
      basename <path>
      dirname <path>
      open <file>
      clear
      help
      sed 's/re/sub/g'
      diff <a> <b>
      tee [-a] <file>
      xargs <cmd>
      nl
      rev
      tac
      base64 [-d]
      md5sum / sha256sum
      ping [-c N] <host>
      curl [-o file] <url>
      wget <url>
      sleep <s>
      uname [-a]
      df
      free
      uptime
      ip / ifconfig
      chmod <octal> <file>
      ps / top
      less / more
      nano / vi
      sudo <cmd>
      git <init|status|log|commit -m|branch|checkout|merge|pull|diff|push|fetch|remote>
      test <expr> / [ <expr> ]
      read [-r] NAME…
      set [-ex] [-o pipefail] [--] [arg…]
      shift [n]
      local NAME=value
      break / continue / return / exit [n]
      eval <text>
      source <file> / . <file>
      sh <file> / sh -c <cmd> / ./<script.sh>
      npm <install [pkg[@range]…] | ls>   (pnpm / yarn alias)
      npx <package>
      node <file> / node -e <code>
    language:
      if …; then …; elif …; else …; fi
      for NAME in …; do …; done
      while …; do …; done  /  until …; do …; done
      case … in pattern) … ;; esac
      NAME() { …; }
    grammar: 'quotes' "with $VARS"  |  > >> <  ;  &&  ||  !  ~  *  ?  $?
      $(cmd)  `cmd`  $((expr))  ${VAR:-…} ${VAR#…} ${#VAR}  $1…$9 $@ $# $$
    """

    // MARK: Individual commands

    private func cd(_ args: [String], context: Context) -> IO {
        guard let target = resolve(args.first ?? "/", context: context) else {
            return IO(err: "cd: invalid path", status: 1)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return IO(err: "cd: not a directory: \(display(target.rel))", status: 1)
        }
        cwd = target.rel
        env["PWD"] = "/" + cwd
        return IO()
    }

    private func ls(_ args: [String], context: Context) -> IO {
        // Flags combine (-la == -l -a), like the real thing.
        let flags = Set(args.filter { $0.hasPrefix("-") }.flatMap { $0.dropFirst() })
        let showHidden = flags.contains("a")
        let long = flags.contains("l")
        let path = args.first { !$0.hasPrefix("-") } ?? "."
        guard let target = resolve(path, context: context) else { return IO(err: "ls: invalid path", status: 1) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDirectory) else {
            return IO(err: "ls: no such path: \(display(target.rel))", status: 1)
        }
        guard isDirectory.boolValue else {
            return IO(out: (long ? longLine(target.url) : display(target.rel)) + "\n")
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: target.url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return IO(err: "ls: can't read: \(display(target.rel))", status: 1)
        }
        let sorted = entries
            .filter { showHidden || !$0.lastPathComponent.hasPrefix(".") }
            .map { url -> (url: URL, name: String, isDir: Bool) in
                (url, url.lastPathComponent, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            }
            .sorted { lhs, rhs in
                if lhs.isDir != rhs.isDir { return lhs.isDir }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        if sorted.isEmpty { return IO(out: "(empty)\n") }
        if long {
            return IO(out: joinLines(sorted.map { longLine($0.url) }))
        }
        return IO(out: sorted.map { $0.isDir ? $0.name + "/" : $0.name }.joined(separator: "  ") + "\n")
    }

    /// One `ls -l` row: permissions, size, modified date, name — real values from the sandbox.
    private func longLine(_ url: URL) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let mode = (attrs[.posixPermissions] as? Int) ?? 0
        let size = (attrs[.size] as? Int) ?? 0
        let date = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let sets = [(mode >> 6) & 7, (mode >> 3) & 7, mode & 7]
        let perms = (isDir ? "d" : "-") + sets.map { s in
            "\(s & 4 != 0 ? "r" : "-")\(s & 2 != 0 ? "w" : "-")\(s & 1 != 0 ? "x" : "-")"
        }.joined()
        let sizeColumn = String(repeating: " ", count: max(0, 8 - String(size).count)) + String(size)
        return "\(perms) \(sizeColumn)  \(formatter.string(from: date))  \(url.lastPathComponent)\(isDir ? "/" : "")"
    }

    private func cat(_ args: [String], stdin: String, context: Context) -> IO {
        guard !args.isEmpty else { return IO(out: stdin) }
        var out = ""
        for file in args {
            guard let target = resolve(file, context: context),
                  let data = try? Data(contentsOf: target.url) else {
                return IO(err: "cat: no such file: \(file)", status: 1)
            }
            guard data.count < 400_000 else { return IO(err: "cat: file too large (\(data.count / 1024) KB)", status: 1) }
            guard let text = String(data: data, encoding: .utf8) else {
                return IO(err: "cat: binary file: \(file)", status: 1)
            }
            out += text
        }
        return IO(out: out)
    }

    private func printfCmd(_ args: [String]) -> IO {
        guard var format = args.first else { return IO(err: "printf: usage: printf <format> [args…]", status: 1) }
        format = format
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
        var rest = args.dropFirst().makeIterator()
        var out = ""
        var i = format.startIndex
        while i < format.endIndex {
            let ch = format[i]
            if ch == "%", format.index(after: i) < format.endIndex {
                let spec = format[format.index(after: i)]
                switch spec {
                case "s": out += rest.next() ?? ""
                case "d": out += String(Int(rest.next() ?? "") ?? 0)
                case "%": out += "%"
                default: out.append(ch); out.append(spec)
                }
                i = format.index(i, offsetBy: 2)
                continue
            }
            out.append(ch)
            i = format.index(after: i)
        }
        return IO(out: out)
    }

    // MARK: - System information (real device facts; nothing simulated)

    private func unameCmd(_ args: [String]) -> IO {
        var uts = utsname()
        uname(&uts)
        func field<T>(_ value: T) -> String {
            withUnsafeBytes(of: value) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        }
        if args.contains("-a") {
            return IO(out: "\(field(uts.sysname)) \(field(uts.nodename)) \(field(uts.release)) \(field(uts.version)) \(field(uts.machine))\n")
        }
        if args.contains("-m") { return IO(out: field(uts.machine) + "\n") }
        if args.contains("-r") { return IO(out: field(uts.release) + "\n") }
        return IO(out: field(uts.sysname) + "\n")
    }

    private func df(context: Context) -> IO {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: context.root.path),
              let total = (attrs[.systemSize] as? NSNumber)?.int64Value,
              let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value else {
            return IO(err: "df: couldn't stat the filesystem", status: 1)
        }
        let format = ByteCountFormatter()
        format.countStyle = .file
        let used = total - free
        let percent = total > 0 ? Int((Double(used) / Double(total) * 100).rounded()) : 0
        return IO(out: "size \(format.string(fromByteCount: total))  used \(format.string(fromByteCount: used)) (\(percent)%)  avail \(format.string(fromByteCount: free))\n")
    }

    private func freeCmd() -> IO {
        let format = ByteCountFormatter()
        format.countStyle = .memory
        var out = "device memory \(format.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory)))\n"
        out += "app footprint \(format.string(fromByteCount: Self.memoryFootprint()))\n"
        #if os(iOS)
        out += "available to the app \(format.string(fromByteCount: Int64(os_proc_available_memory())))\n"
        #endif
        return IO(out: out)
    }

    private func psCmd() -> IO {
        let format = ByteCountFormatter()
        format.countStyle = .memory
        return IO(out: "only this app is visible on iOS\npid \(getpid())  mouse  \(format.string(fromByteCount: Self.memoryFootprint()))\n")
    }

    private func topCmd() -> IO {
        return IO(out: topLines().joined(separator: "\n") + "\n")
    }

    /// The facts `top` shows — shared by the one-shot builtin and the live TopProgram.
    func topLines() -> [String] {
        let format = ByteCountFormatter()
        format.countStyle = .memory
        let info = ProcessInfo.processInfo
        var lines = ["processes 1 (only this app is visible on iOS)"]
        var memory = "mem \(format.string(fromByteCount: Self.memoryFootprint())) of \(format.string(fromByteCount: Int64(info.physicalMemory)))"
        memory += "  cores \(info.processorCount)  up \(Self.uptimeString())"
        lines.append(memory)
        #if os(iOS)
        lines.append("headroom \(format.string(fromByteCount: Int64(os_proc_available_memory())))")
        #endif
        lines.append("")
        lines.append("pid \(getpid())  mouse  \(format.string(fromByteCount: Self.memoryFootprint()))")
        return lines
    }

    /// Interfaces and addresses via getifaddrs — the LAN address matters once the dev server
    /// hosts on the network.
    private func ipCmd() -> IO {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return IO(err: "ip: couldn't read interfaces", status: 1)
        }
        defer { freeifaddrs(ifaddr) }
        var lines: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = pointer {
            defer { pointer = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = family == UInt8(AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            if getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let addr = String(decoding: host.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
                lines.append("\(name)  \(family == UInt8(AF_INET) ? "inet" : "inet6")  \(addr)")
            }
        }
        return IO(out: joinLines(lines))
    }

    private func chmod(_ args: [String], context: Context) -> IO {
        guard args.count >= 2, let mode = Int(args[0], radix: 8) else {
            return IO(err: "chmod: usage: chmod <octal-mode> <file…>", status: 1)
        }
        for file in args.dropFirst() {
            guard let target = resolve(file, context: context),
                  FileManager.default.fileExists(atPath: target.url.path) else {
                return IO(err: "chmod: no such file: \(file)", status: 1)
            }
            do { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.url.path) }
            catch { return IO(err: "chmod: \(error.localizedDescription)", status: 1) }
        }
        return IO()
    }

    private static func uptimeString() -> String {
        let up = Int(ProcessInfo.processInfo.systemUptime)
        let days = up / 86400, hours = (up % 86400) / 3600, minutes = (up % 3600) / 60
        var pieces: [String] = []
        if days > 0 { pieces.append("\(days)d") }
        if hours > 0 { pieces.append("\(hours)h") }
        pieces.append("\(minutes)m")
        return pieces.joined(separator: " ")
    }

    /// The app's physical memory footprint (the number Xcode's gauge shows), via task_info.
    private static func memoryFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    private func mkdir(_ args: [String], context: Context) -> IO {
        let dirs = args.filter { !$0.hasPrefix("-") }   // -p is the behavior anyway
        guard !dirs.isEmpty else { return IO(err: "mkdir: usage: mkdir [-p] <dir…>", status: 1) }
        for dir in dirs {
            guard let target = resolve(dir, context: context) else {
                return IO(err: "mkdir: bad path: \(dir)", status: 1)
            }
            do {
                try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
            } catch {
                return IO(err: "mkdir: \(error.localizedDescription)", status: 1)
            }
        }
        return IO()
    }

    private func touch(_ args: [String], context: Context) -> IO {
        guard !args.isEmpty else { return IO(err: "touch: usage: touch <file…>", status: 1) }
        for arg in args {
            guard let target = resolve(arg, context: context) else {
                return IO(err: "touch: bad path: \(arg)", status: 1)
            }
            if !FileManager.default.fileExists(atPath: target.url.path) {
                FileManager.default.createFile(atPath: target.url.path, contents: Data())
                context.markModified(target.rel)
            }
        }
        return IO()
    }

    private func rm(_ args: [String], context: Context) -> IO {
        let recursive = args.contains("-r")
        let targets = args.filter { $0 != "-r" }
        guard !targets.isEmpty else { return IO(err: "rm: usage: rm [-r] <path…>", status: 1) }
        for arg in targets {
            guard let target = resolve(arg, context: context) else { return IO(err: "rm: invalid path: \(arg)", status: 1) }
            guard !target.rel.isEmpty else { return IO(err: "rm: refusing to remove the workspace root", status: 1) }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDirectory) else {
                return IO(err: "rm: no such path: \(display(target.rel))", status: 1)
            }
            if isDirectory.boolValue && !recursive {
                return IO(err: "rm: is a directory (use rm -r): \(display(target.rel))", status: 1)
            }
            do { try FileManager.default.removeItem(at: target.url) } catch {
                return IO(err: "rm: \(error.localizedDescription)", status: 1)
            }
        }
        return IO()
    }

    private func moveOrCopy(_ args: [String], copy: Bool, context: Context) -> IO {
        let name = copy ? "cp" : "mv"
        guard args.count >= 2,
              let source = resolve(args[0], context: context),
              let destination = resolve(args[1], context: context) else {
            return IO(err: "\(name): usage: \(name) <source> <destination>", status: 1)
        }
        do {
            if copy {
                try FileManager.default.copyItem(at: source.url, to: destination.url)
            } else {
                try FileManager.default.moveItem(at: source.url, to: destination.url)
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: destination.url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                context.markModified(destination.rel)
            }
            return IO()
        } catch {
            return IO(err: "\(name): \(error.localizedDescription)", status: 1)
        }
    }

    private func headTail(_ args: [String], stdin: String, fromStart: Bool, context: Context) -> IO {
        var count = 10
        var fileArg: String?
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "-n", let value = iterator.next() { count = Int(value) ?? 10 }
            else if !arg.hasPrefix("-") { fileArg = arg }
        }
        let text: String
        if let fileArg {
            guard let target = resolve(fileArg, context: context),
                  let contents = try? String(contentsOf: target.url, encoding: .utf8) else {
                return IO(err: "\(fromStart ? "head" : "tail"): can't read \(fileArg)", status: 1)
            }
            text = contents
        } else {
            text = stdin
        }
        let all = splitLines(text)
        return IO(out: joinLines(Array(fromStart ? all.prefix(count) : all.suffix(count))))
    }

    private func wc(_ args: [String], stdin: String, context: Context) -> IO {
        let text = input(args, stdin: stdin, context: context)
        let lineCount = splitLines(text).count
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        let charCount = text.count
        if args.contains("-l") { return IO(out: "\(lineCount)\n") }
        if args.contains("-w") { return IO(out: "\(wordCount)\n") }
        if args.contains("-c") { return IO(out: "\(charCount)\n") }
        return IO(out: "\(lineCount) \(wordCount) \(charCount)\n")
    }

    private func sortCmd(_ args: [String], stdin: String, context: Context) -> IO {
        var lines = splitLines(input(args, stdin: stdin, context: context))
        lines.sort()
        if args.contains("-r") { lines.reverse() }
        return IO(out: joinLines(lines))
    }

    private func uniq(_ args: [String], stdin: String, context: Context) -> IO {
        let counted = args.contains("-c")
        var out: [String] = []
        var previous: String? = nil
        var count = 0
        func flush() {
            guard let line = previous else { return }
            out.append(counted ? "\(String(format: "%4d", count)) \(line)" : line)
        }
        for line in splitLines(input(args, stdin: stdin, context: context)) {
            if line == previous { count += 1 } else {
                flush()
                previous = line
                count = 1
            }
        }
        flush()
        return IO(out: joinLines(out))
    }

    private func tr(_ args: [String], stdin: String) -> IO {
        guard args.count >= 2 else { return IO(err: "tr: usage: tr <set1> <set2>", status: 1) }
        let from = Array(expandRanges(args[0]))
        let to = Array(expandRanges(args[1]))
        guard !from.isEmpty, !to.isEmpty else { return IO(err: "tr: empty set", status: 1) }
        let mapping = Dictionary(uniqueKeysWithValues: from.enumerated().map { index, ch in
            (ch, to[min(index, to.count - 1)])
        })
        return IO(out: String(stdin.map { mapping[$0] ?? $0 }))
    }

    private func expandRanges(_ set: String) -> String {
        var out = ""
        let chars = Array(set)
        var i = 0
        while i < chars.count {
            if i + 2 < chars.count, chars[i + 1] == "-",
               let low = chars[i].asciiValue, let high = chars[i + 2].asciiValue, low <= high {
                out += String((low...high).map { Character(UnicodeScalar($0)) })
                i += 3
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    private func cut(_ args: [String], stdin: String, context: Context) -> IO {
        var delimiter: Character = "\t"
        var fields: [Int] = []
        var files: [String] = []
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "-d", let value = iterator.next() { delimiter = value.first ?? "\t" }
            else if arg == "-f", let value = iterator.next() {
                fields = value.split(separator: ",").compactMap { Int($0) }
            } else if !arg.hasPrefix("-") { files.append(arg) }
        }
        guard !fields.isEmpty else { return IO(err: "cut: usage: cut -d X -f N[,M]", status: 1) }
        let out = splitLines(input(files, stdin: stdin, context: context)).map { line -> String in
            let columns = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
            return fields.compactMap { $0 >= 1 && $0 <= columns.count ? columns[$0 - 1] : nil }
                .joined(separator: String(delimiter))
        }
        return IO(out: joinLines(out))
    }

    private func seq(_ args: [String]) -> IO {
        let numbers = args.compactMap { Int($0) }
        let (low, high): (Int, Int)
        switch numbers.count {
        case 1: (low, high) = (1, numbers[0])
        case 2: (low, high) = (numbers[0], numbers[1])
        default: return IO(err: "seq: usage: seq [first] last", status: 1)
        }
        guard high >= low, high - low < 10_000 else { return IO(err: "seq: range too large", status: 1) }
        return IO(out: joinLines((low...high).map(String.init)))
    }

    private func grep(_ args: [String], stdin: String, context: Context) -> IO {
        let caseInsensitive = args.contains("-i")
        let positional = args.filter { !$0.hasPrefix("-") }
        guard let pattern = positional.first else {
            return IO(err: "grep: usage: grep [-i] <pattern> [file…]", status: 1)
        }
        let files = Array(positional.dropFirst())
        func matches(_ line: String) -> Bool {
            caseInsensitive ? line.localizedCaseInsensitiveContains(pattern) : line.contains(pattern)
        }
        var out: [String] = []
        if files.isEmpty {
            out = splitLines(stdin).filter(matches)
        } else {
            for file in files {
                guard let target = resolve(file, context: context),
                      let text = try? String(contentsOf: target.url, encoding: .utf8) else {
                    return IO(err: "grep: can't read \(file)", status: 1)
                }
                for (index, line) in splitLines(text).enumerated() where matches(line) {
                    out.append(files.count > 1 ? "\(file):\(index + 1): \(line)" : "\(index + 1): \(line)")
                    if out.count >= 200 { out.append("… stopped at 200 matches"); break }
                }
            }
        }
        return IO(out: joinLines(out), status: out.isEmpty ? 1 : 0)
    }

    private func find(_ args: [String], context: Context) -> IO {
        guard let arg = args.first else { return IO(err: "find: usage: find <name>", status: 1) }
        guard let start = resolve(".", context: context) else { return IO(status: 1) }
        let isGlob = arg.contains("*") || arg.contains("?") || arg.contains("[")
        var matches: [String] = []
        if let enumerator = FileManager.default.enumerator(at: start.url, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                let component = url.lastPathComponent
                if component == ".git" || component == "node_modules" {
                    enumerator.skipDescendants()
                    continue
                }
                let hit = isGlob
                    ? fnmatch(arg, component, 0) == 0
                    : component.localizedCaseInsensitiveContains(arg)
                if hit {
                    matches.append(url.path.replacingOccurrences(of: context.root.path + "/", with: ""))
                    if matches.count >= 200 { matches.append("… stopped at 200 matches"); break }
                }
            }
        }
        return IO(out: matches.isEmpty ? "" : joinLines(matches), status: matches.isEmpty ? 1 : 0)
    }

    private func export(_ args: [String]) -> IO {
        for arg in args {
            // Everything here is exported already (one process); a bare NAME is a no-op
            // that succeeds, NAME=value assigns.
            if let equals = arg.firstIndex(of: "=") {
                env[String(arg[..<equals])] = String(arg[arg.index(after: equals)...])
            }
        }
        return IO()
    }

    private func which(_ args: [String]) -> IO {
        guard let name = args.first else { return IO(err: "which: usage: which <name>", status: 1) }
        return Self.builtinNames.contains(name)
            ? IO(out: "\(name): msh built-in\n")
            : IO(err: "\(name) not found", status: 1)
    }

    private func open(_ args: [String], context: Context) -> IO {
        guard let arg = args.first, let target = resolve(arg, context: context) else {
            return IO(err: "open: usage: open <file>", status: 1)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return IO(err: "open: not a file: \(display(target.rel))", status: 1)
        }
        context.openFile(target.rel)
        return IO(out: "opened \(display(target.rel)) in the viewer\n")
    }

    // MARK: - git (the native engine: GitCore)

    private func git(_ args: [String], context: Context) async -> IO {
        guard let sub = args.first else {
            return IO(out: "usage: git <init|status|log|commit|branch|checkout|diff>\n")
        }
        let rest = Array(args.dropFirst())
        let root = context.root
        do {
            switch sub {
            case "init":
                try GitCore.initRepo(root)
                context.historyChanged()
                return IO(out: "initialized empty repository on main\n")
            case "status":
                guard GitCore.hasRepo(root) else { return IO(err: "git: not a repository (git init)", status: 1) }
                let status = try GitCore.status(in: root)
                if status.isClean { return IO(out: "clean\n") }
                var out: [String] = []
                out.append(contentsOf: status.added.map { "A  \($0)" })
                out.append(contentsOf: status.modified.map { "M  \($0)" })
                out.append(contentsOf: status.deleted.map { "D  \($0)" })
                return IO(out: joinLines(out))
            case "log":
                guard GitCore.hasRepo(root) else { return IO(err: "git: not a repository (git init)", status: 1) }
                let head = try GitCore.headCommit(in: root)
                let commits = try GitCore.log(from: head.sha, in: root)
                return IO(out: joinLines(commits.map { "\($0.sha.prefix(7))  \($0.message.components(separatedBy: "\n")[0])" }))
            case "commit":
                guard GitCore.hasRepo(root) else { return IO(err: "git: not a repository (git init)", status: 1) }
                var message = "commit from mouse"
                var iterator = rest.makeIterator()
                while let arg = iterator.next() {
                    if arg == "-m", let value = iterator.next() { message = value }
                }
                let sha = try GitCore.commitAll(in: root, message: message)
                context.historyChanged()
                return IO(out: "[\(GitCore.currentBranch(in: root) ?? "?") \(sha.prefix(7))] \(message)\n")
            case "branch":
                guard GitCore.hasRepo(root) else { return IO(err: "git: not a repository (git init)", status: 1) }
                if let name = rest.first {
                    try GitCore.createBranch(name, in: root)
                    context.historyChanged()
                    return IO()
                }
                let current = GitCore.currentBranch(in: root)
                let names = GitCore.branches(in: root).keys.sorted()
                return IO(out: joinLines(names.map { ($0 == current ? "* " : "  ") + $0 }))
            case "checkout", "switch":
                guard GitCore.hasRepo(root) else { return IO(err: "git: not a repository (git init)", status: 1) }
                guard let name = rest.first else { return IO(err: "git checkout: usage: git checkout <branch>", status: 1) }
                try GitCore.checkout(name, in: root)
                context.reloadTree()
                context.historyChanged()
                return IO(out: "switched to \(name)\n")
            case "diff":
                guard GitCore.hasRepo(root) else { return IO(err: "git: not a repository (git init)", status: 1) }
                let status = try GitCore.status(in: root)
                let paths = rest.isEmpty ? status.modified : rest
                var out: [String] = []
                for path in paths {
                    guard let old = GitCore.headText(of: path, in: root) else { continue }
                    let target = resolve(path, context: context)
                    let new = (try? String(contentsOf: target?.url ?? root, encoding: .utf8)) ?? ""
                    out.append("--- \(path)")
                    out.append(contentsOf: diffLines(splitLines(old), splitLines(new)))
                }
                return IO(out: joinLines(out))
            case "remote":
                guard GitCore.hasRepo(root) else { return IO(err: "git: not a repository (git init)", status: 1) }
                if rest.first == "add", rest.count >= 3 {
                    try GitCore.setRemote(rest[2], in: root)
                    return IO()
                }
                if let url = GitCore.remoteURL(in: root) { return IO(out: "origin\t\(url)\n") }
                return IO(out: "")
            case "push":
                guard GitCore.hasRepo(root) else { return IO(err: "git: not a repository (git init)", status: 1) }
                guard let token = context.githubToken(), let login = context.githubLogin() else {
                    return IO(err: "git: sign in with the GitHub container first", status: 1)
                }
                let branch = GitCore.currentBranch(in: root) ?? "main"
                // Target: an explicit remote, else "<login>/<project>" (auto-created on push).
                let repoFullName = remoteRepoName(root: root, login: login)
                let result = try await GitRemote.push(root: root, repoFullName: repoFullName, branch: branch, token: token, login: login)
                context.historyChanged()
                var lines: [String] = []
                if result.createdRepo { lines.append("created \(login)/\(repoFullName.split(separator: "/").last ?? "")") }
                lines.append(result.objectCount == 0
                    ? "everything up-to-date"
                    : "pushed \(result.objectCount) object\(result.objectCount == 1 ? "" : "s") to origin/\(branch)")
                return IO(out: joinLines(lines))
            case "fetch":
                guard GitCore.hasRepo(root), let url = GitCore.remoteURL(in: root) else {
                    return IO(err: "git: no origin remote", status: 1)
                }
                guard let token = context.githubToken() else { return IO(err: "git: sign in first", status: 1) }
                let repoFullName = repoName(fromRemoteURL: url)
                let result = try await GitRemote.fetch(root: root, repoFullName: repoFullName, token: token)
                context.historyChanged()
                return IO(out: "fetched \(result.objectCount) object\(result.objectCount == 1 ? "" : "s") from origin/\(result.branch)\n")
            case "pull":
                guard GitCore.hasRepo(root), let url = GitCore.remoteURL(in: root) else {
                    return IO(err: "git: no origin remote", status: 1)
                }
                guard let token = context.githubToken() else { return IO(err: "git: sign in first", status: 1) }
                let repoFullName = repoName(fromRemoteURL: url)
                let fetched = try await GitRemote.fetch(root: root, repoFullName: repoFullName, token: token)
                let branch = GitCore.currentBranch(in: root) ?? fetched.branch
                guard let local = GitCore.refSha(branch, in: root) else {
                    // No local commits yet: adopt the remote branch wholesale (first pull).
                    try GitCore.setRef(fetched.branch, to: fetched.sha, in: root)
                    try GitCore.setHead(branch: fetched.branch, in: root)
                    try GitCore.checkout(fetched.branch, in: root)
                    context.reloadTree()
                    context.historyChanged()
                    return IO(out: "pulled \(fetched.objectCount) object\(fetched.objectCount == 1 ? "" : "s"), now at \(fetched.sha.prefix(7))\n")
                }
                if local != fetched.sha, try GitCore.mergeBase(local, fetched.sha, in: root) != fetched.sha {
                    // A real integration is coming: refuse over uncommitted edits, like git does.
                    guard try GitCore.status(in: root).isClean else {
                        return IO(err: "git pull: you have uncommitted changes — commit first", status: 1)
                    }
                }
                let merged = try GitCore.merge(commit: fetched.sha, label: "origin/\(fetched.branch)", in: root)
                context.reloadTree()
                context.historyChanged()
                switch merged {
                case .upToDate:
                    return IO(out: "already up to date\n")
                case .fastForward(let sha):
                    return IO(out: "fast-forward to \(sha.prefix(7))\n")
                case .merged(let sha):
                    return IO(out: "merge made by the three-way strategy (\(sha.prefix(7)))\n")
                case .conflicts(let files):
                    return IO(err: "conflicts in \(files.joined(separator: ", ")) — resolve the markers and commit", status: 1)
                }
            case "merge":
                guard GitCore.hasRepo(root) else { return IO(err: "git: not a repository (git init)", status: 1) }
                guard let name = rest.first else { return IO(err: "git merge: usage: git merge <branch>", status: 1) }
                let result = try GitCore.merge(name, in: root)
                context.reloadTree()
                context.historyChanged()
                switch result {
                case .upToDate:
                    return IO(out: "already up to date\n")
                case .fastForward(let sha):
                    return IO(out: "fast-forward to \(sha.prefix(7))\n")
                case .merged(let sha):
                    return IO(out: "merge made by the three-way strategy (\(sha.prefix(7)))\n")
                case .conflicts(let files):
                    return IO(err: "conflicts in \(files.joined(separator: ", ")) — resolve the markers and commit", status: 1)
                }
            case "clone":
                return IO(err: "git clone: not built yet", status: 1)
            default:
                return IO(err: "git: unknown command: \(sub)", status: 1)
            }
        } catch {
            return IO(err: "git: \(error)", status: 1)
        }
    }

    /// The GitHub "owner/name" for a push target: the origin remote if one is set, else the
    /// project's own name under the signed-in user (which push auto-creates).
    private func remoteRepoName(root: URL, login: String) -> String {
        if let url = GitCore.remoteURL(in: root) { return repoName(fromRemoteURL: url) }
        let leaf = root.lastPathComponent.replacingOccurrences(of: "local__", with: "")
        return "\(login)/\(leaf)"
    }

    private func repoName(fromRemoteURL url: String) -> String {
        var name = url
        if let range = name.range(of: "github.com/") { name = String(name[range.upperBound...]) }
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return name
    }

    // MARK: - Streaming & network commands

    private func sleepCmd(_ args: [String]) async -> IO {
        guard let seconds = args.first.flatMap(Double.init), seconds >= 0, seconds <= 3600 else {
            return IO(err: "sleep: usage: sleep <seconds>", status: 1)
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return IO(status: Task.isCancelled ? 130 : 0)
    }

    /// Real ICMP echo — an unprivileged ICMP datagram socket, the platform-sanctioned way
    /// (Apple's SimplePing pattern; no entitlements). Solo it streams a line per second until
    /// any keypress interrupts; in a pipeline it collects (default -c 4) so `ping | grep` works.
    private func ping(_ args: [String], context: Context, streaming: Bool) async -> IO {
        var count: Int? = nil
        var host: String? = nil
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "-c", let value = iterator.next() { count = Int(value) }
            else if !arg.hasPrefix("-") { host = arg }
        }
        guard let host else { return IO(err: "ping: usage: ping [-c N] <host>", status: 1) }
        let limit = count ?? (streaming ? Int.max : 4)
        guard limit > 0 else { return IO(err: "ping: count must be positive", status: 1) }
        guard let address = await ICMPPinger.resolve(host) else {
            return IO(err: "ping: cannot resolve \(host)", status: 1)
        }
        guard let pinger = ICMPPinger(address: address) else {
            return IO(err: "ping: icmp socket unavailable here", status: 1)
        }
        defer { pinger.shutdown() }

        var collected: [String] = []
        func line(_ text: String) {
            if streaming { context.emit(Output(text: text, isError: false)) } else { collected.append(text) }
        }
        line("PING \(host) (\(pinger.addressString)): 56 data bytes")
        var sent = 0
        var received = 0
        var sequence: UInt16 = 0
        while sent < limit, !Task.isCancelled {
            sequence &+= 1
            sent += 1
            let start = Date()
            let rtt = await pinger.pingOnce(sequence: sequence, timeout: 2.0)
            if Task.isCancelled { break }
            if let rtt {
                received += 1
                line(String(format: "64 bytes from %@: icmp_seq=%d time=%.2f ms",
                            pinger.addressString, Int(sequence), rtt * 1000))
            } else {
                line("request timeout for icmp_seq \(sequence)")
            }
            if sent < limit {
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < 1 { try? await Task.sleep(nanoseconds: UInt64(max(0, 1 - elapsed) * 1_000_000_000)) }
            }
        }
        let loss = sent == 0 ? 0 : Int((Double(sent - received) / Double(sent) * 100).rounded())
        line("--- \(host) ping statistics ---")
        line("\(sent) packets transmitted, \(received) packets received, \(loss)% packet loss")
        return IO(out: streaming ? "" : joinLines(collected), status: received > 0 ? 0 : 1)
    }

    private func curl(_ args: [String], context: Context) async -> IO {
        var outFile: String? = nil
        var urlString: String? = nil
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "-o" { outFile = iterator.next() }
            else if !arg.hasPrefix("-") { urlString = arg }
        }
        guard var urlString else { return IO(err: "curl: usage: curl [-o file] <url>", status: 1) }
        if !urlString.contains("://") { urlString = "https://" + urlString }
        guard let url = URL(string: urlString) else { return IO(err: "curl: bad url", status: 1) }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let outFile {
                guard let target = resolve(outFile, context: context), !target.rel.isEmpty else {
                    return IO(err: "curl: bad output path: \(outFile)", status: 1)
                }
                try data.write(to: target.url)
                context.markModified(target.rel)
                return IO(out: "saved \(display(target.rel)) (\(data.count) bytes, HTTP \(code))\n",
                          status: code >= 400 ? 22 : 0)
            }
            guard data.count < 400_000 else {
                return IO(out: "curl: response too large to print (\(data.count / 1024) KB), use -o <file>\n",
                          status: code >= 400 ? 22 : 0)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return IO(out: "curl: binary response (\(data.count) bytes), use -o <file>\n",
                          status: code >= 400 ? 22 : 0)
            }
            return IO(out: text, status: code >= 400 ? 22 : 0)
        } catch {
            return IO(err: "curl: \(error.localizedDescription)", status: 7)
        }
    }

    // MARK: - Text tools

    private func tee(_ args: [String], stdin: String, context: Context) -> IO {
        let append = args.contains("-a")
        for file in args.filter({ !$0.hasPrefix("-") }) {
            if let failure = write(stdin, to: file, append: append, context: context) {
                return IO(err: failure, status: 1)
            }
        }
        return IO(out: stdin)
    }

    private func xargs(_ args: [String], stdin: String, context: Context) async -> IO {
        let base = args.isEmpty ? ["echo"] : args
        let extra = stdin.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return await dispatch(base + extra, stdin: "", context: context)
    }

    private func nl(_ args: [String], stdin: String, context: Context) -> IO {
        let lines = splitLines(input(args, stdin: stdin, context: context))
        return IO(out: joinLines(lines.enumerated().map { String(format: "%6d  %@", $0.offset + 1, $0.element) }))
    }

    private func base64Cmd(_ args: [String], stdin: String, context: Context) -> IO {
        let decode = args.contains("-d")
        let text = input(args.filter { $0 != "-d" }, stdin: stdin, context: context)
        if decode {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: trimmed),
                  let decoded = String(data: data, encoding: .utf8) else {
                return IO(err: "base64: invalid input", status: 1)
            }
            return IO(out: decoded)
        }
        return IO(out: Data(text.utf8).base64EncodedString() + "\n")
    }

    private func checksum(_ args: [String], stdin: String, context: Context, sha: Bool) -> IO {
        let files = args.filter { !$0.hasPrefix("-") }
        func digest(_ data: Data) -> String {
            sha ? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                : Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        guard !files.isEmpty else { return IO(out: digest(Data(stdin.utf8)) + "  -\n") }
        var out: [String] = []
        for file in files {
            guard let target = resolve(file, context: context),
                  let data = try? Data(contentsOf: target.url) else {
                return IO(err: "\(sha ? "sha256sum" : "md5sum"): can't read \(file)", status: 1)
            }
            out.append("\(digest(data))  \(file)")
        }
        return IO(out: joinLines(out))
    }

    /// `sed 's/regex/replacement/[g]'` — substitution only, ICU regex syntax (the honest
    /// subset; full sed is a language). Any delimiter after `s` works: s|a|b|.
    private func sed(_ args: [String], stdin: String, context: Context) -> IO {
        guard let script = args.first, script.hasPrefix("s"), script.count >= 4 else {
            return IO(err: "sed: usage: sed 's/regex/replacement/[g]' [file]", status: 1)
        }
        let delimiter = script[script.index(script.startIndex, offsetBy: 1)]
        let pieces = script.dropFirst(2).split(separator: delimiter, omittingEmptySubsequences: false)
        guard pieces.count >= 2 else { return IO(err: "sed: bad substitution: \(script)", status: 1) }
        let pattern = String(pieces[0])
        // sed-style \1 backreferences → ICU-style $1
        var replacement = String(pieces[1])
        for group in 1...9 {
            replacement = replacement.replacingOccurrences(of: "\\\(group)", with: "$\(group)")
        }
        let global = pieces.count > 2 && pieces[2].contains("g")
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return IO(err: "sed: bad regex: \(pattern)", status: 1)
        }
        let text = input(Array(args.dropFirst()), stdin: stdin, context: context)
        let out = splitLines(text).map { line -> String in
            let range = NSRange(line.startIndex..., in: line)
            if global {
                return regex.stringByReplacingMatches(in: line, range: range, withTemplate: replacement)
            }
            guard let match = regex.firstMatch(in: line, range: range) else { return line }
            let mutable = NSMutableString(string: line)
            regex.replaceMatches(in: mutable, range: match.range, withTemplate: replacement)
            return mutable as String
        }
        return IO(out: joinLines(out))
    }

    /// Minimal line diff (LCS): unified-style hunks. Big inputs fall back to a whole-block
    /// comparison rather than pretending precision.
    private func diff(_ args: [String], context: Context) -> IO {
        guard args.count == 2,
              let a = resolve(args[0], context: context),
              let b = resolve(args[1], context: context),
              let textA = try? String(contentsOf: a.url, encoding: .utf8),
              let textB = try? String(contentsOf: b.url, encoding: .utf8) else {
            return IO(err: "diff: usage: diff <fileA> <fileB>", status: 1)
        }
        let linesA = splitLines(textA)
        let linesB = splitLines(textB)
        if linesA == linesB { return IO(status: 0) }
        return IO(out: joinLines(diffLines(linesA, linesB)), status: 1)
    }

    /// Minimal line diff (LCS): -/+ lines, shared by the `diff` builtin and `git diff`.
    private func diffLines(_ linesA: [String], _ linesB: [String]) -> [String] {
        guard linesA.count * linesB.count <= 4_000_000 else {
            return ["files differ (\(linesA.count) vs \(linesB.count) lines)"]
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: linesB.count + 1), count: linesA.count + 1)
        for i in stride(from: linesA.count - 1, through: 0, by: -1) {
            for j in stride(from: linesB.count - 1, through: 0, by: -1) {
                table[i][j] = linesA[i] == linesB[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < linesA.count || j < linesB.count {
            if i < linesA.count, j < linesB.count, linesA[i] == linesB[j] {
                i += 1; j += 1
            } else if j == linesB.count || (i < linesA.count && table[i + 1][j] >= table[i][j + 1]) {
                out.append("- \(linesA[i])"); i += 1
            } else {
                out.append("+ \(linesB[j])"); j += 1
            }
            if out.count > 500 { out.append("… diff truncated at 500 lines"); break }
        }
        return out
    }

    // MARK: - Helpers

    /// Stdin, or the concatenation of any file arguments (for text filters).
    private func input(_ args: [String], stdin: String, context: Context) -> String {
        let files = args.filter { !$0.hasPrefix("-") }
        guard !files.isEmpty else { return stdin }
        return files.compactMap { file in
            resolve(file, context: context).flatMap { try? String(contentsOf: $0.url, encoding: .utf8) }
        }.joined()
    }

    private func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // trailing newline is a terminator, not a line
        return lines
    }

    private func joinLines(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Resolve a path against the cwd. `/`-prefixed means the workspace root; `..` is clamped
    /// at the root, so the workspace can never be escaped.
    private func resolve(_ arg: String, context: Context) -> (rel: String, url: URL)? {
        var components = arg.hasPrefix("/") ? [] : cwd.split(separator: "/").map(String.init)
        for piece in arg.split(separator: "/") {
            switch piece {
            case ".", "": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(piece))
            }
        }
        let rel = components.joined(separator: "/")
        return (rel, rel.isEmpty ? context.root : context.root.appendingPathComponent(rel))
    }

    private func display(_ rel: String) -> String { rel.isEmpty ? "/" : rel }
}

/// Unprivileged ICMP echo on Apple platforms: `SOCK_DGRAM` + `IPPROTO_ICMP` needs no
/// entitlements (the SimplePing pattern). The kernel rewrites the identifier on these
/// sockets, so replies are matched by sequence number. Socket I/O runs on a background
/// queue — the shell awaits each round trip without blocking the main actor.
final class ICMPPinger: @unchecked Sendable {
    private let fd: Int32
    private let address: sockaddr_in
    let addressString: String

    init?(address: sockaddr_in) {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        self.address = address
        var mutable = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &mutable.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        // String(cString: [CChar]) is deprecated: truncate at the NUL, decode as UTF-8.
        addressString = String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    func shutdown() {
        close(fd)
    }

    static func resolve(_ host: String) async -> sockaddr_in? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_DGRAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(result) }
                let resolved = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                continuation.resume(returning: resolved)
            }
        }
    }

    /// One echo round trip: send, wait up to `timeout` for the matching reply, return RTT.
    func pingOnce(sequence: UInt16, timeout: Double) async -> Double? {
        let fd = self.fd
        let target = address
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var destination = target
                // Echo request: 8-byte header + 56-byte pattern payload = classic 64 bytes.
                var packet = [UInt8](repeating: 0, count: 64)
                packet[0] = 8   // ICMP_ECHO
                packet[6] = UInt8(sequence >> 8)
                packet[7] = UInt8(sequence & 0xff)
                for i in 8..<packet.count { packet[i] = UInt8(i) }
                let sum = Self.checksum(packet)
                packet[2] = UInt8(sum >> 8)
                packet[3] = UInt8(sum & 0xff)

                let start = Date()
                let sent = packet.withUnsafeBytes { raw in
                    withUnsafePointer(to: &destination) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                guard sent == packet.count else {
                    continuation.resume(returning: nil)
                    return
                }

                let deadline = start.addingTimeInterval(timeout)
                var pollTarget = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                while Date() < deadline {
                    let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                    guard poll(&pollTarget, 1, remaining) > 0 else { break }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    let received = recv(fd, &buffer, buffer.count, 0)
                    guard received > 0 else { break }
                    // Darwin prepends the IP header on these sockets; skip it by IHL.
                    var offset = 0
                    if received >= 20, buffer[0] >> 4 == 4 { offset = Int(buffer[0] & 0x0f) * 4 }
                    guard received - offset >= 8, buffer[offset] == 0 else { continue }   // ICMP_ECHOREPLY
                    let replySequence = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
                    guard replySequence == sequence else { continue }
                    continuation.resume(returning: Date().timeIntervalSince(start))
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    /// RFC 1071 internet checksum: ones' complement of the ones' complement sum.
    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum &+= UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum &+= UInt32(bytes[i]) << 8 }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }
}
