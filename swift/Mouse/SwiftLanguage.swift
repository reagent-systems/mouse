import Foundation

// The Swift language as Mouse reads it: lexer, syntax tree, recursive-descent parser. Pure — no
// I/O, no state, no platform — so it builds headlessly beside the compiler and VM that consume it
// (`SwiftBytecode.swift`, `SwiftVM.swift`). iOS will not run swiftc or anything it emits, so a
// Swift project runs here the way the tweet that started this did it: compiled to bytecode by us,
// then interpreted.
//
// The grammar is the everyday subset: declarations (func/struct/class/enum/protocol/extension),
// control flow, patterns, closures, optionals, errors, string interpolation, and enough of the
// type grammar to read annotations. Generics and access control are read and ignored — the VM is
// dynamically typed, and a program that typechecks under swiftc behaves the same without them.

struct SwiftSyntaxError: Error, CustomStringConvertible {
    let message: String
    let line: Int
    var description: String { "line \(line): \(message)" }
}

// MARK: - Tokens

struct SwiftToken {
    enum Kind: Equatable {
        case identifier
        case keyword
        case integer
        case float
        case string
        case op
        case punct
        case eof
    }

    var kind: Kind
    var text: String
    var line: Int
    /// Whitespace (or a comment) directly before the token. Swift decides prefix / postfix /
    /// binary for an operator by the whitespace on its two sides, so the lexer must keep it.
    var spaceBefore: Bool
    var newlineBefore: Bool
    var intValue: Int = 0
    var floatValue: Double = 0
    /// A string literal's pieces: literal text, or the tokens of an interpolated `\( … )`.
    var segments: [SwiftStringSegment] = []
}

enum SwiftStringSegment {
    case text(String)
    case code([SwiftToken])
}

enum SwiftLexer {
    static let keywords: Set<String> = [
        "let", "var", "func", "if", "else", "guard", "while", "repeat", "for", "in", "return",
        "break", "continue", "switch", "case", "default", "fallthrough", "struct", "class", "enum",
        "protocol", "extension", "init", "deinit", "self", "Self", "super", "nil", "true", "false",
        "import", "throw", "throws", "rethrows", "try", "catch", "do", "defer", "where", "is", "as",
        "static", "inout", "typealias", "subscript", "associatedtype", "operator", "actor",
    ]

    private static let operatorChars: Set<Character> = ["/", "=", "-", "+", "!", "*", "%", "<", ">", "&", "|", "^", "~", "?"]

    static func tokenize(_ source: String, firstLine: Int = 1) throws -> [SwiftToken] {
        let chars = Array(source)
        var tokens: [SwiftToken] = []
        var i = 0
        var line = firstLine
        var space = true
        var newline = true

        func peek(_ offset: Int = 0) -> Character? {
            i + offset < chars.count ? chars[i + offset] : nil
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; space = true; newline = true; continue }
            if c == " " || c == "\t" || c == "\r" { i += 1; space = true; continue }
            if c == "/" && peek(1) == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                space = true
                continue
            }
            if c == "/" && peek(1) == "*" {
                var depth = 0
                repeat {
                    if chars[i] == "/" && peek(1) == "*" { depth += 1; i += 2; continue }
                    if chars[i] == "*" && peek(1) == "/" { depth -= 1; i += 2; continue }
                    if chars[i] == "\n" { line += 1; newline = true }
                    i += 1
                } while depth > 0 && i < chars.count
                space = true
                continue
            }
            var token = SwiftToken(kind: .eof, text: "", line: line, spaceBefore: space, newlineBefore: newline)
            space = false
            newline = false

            if c.isLetter || c == "_" || c == "$" {
                let start = i
                i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
                token.text = String(chars[start..<i])
                token.kind = keywords.contains(token.text) ? .keyword : .identifier
            } else if c == "`" {
                let start = i + 1
                i += 1
                while i < chars.count && chars[i] != "`" { i += 1 }
                token.text = String(chars[start..<min(i, chars.count)])
                token.kind = .identifier
                i += 1
            } else if c.isNumber {
                try lexNumber(chars, &i, &token)
            } else if c == "\"" || (c == "#" && peek(1) == "\"") {
                try lexString(chars, &i, &line, &token)
            } else if c == "." && peek(1) == "." && (peek(2) == "." || peek(2) == "<") {
                token.kind = .op
                token.text = peek(2) == "." ? "..." : "..<"
                i += 3
            } else if c == "-" && peek(1) == ">" {
                token.kind = .punct
                token.text = "->"
                i += 2
            } else if operatorChars.contains(c) {
                let start = i
                // `?` and `!` directly after an operand are postfix and stand alone; otherwise
                // operator characters run together greedily (`!=`, `??`, `+=`, `&&`).
                if (c == "?" || c == "!") && !token.spaceBefore && !(c == "!" && peek(1) == "=")
                    && !(c == "?" && peek(1) == "?") {
                    i += 1
                } else {
                    i += 1
                    while i < chars.count, operatorChars.contains(chars[i]) {
                        // Stop before a postfix-looking `?`/`!` that belongs to the next operand?
                        // No: Swift itself lexes greedily; the parser splits where it must.
                        i += 1
                    }
                }
                token.kind = .op
                token.text = String(chars[start..<i])
            } else if "()[]{},:;.@#\\".contains(c) {
                token.kind = .punct
                token.text = String(c)
                i += 1
            } else {
                throw SwiftSyntaxError(message: "unexpected character '\(c)'", line: line)
            }
            tokens.append(token)
        }
        tokens.append(SwiftToken(kind: .eof, text: "", line: line, spaceBefore: true, newlineBefore: true))
        return tokens
    }

    private static func lexNumber(_ chars: [Character], _ i: inout Int, _ token: inout SwiftToken) throws {
        let start = i
        var radix = 10
        if chars[i] == "0", i + 1 < chars.count, "xbo".contains(chars[i + 1]) {
            radix = chars[i + 1] == "x" ? 16 : chars[i + 1] == "b" ? 2 : 8
            i += 2
        }
        var digits = ""
        var isFloat = false
        while i < chars.count {
            let ch = chars[i]
            if ch == "_" { i += 1; continue }
            if radix == 16 ? ch.isHexDigit : ch.isNumber {
                digits.append(ch); i += 1; continue
            }
            if radix == 10 && ch == "." && i + 1 < chars.count && chars[i + 1].isNumber && !isFloat {
                isFloat = true; digits.append(ch); i += 1; continue
            }
            if radix == 10 && (ch == "e" || ch == "E") {
                var j = i + 1
                if j < chars.count && (chars[j] == "-" || chars[j] == "+") { j += 1 }
                if j < chars.count && chars[j].isNumber {
                    isFloat = true
                    digits.append(contentsOf: String(chars[i..<j]))
                    i = j
                    continue
                }
            }
            break
        }
        token.text = String(chars[start..<i])
        if isFloat {
            token.kind = .float
            token.floatValue = Double(digits) ?? 0
        } else {
            token.kind = .integer
            guard let value = Int(digits, radix: radix) else {
                throw SwiftSyntaxError(message: "integer literal '\(token.text)' overflows Int", line: token.line)
            }
            token.intValue = value
        }
    }

    private static func lexString(_ chars: [Character], _ i: inout Int, _ line: inout Int, _ token: inout SwiftToken) throws {
        var hashes = 0
        while i < chars.count && chars[i] == "#" { hashes += 1; i += 1 }
        let multiline = i + 2 < chars.count && chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\""
        i += multiline ? 3 : 1
        let startLine = line
        var segments: [SwiftStringSegment] = []
        var text = ""
        let closing = String(repeating: "\"", count: multiline ? 3 : 1) + String(repeating: "#", count: hashes)
        let closeChars = Array(closing)

        func atClose() -> Bool {
            guard i + closeChars.count <= chars.count else { return false }
            return Array(chars[i..<i + closeChars.count]) == closeChars
        }

        while true {
            guard i < chars.count else {
                throw SwiftSyntaxError(message: "unterminated string literal", line: startLine)
            }
            if atClose() { i += closeChars.count; break }
            let ch = chars[i]
            if ch == "\n" {
                if !multiline { throw SwiftSyntaxError(message: "unterminated string literal", line: startLine) }
                line += 1
            }
            let escapeHashes = hashes > 0 ? Array(chars[min(i + 1, chars.count)..<min(i + 1 + hashes, chars.count)]) : []
            if ch == "\\" && (hashes == 0 || escapeHashes == Array(repeating: "#", count: hashes)) {
                i += 1 + hashes
                guard i < chars.count else { break }
                let e = chars[i]
                switch e {
                case "n": text.append("\n"); i += 1
                case "t": text.append("\t"); i += 1
                case "r": text.append("\r"); i += 1
                case "0": text.append("\0"); i += 1
                case "\\": text.append("\\"); i += 1
                case "\"": text.append("\""); i += 1
                case "'": text.append("'"); i += 1
                case "u":
                    i += 2
                    var hex = ""
                    while i < chars.count && chars[i] != "}" { hex.append(chars[i]); i += 1 }
                    i += 1
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        text.append(Character(scalar))
                    }
                case "(":
                    // Interpolation: find the balancing paren, skipping nested string literals.
                    var depth = 1
                    var j = i + 1
                    var inString = false
                    while j < chars.count {
                        let cj = chars[j]
                        if inString {
                            if cj == "\\" { j += 2; continue }
                            if cj == "\"" { inString = false }
                        } else if cj == "\"" {
                            inString = true
                        } else if cj == "(" {
                            depth += 1
                        } else if cj == ")" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        j += 1
                    }
                    guard j < chars.count else {
                        throw SwiftSyntaxError(message: "unterminated interpolation", line: line)
                    }
                    if !text.isEmpty { segments.append(.text(text)); text = "" }
                    var inner = try tokenize(String(chars[(i + 1)..<j]), firstLine: line)
                    inner.removeLast()
                    segments.append(.code(inner))
                    i = j + 1
                case "\n" where multiline:
                    // Line continuation: the newline and nothing else is dropped.
                    line += 1
                    i += 1
                default:
                    throw SwiftSyntaxError(message: "invalid escape sequence '\\\(e)'", line: line)
                }
                continue
            }
            text.append(ch)
            i += 1
        }
        if !text.isEmpty { segments.append(.text(text)) }
        if multiline { segments = stripMultiline(segments) }
        token.kind = .string
        token.segments = segments
    }

    /// A multi-line literal drops its first and last line breaks and the closing delimiter's
    /// indentation from every line.
    private static func stripMultiline(_ segments: [SwiftStringSegment]) -> [SwiftStringSegment] {
        var segs = segments
        // Indentation of the closing delimiter: the whitespace after the final newline.
        var indent = ""
        if case .text(let last)? = segs.last, let nl = last.lastIndex(of: "\n") {
            let tail = last[last.index(after: nl)...]
            if tail.allSatisfy({ $0 == " " || $0 == "\t" }) {
                indent = String(tail)
                segs[segs.count - 1] = .text(String(last[..<nl]))
            }
        }
        if case .text(let first)? = segs.first, first.hasPrefix("\n") {
            segs[0] = .text(String(first.dropFirst()))
        }
        guard !indent.isEmpty else { return segs }
        var result: [SwiftStringSegment] = []
        var atLineStart = true
        for seg in segs {
            switch seg {
            case .code:
                result.append(seg)
                atLineStart = false
            case .text(let t):
                var out = ""
                var rest = Substring(t)
                while !rest.isEmpty {
                    if atLineStart && rest.hasPrefix(indent) { rest = rest.dropFirst(indent.count) }
                    atLineStart = false
                    if let nl = rest.firstIndex(of: "\n") {
                        out += rest[...nl]
                        rest = rest[rest.index(after: nl)...]
                        atLineStart = true
                    } else {
                        out += rest
                        rest = ""
                    }
                }
                result.append(.text(out))
            }
        }
        return result
    }
}

// MARK: - Syntax tree

indirect enum SwiftTypeRef: CustomStringConvertible {
    case named(String, [SwiftTypeRef])
    case array(SwiftTypeRef)
    case dictionary(SwiftTypeRef, SwiftTypeRef)
    case optional(SwiftTypeRef)
    case tuple([SwiftTypeRef], labels: [String?])
    case function

    var description: String {
        switch self {
        case .named(let name, let args): args.isEmpty ? name : "\(name)<\(args.map(\.description).joined(separator: ", "))>"
        case .array(let e): "[\(e)]"
        case .dictionary(let k, let v): "[\(k): \(v)]"
        case .optional(let w): "\(w)?"
        case .tuple(let es, _): "(\(es.map(\.description).joined(separator: ", ")))"
        case .function: "function"
        }
    }

    /// The outermost name, looking through Optional (`Int?` → "Int").
    var baseName: String? {
        switch self {
        case .named(let name, _): name
        case .optional(let w): w.baseName
        default: nil
        }
    }
}

struct SwiftArgument {
    var label: String?
    var value: SwiftExpr
    var isInout = false
}

enum SwiftStringPart {
    case text(String)
    case expr(SwiftExpr)
}

indirect enum SwiftExpr {
    case intLit(Int)
    case doubleLit(Double)
    case stringLit([SwiftStringPart])
    case boolLit(Bool)
    case nilLit
    case identifier(String, line: Int)
    case selfRef
    case superMember(String)
    case implicitMember(String)
    case member(SwiftExpr, String, line: Int)
    /// `a?` inside an optional chain: the chain short-circuits to nil when `a` is nil.
    case optionalChain(SwiftExpr)
    case forceUnwrap(SwiftExpr, line: Int)
    case call(SwiftExpr, [SwiftArgument], line: Int)
    case subscriptAccess(SwiftExpr, [SwiftArgument], line: Int)
    case prefix(String, SwiftExpr, line: Int)
    case postfixRange(SwiftExpr)
    case binary(String, SwiftExpr, SwiftExpr, line: Int)
    case assign(String, SwiftExpr, SwiftExpr, line: Int)
    case ternary(SwiftExpr, SwiftExpr, SwiftExpr)
    case arrayLit([SwiftExpr])
    case dictionaryLit([(SwiftExpr, SwiftExpr)])
    case tuple([(label: String?, value: SwiftExpr)])
    case closure(SwiftClosure)
    case tryExpr(String, SwiftExpr)
    case isType(SwiftExpr, SwiftTypeRef)
    case cast(SwiftExpr, SwiftTypeRef, String)
    case typeExpr(SwiftTypeRef)
    case keyPath([String])
    case ifExpr(SwiftStmt)
}

final class SwiftClosure {
    var params: [SwiftParam]
    var body: [SwiftStmt]
    var line: Int
    init(params: [SwiftParam], body: [SwiftStmt], line: Int) {
        self.params = params
        self.body = body
        self.line = line
    }
}

struct SwiftParam {
    var label: String?
    var name: String
    var type: SwiftTypeRef?
    var defaultValue: SwiftExpr?
    var isInout = false
    var isVariadic = false
}

indirect enum SwiftPattern {
    case wildcard
    case binding(String)
    case expr(SwiftExpr)
    case tuple([SwiftPattern])
    case enumCase(String, [SwiftPattern]?)
    case optionalSome(SwiftPattern)
    case isType(SwiftTypeRef)
    case asType(SwiftPattern, SwiftTypeRef)

    var bindings: [String] {
        switch self {
        case .binding(let name): [name]
        case .tuple(let ps): ps.flatMap(\.bindings)
        case .enumCase(_, let ps): (ps ?? []).flatMap(\.bindings)
        case .optionalSome(let p): p.bindings
        case .asType(let p, _): p.bindings
        default: []
        }
    }
}

enum SwiftCondition {
    case expr(SwiftExpr)
    case optionalBinding(String, SwiftExpr)
    case pattern(SwiftPattern, SwiftExpr)
}

struct SwiftSwitchCase {
    var patterns: [SwiftPattern]
    var guardExpr: SwiftExpr?
    var body: [SwiftStmt]
    var isDefault: Bool
}

struct SwiftCatchClause {
    var pattern: SwiftPattern?
    var guardExpr: SwiftExpr?
    var body: [SwiftStmt]
}

indirect enum SwiftStmt {
    case expr(SwiftExpr, line: Int)
    case variable(SwiftVariableDecl)
    case ifStmt([SwiftCondition], [SwiftStmt], [SwiftStmt]?, line: Int)
    case guardStmt([SwiftCondition], [SwiftStmt], line: Int)
    case whileStmt([SwiftCondition], [SwiftStmt], label: String?, line: Int)
    case repeatWhile([SwiftStmt], SwiftExpr, label: String?, line: Int)
    case forIn(SwiftPattern, SwiftExpr, SwiftExpr?, [SwiftStmt], label: String?, line: Int)
    case switchStmt(SwiftExpr, [SwiftSwitchCase], label: String?, line: Int)
    case returnStmt(SwiftExpr?, line: Int)
    case breakStmt(String?, line: Int)
    case continueStmt(String?, line: Int)
    case fallthroughStmt(line: Int)
    case throwStmt(SwiftExpr, line: Int)
    case doCatch([SwiftStmt], [SwiftCatchClause], line: Int)
    case deferStmt([SwiftStmt])
    case function(SwiftFunctionDecl)
    case type(SwiftTypeDecl)
    case block([SwiftStmt])
    case typeAlias(String, SwiftTypeRef)
    case empty
}

final class SwiftFunctionDecl {
    var name: String
    var params: [SwiftParam]
    var returnType: SwiftTypeRef?
    var body: [SwiftStmt]?
    var isStatic = false
    var isMutating = false
    var isInit = false
    var isFailable = false
    var throwsErrors = false
    var attributes: Set<String> = []
    var line: Int

    init(name: String, params: [SwiftParam], returnType: SwiftTypeRef?, body: [SwiftStmt]?, line: Int) {
        self.name = name
        self.params = params
        self.returnType = returnType
        self.body = body
        self.line = line
    }

    var labels: [String?] { params.map(\.label) }
}

final class SwiftVariableDecl {
    var pattern: SwiftPattern
    var type: SwiftTypeRef?
    var initializer: SwiftExpr?
    var isLet: Bool
    var isStatic = false
    var attributes: Set<String> = []
    /// Computed property accessors: `get` and `set` (with its parameter name).
    var getter: [SwiftStmt]?
    var setter: (name: String, body: [SwiftStmt])?
    var willSet: (name: String, body: [SwiftStmt])?
    var didSet: (name: String, body: [SwiftStmt])?
    var line: Int

    init(pattern: SwiftPattern, type: SwiftTypeRef?, initializer: SwiftExpr?, isLet: Bool, line: Int) {
        self.pattern = pattern
        self.type = type
        self.initializer = initializer
        self.isLet = isLet
        self.line = line
    }

    var name: String? {
        if case .binding(let n) = pattern { return n }
        return nil
    }
}

struct SwiftEnumCaseDecl {
    var name: String
    var associated: [(label: String?, type: SwiftTypeRef)]?
    var rawValue: SwiftExpr?
}

final class SwiftTypeDecl {
    enum Kind: String { case structType = "struct", classType = "class", enumType = "enum", protocolType = "protocol", extensionType = "extension" }

    var kind: Kind
    var name: String
    var inherits: [String]
    var properties: [SwiftVariableDecl] = []
    var methods: [SwiftFunctionDecl] = []
    var cases: [SwiftEnumCaseDecl] = []
    var nested: [SwiftTypeDecl] = []
    var subscripts: [SwiftFunctionDecl] = []
    var aliases: [(String, SwiftTypeRef)] = []
    var attributes: Set<String> = []
    var line: Int

    init(kind: Kind, name: String, inherits: [String], line: Int) {
        self.kind = kind
        self.name = name
        self.inherits = inherits
        self.line = line
    }
}

// MARK: - Parser

struct SwiftParser {
    private var tokens: [SwiftToken]
    private var pos = 0
    /// Set while parsing an `if`/`while`/`guard`/`for`/`switch` head, where `{` opens the body
    /// and must not be read as a trailing closure.
    private var noTrailingClosure = false

    init(tokens: [SwiftToken]) {
        self.tokens = tokens
    }

    static func parse(_ source: String) throws -> [SwiftStmt] {
        var parser = SwiftParser(tokens: try SwiftLexer.tokenize(source))
        return try parser.parseProgram()
    }

    mutating func parseProgram() throws -> [SwiftStmt] {
        var stmts: [SwiftStmt] = []
        while !atEOF {
            if consumePunct(";") { continue }
            stmts.append(try parseStatement())
        }
        return stmts
    }

    // MARK: Token helpers

    private var current: SwiftToken { tokens[pos] }
    private var atEOF: Bool { current.kind == .eof }
    private func peekToken(_ offset: Int = 1) -> SwiftToken { tokens[min(pos + offset, tokens.count - 1)] }
    private mutating func advance() -> SwiftToken {
        let t = tokens[pos]
        if pos < tokens.count - 1 { pos += 1 }
        return t
    }

    private func isPunct(_ p: String) -> Bool { current.kind == .punct && current.text == p }
    private func isOp(_ o: String) -> Bool { current.kind == .op && current.text == o }
    private func isKeyword(_ k: String) -> Bool { current.kind == .keyword && current.text == k }
    private func isIdent(_ name: String) -> Bool { current.kind == .identifier && current.text == name }

    @discardableResult
    private mutating func consumePunct(_ p: String) -> Bool {
        if isPunct(p) { pos += 1; return true }
        return false
    }

    @discardableResult
    private mutating func consumeKeyword(_ k: String) -> Bool {
        if isKeyword(k) { pos += 1; return true }
        return false
    }

    @discardableResult
    private mutating func consumeOp(_ o: String) -> Bool {
        if isOp(o) { pos += 1; return true }
        return false
    }

    private func error(_ message: String) -> SwiftSyntaxError {
        SwiftSyntaxError(message: message, line: current.line)
    }

    private mutating func expectPunct(_ p: String) throws {
        guard consumePunct(p) else {
            throw error("expected '\(p)'" + (atEOF ? " at end of file" : ", found '\(current.text)'"))
        }
    }

    private mutating func expectIdentifier() throws -> String {
        // Contextual keywords are ordinary names wherever an identifier is expected.
        if current.kind == .identifier || (current.kind == .keyword && ["init", "self", "Self", "default", "is", "in", "as", "do", "where", "case", "static", "subscript", "operator", "actor", "protocol", "extension", "repeat", "defer", "catch", "throw", "func", "struct", "class", "enum", "return", "for", "while", "if", "else", "switch", "let", "var", "import", "typealias", "inout", "throws", "rethrows", "true", "false", "nil", "super", "guard", "break", "continue", "fallthrough", "try", "associatedtype", "deinit"].contains(current.text)) {
            return advance().text
        }
        throw error("expected identifier" + (atEOF ? " at end of file" : ", found '\(current.text)'"))
    }

    /// Split a compound operator token so its first character can be consumed on its own
    /// (`>>` closing two generic lists, `?.` never occurs because `.` is punctuation).
    private mutating func splitFirst(_ ch: String) -> Bool {
        guard current.kind == .op, current.text.hasPrefix(ch) else { return false }
        if current.text == ch { pos += 1; return true }
        tokens[pos].text = String(current.text.dropFirst(ch.count))
        tokens[pos].spaceBefore = false
        return true
    }

    // MARK: Attributes and modifiers

    private static let modifiers: Set<String> = [
        "public", "private", "fileprivate", "internal", "open", "final", "override", "lazy", "weak",
        "unowned", "required", "convenience", "dynamic", "nonisolated", "indirect", "optional",
        "mutating", "nonmutating", "isolated", "consuming", "borrowing", "package",
    ]

    private mutating func parseAttributesAndModifiers() throws -> (attributes: Set<String>, modifiers: Set<String>) {
        var attributes: Set<String> = []
        var mods: Set<String> = []
        while true {
            if isPunct("@") {
                pos += 1
                let name = try expectIdentifier()
                attributes.insert(name)
                if isPunct("(") && !current.spaceBefore { try skipBalanced("(", ")") }
                continue
            }
            if current.kind == .identifier && Self.modifiers.contains(current.text) {
                // `private(set)` and friends.
                let next = peekToken()
                let isDeclStart = next.kind == .keyword || (next.kind == .identifier && (Self.modifiers.contains(next.text)))
                    || (next.kind == .punct && (next.text == "(" || next.text == "@"))
                if !isDeclStart { break }
                mods.insert(advance().text)
                if isPunct("(") { try skipBalanced("(", ")") }
                continue
            }
            if isKeyword("static") || (current.kind == .keyword && current.text == "class" && peekToken().kind == .keyword && ["func", "var", "let"].contains(peekToken().text)) {
                mods.insert("static")
                pos += 1
                continue
            }
            break
        }
        return (attributes, mods)
    }

    private mutating func skipBalanced(_ open: String, _ close: String) throws {
        try expectPunct(open)
        var depth = 1
        while depth > 0 {
            if atEOF { throw error("unbalanced '\(open)'") }
            if isPunct(open) { depth += 1 } else if isPunct(close) { depth -= 1 }
            pos += 1
        }
    }

    // MARK: Statements

    mutating func parseStatement() throws -> SwiftStmt {
        let line = current.line
        // Labeled loops: `outer: for …`
        if current.kind == .identifier, peekToken().kind == .punct, peekToken().text == ":",
           peekToken(2).kind == .keyword, ["for", "while", "repeat", "switch"].contains(peekToken(2).text) {
            let label = advance().text
            pos += 1
            return try parseLoop(label: label)
        }

        let saved = pos
        let (attributes, mods) = try parseAttributesAndModifiers()
        if current.kind == .keyword {
            switch current.text {
            case "let", "var":
                let decls = try parseVariableDecl(attributes: attributes, isStatic: mods.contains("static"))
                return decls.count == 1 ? .variable(decls[0]) : .block(decls.map { .variable($0) })
            case "func":
                let f = try parseFunction(attributes: attributes, modifiers: mods)
                return .function(f)
            case "init":
                let f = try parseInit(attributes: attributes, modifiers: mods)
                return .function(f)
            case "struct", "class", "enum", "protocol", "extension", "actor":
                return .type(try parseTypeDecl(attributes: attributes))
            case "import":
                pos += 1
                if current.kind == .identifier || current.kind == .keyword { pos += 1 }
                while consumePunct(".") { _ = try expectIdentifier() }
                return .empty
            case "typealias":
                pos += 1
                let name = try expectIdentifier()
                if isOp("<") { try skipGenericParams() }
                guard consumeOp("=") else { throw error("expected '=' in typealias") }
                return .typeAlias(name, try parseType())
            case "subscript", "deinit":
                break
            default:
                break
            }
        }
        if (!attributes.isEmpty || !mods.isEmpty) && pos != saved {
            throw error("expected declaration after '\(tokens[saved].text)'")
        }

        if current.kind == .keyword {
            switch current.text {
            case "if":
                return try parseIf()
            case "guard":
                pos += 1
                let conds = try parseConditions()
                guard consumeKeyword("else") else { throw error("expected 'else' after guard condition") }
                let body = try parseBlock()
                return .guardStmt(conds, body, line: line)
            case "while", "repeat", "for", "switch":
                return try parseLoop(label: nil)
            case "return":
                pos += 1
                if atEOF || isPunct("}") || isPunct(";") || current.newlineBefore || isKeyword("case") || isKeyword("default") {
                    return .returnStmt(nil, line: line)
                }
                return .returnStmt(try parseExpression(), line: line)
            case "break":
                pos += 1
                if current.kind == .identifier && !current.newlineBefore { return .breakStmt(advance().text, line: line) }
                return .breakStmt(nil, line: line)
            case "continue":
                pos += 1
                if current.kind == .identifier && !current.newlineBefore { return .continueStmt(advance().text, line: line) }
                return .continueStmt(nil, line: line)
            case "fallthrough":
                pos += 1
                return .fallthroughStmt(line: line)
            case "throw":
                pos += 1
                return .throwStmt(try parseExpression(), line: line)
            case "do":
                pos += 1
                let body = try parseBlock()
                var catches: [SwiftCatchClause] = []
                while consumeKeyword("catch") {
                    var pattern: SwiftPattern? = nil
                    var guardExpr: SwiftExpr? = nil
                    if !isPunct("{") {
                        noTrailingClosure = true
                        defer { noTrailingClosure = false }
                        pattern = try parsePattern(binding: false)
                        if consumeKeyword("where") { guardExpr = try parseExpression() }
                    }
                    catches.append(SwiftCatchClause(pattern: pattern, guardExpr: guardExpr, body: try parseBlock()))
                }
                return .doCatch(body, catches, line: line)
            case "defer":
                pos += 1
                return .deferStmt(try parseBlock())
            default:
                break
            }
        }
        let expr = try parseExpression()
        return .expr(expr, line: line)
    }

    private mutating func parseLoop(label: String?) throws -> SwiftStmt {
        let line = current.line
        if consumeKeyword("while") {
            let conds = try parseConditions()
            return .whileStmt(conds, try parseBlock(), label: label, line: line)
        }
        if consumeKeyword("repeat") {
            let body = try parseBlock()
            guard consumeKeyword("while") else { throw error("expected 'while' after repeat body") }
            return .repeatWhile(body, try parseExpression(), label: label, line: line)
        }
        if consumeKeyword("for") {
            consumeKeyword("case")
            let pattern = try parsePattern(binding: true)
            guard consumeKeyword("in") else { throw error("expected 'in' in for-in loop") }
            noTrailingClosure = true
            let seq = try parseExpression()
            var whereExpr: SwiftExpr? = nil
            if consumeKeyword("where") { whereExpr = try parseExpression() }
            noTrailingClosure = false
            return .forIn(pattern, seq, whereExpr, try parseBlock(), label: label, line: line)
        }
        if consumeKeyword("switch") {
            noTrailingClosure = true
            let subject = try parseExpression()
            noTrailingClosure = false
            try expectPunct("{")
            var cases: [SwiftSwitchCase] = []
            while !consumePunct("}") {
                if atEOF { throw error("unterminated switch") }
                _ = try parseAttributesAndModifiers()
                if consumeKeyword("default") {
                    try expectPunct(":")
                    cases.append(SwiftSwitchCase(patterns: [], guardExpr: nil, body: try parseCaseBody(), isDefault: true))
                    continue
                }
                guard consumeKeyword("case") else { throw error("expected 'case' in switch") }
                var patterns: [SwiftPattern] = []
                var guardExpr: SwiftExpr? = nil
                repeat {
                    patterns.append(try parsePattern(binding: false))
                } while consumePunct(",")
                if consumeKeyword("where") { guardExpr = try parseExpression() }
                try expectPunct(":")
                cases.append(SwiftSwitchCase(patterns: patterns, guardExpr: guardExpr, body: try parseCaseBody(), isDefault: false))
            }
            return .switchStmt(subject, cases, label: label, line: line)
        }
        throw error("expected loop")
    }

    private mutating func parseCaseBody() throws -> [SwiftStmt] {
        var body: [SwiftStmt] = []
        while !isKeyword("case") && !isKeyword("default") && !isPunct("}") {
            if atEOF { throw error("unterminated switch case") }
            if consumePunct(";") { continue }
            if isPunct("@") && peekToken().text == "unknown" { pos += 2; continue }
            body.append(try parseStatement())
        }
        return body
    }

    private mutating func parseIf() throws -> SwiftStmt {
        let line = current.line
        pos += 1
        let conds = try parseConditions()
        let then = try parseBlock()
        var elseBody: [SwiftStmt]? = nil
        if consumeKeyword("else") {
            if isKeyword("if") {
                elseBody = [try parseIf()]
            } else {
                elseBody = try parseBlock()
            }
        }
        return .ifStmt(conds, then, elseBody, line: line)
    }

    private mutating func parseConditions() throws -> [SwiftCondition] {
        noTrailingClosure = true
        defer { noTrailingClosure = false }
        var conds: [SwiftCondition] = []
        repeat {
            if isKeyword("let") || isKeyword("var") {
                pos += 1
                let name = try expectIdentifier()
                if consumePunct(":") { _ = try parseType() }
                if consumeOp("=") {
                    conds.append(.optionalBinding(name, try parseExpression()))
                } else {
                    // `if let x` shorthand (SE-0345).
                    conds.append(.optionalBinding(name, .identifier(name, line: current.line)))
                }
            } else if consumeKeyword("case") {
                let pattern = try parsePattern(binding: false)
                guard consumeOp("=") else { throw error("expected '=' in case condition") }
                conds.append(.pattern(pattern, try parseExpression()))
            } else {
                conds.append(.expr(try parseExpression()))
            }
        } while consumePunct(",")
        return conds
    }

    mutating func parseBlock() throws -> [SwiftStmt] {
        let saved = noTrailingClosure
        noTrailingClosure = false
        defer { noTrailingClosure = saved }
        try expectPunct("{")
        var stmts: [SwiftStmt] = []
        while !consumePunct("}") {
            if atEOF { throw error("expected '}'") }
            if consumePunct(";") { continue }
            stmts.append(try parseStatement())
        }
        return stmts
    }

    // MARK: Declarations

    private mutating func parseVariableDecl(attributes: Set<String>, isStatic: Bool) throws -> [SwiftVariableDecl] {
        let line = current.line
        let isLet = advance().text == "let"
        var decls: [SwiftVariableDecl] = []
        repeat {
            let pattern = try parsePattern(binding: true, allowTyped: false)
            var type: SwiftTypeRef? = nil
            if consumePunct(":") { type = try parseType() }
            var initializer: SwiftExpr? = nil
            if consumeOp("=") { initializer = try parseExpression() }
            let decl = SwiftVariableDecl(pattern: pattern, type: type, initializer: initializer, isLet: isLet, line: line)
            decl.isStatic = isStatic
            decl.attributes = attributes
            if isPunct("{") && !current.newlineBefore || (isPunct("{") && type != nil && initializer == nil) {
                try parseAccessors(decl)
            }
            decls.append(decl)
        } while consumePunct(",")
        return decls
    }

    private mutating func parseAccessors(_ decl: SwiftVariableDecl) throws {
        try expectPunct("{")
        let isAccessorBlock: Bool = {
            if current.kind == .identifier && ["get", "set", "willSet", "didSet"].contains(current.text) {
                let next = peekToken()
                return next.kind == .punct && (next.text == "{" || next.text == "(" || next.text == "}") || next.newlineBefore
                    || (next.kind == .identifier && ["set", "get"].contains(next.text))
            }
            if isPunct("@") || (current.kind == .identifier && Self.modifiers.contains(current.text)) { return true }
            return false
        }()
        if !isAccessorBlock {
            // Shorthand getter: `var x: Int { expr }`.
            var stmts: [SwiftStmt] = []
            while !consumePunct("}") {
                if atEOF { throw error("expected '}'") }
                if consumePunct(";") { continue }
                stmts.append(try parseStatement())
            }
            decl.getter = stmts
            return
        }
        while !consumePunct("}") {
            if atEOF { throw error("expected '}'") }
            _ = try parseAttributesAndModifiers()
            let which = try expectIdentifier()
            var paramName: String? = nil
            if consumePunct("(") {
                paramName = try expectIdentifier()
                try expectPunct(")")
            }
            let body: [SwiftStmt] = isPunct("{") ? try parseBlock() : []
            switch which {
            case "get": decl.getter = body
            case "set": decl.setter = (paramName ?? "newValue", body)
            case "willSet": decl.willSet = (paramName ?? "newValue", body)
            case "didSet": decl.didSet = (paramName ?? "oldValue", body)
            default: throw error("unknown accessor '\(which)'")
            }
        }
    }

    private mutating func skipGenericParams() throws {
        guard splitFirst("<") else { return }
        var depth = 1
        while depth > 0 {
            if atEOF { throw error("unbalanced generic parameter list") }
            if current.kind == .op {
                for ch in current.text {
                    if ch == "<" { depth += 1 } else if ch == ">" { depth -= 1 }
                }
            }
            pos += 1
        }
    }

    private mutating func skipWhereClause() throws {
        guard consumeKeyword("where") else { return }
        while !isPunct("{") && !atEOF && !(current.newlineBefore && !isPunct(",") && !isOp(":") && !isPunct(":")) {
            pos += 1
        }
    }

    /// Subscript parameters have no argument label unless one is written out.
    private mutating func parseParams(forSubscript: Bool = false) throws -> [SwiftParam] {
        try expectPunct("(")
        var params: [SwiftParam] = []
        while !consumePunct(")") {
            _ = try parseAttributesAndModifiers()
            let first = try expectIdentifier()
            var label: String? = forSubscript ? nil : first
            var name = first
            if !isPunct(":") {
                label = first
                name = try expectIdentifier()
            }
            if label == "_" { label = nil }
            var param = SwiftParam(label: label, name: name)
            try expectPunct(":")
            while isPunct("@") { pos += 1; _ = try expectIdentifier() }
            if consumeKeyword("inout") { param.isInout = true }
            param.type = try parseType()
            if consumeOp("...") { param.isVariadic = true }
            if consumeOp("=") { param.defaultValue = try parseExpression() }
            params.append(param)
            if !consumePunct(",") {
                try expectPunct(")")
                break
            }
        }
        return params
    }

    private mutating func parseFunction(attributes: Set<String>, modifiers: Set<String>) throws -> SwiftFunctionDecl {
        let line = current.line
        pos += 1
        let name: String
        if current.kind == .op {
            name = advance().text
        } else {
            name = try expectIdentifier()
        }
        if isOp("<") || (current.kind == .op && current.text.hasPrefix("<")) { try skipGenericParams() }
        var params = try parseParams()
        // Operator functions take no argument labels at the call site.
        if name.first.map({ "+-*/%<>=!&|^~".contains($0) }) == true {
            for i in params.indices { params[i].label = nil }
        }
        let (throwsErrors, returnType) = try parseFunctionTail()
        try skipWhereClause()
        let body: [SwiftStmt]? = isPunct("{") ? try parseBlock() : nil
        let f = SwiftFunctionDecl(name: name, params: params, returnType: returnType, body: body, line: line)
        f.isStatic = modifiers.contains("static")
        f.isMutating = modifiers.contains("mutating")
        f.throwsErrors = throwsErrors
        f.attributes = attributes
        return f
    }

    private mutating func parseFunctionTail() throws -> (Bool, SwiftTypeRef?) {
        var throwsErrors = false
        while true {
            if isIdent("async") { pos += 1; continue }
            if consumeKeyword("throws") || consumeKeyword("rethrows") {
                throwsErrors = true
                if isPunct("(") { try skipBalanced("(", ")") }
                continue
            }
            break
        }
        var returnType: SwiftTypeRef? = nil
        if consumePunct("->") { returnType = try parseType() }
        return (throwsErrors, returnType)
    }

    private mutating func parseInit(attributes: Set<String>, modifiers: Set<String>) throws -> SwiftFunctionDecl {
        let line = current.line
        pos += 1
        var failable = false
        if isOp("?") || isOp("!") { failable = isOp("?"); pos += 1 }
        if isOp("<") { try skipGenericParams() }
        let params = try parseParams()
        let (throwsErrors, _) = try parseFunctionTail()
        try skipWhereClause()
        let body: [SwiftStmt]? = isPunct("{") ? try parseBlock() : nil
        let f = SwiftFunctionDecl(name: "init", params: params, returnType: nil, body: body, line: line)
        f.isInit = true
        f.isFailable = failable
        f.throwsErrors = throwsErrors
        f.attributes = attributes
        f.isStatic = false
        _ = modifiers
        return f
    }

    private mutating func parseTypeDecl(attributes: Set<String>) throws -> SwiftTypeDecl {
        let line = current.line
        let keyword = advance().text
        let kind: SwiftTypeDecl.Kind = switch keyword {
        case "struct": .structType
        case "class", "actor": .classType
        case "enum": .enumType
        case "protocol": .protocolType
        default: .extensionType
        }
        var name = try expectIdentifier()
        while consumePunct(".") { name += "." + (try expectIdentifier()) }
        if isOp("<") || (current.kind == .op && current.text.hasPrefix("<")) { try skipGenericParams() }
        var inherits: [String] = []
        if consumePunct(":") {
            repeat {
                if isOp("~") { pos += 1 }
                let t = try parseType()
                if let base = t.baseName { inherits.append(base) }
                while consumeOp("&") { if let b = (try parseType()).baseName { inherits.append(b) } }
            } while consumePunct(",")
        }
        try skipWhereClause()
        let decl = SwiftTypeDecl(kind: kind, name: name, inherits: inherits, line: line)
        decl.attributes = attributes
        try expectPunct("{")
        while !consumePunct("}") {
            if atEOF { throw error("expected '}' to close \(keyword) \(name)") }
            if consumePunct(";") { continue }
            let (attrs, mods) = try parseAttributesAndModifiers()
            if current.kind == .keyword || current.kind == .identifier {
                switch current.text {
                case "let", "var":
                    let decls = try parseVariableDecl(attributes: attrs, isStatic: mods.contains("static"))
                    decl.properties.append(contentsOf: decls)
                    continue
                case "func":
                    let f = try parseFunction(attributes: attrs, modifiers: mods)
                    decl.methods.append(f)
                    continue
                case "init":
                    decl.methods.append(try parseInit(attributes: attrs, modifiers: mods))
                    continue
                case "deinit":
                    pos += 1
                    _ = try parseBlock()
                    continue
                case "subscript":
                    let sl = current.line
                    pos += 1
                    let params = try parseParams(forSubscript: true)
                    guard consumePunct("->") else { throw error("expected '->' in subscript") }
                    let type = try parseType()
                    let holder = SwiftVariableDecl(pattern: .binding("subscript"), type: type, initializer: nil, isLet: false, line: sl)
                    try parseAccessors(holder)
                    let getter = SwiftFunctionDecl(name: "subscript", params: params, returnType: type, body: holder.getter ?? [], line: sl)
                    getter.isStatic = mods.contains("static")
                    decl.subscripts.append(getter)
                    if let setter = holder.setter {
                        var setParams = params
                        setParams.append(SwiftParam(label: nil, name: setter.name, type: type))
                        let s = SwiftFunctionDecl(name: "subscript=", params: setParams, returnType: nil, body: setter.body, line: sl)
                        s.isMutating = true
                        decl.subscripts.append(s)
                    }
                    continue
                case "case":
                    pos += 1
                    repeat {
                        let caseName = try expectIdentifier()
                        var assoc: [(label: String?, type: SwiftTypeRef)]? = nil
                        if consumePunct("(") {
                            var list: [(label: String?, type: SwiftTypeRef)] = []
                            while !consumePunct(")") {
                                var label: String? = nil
                                if (current.kind == .identifier || current.kind == .keyword), peekToken().kind == .punct, peekToken().text == ":" {
                                    label = advance().text
                                    pos += 1
                                }
                                let t = try parseType()
                                if consumeOp("=") { _ = try parseExpression() }
                                list.append((label, t))
                                if !consumePunct(",") { try expectPunct(")"); break }
                            }
                            assoc = list
                        }
                        var raw: SwiftExpr? = nil
                        if consumeOp("=") { raw = try parsePrimary() }
                        decl.cases.append(SwiftEnumCaseDecl(name: caseName, associated: assoc, rawValue: raw))
                    } while consumePunct(",")
                    continue
                case "struct", "class", "enum", "protocol", "extension", "actor":
                    decl.nested.append(try parseTypeDecl(attributes: attrs))
                    continue
                case "typealias", "associatedtype":
                    pos += 1
                    let aliasName = try expectIdentifier()
                    if consumePunct(":") { _ = try parseType() }
                    if consumeOp("=") { decl.aliases.append((aliasName, try parseType())) }
                    try skipWhereClause()
                    continue
                default:
                    break
                }
            }
            throw error("unexpected '\(current.text)' in \(keyword) \(name)")
        }
        return decl
    }

    // MARK: Types

    mutating func parseType() throws -> SwiftTypeRef {
        var base: SwiftTypeRef
        if isIdent("some") || isIdent("any") { pos += 1 }
        while isPunct("@") { pos += 1; _ = try expectIdentifier() }
        if consumeKeyword("inout") {}
        if consumePunct("[") {
            let element = try parseType()
            if consumePunct(":") {
                let value = try parseType()
                try expectPunct("]")
                base = .dictionary(element, value)
            } else {
                try expectPunct("]")
                base = .array(element)
            }
        } else if consumePunct("(") {
            var elements: [SwiftTypeRef] = []
            var labels: [String?] = []
            while !consumePunct(")") {
                var label: String? = nil
                if (current.kind == .identifier || current.kind == .keyword), peekToken().kind == .punct, peekToken().text == ":" { label = current.text; pos += 2 }
                else if current.kind == .identifier, peekToken().kind == .identifier, peekToken(2).kind == .punct, peekToken(2).text == ":" { pos += 3 }
                labels.append(label)
                elements.append(try parseType())
                consumeOp("...")
                if !consumePunct(",") { try expectPunct(")"); break }
            }
            while isIdent("async") || isKeyword("throws") || isKeyword("rethrows") { pos += 1 }
            if consumePunct("->") {
                _ = try parseType()
                base = .function
            } else {
                base = elements.count == 1 ? elements[0] : .tuple(elements, labels: labels)
            }
        } else {
            var name = try expectIdentifier()
            var args: [SwiftTypeRef] = []
            if isOp("<") || (current.kind == .op && current.text.hasPrefix("<") && !current.spaceBefore) {
                _ = splitFirst("<")
                while true {
                    args.append(try parseType())
                    if consumePunct(",") { continue }
                    guard splitFirst(">") else { throw error("expected '>' in generic argument list") }
                    break
                }
            }
            while isPunct(".") && peekToken().kind == .identifier {
                pos += 1
                name += "." + advance().text
            }
            if name == "Array", args.count == 1 { base = .array(args[0]) }
            else if name == "Dictionary", args.count == 2 { base = .dictionary(args[0], args[1]) }
            else if name == "Optional", args.count == 1 { base = .optional(args[0]) }
            else { base = .named(name, args) }
        }
        while !current.spaceBefore && current.kind == .op && (current.text.hasPrefix("?") || current.text.hasPrefix("!")) {
            if current.text.hasPrefix("?") {
                _ = splitFirst("?")
                base = .optional(base)
            } else {
                _ = splitFirst("!")
                base = .optional(base)
            }
        }
        if isPunct("->") {
            pos += 1
            _ = try parseType()
            return .function
        }
        return base
    }

    // MARK: Patterns

    mutating func parsePattern(binding: Bool, allowTyped: Bool = true) throws -> SwiftPattern {
        var pattern = try parsePatternPrimary(binding: binding)
        if allowTyped, consumeKeyword("as") {
            pattern = .asType(pattern, try parseType())
        }
        return pattern
    }

    private mutating func parsePatternPrimary(binding: Bool) throws -> SwiftPattern {
        if current.kind == .identifier, current.text == "_" {
            pos += 1
            return .wildcard
        }
        if isKeyword("let") || isKeyword("var") {
            pos += 1
            return try parsePattern(binding: true)
        }
        if consumeKeyword("is") {
            return .isType(try parseType())
        }
        if isPunct("(") {
            // A tuple pattern — or, outside binding mode, a parenthesised expression.
            let saved = pos
            pos += 1
            var elements: [SwiftPattern] = []
            var ok = true
            while !consumePunct(")") {
                if (current.kind == .identifier), peekToken().kind == .punct, peekToken().text == ":", !binding {
                    pos += 2
                }
                guard let element = try? parsePattern(binding: binding) else { ok = false; break }
                elements.append(element)
                if !consumePunct(",") {
                    if !consumePunct(")") { ok = false }
                    break
                }
            }
            if ok && (elements.count != 1 || binding) {
                return elements.count == 1 ? elements[0] : .tuple(elements)
            }
            pos = saved
        }
        if isPunct(".") && (peekToken().kind == .identifier || peekToken().kind == .keyword) {
            pos += 1
            let name = advance().text
            return .enumCase(name, try parseEnumPayloadPatterns(binding: binding))
        }
        // `Type.case(…)` — a capitalised name, a dot, a lower-case case name.
        if current.kind == .identifier, current.text.first?.isUppercase == true,
           peekToken().kind == .punct, peekToken().text == ".",
           peekToken(2).kind == .identifier, peekToken(2).text.first?.isLowercase == true,
           !(peekToken(3).kind == .punct && peekToken(3).text == ".") {
            pos += 2
            let name = advance().text
            return .enumCase(name, try parseEnumPayloadPatterns(binding: binding))
        }
        if binding, current.kind == .identifier || (current.kind == .keyword && current.text == "self") {
            let name = advance().text
            if !current.spaceBefore, current.kind == .op, current.text.hasPrefix("?") {
                _ = splitFirst("?")
                return .optionalSome(.binding(name))
            }
            return .binding(name)
        }
        let expr = try parseExpression(noAssign: true)
        if !current.spaceBefore, current.kind == .op, current.text == "?" {
            pos += 1
            return .optionalSome(.expr(expr))
        }
        return .expr(expr)
    }

    private mutating func parseEnumPayloadPatterns(binding: Bool) throws -> [SwiftPattern]? {
        guard isPunct("(") && !current.spaceBefore else { return nil }
        pos += 1
        var subs: [SwiftPattern] = []
        while !consumePunct(")") {
            if (current.kind == .identifier || current.kind == .keyword), peekToken().kind == .punct, peekToken().text == ":" {
                pos += 2
            }
            subs.append(try parsePattern(binding: binding))
            if !consumePunct(",") { try expectPunct(")"); break }
        }
        return subs
    }

    // MARK: Expressions

    private static let precedence: [String: (Int, Bool)] = [
        // (precedence, right-associative)
        "||": (20, false),
        "&&": (30, false),
        "==": (40, false), "!=": (40, false), "<": (40, false), ">": (40, false), "<=": (40, false),
        ">=": (40, false), "===": (40, false), "!==": (40, false), "~=": (40, false),
        "??": (50, true),
        // casting (is/as) sits at 60
        "..<": (70, false), "...": (70, false),
        "+": (80, false), "-": (80, false), "|": (80, false), "^": (80, false), "&+": (80, false), "&-": (80, false),
        "*": (90, false), "/": (90, false), "%": (90, false), "&": (90, false), "&*": (90, false),
        "<<": (100, false), ">>": (100, false),
    ]

    private static let assignmentOps: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "??="]

    mutating func parseExpression(noAssign: Bool = false) throws -> SwiftExpr {
        let line = current.line
        let lhs = try parseTernary()
        if !noAssign, current.kind == .op, Self.assignmentOps.contains(current.text), current.spaceBefore == peekToken().spaceBefore || current.spaceBefore {
            let op = advance().text
            let rhs = try parseExpression()
            return .assign(op, lhs, rhs, line: line)
        }
        return lhs
    }

    private mutating func parseTernary() throws -> SwiftExpr {
        let cond = try parseBinary(minPrecedence: 0)
        if isOp("?") && current.spaceBefore {
            pos += 1
            let a = try parseTernary()
            guard consumePunct(":") else { throw error("expected ':' in ternary expression") }
            let b = try parseTernary()
            return .ternary(cond, a, b)
        }
        return cond
    }

    /// An operator token is binary when its whitespace is balanced on both sides.
    private func isBinaryOperatorHere() -> Bool {
        guard current.kind == .op else { return false }
        let after = peekToken()
        let spaceAfter = after.spaceBefore
        return current.spaceBefore == spaceAfter
    }

    private mutating func parseBinary(minPrecedence: Int) throws -> SwiftExpr {
        var lhs = try parsePrefix()
        while true {
            let line = current.line
            if (isKeyword("is") || isKeyword("as")) && 60 >= minPrecedence {
                if consumeKeyword("is") {
                    lhs = .isType(lhs, try parseType())
                } else {
                    pos += 1
                    var kind = "as"
                    if !current.spaceBefore, current.kind == .op, current.text == "?" || current.text == "!" {
                        kind += advance().text
                    }
                    lhs = .cast(lhs, try parseType(), kind)
                }
                continue
            }
            guard current.kind == .op, !Self.assignmentOps.contains(current.text) else { break }
            // A postfix `...` (one-sided range `a...`) ends the expression.
            if current.text == "..." && !current.spaceBefore && (peekToken().kind == .punct && ["]", ")", ","].contains(peekToken().text)) {
                pos += 1
                lhs = .postfixRange(lhs)
                continue
            }
            // An operator on a new line with no space after it is a prefix operator starting
            // the next statement (`-1`), not a continuation.
            if current.newlineBefore && !isBinaryOperatorHere() { break }
            guard let (prec, rightAssoc) = Self.precedence[current.text], prec >= minPrecedence else { break }
            if !isBinaryOperatorHere() && current.text != "..<" && current.text != "..." { break }
            let op = advance().text
            let rhs = try parseBinary(minPrecedence: rightAssoc ? prec : prec + 1)
            lhs = .binary(op, lhs, rhs, line: line)
        }
        return lhs
    }

    private mutating func parsePrefix() throws -> SwiftExpr {
        let line = current.line
        if consumeKeyword("try") {
            var kind = "try"
            if !current.spaceBefore, current.kind == .op, current.text == "?" || current.text == "!" {
                kind += advance().text
            }
            return .tryExpr(kind, try parseBinary(minPrecedence: 0))
        }
        if isIdent("await") && !peekToken().spaceBefore == false {
            pos += 1
            return try parsePrefix()
        }
        if current.kind == .op, !peekToken().spaceBefore {
            let op = current.text
            if op == "&" {
                pos += 1
                return .prefix("&", try parsePostfix(), line: line)
            }
            if ["-", "!", "+", "~", "..<", "..."].contains(op) {
                pos += 1
                let operand = try parsePrefix()
                if op == "-", case .intLit(let v) = operand { return .intLit(-v) }
                if op == "-", case .doubleLit(let v) = operand { return .doubleLit(-v) }
                return .prefix(op, operand, line: line)
            }
            // Greedy lexing can glue a prefix operator to a unary one (`-!x`): split it.
            if op.count > 1, let first = op.first, "-!".contains(first) {
                _ = splitFirst(String(first))
                return .prefix(String(first), try parsePrefix(), line: line)
            }
        }
        return try parsePostfix()
    }

    private mutating func parsePostfix() throws -> SwiftExpr {
        var expr = try parsePrimary()
        while true {
            let line = current.line
            if isPunct(".") {
                // `.member` continues across newlines (method chains).
                pos += 1
                if current.kind == .integer {
                    expr = .member(expr, current.text, line: line)
                    pos += 1
                    continue
                }
                if isKeyword("init") {
                    pos += 1
                    expr = .member(expr, "init", line: line)
                    continue
                }
                let name = try expectIdentifier()
                expr = .member(expr, name, line: line)
                continue
            }
            if current.newlineBefore { break }
            if isPunct("(") && !current.spaceBefore {
                let args = try parseArguments(close: ")")
                expr = .call(expr, args + (try parseTrailingClosures()), line: line)
                continue
            }
            if isPunct("[") && !current.spaceBefore {
                let args = try parseArguments(close: "]")
                expr = .subscriptAccess(expr, args, line: line)
                continue
            }
            if current.kind == .op && !current.spaceBefore {
                if current.text == "!" || (current.text.hasPrefix("!") && current.text != "!=" && current.text != "!==") {
                    _ = splitFirst("!")
                    expr = .forceUnwrap(expr, line: line)
                    continue
                }
                if current.text == "?" || (current.text.hasPrefix("?") && !current.text.hasPrefix("??")) {
                    _ = splitFirst("?")
                    expr = .optionalChain(expr)
                    continue
                }
            }
            if isPunct("{") && !noTrailingClosure && !isObserverBlock() {
                let closures = try parseTrailingClosures()
                if closures.isEmpty { break }
                expr = .call(expr, closures, line: line)
                continue
            }
            break
        }
        return expr
    }

    /// `{ didSet … }` / `{ willSet … }` after a variable's initializer is its observer block.
    private func isObserverBlock() -> Bool {
        guard isPunct("{") else { return false }
        let next = peekToken()
        return next.kind == .identifier && (next.text == "didSet" || next.text == "willSet")
    }

    private mutating func parseTrailingClosures() throws -> [SwiftArgument] {
        guard isPunct("{") && !noTrailingClosure && !current.newlineBefore && !isObserverBlock() else { return [] }
        var args: [SwiftArgument] = [SwiftArgument(label: nil, value: .closure(try parseClosure()))]
        // Additional labelled trailing closures: `} label: { … }`.
        while (current.kind == .identifier || current.kind == .keyword), peekToken().kind == .punct, peekToken().text == ":",
              peekToken(2).kind == .punct, peekToken(2).text == "{" {
            let label = advance().text
            pos += 1
            args.append(SwiftArgument(label: label, value: .closure(try parseClosure())))
        }
        return args
    }

    private mutating func parseArguments(close: String) throws -> [SwiftArgument] {
        pos += 1
        let saved = noTrailingClosure
        noTrailingClosure = false
        defer { noTrailingClosure = saved }
        var args: [SwiftArgument] = []
        while !consumePunct(close) {
            var label: String? = nil
            if (current.kind == .identifier || current.kind == .keyword), peekToken().kind == .punct, peekToken().text == ":",
               !(peekToken(2).kind == .punct && peekToken(2).text == ":") {
                label = advance().text
                pos += 1
            }
            var arg = SwiftArgument(label: label, value: .nilLit)
            if isOp("&") && !peekToken().spaceBefore {
                pos += 1
                arg.isInout = true
            }
            // An operator passed as a function (`reduce(0, +)`, `sorted(by: <)`).
            if current.kind == .op, peekToken().kind == .punct, [",", ")"].contains(peekToken().text) {
                arg.value = .identifier(advance().text, line: current.line)
            } else {
                arg.value = try parseExpression()
            }
            args.append(arg)
            if !consumePunct(",") {
                try expectPunct(close)
                break
            }
        }
        return args
    }

    private mutating func parseClosure() throws -> SwiftClosure {
        let line = current.line
        try expectPunct("{")
        var params: [SwiftParam] = []
        // Look ahead for `in` to decide whether the closure declares a signature.
        let saved = pos
        var hasSignature = false
        var depth = 0
        var scan = pos
        while scan < tokens.count {
            let t = tokens[scan]
            if t.kind == .eof { break }
            if t.kind == .punct && (t.text == "{" || t.text == "(" || t.text == "[") { depth += 1 }
            if t.kind == .punct && (t.text == "}" || t.text == ")" || t.text == "]") {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0 && t.kind == .keyword && t.text == "in" { hasSignature = true; break }
            // Anything statement-like before `in` means there is no signature.
            if depth == 0 && t.kind == .keyword && !["inout", "throws", "rethrows", "self"].contains(t.text) { break }
            if depth == 0 && t.kind == .op && !["->", "?", "!", "...", "<", ">"].contains(t.text) { break }
            scan += 1
        }
        if hasSignature {
            if isPunct("[") { try skipBalanced("[", "]") }
            if isPunct("(") {
                pos += 1
                while !consumePunct(")") {
                    var name = try expectIdentifier()
                    if current.kind == .identifier { name = advance().text }
                    var p = SwiftParam(label: nil, name: name)
                    if consumePunct(":") {
                        if consumeKeyword("inout") { p.isInout = true }
                        p.type = try parseType()
                    }
                    params.append(p)
                    if !consumePunct(",") { try expectPunct(")"); break }
                }
            } else {
                while !isKeyword("in") && !isPunct("->") && !isIdent("async") && !isKeyword("throws") {
                    let name = try expectIdentifier()
                    params.append(SwiftParam(label: nil, name: name))
                    if !consumePunct(",") { break }
                }
            }
            while isIdent("async") || isKeyword("throws") { pos += 1 }
            if consumePunct("->") { _ = try parseType() }
            guard consumeKeyword("in") else { pos = saved; throw error("expected 'in' in closure signature") }
        }
        var body: [SwiftStmt] = []
        let savedNTC = noTrailingClosure
        noTrailingClosure = false
        while !consumePunct("}") {
            if atEOF { throw error("expected '}' to close closure") }
            if consumePunct(";") { continue }
            body.append(try parseStatement())
        }
        noTrailingClosure = savedNTC
        return SwiftClosure(params: params, body: body, line: line)
    }

    private mutating func parsePrimary() throws -> SwiftExpr {
        let tok = current
        let line = tok.line
        switch tok.kind {
        case .integer:
            pos += 1
            return .intLit(tok.intValue)
        case .float:
            pos += 1
            return .doubleLit(tok.floatValue)
        case .string:
            pos += 1
            var parts: [SwiftStringPart] = []
            for segment in tok.segments {
                switch segment {
                case .text(let t):
                    parts.append(.text(t))
                case .code(var inner):
                    inner.append(SwiftToken(kind: .eof, text: "", line: tok.line, spaceBefore: true, newlineBefore: true))
                    var sub = SwiftParser(tokens: inner)
                    // `\(value, format: …)` style extras are not Swift; a lone expression is.
                    let e = try sub.parseExpression()
                    parts.append(.expr(e))
                }
            }
            return .stringLit(parts)
        case .keyword:
            switch tok.text {
            case "true": pos += 1; return .boolLit(true)
            case "false": pos += 1; return .boolLit(false)
            case "nil": pos += 1; return .nilLit
            case "self": pos += 1; return .selfRef
            case "Self": pos += 1; return .identifier("Self", line: line)
            case "super":
                pos += 1
                try expectPunct(".")
                if consumeKeyword("init") { return .superMember("init") }
                return .superMember(try expectIdentifier())
            case "init":
                pos += 1
                return .identifier("init", line: line)
            case "if", "switch":
                // An `if`/`switch` expression (SE-0380) in value position.
                let stmt = tok.text == "if" ? try parseIf() : try parseLoop(label: nil)
                return .ifExpr(stmt)
            case "try":
                return try parsePrefix()
            default:
                throw error("expected expression, found '\(tok.text)'")
            }
        case .identifier:
            pos += 1
            // Generic arguments in expression position: `Array<Int>()`, `Set<String>()`.
            if !current.spaceBefore, current.kind == .op, current.text.hasPrefix("<"), tok.text.first?.isUppercase == true {
                let saved = pos
                let savedTokens = tokens
                _ = splitFirst("<")
                var args: [SwiftTypeRef] = []
                var ok = true
                while true {
                    guard let t = try? parseType() else { ok = false; break }
                    args.append(t)
                    if consumePunct(",") { continue }
                    if splitFirst(">") { break }
                    ok = false
                    break
                }
                if ok && (isPunct("(") || isPunct(".")) {
                    var type: SwiftTypeRef = .named(tok.text, args)
                    if tok.text == "Array", args.count == 1 { type = .array(args[0]) }
                    if tok.text == "Dictionary", args.count == 2 { type = .dictionary(args[0], args[1]) }
                    return .typeExpr(type)
                }
                pos = saved
                tokens = savedTokens
            }
            return .identifier(tok.text, line: line)
        case .punct:
            switch tok.text {
            case "(":
                pos += 1
                let saved = noTrailingClosure
                noTrailingClosure = false
                defer { noTrailingClosure = saved }
                var elements: [(label: String?, value: SwiftExpr)] = []
                while !consumePunct(")") {
                    var label: String? = nil
                    if (current.kind == .identifier || current.kind == .keyword), peekToken().kind == .punct, peekToken().text == ":" {
                        label = advance().text
                        pos += 1
                    }
                    elements.append((label, try parseExpression()))
                    if !consumePunct(",") { try expectPunct(")"); break }
                }
                if elements.count == 1 && elements[0].label == nil { return elements[0].value }
                return .tuple(elements)
            case "[":
                pos += 1
                let saved = noTrailingClosure
                noTrailingClosure = false
                defer { noTrailingClosure = saved }
                if consumePunct(":") {
                    try expectPunct("]")
                    return .dictionaryLit([])
                }
                if consumePunct("]") { return .arrayLit([]) }
                let first = try parseExpression()
                if consumePunct(":") {
                    var pairs = [(first, try parseExpression())]
                    while consumePunct(",") {
                        if isPunct("]") { break }
                        let k = try parseExpression()
                        try expectPunct(":")
                        pairs.append((k, try parseExpression()))
                    }
                    try expectPunct("]")
                    return .dictionaryLit(pairs)
                }
                var elements = [first]
                while consumePunct(",") {
                    if isPunct("]") { break }
                    elements.append(try parseExpression())
                }
                try expectPunct("]")
                return .arrayLit(elements)
            case "{":
                return .closure(try parseClosure())
            case ".":
                pos += 1
                if consumeKeyword("init") { return .implicitMember("init") }
                return .implicitMember(try expectIdentifier())
            case "\\":
                pos += 1
                var path: [String] = []
                if current.kind == .identifier && current.text.first?.isUppercase == true { pos += 1 }
                while consumePunct(".") {
                    path.append(try expectIdentifier())
                }
                return .keyPath(path)
            case "#":
                pos += 1
                let name = try expectIdentifier()
                if name == "line" { return .intLit(line) }
                if name == "file" || name == "fileID" || name == "filePath" { return .stringLit([.text("main.swift")]) }
                if name == "function" { return .stringLit([.text("main")]) }
                if name == "Preview" || name == "if" {
                    // `#Preview { … }` is design-time only; `#if` blocks are rare in scripts.
                    if isPunct("(") { try skipBalanced("(", ")") }
                    if isPunct("{") { try skipBalanced("{", "}") }
                    return .nilLit
                }
                throw error("unsupported directive #\(name)")
            default:
                break
            }
        case .op:
            // A bare operator used as a value (`reduce(0, +)`) is handled in argument lists.
            break
        default:
            break
        }
        throw error(tok.kind == .eof ? "unexpected end of file" : "expected expression, found '\(tok.text)'")
    }
}
