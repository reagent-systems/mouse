import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Unhandled rejections were the last gap on record whose blocker was a platform limit rather
// than effort: a userland tracker cannot see them, because patching Promise.prototype.then is
// called ZERO times by `await` (JSC's await goes through the internal PerformPromiseThen). The
// refusal said JSC exposes no rejection hook — true of the public headers, false of the
// exported symbols. This gates the contract that follows from having one: node's exit status
// and stdout for each shape of rejection, handled and unhandled.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let cases = ((try? String(contentsOf: here.appendingPathComponent("cases.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init)
var expected: [String: (Int32, String)] = [:]
for line in ((try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init) {
    let parts = line.components(separatedBy: "|")
    guard parts.count >= 3, let r = line.range(of: "|<- ") else { continue }
    expected[String(line[r.upperBound...])] = (Int32(parts[0]) ?? -1, parts[1])
}
var bad = 0
for source in cases {
    let engine = NodeEngine(root: here, env: [:])
    let mine = await engine.run(source: source, path: "/e.js", argv: ["node", "-e", source], cwd: "/", stdin: "")
    guard let (wantStatus, wantOut) = expected[source] else { continue }
    let gotOut = mine.out.trimmingCharacters(in: .whitespacesAndNewlines)
    if mine.status != wantStatus || gotOut != wantOut {
        print("  node: exit=\(wantStatus) out=\(wantOut.isEmpty ? "<none>" : wantOut)")
        print("  ours: exit=\(mine.status) out=\(gotOut.isEmpty ? "<none>" : gotOut)")
        print("    <- \(source.prefix(76))")
        bad += 1
    }
}
if bad == 0 {
    print("REJECTIONS MATCH — all \(cases.count) cases exit as node does")
} else {
    print("REJECTIONS DIFFER — \(bad) of \(cases.count)")
    exit(1)
}
