import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The export sweep called functions; this one looks at OBJECTS. Two of this engine's worst bugs
// were instance-shape bugs invisible to an export list: Buffer's statics were non-enumerable, so
// express broke on every route, and fs.Stats had no `mode`, so chokidar hid every file.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let probe = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = (try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? ""

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: probe, path: "/probe.js",
                            argv: ["node", "/probe.js"], cwd: "/", stdin: "")
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }

func rows(_ text: String) -> [String: Set<String>] {
    var out: [String: Set<String>] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { continue }
        out[parts[0]] = Set(parts[1].split(separator: " ").map(String.init))
    }
    return out
}
let theirs = rows(expected), ours = rows(mine.out)
print("shapes — node: \(theirs.count)  ours: \(ours.count)\n")

// Properties node's object has that ours does not. Numeric indices and typed-array internals are
// noise on a Buffer, so they are dropped rather than reported as gaps.
let noise: Set<String> = ["apply", "arguments", "bind", "call", "caller", "length", "name",
                          "toString", "valueOf", "hasOwnProperty", "isPrototypeOf",
                          "propertyIsEnumerable", "toLocaleString", "prototype"]
var total = 0
for label in theirs.keys.sorted() {
    guard let mineSet = ours[label] else { print("\(label): MISSING ENTIRELY"); continue }
    let missing = theirs[label]!.subtracting(mineSet)
        .filter { !noise.contains($0) && Int($0) == nil && !$0.hasPrefix("Symbol(") }
    if !missing.isEmpty {
        total += missing.count
        print("\(label) missing \(missing.count): \(missing.sorted().joined(separator: " "))")
    }
}
print("\ntotal properties node has and we do not: \(total)")
