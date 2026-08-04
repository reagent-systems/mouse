import Foundation
let source = try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), encoding: .utf8)
print(NodeEngine.transpileESM(source))
