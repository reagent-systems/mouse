import Foundation

// The Swift VM gate. Every program in corpus/ was run through real swiftc (`-module-name main`)
// and its output recorded beside it as <name>.txt; the VM must reproduce that output byte for
// byte. Then: runtime traps and compile errors say what Swift says, a SwiftUI app renders and
// responds to taps headlessly, Swift projects are detected (and non-projects are not), the
// threaded runner streams output and stops on ^C, and appends stay linear.

var failures: [String] = []
func check(_ ok: Bool, _ label: String) {
    if !ok { failures.append(label) }
    print("  \(ok ? "ok  " : "FAIL") \(label)")
}

func run(_ source: String, files extra: [(String, String)] = []) -> (out: String, error: String?) {
    var out = ""
    do {
        let program = try SwiftCompiler.compile(files: [("main.swift", source)] + extra)
        let vm = SwiftVM(program: program) { out += $0 }
        try vm.runMain()
        return (out, nil)
    } catch {
        return (out, "\(error)")
    }
}

// MARK: Corpus against real swiftc

print("corpus (byte-identical to swiftc)")
let corpus = URL(fileURLWithPath: "corpus")
let names = ((try? FileManager.default.contentsOfDirectory(atPath: corpus.path)) ?? [])
    .filter { $0.hasSuffix(".swift") }.sorted()
check(names.count >= 13, "corpus present (\(names.count) programs)")
for name in names {
    let base = String(name.dropLast(6))
    guard let source = try? String(contentsOf: corpus.appendingPathComponent(name), encoding: .utf8),
          let expected = try? String(contentsOf: corpus.appendingPathComponent(base + ".txt"), encoding: .utf8) else {
        check(false, "\(base): unreadable")
        continue
    }
    let result = run(source)
    let actual = result.out + (result.error.map { $0 + "\n" } ?? "")
    if actual != expected {
        let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let e = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let firstDiff = (0..<min(a.count, e.count)).first { a[$0] != e[$0] } ?? min(a.count, e.count)
        print("    first difference at line \(firstDiff + 1):")
        print("      swiftc: \(firstDiff < e.count ? String(e[firstDiff]) : "<end>")")
        print("      vm:     \(firstDiff < a.count ? String(a[firstDiff]) : "<end>")")
    }
    check(actual == expected, base)
}

// MARK: Traps and compile errors

print("traps and compile errors")
let traps: [(String, String, String)] = [
    ("let a = [1, 2, 3]\nprint(\"before\")\nprint(a[5])", "before\n", "Fatal error: Index out of range (line 3)"),
    ("let v: Int? = nil\nprint(v!)", "", "Fatal error: Unexpectedly found nil while unwrapping an Optional value (line 2)"),
    ("var x = Int.max\nx += 1", "", "Fatal error: arithmetic overflow (line 2)"),
    ("print(1 / (2 - 2))", "", "Fatal error: Division by zero (line 1)"),
    ("fatalError(\"boom\")", "", "Fatal error: boom (line 1)"),
    ("func f(_ n: Int) -> Int { f(n + 1) }\nprint(f(0))", "", "stack overflow"),
    ("print(undefinedName)", "", "main.swift:1: error: cannot find 'undefinedName' in scope"),
    ("let s = \"unterminated\nprint(s)", "", "main.swift:1: error: unterminated string literal"),
    ("struct P { var x: Int }\nlet p = P(y: 1)", "", "missing argument for parameter 'x'"),
]
for (source, expectedOut, expectedError) in traps {
    let result = run(source)
    check(result.out == expectedOut && (result.error ?? "").contains(expectedError),
          "\(expectedError) — got \(result.error ?? "no error")")
}

// MARK: A SwiftUI app, headless

print("SwiftUI host")
let appSource = """
import SwiftUI

struct Row: View {
    let title: String
    @Binding var done: Bool
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(done ? "undo" : "done") { done.toggle() }
        }
    }
}

struct Tally: View {
    @State private var taps = 0
    var body: some View {
        Button("tally \\(taps)") { taps += 1 }
    }
}

struct ContentView: View {
    @State private var count = 0
    @State private var name = ""
    @State private var finished = false
    let items = ["a", "b"]
    var body: some View {
        VStack(spacing: 12) {
            Text("Count: \\(count)")
                .font(.largeTitle)
                .foregroundColor(.blue)
            Button("Increment") { count += 1 }
            if count > 1 {
                Text("more than one")
            }
            TextField("Name", text: $name)
            Text(name.isEmpty ? "anonymous" : "hi \\(name)")
            Row(title: "task", done: $finished)
            Tally()
            ForEach(items, id: \\.self) { item in
                Text(item.uppercased())
            }
        }
        .padding()
    }
}

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
"""

func texts(_ node: SwiftRenderedNode) -> [String] {
    (node.text.map { [$0] } ?? []) + node.children.flatMap(texts)
}
func find(_ node: SwiftRenderedNode, _ kind: String, _ text: String? = nil) -> SwiftRenderedNode? {
    if node.kind == kind && (text == nil || node.text == text) { return node }
    for child in node.children { if let hit = find(child, kind, text) { return hit } }
    return nil
}

func tap(_ host: SwiftAppHost, _ frame: SwiftRenderedNode, _ title: String) throws {
    guard let action = find(frame, "Button", title)?.action else { throw SwiftProjectError("no button '\(title)'") }
    try host.perform(action)
}

do {
    let program = try SwiftCompiler.compile(files: [("App.swift", appSource)])
    let vm = SwiftVM(program: program) { _ in }
    try vm.runMain()
    guard let root = try SwiftAppHost.rootView(vm: vm) else { throw SwiftProjectError("no root view") }
    let host = SwiftAppHost(vm: vm, root: root)
    var frame = try host.render()
    check(texts(frame).contains("Count: 0"), "first frame shows Count: 0")
    check(texts(frame).contains("A") && texts(frame).contains("B"), "ForEach rendered its rows")
    check(!texts(frame).contains("more than one"), "if-branch hidden at 0")
    let countText = find(frame, "Text", "Count: 0")
    check(countText?.modifiers.map(\.name) == ["font", "foregroundColor"], "modifiers carried in order")
    check(countText?.modifiers.first?.values == [.name("largeTitle")], "font resolves to .largeTitle")
    check(frame.modifiers.first?.name == "padding", "container modifier on the root VStack")
    guard let increment = find(frame, "Button", "Increment")?.action else { throw SwiftProjectError("no increment action") }
    try host.perform(increment)
    frame = try host.render()
    try tap(host, frame, "Increment")
    frame = try host.render()
    check(texts(frame).contains("Count: 2"), "two taps → Count: 2 (state persists across renders)")
    check(texts(frame).contains("more than one"), "if-branch shown after state change")
    guard let field = find(frame, "TextField")?.binding else { throw SwiftProjectError("no text binding") }
    host.setBinding(field, .string("Ann"))
    frame = try host.render()
    check(texts(frame).contains("hi Ann"), "TextField binding writes @State")
    check(texts(frame).contains("done"), "child view reads @Binding")
    try tap(host, frame, "done")
    frame = try host.render()
    check(texts(frame).contains("undo"), "child's @Binding write reaches the parent's @State")
    check(texts(frame).contains("Count: 2"), "unrelated state untouched")
    // A child's own @State survives its parent rebuilding it: the store keys it by position.
    try tap(host, frame, "tally 0")
    frame = try host.render()
    try tap(host, frame, "tally 1")
    frame = try host.render()
    check(texts(frame).contains("tally 2"), "a rebuilt child keeps its own @State")
} catch {
    check(false, "SwiftUI app: \(error)")
}

// MARK: Project detection

print("project detection")
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("swiftvm-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: scratch)
func write(_ path: String, _ text: String) {
    let url = scratch.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
write("pkg/Package.swift", """
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Greeter",
    targets: [
        .target(name: "Lib"),
        .executableTarget(name: "greet", dependencies: ["Lib"]),
        .testTarget(name: "GreeterTests"),
    ]
)
""")
write("pkg/Sources/greet/main.swift", "print(greeting(\"pkg\"))\n")
write("pkg/Sources/greet/Greeting.swift", "func greeting(_ n: String) -> String { \"hello \\(n)\" }\n")
write("pkg/Sources/Lib/Lib.swift", "public func lib() {}\n")
write("pkg/Tests/GreeterTests/T.swift", "import XCTest\n")
write("app/Demo.xcodeproj/project.pbxproj", "")
write("app/Demo/DemoApp.swift", "@main struct DemoApp: App { var body: some Scene { WindowGroup { ContentView() } } }\n")
write("app/Demo/ContentView.swift", "struct ContentView: View { var body: some View { Text(\"x\") } }\n")
write("app/DemoTests/DemoTests.swift", "import XCTest\n")
write("loose/hello.swift", "print(\"loose\")\n")
write("node/package.json", "{}\n")
write("node/index.js", "\n")

let pkg = SwiftProject.detect(root: scratch, directory: scratch.appendingPathComponent("pkg/Sources/greet"))
check(pkg?.kind == .package && pkg?.name == "Greeter", "package found from a subdirectory: \(pkg.map { "\($0.kind) \($0.name)" } ?? "nil")")
let pkgSources = (try? pkg?.sources(target: nil)) ?? []
check(pkgSources.map(\.name) == ["Sources/greet/Greeting.swift", "Sources/greet/main.swift"], "executable target's sources only: \(pkgSources.map(\.name))")
check(run(pkgSources.first { $0.name.hasSuffix("main.swift") }!.source, files: pkgSources.filter { !$0.name.hasSuffix("main.swift") }).out == "hello pkg\n", "package runs across files")
check((try? pkg?.sources(target: "nope")) == nil, "unknown target refused")
let app = SwiftProject.detect(root: scratch, directory: scratch.appendingPathComponent("app"))
check(app?.kind == .xcode && app?.name == "Demo", "Xcode project found")
check(((try? app?.sources(target: nil)) ?? []).map(\.name) == ["Demo/ContentView.swift", "Demo/DemoApp.swift"], "app target's sources, tests excluded")
check(SwiftProject.detect(root: scratch, directory: scratch.appendingPathComponent("loose"))?.kind == .loose, "loose .swift files found")
check(SwiftProject.detect(root: scratch, directory: scratch.appendingPathComponent("node")) == nil, "a Node project is not a Swift project")
try? FileManager.default.removeItem(at: scratch)

// MARK: The threaded runner

print("runner")
final class Collector: @unchecked Sendable {
    let lock = NSLock()
    var events: [SwiftRunEvent] = []
    let done = DispatchSemaphore(value: 0)
    func add(_ e: SwiftRunEvent) {
        lock.lock(); events.append(e); lock.unlock()
        if case .finished = e { done.signal() }
    }
    var output: String {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap { if case .output(let t, false) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }
    var status: Int32? {
        lock.lock(); defer { lock.unlock() }
        for e in events { if case .finished(let s) = e { return s } }
        return nil
    }
}
do {
    let c = Collector()
    let runner = SwiftRunner { c.add($0) }
    runner.start(files: [("main.swift", "for i in 1...3 { print(\"line \\(i)\") }\nprint(\"end\", terminator: \"\")")])
    let finished = c.done.wait(timeout: .now() + 10) == .success
    check(finished && c.status == 0, "CLI program finishes with status 0")
    check(c.output == "line 1\nline 2\nline 3\nend", "output streamed in order: \(c.output.debugDescription)")
}
do {
    let c = Collector()
    let runner = SwiftRunner { c.add($0) }
    runner.start(files: [("main.swift", "var n = 0\nwhile true { n += 1 }")])
    Thread.sleep(forTimeInterval: 0.3)
    runner.stop()
    let finished = c.done.wait(timeout: .now() + 10) == .success
    check(finished && c.status == 130, "^C stops an infinite loop (status 130)")
}
do {
    let c = Collector()
    let runner = SwiftRunner { c.add($0) }
    runner.start(files: [("main.swift", "let x = \n")])
    _ = c.done.wait(timeout: .now() + 10)
    check(c.status == 1, "a compile error ends the run with status 1")
}

// MARK: Performance

print("performance")
let perfSource = """
var list: [Int] = []
for i in 0..<200_000 { list.append(i) }
struct Bag { var items: [Int] = [] }
var bag = Bag()
for i in 0..<100_000 { bag.items.append(i) }
var text = ""
for _ in 0..<100_000 { text += "x" }
func fib(_ n: Int) -> Int { n < 2 ? n : fib(n - 1) + fib(n - 2) }
print(list.count, bag.items.count, text.count, fib(22))
"""
let started = Date()
let perf = run(perfSource)
let elapsed = Date().timeIntervalSince(started)
check(perf.out == "200000 100000 100000 17711\n", "perf program output")
check(elapsed < 5, "appends stay linear (\(String(format: "%.2f", elapsed))s)")

print(failures.isEmpty ? "ALL PASS — swiftvm" : "FAILED — \(failures.count) swiftvm checks")
