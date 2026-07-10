import SwiftUI

/// The Terminal container (kind 5): a real terminal in look and feel — prompt, scrollback,
/// mono — whose commands are implemented natively against the ring's workspace (the a-Shell
/// model; iOS has no fork/exec). Filesystem built-ins ship first; `git` arrives with the
/// libgit2 engine and `npm`/`pnpm` with the package engine. Output wraps, scrollback scrolls
/// vertically, taps focus the prompt — all per the gesture law.
@Observable
final class TerminalSession {
    struct Line: Identifiable {
        enum Kind {
            case command, output, error
        }

        let id = UUID()
        let text: String
        let kind: Kind
    }

    let root: URL
    /// Current directory, relative to `root` ("" = repo root). Never escapes the workspace.
    private(set) var cwd = ""
    private(set) var lines: [Line] = []

    init(root: URL) {
        self.root = root
    }

    var prompt: String {
        (cwd.isEmpty ? "~" : "~/" + cwd) + " $"
    }

    func run(_ raw: String, workspace: Workspace?, deck: CarouselDeck?) {
        let command = raw.trimmingCharacters(in: .whitespaces)
        append("\(prompt) \(command)", .command)
        guard !command.isEmpty else { return }
        var parts = command.split(separator: " ").map(String.init)
        let name = parts.removeFirst()

        switch name {
        case "help": help()
        case "clear": lines = []
        case "pwd": append("/" + cwd, .output)
        case "ls": ls(parts.first)
        case "cd": cd(parts.first)
        case "cat": cat(parts.first)
        case "echo": append(parts.joined(separator: " "), .output)
        case "mkdir": mkdir(parts.first)
        case "touch": touch(parts.first, workspace: workspace)
        case "rm": rm(parts)
        case "mv": moveOrCopy(parts, copy: false, workspace: workspace)
        case "cp": moveOrCopy(parts.filter { $0 != "-r" }, copy: true, workspace: workspace)
        case "head": headTail(parts, fromStart: true)
        case "tail": headTail(parts, fromStart: false)
        case "find": find(parts.first)
        case "grep": grep(parts)
        case "open": open(parts.first, workspace: workspace, deck: deck)
        case "git", "npm", "pnpm", "node", "npx":
            append("\(name): not built yet — the native \(name == "git" ? "git" : "package") engine is on the roadmap", .error)
        default:
            append("command not found: \(name) (type help)", .error)
        }
    }

    // MARK: - Built-ins

    private func help() {
        append("""
        built-ins:
          ls [path]      cd [path]      pwd            cat <file>
          echo [text]    mkdir <dir>    touch <file>   rm [-r] <path>
          mv <a> <b>     cp <a> <b>     head/tail [-n N] <file>
          find <name>    grep <text> <file>             open <file>
          clear          help
        """, .output)
    }

    private func ls(_ arg: String?) {
        guard let target = resolve(arg ?? ".") else { return badPath(arg) }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: target.url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return append("ls: not a directory: \(display(target.rel))", .error)
        }
        let names = entries
            .map { url -> (String, Bool) in
                (url.lastPathComponent, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 }
                return lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
            }
            .map { $0.1 ? $0.0 + "/" : $0.0 }
        append(names.isEmpty ? "(empty)" : names.joined(separator: "  "), .output)
    }

    private func cd(_ arg: String?) {
        guard let target = resolve(arg ?? "/") else { return badPath(arg) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return append("cd: not a directory: \(display(target.rel))", .error)
        }
        cwd = target.rel
    }

    private func cat(_ arg: String?) {
        guard let arg, let target = resolve(arg) else { return badPath(arg) }
        guard let data = try? Data(contentsOf: target.url) else {
            return append("cat: no such file: \(display(target.rel))", .error)
        }
        guard data.count < 200_000 else {
            return append("cat: file too large (\(data.count / 1024) KB)", .error)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return append("cat: binary file", .error)
        }
        append(text.hasSuffix("\n") ? String(text.dropLast()) : text, .output)
    }

    private func mkdir(_ arg: String?) {
        guard let arg, let target = resolve(arg) else { return badPath(arg) }
        do {
            try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
        } catch {
            append("mkdir: \(error.localizedDescription)", .error)
        }
    }

    private func touch(_ arg: String?, workspace: Workspace?) {
        guard let arg, let target = resolve(arg) else { return badPath(arg) }
        if !FileManager.default.fileExists(atPath: target.url.path) {
            FileManager.default.createFile(atPath: target.url.path, contents: Data())
            workspace?.markModified(target.rel)
        }
    }

    private func rm(_ args: [String]) {
        let recursive = args.contains("-r")
        guard let arg = args.first(where: { $0 != "-r" }), let target = resolve(arg) else { return badPath(args.first) }
        guard !target.rel.isEmpty else { return append("rm: refusing to remove the workspace root", .error) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDirectory) else {
            return append("rm: no such path: \(display(target.rel))", .error)
        }
        if isDirectory.boolValue && !recursive {
            return append("rm: is a directory (use rm -r): \(display(target.rel))", .error)
        }
        do {
            try FileManager.default.removeItem(at: target.url)
        } catch {
            append("rm: \(error.localizedDescription)", .error)
        }
    }

    private func moveOrCopy(_ args: [String], copy: Bool, workspace: Workspace?) {
        let name = copy ? "cp" : "mv"
        guard args.count >= 2,
              let source = resolve(args[0]),
              let destination = resolve(args[1]) else {
            return append("\(name): usage: \(name) <source> <destination>", .error)
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
                workspace?.markModified(destination.rel)
            }
        } catch {
            append("\(name): \(error.localizedDescription)", .error)
        }
    }

    private func headTail(_ args: [String], fromStart: Bool) {
        var count = 10
        var fileArg: String?
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "-n", let value = iterator.next() { count = Int(value) ?? 10 }
            else { fileArg = arg }
        }
        guard let fileArg, let target = resolve(fileArg) else { return badPath(fileArg) }
        guard let text = try? String(contentsOf: target.url, encoding: .utf8) else {
            return append("\(fromStart ? "head" : "tail"): can't read \(display(target.rel))", .error)
        }
        let allLines = text.components(separatedBy: "\n")
        let slice = fromStart ? allLines.prefix(count) : allLines.suffix(count)
        append(slice.joined(separator: "\n"), .output)
    }

    private func find(_ arg: String?) {
        guard let arg else { return append("find: usage: find <name>", .error) }
        guard let start = resolve(".") else { return }
        let fm = FileManager.default
        var matches: [String] = []
        if let enumerator = fm.enumerator(at: start.url, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                let component = url.lastPathComponent
                if component == ".git" || component == "node_modules" {
                    enumerator.skipDescendants()
                    continue
                }
                if component.localizedCaseInsensitiveContains(arg) {
                    let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    matches.append(rel)
                    if matches.count >= 200 {
                        matches.append("… stopped at 200 matches")
                        break
                    }
                }
            }
        }
        append(matches.isEmpty ? "no matches" : matches.joined(separator: "\n"), .output)
    }

    private func grep(_ args: [String]) {
        guard args.count >= 2, let target = resolve(args[1]) else {
            return append("grep: usage: grep <text> <file>", .error)
        }
        guard let text = try? String(contentsOf: target.url, encoding: .utf8) else {
            return append("grep: can't read \(display(target.rel))", .error)
        }
        let pattern = args[0]
        var results: [String] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() where line.contains(pattern) {
            results.append("\(index + 1): \(line)")
            if results.count >= 100 {
                results.append("… stopped at 100 matches")
                break
            }
        }
        append(results.isEmpty ? "no matches" : results.joined(separator: "\n"), .output)
    }

    private func open(_ arg: String?, workspace: Workspace?, deck: CarouselDeck?) {
        guard let arg, let target = resolve(arg) else { return badPath(arg) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return append("open: not a file: \(display(target.rel))", .error)
        }
        deck?.openFile(target.rel)
        append("opened \(display(target.rel)) in the viewer", .output)
    }

    // MARK: - Plumbing

    /// Resolve a path argument against the cwd. `/`-prefixed means the workspace root; `..` is
    /// clamped at the root, so the workspace can never be escaped.
    private func resolve(_ arg: String) -> (rel: String, url: URL)? {
        var components = arg.hasPrefix("/") ? [] : cwd.split(separator: "/").map(String.init)
        for piece in arg.split(separator: "/") {
            switch piece {
            case ".", "": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(piece))
            }
        }
        let rel = components.joined(separator: "/")
        return (rel, rel.isEmpty ? root : root.appendingPathComponent(rel))
    }

    private func display(_ rel: String) -> String { rel.isEmpty ? "/" : rel }

    private func badPath(_ arg: String?) {
        append("invalid path: \(arg ?? "")", .error)
    }

    private func append(_ text: String, _ kind: Line.Kind) {
        lines.append(Line(text: text, kind: kind))
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }
}

struct TerminalContainerView: View {
    let deck: CarouselDeck?

    @State private var promptFocused = false

    var body: some View {
        Group {
            if let deck, let workspace = deck.workspace {
                // The ring's OWN session: rings sharing a repo get separate terminals.
                let terminal = deck.terminal(for: workspace)
                VStack(alignment: .leading, spacing: 6) {
                    // Bottom-anchored like a chat: content sticks to the bottom as output
                    // arrives, with no manual scrollTo to miscompute against unlaid-out lines
                    // (which used to park the response offscreen). Scrolling up to read holds.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(terminal.lines) { line in
                                Text(line.text)
                                    .font(.custom(AppFont.asciiName, size: 12))
                                    .foregroundStyle(color(for: line.kind))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .defaultScrollAnchor(.bottom)
                    HStack(spacing: 6) {
                        Text(terminal.prompt)
                            .font(.custom(AppFont.asciiName, size: 12))
                            .opacity(0.7)
                        TerminalPromptField(isFocused: $promptFocused) { command in
                            terminal.run(command, workspace: workspace, deck: deck)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                    }
                }
                .padding(16)
                .contentShape(Rectangle())
                .onTapGesture { promptFocused = true }
            } else {
                Text("open a repo in the Files container —\nthe terminal runs on the workspace")
                    .font(.custom(AppFont.asciiName, size: 14))
                    .multilineTextAlignment(.center)
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
    }

    private func color(for kind: TerminalSession.Line.Kind) -> Color {
        switch kind {
        case .command: .white
        case .output: .white.opacity(0.8)
        case .error: .red
        }
    }
}


/// UIKit-backed prompt: pressing return runs the command WITHOUT resigning first responder
/// (returning `false` from `textFieldShouldReturn`), so the keyboard never dips between
/// commands — SwiftUI's TextField unavoidably dismisses on submit, which flickered it.
private struct TerminalPromptField: UIViewRepresentable {
    @Binding var isFocused: Bool
    let onCommand: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = UIFont(name: AppFont.asciiName, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .bold)
        field.textColor = .white
        field.tintColor = .white
        field.backgroundColor = .clear
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.keyboardType = .asciiCapable
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TerminalPromptField
        init(_ parent: TerminalPromptField) { self.parent = parent }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onCommand(textField.text ?? "")
            textField.text = ""
            return false  // keep first responder: the keyboard never leaves mid-session
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { self.parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            DispatchQueue.main.async { self.parent.isFocused = false }
        }
    }
}
