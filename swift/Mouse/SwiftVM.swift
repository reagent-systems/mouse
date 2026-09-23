import Foundation

// The Swift VM: values, runtime type metadata, and the bytecode interpreter loop. The compiler
// (`SwiftBytecode.swift`) turns the syntax tree into `SwiftProto`s; this file runs them. The
// standard-library surface (String, Array, Dictionary, math, print) lives in
// `SwiftRuntimeLibrary.swift`.
//
// Value semantics are Swift's own: arrays, dictionaries, structs and enums are Swift value types
// here too, so copy-on-write comes for free — provided mutation happens IN PLACE. Every write
// (`a.b[i].c = v`, `list.append(x)`, `count += 1`) is a single path operation that takes the root
// value out of its slot, walks the path with `inout`, and puts it back, so the buffers it touches
// are uniquely referenced and never copied. A load-modify-store chain would copy the whole array
// on every append and turn a loop quadratic.

// MARK: - Values

indirect enum SwiftValue {
    case void
    case none
    case some(SwiftValue)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case array([SwiftValue])
    case dictionary(SwiftDictionary)
    case set(SwiftDictionary)
    case tuple(SwiftTuple)
    case structValue(SwiftStructValue)
    case object(SwiftObject)
    case enumValue(SwiftEnumValue)
    case function(SwiftFunction)
    case type(SwiftTypeInfo)
    case builtinType(String)
    case range(Int, Int, closed: Bool)
    case doubleRange(Double, Double, closed: Bool)
    case iterator(SwiftIterator)
    case unresolved(SwiftUnresolved)
    case keyPath([String])
    case cell(SwiftCell)
    case view(SwiftViewNode)
    /// A captured local's slot: the frame and every closure capturing it share the box.
    case boxRef(SwiftBox)

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    /// Optional payload, looking through one level of wrapping.
    var unwrapped: SwiftValue? {
        switch self {
        case .none: return nil
        case .some(let inner): return inner
        default: return self
        }
    }

    /// A payload-free discriminator. In-place mutation switches on this, never on the value
    /// itself: `switch value { case .array(var items): … }` keeps a temporary reference to the
    /// payload alive for the whole case body, so the buffer has two owners and every mutation
    /// copies it — an append loop goes quadratic.
    enum Kind { case none, some, array, dictionary, set, string, structValue, tuple, cell, object, type, other }

    var kind: Kind {
        switch self {
        case .none: .none
        case .some: .some
        case .array: .array
        case .dictionary: .dictionary
        case .set: .set
        case .string: .string
        case .structValue: .structValue
        case .tuple: .tuple
        case .cell: .cell
        case .object: .object
        case .type: .type
        default: .other
        }
    }

    // Take the payload out, leaving `.void`, so the caller holds the only reference.
    mutating func takeSome() -> SwiftValue {
        guard case .some(let inner) = self else { return self }
        self = .void
        return inner
    }

    mutating func takeArray() -> [SwiftValue] {
        guard case .array(let items) = self else { return [] }
        self = .void
        return items
    }

    mutating func takeDictionary() -> SwiftDictionary {
        let result: SwiftDictionary
        switch self {
        case .dictionary(let d), .set(let d): result = d
        default: return SwiftDictionary()
        }
        self = .void
        return result
    }

    mutating func takeString() -> String {
        guard case .string(let s) = self else { return "" }
        self = .void
        return s
    }

    mutating func takeStruct() -> SwiftStructValue? {
        guard case .structValue(let s) = self else { return nil }
        self = .void
        return s
    }

    mutating func takeTuple() -> SwiftTuple? {
        guard case .tuple(let t) = self else { return nil }
        self = .void
        return t
    }

    /// The whole value, moved out.
    mutating func take() -> SwiftValue {
        let v = self
        self = .void
        return v
    }

    /// The value with any property-wrapper cell read through.
    var dereferenced: SwiftValue {
        if case .cell(let c) = self { return c.value }
        return self
    }
}

struct SwiftTuple {
    var values: [SwiftValue]
    var labels: [String?]
}

struct SwiftStructValue {
    let type: SwiftTypeInfo
    var fields: [SwiftValue]
}

struct SwiftEnumValue {
    let type: SwiftTypeInfo
    let name: String
    var payload: [SwiftValue]
}

struct SwiftUnresolved {
    let name: String
    var args: [SwiftValue]?
    var labels: [String?]
}

/// Swift's Dictionary and Set, keyed by a canonical hash key. Insertion-ordered so output is
/// deterministic; real Swift's order is per-process random, so programs never depend on it.
struct SwiftDictionary {
    var keys: [SwiftValue] = []
    var values: [SwiftValue] = []
    var index: [String: Int] = [:]

    var count: Int { keys.count }

    func lookup(_ key: SwiftValue) -> SwiftValue? {
        guard let i = index[SwiftRuntime.hashKey(key)] else { return nil }
        return values[i]
    }

    mutating func set(_ key: SwiftValue, _ value: SwiftValue) {
        let k = SwiftRuntime.hashKey(key)
        if let i = index[k] {
            values[i] = value
        } else {
            index[k] = keys.count
            keys.append(key)
            values.append(value)
        }
    }

    @discardableResult
    mutating func remove(_ key: SwiftValue) -> SwiftValue? {
        let k = SwiftRuntime.hashKey(key)
        guard let i = index[k] else { return nil }
        let old = values[i]
        keys.remove(at: i)
        values.remove(at: i)
        index[k] = nil
        for j in i..<keys.count { index[SwiftRuntime.hashKey(keys[j])] = j }
        return old
    }
}

final class SwiftObject {
    let type: SwiftTypeInfo
    var fields: [SwiftValue]
    init(type: SwiftTypeInfo, fields: [SwiftValue]) {
        self.type = type
        self.fields = fields
    }
}

/// A captured variable. Locals that a closure captures live in a box so both see one variable.
final class SwiftBox {
    var value: SwiftValue
    init(_ value: SwiftValue) { self.value = value }
}

/// Storage behind a property wrapper (`@State`, `@Binding`, `@Published`): a struct copy of a
/// view shares its cells with the original, which is what makes a button's action — holding a
/// copy of `self` — able to change what the next render reads.
final class SwiftCell {
    var value: SwiftValue
    var onChange: (() -> Void)?
    init(_ value: SwiftValue) { self.value = value }
}

final class SwiftIterator {
    enum Source {
        case range(Int, Int)
        case values([SwiftValue])
    }

    var source: Source
    var position: Int

    init(_ source: Source) {
        self.source = source
        switch source {
        case .range(let lo, _): position = lo
        case .values: position = 0
        }
    }

    func next() -> SwiftValue? {
        switch source {
        case .range(_, let hi):
            guard position < hi else { return nil }
            defer { position += 1 }
            return .int(position)
        case .values(let values):
            guard position < values.count else { return nil }
            defer { position += 1 }
            return values[position]
        }
    }
}

final class SwiftFunction {
    enum Kind {
        case closure(SwiftProto, [SwiftBox])
        case method(SwiftProto, SwiftValue)
        case native(String, ([SwiftValue], [String?], SwiftVM) throws -> SwiftValue)
        case nativeMethod(SwiftValue, String)
        case enumCase(SwiftTypeInfo, String)
    }

    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

// MARK: - Runtime type metadata

final class SwiftTypeInfo {
    enum Kind { case structType, classType, enumType, protocolType, builtinExtension }

    struct StoredProperty {
        let name: String
        var type: SwiftTypeRef?
        var initializer: SwiftProto?
        var isLet: Bool
        var wrapper: String?
        var willSet: SwiftProto?
        var didSet: SwiftProto?
    }

    struct EnumCase {
        let name: String
        let labels: [String?]?
        var types: [SwiftTypeRef] = []
        var rawValue: SwiftValue?
    }

    let name: String
    let kind: Kind
    var stored: [StoredProperty] = []
    var storedIndex: [String: Int] = [:]
    var computed: [String: (getter: SwiftProto?, setter: SwiftProto?)] = [:]
    var methods: [String: [SwiftProto]] = [:]
    var staticMethods: [String: [SwiftProto]] = [:]
    var staticComputed: [String: SwiftProto] = [:]
    var staticInitializers: [String: SwiftProto] = [:]
    var staticValues: [String: SwiftValue] = [:]
    var inits: [SwiftProto] = []
    var subscriptGetters: [SwiftProto] = []
    var subscriptSetters: [SwiftProto] = []
    var superclass: SwiftTypeInfo?
    var conformances: [String] = []
    var cases: [EnumCase] = []
    var caseIndex: [String: Int] = [:]
    var rawType: String?
    var nested: [String: SwiftTypeInfo] = [:]
    /// Memberwise init is synthesised for structs that declare no init of their own.
    var hasMemberwiseInit = false

    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    var shortName: String { name.split(separator: ".").last.map(String.init) ?? name }

    func isSubclass(of other: SwiftTypeInfo) -> Bool {
        var t: SwiftTypeInfo? = self
        while let current = t {
            if current === other { return true }
            t = current.superclass
        }
        return false
    }
}

// MARK: - Bytecode

enum SwiftRoot {
    case local(Int)
    case upvalue(Int)
    case global(Int)
    /// A value from the constant pool — a type, whose static properties are the place.
    case constant(Int)
    /// The type of the running method's `self` (`Self.count += 1`).
    case selfType
}

enum SwiftPathStep {
    case member(String)
    case index(argc: Int, labels: [String?])
    case unwrap
    /// `a?.b = x`: a nil `a` makes the whole assignment a no-op.
    case chain
}

enum SwiftOp {
    case constant(Int)
    case pop
    case dup
    case loadLocal(Int)
    /// Declare: a fresh value over the slot (a previous iteration's captured box is left behind).
    case storeLocal(Int)
    /// Assign: through the slot's box when a closure has captured it.
    case assignLocal(Int)
    case loadUpvalue(Int)
    case storeUpvalue(Int)
    case loadGlobal(Int)
    case storeGlobal(Int)
    case getMember(String)
    case getIndex(argc: Int, labels: [String?])
    /// Stack: [keys…, value]. Stores `value` at root.path.
    case storePath(SwiftRoot, [SwiftPathStep], coerce: SwiftTypeRef?)
    /// Stack: [keys…, rhs]. root.path = root.path <op> rhs.
    case modifyPath(SwiftRoot, [SwiftPathStep], String)
    /// Stack: [keys…, args…]. Calls a mutating method on root.path in place; pushes its result.
    case mutatePath(SwiftRoot, [SwiftPathStep], String, argc: Int, labels: [String?])
    case call(argc: Int, labels: [String?], inouts: [Int])
    case invoke(String, argc: Int, labels: [String?], inouts: [Int])
    case superInvoke(String, argc: Int, labels: [String?])
    case makeUnresolved(String, argc: Int, labels: [String?])
    case binary(String)
    case prefix(String)
    case jump(Int)
    case jumpIfFalse(Int)
    case jumpIfTrue(Int)
    /// Optional chaining: nil jumps (keeping nil); a value is unwrapped in place.
    case chainJump(Int)
    /// `??`: a value is unwrapped and jumps; nil is popped and falls through to the default.
    case coalesce(Int)
    /// `if let`: nil is popped and jumps; a value is unwrapped in place.
    case unwrapOrJump(Int)
    case wrapOptional
    case forceUnwrap
    case makeArray(Int)
    case makeDictionary(Int)
    case makeTuple([String?])
    case makeClosure(SwiftProto)
    case interpolate(Int)
    case coerce(SwiftTypeRef)
    case returnValue
    case makeIterator
    case iterate(slot: Int, exit: Int)
    case patternMatch
    case enumCaseIs(String)
    case enumPayload(Int)
    case tupleElement(Int)
    case isSome
    case typeCheck(SwiftTypeRef)
    case cast(SwiftTypeRef, String)
    case throwError
    case pushHandler(Int)
    case popHandler
    case popInout
    case collect
    case fallOff
    case fail(String)
    case loadSelfType
}

final class SwiftProto {
    struct Param {
        var label: String?
        var name: String
        var slot: Int
        var type: SwiftTypeRef?
        var defaultValue: SwiftProto?
        var isInout: Bool
        var isVariadic: Bool
    }

    enum Capture {
        case local(Int)
        case upvalue(Int)
    }

    let name: String
    var code: [SwiftOp] = []
    var lines: [Int] = []
    var localCount = 0
    var params: [Param] = []
    var captures: [Capture] = []
    /// Methods keep `self` in slot 0.
    var hasSelf = false
    var isMutating = false
    var isInit = false
    var isFailable = false
    var isClosure = false
    var isStatic = false
    var throwsErrors = false
    var returnType: SwiftTypeRef?
    weak var owner: SwiftTypeInfo?

    init(name: String) { self.name = name }

    var labels: [String?] { params.map(\.label) }
}

// MARK: - Errors

struct SwiftRuntimeError: Error, CustomStringConvertible {
    let message: String
    var line: Int?
    var description: String {
        if let line { return "Fatal error: \(message) (line \(line))" }
        return "Fatal error: \(message)"
    }
}

/// A Swift `throw`, carrying the thrown value up through the host stack. `Error` demands
/// Sendable; the value never leaves the VM's thread (a throw unwinds to a handler in the same
/// run, or ends the run where the host reports it as text), so the promise is kept by confinement.
struct SwiftThrown: Error, @unchecked Sendable {
    let value: SwiftValue
}

/// Raised when the host stops a running program (the terminal's ^C).
struct SwiftInterrupted: Error {}

// MARK: - Program

/// A compiled program: the entry proto, globals, and every type by qualified name.
final class SwiftProgram {
    var main = SwiftProto(name: "main")
    var globals: [SwiftValue] = []
    var globalNames: [String] = []
    var globalIndex: [String: Int] = [:]
    var typeAliases: [String: SwiftTypeRef] = [:]
    /// The constant pool `SwiftOp.constant` indexes.
    var constants: [SwiftValue] = []
    var types: [String: SwiftTypeInfo] = [:]
    var protocols: [String: SwiftTypeInfo] = [:]
    var builtinExtensions: [String: SwiftTypeInfo] = [:]
    /// The `@main` type, when the program declares one.
    var entryType: SwiftTypeInfo?

    func global(named name: String) -> Int {
        if let i = globalIndex[name] { return i }
        globalIndex[name] = globals.count
        globalNames.append(name)
        globals.append(.none)
        return globals.count - 1
    }
}

// MARK: - The machine

final class SwiftVM {
    struct Handler {
        let pc: Int
        let stackHeight: Int
    }

    enum ReturnMode {
        case normal
        /// A mutating method: the callee's final `self` goes back to the caller's path.
        case mutating
        /// An initializer: the callee's `self` is the result.
        case initializer
    }

    struct Frame {
        let proto: SwiftProto
        var pc: Int
        let base: Int
        let upvalues: [SwiftBox]
        var handlers: [Handler] = []
        var builder: [SwiftValue]? = nil
        let mode: ReturnMode
        /// Set when the frame was entered from a `call`/`invoke` op with inout arguments: its
        /// final parameter values go to `inoutResults` as it returns.
        var inoutPositions: [Int] = []
    }

    let program: SwiftProgram
    var stack: [SwiftValue] = []
    var frames: [Frame] = []
    /// Final values of inout arguments, popped by the caller after a call returns.
    var inoutResults: [SwiftValue] = []
    /// Receives everything `print` writes.
    var output: (String) -> Void
    /// Polled every few thousand instructions; returning true stops the program.
    var shouldStop: () -> Bool = { false }
    /// Called whenever a property-wrapper cell changes (a SwiftUI host re-renders on it).
    var stateChanged: () -> Void = {}
    private var budget = 0

    init(program: SwiftProgram, output: @escaping (String) -> Void) {
        self.program = program
        self.output = output
    }

    // MARK: Entry points

    /// Run the program's top-level code, then its `@main` entry if it declares one.
    func runMain() throws {
        _ = try invoke(proto: program.main, arguments: [], selfValue: nil, upvalues: [], mode: .normal)
        if let entry = program.entryType, let mainProto = entry.staticMethods["main"]?.first {
            _ = try invoke(proto: mainProto, arguments: [], selfValue: .type(entry), upvalues: [], mode: .normal)
        }
    }

    /// Call any callable value from native code (map's transform, a button's action).
    func call(_ callee: SwiftValue, _ args: [SwiftValue], labels: [String?]? = nil) throws -> SwiftValue {
        var args = args
        return try callValue(callee, &args, labels: labels ?? Array(repeating: nil, count: args.count))
    }

    // MARK: Calls

    func callValue(_ callee: SwiftValue, _ args: inout [SwiftValue], labels: [String?]) throws -> SwiftValue {
        switch callee {
        case .function(let fn):
            switch fn.kind {
            case .closure(let proto, let upvalues):
                let bound = try bind(proto, args, labels)
                let result = try invoke(proto: proto, arguments: bound, selfValue: nil, upvalues: upvalues, mode: .normal)
                collectInout(proto, into: &args)
                return result
            case .method(let proto, let receiver):
                let bound = try bind(proto, args, labels)
                let result = try invoke(proto: proto, arguments: bound, selfValue: receiver, upvalues: [], mode: .normal)
                collectInout(proto, into: &args)
                return result
            case .native(let name, let body):
                if name == "swap", args.count == 2 {
                    args.swapAt(0, 1)
                    return .void
                }
                return try body(args, labels, self)
            case .nativeMethod(let receiver, let name):
                return try SwiftRuntime.invokeBuiltin(receiver, name, args, labels, vm: self)
            case .enumCase(let type, let name):
                return .enumValue(SwiftEnumValue(type: type, name: name, payload: try coercePayload(type, name, args)))
            }
        case .type(let type):
            return try construct(type, args, labels)
        case .builtinType(let name):
            return try SwiftRuntime.constructBuiltin(name, &args, labels, vm: self)
        case .array(let elements) where elements.count == 1:
            // `[Int]()`, `[Bool](repeating: false, count: n)` — an array type called as an init.
            switch elements[0] {
            case .builtinType, .type:
                if args.isEmpty { return .array([]) }
                return try SwiftRuntime.constructBuiltin("Array", &args, labels, vm: self)
            default:
                break
            }
        case .dictionary(let d) where d.count == 1:
            if args.isEmpty { return .dictionary(SwiftDictionary()) }
            return try SwiftRuntime.constructBuiltin("Dictionary", &args, labels, vm: self)
        case .unresolved(var u):
            u.args = args
            u.labels = labels
            return .unresolved(u)
        default:
            break
        }
        throw SwiftRuntimeError(message: "cannot call value of type \(SwiftRuntime.typeName(callee))")
    }

    /// Match call arguments to parameters by label, filling defaults and variadics.
    func bind(_ proto: SwiftProto, _ args: [SwiftValue], _ labels: [String?]) throws -> [SwiftValue] {
        if proto.isClosure {
            var values = args
            // A closure taking N parameters called with one N-tuple destructures it.
            if proto.params.count > 1, values.count == 1, case .tuple(let t) = values[0], t.values.count == proto.params.count {
                values = t.values
            }
            if values.count > proto.params.count { values = Array(values.prefix(proto.params.count)) }
            while values.count < proto.params.count { values.append(.void) }
            return values
        }
        var result: [SwiftValue] = []
        result.reserveCapacity(proto.params.count)
        var ai = 0
        for param in proto.params {
            if param.isVariadic {
                var items: [SwiftValue] = []
                if ai < args.count, labels[ai] == param.label {
                    items.append(args[ai]); ai += 1
                    while ai < args.count, labels[ai] == nil { items.append(args[ai]); ai += 1 }
                }
                result.append(.array(items.map { coerce($0, to: param.type) }))
                continue
            }
            if ai < args.count, labels[ai] == param.label {
                result.append(coerce(args[ai], to: param.type))
                ai += 1
            } else if let def = param.defaultValue {
                result.append(coerce(try invoke(proto: def, arguments: [], selfValue: nil, upvalues: [], mode: .normal), to: param.type))
            } else {
                throw SwiftRuntimeError(message: "missing argument for parameter '\(param.label ?? param.name)' in call to \(proto.name)")
            }
        }
        if ai < args.count {
            throw SwiftRuntimeError(message: "extra argument\(labels[ai].map { " '\($0)'" } ?? "") in call to \(proto.name)")
        }
        return result
    }

    /// Whether `labels` can call `proto` — the overload test.
    func accepts(_ proto: SwiftProto, _ labels: [String?]) -> Bool {
        if proto.isClosure { return true }
        var ai = 0
        for param in proto.params {
            if ai < labels.count, labels[ai] == param.label {
                ai += 1
                if param.isVariadic { while ai < labels.count, labels[ai] == nil { ai += 1 } }
            } else if param.defaultValue == nil && !param.isVariadic {
                return false
            }
        }
        return ai == labels.count
    }

    func pick(_ candidates: [SwiftProto]?, _ labels: [String?], _ argc: Int) -> SwiftProto? {
        guard let candidates else { return nil }
        if candidates.count == 1 { return accepts(candidates[0], labels) ? candidates[0] : nil }
        return candidates.first { accepts($0, labels) && $0.params.count == argc } ?? candidates.first { accepts($0, labels) }
    }

    private func collectInout(_ proto: SwiftProto, into args: inout [SwiftValue]) {
        guard !lastInoutFinals.isEmpty else { return }
        var k = 0
        for (i, param) in proto.params.enumerated() where param.isInout && i < args.count {
            args[i] = lastInoutFinals[k]
            k += 1
        }
        lastInoutFinals = []
    }

    /// Inout parameter values at the moment the most recent frame returned.
    var lastInoutFinals: [SwiftValue] = []

    /// Run `proto` to completion on this thread and return its result.
    @discardableResult
    func invoke(proto: SwiftProto, arguments: [SwiftValue], selfValue: SwiftValue?, upvalues: [SwiftBox], mode: ReturnMode) throws -> SwiftValue {
        let depth = frames.count
        try pushFrame(proto: proto, arguments: arguments, selfValue: selfValue, upvalues: upvalues, mode: mode)
        return try run(depth: depth)
    }

    /// Frames deeper than this are a runaway recursion: Swift itself would overflow its stack.
    static let maxDepth = 100_000

    private func pushFrame(proto: SwiftProto, arguments: [SwiftValue], selfValue: SwiftValue?, upvalues: [SwiftBox],
                           mode: ReturnMode, inoutPositions: [Int] = []) throws {
        guard frames.count < SwiftVM.maxDepth else {
            throw SwiftRuntimeError(message: "stack overflow (\(SwiftVM.maxDepth) nested calls)")
        }
        let base = stack.count
        let first = stack.count
        stack.append(contentsOf: repeatElement(.none, count: proto.localCount))
        if proto.hasSelf {
            let s = selfValue ?? .void
            stack[first] = s
        }
        for (i, param) in proto.params.enumerated() where i < arguments.count {
            stack[first + param.slot] = arguments[i]
        }
        frames.append(Frame(proto: proto, pc: 0, base: base, upvalues: upvalues, mode: mode, inoutPositions: inoutPositions))
    }

    // MARK: The loop

    private func run(depth: Int) throws -> SwiftValue {
        while true {
            do {
                return try loop(depth: depth)
            } catch let thrown as SwiftThrown {
                // Find the innermost handler above `depth`.
                var found = false
                while frames.count > depth {
                    if let handler = frames[frames.count - 1].handlers.popLast() {
                        stack.removeSubrange(handler.stackHeight...)
                        stack.append(thrown.value)
                        frames[frames.count - 1].pc = handler.pc
                        found = true
                        break
                    }
                    let frame = frames.removeLast()
                    stack.removeSubrange(frame.base...)
                }
                if !found { throw thrown }
            } catch {
                while frames.count > depth {
                    let frame = frames.removeLast()
                    stack.removeSubrange(frame.base...)
                }
                throw error
            }
        }
    }

    private var currentLine: Int? {
        guard let frame = frames.last else { return nil }
        let pc = max(0, frame.pc - 1)
        return pc < frame.proto.lines.count ? frame.proto.lines[pc] : nil
    }

    @inline(__always) private func pop() -> SwiftValue { stack.removeLast() }

    private func popN(_ n: Int) -> [SwiftValue] {
        guard n > 0 else { return [] }
        let values = Array(stack[(stack.count - n)...])
        stack.removeLast(n)
        return values
    }

    private func loop(depth: Int) throws -> SwiftValue {
        var frameIndex = frames.count - 1
        var code = frames[frameIndex].proto.code
        var pc = frames[frameIndex].pc
        var base = frames[frameIndex].base

        func sync() { frames[frameIndex].pc = pc }
        func reload() {
            frameIndex = frames.count - 1
            code = frames[frameIndex].proto.code
            pc = frames[frameIndex].pc
            base = frames[frameIndex].base
        }

        do {
            while true {
                budget += 1
                if budget >= 4096 {
                    budget = 0
                    if shouldStop() { throw SwiftInterrupted() }
                }
                let op = code[pc]
                pc += 1
                switch op {
                case .constant(let i):
                    stack.append(program.constants[i])
                case .pop:
                    stack.removeLast()
                case .dup:
                    stack.append(stack[stack.count - 1])
                case .loadLocal(let slot):
                    if case .boxRef(let box) = stack[base + slot] {
                        stack.append(box.value)
                    } else {
                        stack.append(stack[base + slot])
                    }
                case .storeLocal(let slot):
                    stack[base + slot] = pop()
                case .assignLocal(let slot):
                    let v = pop()
                    if case .boxRef(let box) = stack[base + slot] {
                        box.value = v
                    } else {
                        stack[base + slot] = v
                    }
                case .loadUpvalue(let i):
                    stack.append(frames[frameIndex].upvalues[i].value)
                case .storeUpvalue(let i):
                    frames[frameIndex].upvalues[i].value = pop()
                case .loadGlobal(let i):
                    stack.append(program.globals[i])
                case .storeGlobal(let i):
                    program.globals[i] = pop()
                case .loadSelfType:
                    let proto = frames[frameIndex].proto
                    if let owner = proto.owner { stack.append(.type(owner)) } else { stack.append(.none) }

                case .getMember(let name):
                    let receiver = pop()
                    sync()
                    stack.append(try getMember(receiver, name))
                    reload()
                case .getIndex(let argc, let labels):
                    let keys = popN(argc)
                    let receiver = pop()
                    sync()
                    stack.append(try getIndex(receiver, keys, labels))
                    reload()

                case .storePath(let root, let steps, let coerceType):
                    var value = pop()
                    if let coerceType { value = coerce(value, to: coerceType) }
                    let keys = popN(keyCount(steps))
                    sync()
                    // Only an assignment converts to the property's declared type; mutating a
                    // property in place must not re-walk (and re-copy) its whole value.
                    let savedCoercing = coercingStore
                    coercingStore = true
                    defer { coercingStore = savedCoercing }
                    try withRoot(root, frameIndex: frameIndex, base: base) { target in
                        try self.walk(&target, steps[...], keys[...]) { slot in
                            if case .cell(let c) = slot {
                                c.value = value
                                self.stateChanged()
                            } else {
                                slot = value
                            }
                        }
                    }
                    reload()
                case .modifyPath(let root, let steps, let opName):
                    let rhs = pop()
                    let savedCoercing = coercingStore
                    coercingStore = false
                    defer { coercingStore = savedCoercing }
                    let keys = popN(keyCount(steps))
                    sync()
                    try withRoot(root, frameIndex: frameIndex, base: base) { target in
                        try self.walk(&target, steps[...], keys[...]) { slot in
                            if case .cell(let c) = slot {
                                c.value = try self.binary(opName, c.value, rhs)
                                self.stateChanged()
                            } else if opName == "+", slot.kind == .array, case .array(let more) = rhs {
                                // `list += more` appends in place, as Array's own `+=` does.
                                var items = slot.takeArray()
                                items.append(contentsOf: more)
                                slot = .array(items)
                            } else if opName == "+", slot.kind == .string, case .string(let more) = rhs {
                                var text = slot.takeString()
                                text += more
                                slot = .string(text)
                            } else {
                                slot = try self.binary(opName, slot, rhs)
                            }
                        }
                    }
                    reload()
                case .mutatePath(let root, let steps, let method, let argc, let labels):
                    let args = popN(argc)
                    let savedCoercing = coercingStore
                    coercingStore = false
                    defer { coercingStore = savedCoercing }
                    let keys = popN(keyCount(steps))
                    sync()
                    var result: SwiftValue = .void
                    try withRoot(root, frameIndex: frameIndex, base: base) { target in
                        try self.walk(&target, steps[...], keys[...]) { slot in
                            if case .cell(let c) = slot {
                                var inner = c.value
                                result = try self.callMutating(&inner, method, args, labels)
                                c.value = inner
                                self.stateChanged()
                            } else {
                                result = try self.callMutating(&slot, method, args, labels)
                            }
                        }
                    }
                    stack.append(result)
                    reload()

                case .call(let argc, let labels, let inoutPositions):
                    var args = popN(argc)
                    let callee = pop()
                    sync()
                    // A call to interpreted code runs in this loop: push its frame and carry
                    // on, so recursion in the program is not recursion on the host stack.
                    if case .function(let fn) = callee {
                        switch fn.kind {
                        case .closure(let proto, let upvalues):
                            try pushFrame(proto: proto, arguments: try bind(proto, args, labels), selfValue: nil,
                                          upvalues: upvalues, mode: .normal, inoutPositions: inoutPositions)
                            reload()
                            continue
                        case .method(let proto, let receiver):
                            try pushFrame(proto: proto, arguments: try bind(proto, args, labels), selfValue: receiver,
                                          upvalues: [], mode: .normal, inoutPositions: inoutPositions)
                            reload()
                            continue
                        default:
                            break
                        }
                    }
                    let result = try callValue(callee, &args, labels: labels)
                    for i in inoutPositions { inoutResults.append(args[i]) }
                    stack.append(result)
                    reload()
                case .invoke(let name, let argc, let labels, let inoutPositions):
                    var args = popN(argc)
                    let receiver = pop()
                    sync()
                    if let type = typeOf(receiver), let proto = pick(findMethods(type, name), labels, argc) {
                        try pushFrame(proto: proto, arguments: try bind(proto, args, labels), selfValue: receiver,
                                      upvalues: [], mode: .normal, inoutPositions: inoutPositions)
                        reload()
                        continue
                    }
                    if case .type(let t) = receiver, let proto = pick(findStaticMethods(t, name), labels, argc) {
                        try pushFrame(proto: proto, arguments: try bind(proto, args, labels), selfValue: receiver,
                                      upvalues: [], mode: .normal, inoutPositions: inoutPositions)
                        reload()
                        continue
                    }
                    let result = try invokeMethod(receiver, name, &args, labels)
                    for i in inoutPositions { inoutResults.append(args[i]) }
                    stack.append(result)
                    reload()
                case .superInvoke(let name, let argc, let labels):
                    let args = popN(argc)
                    let receiver = pop()
                    sync()
                    guard let owner = frames[frameIndex].proto.owner, let superType = owner.superclass else {
                        throw SwiftRuntimeError(message: "'super' used outside of a subclass")
                    }
                    if name == "init" {
                        guard let initProto = pick(findInits(superType), labels, argc) else {
                            throw SwiftRuntimeError(message: "no matching super.init")
                        }
                        let bound = try bind(initProto, args, labels)
                        _ = try invoke(proto: initProto, arguments: bound, selfValue: receiver, upvalues: [], mode: .initializer)
                        stack.append(.void)
                    } else if let proto = pick(findMethods(superType, name), labels, argc) {
                        let bound = try bind(proto, args, labels)
                        stack.append(try invoke(proto: proto, arguments: bound, selfValue: receiver, upvalues: [], mode: .normal))
                    } else if argc == 0, let getter = findComputed(superType, name)?.getter {
                        stack.append(try invoke(proto: getter, arguments: [], selfValue: receiver, upvalues: [], mode: .normal))
                    } else {
                        throw SwiftRuntimeError(message: "superclass has no member '\(name)'")
                    }
                    reload()
                case .makeUnresolved(let name, let argc, let labels):
                    let args = popN(argc)
                    stack.append(.unresolved(SwiftUnresolved(name: name, args: args, labels: labels)))

                case .binary(let opName):
                    let rhs = pop()
                    let lhs = pop()
                    sync()
                    stack.append(try binary(opName, lhs, rhs))
                    reload()
                case .prefix(let opName):
                    let v = pop()
                    stack.append(try SwiftRuntime.prefix(opName, v))

                case .jump(let target):
                    pc = target
                case .jumpIfFalse(let target):
                    if case .bool(false) = pop() { pc = target }
                case .jumpIfTrue(let target):
                    if case .bool(true) = pop() { pc = target }
                case .chainJump(let target):
                    switch stack[stack.count - 1] {
                    case .none: pc = target
                    case .some(let inner): stack[stack.count - 1] = inner
                    default: break
                    }
                case .coalesce(let target):
                    switch stack[stack.count - 1] {
                    case .none: stack.removeLast()
                    case .some(let inner): stack[stack.count - 1] = inner; pc = target
                    default: pc = target
                    }
                case .unwrapOrJump(let target):
                    switch stack[stack.count - 1] {
                    case .none: stack.removeLast(); pc = target
                    case .some(let inner): stack[stack.count - 1] = inner
                    default: break
                    }
                case .wrapOptional:
                    let v = pop()
                    switch v {
                    case .none, .some: stack.append(v)
                    default: stack.append(.some(v))
                    }
                case .forceUnwrap:
                    switch pop() {
                    case .none:
                        throw SwiftRuntimeError(message: "Unexpectedly found nil while unwrapping an Optional value")
                    case .some(let inner): stack.append(inner)
                    case let other: stack.append(other)
                    }

                case .makeArray(let n):
                    var items = popN(n)
                    // `[Level.high, .low]`: the literal's element type comes from its typed elements.
                    if items.contains(where: { if case .unresolved = $0 { return true }; return false }),
                       let type = items.lazy.compactMap({ self.typeOf($0) }).first {
                        items = items.map { v in
                            if case .unresolved(let u) = v, let r = try? resolveUnresolved(u, in: type) { return r }
                            return v
                        }
                    }
                    stack.append(.array(items))
                case .makeDictionary(let n):
                    let flat = popN(n * 2)
                    var dict = SwiftDictionary()
                    for i in 0..<n { dict.set(flat[i * 2], flat[i * 2 + 1]) }
                    stack.append(.dictionary(dict))
                case .makeTuple(let labels):
                    stack.append(.tuple(SwiftTuple(values: popN(labels.count), labels: labels)))
                case .makeClosure(let proto):
                    var boxes: [SwiftBox] = []
                    boxes.reserveCapacity(proto.captures.count)
                    for capture in proto.captures {
                        switch capture {
                        case .local(let slot):
                            boxes.append(boxAt(base + slot))
                        case .upvalue(let i):
                            boxes.append(frames[frameIndex].upvalues[i])
                        }
                    }
                    stack.append(.function(SwiftFunction(.closure(proto, boxes))))
                case .interpolate(let n):
                    let parts = popN(n)
                    sync()
                    var text = ""
                    for part in parts { text += try describe(part) }
                    stack.append(.string(text))
                    reload()
                case .coerce(let type):
                    let v = pop()
                    stack.append(coerce(v, to: type))

                case .returnValue:
                    let result = pop()
                    let frame = frames[frameIndex]
                    var value = result
                    switch frame.mode {
                    case .normal:
                        if frame.proto.isFailable, case .none = result {
                            value = .none
                        }
                    case .initializer:
                        if frame.proto.isFailable, case .none = result {
                            value = .none
                        } else {
                            value = selfSlot(frameIndex)
                            if frame.proto.isFailable { value = .some(value) }
                        }
                    case .mutating:
                        // Moved out, not copied: the caller's place gets the only reference.
                        if case .boxRef(let box) = stack[frame.base] {
                            lastFinalSelf = box.value
                        } else {
                            lastFinalSelf = stack[frame.base].take()
                        }
                    }
                    if frame.proto.returnType != nil, frame.mode == .normal {
                        value = coerce(value, to: frame.proto.returnType)
                    }
                    // Inout parameters report their final values to the caller.
                    if frame.proto.params.contains(where: \.isInout) {
                        lastInoutFinals = frame.proto.params.filter(\.isInout).map { p in
                            let raw = stack[frame.base + p.slot]
                            if case .boxRef(let box) = raw { return box.value }
                            return raw
                        }
                    }
                    if !frame.inoutPositions.isEmpty {
                        inoutResults.append(contentsOf: lastInoutFinals)
                        lastInoutFinals = []
                    }
                    if frameIndex == recordParamsFrame {
                        recordedParams = frame.proto.params.map { p in
                            if case .boxRef(let box) = stack[frame.base + p.slot] { return box.value }
                            return stack[frame.base + p.slot]
                        }
                    }
                    frames.removeLast()
                    stack.removeSubrange(frame.base...)
                    if frames.count == depth { return value }
                    reload()
                    stack.append(value)

                case .makeIterator:
                    let v = pop()
                    stack.append(.iterator(try makeIterator(v)))
                case .iterate(let slot, let exit):
                    guard case .iterator(let it) = stack[base + slot] else {
                        throw SwiftRuntimeError(message: "internal: iterator slot")
                    }
                    if let next = it.next() { stack.append(next) } else { pc = exit }

                case .patternMatch:
                    let value = pop()
                    let pattern = pop()
                    sync()
                    stack.append(.bool(try matches(pattern, value)))
                    reload()
                case .enumCaseIs(let name):
                    let v = pop()
                    stack.append(.bool(enumCaseIs(v, name)))
                case .enumPayload(let i):
                    let v = pop()
                    switch v {
                    case .enumValue(let e) where i < e.payload.count:
                        stack.append(e.payload[i])
                    case .some(let inner):
                        if case .enumValue(let e) = inner, i < e.payload.count { stack.append(e.payload[i]) } else { stack.append(inner) }
                    default:
                        stack.append(v)
                    }
                case .tupleElement(let i):
                    let v = pop()
                    guard case .tuple(let t) = v, i < t.values.count else {
                        throw SwiftRuntimeError(message: "value is not a tuple")
                    }
                    stack.append(t.values[i])
                case .isSome:
                    let v = pop()
                    stack.append(.bool(!v.isNone))
                case .typeCheck(let type):
                    let v = pop()
                    stack.append(.bool(isInstance(v, of: type)))
                case .cast(let type, let kind):
                    let v = pop()
                    let inner = v.unwrapped ?? v
                    let ok = isInstance(inner, of: type)
                    switch kind {
                    case "as?": stack.append(ok ? .some(coerce(inner, to: type)) : .none)
                    case "as!":
                        guard ok else {
                            throw SwiftRuntimeError(message: "Could not cast value of type '\(SwiftRuntime.typeName(inner))' to '\(type)'")
                        }
                        stack.append(coerce(inner, to: type))
                    default: stack.append(coerce(v, to: type))
                    }

                case .throwError:
                    let v = pop()
                    sync()
                    throw SwiftThrown(value: v)
                case .pushHandler(let target):
                    frames[frameIndex].handlers.append(Handler(pc: target, stackHeight: stack.count))
                case .popHandler:
                    _ = frames[frameIndex].handlers.popLast()
                case .popInout:
                    stack.append(inoutResults.removeFirst())

                case .collect:
                    let v = pop()
                    if isViewLike(v) {
                        if frames[frameIndex].builder == nil { frames[frameIndex].builder = [] }
                        frames[frameIndex].builder!.append(v)
                    }
                case .fallOff:
                    // The end of a body with no explicit return: a result builder's collected
                    // views, or Void.
                    if let built = frames[frameIndex].builder {
                        stack.append(built.count == 1 ? built[0] : .view(SwiftViewNode(kind: "Group", children: built)))
                    } else {
                        stack.append(.void)
                    }
                case .fail(let message):
                    throw SwiftRuntimeError(message: message)
                }
            }
        } catch var error as SwiftRuntimeError {
            if error.line == nil {
                sync()
                error.line = currentLine
            }
            throw error
        } catch {
            sync()
            throw error
        }
    }

    var lastFinalSelf: SwiftValue = .void
    /// True while a `storePath` walks to its target (see there).
    private var coercingStore = false
    /// `reduce(into:)` reads its closure's parameters after the call: the frame at this index
    /// records them as it returns.
    var recordParamsFrame: Int?
    var recordedParams: [SwiftValue] = []

    private func selfSlot(_ frameIndex: Int) -> SwiftValue {
        let frame = frames[frameIndex]
        let raw = stack[frame.base]
        if case .boxRef(let box) = raw { return box.value }
        return raw
    }

    private func boxAt(_ index: Int) -> SwiftBox {
        if case .boxRef(let box) = stack[index] { return box }
        let box = SwiftBox(stack[index])
        stack[index] = .boxRef(box)
        return box
    }

    private func keyCount(_ steps: [SwiftPathStep]) -> Int {
        steps.reduce(0) { total, step in
            if case .index(let argc, _) = step { return total + argc }
            return total
        }
    }

    // MARK: Paths

    private func withRoot(_ root: SwiftRoot, frameIndex: Int, base: Int, _ body: (inout SwiftValue) throws -> Void) throws {
        switch root {
        case .local(let slot):
            if case .boxRef(let box) = stack[base + slot] {
                var v = box.value
                box.value = .void
                defer { box.value = v }
                try body(&v)
                return
            }
            var v = stack[base + slot]
            stack[base + slot] = .void
            defer { stack[base + slot] = v }
            try body(&v)
        case .constant(let i):
            var v = program.constants[i]
            try body(&v)
        case .selfType:
            guard let owner = frames[frameIndex].proto.owner else {
                throw SwiftRuntimeError(message: "'Self' is only available in a type")
            }
            var v = SwiftValue.type(owner)
            try body(&v)
        case .upvalue(let i):
            let box = frames[frameIndex].upvalues[i]
            var v = box.value
            box.value = .void
            defer { box.value = v }
            try body(&v)
        case .global(let i):
            var v = program.globals[i]
            program.globals[i] = .void
            defer { program.globals[i] = v }
            try body(&v)
        }
    }

    /// Walk `steps` into `value` in place and apply `leaf` to the slot at the end. Structs and
    /// arrays are mutated where they sit; class instances are mutated through their reference;
    /// computed properties and subscripts go through their getter and setter.
    func walk(_ value: inout SwiftValue, _ steps: ArraySlice<SwiftPathStep>, _ keys: ArraySlice<SwiftValue>,
              _ leaf: (inout SwiftValue) throws -> Void) throws {
        guard let step = steps.first else {
            try leaf(&value)
            return
        }
        let rest = steps.dropFirst()
        switch step {
        case .chain, .unwrap:
            switch value.kind {
            case .none:
                if case .chain = step { return }
                throw SwiftRuntimeError(message: "Unexpectedly found nil while unwrapping an Optional value")
            case .some:
                var inner = value.takeSome()
                defer { value = .some(inner) }
                try walk(&inner, rest, keys, leaf)
            default:
                try walk(&value, rest, keys, leaf)
            }
        case .member(let name):
            try walkMember(&value, name, rest, keys, leaf)
        case .index(let argc, let labels):
            let myKeys = Array(keys.prefix(argc))
            let restKeys = keys.dropFirst(argc)
            try walkIndex(&value, myKeys, labels, rest, restKeys, leaf)
        }
    }

    private func walkMember(_ value: inout SwiftValue, _ name: String, _ rest: ArraySlice<SwiftPathStep>,
                            _ keys: ArraySlice<SwiftValue>, _ leaf: (inout SwiftValue) throws -> Void) throws {
        if value.kind == .structValue, let type = typeOf(value), type.storedIndex[name] != nil {
            var s = value.takeStruct()!
            defer { value = .structValue(s) }
            try walkStoredField(&s, name, rest, keys, leaf)
            return
        }
        if value.kind == .tuple {
            var t = value.takeTuple()!
            defer { value = .tuple(t) }
            let i = t.labels.firstIndex(of: name) ?? Int(name) ?? -1
            guard i >= 0, i < t.values.count else { throw SwiftRuntimeError(message: "tuple has no member '\(name)'") }
            try walk(&t.values[i], rest, keys, leaf)
            return
        }
        switch value {
        case .cell(let cell):
            var inner = cell.value
            try walkMember(&inner, name, rest, keys, leaf)
            cell.value = inner
            stateChanged()
            return
        case .structValue(let s):
            if let accessors = findComputed(s.type, name) {
                guard let getter = accessors.getter else { throw SwiftRuntimeError(message: "'\(name)' has no getter") }
                var inner = try invoke(proto: getter, arguments: [], selfValue: value, upvalues: [], mode: .normal)
                try walk(&inner, rest, keys, leaf)
                guard let setter = accessors.setter else {
                    throw SwiftRuntimeError(message: "cannot assign to property: '\(name)' is a get-only property")
                }
                _ = try invoke(proto: setter, arguments: [inner], selfValue: value, upvalues: [], mode: .mutating)
                value = lastFinalSelf.take()
                return
            }
            throw SwiftRuntimeError(message: "value of type '\(s.type.name)' has no member '\(name)'")
        case .object(let obj):
            if let i = obj.type.storedIndex[name] {
                let prop = obj.type.stored[i]
                if prop.willSet != nil || prop.didSet != nil {
                    let old = obj.fields[i]
                    var new = old
                    try walk(&new, rest, keys, leaf)
                    new = coerce(new, to: prop.type)
                    if let ws = prop.willSet { _ = try invoke(proto: ws, arguments: [new], selfValue: value, upvalues: [], mode: .normal) }
                    obj.fields[i] = new
                    if let ds = prop.didSet { _ = try invoke(proto: ds, arguments: [old], selfValue: value, upvalues: [], mode: .normal) }
                    if prop.wrapper == "Published" { stateChanged() }
                    return
                }
                var field = obj.fields[i]
                obj.fields[i] = .void
                defer { obj.fields[i] = field }
                try walk(&field, rest, keys, leaf)
                if rest.isEmpty, coercingStore, let t = prop.type { field = coerce(field, to: t) }
                stateChanged()
                return
            }
            if let accessors = findComputed(obj.type, name) {
                guard let getter = accessors.getter else { throw SwiftRuntimeError(message: "'\(name)' has no getter") }
                var inner = try invoke(proto: getter, arguments: [], selfValue: value, upvalues: [], mode: .normal)
                try walk(&inner, rest, keys, leaf)
                guard let setter = accessors.setter else {
                    throw SwiftRuntimeError(message: "cannot assign to property: '\(name)' is a get-only property")
                }
                _ = try invoke(proto: setter, arguments: [inner], selfValue: value, upvalues: [], mode: .normal)
                return
            }
            throw SwiftRuntimeError(message: "value of type '\(obj.type.name)' has no member '\(name)'")
        case .type(let t):
            var current = try staticMember(t, name)
            try walk(&current, rest, keys, leaf)
            t.staticValues[name] = current
            return
        default:
            // Builtin computed properties with setters are rare; the common one is none.
            var inner = try getMember(value, name)
            try walk(&inner, rest, keys, leaf)
            throw SwiftRuntimeError(message: "cannot assign to property '\(name)' of \(SwiftRuntime.typeName(value))")
        }
    }

    /// A struct's stored property, with its observers and its coercion to the declared type.
    private func walkStoredField(_ s: inout SwiftStructValue, _ name: String, _ rest: ArraySlice<SwiftPathStep>,
                                 _ keys: ArraySlice<SwiftValue>, _ leaf: (inout SwiftValue) throws -> Void) throws {
        let i = s.type.storedIndex[name]!
        let prop = s.type.stored[i]
        if prop.willSet != nil || prop.didSet != nil {
            let old = s.fields[i]
            var new = old
            try walk(&new, rest, keys, leaf)
            new = coerce(new, to: prop.type)
            if let ws = prop.willSet { _ = try invoke(proto: ws, arguments: [new], selfValue: .structValue(s), upvalues: [], mode: .normal) }
            s.fields[i] = new
            if let ds = prop.didSet {
                _ = try invoke(proto: ds, arguments: [old], selfValue: .structValue(s), upvalues: [], mode: .mutating)
                s = structOf(lastFinalSelf.take()) ?? s
            }
            return
        }
        try walk(&s.fields[i], rest, keys, leaf)
        if rest.isEmpty, coercingStore, let t = prop.type, s.fields[i].kind != .cell { s.fields[i] = coerce(s.fields[i], to: t) }
    }

    private func walkIndex(_ value: inout SwiftValue, _ keys: [SwiftValue], _ labels: [String?],
                           _ rest: ArraySlice<SwiftPathStep>, _ restKeys: ArraySlice<SwiftValue>,
                           _ leaf: (inout SwiftValue) throws -> Void) throws {
        switch value.kind {
        case .cell:
            guard case .cell(let cell) = value else { return }
            var inner = cell.value
            try walkIndex(&inner, keys, labels, rest, restKeys, leaf)
            cell.value = inner
            stateChanged()
        case .array:
            guard keys.count == 1, case .int(let i) = keys[0] else {
                throw SwiftRuntimeError(message: "array subscript must be an Int")
            }
            var items = value.takeArray()
            defer { value = .array(items) }
            guard i >= 0 && i < items.count else { throw SwiftRuntimeError(message: "Index out of range") }
            try walk(&items[i], rest, restKeys, leaf)
        case .dictionary:
            guard let key = keys.first else { throw SwiftRuntimeError(message: "dictionary subscript needs a key") }
            let defaultValue: SwiftValue? = labels.count > 1 && labels[1] == "default" ? keys[1] : nil
            var dict = value.takeDictionary()
            defer { value = .dictionary(dict) }
            let k = SwiftRuntime.hashKey(key)
            if let i = dict.index[k] {
                var slot: SwiftValue = defaultValue == nil ? .some(dict.values[i]) : dict.values[i]
                dict.values[i] = .void
                try walk(&slot, rest, restKeys, leaf)
                if defaultValue == nil {
                    if let v = slot.unwrapped { dict.values[i] = v } else { dict.remove(key) }
                } else {
                    dict.values[i] = slot
                }
            } else {
                var slot: SwiftValue = defaultValue ?? .none
                try walk(&slot, rest, restKeys, leaf)
                if defaultValue == nil {
                    if let v = slot.unwrapped { dict.set(key, v) }
                } else {
                    dict.set(key, slot)
                }
            }
        case .structValue, .object:
            let type = typeOf(value)!
            guard let getter = pick(findSubscripts(type, setters: false), labels, keys.count),
                  let setter = pick(findSubscripts(type, setters: true), labels + [nil], keys.count + 1) else {
                throw SwiftRuntimeError(message: "value of type '\(type.name)' has no settable subscript")
            }
            var inner = try invoke(proto: getter, arguments: try bind(getter, keys, labels), selfValue: value, upvalues: [], mode: .normal)
            try walk(&inner, rest, restKeys, leaf)
            _ = try invoke(proto: setter, arguments: try bind(setter, keys + [inner], labels + [nil]), selfValue: value, upvalues: [], mode: .mutating)
            if case .structValue = value { value = lastFinalSelf.take() }
        default:
            throw SwiftRuntimeError(message: "cannot subscript a value of type \(SwiftRuntime.typeName(value))")
        }
    }

    private func structOf(_ v: SwiftValue) -> SwiftStructValue? {
        if case .structValue(let s) = v { return s }
        return nil
    }

    /// Run a mutating method with `receiver` as its `self`, moving the value into the frame and
    /// back so the method mutates the only copy. A method that can throw gets a copy instead: a
    /// throw unwinds its frame, and the caller must still hold its value.
    func invokeMutating(_ proto: SwiftProto, _ arguments: [SwiftValue], _ receiver: inout SwiftValue) throws -> SwiftValue {
        if proto.throwsErrors {
            let result = try invoke(proto: proto, arguments: arguments, selfValue: receiver, upvalues: [], mode: .mutating)
            receiver = lastFinalSelf.take()
            return result
        }
        let depth = frames.count
        try pushFrame(proto: proto, arguments: arguments, selfValue: nil, upvalues: [], mode: .mutating)
        stack[frames[depth].base] = receiver.take()
        let result = try run(depth: depth)
        receiver = lastFinalSelf.take()
        return result
    }

    /// Call a (possibly) mutating method on a value held in place.
    func callMutating(_ receiver: inout SwiftValue, _ name: String, _ args: [SwiftValue], _ labels: [String?]) throws -> SwiftValue {
        if let type = typeOf(receiver), type.kind != .classType {
            if let proto = pick(findMethods(type, name), labels, args.count) {
                let bound = try bind(proto, args, labels)
                if proto.isMutating { return try invokeMutating(proto, bound, &receiver) }
                return try invoke(proto: proto, arguments: bound, selfValue: receiver, upvalues: [], mode: .normal)
            }
        }
        if case .object = receiver {
            var a = args
            return try invokeMethod(receiver, name, &a, labels)
        }
        if case .structValue = receiver {
            var a = args
            return try invokeMethod(receiver, name, &a, labels)
        }
        if case .enumValue = receiver {
            var a = args
            return try invokeMethod(receiver, name, &a, labels)
        }
        if let result = try SwiftRuntime.mutateBuiltin(&receiver, name, args, labels, vm: self) {
            return result
        }
        // A user extension on a builtin type (`extension Array { mutating func … }`).
        if let ext = program.builtinExtensions[SwiftRuntime.builtinTypeName(receiver)],
           let proto = pick(ext.methods[name], labels, args.count) {
            let bound = try bind(proto, args, labels)
            if proto.isMutating { return try invokeMutating(proto, bound, &receiver) }
            return try invoke(proto: proto, arguments: bound, selfValue: receiver, upvalues: [], mode: .normal)
        }
        var a = args
        return try invokeMethod(receiver, name, &a, labels)
    }

    // MARK: Members

    func typeOf(_ v: SwiftValue) -> SwiftTypeInfo? {
        switch v {
        case .structValue(let s): s.type
        case .object(let o): o.type
        case .enumValue(let e): e.type
        default: nil
        }
    }

    func findMethods(_ type: SwiftTypeInfo, _ name: String) -> [SwiftProto]? {
        var t: SwiftTypeInfo? = type
        while let current = t {
            if let m = current.methods[name] { return m }
            t = current.superclass
        }
        for proto in allConformances(type) {
            if let p = program.protocols[proto], let m = p.methods[name] { return m }
        }
        return nil
    }

    func findStaticMethods(_ type: SwiftTypeInfo, _ name: String) -> [SwiftProto]? {
        var t: SwiftTypeInfo? = type
        while let current = t {
            if let m = current.staticMethods[name] { return m }
            t = current.superclass
        }
        for proto in allConformances(type) {
            if let p = program.protocols[proto], let m = p.staticMethods[name] { return m }
        }
        return nil
    }

    func findComputed(_ type: SwiftTypeInfo, _ name: String) -> (getter: SwiftProto?, setter: SwiftProto?)? {
        var t: SwiftTypeInfo? = type
        while let current = t {
            if let c = current.computed[name] { return c }
            t = current.superclass
        }
        for proto in allConformances(type) {
            if let p = program.protocols[proto], let c = p.computed[name] { return c }
        }
        return nil
    }

    func findInits(_ type: SwiftTypeInfo) -> [SwiftProto] {
        if !type.inits.isEmpty { return type.inits }
        // A subclass that declares no initializer inherits its superclass's.
        if type.kind == .classType, let s = type.superclass { return findInits(s) }
        return []
    }

    func findSubscripts(_ type: SwiftTypeInfo, setters: Bool) -> [SwiftProto]? {
        var t: SwiftTypeInfo? = type
        while let current = t {
            let list = setters ? current.subscriptSetters : current.subscriptGetters
            if !list.isEmpty { return list }
            t = current.superclass
        }
        return nil
    }

    func allConformances(_ type: SwiftTypeInfo) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        var queue: [String] = []
        var t: SwiftTypeInfo? = type
        while let current = t {
            queue.append(contentsOf: current.conformances)
            t = current.superclass
        }
        while let name = queue.first {
            queue.removeFirst()
            guard seen.insert(name).inserted else { continue }
            result.append(name)
            if let p = program.protocols[name] { queue.append(contentsOf: p.conformances) }
        }
        return result
    }

    func conforms(_ type: SwiftTypeInfo, to proto: String) -> Bool {
        allConformances(type).contains(proto)
    }

    func getMember(_ receiver: SwiftValue, _ name: String) throws -> SwiftValue {
        switch receiver {
        case .cell(let c):
            return try getMember(c.value, name)
        case .structValue(let s):
            if let i = s.type.storedIndex[name] { return s.fields[i].dereferenced }
            if name.hasPrefix("$"), let i = s.type.storedIndex[String(name.dropFirst())] { return s.fields[i] }
            if let c = findComputed(s.type, name), let getter = c.getter {
                return try invoke(proto: getter, arguments: [], selfValue: receiver, upvalues: [], mode: .normal)
            }
            if let m = findMethods(s.type, name)?.first { return .function(SwiftFunction(.method(m, receiver))) }
        case .object(let o):
            if let i = o.type.storedIndex[name] { return o.fields[i].dereferenced }
            if name.hasPrefix("$"), let i = o.type.storedIndex[String(name.dropFirst())] { return o.fields[i] }
            if let c = findComputed(o.type, name), let getter = c.getter {
                return try invoke(proto: getter, arguments: [], selfValue: receiver, upvalues: [], mode: .normal)
            }
            if let m = findMethods(o.type, name)?.first { return .function(SwiftFunction(.method(m, receiver))) }
        case .enumValue(let e):
            if name == "rawValue", let c = e.type.caseIndex[e.name], let raw = e.type.cases[c].rawValue { return raw }
            if let c = findComputed(e.type, name), let getter = c.getter {
                return try invoke(proto: getter, arguments: [], selfValue: receiver, upvalues: [], mode: .normal)
            }
            if let m = findMethods(e.type, name)?.first { return .function(SwiftFunction(.method(m, receiver))) }
            if name == "hashValue" { return .int(SwiftRuntime.hashKey(receiver).hashValue) }
        case .type(let t):
            return try staticMember(t, name)
        case .tuple(let t):
            if let i = t.labels.firstIndex(of: name) { return t.values[i] }
            if let i = Int(name), i < t.values.count { return t.values[i] }
        case .unresolved(let u):
            return .unresolved(SwiftUnresolved(name: u.name + "." + name, args: nil, labels: []))
        default:
            break
        }
        if let value = try SwiftRuntime.builtinProperty(receiver, name, vm: self) { return value }
        if let ext = program.builtinExtensions[SwiftRuntime.builtinTypeName(receiver)] {
            if let c = ext.computed[name], let getter = c.getter {
                return try invoke(proto: getter, arguments: [], selfValue: receiver, upvalues: [], mode: .normal)
            }
            if let m = ext.methods[name]?.first { return .function(SwiftFunction(.method(m, receiver))) }
        }
        for protoName in SwiftRuntime.builtinConformances(receiver) {
            if let p = program.protocols[protoName], let c = p.computed[name], let getter = c.getter {
                return try invoke(proto: getter, arguments: [], selfValue: receiver, upvalues: [], mode: .normal)
            }
        }
        if SwiftRuntime.hasBuiltinMethod(receiver, name) {
            return .function(SwiftFunction(.nativeMethod(receiver, name)))
        }
        throw SwiftRuntimeError(message: "value of type '\(SwiftRuntime.typeName(receiver))' has no member '\(name)'")
    }

    func staticMember(_ t: SwiftTypeInfo, _ name: String) throws -> SwiftValue {
        if let v = t.staticValues[name] { return v }
        if let initializer = t.staticInitializers[name] {
            // Static stored properties initialise lazily, on first access, as in Swift.
            t.staticValues[name] = .void
            let v = coerce(try invoke(proto: initializer, arguments: [], selfValue: .type(t), upvalues: [], mode: .normal), to: nil)
            t.staticValues[name] = v
            return v
        }
        if let getter = t.staticComputed[name] {
            return try invoke(proto: getter, arguments: [], selfValue: .type(t), upvalues: [], mode: .normal)
        }
        if let c = t.caseIndex[name] {
            let info = t.cases[c]
            if info.labels != nil { return .function(SwiftFunction(.enumCase(t, name))) }
            return .enumValue(SwiftEnumValue(type: t, name: name, payload: []))
        }
        if let nested = t.nested[name] { return .type(nested) }
        if name == "allCases", t.kind == .enumType {
            return .array(t.cases.map { .enumValue(SwiftEnumValue(type: t, name: $0.name, payload: [])) })
        }
        if name == "self" { return .type(t) }
        if name == "init" {
            return .function(SwiftFunction(.native("\(t.name).init") { args, labels, vm in
                try vm.construct(t, args, labels)
            }))
        }
        if let m = findStaticMethods(t, name)?.first {
            return .function(SwiftFunction(.method(m, .type(t))))
        }
        if let superclass = t.superclass { return try staticMember(superclass, name) }
        throw SwiftRuntimeError(message: "type '\(t.name)' has no member '\(name)'")
    }

    func getIndex(_ receiver: SwiftValue, _ keys: [SwiftValue], _ labels: [String?]) throws -> SwiftValue {
        if let type = typeOf(receiver) {
            guard let getter = pick(findSubscripts(type, setters: false), labels, keys.count) else {
                throw SwiftRuntimeError(message: "value of type '\(type.name)' has no subscript")
            }
            return try invoke(proto: getter, arguments: try bind(getter, keys, labels), selfValue: receiver, upvalues: [], mode: .normal)
        }
        if case .type(let t) = receiver, let getter = t.staticMethods["subscript"]?.first {
            return try invoke(proto: getter, arguments: try bind(getter, keys, labels), selfValue: receiver, upvalues: [], mode: .normal)
        }
        return try SwiftRuntime.subscriptBuiltin(receiver, keys, labels)
    }

    func invokeMethod(_ receiver: SwiftValue, _ name: String, _ args: inout [SwiftValue], _ labels: [String?]) throws -> SwiftValue {
        switch receiver {
        case .cell(let c):
            return try invokeMethod(c.value, name, &args, labels)
        case .structValue, .object, .enumValue:
            let type = typeOf(receiver)!
            if name == "init", case .object = receiver, let proto = pick(findInits(type), labels, args.count) {
                _ = try invoke(proto: proto, arguments: try bind(proto, args, labels), selfValue: receiver, upvalues: [], mode: .initializer)
                return .void
            }
            if let proto = pick(findMethods(type, name), labels, args.count) {
                let bound = try bind(proto, args, labels)
                let result = try invoke(proto: proto, arguments: bound, selfValue: receiver, upvalues: [], mode: .normal)
                collectInout(proto, into: &args)
                return result
            }
            // A stored closure property called like a method: `self.onTap()`.
            if let i = type.storedIndex[name] {
                let field: SwiftValue
                switch receiver {
                case .structValue(let s): field = s.fields[i].dereferenced
                case .object(let o): field = o.fields[i].dereferenced
                default: field = .void
                }
                return try callValue(field, &args, labels: labels)
            }
            if findComputed(type, name) != nil {
                return try callValue(try getMember(receiver, name), &args, labels: labels)
            }
            if case .structValue(let s) = receiver, conforms(s.type, to: "View") {
                return SwiftViewLibrary.modify(receiver, name, args, labels)
            }
        case .type(let t):
            if let proto = pick(findStaticMethods(t, name), labels, args.count) {
                let bound = try bind(proto, args, labels)
                let result = try invoke(proto: proto, arguments: bound, selfValue: receiver, upvalues: [], mode: .normal)
                collectInout(proto, into: &args)
                return result
            }
            if name == "init" { return try construct(t, args, labels) }
            if let c = t.caseIndex[name] {
                guard t.cases[c].labels != nil else {
                    throw SwiftRuntimeError(message: "enum case '\(name)' has no associated values")
                }
                return .enumValue(SwiftEnumValue(type: t, name: name, payload: try coercePayload(t, name, args)))
            }
            if let nested = t.nested[name] { return try construct(nested, args, labels) }
            if name == "random", t.kind == .enumType, let pick = t.cases.randomElement() {
                return .enumValue(SwiftEnumValue(type: t, name: pick.name, payload: []))
            }
            if let member = try? staticMember(t, name) {
                return try callValue(member, &args, labels: labels)
            }
            throw SwiftRuntimeError(message: "type '\(t.name)' has no member '\(name)'")
        case .unresolved(let u):
            return .unresolved(SwiftUnresolved(name: u.name + "." + name, args: args, labels: labels))
        case .function where name == "callAsFunction":
            return try callValue(receiver, &args, labels: labels)
        case .view:
            return SwiftViewLibrary.modify(receiver, name, args, labels)
        default:
            break
        }
        if case .builtinType(let typeName) = receiver {
            if let ext = program.builtinExtensions[typeName], let proto = pick(ext.staticMethods[name], labels, args.count) {
                return try invoke(proto: proto, arguments: try bind(proto, args, labels), selfValue: receiver, upvalues: [], mode: .normal)
            }
        }
        if let ext = program.builtinExtensions[SwiftRuntime.builtinTypeName(receiver)],
           let proto = pick(ext.methods[name], labels, args.count) {
            let bound = try bind(proto, args, labels)
            return try invoke(proto: proto, arguments: bound, selfValue: receiver, upvalues: [], mode: .normal)
        }
        if SwiftRuntime.hasBuiltinMethod(receiver, name) {
            return try SwiftRuntime.invokeBuiltin(receiver, name, args, labels, vm: self)
        }
        for protoName in SwiftRuntime.builtinConformances(receiver) {
            if let p = program.protocols[protoName], let proto = pick(p.methods[name], labels, args.count) {
                let bound = try bind(proto, args, labels)
                return try invoke(proto: proto, arguments: bound, selfValue: receiver, upvalues: [], mode: .normal)
            }
        }
        // A property holding a closure, called: `vm.transform(x)`.
        if let member = try? getMember(receiver, name), case .function = member {
            return try callValue(member, &args, labels: labels)
        }
        return try SwiftRuntime.invokeBuiltin(receiver, name, args, labels, vm: self)
    }

    // MARK: Construction

    func construct(_ type: SwiftTypeInfo, _ args: [SwiftValue], _ labels: [String?]) throws -> SwiftValue {
        switch type.kind {
        case .enumType:
            if labels == ["rawValue"], args.count == 1 {
                let match = type.cases.first { c in
                    if let raw = c.rawValue { return SwiftRuntime.equal(raw, args[0]) }
                    return false
                }
                if let match { return .some(.enumValue(SwiftEnumValue(type: type, name: match.name, payload: []))) }
                if type.inits.isEmpty { return .none }
            }
            if let proto = pick(type.inits, labels, args.count) {
                let bound = try bind(proto, args, labels)
                return try invoke(proto: proto, arguments: bound, selfValue: SwiftValue.none, upvalues: [], mode: .initializer)
            }
            throw SwiftRuntimeError(message: "enum '\(type.name)' has no matching initializer")
        case .protocolType, .builtinExtension:
            throw SwiftRuntimeError(message: "'\(type.name)' cannot be constructed")
        case .structType, .classType:
            let blank = try makeBlank(type)
            let inits = findInits(type)
            if let proto = pick(inits, labels, args.count) {
                let bound = try bind(proto, args, labels)
                return try invoke(proto: proto, arguments: bound, selfValue: blank, upvalues: [], mode: .initializer)
            }
            if type.hasMemberwiseInit || (inits.isEmpty && type.kind == .classType) {
                return try memberwise(type, blank, args, labels)
            }
            throw SwiftRuntimeError(message: "no initializer for '\(type.name)' matches (\(labels.map { ($0 ?? "_") + ":" }.joined()))")
        }
    }

    /// A fresh instance with every stored property at its declared default.
    func makeBlank(_ type: SwiftTypeInfo) throws -> SwiftValue {
        var chain: [SwiftTypeInfo] = []
        var t: SwiftTypeInfo? = type
        while let current = t { chain.insert(current, at: 0); t = current.superclass }
        var fields: [SwiftValue] = Array(repeating: .none, count: type.stored.count)
        for (i, prop) in type.stored.enumerated() {
            if let initializer = prop.initializer {
                fields[i] = coerce(try invoke(proto: initializer, arguments: [], selfValue: nil, upvalues: [], mode: .normal), to: prop.type)
            } else if case .optional? = prop.type {
                fields[i] = .none
            } else {
                fields[i] = .void
            }
            if let wrapper = prop.wrapper, SwiftRuntime.cellWrappers.contains(wrapper) {
                fields[i] = .cell(SwiftCell(fields[i]))
            }
        }
        if type.kind == .classType { return .object(SwiftObject(type: type, fields: fields)) }
        return .structValue(SwiftStructValue(type: type, fields: fields))
    }

    private func memberwise(_ type: SwiftTypeInfo, _ blank: SwiftValue, _ args: [SwiftValue], _ labels: [String?]) throws -> SwiftValue {
        guard case .structValue(var s) = blank else {
            if args.isEmpty { return blank }
            throw SwiftRuntimeError(message: "class '\(type.name)' has no initializers")
        }
        var ai = 0
        for (i, prop) in type.stored.enumerated() {
            if prop.isLet && prop.initializer != nil { continue }
            let label = prop.wrapper == nil ? prop.name : prop.name
            if ai < args.count, labels[ai] == label {
                let value = coerce(args[ai], to: prop.type)
                if case .cell(let c) = s.fields[i] {
                    // `@Binding var x` takes the caller's cell; `@State` takes an initial value.
                    if case .cell(let passed) = args[ai] { s.fields[i] = .cell(passed) } else { c.value = value }
                } else if prop.wrapper == "Binding", case .cell = args[ai] {
                    s.fields[i] = args[ai]
                } else {
                    s.fields[i] = value
                }
                ai += 1
            } else if prop.initializer == nil && !isOptionalType(prop.type) && prop.wrapper == nil {
                throw SwiftRuntimeError(message: "missing argument for parameter '\(prop.name)' in call to \(type.name).init")
            }
        }
        if ai < args.count {
            throw SwiftRuntimeError(message: "extra argument '\(labels[ai] ?? "_")' in call to \(type.name).init")
        }
        return .structValue(s)
    }

    private func isOptionalType(_ t: SwiftTypeRef?) -> Bool {
        if case .optional? = t { return true }
        return false
    }

    private func coercePayload(_ type: SwiftTypeInfo, _ name: String, _ args: [SwiftValue]) throws -> [SwiftValue] {
        guard let c = type.caseIndex[name] else { return args }
        let types = type.cases[c].types
        return args.enumerated().map { i, v in i < types.count ? coerce(v, to: types[i]) : v }
    }

    // MARK: Coercion

    /// Apply a declared type to a value: numeric literals widen to Double, values entering an
    /// Optional are wrapped, and implicit members (`.red`) resolve against the named type.
    func coerce(_ value: SwiftValue, to type: SwiftTypeRef?) -> SwiftValue {
        guard let type else { return value }
        switch type {
        case .optional(let inner):
            switch value {
            case .none: return .none
            case .some(let v): return .some(coerce(v, to: inner))
            case .void: return .none
            default: return .some(coerce(value, to: inner))
            }
        case .named(let name, _):
            if let alias = program.typeAliases[name] { return coerce(value, to: alias) }
            switch (name, value) {
            case ("Double", .int(let i)), ("Float", .int(let i)), ("CGFloat", .int(let i)), ("TimeInterval", .int(let i)):
                return .double(Double(i))
            case (_, .unresolved(let u)):
                if let t = lookupType(name), let resolved = try? resolveUnresolved(u, in: t) { return resolved }
                return value
            case (_, .cell(let c)) where name != "Binding":
                return c.value
            case ("Set", .array(let items)):
                var d = SwiftDictionary()
                for item in items { d.set(item, .void) }
                return .set(d)
            default:
                return value
            }
        case .array(let element):
            if case .array(let items) = value { return .array(items.map { coerce($0, to: element) }) }
            return value
        case .dictionary(let k, let v):
            if case .dictionary(var d) = value {
                d.values = d.values.map { coerce($0, to: v) }
                d.keys = d.keys.map { coerce($0, to: k) }
                return .dictionary(d)
            }
            if case .array(let items) = value, items.isEmpty { return .dictionary(SwiftDictionary()) }
            return value
        case .tuple(let types, let labels):
            if case .tuple(var t) = value, t.values.count == types.count {
                t.values = zip(t.values, types).map { coerce($0, to: $1) }
                if labels.contains(where: { $0 != nil }) { t.labels = labels }
                return .tuple(t)
            }
            return value
        case .function:
            return value
        }
    }

    func lookupType(_ name: String) -> SwiftTypeInfo? {
        if let t = program.types[name] { return t }
        if let dot = name.lastIndex(of: ".") { return program.types[String(name[name.index(after: dot)...])] }
        return nil
    }

    func resolveUnresolved(_ u: SwiftUnresolved, in type: SwiftTypeInfo) throws -> SwiftValue {
        let base = try staticMember(type, u.name)
        guard let args = u.args else { return base }
        var a = args
        if case .function = base { return try callValue(base, &a, labels: u.labels) }
        return try invokeMethod(.type(type), u.name, &a, u.labels)
    }

    // MARK: Operators

    func binary(_ op: String, _ lhs: SwiftValue, _ rhs: SwiftValue) throws -> SwiftValue {
        let l = lhs.dereferenced
        let r = rhs.dereferenced
        // User-defined operators: a static func on either operand's type, then a global.
        if let t = typeOf(l) ?? typeOf(r) {
            if let proto = pick(findStaticMethods(t, op), [nil, nil], 2) {
                return try invoke(proto: proto, arguments: [l, r], selfValue: .type(t), upvalues: [], mode: .normal)
            }
            if op == "!=", let proto = pick(findStaticMethods(t, "=="), [nil, nil], 2) {
                let eq = try invoke(proto: proto, arguments: [l, r], selfValue: .type(t), upvalues: [], mode: .normal)
                if case .bool(let b) = eq { return .bool(!b) }
            }
            if [">", "<=", ">="].contains(op), let proto = pick(findStaticMethods(t, "<"), [nil, nil], 2) {
                func less(_ a: SwiftValue, _ b: SwiftValue) throws -> Bool {
                    if case .bool(let v) = try invoke(proto: proto, arguments: [a, b], selfValue: .type(t), upvalues: [], mode: .normal) { return v }
                    return false
                }
                switch op {
                case ">": return .bool(try less(r, l))
                case "<=": return .bool(!(try less(r, l)))
                default: return .bool(!(try less(l, r)))
                }
            }
        }
        if let index = program.globalIndex["operator " + op], case .function = program.globals[index],
           typeOf(l) != nil || typeOf(r) != nil {
            return try call(program.globals[index], [l, r])
        }
        // `==` against an implicit member: `direction == .north`.
        if case .unresolved(let u) = r, let t = typeOf(l), let resolved = try? resolveUnresolved(u, in: t) {
            return try binary(op, l, resolved)
        }
        if case .unresolved(let u) = l, let t = typeOf(r), let resolved = try? resolveUnresolved(u, in: t) {
            return try binary(op, resolved, r)
        }
        if case .some(let inner) = r, case .unresolved(let u) = inner, let t = typeOf(l.unwrapped ?? l),
           let resolved = try? resolveUnresolved(u, in: t) {
            return try binary(op, l, resolved)
        }
        return try SwiftRuntime.binary(op, l, r, vm: self)
    }

    func matches(_ pattern: SwiftValue, _ value: SwiftValue) throws -> Bool {
        switch pattern {
        case .range(let lo, let hi, let closed):
            guard case .int(let v) = value.unwrapped ?? value else {
                if case .double(let d) = value { return Double(lo) <= d && (closed ? d <= Double(hi) : d < Double(hi)) }
                return false
            }
            return v >= lo && (closed ? v <= hi : v < hi)
        case .doubleRange(let lo, let hi, let closed):
            let d: Double
            switch value {
            case .double(let x): d = x
            case .int(let x): d = Double(x)
            default: return false
            }
            return lo <= d && (closed ? d <= hi : d < hi)
        default:
            if case .bool(let b) = try binary("==", pattern, value) { return b }
            return false
        }
    }

    private func enumCaseIs(_ v: SwiftValue, _ name: String) -> Bool {
        switch v {
        case .enumValue(let e): return e.name == name
        case .none: return name == "none"
        case .some(let inner):
            if name == "some" { return true }
            return enumCaseIs(inner, name)
        default:
            if name == "some" { return true }
            return false
        }
    }

    func isInstance(_ v: SwiftValue, of type: SwiftTypeRef) -> Bool {
        let value = v.dereferenced
        switch type {
        case .optional(let inner):
            if case .none = value { return true }
            return isInstance(value.unwrapped ?? value, of: inner)
        case .array(let element):
            guard case .array(let items) = value else { return false }
            return items.allSatisfy { isInstance($0, of: element) }
        case .dictionary:
            if case .dictionary = value { return true }
            return false
        case .tuple:
            if case .tuple = value { return true }
            return false
        case .function:
            if case .function = value { return true }
            return false
        case .named(let name, _):
            if let alias = program.typeAliases[name] { return isInstance(value, of: alias) }
            switch (name, value) {
            case ("Any", _), ("AnyObject", .object): return true
            case ("Int", .int), ("Double", .double), ("Float", .double), ("CGFloat", .double),
                 ("String", .string), ("Bool", .bool), ("Character", .string): return true
            case ("Error", _):
                if let t = typeOf(value) { return conforms(t, to: "Error") || t.conformances.contains("Error") }
                return false
            default:
                if let t = typeOf(value) {
                    if t.name == name || t.shortName == name { return true }
                    if let target = lookupType(name), t.isSubclass(of: target) { return true }
                    return conforms(t, to: name)
                }
                return SwiftRuntime.builtinConformances(value).contains(name)
            }
        }
    }

    func isViewLike(_ v: SwiftValue) -> Bool {
        switch v {
        case .view: return true
        case .structValue(let s): return conforms(s.type, to: "View")
        default: return false
        }
    }

    // MARK: Iteration and description

    func makeIterator(_ v: SwiftValue) throws -> SwiftIterator {
        switch v.dereferenced {
        case .range(let lo, let hi, let closed):
            return SwiftIterator(.range(lo, closed ? hi + 1 : hi))
        case .array(let items):
            return SwiftIterator(.values(items))
        case .set(let d):
            return SwiftIterator(.values(d.keys))
        case .dictionary(let d):
            return SwiftIterator(.values(zip(d.keys, d.values).map {
                .tuple(SwiftTuple(values: [$0, $1], labels: ["key", "value"]))
            }))
        case .string(let s):
            return SwiftIterator(.values(s.map { .string(String($0)) }))
        case .iterator(let it):
            return it
        case let other:
            if let type = typeOf(other), let makeProto = findMethods(type, "makeIterator")?.first {
                let iterator = try invoke(proto: makeProto, arguments: [], selfValue: other, upvalues: [], mode: .normal)
                return try drainIterator(iterator)
            }
            if let type = typeOf(other), findMethods(type, "next") != nil {
                return try drainIterator(other)
            }
            throw SwiftRuntimeError(message: "for-in requires a Sequence, found \(SwiftRuntime.typeName(other))")
        }
    }

    /// A user-defined IteratorProtocol, drained into values (its `next()` is mutating).
    private func drainIterator(_ iterator: SwiftValue) throws -> SwiftIterator {
        var it = iterator
        var values: [SwiftValue] = []
        while true {
            let next = try callMutating(&it, "next", [], [])
            guard let v = next.unwrapped else { break }
            values.append(v)
            if values.count > 10_000_000 { break }
        }
        return SwiftIterator(.values(values))
    }

    /// `String(describing:)` — what `print` and interpolation show.
    func describe(_ v: SwiftValue) throws -> String {
        try SwiftRuntime.describe(v, vm: self, debug: false)
    }
}
