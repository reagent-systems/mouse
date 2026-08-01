import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The sweep that generalises six gaps found one at a time by hand: call every function export
// with no arguments in BOTH engines and classify the failure. Our refusals say "is not
// available:", so they are distinguishable from a function that merely wants arguments.
// Anything WE refuse and node does not is a candidate reachable gap.
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let probe = (try? String(contentsOf: here.appendingPathComponent("probe.js"), encoding: .utf8)) ?? ""
let modules = ["fs", "path", "os", "util", "events", "stream", "buffer", "crypto", "zlib",
               "net", "http", "https", "dns", "readline", "child_process", "url", "querystring",
               "string_decoder", "timers", "assert", "tty", "worker_threads", "cluster", "dgram",
               "v8", "vm", "perf_hooks", "http2", "tls"]   // inspector blocks in node itself

func parse(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3 { out[parts[0] + "." + parts[1]] = parts[2] }
    }
    return out
}

let nodeText = (try? String(contentsOf: here.appendingPathComponent("node.txt"), encoding: .utf8)) ?? ""
let theirs = parse(nodeText)

var oursText = ""
for module in modules {
    let engine = NodeEngine(root: here, env: ["PATH": "/usr/bin"])
    let result = await engine.run(source: probe, path: "/probe.js",
                                  argv: ["node", "/probe.js", module], cwd: "/", stdin: "")
    oursText += result.out
    if !result.err.isEmpty, result.out.isEmpty {
        print("[\(module)] stderr: \(result.err.prefix(200))")
    }
}
let ours = parse(oursText)
print("node entries: \(theirs.count)  ours: \(ours.count)")

// The interesting set: node has it working (or merely wanting arguments), we refuse.
var reachable: [String] = []
var missing: [String] = []
for (key, theirVerdict) in theirs {
    guard let ourVerdict = ours[key] else { missing.append(key); continue }
    if ourVerdict == "refused", theirVerdict != "refused", theirVerdict != "module-refused" {
        reachable.append("\(key)  (node: \(theirVerdict))")
    }
}
print("\n--- WE REFUSE, NODE DOES NOT (\(reachable.count)) ---")
for line in reachable.sorted() { print("  " + line) }
print("\n--- EXPORT ABSENT HERE (\(missing.count)) ---")
for line in missing.sorted().prefix(40) { print("  " + line) }
