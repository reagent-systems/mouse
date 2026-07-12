import Foundation
import Darwin

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
final class MouseShell {

    /// Wiring to the app: filesystem root plus the side effects a shell can cause.
    struct Context {
        let root: URL
        var markModified: (String) -> Void = { _ in }
        var openFile: (String) -> Void = { _ in }
        var clear: () -> Void = {}
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
    func execute(_ rawLine: String, context: Context) -> (outputs: [Output], echoExpansion: String?) {
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

        let tokens: [Token]
        do {
            tokens = try lex(line)
        } catch let error as ShellError {
            lastStatus = 2
            return ([Output(text: "msh: \(error.message)", isError: true)], echo)
        } catch {
            lastStatus = 2
            return ([Output(text: "msh: parse error", isError: true)], echo)
        }

        var outputs: [Output] = []
        var index = 0
        var runNext = true   // connector logic: ; always, && on success, || on failure
        while index < tokens.count {
            // Collect one pipeline up to the next connector.
            var pipelineTokens: [Token] = []
            var connector = ";"
            while index < tokens.count {
                if case .op(let op) = tokens[index], op == ";" || op == "&&" || op == "||" {
                    connector = op
                    index += 1
                    break
                }
                pipelineTokens.append(tokens[index])
                index += 1
            }
            if runNext, !pipelineTokens.isEmpty {
                outputs.append(contentsOf: runPipeline(pipelineTokens, context: context))
            }
            switch connector {
            case "&&": runNext = runNext && lastStatus == 0
            case "||": runNext = runNext && lastStatus != 0
            default: runNext = true
            }
        }
        return (outputs, echo)
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

    // MARK: - Lexer

    private struct ShellError: Error { let message: String }

    private enum Quote { case none, single, double }

    /// A word is segments with their quoting, so expansion can respect it: single quotes are
    /// literal, double quotes expand variables but never glob, bare text does both.
    private struct WordPart {
        var text: String
        var quote: Quote
    }

    private enum Token {
        case word([WordPart])
        case op(String)   // | ; && || > >> <
    }

    private func lex(_ line: String) throws -> [Token] {
        var tokens: [Token] = []
        var parts: [WordPart] = []
        var current = ""
        var currentQuote = Quote.none

        func flushSegment() {
            if !current.isEmpty || currentQuote != .none {
                parts.append(WordPart(text: current, quote: currentQuote))
                current = ""
            }
        }
        func flushWord() {
            flushSegment()
            if !parts.isEmpty {
                tokens.append(.word(parts))
                parts = []
            }
        }

        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            switch currentQuote {
            case .single:
                if ch == "'" {
                    parts.append(WordPart(text: current, quote: .single)); current = ""
                    currentQuote = .none
                } else { current.append(ch) }
            case .double:
                if ch == "\"" {
                    parts.append(WordPart(text: current, quote: .double)); current = ""
                    currentQuote = .none
                } else if ch == "\\", line.index(after: i) < line.endIndex,
                          "\"\\$".contains(line[line.index(after: i)]) {
                    i = line.index(after: i)
                    current.append(line[i])
                } else { current.append(ch) }
            case .none:
                switch ch {
                case "'": flushSegment(); currentQuote = .single
                case "\"": flushSegment(); currentQuote = .double
                case "\\":
                    guard line.index(after: i) < line.endIndex else { throw ShellError(message: "trailing backslash") }
                    i = line.index(after: i)
                    // An escaped char is literal: carry it as a single-quoted segment.
                    flushSegment()
                    parts.append(WordPart(text: String(line[i]), quote: .single))
                case " ", "\t": flushWord()
                case "|", ";", "<", ">", "&":
                    flushWord()
                    let next = line.index(after: i) < line.endIndex ? line[line.index(after: i)] : " "
                    switch (ch, next) {
                    case ("&", "&"): tokens.append(.op("&&")); i = line.index(after: i)
                    case ("|", "|"): tokens.append(.op("||")); i = line.index(after: i)
                    case (">", ">"): tokens.append(.op(">>")); i = line.index(after: i)
                    case ("&", _): throw ShellError(message: "no job control (&)")
                    default: tokens.append(.op(String(ch)))
                    }
                default: current.append(ch)
                }
            }
            i = line.index(after: i)
        }
        guard currentQuote == .none else { throw ShellError(message: "unclosed quote") }
        flushWord()
        return tokens
    }

    // MARK: - Expansion

    private func expandVariables(in text: String) -> String {
        var result = ""
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "$", text.index(after: i) < text.endIndex {
                let next = text.index(after: i)
                if text[next] == "?" {
                    result += String(lastStatus)
                    i = text.index(after: next)
                    continue
                }
                if text[next] == "{" {
                    if let close = text[next...].firstIndex(of: "}") {
                        let name = String(text[text.index(after: next)..<close])
                        result += env[name] ?? ""
                        i = text.index(after: close)
                        continue
                    }
                } else {
                    var j = next
                    while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "_" {
                        j = text.index(after: j)
                    }
                    if j > next {
                        result += env[String(text[next..<j])] ?? ""
                        i = j
                        continue
                    }
                }
            }
            result.append(ch)
            i = text.index(after: i)
        }
        return result
    }

    /// Word → argv strings: variable expansion (quote-aware), tilde, then globbing.
    private func expand(_ parts: [WordPart], context: Context) -> [String] {
        var text = ""
        var globbable = ""   // only unquoted characters may act as glob metacharacters
        for (index, part) in parts.enumerated() {
            var piece = part.quote == .single ? part.text : expandVariables(in: part.text)
            if part.quote == .none, index == 0, piece.hasPrefix("~") {
                piece = "/" + piece.dropFirst()   // ~ is the workspace root
            }
            text += piece
            globbable += part.quote == .none ? piece : String(repeating: "\u{0}", count: piece.count)
        }
        // Glob only when an unquoted metacharacter survives expansion.
        var hasGlob = false
        for (textChar, marker) in zip(text, globbable) where marker != "\u{0}" {
            if textChar == "*" || textChar == "?" || textChar == "[" {
                hasGlob = true
                break
            }
        }
        if hasGlob {
            let matches = glob(text, context: context)
            if !matches.isEmpty { return matches }
        }
        return [text]
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

    // MARK: - Pipeline execution

    private struct Command {
        var argv: [String] = []
        var stdinFile: String?
        var stdoutFile: String?
        var appendOut = false
    }

    private struct IO {
        var out = ""
        var err = ""
        var status: Int32 = 0
    }

    private func runPipeline(_ tokens: [Token], context: Context) -> [Output] {
        // Parse: commands separated by |, each collecting argv + redirects.
        var commands: [Command] = []
        var command = Command()
        var pendingRedirect: String? = nil
        for token in tokens {
            switch token {
            case .op("|"):
                commands.append(command); command = Command()
            case .op(let op) where op == ">" || op == ">>" || op == "<":
                pendingRedirect = op
            case .word(let parts):
                let expanded = expand(parts, context: context)
                if let redirect = pendingRedirect {
                    guard let target = expanded.first else { break }
                    switch redirect {
                    case ">": command.stdoutFile = target; command.appendOut = false
                    case ">>": command.stdoutFile = target; command.appendOut = true
                    default: command.stdinFile = target
                    }
                    pendingRedirect = nil
                } else {
                    command.argv.append(contentsOf: expanded)
                }
            default: break
            }
        }
        if pendingRedirect != nil {
            lastStatus = 2
            return [Output(text: "msh: redirect needs a target", isError: true)]
        }
        commands.append(command)

        var outputs: [Output] = []
        var pipe = ""
        for (index, cmd) in commands.enumerated() {
            guard !cmd.argv.isEmpty else {
                lastStatus = 2
                if commands.count > 1 { outputs.append(Output(text: "msh: empty command in pipeline", isError: true)) }
                return outputs
            }
            var stdin = pipe
            if let file = cmd.stdinFile {
                guard let target = resolve(file, context: context),
                      let text = try? String(contentsOf: target.url, encoding: .utf8) else {
                    lastStatus = 1
                    outputs.append(Output(text: "msh: can't read \(file)", isError: true))
                    return outputs
                }
                stdin = text
            }
            var io = dispatch(cmd.argv, stdin: stdin, context: context)
            if !io.err.isEmpty {
                outputs.append(Output(text: io.err, isError: true))
            }
            let isLast = index == commands.count - 1
            if let file = cmd.stdoutFile {
                if let failure = write(io.out, to: file, append: cmd.appendOut, context: context) {
                    outputs.append(Output(text: failure, isError: true))
                    io.status = 1
                }
                if !isLast { pipe = "" }
            } else if isLast {
                if !io.out.isEmpty {
                    let trimmed = io.out.hasSuffix("\n") ? String(io.out.dropLast()) : io.out
                    if !trimmed.isEmpty { outputs.append(Output(text: trimmed, isError: false)) }
                }
            } else {
                pipe = io.out
            }
            lastStatus = io.status
        }
        return outputs
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

    private func dispatch(_ argv: [String], stdin: String, context: Context) -> IO {
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
        case "env": return IO(out: joinLines(env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }))
        case "export": return export(args)
        case "unset": args.forEach { env.removeValue(forKey: $0) }; return IO()
        case "history": return IO(out: joinLines(history.enumerated().map { "\($0.offset + 1)  \($0.element)" }))
        case "which": return which(args)
        case "basename": return IO(out: (args.first.map { ($0 as NSString).lastPathComponent } ?? "") + "\n")
        case "dirname": return IO(out: (args.first.map { ($0 as NSString).deletingLastPathComponent.isEmpty ? "." : ($0 as NSString).deletingLastPathComponent } ?? "") + "\n")
        case "open": return open(args, context: context)
        case "git", "npm", "pnpm", "node", "npx":
            return IO(err: "\(name): not built yet — the native \(name == "git" ? "git" : "package") engine is on the roadmap", status: 127)
        default:
            return IO(err: "msh: command not found: \(name) (type help)", status: 127)
        }
    }

    static let builtinNames: Set<String> = [
        "help", "clear", "pwd", "cd", "ls", "cat", "echo", "printf", "mkdir", "touch", "rm",
        "mv", "cp", "head", "tail", "wc", "sort", "uniq", "tr", "cut", "seq", "grep", "find",
        "date", "whoami", "true", "false", "env", "export", "unset", "history", "which",
        "basename", "dirname", "open",
    ]

    private static let helpText = """
    msh — built-ins:
      ls [-a] [path]   cd [path]     pwd           cat [file…]
      echo [-n]        printf        mkdir <dir>   touch <file>
      rm [-r]          mv <a> <b>    cp [-r]       head/tail [-n N]
      wc [-l -w -c]    sort [-r]     uniq [-c]     tr <set1> <set2>
      cut -d X -f N    seq [a] b     grep [-i] <pattern> [file…]
      find <name>      date          env           export NAME=value
      unset NAME       history (!!, !N)            which <name>
      basename/dirname open <file>   clear         help
    grammar: 'quotes' "with $VARS"  |  > >> <  ;  &&  ||  ~  *  ?  $?
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
        let showHidden = args.contains("-a")
        let path = args.first { !$0.hasPrefix("-") } ?? "."
        guard let target = resolve(path, context: context) else { return IO(err: "ls: invalid path", status: 1) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDirectory) else {
            return IO(err: "ls: no such path: \(display(target.rel))", status: 1)
        }
        guard isDirectory.boolValue else { return IO(out: display(target.rel) + "\n") }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: target.url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return IO(err: "ls: can't read: \(display(target.rel))", status: 1)
        }
        let names = entries
            .filter { showHidden || !$0.lastPathComponent.hasPrefix(".") }
            .map { url -> (String, Bool) in
                (url.lastPathComponent, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 }
                return lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
            }
            .map { $0.1 ? $0.0 + "/" : $0.0 }
        return IO(out: names.isEmpty ? "(empty)\n" : names.joined(separator: "  ") + "\n")
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

    private func mkdir(_ args: [String], context: Context) -> IO {
        guard let arg = args.first, let target = resolve(arg, context: context) else {
            return IO(err: "mkdir: usage: mkdir <dir>", status: 1)
        }
        do {
            try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
            return IO()
        } catch {
            return IO(err: "mkdir: \(error.localizedDescription)", status: 1)
        }
    }

    private func touch(_ args: [String], context: Context) -> IO {
        guard let arg = args.first, let target = resolve(arg, context: context) else {
            return IO(err: "touch: usage: touch <file>", status: 1)
        }
        if !FileManager.default.fileExists(atPath: target.url.path) {
            FileManager.default.createFile(atPath: target.url.path, contents: Data())
            context.markModified(target.rel)
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
            guard let equals = arg.firstIndex(of: "=") else {
                return IO(err: "export: usage: export NAME=value", status: 1)
            }
            env[String(arg[..<equals])] = String(arg[arg.index(after: equals)...])
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
