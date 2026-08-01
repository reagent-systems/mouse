import Foundation
let script = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "echo none"
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("msh-debug-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let shell = MouseShell()
let context = MouseShell.Context(root: dir)
let outputs = await shell.runProgram(script, context: context, interactive: false)
for output in outputs { print("\(output.isError ? "ERR" : "OUT"): \(output.text)") }
print("status: \(shell.lastStatus)")
try? FileManager.default.removeItem(at: dir)
