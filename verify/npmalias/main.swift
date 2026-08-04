import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// An npm ALIAS — `"local-name": "npm:real-name@range"` — installs one published package under a
// different directory name. It is how a tree depends on two major versions of the same package
// at once, and it is not exotic: n8n's tree uses one, and `npx n8n` failed on this engine with
// "package not found: zod-from-json-schema-v3", a name nobody ever published, because the alias
// was carried to the registry as if it were the package.
let base = FileManager.default.temporaryDirectory.appendingPathComponent("alias-\(getpid())")
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }

var problems: [String] = []
let report = try await PackageManager.install(
    requirements: ["string-width-cjs": "npm:string-width@^4.2.3",
                   "string-width": "^5.1.2"],
    into: base)

// Placed under the ALIAS name…
let aliasDir = base.appendingPathComponent("node_modules/string-width-cjs/package.json")
guard let aliasData = try? Data(contentsOf: aliasDir),
      let alias = try? JSONSerialization.jsonObject(with: aliasData) as? [String: Any] else {
    print("no node_modules/string-width-cjs/package.json — the alias never installed")
    print("NPM ALIAS MISMATCH"); exit(1)
}
// …carrying the REAL package's identity inside.
let realName = alias["name"] as? String ?? "?"
let aliasVersion = alias["version"] as? String ?? "?"
if realName != "string-width" { problems.append("alias holds '\(realName)', expected string-width") }
if !aliasVersion.hasPrefix("4.") { problems.append("alias resolved \(aliasVersion), expected 4.x") }

// And the un-aliased dependency on the same package is a SEPARATE install at its own version:
// resolving the alias to the same slot would silently give one of them the wrong major.
let plainPath = base.appendingPathComponent("node_modules/string-width/package.json")
let plainVersion = (try? Data(contentsOf: plainPath))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    .flatMap { $0["version"] as? String } ?? "missing"
if !plainVersion.hasPrefix("5.") { problems.append("string-width is \(plainVersion), expected 5.x") }

// The install report should say what it did rather than pretend the alias was its own package.
let aliased = report.placements.filter { $0.installedAs != nil }
if !aliased.contains(where: { $0.installedAs == "string-width-cjs" && $0.package.name == "string-width" }) {
    problems.append("the report does not record string-width-cjs as an alias of string-width")
}

if problems.isEmpty {
    print("NPM ALIAS MATCH — `npm:` aliases resolve to the published package and install under "
          + "the requested name: string-width-cjs holds string-width@\(aliasVersion) while the "
          + "direct dependency keeps \(plainVersion), side by side")
} else {
    for problem in problems { print("  \(problem)") }
    print("NPM ALIAS MISMATCH")
    exit(1)
}
