import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// `node app.ts`. Node itself grew this in 22.6 (`--experimental-transform-types`), and it is
// what an iOS IDE's users write, so the engine compiles TypeScript with the project's OWN
// typescript package — the ts-node model. Type erasure is not a text substitution: enums,
// parameter properties, decorators and `satisfies` all change the emitted JavaScript, and a
// partial stripper would be wrong on real code rather than merely incomplete.
//
// Real node with its transform-types flag is the peer, so two independent TypeScript
// implementations — node's swc-based one and Microsoft's own compiler — have to agree on what
// the program PRINTS.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("typescript-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
print("installing typescript with our own package manager…")
do { _ = try await PackageManager.install(requirements: ["typescript": "^5.6.0", "tsx": "^4.19.0"], into: base) }
catch { print("FAIL: install: \(error)"); exit(1) }

func put(_ text: String, _ name: String) {
    try? text.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
put("""
    export interface Point { x: number; y: number }
    export type Label = 'near' | 'far';
    export function distance(p: Point): number { return Math.abs(p.x) + Math.abs(p.y); }
    export const label = (n: number): Label => (n < 5 ? 'near' : 'far');
    """, "lib.ts")
put("""
    import { distance, label, type Point } from './lib.ts';

    const origin = { x: 3, y: 4 } satisfies Point;
    const values: number[] = [1, 2, 3];

    // Parameter properties and default values: a declaration form with no JavaScript equivalent.
    class Counter {
      constructor(private start: number = 0, readonly step: number = 1) {}
      bump(by: number = this.step): number { return this.start + by; }
    }

    // An enum is an OBJECT at runtime, not a type — the clearest case that erasure is a compile.
    enum Colour { Red = 'red', Blue = 'blue' }

    // Generics, optional parameters, non-null assertions, `as`.
    function first<T>(items: T[], fallback?: T): T { return items.length ? items[0]! : (fallback as T); }

    abstract class Shape { abstract area(): number; describe(): string { return 'area ' + this.area(); } }
    class Square extends Shape { constructor(private side: number) { super(); } area(): number { return this.side ** 2; } }

    console.log('distance', distance(origin), label(distance(origin)));
    console.log('sum', values.reduce((a: number, b: number) => a + b, 0));
    console.log('counter', new Counter(5).bump(2), new Counter(5).bump());
    console.log('enum', Colour.Blue, Object.keys(Colour).join('|'));
    console.log('generic', first<number>([9, 8]), first<string>([], 'none'));
    console.log('shape', new Square(3).describe());
    """, "main.ts")

// A second project, this one shaped like a real one: a tsconfig with a target, decorators and
// `paths` aliases. Node's own transform-types cannot resolve an alias — that is a project
// convention, not a language feature — so the peer here is tsx, which reads the same tsconfig.
put("""
    {
      "compilerOptions": {
        "target": "ES2020",
        "experimentalDecorators": true,
        "useDefineForClassFields": false,
        "baseUrl": ".",
        "paths": { "@app/*": ["./src/*"], "@config": ["./src/settings.ts"] }
      }
    }
    """, "tsconfig.json")
try? FileManager.default.createDirectory(at: base.appendingPathComponent("src"), withIntermediateDirectories: true)
put("export const settings = { name: 'aliased' };\n", "src/settings.ts")
put("""
    export function shout(text: string): string { return text.toUpperCase(); }
    export default class Greeter { constructor(public who: string) {} greet(): string { return 'hi ' + this.who; } }
    """, "src/greet.ts")
put("""
    import Greeter, { shout } from '@app/greet.ts';
    import { settings } from '@config';

    function logged(target: any, key: string, descriptor: PropertyDescriptor) {
      const inner = descriptor.value;
      descriptor.value = function (...args: unknown[]) { return 'logged:' + inner.apply(this, args); };
      return descriptor;
    }
    class Service {
      @logged run(n: number): string { return 'ran ' + n; }
    }

    console.log(shout(settings.name), new Greeter('mouse').greet());
    console.log(new Service().run(2));
    """, "aliased.ts")

let real = Process()
real.executableURL = URL(fileURLWithPath: realNode)
real.arguments = ["--experimental-transform-types", "--no-warnings", "main.ts"]
real.currentDirectoryURL = base
let out = Pipe(), err = Pipe()
real.standardOutput = out
real.standardError = err
try? real.run()
let realText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let realProblems = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
real.waitUntilExit()
if !realProblems.isEmpty { print("real stderr: \(realProblems.prefix(400))") }

let source = try! String(contentsOf: base.appendingPathComponent("main.ts"), encoding: .utf8)
let engine = NodeEngine(root: base, env: ["PATH": "/"])
let ours = await engine.run(source: source, path: "/main.ts", argv: ["node", "/main.ts"], cwd: "/", stdin: "")
if !ours.err.isEmpty { print("ours stderr: \(ours.err.prefix(800))") }

// And with no typescript installed, the refusal has to be the actionable one — not a
// SyntaxError pointing at a type annotation, which tells the reader nothing they can use.
let bare = FileManager.default.temporaryDirectory.appendingPathComponent("typescript-bare-\(getpid())")
try? FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
try? "const x: number = 1; console.log(x);".write(to: bare.appendingPathComponent("solo.ts"),
                                                  atomically: true, encoding: .utf8)
let bareEngine = NodeEngine(root: bare, env: ["PATH": "/"])
let bareRun = await bareEngine.run(source: "const x: number = 1; console.log(x);", path: "/solo.ts",
                                   argv: ["node", "/solo.ts"], cwd: "/", stdin: "")

print("---- ours ----\n\(ours.out)---- real ----\n\(realText)")
print("without typescript installed: \(bareRun.err.trimmingCharacters(in: .whitespacesAndNewlines))")

// The aliased project, through tsx on real node and through this engine natively.
let viaTsx = Process()
viaTsx.executableURL = URL(fileURLWithPath: realNode)
viaTsx.arguments = ["--import", "tsx", "--no-warnings", "aliased.ts"]
viaTsx.currentDirectoryURL = base
let tsxOut = Pipe(), tsxErr = Pipe()
viaTsx.standardOutput = tsxOut
viaTsx.standardError = tsxErr
try? viaTsx.run()
let tsxText = String(decoding: tsxOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let tsxProblems = String(decoding: tsxErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
viaTsx.waitUntilExit()
if !tsxProblems.isEmpty { print("tsx stderr: \(tsxProblems.prefix(400))") }

let aliasedSource = try! String(contentsOf: base.appendingPathComponent("aliased.ts"), encoding: .utf8)
let aliasEngine = NodeEngine(root: base, env: ["PATH": "/"])
let aliased = await aliasEngine.run(source: aliasedSource, path: "/aliased.ts",
                                    argv: ["node", "/aliased.ts"], cwd: "/", stdin: "")
if !aliased.err.isEmpty { print("ours (aliased) stderr: \(aliased.err.prefix(600))") }
print("---- ours (tsconfig + paths) ----\n\(aliased.out)---- tsx ----\n\(tsxText)")

if ours.out == realText, !realText.isEmpty, ours.status == real.terminationStatus,
   aliased.out == tsxText, !tsxText.isEmpty,
   bareRun.err.contains("typescript"), bareRun.status == 1 {
    let lines = realText.components(separatedBy: "\n").filter { !$0.isEmpty }.count
          + tsxText.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    print("TYPESCRIPT MATCH — \(lines) lines identical to real node's own transform-types and to "
          + "tsx on the same tsconfig (target, decorators, paths aliases), and a project without "
          + "typescript is told exactly that")
} else {
    print("MISMATCH: TypeScript execution")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
try? FileManager.default.removeItem(at: bare)
