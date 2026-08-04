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
                               body: (EvalState) async throws -> Void) async throws {
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

        // ./script.sh, path/to/script.sh: a file in the workspace runs as a script.
        if name.contains("/") || name.hasSuffix(".sh") {
            if let resolved = resolve(name, context: state.context),
               FileManager.default.fileExists(atPath: resolved.url.path),
               let source = try? String(contentsOf: resolved.url, encoding: .utf8) {
                return try await runScript(source: source, name: name, args: args, stdin: stdin, state: state)
            }
        }

        let clean = !redirectedOut && state.sink.captureBuffer == nil
        let interactive = clean && state.interactiveAllowed
            && (pipelinePosition == .solo || pipelinePosition == .last)
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
            if case .returnStatus(let status) = control { lastStatus = status } else { throw control }
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
            default: throw control
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
        let range = prefix ? Array(0...chars.count) : Array((0...chars.count).reversed())
        // prefix: candidate length grows 0→n (shortest first); suffix mirrors.
        var lengths = range
        if longest { lengths = lengths.reversed() }
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
