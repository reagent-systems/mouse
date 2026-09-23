import Foundation

// The standard-library surface of the Swift VM: printing, equality, hashing, arithmetic, and the
// methods programs actually call on Int, Double, String, Array, Dictionary, Set and ranges. Each
// entry mirrors the real library's observable behaviour — `print([p])` qualifies the type name
// with the module the way swiftc's output does, integer overflow traps, `Dictionary` subscripts
// return Optionals — because the gate for this layer is byte-identical output against real
// swiftc on the same program (`verify/swiftvm`).

enum SwiftRuntime {
    /// The module name real Swift prints in debug descriptions (`[main.Point(x: 1)]`).
    static let moduleName = "main"

    /// Property wrappers whose storage is a shared cell (see `SwiftCell`).
    static let cellWrappers: Set<String> = ["State", "Binding", "Published", "AppStorage", "SceneStorage", "FocusState", "StateObject", "ObservedObject", "EnvironmentObject", "Bindable"]

    // MARK: - Names

    static func typeName(_ v: SwiftValue) -> String {
        switch v {
        case .void: "()"
        case .none: "Optional"
        case .some(let inner): "Optional<\(typeName(inner))>"
        case .int: "Int"
        case .double: "Double"
        case .bool: "Bool"
        case .string: "String"
        case .array(let items): "Array<\(items.first.map(typeName) ?? "Any")>"
        case .dictionary: "Dictionary"
        case .set: "Set"
        case .tuple: "Tuple"
        case .structValue(let s): s.type.name
        case .object(let o): o.type.name
        case .enumValue(let e): e.type.name
        case .function: "Function"
        case .type(let t): "\(t.name).Type"
        case .builtinType(let n): "\(n).Type"
        case .range: "Range<Int>"
        case .doubleRange: "ClosedRange<Double>"
        case .iterator: "Iterator"
        case .unresolved(let u): ".\(u.name)"
        case .keyPath: "KeyPath"
        case .cell(let c): typeName(c.value)
        case .view(let n): n.kind
        case .boxRef(let b): typeName(b.value)
        }
    }

    /// The builtin type a value's `extension` would be declared on.
    static func builtinTypeName(_ v: SwiftValue) -> String {
        switch v {
        case .int: "Int"
        case .double: "Double"
        case .bool: "Bool"
        case .string: "String"
        case .array: "Array"
        case .dictionary: "Dictionary"
        case .set: "Set"
        case .none, .some: "Optional"
        case .range: "Range"
        default: typeName(v)
        }
    }

    /// Protocols the builtin types conform to, for `extension Collection { … }`-style defaults.
    static func builtinConformances(_ v: SwiftValue) -> [String] {
        switch v {
        case .int: ["BinaryInteger", "FixedWidthInteger", "SignedInteger", "Numeric", "AdditiveArithmetic", "Comparable", "Equatable", "Hashable", "CustomStringConvertible", "Strideable"]
        case .double: ["BinaryFloatingPoint", "FloatingPoint", "Numeric", "AdditiveArithmetic", "Comparable", "Equatable", "Hashable", "CustomStringConvertible", "Strideable"]
        case .string: ["StringProtocol", "Collection", "Sequence", "BidirectionalCollection", "Comparable", "Equatable", "Hashable", "CustomStringConvertible"]
        case .array: ["Collection", "Sequence", "BidirectionalCollection", "RandomAccessCollection", "MutableCollection", "RangeReplaceableCollection", "Equatable", "Hashable"]
        case .dictionary, .set: ["Collection", "Sequence", "Equatable", "Hashable"]
        case .range: ["Collection", "Sequence", "BidirectionalCollection", "RandomAccessCollection", "Equatable", "Hashable"]
        case .bool: ["Equatable", "Hashable", "CustomStringConvertible"]
        default: []
        }
    }

    // MARK: - Hashing and equality

    static func hashKey(_ v: SwiftValue) -> String {
        switch v {
        case .void: return "v"
        case .none: return "n"
        case .some(let inner): return "?" + hashKey(inner)
        case .int(let i): return "i\(i)"
        case .double(let d): return "d\(d)"
        case .bool(let b): return b ? "T" : "F"
        case .string(let s): return "s\(s.count):" + s
        case .array(let items): return "[" + items.map(hashKey).joined(separator: ",") + "]"
        case .set(let d): return "{" + d.keys.map(hashKey).sorted().joined(separator: ",") + "}"
        case .dictionary(let d):
            return "{" + zip(d.keys, d.values).map { hashKey($0) + ":" + hashKey($1) }.sorted().joined(separator: ",") + "}"
        case .tuple(let t): return "(" + t.values.map(hashKey).joined(separator: ",") + ")"
        case .structValue(let s): return "S\(s.type.name){" + s.fields.map { hashKey($0.dereferenced) }.joined(separator: ",") + "}"
        case .object(let o): return "O\(ObjectIdentifier(o).hashValue)"
        case .enumValue(let e): return "E\(e.type.name).\(e.name)(" + e.payload.map(hashKey).joined(separator: ",") + ")"
        case .type(let t): return "t" + t.name
        case .builtinType(let n): return "t" + n
        case .range(let lo, let hi, let closed): return "r\(lo)\(closed ? "..." : "..<")\(hi)"
        case .doubleRange(let lo, let hi, let closed): return "R\(lo)\(closed ? "..." : "..<")\(hi)"
        case .unresolved(let u): return "u" + u.name
        case .cell(let c): return hashKey(c.value)
        case .keyPath(let p): return "k" + p.joined(separator: ".")
        case .boxRef(let b): return hashKey(b.value)
        case .function(let f): return "f\(ObjectIdentifier(f).hashValue)"
        case .iterator(let it): return "I\(ObjectIdentifier(it).hashValue)"
        case .view(let n): return "V\(ObjectIdentifier(n).hashValue)"
        }
    }

    static func equal(_ a: SwiftValue, _ b: SwiftValue) -> Bool {
        switch (a.dereferenced, b.dereferenced) {
        case (.none, .none): return true
        case (.none, _), (_, .none): return false
        case (.some(let x), .some(let y)): return equal(x, y)
        case (.some(let x), let y): return equal(x, y)
        case (let x, .some(let y)): return equal(x, y)
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.int(let x), .double(let y)): return Double(x) == y
        case (.double(let x), .int(let y)): return x == Double(y)
        case (.string(let x), .string(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.void, .void): return true
        case (.array(let x), .array(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.tuple(let x), .tuple(let y)):
            return x.values.count == y.values.count && zip(x.values, y.values).allSatisfy { equal($0, $1) }
        case (.dictionary(let x), .dictionary(let y)), (.set(let x), .set(let y)):
            guard x.count == y.count else { return false }
            for (k, v) in zip(x.keys, x.values) {
                guard let other = y.lookup(k), equal(v, other) else { return false }
            }
            return true
        case (.structValue(let x), .structValue(let y)):
            return x.type === y.type && zip(x.fields, y.fields).allSatisfy { equal($0, $1) }
        case (.enumValue(let x), .enumValue(let y)):
            return x.type === y.type && x.name == y.name && zip(x.payload, y.payload).allSatisfy { equal($0, $1) }
        case (.object(let x), .object(let y)): return x === y
        case (.type(let x), .type(let y)): return x === y
        case (.builtinType(let x), .builtinType(let y)): return x == y
        case (.range(let a1, let b1, let c1), .range(let a2, let b2, let c2)): return a1 == a2 && b1 == b2 && c1 == c2
        case (.unresolved(let x), .enumValue(let y)), (.enumValue(let y), .unresolved(let x)): return x.name == y.name
        case (.unresolved(let x), .unresolved(let y)): return x.name == y.name
        default: return false
        }
    }

    /// `<` for the builtin Comparable types; user types go through their own `<` first.
    static func less(_ a: SwiftValue, _ b: SwiftValue, vm: SwiftVM) throws -> Bool {
        switch (a.dereferenced, b.dereferenced) {
        case (.int(let x), .int(let y)): return x < y
        case (.double(let x), .double(let y)): return x < y
        case (.int(let x), .double(let y)): return Double(x) < y
        case (.double(let x), .int(let y)): return x < Double(y)
        case (.string(let x), .string(let y)): return x < y
        case (.bool(let x), .bool(let y)): return !x && y
        case (.tuple(let x), .tuple(let y)):
            for (l, r) in zip(x.values, y.values) {
                if try less(l, r, vm: vm) { return true }
                if try less(r, l, vm: vm) { return false }
            }
            return false
        case (.enumValue(let x), .enumValue(let y)) where x.type === y.type:
            if case .bool(let result) = try vm.binaryUser("<", a, b) { return result }
            return (x.type.caseIndex[x.name] ?? 0) < (y.type.caseIndex[y.name] ?? 0)
        case (.some(let x), .some(let y)): return try less(x, y, vm: vm)
        case (.none, .some): return true
        case (.some, .none), (.none, .none): return false
        case (let x, let y):
            if vm.typeOf(x) != nil, case .bool(let result) = try vm.binary("<", x, y) { return result }
            throw SwiftRuntimeError(message: "binary operator '<' cannot be applied to \(typeName(x)) and \(typeName(y))")
        }
    }

    // MARK: - Operators

    static func binary(_ op: String, _ l: SwiftValue, _ r: SwiftValue, vm: SwiftVM) throws -> SwiftValue {
        switch op {
        case "==": return .bool(equal(l, r))
        case "!=": return .bool(!equal(l, r))
        case "===":
            if case .object(let x) = l, case .object(let y) = r { return .bool(x === y) }
            return .bool(l.isNone && r.isNone)
        case "!==":
            if case .object(let x) = l, case .object(let y) = r { return .bool(x !== y) }
            return .bool(!(l.isNone && r.isNone))
        case "<": return .bool(try less(l, r, vm: vm))
        case ">": return .bool(try less(r, l, vm: vm))
        case "<=": return .bool(!(try less(r, l, vm: vm)))
        case ">=": return .bool(!(try less(l, r, vm: vm)))
        case "..<", "...":
            let closed = op == "..."
            switch (l, r) {
            case (.int(let a), .int(let b)):
                if closed ? a > b : a > b {
                    throw SwiftRuntimeError(message: "Range requires lowerBound <= upperBound")
                }
                return .range(a, b, closed: closed)
            case (.double(let a), .double(let b)): return .doubleRange(a, b, closed: closed)
            case (.int(let a), .double(let b)): return .doubleRange(Double(a), b, closed: closed)
            case (.double(let a), .int(let b)): return .doubleRange(a, Double(b), closed: closed)
            case (.string(let a), .string(let b)):
                // Character ranges (`"a"..."z"`) only ever feed `~=` and `contains`.
                return .tuple(SwiftTuple(values: [.string(a), .string(b), .bool(closed)], labels: ["lower", "upper", "closed"]))
            default:
                throw SwiftRuntimeError(message: "cannot form a range from \(typeName(l)) and \(typeName(r))")
            }
        case "~=":
            return .bool(try vm.matches(l, r))
        default:
            break
        }
        switch (l, r) {
        case (.int(let a), .int(let b)):
            switch op {
            case "+": let (v, o) = a.addingReportingOverflow(b); if o { throw overflow() }; return .int(v)
            case "-": let (v, o) = a.subtractingReportingOverflow(b); if o { throw overflow() }; return .int(v)
            case "*": let (v, o) = a.multipliedReportingOverflow(by: b); if o { throw overflow() }; return .int(v)
            case "/":
                guard b != 0 else { throw SwiftRuntimeError(message: "Division by zero") }
                return .int(a / b)
            case "%":
                guard b != 0 else { throw SwiftRuntimeError(message: "Division by zero in remainder operation") }
                return .int(a % b)
            case "&+": return .int(a &+ b)
            case "&-": return .int(a &- b)
            case "&*": return .int(a &* b)
            case "&": return .int(a & b)
            case "|": return .int(a | b)
            case "^": return .int(a ^ b)
            case "<<": return .int(a << b)
            case ">>": return .int(a >> b)
            default: break
            }
        case (.double, .double), (.int, .double), (.double, .int):
            let a = number(l)!, b = number(r)!
            switch op {
            case "+": return .double(a + b)
            case "-": return .double(a - b)
            case "*": return .double(a * b)
            case "/": return .double(a / b)
            case "%": return .double(a.truncatingRemainder(dividingBy: b))
            default: break
            }
        case (.string(let a), .string(let b)) where op == "+":
            return .string(a + b)
        case (.array(let a), .array(let b)) where op == "+":
            return .array(a + b)
        case (.bool(let a), .bool(let b)):
            switch op {
            case "&&": return .bool(a && b)
            case "||": return .bool(a || b)
            default: break
            }
        default:
            break
        }
        throw SwiftRuntimeError(message: "binary operator '\(op)' cannot be applied to operands of type '\(typeName(l))' and '\(typeName(r))'")
    }

    private static func overflow() -> SwiftRuntimeError {
        SwiftRuntimeError(message: "arithmetic overflow")
    }

    static func number(_ v: SwiftValue) -> Double? {
        switch v.dereferenced {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    static func prefix(_ op: String, _ v: SwiftValue) throws -> SwiftValue {
        switch (op, v.dereferenced) {
        case ("-", .int(let i)):
            guard i != Int.min else { throw overflow() }
            return .int(-i)
        case ("-", .double(let d)): return .double(-d)
        case ("+", let x): return x
        case ("!", .bool(let b)): return .bool(!b)
        case ("~", .int(let i)): return .int(~i)
        case ("..<", .int(let i)): return .range(Int.min, i, closed: false)
        case ("...", .int(let i)): return .range(Int.min, i, closed: true)
        case ("&", let x): return x
        default:
            throw SwiftRuntimeError(message: "unary operator '\(op)' cannot be applied to \(typeName(v))")
        }
    }

    // MARK: - Description

    static func describe(_ v: SwiftValue, vm: SwiftVM, debug: Bool) throws -> String {
        switch v {
        case .void: return "()"
        case .none: return "nil"
        case .some(let inner): return "Optional(" + (try describe(inner, vm: vm, debug: true)) + ")"
        case .int(let i): return String(i)
        case .double(let d): return String(describing: d)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return debug ? quote(s) : s
        case .array(let items):
            return "[" + (try items.map { try describe($0, vm: vm, debug: true) }).joined(separator: ", ") + "]"
        case .set(let d):
            return "[" + (try d.keys.map { try describe($0, vm: vm, debug: true) }).joined(separator: ", ") + "]"
        case .dictionary(let d):
            if d.count == 0 { return "[:]" }
            return "[" + (try zip(d.keys, d.values).map {
                try describe($0, vm: vm, debug: true) + ": " + describe($1, vm: vm, debug: true)
            }).joined(separator: ", ") + "]"
        case .tuple(let t):
            let parts = try zip(t.values, t.labels).map { value, label in
                (label.map { "\($0): " } ?? "") + (try describe(value, vm: vm, debug: true))
            }
            return "(" + parts.joined(separator: ", ") + ")"
        case .structValue(let s):
            if let custom = try customDescription(v, s.type, vm: vm, debug: debug) { return custom }
            let fields = try zip(s.type.stored, s.fields).map { prop, value in
                "\(prop.name): " + (try describe(value.dereferenced, vm: vm, debug: true))
            }
            let name = debug ? "\(moduleName).\(s.type.name)" : s.type.shortName
            return name + "(" + fields.joined(separator: ", ") + ")"
        case .object(let o):
            if let custom = try customDescription(v, o.type, vm: vm, debug: debug) { return custom }
            return "\(moduleName).\(o.type.name)"
        case .enumValue(let e):
            if let custom = try customDescription(v, e.type, vm: vm, debug: debug) { return custom }
            var text = debug ? "\(moduleName).\(e.type.name).\(e.name)" : e.name
            if !e.payload.isEmpty {
                let labels = e.type.caseIndex[e.name].flatMap { e.type.cases[$0].labels } ?? []
                let parts = try e.payload.enumerated().map { i, value in
                    let label = i < labels.count ? labels[i] : nil
                    return (label.map { "\($0): " } ?? "") + (try describe(value, vm: vm, debug: true))
                }
                text += "(" + parts.joined(separator: ", ") + ")"
            }
            return text
        case .function: return "(Function)"
        case .type(let t): return t.shortName
        case .builtinType(let n): return n
        case .range(let lo, let hi, let closed):
            if lo == Int.min { return (closed ? "..." : "..<") + String(hi) }
            if hi == Int.max && closed { return "\(lo)..." }
            return "\(lo)\(closed ? "..." : "..<")\(hi)"
        case .doubleRange(let lo, let hi, let closed): return "\(lo)\(closed ? "..." : "..<")\(hi)"
        case .iterator: return "IndexingIterator"
        case .unresolved(let u): return u.name
        case .keyPath(let p): return "\\." + p.joined(separator: ".")
        case .cell(let c): return try describe(c.value, vm: vm, debug: debug)
        case .view(let n): return n.kind
        case .boxRef(let b): return try describe(b.value, vm: vm, debug: debug)
        }
    }

    private static func customDescription(_ v: SwiftValue, _ type: SwiftTypeInfo, vm: SwiftVM, debug: Bool) throws -> String? {
        if debug, vm.conforms(type, to: "CustomDebugStringConvertible"), vm.findComputed(type, "debugDescription") != nil || type.storedIndex["debugDescription"] != nil {
            if case .string(let s) = try vm.getMember(v, "debugDescription") { return s }
        }
        let conforms = vm.conforms(type, to: "CustomStringConvertible") || vm.conforms(type, to: "LocalizedError") && false
        if conforms, vm.findComputed(type, "description") != nil || type.storedIndex["description"] != nil {
            if case .string(let s) = try vm.getMember(v, "description") { return s }
        }
        return nil
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\0": out += "\\0"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    // MARK: - Sequences

    /// The elements of anything `for-in` could iterate.
    static func elements(_ v: SwiftValue, vm: SwiftVM) throws -> [SwiftValue] {
        switch v.dereferenced {
        case .array(let items): return items
        case .set(let d): return d.keys
        case .string(let s): return s.map { .string(String($0)) }
        case .range(let lo, let hi, let closed):
            let upper = closed ? hi + 1 : hi
            guard upper > lo else { return [] }
            return (lo..<upper).map { .int($0) }
        case .dictionary(let d):
            return zip(d.keys, d.values).map { .tuple(SwiftTuple(values: [$0, $1], labels: ["key", "value"])) }
        case .none: return []
        case .some(let inner): return try elements(inner, vm: vm)
        case let other:
            let it = try vm.makeIterator(other)
            var out: [SwiftValue] = []
            while let next = it.next() { out.append(next) }
            return out
        }
    }

    private static func bool(_ v: SwiftValue) throws -> Bool {
        if case .bool(let b) = v.dereferenced { return b }
        throw SwiftRuntimeError(message: "expected Bool, found \(typeName(v))")
    }

    private static func int(_ v: SwiftValue) throws -> Int {
        switch v.dereferenced {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: throw SwiftRuntimeError(message: "expected Int, found \(typeName(v))")
        }
    }

    private static func string(_ v: SwiftValue) throws -> String {
        if case .string(let s) = v.dereferenced { return s }
        throw SwiftRuntimeError(message: "expected String, found \(typeName(v))")
    }

    private static func arg(_ args: [SwiftValue], _ i: Int, _ method: String) throws -> SwiftValue {
        guard i < args.count else { throw SwiftRuntimeError(message: "missing argument in call to \(method)") }
        return args[i]
    }

    /// A key path used where a function is expected: `map(\.name)`.
    private static func callable(_ f: SwiftValue) -> SwiftValue {
        if case .keyPath(let path) = f {
            return .function(SwiftFunction(.native("keyPath") { args, _, vm in
                var v = args.first ?? .void
                for p in path where p != "self" { v = try vm.getMember(v, p) }
                return v
            }))
        }
        return f
    }

    /// Collections rebuild their own kind from filtered elements: a filtered String is a String.
    private static func rebuild(_ original: SwiftValue, _ items: [SwiftValue]) -> SwiftValue {
        switch original.dereferenced {
        case .string:
            return .string(items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }.joined())
        case .set:
            var d = SwiftDictionary()
            for i in items { d.set(i, .void) }
            return .set(d)
        default:
            return .array(items)
        }
    }

    // MARK: - Properties

    static func builtinProperty(_ receiver: SwiftValue, _ name: String, vm: SwiftVM) throws -> SwiftValue? {
        let r = receiver.dereferenced
        switch name {
        case "description":
            return .string(try describe(r, vm: vm, debug: false))
        case "debugDescription":
            return .string(try describe(r, vm: vm, debug: true))
        case "self":
            return r
        default:
            break
        }
        switch r {
        case .int(let i):
            switch name {
            case "magnitude": return .int(i.magnitude > UInt(Int.max) ? Int.max : Int(i.magnitude))
            case "isZero": return .bool(i == 0)
            case "words", "bitWidth": return .int(64)
            case "nonzeroBitCount": return .int(i.nonzeroBitCount)
            case "leadingZeroBitCount": return .int(i.leadingZeroBitCount)
            case "trailingZeroBitCount": return .int(i.trailingZeroBitCount)
            default: return nil
            }
        case .double(let d):
            switch name {
            case "isNaN": return .bool(d.isNaN)
            case "isInfinite": return .bool(d.isInfinite)
            case "isFinite": return .bool(d.isFinite)
            case "isZero": return .bool(d.isZero)
            case "magnitude": return .double(d.magnitude)
            case "sign": return .unresolved(SwiftUnresolved(name: d.sign == .minus ? "minus" : "plus", args: nil, labels: []))
            default: return nil
            }
        case .string(let s):
            switch name {
            case "count": return .int(s.count)
            case "isEmpty": return .bool(s.isEmpty)
            case "first": return s.first.map { .some(.string(String($0))) } ?? SwiftValue.none
            case "last": return s.last.map { .some(.string(String($0))) } ?? SwiftValue.none
            case "startIndex": return .int(0)
            case "endIndex": return .int(s.count)
            case "indices": return .range(0, s.count, closed: false)
            case "capitalized": return .string(s.capitalized)
            case "utf8": return .array(s.utf8.map { .int(Int($0)) })
            case "utf16": return .array(s.utf16.map { .int(Int($0)) })
            case "unicodeScalars": return .array(s.unicodeScalars.map { .string(String($0)) })
            case "isLetter": return .bool(s.first?.isLetter ?? false)
            case "isNumber": return .bool(s.first?.isNumber ?? false)
            case "isWhitespace": return .bool(s.first?.isWhitespace ?? false)
            case "isNewline": return .bool(s.first?.isNewline ?? false)
            case "isUppercase": return .bool(s.first?.isUppercase ?? false)
            case "isLowercase": return .bool(s.first?.isLowercase ?? false)
            case "isPunctuation": return .bool(s.first?.isPunctuation ?? false)
            case "isSymbol": return .bool(s.first?.isSymbol ?? false)
            case "isHexDigit": return .bool(s.first?.isHexDigit ?? false)
            case "isASCII": return .bool(s.first?.isASCII ?? false)
            case "isCased": return .bool(s.first?.isCased ?? false)
            case "isLetterOrDigit": return .bool((s.first?.isLetter ?? false) || (s.first?.isNumber ?? false))
            case "asciiValue": return s.first?.asciiValue.map { .some(.int(Int($0))) } ?? SwiftValue.none
            case "wholeNumberValue": return s.first?.wholeNumberValue.map { .some(.int($0)) } ?? SwiftValue.none
            case "hexDigitValue": return s.first?.hexDigitValue.map { .some(.int($0)) } ?? SwiftValue.none
            case "value": return .int(Int(s.unicodeScalars.first?.value ?? 0))
            default: return nil
            }
        case .array(let items):
            switch name {
            case "count": return .int(items.count)
            case "isEmpty": return .bool(items.isEmpty)
            case "first": return items.first.map { .some($0) } ?? SwiftValue.none
            case "last": return items.last.map { .some($0) } ?? SwiftValue.none
            case "startIndex": return .int(0)
            case "endIndex": return .int(items.count)
            case "indices": return .range(0, items.count, closed: false)
            case "capacity": return .int(items.capacity)
            case "lazy": return r
            default: return nil
            }
        case .dictionary(let d):
            switch name {
            case "count": return .int(d.count)
            case "isEmpty": return .bool(d.count == 0)
            case "keys": return .array(d.keys)
            case "values": return .array(d.values)
            case "first": return d.count > 0 ? .some(.tuple(SwiftTuple(values: [d.keys[0], d.values[0]], labels: ["key", "value"]))) : SwiftValue.none
            case "lazy": return r
            default: return nil
            }
        case .set(let d):
            switch name {
            case "count": return .int(d.count)
            case "isEmpty": return .bool(d.count == 0)
            case "first": return d.keys.first.map { .some($0) } ?? SwiftValue.none
            default: return nil
            }
        case .range(let lo, let hi, let closed):
            let upper = closed ? hi + 1 : hi
            switch name {
            case "lowerBound": return .int(lo)
            case "upperBound": return .int(hi)
            case "count": return .int(max(0, upper - lo))
            case "isEmpty": return .bool(upper <= lo)
            case "first": return upper > lo ? .some(.int(lo)) : SwiftValue.none
            case "last": return upper > lo ? .some(.int(upper - 1)) : SwiftValue.none
            case "startIndex": return .int(lo)
            case "endIndex": return .int(upper)
            case "indices": return r
            case "lazy": return r
            default: return nil
            }
        case .doubleRange(let lo, let hi, _):
            switch name {
            case "lowerBound": return .double(lo)
            case "upperBound": return .double(hi)
            default: return nil
            }
        case .tuple(let t) where t.labels == ["lower", "upper", "closed"]:
            return nil
        case .enumValue(let e) where e.type.conformances.contains("Error") || vm.conforms(e.type, to: "Error"):
            if name == "localizedDescription" {
                if let c = vm.findComputed(e.type, "errorDescription"), let g = c.getter,
                   let text = try vm.invoke(proto: g, arguments: [], selfValue: r, upvalues: [], mode: .normal).unwrapped,
                   case .string(let s) = text {
                    return .string(s)
                }
                let index = e.type.caseIndex[e.name] ?? 0
                return .string("The operation couldn’t be completed. (\(moduleName).\(e.type.name) error \(index).)")
            }
            return nil
        case .structValue(let s) where name == "localizedDescription":
            if let c = vm.findComputed(s.type, "errorDescription"), let g = c.getter,
               let text = try vm.invoke(proto: g, arguments: [], selfValue: r, upvalues: [], mode: .normal).unwrapped,
               case .string(let str) = text {
                return .string(str)
            }
            return .string("The operation couldn’t be completed. (\(moduleName).\(s.type.name) error 1.)")
        case .builtinType(let typeName):
            return try staticBuiltin(typeName, name)
        case .some(let inner) where name == "unsafelyUnwrapped":
            return inner
        default:
            return nil
        }
    }

    static func staticBuiltin(_ typeName: String, _ name: String) throws -> SwiftValue? {
        switch (typeName, name) {
        case ("Int", "max"): return .int(Int.max)
        case ("Int", "min"): return .int(Int.min)
        case ("Int", "zero"), ("Int", "self"): return name == "zero" ? .int(0) : .builtinType("Int")
        case ("Double", "pi"), ("CGFloat", "pi"), ("Float", "pi"): return .double(Double.pi)
        case ("Double", "infinity"), ("CGFloat", "infinity"), ("Float", "infinity"): return .double(Double.infinity)
        case ("Double", "nan"), ("Float", "nan"): return .double(Double.nan)
        case ("Double", "greatestFiniteMagnitude"): return .double(Double.greatestFiniteMagnitude)
        case ("Double", "leastNonzeroMagnitude"): return .double(Double.leastNonzeroMagnitude)
        case ("Double", "ulpOfOne"): return .double(Double.ulpOfOne)
        case ("Double", "zero"), ("CGFloat", "zero"): return .double(0)
        case ("String", "self"), ("Double", "self"), ("Bool", "self"): return .builtinType(typeName)
        default: return SwiftViewLibrary.staticMember(typeName, name)
        }
    }

    // MARK: - Methods

    private static let stringMethods: Set<String> = [
        "uppercased", "lowercased", "hasPrefix", "hasSuffix", "contains", "split", "components",
        "replacingOccurrences", "trimmingCharacters", "reversed", "sorted", "map", "filter", "compactMap",
        "flatMap", "forEach", "reduce", "prefix", "suffix", "dropFirst", "dropLast", "index", "firstIndex",
        "lastIndex", "starts", "allSatisfy", "enumerated", "first", "last", "count", "max", "min",
        "joined", "padding", "range", "distance", "elementsEqual", "localizedCaseInsensitiveContains",
        "caseInsensitiveCompare", "compare", "shuffled", "randomElement",
    ]

    private static let sequenceMethods: Set<String> = [
        "map", "compactMap", "flatMap", "filter", "reduce", "forEach", "enumerated", "contains",
        "first", "firstIndex", "last", "lastIndex", "allSatisfy", "joined", "sorted", "reversed",
        "min", "max", "prefix", "suffix", "dropFirst", "dropLast", "randomElement", "shuffled",
        "elementsEqual", "starts", "index", "distance", "split", "count",
        "union", "intersection", "subtracting", "symmetricDifference", "isSubset", "isSuperset",
        "isDisjoint", "isStrictSubset", "isStrictSuperset", "mapValues", "compactMapValues",
        "drop", "lexicographicallyPrecedes", "makeIterator",
    ]

    static func hasBuiltinMethod(_ receiver: SwiftValue, _ name: String) -> Bool {
        switch receiver.dereferenced {
        case .int: return ["isMultiple", "signum", "quotientAndRemainder", "advanced", "distance", "formatted", "clamped"].contains(name)
        case .double: return ["rounded", "squareRoot", "truncatingRemainder", "remainder", "advanced", "distance", "formatted", "clamped"].contains(name)
        case .string: return stringMethods.contains(name)
        case .array, .set, .dictionary, .range: return sequenceMethods.contains(name)
        case .builtinType: return true
        case .function: return name == "callAsFunction"
        case .doubleRange: return name == "contains"
        case .tuple(let t) where t.labels == ["lower", "upper", "closed"]: return name == "contains"
        case .none, .some: return ["map", "flatMap"].contains(name)
        default: return false
        }
    }

    /// A trailing closure arrives unlabelled; give it the label the method's closure parameter
    /// has (`removeAll { … }` is `removeAll(where:)`).
    static func trailingLabels(_ name: String, _ args: [SwiftValue], _ labels: [String?]) -> [String?] {
        guard let last = args.last, case .function = last, labels.last == Optional<String?>.some(nil) else { return labels }
        let label: String
        switch name {
        case "contains", "firstIndex", "lastIndex", "removeAll", "first", "last": label = "where"
        case "prefix", "drop": label = "while"
        case "sorted", "sort", "min", "max": label = "by"
        case "split": label = "whereSeparator"
        default: return labels
        }
        var out = labels
        out[out.count - 1] = label
        return out
    }

    static func invokeBuiltin(_ receiver: SwiftValue, _ name: String, _ args: [SwiftValue], _ rawLabels: [String?], vm: SwiftVM) throws -> SwiftValue {
        let labels = trailingLabels(name, args, rawLabels)
        let r = receiver.dereferenced
        switch r {
        case .builtinType(let typeName):
            return try invokeStatic(typeName, name, args, labels, vm: vm)
        case .function:
            if name == "callAsFunction" { return try vm.call(r, args, labels: labels) }
        case .int(let i):
            switch name {
            case "isMultiple": let d = try int(try arg(args, 0, name)); return .bool(d == 0 ? i == 0 : i % d == 0)
            case "signum": return .int(i.signum())
            case "quotientAndRemainder":
                let d = try int(try arg(args, 0, name))
                guard d != 0 else { throw SwiftRuntimeError(message: "Division by zero") }
                return .tuple(SwiftTuple(values: [.int(i / d), .int(i % d)], labels: ["quotient", "remainder"]))
            case "advanced": return .int(i + (try int(try arg(args, 0, name))))
            case "distance": return .int((try int(try arg(args, 0, name))) - i)
            case "formatted": return .string(String(i))
            default: break
            }
        case .double(let d):
            switch name {
            case "rounded":
                if let rule = args.first, case .unresolved(let u) = rule {
                    switch u.name {
                    case "up": return .double(d.rounded(.up))
                    case "down": return .double(d.rounded(.down))
                    case "towardZero": return .double(d.rounded(.towardZero))
                    case "awayFromZero": return .double(d.rounded(.awayFromZero))
                    case "toNearestOrEven": return .double(d.rounded(.toNearestOrEven))
                    default: return .double(d.rounded())
                    }
                }
                return .double(d.rounded())
            case "squareRoot": return .double(d.squareRoot())
            case "truncatingRemainder": return .double(d.truncatingRemainder(dividingBy: number(try arg(args, 0, name)) ?? 1))
            case "remainder": return .double(d.remainder(dividingBy: number(try arg(args, 0, name)) ?? 1))
            case "advanced": return .double(d + (number(try arg(args, 0, name)) ?? 0))
            case "distance": return .double((number(try arg(args, 0, name)) ?? 0) - d)
            case "formatted": return .string(String(describing: d))
            default: break
            }
        case .string(let s):
            if let result = try stringMethod(s, name, args, labels, vm: vm) { return result }
        case .doubleRange(let lo, let hi, let closed) where name == "contains":
            guard let x = number(try arg(args, 0, name)) else { return .bool(false) }
            return .bool(lo <= x && (closed ? x <= hi : x < hi))
        case .tuple(let t) where name == "contains" && t.labels == ["lower", "upper", "closed"]:
            guard case .string(let lo) = t.values[0], case .string(let hi) = t.values[1], case .bool(let closed) = t.values[2],
                  case .string(let x) = try arg(args, 0, name) else { return .bool(false) }
            return .bool(lo <= x && (closed ? x <= hi : x < hi))
        case .range(let lo, let hi, let closed) where name == "contains" && labels.first != "where":
            guard case .int(let x) = try arg(args, 0, name) else { return .bool(false) }
            return .bool(x >= lo && (closed ? x <= hi : x < hi))
        case .none where name == "map" || name == "flatMap":
            return .none
        case .some(let inner) where name == "map" || name == "flatMap":
            let result = try vm.call(callable(try arg(args, 0, name)), [inner])
            if name == "flatMap" { return result }
            if case .none = result { return .some(.none) }
            return .some(result)
        case .dictionary(let d):
            if let result = try dictionaryMethod(d, name, args, labels, vm: vm) { return result }
        case .set(let d):
            if let result = try setMethod(d, name, args, labels, vm: vm) { return result }
        default:
            break
        }
        if sequenceMethods.contains(name) {
            switch r {
            case .array, .set, .dictionary, .range, .string:
                return try sequenceMethod(r, try elements(r, vm: vm), name, args, labels, vm: vm)
            default:
                break
            }
        }
        throw SwiftRuntimeError(message: "value of type '\(typeName(r))' has no member '\(name)'")
    }

    private static func sequenceMethod(_ original: SwiftValue, _ items: [SwiftValue], _ name: String, _ args: [SwiftValue],
                                       _ labels: [String?], vm: SwiftVM) throws -> SwiftValue {
        func fn(_ i: Int = 0) throws -> SwiftValue { callable(try arg(args, i, name)) }
        func test(_ f: SwiftValue, _ v: SwiftValue) throws -> Bool { try bool(try vm.call(f, [v])) }
        switch name {
        case "map":
            let f = try fn()
            return .array(try items.map { try vm.call(f, [$0]) })
        case "compactMap":
            let f = try fn()
            return .array(try items.compactMap { try vm.call(f, [$0]).unwrapped })
        case "flatMap":
            let f = try fn()
            return .array(try items.flatMap { v -> [SwiftValue] in
                let result = try vm.call(f, [v])
                if case .none = result { return [] }
                if case .some(let x) = result { return [x] }
                return try elements(result, vm: vm)
            })
        case "filter":
            let f = try fn()
            return rebuild(original, try items.filter { try test(f, $0) })
        case "forEach":
            let f = try fn()
            for item in items { _ = try vm.call(f, [item]) }
            return .void
        case "reduce":
            if labels.first == "into" {
                var acc = try arg(args, 0, name)
                let f = try fn(1)
                for item in items {
                    acc = try vm.callAccumulating(f, acc, item)
                }
                return acc
            }
            var acc = try arg(args, 0, name)
            let f = try fn(1)
            for item in items { acc = try vm.call(f, [acc, item]) }
            return acc
        case "enumerated":
            return .array(items.enumerated().map { .tuple(SwiftTuple(values: [.int($0.offset), $0.element], labels: ["offset", "element"])) })
        case "contains":
            if labels.first == "where" {
                let f = try fn()
                return .bool(try items.contains { try test(f, $0) })
            }
            let target = try arg(args, 0, name)
            if case .string(let sub) = target, case .string(let s) = original { return .bool(s.contains(sub)) }
            return .bool(items.contains { equal($0, target) })
        case "first":
            let f = try fn()
            return try items.first { try test(f, $0) }.map { .some($0) } ?? .none
        case "last":
            let f = try fn()
            return try items.last { try test(f, $0) }.map { .some($0) } ?? .none
        case "firstIndex", "index":
            let index: Int?
            if labels.first == "where" {
                let f = try fn()
                index = try items.firstIndex { try test(f, $0) }
            } else {
                let target = try arg(args, 0, name)
                index = items.firstIndex { equal($0, target) }
            }
            return index.map { .some(.int(indexOffset(original) + $0)) } ?? .none
        case "lastIndex":
            let index: Int?
            if labels.first == "where" {
                let f = try fn()
                index = try items.lastIndex { try test(f, $0) }
            } else {
                let target = try arg(args, 0, name)
                index = items.lastIndex { equal($0, target) }
            }
            return index.map { .some(.int(indexOffset(original) + $0)) } ?? .none
        case "allSatisfy":
            let f = try fn()
            return .bool(try items.allSatisfy { try test(f, $0) })
        case "count":
            let f = try fn()
            return .int(try items.filter { try test(f, $0) }.count)
        case "joined":
            let sep = labels.first == "separator" ? try string(try arg(args, 0, name)) : ""
            if case .array(let first)? = items.first, !first.isEmpty || items.allSatisfy({ if case .array = $0 { return true }; return false }) {
                return .array(try items.flatMap { try elements($0, vm: vm) })
            }
            return .string(try items.map { try describe($0, vm: vm, debug: false) }.joined(separator: sep))
        case "sorted":
            if args.isEmpty {
                return .array(try items.sorted { try less($0, $1, vm: vm) })
            }
            let f = try fn()
            return .array(try items.sorted { try bool(try vm.call(f, [$0, $1])) })
        case "reversed":
            return .array(items.reversed())
        case "min", "max":
            let ordered: (SwiftValue, SwiftValue) throws -> Bool
            if args.isEmpty {
                ordered = { try less($0, $1, vm: vm) }
            } else {
                let f = try fn()
                ordered = { try bool(try vm.call(f, [$0, $1])) }
            }
            let result = name == "min" ? try items.min(by: ordered) : try items.max(by: ordered)
            return result.map { .some($0) } ?? .none
        case "prefix":
            if labels.first == "while" {
                let f = try fn()
                var out: [SwiftValue] = []
                for item in items { guard try test(f, item) else { break }; out.append(item) }
                return rebuild(original, out)
            }
            return rebuild(original, Array(items.prefix(max(0, try int(try arg(args, 0, name))))))
        case "suffix":
            return rebuild(original, Array(items.suffix(max(0, try int(try arg(args, 0, name))))))
        case "dropFirst":
            let n = args.isEmpty ? 1 : try int(args[0])
            return rebuild(original, Array(items.dropFirst(max(0, n))))
        case "dropLast":
            let n = args.isEmpty ? 1 : try int(args[0])
            return rebuild(original, Array(items.dropLast(max(0, n))))
        case "drop":
            let f = try fn()
            var dropping = true
            var out: [SwiftValue] = []
            for item in items {
                if dropping, try test(f, item) { continue }
                dropping = false
                out.append(item)
            }
            return rebuild(original, out)
        case "randomElement":
            return items.randomElement().map { .some($0) } ?? .none
        case "shuffled":
            return .array(items.shuffled())
        case "elementsEqual":
            let other = try elements(try arg(args, 0, name), vm: vm)
            return .bool(items.count == other.count && zip(items, other).allSatisfy { equal($0, $1) })
        case "starts":
            let other = try elements(try arg(args, 0, name), vm: vm)
            return .bool(items.count >= other.count && zip(items, other).allSatisfy { equal($0, $1) })
        case "split":
            if case .string = original { break }
            let sep = try arg(args, 0, name)
            var out: [SwiftValue] = []
            var current: [SwiftValue] = []
            for item in items {
                if equal(item, sep) { if !current.isEmpty { out.append(.array(current)) }; current = [] } else { current.append(item) }
            }
            if !current.isEmpty { out.append(.array(current)) }
            return .array(out)
        case "isEmpty":
            return .bool(items.isEmpty)
        case "union", "intersection", "subtracting", "symmetricDifference", "isSubset", "isSuperset", "isDisjoint":
            var d = SwiftDictionary()
            for i in items { d.set(i, .void) }
            return try setMethod(d, name, args, labels, vm: vm) ?? .void
        case "lexicographicallyPrecedes":
            let other = try elements(try arg(args, 0, name), vm: vm)
            for (a, b) in zip(items, other) {
                if try less(a, b, vm: vm) { return .bool(true) }
                if try less(b, a, vm: vm) { return .bool(false) }
            }
            return .bool(items.count < other.count)
        case "makeIterator":
            return .iterator(SwiftIterator(.values(items)))
        default:
            break
        }
        throw SwiftRuntimeError(message: "value of type '\(typeName(original))' has no member '\(name)'")
    }

    /// Ranges index from their lower bound; everything else from zero.
    private static func indexOffset(_ v: SwiftValue) -> Int {
        if case .range(let lo, _, _) = v { return lo }
        return 0
    }

    private static func dictionaryMethod(_ d: SwiftDictionary, _ name: String, _ args: [SwiftValue], _ labels: [String?], vm: SwiftVM) throws -> SwiftValue? {
        switch name {
        case "mapValues":
            let f = callable(try arg(args, 0, name))
            var out = d
            out.values = try d.values.map { try vm.call(f, [$0]) }
            return .dictionary(out)
        case "compactMapValues":
            let f = callable(try arg(args, 0, name))
            var out = SwiftDictionary()
            for (k, v) in zip(d.keys, d.values) {
                if let mapped = try vm.call(f, [v]).unwrapped { out.set(k, mapped) }
            }
            return .dictionary(out)
        case "filter":
            let f = callable(try arg(args, 0, name))
            var out = SwiftDictionary()
            for (k, v) in zip(d.keys, d.values) {
                let pair = SwiftValue.tuple(SwiftTuple(values: [k, v], labels: ["key", "value"]))
                if try bool(try vm.call(f, [pair])) { out.set(k, v) }
            }
            return .dictionary(out)
        case "index":
            guard labels.first == "forKey" else { return nil }
            let key = try arg(args, 0, name)
            return d.index[hashKey(key)].map { .some(.int($0)) } ?? SwiftValue.none
        default:
            return nil
        }
    }

    private static func setMethod(_ d: SwiftDictionary, _ name: String, _ args: [SwiftValue], _ labels: [String?], vm: SwiftVM) throws -> SwiftValue? {
        func otherSet() throws -> SwiftDictionary {
            var o = SwiftDictionary()
            for item in try elements(try arg(args, 0, name), vm: vm) { o.set(item, .void) }
            return o
        }
        switch name {
        case "contains" where labels.first != "where":
            return .bool(d.lookup(try arg(args, 0, name)) != nil)
        case "union":
            var out = d
            for k in try otherSet().keys { out.set(k, .void) }
            return .set(out)
        case "intersection":
            let o = try otherSet()
            var out = SwiftDictionary()
            for k in d.keys where o.lookup(k) != nil { out.set(k, .void) }
            return .set(out)
        case "subtracting":
            let o = try otherSet()
            var out = SwiftDictionary()
            for k in d.keys where o.lookup(k) == nil { out.set(k, .void) }
            return .set(out)
        case "symmetricDifference":
            let o = try otherSet()
            var out = SwiftDictionary()
            for k in d.keys where o.lookup(k) == nil { out.set(k, .void) }
            for k in o.keys where d.lookup(k) == nil { out.set(k, .void) }
            return .set(out)
        case "isSubset":
            let o = try otherSet()
            return .bool(d.keys.allSatisfy { o.lookup($0) != nil })
        case "isStrictSubset":
            let o = try otherSet()
            return .bool(d.keys.allSatisfy { o.lookup($0) != nil } && o.count > d.count)
        case "isSuperset":
            let o = try otherSet()
            return .bool(o.keys.allSatisfy { d.lookup($0) != nil })
        case "isStrictSuperset":
            let o = try otherSet()
            return .bool(o.keys.allSatisfy { d.lookup($0) != nil } && d.count > o.count)
        case "isDisjoint":
            let o = try otherSet()
            return .bool(d.keys.allSatisfy { o.lookup($0) == nil })
        case "filter":
            let f = callable(try arg(args, 0, name))
            var out = SwiftDictionary()
            for k in d.keys where try bool(try vm.call(f, [k])) { out.set(k, .void) }
            return .set(out)
        default:
            return nil
        }
    }

    private static func stringMethod(_ s: String, _ name: String, _ args: [SwiftValue], _ labels: [String?], vm: SwiftVM) throws -> SwiftValue? {
        switch name {
        case "uppercased": return .string(s.uppercased())
        case "lowercased": return .string(s.lowercased())
        case "hasPrefix": return .bool(s.hasPrefix(try string(try arg(args, 0, name))))
        case "hasSuffix": return .bool(s.hasSuffix(try string(try arg(args, 0, name))))
        case "contains":
            if labels.first == "where" { return nil }
            if case .string(let sub) = try arg(args, 0, name) { return .bool(sub.isEmpty ? true : s.contains(sub)) }
            return nil
        case "localizedCaseInsensitiveContains":
            return .bool(s.localizedCaseInsensitiveContains(try string(try arg(args, 0, name))))
        case "split":
            var maxSplits = Int.max
            var omitting = true
            var separator: SwiftValue? = nil
            for (i, label) in labels.enumerated() {
                switch label {
                case "separator": separator = args[i]
                case "maxSplits": maxSplits = try int(args[i])
                case "omittingEmptySubsequences": omitting = try bool(args[i])
                case "whereSeparator":
                    let f = callable(args[i])
                    let parts = try s.split(maxSplits: maxSplits, omittingEmptySubsequences: omitting) { ch in
                        try bool(try vm.call(f, [.string(String(ch))]))
                    }
                    return .array(parts.map { .string(String($0)) })
                default:
                    if label == nil, separator == nil { separator = args[i] }
                }
            }
            if case .function = separator ?? .void {
                let f = separator!
                let parts = try s.split(maxSplits: maxSplits, omittingEmptySubsequences: omitting) { ch in
                    try bool(try vm.call(f, [.string(String(ch))]))
                }
                return .array(parts.map { .string(String($0)) })
            }
            let sep = try string(separator ?? .string(" "))
            guard let ch = sep.first, sep.count == 1 else {
                return .array(s.components(separatedBy: sep).filter { !omitting || !$0.isEmpty }.map { .string($0) })
            }
            return .array(s.split(separator: ch, maxSplits: maxSplits, omittingEmptySubsequences: omitting).map { .string(String($0)) })
        case "components":
            let arg0 = try arg(args, 0, name)
            if case .string(let sep) = arg0 { return .array(s.components(separatedBy: sep).map { .string($0) }) }
            if case .unresolved(let u) = arg0 {
                let set: CharacterSet = u.name == "newlines" ? .newlines : u.name == "whitespaces" ? .whitespaces : .whitespacesAndNewlines
                return .array(s.components(separatedBy: set).map { .string($0) })
            }
            return nil
        case "replacingOccurrences":
            return .string(s.replacingOccurrences(of: try string(try arg(args, 0, name)), with: try string(try arg(args, 1, name))))
        case "trimmingCharacters":
            let set: CharacterSet
            if case .unresolved(let u) = try arg(args, 0, name) {
                set = u.name == "whitespaces" ? .whitespaces : u.name == "newlines" ? .newlines : u.name == "punctuationCharacters" ? .punctuationCharacters : .whitespacesAndNewlines
            } else {
                set = .whitespacesAndNewlines
            }
            return .string(s.trimmingCharacters(in: set))
        case "reversed":
            return .array(s.reversed().map { .string(String($0)) })
        case "index":
            // String.Index is modelled as an Int offset.
            if labels == [nil, "offsetBy"] { return .int((try int(args[0])) + (try int(args[1]))) }
            if labels == ["after"] { return .int((try int(args[0])) + 1) }
            if labels == ["before"] { return .int((try int(args[0])) - 1) }
            if labels == ["of"] {
                let target = try string(args[0])
                return s.firstIndex(of: Character(target)).map { .some(.int(s.distance(from: s.startIndex, to: $0))) } ?? SwiftValue.none
            }
            return nil
        case "distance":
            return .int((try int(try arg(args, 1, name))) - (try int(try arg(args, 0, name))))
        case "padding":
            let length = try int(try arg(args, 0, name))
            let pad = try string(try arg(args, 1, name))
            return .string(s.padding(toLength: length, withPad: pad, startingAt: 0))
        case "caseInsensitiveCompare", "compare":
            let other = try string(try arg(args, 0, name))
            let result = name == "compare" ? s.compare(other) : s.caseInsensitiveCompare(other)
            let caseName = result == .orderedAscending ? "orderedAscending" : result == .orderedDescending ? "orderedDescending" : "orderedSame"
            return .unresolved(SwiftUnresolved(name: caseName, args: nil, labels: []))
        case "range":
            let target = try string(try arg(args, 0, name))
            guard let range = s.range(of: target) else { return SwiftValue.none }
            let lo = s.distance(from: s.startIndex, to: range.lowerBound)
            return .some(.range(lo, lo + target.count, closed: false))
        default:
            return nil
        }
    }

    // MARK: - Mutating methods

    /// Mutating builtin methods, applied to a value held in place. nil when `name` is not one.
    static func mutateBuiltin(_ receiver: inout SwiftValue, _ name: String, _ args: [SwiftValue], _ rawLabels: [String?], vm: SwiftVM) throws -> SwiftValue? {
        let labels = trailingLabels(name, args, rawLabels)
        switch receiver.kind {
        case .array:
            var items = receiver.takeArray()
            defer { receiver = .array(items) }
            switch name {
            case "append":
                if labels.first == "contentsOf" { items.append(contentsOf: try elements(try arg(args, 0, name), vm: vm)) } else { items.append(try arg(args, 0, name)) }
                return .void
            case "insert":
                let at = try int(try arg(args, 1, name))
                guard at >= 0 && at <= items.count else { throw SwiftRuntimeError(message: "Array index is out of range") }
                if labels.first == "contentsOf" { items.insert(contentsOf: try elements(args[0], vm: vm), at: at) } else { items.insert(args[0], at: at) }
                return .void
            case "remove":
                let at = try int(try arg(args, 0, name))
                guard at >= 0 && at < items.count else { throw SwiftRuntimeError(message: "Index out of range") }
                return items.remove(at: at)
            case "removeFirst":
                if let n = args.first {
                    let count = try int(n)
                    guard count <= items.count else { throw SwiftRuntimeError(message: "Can't remove more items from a collection than it contains") }
                    items.removeFirst(count)
                    return .void
                }
                guard !items.isEmpty else { throw SwiftRuntimeError(message: "Can't remove first element from an empty collection") }
                return items.removeFirst()
            case "removeLast":
                if let n = args.first {
                    let count = try int(n)
                    guard count <= items.count else { throw SwiftRuntimeError(message: "Can't remove more items from a collection than it contains") }
                    items.removeLast(count)
                    return .void
                }
                guard !items.isEmpty else { throw SwiftRuntimeError(message: "Can't remove last element from an empty collection") }
                return items.removeLast()
            case "popLast":
                return items.popLast().map { .some($0) } ?? SwiftValue.none
            case "removeAll":
                if labels.first == "where" {
                    let f = callable(args[0])
                    try items.removeAll { try bool(try vm.call(f, [$0])) }
                } else {
                    items.removeAll()
                }
                return .void
            case "sort":
                if args.isEmpty {
                    try items.sort { try less($0, $1, vm: vm) }
                } else {
                    let f = callable(args[0])
                    try items.sort { try bool(try vm.call(f, [$0, $1])) }
                }
                return .void
            case "reverse":
                items.reverse()
                return .void
            case "shuffle":
                items.shuffle()
                return .void
            case "swapAt":
                let i = try int(try arg(args, 0, name)), j = try int(try arg(args, 1, name))
                guard i >= 0, j >= 0, i < items.count, j < items.count else { throw SwiftRuntimeError(message: "Index out of range") }
                items.swapAt(i, j)
                return .void
            case "replaceSubrange":
                guard case .range(let lo, let hi, let closed) = try arg(args, 0, name) else { return .void }
                items.replaceSubrange(lo..<(closed ? hi + 1 : hi), with: try elements(args[1], vm: vm))
                return .void
            case "removeSubrange":
                guard case .range(let lo, let hi, let closed) = try arg(args, 0, name) else { return .void }
                items.removeSubrange(lo..<(closed ? hi + 1 : hi))
                return .void
            default:
                receiver = .array(items)
                return nil
            }
        case .dictionary:
            var d = receiver.takeDictionary()
            defer { receiver = .dictionary(d) }
            switch name {
            case "removeValue":
                return d.remove(try arg(args, 0, name)).map { .some($0) } ?? SwiftValue.none
            case "updateValue":
                let key = try arg(args, 1, name)
                let old = d.lookup(key)
                d.set(key, args[0])
                return old.map { .some($0) } ?? SwiftValue.none
            case "removeAll":
                d = SwiftDictionary()
                return .void
            case "merge":
                let other = try arg(args, 0, name)
                let f = args.count > 1 ? callable(args[1]) : nil
                let pairs: [(SwiftValue, SwiftValue)]
                if case .dictionary(let o) = other {
                    pairs = Array(zip(o.keys, o.values))
                } else {
                    pairs = try elements(other, vm: vm).compactMap { if case .tuple(let t) = $0 { return (t.values[0], t.values[1]) } else { return nil } }
                }
                for (k, v) in pairs {
                    if let existing = d.lookup(k), let f { d.set(k, try vm.call(f, [existing, v])) } else { d.set(k, v) }
                }
                return .void
            default:
                receiver = .dictionary(d)
                return nil
            }
        case .set:
            var d = receiver.takeDictionary()
            defer { receiver = .set(d) }
            switch name {
            case "insert":
                let v = try arg(args, 0, name)
                let existed = d.lookup(v) != nil
                if !existed { d.set(v, .void) }
                return .tuple(SwiftTuple(values: [.bool(!existed), v], labels: ["inserted", "memberAfterInsert"]))
            case "remove":
                let v = try arg(args, 0, name)
                return d.remove(v) != nil ? .some(v) : SwiftValue.none
            case "removeAll":
                d = SwiftDictionary()
                return .void
            case "formUnion":
                for item in try elements(try arg(args, 0, name), vm: vm) { d.set(item, .void) }
                return .void
            case "subtract":
                for item in try elements(try arg(args, 0, name), vm: vm) { d.remove(item) }
                return .void
            case "formIntersection":
                var o = SwiftDictionary()
                for item in try elements(try arg(args, 0, name), vm: vm) { o.set(item, .void) }
                var out = SwiftDictionary()
                for k in d.keys where o.lookup(k) != nil { out.set(k, .void) }
                d = out
                return .void
            case "update":
                let v = try arg(args, 0, name)
                let old = d.lookup(v) != nil ? SwiftValue.some(v) : .none
                d.set(v, .void)
                return old
            default:
                receiver = .set(d)
                return nil
            }
        case .string:
            var s = receiver.takeString()
            defer { receiver = .string(s) }
            switch name {
            case "append":
                s += try string(try arg(args, 0, name))
                return .void
            case "insert":
                let at = try int(try arg(args, 1, name))
                let index = s.index(s.startIndex, offsetBy: at)
                s.insert(contentsOf: try string(args[0]), at: index)
                return .void
            case "removeLast":
                guard !s.isEmpty else { throw SwiftRuntimeError(message: "Can't remove last element from an empty collection") }
                return .string(String(s.removeLast()))
            case "removeFirst":
                guard !s.isEmpty else { throw SwiftRuntimeError(message: "Can't remove first element from an empty collection") }
                return .string(String(s.removeFirst()))
            case "popLast":
                return s.popLast().map { .some(.string(String($0))) } ?? SwiftValue.none
            case "removeAll":
                if labels.first == "where" {
                    let f = callable(args[0])
                    try s.removeAll { try bool(try vm.call(f, [.string(String($0))])) }
                } else {
                    s = ""
                }
                return .void
            case "remove":
                let at = try int(try arg(args, 0, name))
                return .string(String(s.remove(at: s.index(s.startIndex, offsetBy: at))))
            case "reserveCapacity":
                return .void
            default:
                receiver = .string(s)
                return nil
            }
        default:
            switch (receiver, name) {
            case (.bool(let b), "toggle"):
                receiver = .bool(!b)
                return .void
            case (.int(let i), "negate"):
                receiver = .int(-i)
                return .void
            case (.double(let d), "negate"), (.double(let d), "round"):
                receiver = .double(name == "negate" ? -d : d.rounded())
                return .void
            default:
                return nil
            }
        }
    }

    // MARK: - Subscripts

    static func subscriptBuiltin(_ receiver: SwiftValue, _ keys: [SwiftValue], _ labels: [String?]) throws -> SwiftValue {
        switch receiver.dereferenced {
        case .array(let items):
            guard let key = keys.first else { break }
            switch key {
            case .int(let i):
                guard i >= 0 && i < items.count else { throw SwiftRuntimeError(message: "Index out of range") }
                return items[i]
            case .range(let lo, let hi, let closed):
                let start = lo == Int.min ? 0 : lo
                let end = hi == Int.max ? items.count : (closed ? hi + 1 : hi)
                guard start >= 0, end <= items.count, start <= end else { throw SwiftRuntimeError(message: "Array index is out of range") }
                return .array(Array(items[start..<end]))
            default: break
            }
        case .dictionary(let d):
            guard let key = keys.first else { break }
            if labels.count > 1, labels[1] == "default" { return d.lookup(key) ?? keys[1] }
            return d.lookup(key).map { .some($0) } ?? .none
        case .string(let s):
            guard let key = keys.first else { break }
            switch key {
            case .int(let i):
                guard i >= 0 && i < s.count else { throw SwiftRuntimeError(message: "String index is out of bounds") }
                return .string(String(s[s.index(s.startIndex, offsetBy: i)]))
            case .range(let lo, let hi, let closed):
                let start = lo == Int.min ? 0 : lo
                let end = hi == Int.max ? s.count : (closed ? hi + 1 : hi)
                guard start >= 0, end <= s.count, start <= end else { throw SwiftRuntimeError(message: "String index is out of bounds") }
                let a = s.index(s.startIndex, offsetBy: start)
                let b = s.index(s.startIndex, offsetBy: end)
                return .string(String(s[a..<b]))
            default: break
            }
        case .range(let lo, _, _):
            if case .int(let i) = keys.first { return .int(lo + i) }
        case .tuple(let t):
            if case .int(let i) = keys.first, i < t.values.count { return t.values[i] }
        default:
            break
        }
        throw SwiftRuntimeError(message: "cannot subscript a value of type '\(typeName(receiver))'")
    }

    // MARK: - Builtin types and functions

    static let builtinTypeNames: Set<String> = [
        "Int", "Double", "Float", "CGFloat", "String", "Bool", "Character", "Array", "Dictionary",
        "Set", "Substring", "Int64", "Int32", "UInt", "UInt8", "Float64", "TimeInterval", "Binding",
    ]

    static func constructBuiltin(_ name: String, _ args: inout [SwiftValue], _ labels: [String?], vm: SwiftVM) throws -> SwiftValue {
        let first = args.first?.dereferenced
        switch name {
        case "Int", "Int64", "Int32", "UInt", "UInt8":
            switch (first, labels.first ?? nil) {
            case (.int(let i)?, _): return .int(i)
            case (.double(let d)?, let label):
                if label == "exactly" { return d == d.rounded() && d.isFinite ? .some(.int(Int(d))) : .none }
                guard d.isFinite, d > -9.3e18, d < 9.3e18 else {
                    throw SwiftRuntimeError(message: "Double value cannot be converted to Int because it is either infinite or NaN")
                }
                return .int(Int(d))
            case (.string(let s)?, _):
                let radix = labels.count > 1 && labels[1] == "radix" ? try int(args[1]) : 10
                return Int(s, radix: radix).map { .some(.int($0)) } ?? .none
            case (.bool(let b)?, _): return .int(b ? 1 : 0)
            case (nil, _): return .int(0)
            default: break
            }
        case "Double", "Float", "CGFloat", "Float64", "TimeInterval":
            switch first {
            case .int(let i)?: return .double(Double(i))
            case .double(let d)?:
                if name == "Float" { return .double(Double(Float(d))) }
                return .double(d)
            case .string(let s)?: return Double(s).map { .some(.double($0)) } ?? .none
            case nil: return .double(0)
            default: break
            }
        case "String", "Substring":
            if labels.first == "repeating" {
                return .string(String(repeating: try string(args[0]), count: try int(args[1])))
            }
            if labels.first == "format" {
                return .string(try format(try string(args[0]), Array(args.dropFirst())))
            }
            if labels.count > 1, labels[1] == "radix", case .int(let i)? = first {
                return .string(String(i, radix: try int(args[1]), uppercase: labels.count > 2 && (try? bool(args[2])) == true))
            }
            guard let value = first else { return .string("") }
            switch value {
            case .array(let items) where items.allSatisfy({ if case .string = $0 { return true } else { return false } }):
                return .string(try items.map(string).joined())
            case .string(let s): return .string(s)
            default: return .string(try describe(value, vm: vm, debug: labels.first == "reflecting"))
            }
        case "Bool":
            switch first {
            case .bool(let b)?: return .bool(b)
            case .string(let s)?: return s == "true" ? .some(.bool(true)) : s == "false" ? .some(.bool(false)) : .none
            default: return .bool(false)
            }
        case "Character":
            if case .string(let s)? = first { return .string(s) }
            if case .int(let i)? = first, let scalar = Unicode.Scalar(i) { return .string(String(Character(scalar))) }
        case "Array":
            if labels.first == "repeating" {
                return .array(Array(repeating: try arg(args, 0, name), count: try int(try arg(args, 1, name))))
            }
            guard let value = first else { return .array([]) }
            return .array(try elements(value, vm: vm))
        case "Set":
            var d = SwiftDictionary()
            if let value = first { for item in try elements(value, vm: vm) { d.set(item, .void) } }
            return .set(d)
        case "Dictionary":
            var d = SwiftDictionary()
            if labels.first == "uniqueKeysWithValues", let value = first {
                for item in try elements(value, vm: vm) {
                    guard case .tuple(let t) = item, t.values.count == 2 else { continue }
                    if d.lookup(t.values[0]) != nil { throw SwiftRuntimeError(message: "Duplicate values for key: '\(try describe(t.values[0], vm: vm, debug: false))'") }
                    d.set(t.values[0], t.values[1])
                }
            } else if labels.first == "grouping", let value = first {
                let f = callable(try arg(args, 1, name))
                for item in try elements(value, vm: vm) {
                    let key = try vm.call(f, [item])
                    if case .array(var group)? = d.lookup(key) { group.append(item); d.set(key, .array(group)) } else { d.set(key, .array([item])) }
                }
            } else if let value = first, labels.first == nil {
                for item in try elements(value, vm: vm) {
                    guard case .tuple(let t) = item, t.values.count == 2 else { continue }
                    let f = args.count > 1 ? callable(args[1]) : nil
                    if let existing = d.lookup(t.values[0]), let f { d.set(t.values[0], try vm.call(f, [existing, t.values[1]])) } else { d.set(t.values[0], t.values[1]) }
                }
            }
            return .dictionary(d)
        case "Binding":
            // `Binding(get:set:)` over a closure pair is not modelled; `.constant` is.
            if let value = first { return .cell(SwiftCell(value)) }
        default:
            if SwiftViewLibrary.typeNames.contains(name) { return try SwiftViewLibrary.construct(name, args, labels, vm: vm) }
        }
        throw SwiftRuntimeError(message: "no initializer for \(name) takes (\(labels.map { ($0 ?? "_") + ":" }.joined()))")
    }

    private static func invokeStatic(_ typeName: String, _ name: String, _ args: [SwiftValue], _ labels: [String?], vm: SwiftVM) throws -> SwiftValue {
        switch (typeName, name) {
        case ("Int", "random"):
            guard case .range(let lo, let hi, let closed) = try arg(args, 0, name) else { break }
            return .int(closed ? Int.random(in: lo...hi) : Int.random(in: lo..<hi))
        case ("Double", "random"), ("CGFloat", "random"), ("Float", "random"):
            switch try arg(args, 0, name) {
            case .doubleRange(let lo, let hi, let closed): return .double(closed ? Double.random(in: lo...hi) : Double.random(in: lo..<hi))
            case .range(let lo, let hi, _): return .double(Double.random(in: Double(lo)...Double(hi)))
            default: break
            }
        case ("Bool", "random"):
            return .bool(Bool.random())
        case ("Binding", "constant"):
            return .cell(SwiftCell(try arg(args, 0, name)))
        case (_, "init"):
            var a = args
            return try constructBuiltin(typeName, &a, labels, vm: vm)
        default:
            var a = args
            if let member = try staticBuiltin(typeName, name) { return try vm.callValue(member, &a, labels: labels) }
        }
        throw SwiftRuntimeError(message: "type '\(typeName)' has no member '\(name)'")
    }

    /// `String(format:)` for the specifiers scripts use: %d %i %f %.Nf %s %@ %x %%.
    static func format(_ template: String, _ args: [SwiftValue]) throws -> String {
        var out = ""
        var chars = Array(template)[...]
        var index = 0
        while let c = chars.first {
            chars = chars.dropFirst()
            guard c == "%" else { out.append(c); continue }
            var spec = "%"
            while let n = chars.first, "0123456789.-+ #l".contains(n) { spec.append(n); chars = chars.dropFirst() }
            guard let conv = chars.first else { break }
            chars = chars.dropFirst()
            if conv == "%" { out.append("%"); continue }
            let value = index < args.count ? args[index].dereferenced : .void
            index += 1
            let flags = spec.replacingOccurrences(of: "l", with: "")
            switch conv {
            case "d", "i", "x", "X", "o":
                let n: Int
                switch value {
                case .int(let i): n = i
                case .double(let d): n = Int(d)
                default: n = 0
                }
                out += String(format: flags + "ll" + String(conv), n)
            case "f", "e", "g", "F", "E", "G":
                out += String(format: flags + String(conv), number(value) ?? 0)
            case "s", "@":
                let text: String
                if case .string(let s) = value { text = s } else { text = try describeStatic(value) }
                if let width = Int(flags.dropFirst().replacingOccurrences(of: "-", with: "")), width > text.count {
                    let pad = String(repeating: " ", count: width - text.count)
                    out += flags.contains("-") ? text + pad : pad + text
                } else {
                    out += text
                }
            case "c":
                if case .int(let i) = value, let scalar = Unicode.Scalar(i) { out.unicodeScalars.append(scalar) }
            default:
                out += spec + String(conv)
            }
        }
        return out
    }

    private static func describeStatic(_ v: SwiftValue) throws -> String {
        switch v {
        case .int(let i): return String(i)
        case .double(let d): return String(describing: d)
        case .bool(let b): return String(b)
        case .string(let s): return s
        default: return typeName(v)
        }
    }

    /// Free functions and global names the standard library provides. The compiler resolves an
    /// identifier here only after locals, members and program globals miss.
    static func globalValue(_ name: String) -> SwiftValue? {
        if builtinTypeNames.contains(name) { return .builtinType(name) }
        if let f = SwiftViewLibrary.globalValue(name) { return f }
        // An operator passed as a function: `reduce(0, +)`, `sorted(by: >)`.
        if let first = name.first, "+-*/%<>=!&|^~".contains(first) {
            return .function(SwiftFunction(.native(name) { args, _, vm in
                guard args.count == 2 else { return try prefix(name, args.first ?? .void) }
                return try vm.binary(name, args[0], args[1])
            }))
        }
        guard let body = globalFunctions[name] else { return nil }
        return .function(SwiftFunction(.native(name, body)))
    }

    static func isGlobalName(_ name: String) -> Bool {
        builtinTypeNames.contains(name) || globalFunctions[name] != nil || SwiftViewLibrary.globalValue(name) != nil
    }

    typealias NativeBody = ([SwiftValue], [String?], SwiftVM) throws -> SwiftValue

    // Immutable, and every body is a capture-free function of its arguments.
    nonisolated(unsafe) static let globalFunctions: [String: NativeBody] = [
        "print": { args, labels, vm in
            var separator = " "
            var terminator = "\n"
            var items: [SwiftValue] = []
            for (value, label) in zip(args, labels) {
                switch label {
                case "separator": separator = try string(value)
                case "terminator": terminator = try string(value)
                default: items.append(value)
                }
            }
            vm.output(try items.map { try describe($0, vm: vm, debug: false) }.joined(separator: separator) + terminator)
            return .void
        },
        "debugPrint": { args, labels, vm in
            let items = zip(args, labels).filter { $0.1 == nil }.map(\.0)
            vm.output(try items.map { try describe($0, vm: vm, debug: true) }.joined(separator: " ") + "\n")
            return .void
        },
        "min": { args, _, vm in
            let items = args.count == 1 ? try elements(args[0], vm: vm) : args
            guard var best = items.first else { throw SwiftRuntimeError(message: "min of nothing") }
            for item in items.dropFirst() where try less(item, best, vm: vm) { best = item }
            return best
        },
        "max": { args, _, vm in
            let items = args.count == 1 ? try elements(args[0], vm: vm) : args
            guard var best = items.first else { throw SwiftRuntimeError(message: "max of nothing") }
            for item in items.dropFirst() where try less(best, item, vm: vm) { best = item }
            return best
        },
        "abs": { args, _, _ in
            switch args.first?.dereferenced {
            case .int(let i)?:
                guard i != Int.min else { throw SwiftRuntimeError(message: "arithmetic overflow") }
                return .int(abs(i))
            case .double(let d)?: return .double(abs(d))
            default: throw SwiftRuntimeError(message: "abs needs a number")
            }
        },
        "sqrt": { args, _, _ in .double((number(args.first ?? .void) ?? 0).squareRoot()) },
        "pow": { args, _, _ in .double(Foundation.pow(number(args[0]) ?? 0, number(args[1]) ?? 0)) },
        "floor": { args, _, _ in .double(Foundation.floor(number(args[0]) ?? 0)) },
        "ceil": { args, _, _ in .double(Foundation.ceil(number(args[0]) ?? 0)) },
        "round": { args, _, _ in .double(Foundation.round(number(args[0]) ?? 0)) },
        "sin": { args, _, _ in .double(Foundation.sin(number(args[0]) ?? 0)) },
        "cos": { args, _, _ in .double(Foundation.cos(number(args[0]) ?? 0)) },
        "tan": { args, _, _ in .double(Foundation.tan(number(args[0]) ?? 0)) },
        "asin": { args, _, _ in .double(Foundation.asin(number(args[0]) ?? 0)) },
        "acos": { args, _, _ in .double(Foundation.acos(number(args[0]) ?? 0)) },
        "atan": { args, _, _ in .double(Foundation.atan(number(args[0]) ?? 0)) },
        "atan2": { args, _, _ in .double(Foundation.atan2(number(args[0]) ?? 0, number(args[1]) ?? 0)) },
        "log": { args, _, _ in .double(Foundation.log(number(args[0]) ?? 0)) },
        "log2": { args, _, _ in .double(Foundation.log2(number(args[0]) ?? 0)) },
        "log10": { args, _, _ in .double(Foundation.log10(number(args[0]) ?? 0)) },
        "exp": { args, _, _ in .double(Foundation.exp(number(args[0]) ?? 0)) },
        "hypot": { args, _, _ in .double(Foundation.hypot(number(args[0]) ?? 0, number(args[1]) ?? 0)) },
        "stride": { args, labels, _ in
            guard args.count == 3 else { throw SwiftRuntimeError(message: "stride needs from:to:by: or from:through:by:") }
            let through = labels[1] == "through"
            if case .int(let from) = args[0], case .int(let to) = args[1], case .int(let by) = args[2] {
                guard by != 0 else { throw SwiftRuntimeError(message: "Stride size must not be zero") }
                let values: [SwiftValue] = through ? Swift.stride(from: from, through: to, by: by).map { .int($0) } : Swift.stride(from: from, to: to, by: by).map { .int($0) }
                return .array(values)
            }
            let from = number(args[0]) ?? 0, to = number(args[1]) ?? 0, by = number(args[2]) ?? 1
            let values: [SwiftValue] = through ? Swift.stride(from: from, through: to, by: by).map { .double($0) } : Swift.stride(from: from, to: to, by: by).map { .double($0) }
            return .array(values)
        },
        "zip": { args, _, vm in
            let a = try elements(args[0], vm: vm), b = try elements(args[1], vm: vm)
            return .array(zip(a, b).map { .tuple(SwiftTuple(values: [$0, $1], labels: [nil, nil])) })
        },
        "fatalError": { args, _, vm in
            let message = args.isEmpty ? "" : try describe(args[0], vm: vm, debug: false)
            throw SwiftRuntimeError(message: message.isEmpty ? "Fatal error" : message)
        },
        "precondition": { args, _, vm in
            if case .bool(false) = args.first?.dereferenced ?? .void {
                let message = args.count > 1 ? try describe(args[1], vm: vm, debug: false) : ""
                throw SwiftRuntimeError(message: "Precondition failed" + (message.isEmpty ? "" : ": \(message)"))
            }
            return .void
        },
        "assert": { args, _, vm in
            if case .bool(false) = args.first?.dereferenced ?? .void {
                let message = args.count > 1 ? try describe(args[1], vm: vm, debug: false) : ""
                throw SwiftRuntimeError(message: "Assertion failed" + (message.isEmpty ? "" : ": \(message)"))
            }
            return .void
        },
        "preconditionFailure": { args, _, vm in
            throw SwiftRuntimeError(message: args.isEmpty ? "Precondition failed" : try describe(args[0], vm: vm, debug: false))
        },
        "assertionFailure": { args, _, vm in
            throw SwiftRuntimeError(message: args.isEmpty ? "Assertion failed" : try describe(args[0], vm: vm, debug: false))
        },
        "readLine": { _, _, _ in .none },
        "type": { args, _, _ in
            switch args.first?.dereferenced {
            case .structValue(let s)?: return .type(s.type)
            case .object(let o)?: return .type(o.type)
            case .enumValue(let e)?: return .type(e.type)
            case let other?: return .builtinType(builtinTypeName(other))
            case nil: return .void
            }
        },
        "swap": { args, _, _ in
            // Inout: the VM writes the returned argument array back to the caller's places.
            throw SwiftRuntimeError(message: "internal: swap is handled by the VM")
        },
        "withAnimation": { args, _, vm in
            guard let body = args.last else { return .void }
            return try vm.call(body, [])
        },
        "numericCast": { args, _, _ in args.first ?? .void },
        "repeatElement": { args, _, _ in
            .array(Array(repeating: args[0], count: max(0, (try? int(args[1])) ?? 0)))
        },
        "sequence": { args, labels, vm in
            // `sequence(first:next:)`, drained eagerly with a bound so infinite ones stop.
            guard labels.first == "first" else { throw SwiftRuntimeError(message: "sequence(state:next:) is not supported") }
            var out: [SwiftValue] = []
            var current: SwiftValue? = args[0].unwrapped
            while let c = current, out.count < 1_000_000 {
                out.append(c)
                current = try vm.call(args[1], [c]).unwrapped
            }
            return .array(out)
        },
    ]
}

extension SwiftVM {
    /// A user-defined operator on the operands' types, without the builtin fallback.
    func binaryUser(_ op: String, _ l: SwiftValue, _ r: SwiftValue) throws -> SwiftValue {
        if let t = typeOf(l), let proto = pick(findStaticMethods(t, op), [nil, nil], 2) {
            return try invoke(proto: proto, arguments: [l, r], selfValue: .type(t), upvalues: [], mode: .normal)
        }
        return .void
    }

    /// `reduce(into:)`: call `f(&acc, item)` and return the accumulator's final value.
    func callAccumulating(_ f: SwiftValue, _ acc: SwiftValue, _ item: SwiftValue) throws -> SwiftValue {
        guard case .function(let fn) = f, case .closure(let proto, let upvalues) = fn.kind else {
            var args = [acc, item]
            _ = try callValue(f, &args, labels: [nil, nil])
            return args[0]
        }
        recordParamsFrame = frames.count
        defer { recordParamsFrame = nil }
        _ = try invoke(proto: proto, arguments: try bind(proto, [acc, item], [nil, nil]), selfValue: nil, upvalues: upvalues, mode: .normal)
        return recordedParams.first ?? acc
    }
}
