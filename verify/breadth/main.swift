import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// A DIAGNOSTIC, not an assertion: install a spread of the packages an iOS IDE's user would
// actually reach for, load each one the way its README says to, and report what happens. The
// point is to choose the next boundary from data rather than from intuition — every gap this
// finds is a real user's first five minutes.

let base = FileManager.default.temporaryDirectory.appendingPathComponent("breadth-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

struct Probe { let name: String; let spec: String; let source: String }
let probes: [Probe] = [
    Probe(name: "undici", spec: "^6.19.0",
          source: "const { request, Agent } = require('undici'); console.log(typeof request, typeof Agent);"),
    Probe(name: "hono", spec: "^4.6.0",
          source: "import { Hono } from 'hono'; const app = new Hono(); app.get('/', (c) => c.text('hi')); console.log('routes', typeof app.fetch);"),
    Probe(name: "fastify", spec: "^4.28.0",
          source: "const fastify = require('fastify')(); fastify.get('/', async () => ({ ok: 1 })); console.log('fastify', typeof fastify.listen);"),
    Probe(name: "postcss", spec: "^8.4.0",
          source: "const postcss = require('postcss'); postcss([]).process('a{color:red}', { from: undefined }).then(r => console.log(r.css));"),
    Probe(name: "sass", spec: "^1.79.0",
          source: "const sass = require('sass'); console.log(sass.compileString('a { b { color: red; } }').css.replace(/\\n/g, ' '));"),
    Probe(name: "dayjs", spec: "^1.11.0",
          source: "const dayjs = require('dayjs'); console.log(dayjs('2026-07-31').format('YYYY-MM-DD'));"),
    Probe(name: "markdown-it", spec: "^14.1.0",
          source: "const md = require('markdown-it')(); console.log(md.render('# hi').trim());"),
    Probe(name: "pino", spec: "^9.4.0",
          source: "const pino = require('pino'); const log = pino({ level: 'info' }); log.info('hello'); console.log('pino ok');"),
    Probe(name: "svelte", spec: "^4.2.0",
          source: "const { compile } = require('svelte/compiler'); const out = compile('<h1>{name}</h1>'); console.log('svelte', out.js.code.length > 0);"),
    Probe(name: "graphql", spec: "^16.9.0",
          source: "const { graphql, buildSchema } = require('graphql'); buildSchema('type Query { hi: String }'); console.log('graphql ok');"),
    Probe(name: "tsx-esbuild-kit", spec: "^4.19.0", // tsx: a TS runner built on esbuild
          source: "const tsx = require('tsx'); console.log('tsx', typeof tsx);"),
    Probe(name: "vitest", spec: "^2.1.0",
          source: "const { startVitest } = require('vitest/node'); console.log('vitest', typeof startVitest);"),
    Probe(name: "drizzle-orm", spec: "^0.33.0",
          source: "const { sql } = require('drizzle-orm'); console.log('drizzle', typeof sql);"),
    Probe(name: "socket.io", spec: "^4.8.0",
          source: "const { Server } = require('socket.io'); console.log('socket.io', typeof Server);"),
    Probe(name: "nodemon", spec: "^3.1.0",
          source: "const nodemon = require('nodemon'); console.log('nodemon', typeof nodemon);"),
    Probe(name: "execa", spec: "^9.4.0",
          source: "import { execa } from 'execa'; console.log('execa', typeof execa);"),
    Probe(name: "zx", spec: "^8.1.0",
          source: "const { $ } = require('zx'); console.log('zx', typeof $);"),
    Probe(name: "terser", spec: "^5.34.0",
          source: "const { minify } = require('terser'); minify('const a = 1 + 1;').then(r => console.log(r.code));"),
    Probe(name: "@babel/core", spec: "^7.25.0",
          source: "const babel = require('@babel/core'); console.log(babel.transformSync('const a = () => 1;').code);"),
    Probe(name: "ts-morph", spec: "^23.0.0",
          source: "const { Project } = require('ts-morph'); const p = new Project({ useInMemoryFileSystem: true }); p.createSourceFile('a.ts', 'const x: number = 1;'); console.log('ts-morph', p.getSourceFiles().length);"),
    Probe(name: "listr2", spec: "^8.2.0",
          source: "const { Listr } = require('listr2'); console.log('listr2', typeof new Listr([]).run);"),
    Probe(name: "nanoid", spec: "^5.0.0",
          source: "import { nanoid } from 'nanoid'; console.log('nanoid', nanoid().length);"),
    Probe(name: "cheerio", spec: "^1.0.0",
          source: "const { load } = require('cheerio'); console.log('cheerio', load('<p>hi</p>')('p').text());"),
    Probe(name: "jsdom", spec: "^25.0.0",
          source: "const { JSDOM } = require('jsdom'); console.log('jsdom', new JSDOM('<p>hi</p>').window.document.querySelector('p').textContent);"),
    Probe(name: "sharp", spec: "^0.33.0",   // native: must refuse with a reason, not pretend
          source: "const sharp = require('sharp'); console.log('sharp', typeof sharp);"),
    Probe(name: "better-sqlite3", spec: "^11.3.0",   // native, same
          source: "const db = require('better-sqlite3'); console.log('sqlite', typeof db);"),
    Probe(name: "pg", spec: "^8.13.0",
          source: "const { Client } = require('pg'); console.log('pg', typeof new Client({}).connect);"),
    Probe(name: "mongoose", spec: "^8.7.0",
          source: "const mongoose = require('mongoose'); console.log('mongoose', typeof mongoose.connect);"),
    Probe(name: "@trpc/server", spec: "^10.45.0",
          source: "const { initTRPC } = require('@trpc/server'); console.log('trpc', typeof initTRPC.create);"),
]

var loaded = 0
for probe in probes {
    let dir = base.appendingPathComponent(probe.name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let install = probe.name == "tsx-esbuild-kit" ? "tsx" : probe.name
    do {
        _ = try await PackageManager.install(requirements: [install: probe.spec], into: dir)
    } catch {
        print("\(probe.name): INSTALL FAILED — \(error)")
        continue
    }
    let entry = probe.source.contains("import ") ? "probe.mjs" : "probe.cjs"
    try? probe.source.write(to: dir.appendingPathComponent(entry), atomically: true, encoding: .utf8)
    let engine = NodeEngine(root: dir, env: ["PATH": "/", "HOME": "/"])
    let result = await engine.run(source: probe.source, path: "/" + entry,
                                  argv: ["node", "/" + entry], cwd: "/", stdin: "")
    let out = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.status == 0, !out.isEmpty, result.err.isEmpty {
        loaded += 1
        print("\(probe.name): ok — \(out.prefix(80))")
    } else {
        let firstLine = result.err.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? "no output"
        print("\(probe.name): FAILED — \(firstLine.prefix(160))")
    }
}
print("breadth: \(loaded) of \(probes.count) loaded")
try? FileManager.default.removeItem(at: base)
