import Foundation

// The Swift bytecode compiler: syntax tree in, `SwiftProgram` out. Every function, method,
// closure, accessor and initializer becomes a `SwiftProto` — a flat instruction array over a
// frame of numbered local slots — which the VM (`SwiftVM.swift`) runs.
//
// Names resolve at compile time, in Swift's order: locals, then variables captured from an
// enclosing function, then members of `self`, then globals, then the standard library. A name
// that resolves to none of those is a compile error with a line number, the way swiftc reports
// it, rather than a surprise at run time.
//
// Captured variables are not decided up front. A local lives in its slot until a closure
// captures it, at which point the VM moves it into a box both share (`SwiftValue.boxRef`);
// loads and stores through the slot follow the box from then on. Declaring a variable writes a
// fresh value over the slot instead of through the box, which is what gives each loop iteration
// its own binding.

struct SwiftCompileError: Error, CustomStringConvertible {
    let message: String
    let line: Int
    var file: String?
    var description: String { "\(file.map { "\($0):" } ?? "")\(line): error: \(message)" }
}

final class SwiftCompiler {
    struct Local {
        let slot: Int
        var type: SwiftTypeRef?
    }

    final class LoopContext {
        let label: String?
        let isSwitch: Bool
        var breaks: [Int] = []
        var continues: [Int] = []
        let scopeDepth: Int
        let handlerDepth: Int
        var continueTarget: Int?
        init(label: String?, isSwitch: Bool, scopeDepth: Int, handlerDepth: Int) {
            self.label = label
            self.isSwitch = isSwitch
            self.scopeDepth = scopeDepth
            self.handlerDepth = handlerDepth
        }
    }

    final class Context {
        let proto: SwiftProto
        let parent: Context?
        var scopes: [[String: Local]] = [[:]]
        var defers: [[[SwiftStmt]]] = [[]]
        var loops: [LoopContext] = []
        var handlerDepth = 0
        var upvalues: [String: (index: Int, type: SwiftTypeRef?)] = [:]
        let typeContext: SwiftTypeInfo?
        let isStatic: Bool
        let isTopLevel: Bool
        /// Closures, getters and view bodies collect bare view expressions (result builders).
        var builder = false
        var fallthroughTargets: [Int] = []

        init(proto: SwiftProto, parent: Context?, typeContext: SwiftTypeInfo?, isStatic: Bool, isTopLevel: Bool = false) {
            self.proto = proto
            self.parent = parent
            self.typeContext = typeContext
            self.isStatic = isStatic
            self.isTopLevel = isTopLevel
        }

        func lookupLocal(_ name: String) -> Local? {
            for scope in scopes.reversed() {
                if let local = scope[name] { return local }
            }
            return nil
        }

        func declare(_ name: String, type: SwiftTypeRef? = nil) -> Int {
            let slot = proto.localCount
            proto.localCount += 1
            scopes[scopes.count - 1][name] = Local(slot: slot, type: type)
            return slot
        }

        func temp() -> Int {
            let slot = proto.localCount
            proto.localCount += 1
            return slot
        }
    }

    enum Resolution {
        case local(Int, SwiftTypeRef?)
        case upvalue(Int, SwiftTypeRef?)
        case global(Int, SwiftTypeRef?)
        case selfMember
        case staticMember(SwiftTypeInfo)
        case value(SwiftValue)
    }

    let program = SwiftProgram()
    private var ctx: Context
    private var line = 1
    private var file: String?
    private var constantIndex: [String: Int] = [:]
    private var globalTypes: [String: SwiftTypeRef] = [:]

    // Pass-one knowledge about declared types.
    private var typeDecls: [(decl: SwiftTypeDecl, info: SwiftTypeInfo)] = []
    private var extensions: [(decl: SwiftTypeDecl, target: String)] = []
    private var instanceMemberCache: [ObjectIdentifier: Set<String>] = [:]
    private var staticMemberCache: [ObjectIdentifier: Set<String>] = [:]
    private var mutatingNames: Set<String> = [
        "append", "insert", "remove", "removeFirst", "removeLast", "popLast", "removeAll", "sort",
        "reverse", "shuffle", "swapAt", "removeValue", "updateValue", "merge", "formUnion", "subtract",
        "formIntersection", "toggle", "negate", "replaceSubrange", "removeSubrange", "update", "round",
        "reserveCapacity", "next",
    ]
    /// Chain-jump sites of the optional chain being compiled.
    private var chainStack: [[Int]] = []

    init() {
        ctx = Context(proto: program.main, parent: nil, typeContext: nil, isStatic: false, isTopLevel: true)
    }

    // MARK: - Entry

    /// Compile a set of files as one module. `main` is the file whose top-level statements run.
    static func compile(files: [(name: String, source: String)]) throws -> SwiftProgram {
        let compiler = SwiftCompiler()
        var parsed: [(name: String, stmts: [SwiftStmt])] = []
        for f in files {
            do {
                parsed.append((f.name, try SwiftParser.parse(f.source)))
            } catch let e as SwiftSyntaxError {
                throw SwiftCompileError(message: e.message, line: e.line, file: f.name)
            }
        }
        try compiler.compileModule(parsed)
        return compiler.program
    }

    private func fail(_ message: String) -> SwiftCompileError {
        SwiftCompileError(message: message, line: line, file: file)
    }

    private func compileModule(_ files: [(name: String, stmts: [SwiftStmt])]) throws {
        let mainIndex = files.firstIndex { $0.name.hasSuffix("main.swift") }
            ?? files.firstIndex { f in f.stmts.contains { stmt in
                switch stmt {
                case .function, .type, .variable, .empty: return false
                default: return true
                }
            } } ?? 0

        // Pass 1: declare every type, then every global name.
        for f in files {
            file = f.name
            for stmt in f.stmts { if case .type(let decl) = stmt { try declareType(decl, outer: nil) } }
        }
        try linkTypes()
        var functions: [(SwiftFunctionDecl, String)] = []
        for f in files {
            file = f.name
            for stmt in f.stmts {
                switch stmt {
                case .function(let fn):
                    let name = fn.name.first.map { "+-*/%<>=!&|^~".contains($0) } == true ? "operator " + fn.name : fn.name
                    _ = program.global(named: name)
                    functions.append((fn, f.name))
                case .variable(let v):
                    for name in v.pattern.bindings {
                        _ = program.global(named: name)
                        if let t = v.type { globalTypes[name] = t }
                    }
                case .block(let stmts):
                    for case .variable(let v) in stmts {
                        for name in v.pattern.bindings {
                            _ = program.global(named: name)
                            if let t = v.type { globalTypes[name] = t }
                        }
                    }
                default:
                    break
                }
            }
        }

        // Pass 2: bodies.
        for (decl, info) in typeDecls { file = declFile[ObjectIdentifier(decl)]; try compileMembers(decl, into: info) }
        for (decl, target) in extensions {
            file = declFile[ObjectIdentifier(decl)]
            try compileMembers(decl, into: try extensionTarget(target))
        }
        for (fn, name) in functions {
            file = name
            let proto = try compileFunction(fn, owner: nil, parent: nil, isMethod: false)
            let globalName = fn.name.first.map { "+-*/%<>=!&|^~".contains($0) } == true ? "operator " + fn.name : fn.name
            program.globals[program.global(named: globalName)] = .function(SwiftFunction(.closure(proto, [])))
        }

        // The entry: other files' global initialisers, then main's statements in order.
        let order = files.indices.filter { $0 != mainIndex } + [mainIndex]
        for i in order {
            file = files[i].name
            for stmt in files[i].stmts {
                switch stmt {
                case .function, .type:
                    continue
                default:
                    if i != mainIndex, case .expr = stmt {
                        throw fail("expressions are not allowed at the top level of \(files[i].name)")
                    }
                    try compileStatement(stmt)
                }
            }
        }
        emitConstant(.void)
        emit(.returnValue)
        program.entryType = typeDecls.first { $0.decl.attributes.contains("main") }?.info
    }

    private var declFile: [ObjectIdentifier: String] = [:]

    // MARK: - Emission

    @discardableResult
    private func emit(_ op: SwiftOp) -> Int {
        ctx.proto.code.append(op)
        ctx.proto.lines.append(line)
        return ctx.proto.code.count - 1
    }

    private var here: Int { ctx.proto.code.count }

    private func constant(_ value: SwiftValue) -> Int {
        let key: String?
        switch value {
        case .int, .double, .bool, .string, .none, .void: key = SwiftRuntime.hashKey(value)
        default: key = nil
        }
        if let key, let i = constantIndex[key] { return i }
        program.constants.append(value)
        if let key { constantIndex[key] = program.constants.count - 1 }
        return program.constants.count - 1
    }

    private func emitConstant(_ value: SwiftValue) {
        emit(.constant(constant(value)))
    }

    private func patch(_ at: Int, _ target: Int? = nil) {
        let t = target ?? here
        switch ctx.proto.code[at] {
        case .jump: ctx.proto.code[at] = .jump(t)
        case .jumpIfFalse: ctx.proto.code[at] = .jumpIfFalse(t)
        case .jumpIfTrue: ctx.proto.code[at] = .jumpIfTrue(t)
        case .chainJump: ctx.proto.code[at] = .chainJump(t)
        case .coalesce: ctx.proto.code[at] = .coalesce(t)
        case .unwrapOrJump: ctx.proto.code[at] = .unwrapOrJump(t)
        case .pushHandler: ctx.proto.code[at] = .pushHandler(t)
        case .iterate(let slot, _): ctx.proto.code[at] = .iterate(slot: slot, exit: t)
        default: break
        }
    }

    // MARK: - Types, pass 1

    private static let builtinExtensionTargets: Set<String> = [
        "Int", "Double", "String", "Bool", "Array", "Dictionary", "Set", "Optional", "Character",
        "Float", "CGFloat", "Range", "ClosedRange", "Substring",
    ]

    private func declareType(_ decl: SwiftTypeDecl, outer: String?) throws {
        line = decl.line
        if let file { declFile[ObjectIdentifier(decl)] = file }
        if decl.kind == .extensionType {
            let target = outer.map { "\($0).\(decl.name)" } ?? decl.name
            extensions.append((decl, target))
            for nested in decl.nested { try declareType(nested, outer: decl.name) }
            return
        }
        let name = outer.map { "\($0).\(decl.name)" } ?? decl.name
        let kind: SwiftTypeInfo.Kind = switch decl.kind {
        case .structType: .structType
        case .classType: .classType
        case .enumType: .enumType
        default: .protocolType
        }
        let info = SwiftTypeInfo(name: name, kind: kind)
        if kind == .protocolType {
            program.protocols[decl.name] = info
            info.conformances = decl.inherits
        } else {
            program.types[name] = info
            if outer != nil, program.types[decl.name] == nil { program.types[decl.name] = info }
            if let outer, let parent = program.types[outer] { parent.nested[decl.name] = info }
        }
        typeDecls.append((decl, info))
        for nested in decl.nested { try declareType(nested, outer: name) }
    }

    private func extensionTarget(_ name: String) throws -> SwiftTypeInfo {
        if let t = program.types[name] { return t }
        if let p = program.protocols[name] { return p }
        let base = name.split(separator: ".").last.map(String.init) ?? name
        if let t = program.types[base] { return t }
        if let p = program.protocols[base] { return p }
        let builtin = ["ClosedRange": "Range", "Substring": "String", "Character": "String", "Float": "Double", "CGFloat": "Double"][base] ?? base
        if Self.builtinExtensionTargets.contains(base) {
            if let existing = program.builtinExtensions[builtin] { return existing }
            let info = SwiftTypeInfo(name: builtin, kind: .builtinExtension)
            program.builtinExtensions[builtin] = info
            return info
        }
        // An extension of a protocol the standard library declares (Collection, Numeric, View…).
        let info = SwiftTypeInfo(name: base, kind: .protocolType)
        program.protocols[base] = info
        return info
    }

    /// Superclasses, conformances, raw types and stored-property layout, once every name exists.
    private func linkTypes() throws {
        for (decl, info) in typeDecls where info.kind != .protocolType {
            var conformances: [String] = []
            for (i, parent) in decl.inherits.enumerated() {
                if i == 0, info.kind == .classType, let superType = program.types[parent], superType.kind == .classType {
                    info.superclass = superType
                } else if i == 0, info.kind == .enumType, ["Int", "String", "Character", "Double", "UInt8"].contains(parent) {
                    info.rawType = parent
                } else {
                    conformances.append(parent)
                }
            }
            info.conformances = conformances
        }
        for (decl, target) in extensions {
            if let info = program.types[target] ?? program.types[target.split(separator: ".").last.map(String.init) ?? target] {
                info.conformances.append(contentsOf: decl.inherits)
            } else if let p = program.protocols[target] {
                p.conformances.append(contentsOf: decl.inherits)
            }
        }
        // Stored layout, superclass first.
        var laidOut: Set<ObjectIdentifier> = []
        func layout(_ info: SwiftTypeInfo) {
            guard !laidOut.contains(ObjectIdentifier(info)) else { return }
            laidOut.insert(ObjectIdentifier(info))
            if let s = info.superclass {
                layout(s)
                info.stored = s.stored
                info.storedIndex = s.storedIndex
            }
            guard let decl = typeDecls.first(where: { $0.info === info })?.decl else { return }
            for prop in decl.properties where !prop.isStatic && prop.getter == nil {
                for name in prop.pattern.bindings {
                    info.storedIndex[name] = info.stored.count
                    let wrapper = prop.attributes.first { SwiftRuntime.cellWrappers.contains($0) }
                    info.stored.append(.init(name: name, type: prop.type, initializer: nil, isLet: prop.isLet, wrapper: wrapper))
                }
            }
            if info.kind == .enumType {
                var nextRaw = 0
                for c in decl.cases {
                    var raw: SwiftValue? = nil
                    if let rawType = info.rawType {
                        if let expr = c.rawValue {
                            switch expr {
                            case .intLit(let v): raw = .int(v); nextRaw = v + 1
                            case .doubleLit(let d): raw = .double(d)
                            case .stringLit(let parts):
                                raw = .string(parts.map { if case .text(let t) = $0 { return t } else { return "" } }.joined())
                            default: break
                            }
                        } else if rawType == "String" || rawType == "Character" {
                            raw = .string(c.name)
                        } else if rawType == "Double" {
                            raw = .double(Double(nextRaw)); nextRaw += 1
                        } else {
                            raw = .int(nextRaw); nextRaw += 1
                        }
                    }
                    info.caseIndex[c.name] = info.cases.count
                    info.cases.append(.init(name: c.name, labels: c.associated.map { $0.map(\.label) }, types: c.associated?.map(\.type) ?? [], rawValue: raw))
                }
                if info.rawType != nil, !info.conformances.contains("RawRepresentable") { info.conformances.append("RawRepresentable") }
            }
            if info.kind == .structType {
                info.hasMemberwiseInit = !decl.methods.contains { $0.isInit }
            }
        }
        for (_, info) in typeDecls where info.kind != .protocolType { layout(info) }

        // Mutating method names: a call with one of these names on a place writes back.
        for (decl, _) in typeDecls { for m in decl.methods where m.isMutating { mutatingNames.insert(m.name) } }
        for (decl, _) in extensions { for m in decl.methods where m.isMutating { mutatingNames.insert(m.name) } }
    }

    private func decls(for info: SwiftTypeInfo) -> [SwiftTypeDecl] {
        var result = typeDecls.filter { $0.info === info }.map(\.decl)
        for (decl, target) in extensions {
            if program.types[target] === info || program.protocols[target] === info
                || program.types[target.split(separator: ".").last.map(String.init) ?? target] === info
                || program.builtinExtensions[target] === info {
                result.append(decl)
            }
        }
        return result
    }

    /// Names a bare identifier inside `info`'s methods may mean as `self.name`.
    private func instanceMembers(_ info: SwiftTypeInfo) -> Set<String> {
        if let cached = instanceMemberCache[ObjectIdentifier(info)] { return cached }
        instanceMemberCache[ObjectIdentifier(info)] = []
        var names: Set<String> = Set(info.stored.map(\.name))
        for decl in decls(for: info) {
            for p in decl.properties where !p.isStatic { names.formUnion(p.pattern.bindings) }
            for m in decl.methods where !m.isStatic && !m.isInit { names.insert(m.name) }
        }
        if let s = info.superclass { names.formUnion(instanceMembers(s)) }
        for protoName in info.conformances {
            if let p = program.protocols[protoName] { names.formUnion(instanceMembers(p)) }
        }
        for name in Array(names) where info.storedIndex[name] != nil { names.insert("$" + name) }
        instanceMemberCache[ObjectIdentifier(info)] = names
        return names
    }

    private func staticMembers(_ info: SwiftTypeInfo) -> Set<String> {
        if let cached = staticMemberCache[ObjectIdentifier(info)] { return cached }
        staticMemberCache[ObjectIdentifier(info)] = []
        var names: Set<String> = Set(info.cases.map(\.name))
        for decl in decls(for: info) {
            for p in decl.properties where p.isStatic { names.formUnion(p.pattern.bindings) }
            for m in decl.methods where m.isStatic { names.insert(m.name) }
        }
        if let s = info.superclass { names.formUnion(staticMembers(s)) }
        staticMemberCache[ObjectIdentifier(info)] = names
        return names
    }

    // MARK: - Types, pass 2

    private func compileMembers(_ decl: SwiftTypeDecl, into info: SwiftTypeInfo) throws {
        for (alias, type) in decl.aliases { program.typeAliases[alias] = type }
        for prop in decl.properties {
            line = prop.line
            guard let name = prop.name else {
                if prop.isStatic { throw fail("static tuple patterns are not supported") }
                continue
            }
            if prop.isStatic {
                if let getter = prop.getter {
                    info.staticComputed[name] = try compileAccessor(getter, owner: info, isStatic: true, name: name, returnType: prop.type)
                } else if let initializer = prop.initializer {
                    let proto = try compileThunk(initializer, owner: info, isStatic: true, name: "\(info.name).\(name)", type: prop.type)
                    info.staticInitializers[name] = proto
                } else {
                    info.staticValues[name] = SwiftValue.none
                }
                continue
            }
            if let getter = prop.getter {
                let g = try compileAccessor(getter, owner: info, isStatic: false, name: name, returnType: prop.type)
                var s: SwiftProto? = nil
                if let setter = prop.setter {
                    s = try compileSetter(setter.name, setter.body, owner: info, name: name, type: prop.type)
                }
                info.computed[name] = (g, s)
                continue
            }
            guard let index = info.storedIndex[name] else { continue }
            if let initializer = prop.initializer {
                info.stored[index].initializer = try compileThunk(initializer, owner: info, isStatic: false, name: "\(info.name).\(name)", type: prop.type)
            }
            if let ws = prop.willSet {
                info.stored[index].willSet = try compileSetter(ws.name, ws.body, owner: info, name: name + ".willSet", type: prop.type)
            }
            if let ds = prop.didSet {
                info.stored[index].didSet = try compileSetter(ds.name, ds.body, owner: info, name: name + ".didSet", type: prop.type)
            }
        }
        for method in decl.methods where method.body != nil {
            line = method.line
            let proto = try compileFunction(method, owner: info, parent: nil, isMethod: true)
            if method.isInit {
                info.inits.append(proto)
            } else if method.isStatic {
                info.staticMethods[method.name, default: []].append(proto)
            } else {
                info.methods[method.name, default: []].append(proto)
            }
        }
        for sub in decl.subscripts {
            line = sub.line
            let proto = try compileFunction(sub, owner: info, parent: nil, isMethod: true)
            if sub.name == "subscript=" { info.subscriptSetters.append(proto) }
            else if sub.isStatic { info.staticMethods["subscript", default: []].append(proto) }
            else { info.subscriptGetters.append(proto) }
        }
    }

    private func withContext<T>(_ context: Context, _ body: () throws -> T) rethrows -> T {
        let saved = ctx
        let savedChains = chainStack
        ctx = context
        chainStack = []
        defer { ctx = saved; chainStack = savedChains }
        return try body()
    }

    private func methodContext(_ proto: SwiftProto, owner: SwiftTypeInfo?, isStatic: Bool, parent: Context?) -> Context {
        let c = Context(proto: proto, parent: parent, typeContext: owner, isStatic: isStatic)
        proto.owner = owner
        if owner != nil || isStatic {
            proto.hasSelf = true
            _ = c.declare("self", type: owner.map { .named($0.name, []) })
        }
        return c
    }

    private func compileThunk(_ expr: SwiftExpr, owner: SwiftTypeInfo, isStatic: Bool, name: String, type: SwiftTypeRef?) throws -> SwiftProto {
        let proto = SwiftProto(name: name)
        proto.returnType = type
        let c = methodContext(proto, owner: isStatic ? owner : nil, isStatic: isStatic, parent: nil)
        if !isStatic { proto.hasSelf = false }
        return try withContext(c) {
            try compileExpr(expr)
            if let type { emit(.coerce(type)) }
            emit(.returnValue)
            return proto
        }
    }

    private func compileAccessor(_ body: [SwiftStmt], owner: SwiftTypeInfo, isStatic: Bool, name: String, returnType: SwiftTypeRef?) throws -> SwiftProto {
        let proto = SwiftProto(name: "\(owner.name).\(name)")
        proto.returnType = returnType
        let c = methodContext(proto, owner: owner, isStatic: isStatic, parent: nil)
        c.builder = true
        return try withContext(c) {
            try compileBody(body, implicitReturn: true)
            return proto
        }
    }

    private func compileSetter(_ param: String, _ body: [SwiftStmt], owner: SwiftTypeInfo, name: String, type: SwiftTypeRef?) throws -> SwiftProto {
        let proto = SwiftProto(name: "\(owner.name).\(name)")
        proto.isMutating = owner.kind != .classType
        let c = methodContext(proto, owner: owner, isStatic: false, parent: nil)
        return try withContext(c) {
            let slot = c.declare(param, type: type)
            proto.params = [.init(label: nil, name: param, slot: slot, type: type, defaultValue: nil, isInout: false, isVariadic: false)]
            try compileBody(body, implicitReturn: false)
            return proto
        }
    }

    /// A func, method, init or subscript. `parent` is set for functions nested in a function.
    private func compileFunction(_ fn: SwiftFunctionDecl, owner: SwiftTypeInfo?, parent: Context?, isMethod: Bool) throws -> SwiftProto {
        let proto = SwiftProto(name: owner.map { "\($0.name).\(fn.name)" } ?? fn.name)
        proto.returnType = fn.returnType
        proto.isMutating = fn.isMutating || (fn.isInit && owner?.kind != .classType)
        proto.isInit = fn.isInit
        proto.isFailable = fn.isFailable
        proto.isStatic = fn.isStatic
        proto.throwsErrors = fn.throwsErrors
        let c = isMethod
            ? methodContext(proto, owner: owner, isStatic: fn.isStatic, parent: parent)
            : Context(proto: proto, parent: parent, typeContext: parent?.typeContext, isStatic: parent?.isStatic ?? false)
        if !isMethod { proto.owner = parent?.typeContext }
        let returnsView: Bool = {
            if fn.attributes.contains("ViewBuilder") { return true }
            if case .named(let n, _)? = fn.returnType, n == "View" || n == "Scene" { return true }
            return false
        }()
        c.builder = returnsView
        return try withContext(c) {
            for param in fn.params {
                // Default values evaluate in their own context: they cannot see other parameters.
                var defaultProto: SwiftProto? = nil
                if let def = param.defaultValue {
                    let d = SwiftProto(name: "\(proto.name).\(param.name)=")
                    let dc = Context(proto: d, parent: nil, typeContext: owner, isStatic: true)
                    d.owner = owner
                    try withContext(dc) {
                        try compileExpr(def)
                        emit(.returnValue)
                    }
                    defaultProto = d
                }
                let slot = c.declare(param.name, type: param.isVariadic ? param.type.map { .array($0) } : param.type)
                proto.params.append(.init(label: param.label, name: param.name, slot: slot, type: param.type,
                                          defaultValue: defaultProto, isInout: param.isInout, isVariadic: param.isVariadic))
            }
            try compileBody(fn.body ?? [], implicitReturn: !fn.isInit && fn.returnType != nil)
            return proto
        }
    }

    private func compileClosure(_ closure: SwiftClosure) throws -> SwiftProto {
        let proto = SwiftProto(name: "closure")
        proto.isClosure = true
        proto.owner = ctx.typeContext
        let c = Context(proto: proto, parent: ctx, typeContext: ctx.typeContext, isStatic: ctx.isStatic)
        c.builder = true
        return try withContext(c) {
            var params = closure.params
            if params.isEmpty {
                let count = Self.dollarCount(closure.body)
                params = (0..<count).map { SwiftParam(label: nil, name: "$\($0)") }
            }
            for param in params {
                let slot = c.declare(param.name, type: param.type)
                proto.params.append(.init(label: nil, name: param.name, slot: slot, type: param.type,
                                          defaultValue: nil, isInout: param.isInout, isVariadic: false))
            }
            line = closure.line
            try compileBody(closure.body, implicitReturn: true)
            return proto
        }
    }

    /// How many `$n` parameters an anonymous closure body uses.
    private static func dollarCount(_ body: [SwiftStmt]) -> Int {
        var maxIndex = -1
        func visitExpr(_ e: SwiftExpr) {
            switch e {
            case .identifier(let n, _):
                if n.hasPrefix("$"), let i = Int(n.dropFirst()) { maxIndex = max(maxIndex, i) }
            case .member(let b, _, _), .optionalChain(let b), .forceUnwrap(let b, _), .postfixRange(let b),
                 .prefix(_, let b, _), .tryExpr(_, let b), .isType(let b, _), .cast(let b, _, _):
                visitExpr(b)
            case .call(let f, let args, _), .subscriptAccess(let f, let args, _):
                visitExpr(f)
                for a in args { visitExpr(a.value) }
            case .binary(_, let a, let b, _), .assign(_, let a, let b, _):
                visitExpr(a); visitExpr(b)
            case .ternary(let a, let b, let c):
                visitExpr(a); visitExpr(b); visitExpr(c)
            case .arrayLit(let items): items.forEach(visitExpr)
            case .dictionaryLit(let pairs): pairs.forEach { visitExpr($0.0); visitExpr($0.1) }
            case .tuple(let items): items.forEach { visitExpr($0.value) }
            case .stringLit(let parts): for case .expr(let x) in parts { visitExpr(x) }
            case .ifExpr(let s): visitStmt(s)
            default: break
            }
        }
        func visitConds(_ conds: [SwiftCondition]) {
            for c in conds {
                switch c {
                case .expr(let e), .optionalBinding(_, let e), .pattern(_, let e): visitExpr(e)
                }
            }
        }
        func visitStmt(_ s: SwiftStmt) {
            switch s {
            case .expr(let e, _), .throwStmt(let e, _): visitExpr(e)
            case .returnStmt(let e, _): if let e { visitExpr(e) }
            case .variable(let v): if let i = v.initializer { visitExpr(i) }
            case .ifStmt(let c, let a, let b, _): visitConds(c); a.forEach(visitStmt); b?.forEach(visitStmt)
            case .guardStmt(let c, let a, _): visitConds(c); a.forEach(visitStmt)
            case .whileStmt(let c, let a, _, _): visitConds(c); a.forEach(visitStmt)
            case .repeatWhile(let a, let e, _, _): a.forEach(visitStmt); visitExpr(e)
            case .forIn(_, let e, let w, let a, _, _): visitExpr(e); if let w { visitExpr(w) }; a.forEach(visitStmt)
            case .switchStmt(let e, let cases, _, _): visitExpr(e); cases.forEach { $0.body.forEach(visitStmt) }
            case .doCatch(let a, let cs, _): a.forEach(visitStmt); cs.forEach { $0.body.forEach(visitStmt) }
            case .block(let a), .deferStmt(let a): a.forEach(visitStmt)
            default: break
            }
        }
        body.forEach(visitStmt)
        return maxIndex + 1
    }

    /// A function body: statements, then the implicit end. A body that is one expression returns
    /// it; so does one whose only statement is an `if`/`switch` of expressions (SE-0380).
    private func compileBody(_ body: [SwiftStmt], implicitReturn: Bool) throws {
        if implicitReturn, body.count == 1 {
            switch body[0] {
            case .expr(let e, let l):
                if case .assign = e { break }
                line = l
                try compileExpr(e)
                emit(.returnValue)
                return
            case .ifStmt, .switchStmt:
                if isExpressionBranching(body[0]) {
                    try compileIfExpression(body[0])
                    emit(.returnValue)
                    return
                }
            default:
                break
            }
        }
        for stmt in body { try compileStatement(stmt) }
        try emitDefers(downTo: 0)
        emit(.fallOff)
        emit(.returnValue)
    }

    /// Whether every branch of an `if`/`switch` ends in a value (so it can be an expression).
    private func isExpressionBranching(_ stmt: SwiftStmt) -> Bool {
        func branchOK(_ body: [SwiftStmt]?) -> Bool {
            guard let body, body.count == 1 else { return false }
            switch body[0] {
            case .expr(let e, _):
                if case .assign = e { return false }
                return true
            case .ifStmt, .switchStmt: return isExpressionBranching(body[0])
            case .throwStmt: return true
            default: return false
            }
        }
        switch stmt {
        case .ifStmt(_, let then, let els, _): return branchOK(then) && branchOK(els)
        case .switchStmt(_, let cases, _, _): return !cases.isEmpty && cases.allSatisfy { branchOK($0.body) }
        default: return false
        }
    }

    // MARK: - Statements

    private func pushScope() {
        ctx.scopes.append([:])
        ctx.defers.append([])
    }

    private func popScope() throws {
        if let defers = ctx.defers.last {
            for body in defers.reversed() { try compileBlockInline(body) }
        }
        ctx.scopes.removeLast()
        ctx.defers.removeLast()
    }

    private func compileBlockInline(_ stmts: [SwiftStmt]) throws {
        pushScope()
        for s in stmts { try compileStatement(s) }
        try popScope()
    }

    /// Run the defer blocks of every scope deeper than `depth` (on return/break/continue).
    private func emitDefers(downTo depth: Int) throws {
        guard ctx.defers.count > depth else { return }
        let saved = ctx.defers
        for level in stride(from: ctx.defers.count - 1, through: depth, by: -1) {
            for body in saved[level].reversed() {
                // A defer body must not re-run itself while being inlined.
                ctx.defers = Array(saved.prefix(level)) + [[]]
                try compileBlockInline(body)
            }
        }
        ctx.defers = saved
    }

    private func compileBlock(_ stmts: [SwiftStmt]) throws {
        pushScope()
        for s in stmts { try compileStatement(s) }
        try popScope()
    }

    private var isGlobalScope: Bool { ctx.isTopLevel && ctx.scopes.count == 1 }

    func compileStatement(_ stmt: SwiftStmt) throws {
        switch stmt {
        case .empty:
            return
        case .typeAlias(let name, let type):
            program.typeAliases[name] = type
        case .expr(let e, let l):
            line = l
            if case .assign(let op, let target, let value, let al) = e {
                line = al
                try compileAssign(op, target, value)
                return
            }
            try compileExpr(e)
            emit(ctx.builder ? .collect : .pop)
        case .variable(let v):
            try compileVariable(v)
        case .block(let stmts):
            // A multi-binding declaration (`let a = 1, b = 2`) shares the enclosing scope.
            if stmts.allSatisfy({ if case .variable = $0 { return true } else { return false } }) {
                for s in stmts { try compileStatement(s) }
            } else {
                try compileBlock(stmts)
            }
        case .ifStmt(let conds, let then, let els, let l):
            line = l
            pushScope()
            var failures: [Int] = []
            try compileConditions(conds, failures: &failures)
            for s in then { try compileStatement(s) }
            try popScope()
            if let els {
                let skip = emit(.jump(0))
                for f in failures { patch(f) }
                try compileBlock(els)
                patch(skip)
            } else {
                for f in failures { patch(f) }
            }
        case .guardStmt(let conds, let body, let l):
            line = l
            var failures: [Int] = []
            try compileConditions(conds, failures: &failures)
            let skip = emit(.jump(0))
            for f in failures { patch(f) }
            try compileBlock(body)
            emit(.fail("guard body must not fall through"))
            patch(skip)
        case .whileStmt(let conds, let body, let label, let l):
            line = l
            let top = here
            let loop = LoopContext(label: label, isSwitch: false, scopeDepth: ctx.defers.count, handlerDepth: ctx.handlerDepth)
            loop.continueTarget = top
            ctx.loops.append(loop)
            pushScope()
            var failures: [Int] = []
            try compileConditions(conds, failures: &failures)
            for s in body { try compileStatement(s) }
            try popScope()
            emit(.jump(top))
            for f in failures { patch(f) }
            ctx.loops.removeLast()
            for b in loop.breaks { patch(b) }
        case .repeatWhile(let body, let cond, let label, let l):
            line = l
            let top = here
            let loop = LoopContext(label: label, isSwitch: false, scopeDepth: ctx.defers.count, handlerDepth: ctx.handlerDepth)
            ctx.loops.append(loop)
            try compileBlock(body)
            let condStart = here
            for c in loop.continues { patch(c, condStart) }
            try compileExpr(cond)
            emit(.jumpIfTrue(top))
            ctx.loops.removeLast()
            for b in loop.breaks { patch(b) }
        case .forIn(let pattern, let seq, let whereExpr, let body, let label, let l):
            line = l
            try compileExpr(seq)
            emit(.makeIterator)
            let iterSlot = ctx.temp()
            emit(.storeLocal(iterSlot))
            let top = here
            let next = emit(.iterate(slot: iterSlot, exit: 0))
            let loop = LoopContext(label: label, isSwitch: false, scopeDepth: ctx.defers.count, handlerDepth: ctx.handlerDepth)
            loop.continueTarget = top
            ctx.loops.append(loop)
            pushScope()
            let valueSlot = ctx.temp()
            emit(.storeLocal(valueSlot))
            var failures: [Int] = []
            try compilePatternTest(pattern, slot: valueSlot, failures: &failures, declare: true)
            if let whereExpr {
                try compileExpr(whereExpr)
                failures.append(emit(.jumpIfFalse(0)))
            }
            for s in body { try compileStatement(s) }
            try popScope()
            emit(.jump(top))
            for f in failures { patch(f, top) }
            ctx.loops.removeLast()
            patch(next)
            for b in loop.breaks { patch(b) }
        case .switchStmt(let subject, let cases, let label, let l):
            line = l
            try compileSwitch(subject, cases, label: label, asExpression: false)
        case .returnStmt(let value, let l):
            line = l
            if let value {
                try compileExpr(value)
            } else {
                emitConstant(.void)
            }
            try emitDefers(downTo: 0)
            emit(.returnValue)
        case .breakStmt(let label, let l):
            line = l
            guard let loop = findLoop(label, forContinue: false) else { throw fail("'break' is only allowed inside a loop, if, do, or switch") }
            try emitDefers(downTo: loop.scopeDepth)
            for _ in loop.handlerDepth..<max(loop.handlerDepth, ctx.handlerDepth) { emit(.popHandler) }
            loop.breaks.append(emit(.jump(0)))
        case .continueStmt(let label, let l):
            line = l
            guard let loop = findLoop(label, forContinue: true) else { throw fail("'continue' is only allowed inside a loop") }
            try emitDefers(downTo: loop.scopeDepth)
            for _ in loop.handlerDepth..<max(loop.handlerDepth, ctx.handlerDepth) { emit(.popHandler) }
            if let target = loop.continueTarget { emit(.jump(target)) } else { loop.continues.append(emit(.jump(0))) }
        case .fallthroughStmt(let l):
            line = l
            ctx.fallthroughTargets.append(emit(.jump(0)))
        case .throwStmt(let e, let l):
            line = l
            try compileExpr(e)
            emit(.throwError)
        case .doCatch(let body, let catches, let l):
            line = l
            try compileDoCatch(body, catches)
        case .deferStmt(let body):
            ctx.defers[ctx.defers.count - 1].append(body)
        case .function(let fn):
            line = fn.line
            let slot = ctx.declare(fn.name)
            emitConstant(.none)
            emit(.storeLocal(slot))
            let proto = try compileFunction(fn, owner: nil, parent: ctx, isMethod: false)
            emit(.makeClosure(proto))
            emit(.assignLocal(slot))
        case .type(let decl):
            // A type declared inside a function body.
            line = decl.line
            let before = typeDecls.count
            try declareType(decl, outer: nil)
            try linkTypes()
            for (d, info) in typeDecls[before...] { try compileMembers(d, into: info) }
        }
    }

    private func findLoop(_ label: String?, forContinue: Bool) -> LoopContext? {
        for loop in ctx.loops.reversed() {
            if let label {
                if loop.label == label { return loop }
                continue
            }
            if forContinue && loop.isSwitch { continue }
            return loop
        }
        return nil
    }

    private func compileVariable(_ v: SwiftVariableDecl) throws {
        line = v.line
        if v.getter != nil {
            throw fail("computed variables are only supported as type members")
        }
        if case .binding(let name) = v.pattern {
            if let initializer = v.initializer {
                try compileExpr(initializer)
                if let t = v.type { emit(.coerce(t)) }
            } else {
                emitConstant(.none)
            }
            if isGlobalScope {
                emit(.storeGlobal(program.global(named: name)))
            } else {
                let slot = ctx.declare(name, type: v.type)
                emit(.storeLocal(slot))
            }
            return
        }
        guard let initializer = v.initializer else { throw fail("pattern binding needs an initializer") }
        try compileExpr(initializer)
        if let t = v.type { emit(.coerce(t)) }
        let tmp = ctx.temp()
        emit(.storeLocal(tmp))
        var failures: [Int] = []
        try compilePatternTest(v.pattern, slot: tmp, failures: &failures, declare: true)
        if !failures.isEmpty {
            let ok = emit(.jump(0))
            for f in failures { patch(f) }
            emit(.fail("pattern did not match"))
            patch(ok)
        }
    }

    /// Bind a declared name: a global at the top level, a local everywhere else.
    private func bindName(_ name: String) {
        if isGlobalScope {
            emit(.storeGlobal(program.global(named: name)))
        } else {
            emit(.storeLocal(ctx.declare(name)))
        }
    }

    private func compileConditions(_ conds: [SwiftCondition], failures: inout [Int]) throws {
        for cond in conds {
            switch cond {
            case .expr(let e):
                try compileExpr(e)
                failures.append(emit(.jumpIfFalse(0)))
            case .optionalBinding(let name, let e):
                try compileExpr(e)
                failures.append(emit(.unwrapOrJump(0)))
                emit(.storeLocal(ctx.declare(name)))
            case .pattern(let p, let e):
                try compileExpr(e)
                let tmp = ctx.temp()
                emit(.storeLocal(tmp))
                try compilePatternTest(p, slot: tmp, failures: &failures, declare: true)
            }
        }
    }

    /// Test the value in `slot` against `pattern`, binding names as it goes. Failing tests jump
    /// (with a balanced stack) to sites appended to `failures`.
    private func compilePatternTest(_ pattern: SwiftPattern, slot: Int, failures: inout [Int], declare: Bool,
                                    bindings: [String: Int]? = nil) throws {
        switch pattern {
        case .wildcard:
            return
        case .binding(let name):
            emit(.loadLocal(slot))
            if let target = bindings?[name] {
                emit(.storeLocal(target))
            } else if ctx.isTopLevel && ctx.scopes.count == 1 {
                emit(.storeGlobal(program.global(named: name)))
            } else {
                emit(.storeLocal(ctx.declare(name)))
            }
        case .expr(let e):
            // `case x` against a name that is not in scope is not an expression but a mistake;
            // an identifier that resolves compiles as an equality test.
            try compileExpr(e)
            emit(.loadLocal(slot))
            emit(.patternMatch)
            failures.append(emit(.jumpIfFalse(0)))
        case .tuple(let parts):
            for (i, part) in parts.enumerated() {
                if case .wildcard = part { continue }
                emit(.loadLocal(slot))
                emit(.tupleElement(i))
                let tmp = ctx.temp()
                emit(.storeLocal(tmp))
                try compilePatternTest(part, slot: tmp, failures: &failures, declare: declare, bindings: bindings)
            }
        case .enumCase(let name, let subs):
            emit(.loadLocal(slot))
            emit(.enumCaseIs(name))
            failures.append(emit(.jumpIfFalse(0)))
            guard let subs else { return }
            for (i, sub) in subs.enumerated() {
                if case .wildcard = sub { continue }
                emit(.loadLocal(slot))
                if name == "some" { emit(.forceUnwrap) } else { emit(.enumPayload(i)) }
                let tmp = ctx.temp()
                emit(.storeLocal(tmp))
                try compilePatternTest(sub, slot: tmp, failures: &failures, declare: declare, bindings: bindings)
            }
        case .optionalSome(let inner):
            emit(.loadLocal(slot))
            emit(.isSome)
            failures.append(emit(.jumpIfFalse(0)))
            emit(.loadLocal(slot))
            emit(.forceUnwrap)
            let tmp = ctx.temp()
            emit(.storeLocal(tmp))
            try compilePatternTest(inner, slot: tmp, failures: &failures, declare: declare, bindings: bindings)
        case .isType(let t):
            emit(.loadLocal(slot))
            emit(.typeCheck(t))
            failures.append(emit(.jumpIfFalse(0)))
        case .asType(let inner, let t):
            emit(.loadLocal(slot))
            emit(.typeCheck(t))
            failures.append(emit(.jumpIfFalse(0)))
            emit(.loadLocal(slot))
            emit(.cast(t, "as"))
            let tmp = ctx.temp()
            emit(.storeLocal(tmp))
            try compilePatternTest(inner, slot: tmp, failures: &failures, declare: declare, bindings: bindings)
        }
    }

    private func compileSwitch(_ subject: SwiftExpr, _ cases: [SwiftSwitchCase], label: String?, asExpression: Bool) throws {
        try compileExpr(subject)
        let subjectSlot = ctx.temp()
        emit(.storeLocal(subjectSlot))
        let loop = LoopContext(label: label, isSwitch: true, scopeDepth: ctx.defers.count, handlerDepth: ctx.handlerDepth)
        ctx.loops.append(loop)
        var ends: [Int] = []
        var pendingFallthrough: [Int] = []
        var nextCase: [Int] = []
        for c in cases {
            for f in nextCase { patch(f) }
            nextCase = []
            pushScope()
            var bindings: [String: Int] = [:]
            if let first = c.patterns.first {
                for name in first.bindings { bindings[name] = ctx.declare(name) }
            }
            var bodyJumps: [Int] = []
            if !c.isDefault {
                for pattern in c.patterns {
                    var failures: [Int] = []
                    try compilePatternTest(pattern, slot: subjectSlot, failures: &failures, declare: false, bindings: bindings)
                    bodyJumps.append(emit(.jump(0)))
                    for f in failures { patch(f) }
                }
                nextCase.append(emit(.jump(0)))
            }
            for j in bodyJumps { patch(j) }
            if let g = c.guardExpr {
                try compileExpr(g)
                nextCase.append(emit(.jumpIfFalse(0)))
            }
            for f in pendingFallthrough { patch(f) }
            pendingFallthrough = []
            let savedFall = ctx.fallthroughTargets
            ctx.fallthroughTargets = []
            if asExpression {
                try compileBranchValue(c.body)
            } else {
                for s in c.body { try compileStatement(s) }
            }
            pendingFallthrough = ctx.fallthroughTargets
            ctx.fallthroughTargets = savedFall
            try popScope()
            ends.append(emit(.jump(0)))
        }
        for f in nextCase { patch(f) }
        emit(.fail("unhandled case in switch"))
        for f in pendingFallthrough { patch(f) }
        ctx.loops.removeLast()
        for e in ends { patch(e) }
        for b in loop.breaks { patch(b) }
    }

    private func compileDoCatch(_ body: [SwiftStmt], _ catches: [SwiftCatchClause]) throws {
        guard !catches.isEmpty else {
            try compileBlock(body)
            return
        }
        let handler = emit(.pushHandler(0))
        ctx.handlerDepth += 1
        try compileBlock(body)
        ctx.handlerDepth -= 1
        emit(.popHandler)
        let done = emit(.jump(0))
        patch(handler)
        let errorSlot = ctx.temp()
        emit(.storeLocal(errorSlot))
        var ends: [Int] = []
        for clause in catches {
            pushScope()
            var failures: [Int] = []
            if let pattern = clause.pattern {
                try compilePatternTest(pattern, slot: errorSlot, failures: &failures, declare: true)
            } else {
                emit(.loadLocal(errorSlot))
                emit(.storeLocal(ctx.declare("error")))
            }
            if let g = clause.guardExpr {
                try compileExpr(g)
                failures.append(emit(.jumpIfFalse(0)))
            }
            // A pattern clause still names the error `error` inside its body only if unbound.
            for s in clause.body { try compileStatement(s) }
            try popScope()
            ends.append(emit(.jump(0)))
            for f in failures { patch(f) }
        }
        emit(.loadLocal(errorSlot))
        emit(.throwError)
        patch(done)
        for e in ends { patch(e) }
    }

    // MARK: - Names

    private func resolve(_ name: String) throws -> Resolution {
        if name == "Self", let type = ctx.typeContext { return .value(.type(type)) }
        if let local = ctx.lookupLocal(name) { return .local(local.slot, local.type) }
        if let up = resolveUpvalue(name, in: ctx) { return .upvalue(up.index, up.type) }
        if let type = ctx.typeContext {
            if !ctx.isStatic, instanceMembers(type).contains(name), hasSelfInScope() { return .selfMember }
            if staticMembers(type).contains(name) { return .staticMember(type) }
            var t: SwiftTypeInfo? = type
            while let current = t {
                if let nested = current.nested[name] { return .value(.type(nested)) }
                t = current.superclass
            }
        }
        if let i = program.globalIndex[name] { return .global(i, globalTypes[name]) }
        if let t = program.types[name] { return .value(.type(t)) }
        if let p = program.protocols[name] { return .value(.type(p)) }
        if let builtin = SwiftRuntime.globalValue(name) { return .value(builtin) }
        // Inside an extension of a builtin type or a protocol, `self`'s members include the
        // whole standard library surface (`uppercased()` in `extension String`), which the
        // compiler has no declarations for.
        if let type = ctx.typeContext, type.kind == .builtinExtension || type.kind == .protocolType,
           !ctx.isStatic, hasSelfInScope() {
            return .selfMember
        }
        throw fail("cannot find '\(name)' in scope")
    }

    private func hasSelfInScope() -> Bool {
        var c: Context? = ctx
        while let current = c {
            if current.lookupLocal("self") != nil { return true }
            c = current.parent
        }
        return false
    }

    private func resolveUpvalue(_ name: String, in context: Context) -> (index: Int, type: SwiftTypeRef?)? {
        if let cached = context.upvalues[name] { return cached }
        guard let parent = context.parent else { return nil }
        let capture: SwiftProto.Capture
        let type: SwiftTypeRef?
        if let local = parent.lookupLocal(name) {
            capture = .local(local.slot)
            type = local.type
        } else if let up = resolveUpvalue(name, in: parent) {
            capture = .upvalue(up.index)
            type = up.type
        } else {
            return nil
        }
        context.proto.captures.append(capture)
        let entry = (index: context.proto.captures.count - 1, type: type)
        context.upvalues[name] = entry
        return entry
    }

    private func emitLoadSelf() throws {
        switch try resolve("self") {
        case .local(let slot, _): emit(.loadLocal(slot))
        case .upvalue(let i, _): emit(.loadUpvalue(i))
        default: throw fail("'self' is not available here")
        }
    }

    private func emitLoad(_ name: String) throws {
        if name == "Self" {
            emit(.loadSelfType)
            return
        }
        switch try resolve(name) {
        case .local(let slot, _): emit(.loadLocal(slot))
        case .upvalue(let i, _): emit(.loadUpvalue(i))
        case .global(let i, _): emit(.loadGlobal(i))
        case .selfMember:
            try emitLoadSelf()
            emit(.getMember(name))
        case .staticMember(let t):
            emitConstant(.type(t))
            emit(.getMember(name))
        case .value(let v):
            emitConstant(v)
        }
    }

    // MARK: - Places

    private struct Place {
        var root: SwiftRoot
        var steps: [SwiftPathStep]
        var keys: [SwiftExpr]
        var rootType: SwiftTypeRef?
    }

    private func place(_ expr: SwiftExpr) throws -> Place? {
        switch expr {
        case .identifier(let name, _):
            switch try resolve(name) {
            case .local(let slot, let t): return Place(root: .local(slot), steps: [], keys: [], rootType: t)
            case .upvalue(let i, let t): return Place(root: .upvalue(i), steps: [], keys: [], rootType: t)
            case .global(let i, let t): return Place(root: .global(i), steps: [], keys: [], rootType: t)
            case .selfMember:
                guard var p = try place(.selfRef) else { return nil }
                p.steps.append(.member(name))
                p.rootType = nil
                return p
            case .staticMember(let t):
                return Place(root: .constant(constant(.type(t))), steps: [.member(name)], keys: [], rootType: nil)
            case .value(let v):
                if case .type = v { return Place(root: .constant(constant(v)), steps: [], keys: [], rootType: nil) }
                return nil
            }
        case .selfRef:
            switch try resolve("self") {
            case .local(let slot, let t): return Place(root: .local(slot), steps: [], keys: [], rootType: t)
            case .upvalue(let i, let t): return Place(root: .upvalue(i), steps: [], keys: [], rootType: t)
            default: return nil
            }
        case .member(let base, let name, _):
            if case .identifier(let n, _) = base, n == "Self" {
                return Place(root: .selfType, steps: [.member(name)], keys: [], rootType: nil)
            }
            guard var p = try place(base) else { return nil }
            p.steps.append(.member(name))
            return p
        case .subscriptAccess(let base, let args, _):
            guard var p = try place(base) else { return nil }
            p.steps.append(.index(argc: args.count, labels: args.map(\.label)))
            p.keys += args.map(\.value)
            return p
        case .forceUnwrap(let base, _):
            guard var p = try place(base) else { return nil }
            p.steps.append(.unwrap)
            return p
        case .optionalChain(let base):
            guard var p = try place(base) else { return nil }
            p.steps.append(.chain)
            return p
        default:
            return nil
        }
    }

    private func emitKeys(_ p: Place) throws {
        for k in p.keys { try compileExpr(k) }
    }

    /// Store the value on top of the stack into `p` (keys are emitted before the value).
    private func emitStoreSimple(_ p: Place) {
        switch p.root {
        case .local(let slot): emit(.assignLocal(slot))
        case .upvalue(let i): emit(.storeUpvalue(i))
        case .global(let i): emit(.storeGlobal(i))
        default: emit(.storePath(p.root, [], coerce: nil))
        }
    }

    private func compileAssign(_ op: String, _ target: SwiftExpr, _ value: SwiftExpr) throws {
        if op == "=" {
            if case .identifier("_", _) = target {
                try compileExpr(value)
                emit(.pop)
                return
            }
            if case .tuple(let targets) = target {
                try compileExpr(value)
                let tmp = ctx.temp()
                emit(.storeLocal(tmp))
                for (i, t) in targets.enumerated() {
                    if case .identifier("_", _) = t.value { continue }
                    guard let p = try place(t.value) else { throw fail("cannot assign to this expression") }
                    try emitKeys(p)
                    emit(.loadLocal(tmp))
                    emit(.tupleElement(i))
                    try emitStore(p)
                }
                return
            }
        }
        guard let p = try place(target) else { throw fail("cannot assign to this expression") }
        if op == "=" {
            try emitKeys(p)
            try compileExpr(value)
            try emitStore(p)
            return
        }
        if op == "??=" {
            throw fail("'??=' is not supported")
        }
        try emitKeys(p)
        try compileExpr(value)
        emit(.modifyPath(p.root, p.steps, String(op.dropLast())))
    }

    private func emitStore(_ p: Place) throws {
        if p.steps.isEmpty {
            if let t = p.rootType { emit(.coerce(t)) }
            if case .local(let slot) = p.root, slot == 0, ctx.lookupLocal("self")?.slot == 0, let owner = ctx.typeContext {
                emit(.coerce(.named(owner.name, [])))
            }
            emitStoreSimple(p)
        } else {
            emit(.storePath(p.root, p.steps, coerce: nil))
        }
    }

    // MARK: - Expressions

    private func containsChain(_ e: SwiftExpr) -> Bool {
        switch e {
        case .optionalChain: return true
        case .member(let b, _, _), .forceUnwrap(let b, _): return containsChain(b)
        case .call(let f, _, _): return containsChain(f)
        case .subscriptAccess(let b, _, _): return containsChain(b)
        default: return false
        }
    }

    func compileExpr(_ e: SwiftExpr) throws {
        switch e {
        case .member, .call, .subscriptAccess, .forceUnwrap:
            if containsChain(e) && (chainStack.isEmpty || chainStack.last == nil) {
                chainStack.append([])
                try compilePostfix(e)
                emit(.wrapOptional)
                let jumps = chainStack.removeLast()
                for j in jumps { patch(j) }
                return
            }
            try compilePostfix(e)
        case .optionalChain:
            // A bare `a?` outside member access is just the optional.
            if chainStack.isEmpty {
                chainStack.append([])
                try compilePostfix(e)
                emit(.wrapOptional)
                for j in chainStack.removeLast() { patch(j) }
                return
            }
            try compilePostfix(e)
        default:
            try compileSimple(e)
        }
    }

    /// Compile a sub-expression that starts a fresh optional-chain context (an argument, an
    /// index), so a chain inside it cannot jump out to the enclosing chain's end.
    private func compileIsolated(_ e: SwiftExpr) throws {
        let saved = chainStack
        chainStack = []
        defer { chainStack = saved }
        try compileExpr(e)
    }

    private func compilePostfix(_ e: SwiftExpr) throws {
        switch e {
        case .optionalChain(let inner):
            try compilePostfix(inner)
            if chainStack.isEmpty { return }
            chainStack[chainStack.count - 1].append(emit(.chainJump(0)))
        case .member(let base, let name, let l):
            line = l
            try compilePostfixOrSimple(base)
            emit(.getMember(name))
        case .subscriptAccess(let base, let args, let l):
            line = l
            try compilePostfixOrSimple(base)
            for a in args { try compileIsolated(a.value) }
            emit(.getIndex(argc: args.count, labels: args.map(\.label)))
        case .forceUnwrap(let base, let l):
            line = l
            try compilePostfixOrSimple(base)
            emit(.forceUnwrap)
        case .call(let callee, let args, let l):
            line = l
            try compileCall(callee, args)
        default:
            try compileSimple(e)
        }
    }

    private func compilePostfixOrSimple(_ e: SwiftExpr) throws {
        switch e {
        case .member, .call, .subscriptAccess, .forceUnwrap, .optionalChain:
            try compilePostfix(e)
        default:
            try compileSimple(e)
        }
    }

    private func isTypeName(_ e: SwiftExpr) -> Bool {
        switch e {
        case .identifier(let name, _):
            if name == "Self" { return true }
            if ctx.lookupLocal(name) != nil { return false }
            if name.first?.isUppercase == true, (try? resolve(name)).map({ r -> Bool in
                if case .value(let v) = r {
                    switch v {
                    case .type, .builtinType: return true
                    default: return false
                    }
                }
                return false
            }) == true { return true }
            return false
        case .typeExpr: return true
        case .member(let base, let name, _): return name.first?.isUppercase == true && isTypeName(base)
        default: return false
        }
    }

    /// Arguments; returns the inout places to write back after the call.
    private func compileArguments(_ args: [SwiftArgument]) throws -> [(Int, Place)] {
        var inouts: [(Int, Place)] = []
        for (i, arg) in args.enumerated() {
            if arg.isInout {
                guard let p = try place(arg.value) else { throw fail("cannot pass immutable value as inout argument") }
                inouts.append((i, p))
            }
            if case .closure(let c) = arg.value {
                emit(.makeClosure(try compileClosure(c)))
            } else {
                try compileIsolated(arg.value)
            }
        }
        return inouts
    }

    private func writeBack(_ inouts: [(Int, Place)]) throws {
        for (_, p) in inouts {
            try emitKeys(p)
            emit(.popInout)
            try emitStore(p)
        }
    }

    private func compileCall(_ callee: SwiftExpr, _ args: [SwiftArgument]) throws {
        let labels = args.map(\.label)
        switch callee {
        case .member(.selfRef, "init", let l):
            // Initializer delegation. A class re-runs an init on the object being built; a
            // value type builds a fresh value and assigns it to `self`.
            line = l
            if ctx.typeContext?.kind == .classType {
                try emitLoadSelf()
                _ = try compileArguments(args)
                emit(.invoke("init", argc: args.count, labels: labels, inouts: []))
                return
            }
            emit(.loadSelfType)
            _ = try compileArguments(args)
            emit(.invoke("init", argc: args.count, labels: labels, inouts: []))
            guard let p = try place(.selfRef) else { throw fail("'self.init' outside an initializer") }
            emitStoreSimple(p)
            emitConstant(.void)
        case .member(let base, let name, let l):
            line = l
            if !isTypeName(base), mutatingNames.contains(name), let p = try place(base) {
                try emitKeys(p)
                _ = try compileArguments(args)
                emit(.mutatePath(p.root, p.steps, name, argc: args.count, labels: labels))
                if containsChain(base) { emit(.wrapOptional) }
                return
            }
            if case .superMember = base {
                throw fail("unsupported super expression")
            }
            try compilePostfixOrSimple(base)
            let inouts = try compileArguments(args)
            emit(.invoke(name, argc: args.count, labels: labels, inouts: inouts.map(\.0)))
            try writeBack(inouts)
        case .identifier(let name, let l):
            line = l
            switch try resolve(name) {
            case .selfMember:
                if mutatingNames.contains(name), let p = try place(.selfRef) {
                    _ = try compileArguments(args)
                    emit(.mutatePath(p.root, [], name, argc: args.count, labels: labels))
                    return
                }
                try emitLoadSelf()
                let inouts = try compileArguments(args)
                emit(.invoke(name, argc: args.count, labels: labels, inouts: inouts.map(\.0)))
                try writeBack(inouts)
            case .staticMember(let t):
                emitConstant(.type(t))
                let inouts = try compileArguments(args)
                emit(.invoke(name, argc: args.count, labels: labels, inouts: inouts.map(\.0)))
                try writeBack(inouts)
            default:
                try emitLoad(name)
                let inouts = try compileArguments(args)
                emit(.call(argc: args.count, labels: labels, inouts: inouts.map(\.0)))
                try writeBack(inouts)
            }
        case .superMember(let name):
            try emitLoadSelf()
            _ = try compileArguments(args)
            emit(.superInvoke(name, argc: args.count, labels: labels))
        case .implicitMember(let name):
            _ = try compileArguments(args)
            emit(.makeUnresolved(name, argc: args.count, labels: labels))
        case .selfRef:
            // `self.init(...)` style delegation is written `self.init`; a bare `self(...)` is not Swift.
            throw fail("cannot call 'self'")
        default:
            try compilePostfixOrSimple(callee)
            let inouts = try compileArguments(args)
            emit(.call(argc: args.count, labels: labels, inouts: inouts.map(\.0)))
            try writeBack(inouts)
        }
    }

    private func compileSimple(_ e: SwiftExpr) throws {
        switch e {
        case .intLit(let v): emitConstant(.int(v))
        case .doubleLit(let v): emitConstant(.double(v))
        case .boolLit(let v): emitConstant(.bool(v))
        case .nilLit: emitConstant(.none)
        case .stringLit(let parts):
            if parts.isEmpty { emitConstant(.string("")); return }
            if parts.count == 1, case .text(let t) = parts[0] { emitConstant(.string(t)); return }
            for part in parts {
                switch part {
                case .text(let t): emitConstant(.string(t))
                case .expr(let x): try compileIsolated(x)
                }
            }
            emit(.interpolate(parts.count))
        case .identifier(let name, let l):
            line = l
            try emitLoad(name)
        case .selfRef:
            try emitLoadSelf()
        case .superMember(let name):
            try emitLoadSelf()
            emit(.superInvoke(name, argc: 0, labels: []))
        case .implicitMember(let name):
            emitConstant(.unresolved(SwiftUnresolved(name: name, args: nil, labels: [])))
        case .prefix(let op, let operand, let l):
            line = l
            try compileExpr(operand)
            if op != "&" { emit(.prefix(op)) }
        case .postfixRange(let operand):
            try compileExpr(operand)
            emitConstant(.int(Int.max))
            emit(.binary("..."))
        case .binary(let op, let lhs, let rhs, let l):
            line = l
            switch op {
            case "&&":
                try compileExpr(lhs)
                emit(.dup)
                let skip = emit(.jumpIfFalse(0))
                emit(.pop)
                try compileExpr(rhs)
                patch(skip)
            case "||":
                try compileExpr(lhs)
                emit(.dup)
                let skip = emit(.jumpIfTrue(0))
                emit(.pop)
                try compileExpr(rhs)
                patch(skip)
            case "??":
                try compileExpr(lhs)
                let skip = emit(.coalesce(0))
                try compileExpr(rhs)
                patch(skip)
            default:
                try compileExpr(lhs)
                try compileExpr(rhs)
                emit(.binary(op))
            }
        case .assign(let op, let target, let value, let l):
            line = l
            try compileAssign(op, target, value)
            emitConstant(.void)
        case .ternary(let c, let a, let b):
            try compileExpr(c)
            let elseJump = emit(.jumpIfFalse(0))
            try compileExpr(a)
            let end = emit(.jump(0))
            patch(elseJump)
            try compileExpr(b)
            patch(end)
        case .arrayLit(let items):
            for item in items { try compileIsolated(item) }
            emit(.makeArray(items.count))
        case .dictionaryLit(let pairs):
            for (k, v) in pairs {
                try compileIsolated(k)
                try compileIsolated(v)
            }
            emit(.makeDictionary(pairs.count))
        case .tuple(let items):
            for item in items { try compileIsolated(item.value) }
            emit(.makeTuple(items.map(\.label)))
        case .closure(let c):
            emit(.makeClosure(try compileClosure(c)))
        case .tryExpr(let kind, let inner):
            switch kind {
            case "try?":
                let handler = emit(.pushHandler(0))
                ctx.handlerDepth += 1
                try compileIsolated(inner)
                ctx.handlerDepth -= 1
                emit(.wrapOptional)
                emit(.popHandler)
                let end = emit(.jump(0))
                patch(handler)
                emit(.pop)
                emitConstant(.none)
                patch(end)
            default:
                try compileExpr(inner)
            }
        case .isType(let inner, let t):
            try compileExpr(inner)
            emit(.typeCheck(t))
        case .cast(let inner, let t, let kind):
            try compileExpr(inner)
            emit(.cast(t, kind))
        case .typeExpr(let t):
            emitConstant(typeValue(t))
        case .keyPath(let path):
            emitConstant(.keyPath(path))
        case .ifExpr(let stmt):
            try compileIfExpression(stmt)
        case .member, .call, .subscriptAccess, .forceUnwrap, .optionalChain:
            try compileExpr(e)
        }
    }

    private func typeValue(_ t: SwiftTypeRef) -> SwiftValue {
        switch t {
        case .array(let inner): return .array([typeValue(inner)])
        case .dictionary(let k, let v):
            var d = SwiftDictionary()
            d.set(typeValue(k), typeValue(v))
            return .dictionary(d)
        case .named(let name, _):
            if let info = program.types[name] { return .type(info) }
            return .builtinType(name)
        case .optional(let inner): return typeValue(inner)
        default: return .builtinType("Any")
        }
    }

    /// `if`/`switch` in value position: each branch's final expression is the value.
    private func compileIfExpression(_ stmt: SwiftStmt) throws {
        switch stmt {
        case .ifStmt(let conds, let then, let els, let l):
            line = l
            pushScope()
            var failures: [Int] = []
            try compileConditions(conds, failures: &failures)
            try compileBranchValue(then)
            try popScope()
            let end = emit(.jump(0))
            for f in failures { patch(f) }
            if let els {
                pushScope()
                try compileBranchValue(els)
                try popScope()
            } else {
                emitConstant(.void)
            }
            patch(end)
        case .switchStmt(let subject, let cases, let label, let l):
            line = l
            try compileSwitch(subject, cases, label: label, asExpression: true)
        default:
            throw fail("expected if or switch expression")
        }
    }

    private func compileBranchValue(_ body: [SwiftStmt]) throws {
        guard let last = body.last else { emitConstant(.void); return }
        for s in body.dropLast() { try compileStatement(s) }
        switch last {
        case .expr(let e, let l):
            line = l
            if case .assign = e { try compileStatement(last); emitConstant(.void); return }
            try compileExpr(e)
        case .ifStmt, .switchStmt:
            if isExpressionBranching(last) { try compileIfExpression(last) } else { try compileStatement(last); emitConstant(.void) }
        default:
            try compileStatement(last)
            emitConstant(.void)
        }
    }
}
