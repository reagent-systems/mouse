import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Third sweep: the GLOBALS. Exports and instance shapes have been swept; nothing had looked at
// globalThis, where the web-standard surface modern packages reach for directly lives.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let probe = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let expected = (try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? ""

let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
let mine = await engine.run(source: probe, path: "/probe.js",
                            argv: ["node", "/probe.js"], cwd: "/", stdin: "")
if !mine.err.isEmpty { print("stderr: \(mine.err.prefix(400))") }

func rows(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 { out[parts[0]] = parts[1] }
    }
    return out
}
let theirs = rows(expected), ours = rows(mine.out)
print("node globals: \(theirs.count)  ours: \(ours.count)\n")

var absent: [String] = []
var different: [String] = []
for (name, kind) in theirs.sorted(by: { $0.key < $1.key }) {
    guard let mineKind = ours[name] else { absent.append("\(name) (\(kind))"); continue }
    if mineKind != kind { different.append("\(name): node=\(kind) ours=\(mineKind)") }
}
// Promoted from a one-shot sweep to a GATE. The absent set is settled and deliberate: Crypto,
// CryptoKey and SubtleCrypto stay away so a library feature-detecting crypto.subtle takes its
// fallback path (exposing the type names would undo the refusal), PerformanceObserver needs real
// entry observation rather than a constructor that observes nothing, and the rest are WHATWG
// stream controller/reader internals reachable only through instanceof. What must never happen
// is a global QUIETLY DISAPPEARING or changing kind — that is what this now catches.
// 19, not the 18 I wrote in the globals boundary's record: the original sweep found 21 absent,
// and adding TextDecoderStream and TextEncoderStream left nineteen. The gate's first run caught
// that arithmetic error in my own report rather than a regression — which is still exactly what a
// gate is for, since the alternative was the wrong number sitting in system.md unchallenged.
let expectedAbsent = 19
print("--- ABSENT HERE (\(absent.count)) ---")
for line in absent { print("  " + line) }
print("\n--- DIFFERENT KIND (\(different.count)) ---")
for line in different { print("  " + line) }
let regressed = different.count > 0 || absent.count > expectedAbsent
print(regressed
      ? "\nGLOBALS REGRESSED — \(absent.count) absent (was \(expectedAbsent)), \(different.count) wrong kind"
      : "\nGLOBALS MATCH — \(theirs.count - absent.count) present, \(absent.count) deliberately absent, none of the wrong kind")
exit(regressed ? 1 : 0)
