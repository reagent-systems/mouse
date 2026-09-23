import SwiftUI

// Draws an interpreted SwiftUI program. The VM thread renders the program's views to a
// `SwiftRenderedNode` tree (`SwiftViewLibrary.swift`); this file turns that tree into real
// SwiftUI — a `Text` is a `Text`, a `Button` a `Button` — and sends taps and edits back to the
// program through its `SwiftAppSession`. Nothing here evaluates the program.

/// The terminal container's face while a Swift app runs: the app on its own canvas, in the
/// system's light appearance, as it would look on the device it was written for.
struct SwiftAppSurface: View {
    let app: SwiftAppSession

    var body: some View {
        Group {
            if let frame = app.frame {
                SwiftRenderedView(node: frame, app: app)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(Color.primary)
        .background(Color(uiColor: .systemBackground))
        .environment(\.colorScheme, .light)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One rendered node, recursively.
struct SwiftRenderedView: View {
    let node: SwiftRenderedNode
    let app: SwiftAppSession

    var body: some View {
        modified(base)
    }

    private var kids: some View {
        ForEach(node.children) { SwiftRenderedView(node: $0, app: app) }
    }

    @ViewBuilder
    private var base: some View {
        switch node.kind {
        case "VStack", "LazyVStack", "TabView", "GroupBox", "DisclosureGroup", "Menu":
            VStack(alignment: horizontalAlignment, spacing: node.spacing.map { CGFloat($0) }) { kids }
        case "HStack", "LazyHStack":
            HStack(alignment: verticalAlignment, spacing: node.spacing.map { CGFloat($0) }) { kids }
        case "ZStack":
            ZStack { kids }
        case "ScrollView":
            ScrollView { VStack(alignment: horizontalAlignment, spacing: node.spacing.map { CGFloat($0) }) { kids } }
        case "List", "Form":
            List { kids }
        case "Section":
            if let header = node.text {
                Section { kids } header: { Text(header) }
            } else {
                Section { kids }
            }
        case "NavigationStack", "NavigationView":
            NavigationStack { VStack(spacing: 0) { kids } }
        case "Text":
            Text(node.text ?? "")
        case "Label":
            Label(node.text ?? "", systemImage: node.systemImage ?? "circle")
        case "Image":
            if let symbol = node.systemImage {
                Image(systemName: symbol)
            } else {
                Image(systemName: "photo")
            }
        case "Button":
            Button {
                if let action = node.action { app.perform(action) }
            } label: {
                if let title = node.text { Text(title) } else { kids }
            }
        case "Link", "NavigationLink":
            if let title = node.text { Text(title).foregroundStyle(Color.accentColor) } else { kids }
        case "Toggle":
            Toggle(isOn: Binding(
                get: { if case .bool(let b) = node.value { return b }; return false },
                set: { if let id = node.binding { app.set(id, .bool($0)) } })) {
                if let title = node.text { Text(title) } else { kids }
            }
        case "TextField", "SecureField", "TextEditor":
            SwiftRenderedTextField(node: node, app: app)
        case "Slider":
            Slider(value: Binding(
                get: { if case .number(let n) = node.value { return n }; return 0 },
                set: { if let id = node.binding { app.set(id, .number($0)) } }),
                   in: node.range ?? 0...1)
        case "Stepper":
            Stepper(node.text ?? "", onIncrement: {
                if let id = node.binding {
                    if case .number(let n) = node.value { app.set(id, .number(min(n + (node.step ?? 1), node.range?.upperBound ?? .infinity))) }
                } else if let action = node.action {
                    app.perform(action)
                }
            }, onDecrement: {
                if let id = node.binding {
                    if case .number(let n) = node.value { app.set(id, .number(max(n - (node.step ?? 1), node.range?.lowerBound ?? -.infinity))) }
                } else if let action = node.modifiers.first(where: { $0.name == "onDecrement" })?.action {
                    app.perform(action)
                }
            })
        case "ProgressView":
            if case .number(let n) = node.value {
                ProgressView(value: n, total: node.range?.upperBound ?? 1)
            } else {
                ProgressView()
            }
        case "Spacer":
            Spacer(minLength: 0)
        case "Divider":
            Divider()
        case "Color":
            SwiftRenderedStyle.color(node.value) ?? Color.clear
        case "Circle":
            Circle()
        case "Ellipse":
            Ellipse()
        case "Capsule":
            Capsule()
        case "Rectangle":
            Rectangle()
        case "RoundedRectangle":
            RoundedRectangle(cornerRadius: { if case .number(let r) = node.value { return CGFloat(r) }; return 8 }())
        case "EmptyView":
            EmptyView()
        default:
            // Kinds with no native drawing here (a custom container, a Picker) still show
            // their content.
            VStack(alignment: horizontalAlignment) { kids }
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch node.alignment {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }

    private var verticalAlignment: VerticalAlignment {
        switch node.alignment {
        case "top": .top
        case "bottom": .bottom
        default: .center
        }
    }

    private func modified(_ content: some View) -> AnyView {
        var view = AnyView(content)
        for modifier in node.modifiers {
            view = SwiftRenderedStyle.apply(modifier, to: view, app: app)
        }
        return view
    }
}

/// A text field keeps its own editing state and reports each change to the program, so typing
/// never waits on the VM's re-render.
private struct SwiftRenderedTextField: View {
    let node: SwiftRenderedNode
    let app: SwiftAppSession
    @State private var text = ""

    var body: some View {
        Group {
            switch node.kind {
            case "SecureField": SecureField(node.text ?? "", text: $text)
            case "TextEditor": TextEditor(text: $text)
            default: TextField(node.text ?? "", text: $text)
            }
        }
        .onAppear { if case .string(let s) = node.value { text = s } }
        .onChange(of: node.value) { _, value in
            if case .string(let s) = value, s != text { text = s }
        }
        .onChange(of: text) { _, value in
            if let id = node.binding, node.value != .string(value) { app.set(id, .string(value)) }
        }
    }
}

@MainActor
enum SwiftRenderedStyle {
    static func color(_ value: SwiftRenderedValue) -> Color? {
        guard case .color(let name) = value else {
            if case .name(let n) = value { return color(.color(n)) }
            return nil
        }
        if name.hasPrefix("rgb:") {
            let parts = name.dropFirst(4).split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 3 else { return nil }
            return Color(red: parts[0], green: parts[1], blue: parts[2], opacity: parts.count > 3 ? parts[3] : 1)
        }
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "gray", "grey": return .gray
        case "black": return .black
        case "white": return .white
        case "primary": return .primary
        case "secondary": return .secondary
        case "accentColor", "accent": return .accentColor
        case "clear": return .clear
        default: return nil
        }
    }

    static func font(_ value: SwiftRenderedValue) -> Font? {
        switch value {
        case .name(let name):
            switch name {
            case "largeTitle": return .largeTitle
            case "title": return .title
            case "title2": return .title2
            case "title3": return .title3
            case "headline": return .headline
            case "subheadline": return .subheadline
            case "body": return .body
            case "callout": return .callout
            case "footnote": return .footnote
            case "caption": return .caption
            case "caption2": return .caption2
            default: return nil
            }
        case .call("system", let args, let labels):
            var size: Double = 17
            var weight: Font.Weight = .regular
            var design: Font.Design = .default
            for (arg, label) in zip(args, labels) {
                switch (label, arg) {
                case ("size", .number(let n)), (nil, .number(let n)): size = n
                case ("weight", .name(let w)): weight = fontWeight(w) ?? .regular
                case ("design", .name(let d)): design = d == "rounded" ? .rounded : d == "monospaced" ? .monospaced : d == "serif" ? .serif : .default
                default: break
                }
            }
            return .system(size: size, weight: weight, design: design)
        default:
            return nil
        }
    }

    static func fontWeight(_ name: String) -> Font.Weight? {
        switch name {
        case "ultraLight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "regular": .regular
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: nil
        }
    }

    private static func number(_ v: SwiftRenderedValue?) -> CGFloat? {
        if case .number(let n)? = v { return CGFloat(n) }
        if case .name("infinity")? = v { return .infinity }
        return nil
    }

    private static func value(_ m: SwiftRenderedModifier, _ label: String) -> SwiftRenderedValue? {
        guard let i = m.labels.firstIndex(where: { $0 == label }), i < m.values.count else { return nil }
        return m.values[i]
    }

    private static func edges(_ name: String) -> Edge.Set {
        switch name {
        case "top": .top
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        case "horizontal": .horizontal
        case "vertical": .vertical
        default: .all
        }
    }

    static func apply(_ m: SwiftRenderedModifier, to view: AnyView, app: SwiftAppSession) -> AnyView {
        let first = m.values.first
        switch m.name {
        case "padding":
            switch (first, m.values.count > 1 ? m.values[1] : nil) {
            case (.name(let edge)?, .number(let n)?): return AnyView(view.padding(edges(edge), CGFloat(n)))
            case (.name(let edge)?, _): return AnyView(view.padding(edges(edge)))
            case (.number(let n)?, _): return AnyView(view.padding(CGFloat(n)))
            default: return AnyView(view.padding())
            }
        case "font":
            guard let first, let font = font(first) else { return view }
            return AnyView(view.font(font))
        case "fontWeight":
            if case .name(let w)? = first, let weight = fontWeight(w) { return AnyView(view.fontWeight(weight)) }
            return view
        case "bold": return AnyView(view.bold())
        case "italic": return AnyView(view.italic())
        case "foregroundColor", "foregroundStyle", "fill", "tint", "accentColor":
            guard let first, let color = color(first) else { return view }
            return AnyView(view.foregroundStyle(color).tint(color))
        case "background":
            guard let first, let color = color(first) else { return view }
            return AnyView(view.background(color))
        case "frame":
            let width = number(value(m, "width")), height = number(value(m, "height"))
            let maxWidth = number(value(m, "maxWidth")), maxHeight = number(value(m, "maxHeight"))
            let minWidth = number(value(m, "minWidth")), minHeight = number(value(m, "minHeight"))
            var result = view
            if width != nil || height != nil { result = AnyView(result.frame(width: width, height: height)) }
            if maxWidth != nil || maxHeight != nil || minWidth != nil || minHeight != nil {
                result = AnyView(result.frame(minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight))
            }
            return result
        case "cornerRadius":
            guard let r = number(first) else { return view }
            return AnyView(view.clipShape(RoundedRectangle(cornerRadius: r, style: .continuous)))
        case "opacity":
            guard let o = number(first) else { return view }
            return AnyView(view.opacity(o))
        case "border":
            guard let first, let color = color(first) else { return view }
            return AnyView(view.border(color, width: number(value(m, "width")) ?? 1))
        case "offset":
            return AnyView(view.offset(x: number(value(m, "x")) ?? 0, y: number(value(m, "y")) ?? 0))
        case "scaleEffect":
            return AnyView(view.scaleEffect(number(first) ?? 1))
        case "rotationEffect":
            if case .call(let unit, let args, _)? = first, case .number(let n)? = args.first {
                return AnyView(view.rotationEffect(unit == "radians" ? .radians(n) : .degrees(n)))
            }
            return view
        case "multilineTextAlignment":
            if case .name(let a)? = first {
                return AnyView(view.multilineTextAlignment(a == "center" ? .center : a == "trailing" ? .trailing : .leading))
            }
            return view
        case "lineLimit":
            return AnyView(view.lineLimit(number(first).map { Int($0) }))
        case "navigationTitle":
            if case .string(let title)? = first { return AnyView(view.navigationTitle(title)) }
            return view
        case "disabled":
            if case .bool(let b)? = first { return AnyView(view.disabled(b)) }
            return view
        case "buttonStyle":
            if case .name(let style)? = first {
                switch style {
                case "borderedProminent": return AnyView(view.buttonStyle(.borderedProminent))
                case "bordered": return AnyView(view.buttonStyle(.bordered))
                case "plain": return AnyView(view.buttonStyle(.plain))
                default: return view
                }
            }
            return view
        case "textFieldStyle":
            if case .name("roundedBorder")? = first { return AnyView(view.textFieldStyle(.roundedBorder)) }
            return view
        case "onTapGesture":
            guard let action = m.action else { return view }
            return AnyView(view.contentShape(Rectangle()).onTapGesture { app.perform(action) })
        case "shadow":
            return AnyView(view.shadow(radius: number(value(m, "radius")) ?? 4))
        default:
            return view
        }
    }
}
