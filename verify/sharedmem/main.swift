import Foundation
import JavaScriptCore
setvbuf(stdout, nil, _IONBF, 0)

// What JavaScriptCore will and will not do with wasm threads, measured rather than assumed —
// because the answer decides whether a whole class of packages can ever run here. It is a
// two-part wall and only the second part is real: `new WebAssembly.Memory({shared: true})` is
// ACCEPTED and quietly hands back ordinary memory, so a check on the constructor tells you
// nothing; a MODULE whose memory is declared shared does not parse, which is where it stops.
// rolldown, oxc and every napi-rs build with threads is on the far side of that.

let context = JSContext()!
context.exceptionHandler = { _, exception in print("exception: \(exception?.toString() ?? "?")") }

// A wasm module with a SHARED memory: the flags byte is 0x03 (has-maximum + shared).
func leb(_ value: Int) -> [UInt8] {
    var remaining = value, out: [UInt8] = []
    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        out.append(byte)
    } while remaining != 0
    return out
}
var memorySection: [UInt8] = [0x05]
var entry: [UInt8] = leb(1)
entry += [0x03]
entry += leb(1)
entry += leb(2)
memorySection += leb(entry.count)
memorySection += entry
var shared: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
shared += memorySection
let hex = shared.map { String(format: "%02x", $0) }.joined()

let result = context.evaluateScript("""
const bytes = new Uint8Array('\(hex)'.match(/../g).map((pair) => parseInt(pair, 16)));
const answers = {};
try {
  const memory = new WebAssembly.Memory({ initial: 1, maximum: 2, shared: true });
  answers.constructorAccepts = memory.buffer.constructor.name;
} catch (error) { answers.constructorAccepts = 'threw'; }
try {
  new WebAssembly.Module(bytes);
  answers.sharedModuleParses = true;
} catch (error) {
  answers.sharedModuleParses = false;
  answers.reason = String(error.message).slice(0, 80);
}
JSON.stringify(answers);
""")?.toString() ?? "{}"
print("JavaScriptCore: \(result)")

if result.contains("\"constructorAccepts\":\"ArrayBuffer\""), result.contains("\"sharedModuleParses\":false"),
   result.contains("shared memory is not enabled") {
    // "MATCH" because the suite reads a verdict by keyword, and this IS one: the platform
    // still answers exactly what it answered when this was written down.
    print("SHARED MEMORY MATCH — the constructor accepts `shared: true` and returns ordinary "
          + "memory, and a module declaring shared memory does not parse: wasm threads are off, "
          + "and feature-detecting on the constructor would miss it")
} else {
    print("MISMATCH: the shared-memory measurement changed — re-read what wasm threads do here")
    exit(1)
}
