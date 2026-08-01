import Foundation
let dir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path + "/chalk-dbg")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("node_modules/chalk").path) {
    _ = try await PackageManager.install(requirements: ["chalk": "5.3.0"], into: dir)
}
let script = "import chalk from 'chalk';\nconsole.log(chalk.red('warning'));"
let engine = NodeEngine(root: dir, env: [:])
let result = await engine.run(source: script, path: "/main.mjs", argv: ["node", "/main.mjs"], cwd: "/", stdin: "")
print("status \(result.status)\nOUT: \(result.out)ERR: \(result.err)")
