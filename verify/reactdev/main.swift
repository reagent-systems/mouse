import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// React on a phone. vite serves .tsx by handing it to ESBUILD — which here is the WebAssembly
// build the package manager substitutes, driven through a live child process — so this is the
// first thing that makes esbuild do real work under a dev server rather than in a one-shot
// harness. If a .tsx module comes back as JSX-free JavaScript with React's automatic runtime
// import in it, then a React project is editable on the device.

let base = FileManager.default.temporaryDirectory.appendingPathComponent("reactdev-\(getpid())")
let app = base.appendingPathComponent("app")
try? FileManager.default.createDirectory(at: app.appendingPathComponent("src"), withIntermediateDirectories: true)
print("installing vite + react…")
do {
    _ = try await PackageManager.install(
        requirements: ["vite": "^5.4.0", "@vitejs/plugin-react": "^4.3.0",
                       "react": "^18.3.0", "react-dom": "^18.3.0"], into: base)
} catch { print("FAIL: install: \(error)"); exit(1) }

func put(_ text: String, _ path: String) {
    try? text.write(to: app.appendingPathComponent(path), atomically: true, encoding: .utf8)
}
put(#"""
{
  "name": "reactapp", "private": true, "type": "module",
  "scripts": { "dev": "vite --port 5401 --host 127.0.0.1" }
}
"""#, "package.json")
put("<!doctype html><div id=\"root\"></div><script type=\"module\" src=\"/src/main.tsx\"></script>\n", "index.html")
// The config a React project actually ships: the plugin brings the automatic JSX runtime and
// Fast Refresh, which is babel doing a second pass over what esbuild already compiled.
put("""
    import { defineConfig } from 'vite';
    import react from '@vitejs/plugin-react';
    export default defineConfig({ plugins: [react()] });
    """, "vite.config.js")
put("""
    import { useState } from 'react';

    type Props = { name: string };

    export function Greeting({ name }: Props) {
      const [count, setCount] = useState(0);
      return (
        <div className="greeting">
          <h1>hello {name}</h1>
          <button onClick={() => setCount(count + 1)}>clicked {count} times</button>
        </div>
      );
    }
    """, "src/Greeting.tsx")
put("""
    import { createRoot } from 'react-dom/client';
    import { Greeting } from './Greeting.tsx';

    createRoot(document.getElementById('root')!).render(<Greeting name="mouse" />);
    """, "src/main.tsx")

@MainActor final class Host { var program: TerminalProgram?; var exited = false }
let host = await Host()
let prompt = await MainActor.run { () -> Task<[MouseShell.Output], Never> in
    Task { @MainActor in
        let shell = MouseShell()
        var context = MouseShell.Context(root: base)
        context.launchProgram = { program in
            host.program = program
            program.start(io: TerminalProgramIO(rows: 24, columns: 80, write: { _ in }, exit: { host.exited = true }))
        }
        return await shell.runProgram("cd app && npm run dev", context: context, interactive: true)
    }
}
_ = await prompt.value
try? await Task.sleep(nanoseconds: 8_000_000_000)

func fetchText(_ path: String) async -> String {
    do {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:5401" + path)!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return code == 200 ? String(decoding: data, as: UTF8.self) : "status \(code)"
    } catch { return "failed: \(error.localizedDescription)" }
}

let component = await fetchText("/src/Greeting.tsx")
let entry = await fetchText("/src/main.tsx")
// A transformed .tsx has no angle brackets left and carries React's automatic-runtime import.
// Compiled means the JSX SYNTAX is gone and a runtime call took its place — which call
// depends on the runtime in use, and the plugin selects the automatic one.
let compiled = !component.contains("<div className")
    && (component.contains("jsxDEV") || component.contains("jsx(") || component.contains("createElement"))
let automaticRuntime = component.contains("jsx-dev-runtime") || component.contains("jsx-runtime")
let fastRefresh = component.contains("RefreshReg") || component.contains("refreshreg")
let typesGone = !component.contains("type Props")
let hooked = component.contains("useState")
print("Greeting.tsx: \(component.count) bytes, jsx compiled: \(compiled), types erased: \(typesGone), "
      + "hook kept: \(hooked), automatic runtime: \(automaticRuntime), fast refresh: \(fastRefresh)")
print("first line: \(component.components(separatedBy: "\n").first ?? "")")
let entryCompiled = !entry.contains("<Greeting name") && entry.contains("createRoot")
print("main.tsx: \(entry.count) bytes, compiled: \(entryCompiled)")

// react itself has to be served too — vite rewrites the bare specifier to its own dep path.
let reactImport = component.contains("/node_modules/") || component.contains("/@")
print("bare imports rewritten: \(reactImport)")

await MainActor.run { host.program?.input("\u{3}") }
try? await Task.sleep(nanoseconds: 1_200_000_000)

if compiled, typesGone, hooked, entryCompiled, automaticRuntime, fastRefresh, reactImport {
    print("REACT DEV MATCH — vite served .tsx with types erased, JSX compiled to React's "
          + "automatic runtime, Fast Refresh wired in and `react` itself pre-bundled: the "
          + "WebAssembly esbuild doing a dev server's real work on the device")
} else {
    print("MISMATCH: React through vite\n\(component.prefix(400))")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
