import Foundation

// SwiftUI, as the Swift VM sees it. An interpreted program that says `VStack { Text("hi") }`
// builds `SwiftViewNode`s — plain descriptions, like SwiftUI's own view values — and
// `SwiftAppHost` walks them into a `SwiftRenderedNode` tree the app draws with real SwiftUI
// (`SwiftAppSurface.swift`). Keeping this half Foundation-only is what lets the harness drive an
// interpreted app headlessly: render, tap a button by its action id, render again, compare.
//
// `@State` lives outside the view values, keyed by the view's position in the tree, exactly the
// identity model SwiftUI uses: a parent's body rebuilds its children every render, and the store
// hands each rebuilt child the cells it had last time.

/// A builtin view value: kind, the arguments it was built with, its content, its modifiers.
final class SwiftViewNode {
    struct Modifier {
        let name: String
        let args: [SwiftValue]
        let labels: [String?]
    }

    let kind: String
    let args: [SwiftValue]
    let labels: [String?]
    let children: [SwiftValue]
    let modifiers: [Modifier]

    init(kind: String, args: [SwiftValue] = [], labels: [String?] = [], children: [SwiftValue] = [], modifiers: [Modifier] = []) {
        self.kind = kind
        self.args = args
        self.labels = labels
        self.children = children
        self.modifiers = modifiers
    }

    func argument(_ label: String?) -> SwiftValue? {
        guard let i = labels.firstIndex(where: { $0 == label }) else { return nil }
        return args[i]
    }

    func adding(_ modifier: Modifier) -> SwiftViewNode {
        SwiftViewNode(kind: kind, args: args, labels: labels, children: children, modifiers: modifiers + [modifier])
    }
}

enum SwiftViewLibrary {
    /// The SwiftUI names a program can reach. They are builtin types, so `Color.red` and
    /// `Font.title` read as static members and `Text("x")` as construction.
    static let typeNames: Set<String> = [
        "Text", "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "Button", "Spacer",
        "Divider", "Image", "TextField", "SecureField", "Toggle", "Slider", "Stepper", "List",
        "ForEach", "ScrollView", "NavigationStack", "NavigationView", "Group", "Form", "Section",
        "Circle", "Rectangle", "RoundedRectangle", "Capsule", "Ellipse", "Color", "Label",
        "ProgressView", "EmptyView", "WindowGroup", "Font", "GeometryReader", "TabView",
        "NavigationLink", "Picker", "Menu", "GroupBox", "DisclosureGroup", "LinearGradient",
        "Gradient", "UnitPoint", "Edge", "Alignment", "HorizontalAlignment", "VerticalAlignment",
        "Animation", "TextEditor", "DatePicker", "ColorPicker", "Link", "ContentUnavailableView",
    ]

    static func globalValue(_ name: String) -> SwiftValue? {
        typeNames.contains(name) ? .builtinType(name) : nil
    }

    /// Kinds whose trailing closure is their content.
    private static let containers: Set<String> = [
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "List", "ScrollView",
        "NavigationStack", "NavigationView", "Group", "Form", "Section", "WindowGroup", "TabView",
        "GroupBox", "Menu", "DisclosureGroup",
    ]

    static func construct(_ kind: String, _ args: [SwiftValue], _ labels: [String?], vm: SwiftVM) throws -> SwiftValue {
        switch kind {
        case "Color":
            if let first = args.first, case .string(let name) = first { return .view(SwiftViewNode(kind: "Color", args: [.string(name)], labels: [nil])) }
            return .view(SwiftViewNode(kind: "Color", args: args, labels: labels))
        case "Font", "UnitPoint", "Edge", "Alignment", "Animation", "Gradient", "HorizontalAlignment", "VerticalAlignment":
            return .unresolved(SwiftUnresolved(name: kind, args: args, labels: labels))
        default:
            break
        }
        var children: [SwiftValue] = []
        var plainArgs: [SwiftValue] = []
        var plainLabels: [String?] = []
        for (value, label) in zip(args, labels) {
            // A container's content closure runs now: its result builder collects the children.
            if containers.contains(kind), case .function = value, label == nil || label == "content" {
                children.append(try vm.call(value, []))
                continue
            }
            plainArgs.append(value)
            plainLabels.append(label)
        }
        return .view(SwiftViewNode(kind: kind, args: plainArgs, labels: plainLabels, children: children))
    }

    /// `Color.red`, `Font.title`, `Edge.top`: static members of the SwiftUI types.
    static func staticMember(_ kind: String, _ name: String) -> SwiftValue? {
        guard typeNames.contains(kind) else { return nil }
        if kind == "Color" { return .view(SwiftViewNode(kind: "Color", args: [.string(name)], labels: [nil])) }
        return .unresolved(SwiftUnresolved(name: name, args: nil, labels: []))
    }

    /// A modifier (`.padding()`, `.font(.title)`) applied to a builtin node or a user view.
    static func modify(_ receiver: SwiftValue, _ name: String, _ args: [SwiftValue], _ labels: [String?]) -> SwiftValue {
        let modifier = SwiftViewNode.Modifier(name: name, args: args, labels: labels)
        if case .view(let node) = receiver { return .view(node.adding(modifier)) }
        return .view(SwiftViewNode(kind: "Modified", children: [receiver], modifiers: [modifier]))
    }
}

// MARK: - The rendered tree

/// One drawable node: everything the SwiftUI surface needs, nothing it must evaluate.
struct SwiftRenderedNode: Sendable, Identifiable, Equatable {
    var id: String
    var kind: String
    var text: String? = nil
    var systemImage: String? = nil
    var children: [SwiftRenderedNode] = []
    var modifiers: [SwiftRenderedModifier] = []
    /// Tapping runs this action (`SwiftAppHost.perform`).
    var action: Int? = nil
    /// A control's two-way value (`SwiftAppHost.setBinding`).
    var binding: Int? = nil
    var value: SwiftRenderedValue = .none
    var range: ClosedRange<Double>? = nil
    var step: Double? = nil
    var spacing: Double? = nil
    var alignment: String? = nil
}

struct SwiftRenderedModifier: Sendable, Equatable {
    var name: String
    var values: [SwiftRenderedValue]
    var labels: [String?]
    var action: Int? = nil
}

enum SwiftRenderedValue: Sendable, Equatable {
    case none
    case number(Double)
    case string(String)
    case bool(Bool)
    case name(String)
    case color(String)
}

// MARK: - The host

/// Runs an interpreted SwiftUI app: owns its VM, its state, and the id tables that connect a tap
/// on the drawn tree back to a closure in the program. Confined to one thread by its owner.
final class SwiftAppHost {
    let vm: SwiftVM
    private var root: SwiftValue
    private var stateCells: [String: SwiftCell] = [:]
    private var actions: [Int: SwiftValue] = [:]
    private var bindings: [Int: SwiftCell] = [:]
    private var appeared: Set<String> = []
    private var pendingAppear: [SwiftValue] = []
    private var nextID = 0

    init(vm: SwiftVM, root: SwiftValue) {
        self.vm = vm
        self.root = root
    }

    /// The app's root view, found the way SwiftUI would: an `@main` App's scene, else a View.
    static func rootView(vm: SwiftVM) throws -> SwiftValue? {
        let program = vm.program
        if let entry = program.entryType, vm.conforms(entry, to: "App") {
            let app = try vm.construct(entry, [], [])
            return try vm.getMember(app, "body")
        }
        let views = program.types.values.filter { $0.kind == .structType && vm.conforms($0, to: "View") }
        let preferred = views.first { $0.name == "ContentView" } ?? views.first { $0.name.hasSuffix("View") && !$0.name.contains(".") }
        guard let type = preferred else { return nil }
        return try vm.construct(type, [], [])
    }

    func render() throws -> SwiftRenderedNode {
        actions = [:]
        bindings = [:]
        nextID = 0
        let nodes = try renderValue(root, path: "root")
        let tree = nodes.count == 1 ? nodes[0] : SwiftRenderedNode(id: "root", kind: "VStack", children: nodes)
        // onAppear fires after the render that first shows the view, as in SwiftUI.
        let appearing = pendingAppear
        pendingAppear = []
        for action in appearing { _ = try vm.call(action, []) }
        return appearing.isEmpty ? tree : try render()
    }

    func perform(_ action: Int) throws {
        guard let closure = actions[action] else { return }
        _ = try vm.call(closure, [])
    }

    func setBinding(_ id: Int, _ value: SwiftRenderedValue) {
        guard let cell = bindings[id] else { return }
        switch (value, cell.value) {
        case (.string(let s), _): cell.value = .string(s)
        case (.bool(let b), _): cell.value = .bool(b)
        case (.number(let n), .int): cell.value = .int(Int(n.rounded()))
        case (.number(let n), _): cell.value = .double(n)
        default: break
        }
    }

    private func register(_ closure: SwiftValue) -> Int {
        nextID += 1
        actions[nextID] = closure
        return nextID
    }

    private func register(cell: SwiftCell) -> Int {
        nextID += 1
        bindings[nextID] = cell
        return nextID
    }

    // MARK: Walking values

    private func renderValue(_ value: SwiftValue, path: String) throws -> [SwiftRenderedNode] {
        switch value.dereferenced {
        case .view(let node):
            return try renderNode(node, path: path)
        case .structValue(var s) where vm.conforms(s.type, to: "View"):
            // Hand the rebuilt view the state cells its position owned last render.
            for (i, prop) in s.type.stored.enumerated() where prop.wrapper == "State" || prop.wrapper == "StateObject" {
                let key = path + "." + prop.name
                if let existing = stateCells[key] {
                    s.fields[i] = .cell(existing)
                } else if case .cell(let fresh) = s.fields[i] {
                    stateCells[key] = fresh
                }
            }
            let body = try vm.getMember(.structValue(s), "body")
            return try renderValue(body, path: path + "/" + s.type.shortName)
        case .array(let items):
            return try items.enumerated().flatMap { try renderValue($1, path: path + "/\($0)") }
        case .void, .none:
            return []
        case .some(let inner):
            return try renderValue(inner, path: path)
        case .string(let s):
            return [SwiftRenderedNode(id: path, kind: "Text", text: s)]
        default:
            return []
        }
    }

    private func text(_ v: SwiftValue?) throws -> String? {
        guard let v else { return nil }
        if case .string(let s) = v.dereferenced { return s }
        return try vm.describe(v)
    }

    private func children(_ node: SwiftViewNode, path: String) throws -> [SwiftRenderedNode] {
        try node.children.enumerated().flatMap { try renderValue($1, path: path + "/\($0)") }
    }

    private func cell(_ v: SwiftValue?) -> SwiftCell? {
        if case .cell(let c)? = v { return c }
        return nil
    }

    private func renderNode(_ node: SwiftViewNode, path: String) throws -> [SwiftRenderedNode] {
        var out = SwiftRenderedNode(id: path, kind: node.kind)
        switch node.kind {
        case "Group", "WindowGroup":
            let kids = try children(node, path: path)
            guard !node.modifiers.isEmpty else { return kids }
            out.kind = "VStack"
            out.children = kids
        case "Modified":
            out.kind = "ZStack"
            out.children = try children(node, path: path)
        case "ForEach":
            guard let data = node.args.first else { return [] }
            let content = node.argument("content") ?? node.args.last!
            let idPath: [String]? = { if case .keyPath(let p)? = node.argument("id") { return p }; return nil }()
            var kids: [SwiftRenderedNode] = []
            for (i, element) in try SwiftRuntime.elements(data, vm: vm).enumerated() {
                var key = "\(i)"
                if let idPath {
                    var v = element
                    for p in idPath where p != "self" { v = try vm.getMember(v, p) }
                    key = SwiftRuntime.hashKey(v)
                } else if let t = vm.typeOf(element), t.storedIndex["id"] != nil {
                    key = SwiftRuntime.hashKey(try vm.getMember(element, "id"))
                }
                kids += try renderValue(try vm.call(content, [element]), path: path + "[\(key)]")
            }
            guard !node.modifiers.isEmpty else { return kids }
            out.kind = "VStack"
            out.children = kids
        case "Text":
            out.text = try text(node.args.first) ?? ""
        case "Label":
            out.text = try text(node.args.first) ?? ""
            if let icon = node.argument("systemImage") { out.systemImage = try text(icon) }
        case "Image":
            if let name = node.argument("systemName") { out.systemImage = try text(name) } else { out.text = try text(node.args.first) }
        case "Button", "NavigationLink", "Link":
            if let action = node.argument("action") ?? node.args.last(where: { if case .function = $0 { return true }; return false }),
               node.kind == "Button" {
                out.action = register(action)
            }
            if let title = node.args.first, case .string(let s) = title.dereferenced {
                out.text = s
            } else if let label = node.argument("label") {
                out.children = try renderValue(try vm.call(label, []), path: path + "/label")
            } else if node.kind == "Button", node.args.count >= 2, case .function = node.args[1] {
                // `Button { action } label: { … }` — the first closure is the action.
                out.action = register(node.args[0])
                out.children = try renderValue(try vm.call(node.args[1], []), path: path + "/label")
            }
            if let dest = node.argument("destination") { _ = dest }
        case "Toggle":
            out.text = try text(node.args.first.flatMap { if case .string = $0.dereferenced { return $0 }; return nil })
            if let c = cell(node.argument("isOn")) {
                out.binding = register(cell: c)
                if case .bool(let b) = c.value { out.value = .bool(b) }
            }
            if let label = node.args.last, case .function = label { out.children = try renderValue(try vm.call(label, []), path: path + "/label") }
        case "TextField", "SecureField", "TextEditor":
            out.text = try text(node.args.first.flatMap { if case .string = $0.dereferenced { return $0 }; return nil })
            if let c = cell(node.argument("text")) {
                out.binding = register(cell: c)
                if case .string(let s) = c.value { out.value = .string(s) }
            }
        case "Slider", "Stepper", "ProgressView":
            out.text = try text(node.args.first.flatMap { if case .string = $0.dereferenced { return $0 }; return nil })
            let valueArg = node.argument("value")
            if let c = cell(valueArg) {
                out.binding = register(cell: c)
                if let n = SwiftRuntime.number(c.value) { out.value = .number(n) }
            } else if let v = valueArg, let n = SwiftRuntime.number(v) {
                out.value = .number(n)
            }
            if let r = node.argument("in") {
                switch r.dereferenced {
                case .range(let lo, let hi, _): out.range = Double(lo)...Double(hi)
                case .doubleRange(let lo, let hi, _): out.range = lo...hi
                default: break
                }
            }
            if let s = node.argument("step"), let n = SwiftRuntime.number(s) { out.step = n }
            if let inc = node.argument("onIncrement") { out.action = register(inc) }
            if let dec = node.argument("onDecrement") {
                out.modifiers.append(SwiftRenderedModifier(name: "onDecrement", values: [], labels: [], action: register(dec)))
            }
        case "Color":
            out.value = .color(try text(node.args.first) ?? "clear")
        case "RoundedRectangle":
            if let r = node.argument("cornerRadius"), let n = SwiftRuntime.number(r) { out.value = .number(n) }
        default:
            if let spacing = node.argument("spacing"), let n = SwiftRuntime.number(spacing) { out.spacing = n }
            if let alignment = node.argument("alignment") { out.alignment = renderedName(alignment) }
            out.children = try children(node, path: path)
            if node.kind == "ScrollView" || node.kind == "List" || node.kind == "Form" || node.kind == "Section" {
                if let header = node.argument("header") { out.text = try text(try vm.call(header, [])) }
                if let title = node.args.first, case .string(let s) = title.dereferenced { out.text = s }
            }
        }
        for modifier in node.modifiers {
            out.modifiers.append(try renderModifier(modifier, path: path))
        }
        return [out]
    }

    private func renderedName(_ v: SwiftValue) -> String? {
        if case .unresolved(let u) = v.dereferenced { return u.name }
        return nil
    }

    private func renderModifier(_ modifier: SwiftViewNode.Modifier, path: String) throws -> SwiftRenderedModifier {
        var rendered = SwiftRenderedModifier(name: modifier.name, values: [], labels: modifier.labels)
        for value in modifier.args {
            switch value.dereferenced {
            case .int(let i): rendered.values.append(.number(Double(i)))
            case .double(let d): rendered.values.append(.number(d))
            case .string(let s): rendered.values.append(.string(s))
            case .bool(let b): rendered.values.append(.bool(b))
            case .unresolved(let u): rendered.values.append(.name(u.name))
            case .view(let n) where n.kind == "Color": rendered.values.append(.color(try text(n.args.first) ?? "clear"))
            case .function:
                if modifier.name == "onAppear" {
                    if !appeared.contains(path) {
                        appeared.insert(path)
                        pendingAppear.append(value)
                    }
                } else {
                    rendered.action = register(value)
                }
                rendered.values.append(.none)
            default:
                rendered.values.append(.none)
            }
        }
        return rendered
    }
}
