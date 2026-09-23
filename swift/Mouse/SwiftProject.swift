import Foundation
import Observation

// Swift projects in the terminal. When the working directory belongs to a Swift project — a
// SwiftPM package, an Xcode app, or loose `.swift` files — `swift run` compiles its sources to
// bytecode (`SwiftBytecode.swift`) and runs them in the VM (`SwiftVM.swift`). Anywhere else
// `swift` refuses: there is no toolchain to fall back to on iOS, and the command exists only
// for the projects it can run.
//
// A command-line program streams into the scrollback like any other. A SwiftUI program — an
// `@main` App, or a `ContentView` — is presented instead: the running program's `surface` is a
// `SwiftAppSession`, which the terminal container draws in place of its transcript until the
// program is stopped.

struct SwiftProject {
    enum Kind: Equatable {
        case package
        case xcode
        case loose
    }

    let kind: Kind
    /// The project directory: where Package.swift or the .xcodeproj sits, or the searched folder.
    let directory: URL
    let name: String

    private static let skippedDirectories: Set<String> = [".build", ".git", "node_modules", "DerivedData", ".swiftpm", "Pods"]

    /// The Swift project `directory` belongs to, searching upward to `root` for a manifest and
    /// otherwise looking for loose `.swift` files at and below `directory`.
    static func detect(root: URL, directory: URL) -> SwiftProject? {
        let fm = FileManager.default
        var dir = directory.standardizedFileURL
        let top = root.standardizedFileURL.path
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return SwiftProject(kind: .package, directory: dir, name: packageName(dir) ?? dir.lastPathComponent)
            }
            if let entries = try? fm.contentsOfDirectory(atPath: dir.path),
               let proj = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
                return SwiftProject(kind: .xcode, directory: dir, name: String(proj.dropLast(".xcodeproj".count)))
            }
            if dir.path == top || dir.path.count <= top.count { break }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
        if !swiftFiles(under: directory, limit: 1).isEmpty {
            return SwiftProject(kind: .loose, directory: directory.standardizedFileURL, name: directory.lastPathComponent)
        }
        return nil
    }

    private static func packageName(_ dir: URL) -> String? {
        guard let manifest = try? String(contentsOf: dir.appendingPathComponent("Package.swift"), encoding: .utf8) else { return nil }
        return firstMatch(#"name:\s*"([^"]+)""#, in: manifest)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Every `.swift` file under `dir`, skipping build output, dependencies and test targets.
    static func swiftFiles(under dir: URL, limit: Int = 2000) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedDirectories.contains(name) || name.hasSuffix("Tests") || name.hasSuffix(".xcodeproj") || name == "Package.swift" {
                    walker.skipDescendants()
                }
                continue
            }
            if name.hasSuffix(".swift"), name != "Package.swift" {
                out.append(url)
                if out.count >= limit { break }
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The package's executable targets, in manifest order: (name, sources directory).
    func executableTargets() -> [(name: String, directory: URL)] {
        guard kind == .package,
              let manifest = try? String(contentsOf: directory.appendingPathComponent("Package.swift"), encoding: .utf8) else { return [] }
        var targets: [(String, URL)] = []
        let pattern = #"\.executableTarget\s*\(\s*name:\s*"([^"]+)"([^)]*)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            for m in regex.matches(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)) {
                guard let nameRange = Range(m.range(at: 1), in: manifest) else { continue }
                let name = String(manifest[nameRange])
                var path = "Sources/\(name)"
                if let restRange = Range(m.range(at: 2), in: manifest),
                   let custom = Self.firstMatch(#"path:\s*"([^"]+)""#, in: String(manifest[restRange])) {
                    path = custom
                }
                targets.append((name, directory.appendingPathComponent(path)))
            }
        }
        if targets.isEmpty {
            // Older manifests declare executables as plain `.target`s with a main.swift.
            let sources = directory.appendingPathComponent("Sources")
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: sources.path))?.sorted() ?? [] {
                let dir = sources.appendingPathComponent(entry)
                let files = Self.swiftFiles(under: dir)
                if files.contains(where: { $0.lastPathComponent == "main.swift" }) || files.contains(where: Self.declaresMain) {
                    targets.append((entry, dir))
                }
            }
        }
        return targets
    }

    private static func declaresMain(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("@main")
    }

    /// The sources `swift run [target]` compiles, as (display path, text) pairs.
    func sources(target: String?) throws -> [(name: String, source: String)] {
        let files: [URL]
        switch kind {
        case .package:
            let targets = executableTargets()
            guard !targets.isEmpty else { throw SwiftProjectError("no executable target in Package.swift") }
            let chosen: (name: String, directory: URL)
            if let target {
                guard let match = targets.first(where: { $0.name == target }) else {
                    throw SwiftProjectError("no executable product '\(target)'; available: \(targets.map(\.name).joined(separator: ", "))")
                }
                chosen = match
            } else {
                chosen = targets[0]
            }
            files = Self.swiftFiles(under: chosen.directory)
        case .xcode:
            // The app target is the folder holding the `@main` type.
            let all = Self.swiftFiles(under: directory)
            if let entry = all.first(where: Self.declaresMain) {
                var appDir = entry.deletingLastPathComponent()
                while appDir.deletingLastPathComponent().path.count >= directory.path.count,
                      appDir.deletingLastPathComponent().standardizedFileURL != directory.standardizedFileURL {
                    appDir = appDir.deletingLastPathComponent()
                }
                files = Self.swiftFiles(under: appDir)
            } else {
                files = all
            }
        case .loose:
            files = Self.swiftFiles(under: directory)
        }
        guard !files.isEmpty else { throw SwiftProjectError("no Swift sources found") }
        return try files.map { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let rel = url.path.hasPrefix(directory.path) ? String(url.path.dropFirst(directory.path.count + 1)) : url.lastPathComponent
            return (rel, text)
        }
    }
}

struct SwiftProjectError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - The VM's thread

/// What the VM thread reports to the terminal.
enum SwiftRunEvent: Sendable {
    case output(String, isError: Bool)
    case frame(SwiftRenderedNode)
    case finished(status: Int32)
}

/// Owns a VM on a thread of its own. The VM is not thread-safe and does not need to be: every
/// touch happens on this thread, in job order, which is the confinement `@unchecked Sendable`
/// states. The thread's stack is large because native calls into the program (a `map`
/// transform, a getter) nest on it.
final class SwiftRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []
    private let available = DispatchSemaphore(value: 0)
    private var stopped = false
    private var finished = false
    private var thread: Thread?
    // Confined to the runner's thread.
    private var vm: SwiftVM?
    private var host: SwiftAppHost?
    private let events: @Sendable (SwiftRunEvent) -> Void

    init(events: @escaping @Sendable (SwiftRunEvent) -> Void) {
        self.events = events
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Stop the program: the VM polls this, and the thread exits once idle.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        available.signal()
    }

    private func enqueue(_ job: @escaping @Sendable () -> Void) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
        available.signal()
    }

    private func startThread() {
        let thread = Thread { [self] in
            while true {
                available.wait()
                lock.lock()
                if stopped && !finished {
                    finished = true
                    lock.unlock()
                    events(.finished(status: 130))
                    return
                }
                let job = jobs.isEmpty ? nil : jobs.removeFirst()
                lock.unlock()
                job?()
                lock.lock()
                let done = finished
                lock.unlock()
                if done { return }
            }
        }
        thread.stackSize = 64 << 20
        thread.name = "swift-vm"
        self.thread = thread
        thread.start()
    }

    private func finish(_ status: Int32) {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        if !already { events(.finished(status: status)) }
        available.signal()
    }

    /// Compile and run `files`. A command-line program runs to completion; an app renders its
    /// first frame and then waits for taps.
    func start(files: [(name: String, source: String)]) {
        startThread()
        let events = self.events
        enqueue { [self] in
            let program: SwiftProgram
            do {
                program = try SwiftCompiler.compile(files: files)
            } catch {
                events(.output("\(error)", isError: true))
                finish(1)
                return
            }
            var pending = ""
            let vm = SwiftVM(program: program) { text in
                pending += text
                // Complete lines go out as they are finished; a long run of output is chunked
                // so the terminal fills as the program runs rather than all at the end.
                if let cut = pending.lastIndex(of: "\n") {
                    events(.output(String(pending[..<cut]), isError: false))
                    pending = String(pending[pending.index(after: cut)...])
                }
            }
            vm.shouldStop = { [weak self] in self?.isStopped ?? true }
            self.vm = vm
            do {
                try vm.runMain()
                if !pending.isEmpty { events(.output(pending, isError: false)); pending = "" }
                if let root = try SwiftAppHost.rootView(vm: vm) {
                    let host = SwiftAppHost(vm: vm, root: root)
                    self.host = host
                    events(.frame(try host.render()))
                    return
                }
                finish(0)
            } catch {
                if !pending.isEmpty { events(.output(pending, isError: false)) }
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        switch error {
        case is SwiftInterrupted:
            finish(130)
        case let thrown as SwiftThrown:
            let text = vm.flatMap { try? SwiftRuntime.describe(thrown.value, vm: $0, debug: true) } ?? "error"
            events(.output("Fatal error: Error raised at top level: \(text)", isError: true))
            finish(1)
        default:
            events(.output("\(error)", isError: true))
            finish(1)
        }
    }

    /// A tap on a drawn control.
    func perform(_ action: Int) {
        enqueue { [self] in
            guard let host else { return }
            do {
                try host.perform(action)
                events(.frame(try host.render()))
            } catch {
                report(error)
            }
        }
    }

    /// A control's value changed (typing into a TextField, flipping a Toggle).
    func setBinding(_ id: Int, _ value: SwiftRenderedValue) {
        enqueue { [self] in
            guard let host else { return }
            host.setBinding(id, value)
            do {
                events(.frame(try host.render()))
            } catch {
                report(error)
            }
        }
    }
}

// MARK: - The app surface's model

/// A running SwiftUI program, as the terminal container sees it: the latest frame, and the way
/// back in for taps and edits.
@MainActor
@Observable
final class SwiftAppSession {
    let title: String
    private(set) var frame: SwiftRenderedNode?
    @ObservationIgnored private let runner: SwiftRunner

    init(title: String, runner: SwiftRunner) {
        self.title = title
        self.runner = runner
    }

    func show(_ frame: SwiftRenderedNode) {
        self.frame = frame
    }

    func perform(_ action: Int) {
        runner.perform(action)
    }

    func set(_ binding: Int, _ value: SwiftRenderedValue) {
        runner.setBinding(binding, value)
    }
}

// MARK: - The terminal program

/// `swift run`: a terminal program whose process is the VM thread. Output streams into the
/// scrollback; a SwiftUI program becomes the terminal's `surface`; ^C stops either.
@MainActor
final class SwiftRunProgram: TerminalProgram {
    let title: String
    let rendersScreen = false
    private(set) var surface: AnyObject?
    private let files: [(name: String, source: String)]
    private let transcript: (String, Bool) -> Void
    private var io: TerminalProgramIO?
    private var runner: SwiftRunner?
    private var app: SwiftAppSession?

    init(title: String, files: [(name: String, source: String)], transcript: @escaping (String, Bool) -> Void) {
        self.title = title
        self.files = files
        self.transcript = transcript
    }

    func start(io: TerminalProgramIO) {
        self.io = io
        // Events arrive on the VM thread and cross to the main thread through the main queue,
        // which is FIFO: output lines land in the order the program printed them.
        let target = WeakProgram(self)
        let runner = SwiftRunner { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { target.program?.handle(event) }
            }
        }
        self.runner = runner
        runner.start(files: files)
    }

    fileprivate func handle(_ event: SwiftRunEvent) {
        switch event {
        case .output(let text, let isError):
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                transcript(String(line), isError)
            }
        case .frame(let frame):
            if app == nil, let runner {
                let session = SwiftAppSession(title: title, runner: runner)
                app = session
                surface = session
                io?.modeChanged()
            }
            app?.show(frame)
        case .finished(let status):
            if status == 130 { transcript("^C", false) }
            surface = nil
            app = nil
            let io = self.io
            self.io = nil
            io?.exit()
        }
    }

    func input(_ text: String) {
        if text == "\u{3}" { runner?.stop() }
    }

    func resize(rows: Int, columns: Int) {}

    func terminate() {
        runner?.stop()
    }
}

/// The program as the VM thread's event closure holds it: weakly, so a stopped program is not
/// kept alive by its runner, and only dereferenced on the main thread.
private final class WeakProgram: @unchecked Sendable {
    weak var program: SwiftRunProgram?
    init(_ program: SwiftRunProgram) { self.program = program }
}
