import CryptoKit
import Darwin
import Foundation

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
                outputs.append(contentsOf: await runPipeline(pipelineTokens, context: context))
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

    private func runPipeline(_ tokens: [Token], context: Context) async -> [Output] {
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
            let isLastCommand = index == commands.count - 1
            let mayStream = commands.count == 1 && cmd.stdoutFile == nil
            var io = await dispatch(cmd.argv, stdin: stdin, context: context, streaming: mayStream && isLastCommand)
            if !io.err.isEmpty {
                outputs.append(Output(text: io.err, isError: true))
            }
            let isLast = isLastCommand
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

    private func dispatch(_ argv: [String], stdin: String, context: Context, streaming: Bool = false) async -> IO {
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
        case "npm", "pnpm", "node", "npx":
            return IO(err: "\(name): not built yet", status: 127)
        default:
            return IO(err: "msh: command not found: \(name) (type help)", status: 127)
        }
    }

    static let builtinNames: Set<String> = [
        "help", "clear", "pwd", "cd", "ls", "cat", "echo", "printf", "mkdir", "touch", "rm",
        "mv", "cp", "head", "tail", "wc", "sort", "uniq", "tr", "cut", "seq", "grep", "find",
        "date", "whoami", "true", "false", "env", "export", "unset", "history", "which",
        "basename", "dirname", "open", "sleep", "ping", "curl", "wget", "tee", "xargs",
        "rev", "tac", "nl", "base64", "md5sum", "md5", "sha256sum", "shasum", "sed", "diff",
        "git",
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
      sed 's/re/sub/g' diff <a> <b>  tee [-a]      xargs <cmd>
      nl               rev / tac     base64 [-d]   md5sum / sha256sum
      ping [-c N] <host>             curl [-o file] <url>       sleep <s>
    grammar: 'quotes' "with $VARS"  |  > >> <  ;  &&  ||  ~  *  ?  $?
      git <init|status|log|commit -m|branch|checkout|diff|push|fetch|remote>
    a streaming command (ping without -c) stops on any keypress
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
                let result = try await GitRemote.fetch(root: root, repoFullName: repoFullName, token: token, checkout: false)
                context.historyChanged()
                return IO(out: "fetched \(result.objectCount) object\(result.objectCount == 1 ? "" : "s") from origin/\(result.branch)\n")
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
            case "pull", "clone":
                return IO(err: "git \(sub): not built yet", status: 1)
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
