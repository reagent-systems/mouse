import Foundation

/// The msh LANGUAGE: lexer, AST, and parser — the difference between a command line and a
/// shell. `MouseShell` (Shell.swift) owns execution; this file owns structure, and contains
/// no I/O, no state, and no @MainActor, so it verifies headlessly and could parse a script
/// on any thread.
///
/// The grammar is the POSIX shell subset real scripts are written in — `if`/`for`/`while`/
/// `until`/`case`, functions, `$(…)` and backticks, `$((…))` — deliberately not bash-isms
/// (no arrays, no process substitution). `&` job control stays refused until processes are
/// real (system.md phase E).

// MARK: - Words and tokens

enum ShellQuote: Equatable {
    case none, single, double
    /// `$(…)` or backticks: text is the inner source, executed at expansion time. `quoted`
    /// remembers double-quote context — a quoted substitution never field-splits.
    case commandSub(quoted: Bool)
    /// `$((…))`: text is the arithmetic expression.
    case arithmetic(quoted: Bool)
}

/// A word is segments with their quoting, so expansion can respect it: single quotes are
/// literal, double quotes expand variables but never glob or field-split, bare text does all
/// three.
struct ShellWordPart {
    var text: String
    var quote: ShellQuote
}

typealias ShellWord = [ShellWordPart]

enum ShellToken {
    case word(ShellWord)
    case op(String)   // | ; ;; && || > >> < ( )
    case newline
}

struct ShellParseError: Error {
    let message: String
    /// True when the source simply ended too soon (unclosed quote, missing `fi`) — the
    /// prompt uses this to ask for a continuation line instead of erroring.
    var incomplete = false
}

// MARK: - Lexer

enum ShellLexer {
    static func lex(_ source: String) throws -> [ShellToken] {
        var tokens: [ShellToken] = []
        var parts: ShellWord = []
        var current = ""
        var quote = ShellQuote.none
        var atWordStart = true   // for comment detection: # opens a comment only here

        func flushSegment() {
            if !current.isEmpty || quote != .none {
                parts.append(ShellWordPart(text: current, quote: quote))
                current = ""
            }
        }
        func flushWord() {
            flushSegment()
            if !parts.isEmpty {
                tokens.append(.word(parts))
                parts = []
            }
            atWordStart = true
        }

        let chars = Array(source)
        var i = 0

        /// Scan from an opening delimiter to its match, honoring quotes; returns the inner
        /// text. `open`/`close` of "(" / ")" nest; backticks don't.
        func scanBalanced(open: Character, close: Character) throws -> String {
            var depth = 1
            var inner = ""
            var innerQuote: Character? = nil
            while i < chars.count {
                let c = chars[i]
                if let q = innerQuote {
                    if c == q { innerQuote = nil }
                    if c == "\\", q == "\"", i + 1 < chars.count { inner.append(c); i += 1; inner.append(chars[i]); i += 1; continue }
                    inner.append(c); i += 1; continue
                }
                if c == "'" || c == "\"" { innerQuote = c; inner.append(c); i += 1; continue }
                if c == open, open != close { depth += 1 }
                if c == close {
                    depth -= 1
                    if depth == 0 { i += 1; return inner }
                }
                inner.append(c)
                i += 1
            }
            throw ShellParseError(message: "unclosed \(open)", incomplete: true)
        }

        while i < chars.count {
            let ch = chars[i]
            switch quote {
            case .commandSub, .arithmetic:
                // `quote` only ever holds none/single/double; substitutions are captured
                // whole by scanBalanced and never become the scanning state.
                throw ShellParseError(message: "lexer state corrupted")
            case .single:
                if ch == "'" {
                    parts.append(ShellWordPart(text: current, quote: .single)); current = ""
                    quote = .none
                } else { current.append(ch) }
                i += 1
            case .double:
                if ch == "\"" {
                    parts.append(ShellWordPart(text: current, quote: .double)); current = ""
                    quote = .none
                    i += 1
                } else if ch == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                    current.append(chars[i + 1]); i += 2
                } else if ch == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                    // $( … ) inside double quotes: capture, keep surrounding text double-quoted.
                    if !current.isEmpty { parts.append(ShellWordPart(text: current, quote: .double)); current = "" }
                    i += 2
                    if i < chars.count, chars[i] == "(" {
                        i += 1
                        let inner = try scanBalanced(open: "(", close: ")")
                        guard i < chars.count, chars[i] == ")" else { throw ShellParseError(message: "unclosed $((", incomplete: true) }
                        i += 1
                        parts.append(ShellWordPart(text: inner, quote: .arithmetic(quoted: true)))
                    } else {
                        let inner = try scanBalanced(open: "(", close: ")")
                        parts.append(ShellWordPart(text: inner, quote: .commandSub(quoted: true)))
                    }
                } else if ch == "$", i + 1 < chars.count, chars[i + 1] == "{" {
                    current.append("$"); current.append("{")
                    i += 2
                    var depth = 1
                    while i < chars.count, depth > 0 {
                        if chars[i] == "{" { depth += 1 }
                        if chars[i] == "}" { depth -= 1 }
                        current.append(chars[i])
                        i += 1
                    }
                    guard depth == 0 else { throw ShellParseError(message: "unclosed ${", incomplete: true) }
                } else if ch == "`" {
                    if !current.isEmpty { parts.append(ShellWordPart(text: current, quote: .double)); current = "" }
                    i += 1
                    let inner = try scanBalanced(open: "`", close: "`")
                    parts.append(ShellWordPart(text: inner, quote: .commandSub(quoted: true)))
                } else {
                    current.append(ch); i += 1
                }
            case .none:
                switch ch {
                case "'": flushSegment(); quote = .single; atWordStart = false; i += 1
                case "\"": flushSegment(); quote = .double; atWordStart = false; i += 1
                case "\\":
                    guard i + 1 < chars.count else { throw ShellParseError(message: "trailing backslash", incomplete: true) }
                    if chars[i + 1] == "\n" { i += 2; continue }   // line continuation
                    flushSegment()
                    parts.append(ShellWordPart(text: String(chars[i + 1]), quote: .single))
                    atWordStart = false
                    i += 2
                case "#" where atWordStart && current.isEmpty && parts.isEmpty:
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                case " ", "\t":
                    flushWord(); i += 1
                case "\n":
                    flushWord(); tokens.append(.newline); i += 1
                case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                    flushSegment()
                    atWordStart = false
                    i += 2
                    if i < chars.count, chars[i] == "(" {
                        i += 1
                        let inner = try scanBalanced(open: "(", close: ")")
                        guard i < chars.count, chars[i] == ")" else { throw ShellParseError(message: "unclosed $((", incomplete: true) }
                        i += 1
                        parts.append(ShellWordPart(text: inner, quote: .arithmetic(quoted: false)))
                    } else {
                        let inner = try scanBalanced(open: "(", close: ")")
                        parts.append(ShellWordPart(text: inner, quote: .commandSub(quoted: false)))
                    }
                case "$" where i + 1 < chars.count && chars[i + 1] == "{":
                    // ${…} stays verbatim in the word; the expander re-parses it (it may
                    // hold nested $(…), which must not be captured out of context here).
                    current.append("$"); current.append("{")
                    atWordStart = false
                    i += 2
                    var depth = 1
                    while i < chars.count, depth > 0 {
                        if chars[i] == "{" { depth += 1 }
                        if chars[i] == "}" { depth -= 1 }
                        current.append(chars[i])
                        i += 1
                    }
                    guard depth == 0 else { throw ShellParseError(message: "unclosed ${", incomplete: true) }
                case "`":
                    flushSegment()
                    atWordStart = false
                    i += 1
                    let inner = try scanBalanced(open: "`", close: "`")
                    parts.append(ShellWordPart(text: inner, quote: .commandSub(quoted: false)))
                case "|", ";", "<", ">", "&", "(", ")":
                    flushWord()
                    let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
                    switch (ch, next) {
                    case ("&", "&"): tokens.append(.op("&&")); i += 2
                    case ("|", "|"): tokens.append(.op("||")); i += 2
                    case (">", ">"): tokens.append(.op(">>")); i += 2
                    case (";", ";"): tokens.append(.op(";;")); i += 2
                    // This used to say processes "arrive with the wasm runtime". They arrived —
                    // `pkg install python` runs CPython — and `&` still does not work, so the
                    // old reason had stopped being true. The real one: msh runs one command at
                    // a time, and a running program holds the terminal until a keypress stops it.
                    case ("&", _): throw ShellParseError(message: "no job control (&) — msh runs one command at a time; a running program holds the terminal until a keypress stops it")
                    default: tokens.append(.op(String(ch))); i += 1
                    }
                default:
                    current.append(ch)
                    atWordStart = false
                    i += 1
                }
            }
        }
        guard quote == .none else { throw ShellParseError(message: "unclosed quote", incomplete: true) }
        flushWord()
        return tokens
    }
}

// MARK: - AST

struct ShellRedirect {
    enum Kind { case stdoutWrite, stdoutAppend, stdinRead }
    var kind: Kind
    var target: ShellWord
}

indirect enum ShellNode {
    /// Statements run in order; `&&`/`||` chains are their own node.
    case list([ShellNode])
    case andOr(first: ShellNode, rest: [(op: String, node: ShellNode)])
    case pipeline(commands: [ShellNode], negated: Bool)
    case simple(assignments: [(name: String, value: ShellWord)], words: [ShellWord], redirects: [ShellRedirect])
    case ifClause(branches: [(condition: ShellNode, body: ShellNode)], elseBody: ShellNode?)
    /// `until` is `while` with the condition inverted.
    case whileClause(condition: ShellNode, body: ShellNode, until: Bool, redirects: [ShellRedirect])
    /// nil words = "$@" (POSIX default).
    case forClause(variable: String, words: [ShellWord]?, body: ShellNode, redirects: [ShellRedirect])
    case caseClause(subject: ShellWord, items: [(patterns: [ShellWord], body: ShellNode)])
    case functionDef(name: String, body: ShellNode)
    case braceGroup(ShellNode, redirects: [ShellRedirect])
}

// MARK: - Parser

struct ShellParser {
    private let tokens: [ShellToken]
    private var index = 0

    init(_ tokens: [ShellToken]) {
        self.tokens = tokens
    }

    static func parse(_ source: String) throws -> ShellNode {
        var parser = ShellParser(try ShellLexer.lex(source))
        return try parser.parseProgram()
    }

    // -- token helpers --------------------------------------------------------

    private var peek: ShellToken? { index < tokens.count ? tokens[index] : nil }

    private mutating func advance() -> ShellToken? {
        guard index < tokens.count else { return nil }
        defer { index += 1 }
        return tokens[index]
    }

    private mutating func skipNewlines() {
        while case .newline = peek { index += 1 }
    }

    private mutating func skipSeparators() {
        while true {
            if case .newline = peek { index += 1; continue }
            if case .op(";") = peek { index += 1; continue }
            break
        }
    }

    /// The word's literal text when it is a single unquoted segment — how keywords are
    /// recognized. `"if"` (quoted) is an argument, `if` is a keyword.
    private func literal(_ token: ShellToken?) -> String? {
        guard case .word(let parts) = token, parts.count == 1, parts[0].quote == ShellQuote.none else { return nil }
        return parts[0].text
    }

    private mutating func expectKeyword(_ keyword: String) throws {
        skipSeparators()
        guard literal(peek) == keyword else {
            throw ShellParseError(message: "expected '\(keyword)'", incomplete: peek == nil)
        }
        index += 1
    }

    private static let keywords: Set<String> = [
        "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done",
        "case", "esac", "in", "{", "}", "!",
    ]

    // -- grammar ----------------------------------------------------------------

    mutating func parseProgram() throws -> ShellNode {
        let list = try parseList(stoppers: [])
        skipSeparators()
        if let token = peek {
            if case .op(let op) = token { throw ShellParseError(message: "unexpected '\(op)'") }
            throw ShellParseError(message: "unexpected '\(literal(token) ?? "token")'")
        }
        return list
    }

    /// A sequence of and-or chains, ended by EOF or a keyword in `stoppers` (left unconsumed).
    private mutating func parseList(stoppers: Set<String>) throws -> ShellNode {
        var nodes: [ShellNode] = []
        while true {
            skipSeparators()
            guard let token = peek else { break }
            if case .op(")") = token { break }
            if case .op(";;") = token { break }
            if let word = literal(token), stoppers.contains(word) { break }
            nodes.append(try parseAndOr())
        }
        if stoppers.isEmpty == false, nodes.isEmpty { }
        return .list(nodes)
    }

    private mutating func parseAndOr() throws -> ShellNode {
        let first = try parsePipeline()
        var rest: [(op: String, node: ShellNode)] = []
        while case .op(let op) = peek, op == "&&" || op == "||" {
            index += 1
            skipNewlines()
            rest.append((op: op, node: try parsePipeline()))
        }
        if rest.isEmpty { return first }
        return .andOr(first: first, rest: rest)
    }

    private mutating func parsePipeline() throws -> ShellNode {
        var negated = false
        if literal(peek) == "!" {
            negated = true
            index += 1
        }
        var commands = [try parseCommand()]
        while case .op("|") = peek {
            index += 1
            skipNewlines()
            commands.append(try parseCommand())
        }
        if commands.count == 1 && !negated { return commands[0] }
        return .pipeline(commands: commands, negated: negated)
    }

    private mutating func parseCommand() throws -> ShellNode {
        skipNewlines()
        guard let token = peek else { throw ShellParseError(message: "expected a command", incomplete: true) }
        switch literal(token) {
        case "if": return try parseIf()
        case "while": return try parseWhile(until: false)
        case "until": return try parseWhile(until: true)
        case "for": return try parseFor()
        case "case": return try parseCase()
        case "{": return try parseBraceGroup()
        case "then", "else", "elif", "fi", "do", "done", "esac":
            throw ShellParseError(message: "unexpected '\(literal(token)!)'")
        default:
            return try parseSimpleOrFunction()
        }
    }

    private mutating func parseIf() throws -> ShellNode {
        index += 1   // 'if'
        var branches: [(condition: ShellNode, body: ShellNode)] = []
        let condition = try parseList(stoppers: ["then"])
        try expectKeyword("then")
        let body = try parseList(stoppers: ["elif", "else", "fi"])
        branches.append((condition, body))
        var elseBody: ShellNode? = nil
        while true {
            skipSeparators()
            switch literal(peek) {
            case "elif":
                index += 1
                let condition = try parseList(stoppers: ["then"])
                try expectKeyword("then")
                let body = try parseList(stoppers: ["elif", "else", "fi"])
                branches.append((condition, body))
            case "else":
                index += 1
                elseBody = try parseList(stoppers: ["fi"])
            case "fi":
                index += 1
                let node = ShellNode.ifClause(branches: branches, elseBody: elseBody)
                let redirects = try parseTrailingRedirects()
                return redirects.isEmpty ? node : .braceGroup(node, redirects: redirects)
            default:
                throw ShellParseError(message: "expected 'fi'", incomplete: peek == nil)
            }
        }
    }

    private mutating func parseWhile(until: Bool) throws -> ShellNode {
        index += 1
        let condition = try parseList(stoppers: ["do"])
        try expectKeyword("do")
        let body = try parseList(stoppers: ["done"])
        try expectKeyword("done")
        return .whileClause(condition: condition, body: body, until: until,
                            redirects: try parseTrailingRedirects())
    }

    private mutating func parseFor() throws -> ShellNode {
        index += 1
        guard let name = literal(advance()), isName(name) else {
            throw ShellParseError(message: "for: expected a variable name")
        }
        var words: [ShellWord]? = nil
        skipNewlines()
        if literal(peek) == "in" {
            index += 1
            var collected: [ShellWord] = []
            while case .word(let parts) = peek {
                collected.append(parts)
                index += 1
            }
            words = collected
        }
        try expectKeyword("do")
        let body = try parseList(stoppers: ["done"])
        try expectKeyword("done")
        return .forClause(variable: name, words: words, body: body,
                          redirects: try parseTrailingRedirects())
    }

    private mutating func parseCase() throws -> ShellNode {
        index += 1
        guard case .word(let subject) = advance() else {
            throw ShellParseError(message: "case: expected a word")
        }
        try expectKeyword("in")
        var items: [(patterns: [ShellWord], body: ShellNode)] = []
        while true {
            skipSeparators()
            if literal(peek) == "esac" { index += 1; break }
            guard peek != nil else { throw ShellParseError(message: "expected 'esac'", incomplete: true) }
            if case .op("(") = peek { index += 1 }   // optional leading (
            var patterns: [ShellWord] = []
            while true {
                guard case .word(let pattern) = advance() else {
                    throw ShellParseError(message: "case: expected a pattern", incomplete: peek == nil)
                }
                patterns.append(pattern)
                if case .op("|") = peek { index += 1; continue }
                break
            }
            guard case .op(")") = advance() else {
                throw ShellParseError(message: "case: expected ')'")
            }
            let body = try parseList(stoppers: ["esac"])
            items.append((patterns: patterns, body: body))
            if case .op(";;") = peek { index += 1 }
        }
        let node = ShellNode.caseClause(subject: subject, items: items)
        let redirects = try parseTrailingRedirects()
        return redirects.isEmpty ? node : .braceGroup(node, redirects: redirects)
    }

    private mutating func parseBraceGroup() throws -> ShellNode {
        index += 1   // '{'
        let body = try parseList(stoppers: ["}"])
        try expectKeyword("}")
        return .braceGroup(body, redirects: try parseTrailingRedirects())
    }

    /// `NAME() body`, or a plain command: assignments, words, redirects.
    private mutating func parseSimpleOrFunction() throws -> ShellNode {
        // Function definition: NAME ( ) command
        if let name = literal(peek), isName(name), !Self.keywords.contains(name),
           index + 2 < tokens.count,
           case .op("(") = tokens[index + 1], case .op(")") = tokens[index + 2] {
            index += 3
            skipNewlines()
            let body = try parseCommand()
            return .functionDef(name: name, body: body)
        }

        var assignments: [(name: String, value: ShellWord)] = []
        var words: [ShellWord] = []
        var redirects: [ShellRedirect] = []
        loop: while let token = peek {
            switch token {
            case .word(let parts):
                // NAME=value before the command name is an assignment.
                if words.isEmpty, let assignment = splitAssignment(parts) {
                    assignments.append(assignment)
                } else {
                    words.append(parts)
                }
                index += 1
            case .op(let op) where op == ">" || op == ">>" || op == "<":
                index += 1
                guard case .word(let target) = advance() else {
                    throw ShellParseError(message: "redirect needs a target", incomplete: peek == nil)
                }
                let kind: ShellRedirect.Kind = op == ">" ? .stdoutWrite : (op == ">>" ? .stdoutAppend : .stdinRead)
                redirects.append(ShellRedirect(kind: kind, target: target))
            default:
                break loop
            }
        }
        guard !assignments.isEmpty || !words.isEmpty || !redirects.isEmpty else {
            throw ShellParseError(message: "expected a command")
        }
        return .simple(assignments: assignments, words: words, redirects: redirects)
    }

    private mutating func parseTrailingRedirects() throws -> [ShellRedirect] {
        var redirects: [ShellRedirect] = []
        while case .op(let op) = peek, op == ">" || op == ">>" || op == "<" {
            index += 1
            guard case .word(let target) = advance() else {
                throw ShellParseError(message: "redirect needs a target", incomplete: peek == nil)
            }
            let kind: ShellRedirect.Kind = op == ">" ? .stdoutWrite : (op == ">>" ? .stdoutAppend : .stdinRead)
            redirects.append(ShellRedirect(kind: kind, target: target))
        }
        return redirects
    }

    private func splitAssignment(_ parts: ShellWord) -> (name: String, value: ShellWord)? {
        guard let first = parts.first, first.quote == ShellQuote.none,
              let equals = first.text.firstIndex(of: "=") else { return nil }
        let name = String(first.text[..<equals])
        guard isName(name) else { return nil }
        var value: ShellWord = []
        let rest = String(first.text[first.text.index(after: equals)...])
        if !rest.isEmpty { value.append(ShellWordPart(text: rest, quote: ShellQuote.none)) }
        value.append(contentsOf: parts.dropFirst())
        return (name: name, value: value)
    }

    private func isName(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

// MARK: - Arithmetic ($((…)))

/// Integer arithmetic with variables: `+ - * / %`, comparisons, `&& || !`, parentheses,
/// unary minus. Variables resolve through the lookup the shell provides (bare `x` or `$x`).
enum ShellArithmetic {
    static func evaluate(_ expression: String, lookup: @escaping (String) -> String?) throws -> Int {
        var parser = Parser(expression: Array(expression), lookup: lookup)
        let value = try parser.parseOr()
        parser.skipSpaces()
        guard parser.atEnd else { throw ShellParseError(message: "arithmetic: trailing garbage in '\(expression)'") }
        return value
    }

    private struct Parser {
        let expression: [Character]
        var index = 0
        let lookup: (String) -> String?

        var atEnd: Bool { index >= expression.count }

        mutating func skipSpaces() {
            while index < expression.count, expression[index] == " " || expression[index] == "\t" || expression[index] == "\n" { index += 1 }
        }

        mutating func match(_ text: String) -> Bool {
            skipSpaces()
            let chars = Array(text)
            guard index + chars.count <= expression.count else { return false }
            for (offset, ch) in chars.enumerated() where expression[index + offset] != ch { return false }
            // Don't take '<' when it's '<=' etc.
            if text == "<" || text == ">", index + 1 < expression.count, expression[index + 1] == "=" { return false }
            if text == "&" || text == "|" { return false }
            index += chars.count
            return true
        }

        mutating func parseOr() throws -> Int {
            var left = try parseAnd()
            while match("||") { let right = try parseAnd(); left = (left != 0 || right != 0) ? 1 : 0 }
            return left
        }

        mutating func parseAnd() throws -> Int {
            var left = try parseComparison()
            while match("&&") { let right = try parseComparison(); left = (left != 0 && right != 0) ? 1 : 0 }
            return left
        }

        mutating func parseComparison() throws -> Int {
            var left = try parseAdditive()
            while true {
                if match("==") { left = left == (try parseAdditive()) ? 1 : 0 }
                else if match("!=") { left = left != (try parseAdditive()) ? 1 : 0 }
                else if match("<=") { left = left <= (try parseAdditive()) ? 1 : 0 }
                else if match(">=") { left = left >= (try parseAdditive()) ? 1 : 0 }
                else if match("<") { left = left < (try parseAdditive()) ? 1 : 0 }
                else if match(">") { left = left > (try parseAdditive()) ? 1 : 0 }
                else { return left }
            }
        }

        mutating func parseAdditive() throws -> Int {
            var left = try parseMultiplicative()
            while true {
                if match("+") { left += try parseMultiplicative() }
                else if match("-") { left -= try parseMultiplicative() }
                else { return left }
            }
        }

        mutating func parseMultiplicative() throws -> Int {
            var left = try parseUnary()
            while true {
                if match("*") { left *= try parseUnary() }
                else if match("/") {
                    let right = try parseUnary()
                    guard right != 0 else { throw ShellParseError(message: "arithmetic: division by zero") }
                    left /= right
                } else if match("%") {
                    let right = try parseUnary()
                    guard right != 0 else { throw ShellParseError(message: "arithmetic: division by zero") }
                    left %= right
                } else { return left }
            }
        }

        mutating func parseUnary() throws -> Int {
            skipSpaces()
            if match("!") { return (try parseUnary()) == 0 ? 1 : 0 }
            if match("-") { return -(try parseUnary()) }
            if match("+") { return try parseUnary() }
            if match("(") {
                let value = try parseOr()
                skipSpaces()
                guard match(")") else { throw ShellParseError(message: "arithmetic: expected ')'") }
                return value
            }
            return try parseAtom()
        }

        mutating func parseAtom() throws -> Int {
            skipSpaces()
            guard index < expression.count else { throw ShellParseError(message: "arithmetic: expected a value") }
            var ch = expression[index]
            var isParameter = false
            if ch == "$" {
                // `$1`, `$x`: always a parameter lookup — `$1 + $2` are positionals, not digits.
                isParameter = true
                index += 1
                guard index < expression.count else { throw ShellParseError(message: "arithmetic: bad $") }
                ch = expression[index]
            }
            if ch.isNumber {
                var digits = ""
                while index < expression.count, expression[index].isNumber { digits.append(expression[index]); index += 1 }
                if isParameter { return Int(lookup(digits) ?? "0") ?? 0 }
                return Int(digits) ?? 0
            }
            if ch.isLetter || ch == "_" {
                var name = ""
                while index < expression.count, expression[index].isLetter || expression[index].isNumber || expression[index] == "_" {
                    name.append(expression[index]); index += 1
                }
                return Int(lookup(name) ?? "0") ?? 0
            }
            throw ShellParseError(message: "arithmetic: unexpected '\(ch)'")
        }
    }
}
