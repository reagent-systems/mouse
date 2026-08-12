import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// The ESM statement grammar, form by form, against real node. Two holes in it were found by
// accident this week — `export async function*` and a pattern anchor that reached across the
// newline — and both had been invisible because dual packages resolved to their CommonJS half.
// A transpiler that works by pattern is only as good as its enumeration of the grammar, so the
// grammar is enumerated here rather than trusted.
//
// Each case is a whole little package: main.mjs plus whatever it imports. Both engines run it
// and their stdout must be identical.

let realNode = "/Users/thyfriendlyfox/.local/bin/node"
let base = FileManager.default.temporaryDirectory.appendingPathComponent("esmgrammar-\(getpid())")
try? FileManager.default.removeItem(at: base)

struct Case {
    let name: String
    let files: [String: String]
    /// Set when this engine is KNOWN to differ from node here. The case then pins both sides,
    /// so the divergence cannot widen and cannot be quietly fixed without this saying so.
    var pinned: (ours: String, real: String)? = nil
}
let cases: [Case] = [
    Case(name: "export-declarations", files: [
        "dep.mjs": """
            export const constant = 'const';
            export let mutable = 'let';
            export var older = 'var';
            export function plain() { return 'function'; }
            export async function waited() { return 'async function'; }
            export function* generated() { yield 'function*'; }
            export async function* streamed() { yield 'async function*'; }
            export class Named { get who() { return 'class'; } }
            """,
        "main.mjs": """
            import * as dep from './dep.mjs';
            console.log(dep.constant, dep.mutable, dep.older);
            console.log(dep.plain(), await dep.waited());
            console.log(dep.generated().next().value, (await dep.streamed().next()).value);
            console.log(new dep.Named().who);
            """]),
    Case(name: "export-default-forms", files: [
        "expr.mjs": "export default 40 + 2;\n",
        "fn.mjs": "export default function named() { return 'default function'; }\n",
        "anon.mjs": "export default function () { return 'default anonymous'; }\n",
        "gen.mjs": "export default function* counter() { yield 'default generator'; }\n",
        "cls.mjs": "export default class Thing { who() { return 'default class'; } }\n",
        "arrow.mjs": "export default () => 'default arrow';\n",
        "main.mjs": """
            import expr from './expr.mjs';
            import fn from './fn.mjs';
            import anon from './anon.mjs';
            import gen from './gen.mjs';
            import Cls from './cls.mjs';
            import arrow from './arrow.mjs';
            console.log(expr, fn(), anon());
            console.log(gen().next().value, new Cls().who(), arrow());
            """]),
    Case(name: "named-and-renamed", files: [
        "dep.mjs": """
            const one = 1, two = 2, three = 3;
            function fourth() { return 4; }
            export { one, two as second, three as default, fourth };
            """,
        "main.mjs": """
            import fallback, { one, second, fourth } from './dep.mjs';
            import * as everything from './dep.mjs';
            console.log(one, second, fourth(), fallback);
            console.log(Object.keys(everything).sort().join(','));
            """]),
    Case(name: "re-exports", files: [
        "leaf.mjs": "export const leaf = 'leaf'; export default 'leaf default';\n",
        "middle.mjs": """
            export * from './leaf.mjs';
            export { default as leafDefault } from './leaf.mjs';
            export * as bundled from './leaf.mjs';
            """,
        "main.mjs": """
            import { leaf, leafDefault, bundled } from './middle.mjs';
            console.log(leaf, leafDefault, bundled.leaf);
            """]),
    Case(name: "import-forms", files: [
        "dep.mjs": "export default 'the default'; export const named = 'the named';\n",
        "side.mjs": "globalThis.__sideEffect = 'ran';\n",
        "main.mjs": """
            import './side.mjs';
            import fallback from './dep.mjs';
            import fallback2, { named } from './dep.mjs';
            import fallback3, * as everything from './dep.mjs';
            import {
              named as renamed,
            } from './dep.mjs';
            console.log(globalThis.__sideEffect, fallback, fallback2, named, renamed);
            console.log(fallback3, everything.named, typeof everything.default);
            """]),
    Case(name: "hoisting-and-cycles", files: [
        "a.mjs": """
            import { fromB } from './b.mjs';
            export function fromA() { return 'A'; }
            export const usedB = typeof fromB;
            """,
        "b.mjs": """
            import { fromA } from './a.mjs';
            export function fromB() { return 'B'; }
            export const usedA = typeof fromA;
            """,
        "main.mjs": """
            import { fromA, usedB } from './a.mjs';
            import { fromB } from './b.mjs';
            console.log(fromA(), fromB(), usedB);
            """]),
    Case(name: "dynamic-and-meta", files: [
        "dep.mjs": "export const value = 'dynamic';\nexport default 'dynamic default';\n",
        "main.mjs": """
            const loaded = await import('./dep.mjs');
            console.log(loaded.value, loaded.default);
            console.log(typeof import.meta.url, import.meta.url.startsWith('file:///'));
            console.log(import.meta.url.endsWith('/main.mjs'));
            """]),
    Case(name: "json-and-top-level-await", files: [
        "data.json": #"{ "label": "json" }"#,
        "slow.mjs": "export const slow = await Promise.resolve('awaited');\n",
        "main.mjs": """
            import data from './data.json' with { type: 'json' };
            import { slow } from './slow.mjs';
            console.log(data.label, slow);
            """]),
    // A binding, not a copy: the importer must see a later mutation. Both sides are live now.
    // The exporting side always was — `ns.count` reads through a getter defined before the body.
    // The IMPORTING side was a snapshot for a long time, pinned here as an accepted divergence
    // on the grounds that fixing it needed a parser. It did not need a parser; it needed the
    // reference rewrite in `transpileESM`, which promotes a named import to a read through the
    // namespace wherever the module does not itself bind that name. What forced the issue was
    // svelte: its compiler does `export let locator;` and fills it in during init, so a snapshot
    // stayed undefined and every SSR render died calling it.
    Case(name: "live-bindings", files: [
        "counter.mjs": """
            export let count = 0;
            export function bump() { count += 1; }
            export const box = { hits: 0 };
            export function hit() { box.hits += 1; }
            """,
        "main.mjs": """
            import { count, bump, box, hit } from './counter.mjs';
            import * as ns from './counter.mjs';
            console.log('before', count, ns.count, box.hits);
            bump(); bump(); hit();
            console.log('after', count, ns.count, box.hits);
            """],
        ),
    Case(name: "string-names-and-tdz", files: [
        "dep.mjs": """
            const value = 'quoted name';
            export { value as "with space" };
            export const ready = 'ready';
            """,
        "main.mjs": """
            import * as dep from './dep.mjs';
            console.log(dep["with space"], dep.ready);
            console.log(Object.keys(dep).sort().join('|'));
            """]),
    Case(name: "default-through-a-cycle", files: [
        "a.mjs": """
            import b from './b.mjs';
            export default function a() { return 'a sees ' + typeof b; }
            """,
        "b.mjs": """
            import a from './a.mjs';
            export default function b() { return 'b sees ' + typeof a; }
            """,
        "main.mjs": """
            import a from './a.mjs';
            import b from './b.mjs';
            console.log(a(), b());
            """]),
    // `export const { … } = …` binds names a NAME-shaped pattern cannot see, and signal-exit
    // (under execa) writes exactly this, with the pattern spread over a dozen commented lines.
    Case(name: "destructured-exports", files: [
        "dep.mjs": """
            const source = { first: 1, second: 2, third: 3, nested: { deep: 4 } };
            export const {
              first,
              second: renamed,
              missing = 'defaulted',
              nested: { deep },
              ...rest
            } = source;
            export const [firstItem, , thirdItem = 'fallback'] = ['a', 'b'];
            """,
        "main.mjs": """
            import * as dep from './dep.mjs';
            console.log(dep.first, dep.renamed, dep.missing, dep.deep);
            console.log(JSON.stringify(dep.rest), dep.firstItem, dep.thirdItem);
            console.log(Object.keys(dep).sort().join('|'));
            """]),
    // A cycle where each module imports a FUNCTION from the other and calls it later. Real ESM
    // reads a binding where it is used, so this is legal; reading it at import time is not.
    Case(name: "cyclic-function-bindings", files: [
        "send.mjs": """
            import { wrap } from './strict.mjs';
            export const send = (text) => 'sent(' + wrap(text) + ')';
            """,
        "strict.mjs": """
            import { send } from './send.mjs';
            export const wrap = (text) => '[' + text + ']';
            export const resend = (text) => send(text) + '!';
            """,
        "main.mjs": """
            import { send } from './send.mjs';
            import { resend } from './strict.mjs';
            console.log(send('a'));
            console.log(resend('b'));
            """]),
    // Two ways the live-binding rewrite read the source wrong, both found in svelte's compiler
    // and both silent: the module kept working, it just saw the value the binding held at import
    // time. `dev` here is the real shape — `export let dev`, assigned per compile — and the URL
    // in the thrown message is the real reason it stopped being live: `svelte.dev` sat inside the
    // enclosing call's parentheses, so `dev` read as that call's parameter. The visitor table is
    // the other one: shorthand properties written one per line, where the comma and the name are
    // on different lines.
    Case(name: "live-through-prose-and-tables", files: [
        "state.mjs": """
            export let dev;
            export function set_dev(value) { dev = value; }
            """,
        "visitors.mjs": """
            export const AssignmentExpression = 'assign';
            export const AwaitExpression = 'await';
            """,
        "transform.mjs": """
            import { dev } from './state.mjs';
            import { AssignmentExpression, AwaitExpression } from './visitors.mjs';
            const b = {
              function(name, body) {
                if (name === null) {
                  throw new Error('no longer valid. See https://svelte.dev/docs/svelte/v5-migration-guide for more');
                }
                return name + body;
              },
            };
            export const visitors = {
              _: 'scope',
              AssignmentExpression,
              AwaitExpression
            };
            export function transform() {
              return [dev, b.function('n', 'b'), visitors.AssignmentExpression].join(',');
            }
            """,
        "main.mjs": """
            import { set_dev } from './state.mjs';
            import { transform } from './transform.mjs';
            console.log(transform());
            set_dev(true);
            console.log(transform());
            """]),
    Case(name: "code-in-strings", files: [
        "main.mjs": """
            const emitted = [
              'export default function Generated() {}',
              `export const inTemplate = 1;`,
              `${'nested'} import('./nothing.mjs')`,
              '// import.meta.hot',
            ].join('|');
            const regex = /export\\s+default\\s+["']/;
            console.log(emitted);
            console.log(regex.source, regex.test(`export default "x"`));
            """]),
]

func write(_ files: [String: String], into dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, text) in files {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

var failures = 0
for item in cases {
    let realDir = base.appendingPathComponent("real-" + item.name)
    let ourDir = base.appendingPathComponent("ours-" + item.name)
    write(item.files, into: realDir)
    write(item.files, into: ourDir)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: realNode)
    process.arguments = ["main.mjs"]
    process.currentDirectoryURL = realDir
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try? process.run()
    let realText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let realProblems = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    let engine = NodeEngine(root: ourDir, env: ["PATH": "/"])
    let ours = await engine.run(source: item.files["main.mjs"]!, path: "/main.mjs",
                                argv: ["node", "/main.mjs"], cwd: "/", stdin: "")
    // import.meta.url carries the directory, which differs by construction.
    func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: realDir.path, with: "DIR").replacingOccurrences(of: ourDir.path, with: "DIR")
    }
    if let pinned = item.pinned {
        if normalise(ours.out) == pinned.ours, normalise(realText) == pinned.real {
            print("pinned divergence: \(item.name) — behaves as recorded, and node still differs")
        } else {
            failures += 1
            print("PIN BROKEN: \(item.name) — the recorded divergence is no longer what happens")
            print("  ---- ours ----\n\(normalise(ours.out))  ---- real ----\n\(normalise(realText))  ----")
        }
    } else if normalise(ours.out) == normalise(realText), process.terminationStatus == 0, ours.status == 0 {
        print("ok: \(item.name)")
    } else {
        failures += 1
        print("MISMATCH: \(item.name) (status ours=\(ours.status) real=\(process.terminationStatus))")
        print("  ---- ours ----\n\(normalise(ours.out))\(ours.err.prefix(700))  ---- real ----\n\(normalise(realText))\(realProblems.prefix(400))  ----")
    }
}

if failures == 0 {
    let pinnedCount = cases.filter { $0.pinned != nil }.count
    print("ESM GRAMMAR MATCH — \(cases.count - pinnedCount) module shapes behave as real node's, "
          + "\(pinnedCount) pinned divergences")
} else {
    print("FAIL: \(failures) of \(cases.count) module shapes differ")
    exit(1)
}
try? FileManager.default.removeItem(at: base)
