import Foundation

// Phase F verification per AGENTS.md:
// 1. Semver range assertions against spec truths.
// 2. resolveTree vs real `pnpm install --lockfile-only` (same registry, same rule).
// 3. install() of a real tree, then real `node` requires from it — layout proof.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("FAIL: \(label)") }
}

// -- 1. semver ---------------------------------------------------------------
func satisfies(_ version: String, _ range: String) -> Bool {
    guard let v = PackageManager.Semver(version), let r = PackageManager.SemverRange(range) else { return false }
    return r.satisfied(by: v)
}

check(satisfies("2.1.2", ">= 2.1.2 < 3.0.0"), "space-after-operator range (safer-buffer)")
check(satisfies("2.9.9", ">= 2.1.2 < 3.0.0"), "space range upper interior")
check(!satisfies("3.0.0", ">= 2.1.2 < 3.0.0"), "space range upper bound")
check(!satisfies("2.1.1", ">= 2.1.2 < 3.0.0"), "space range lower bound")
check(satisfies("1.2.3", "^1.2.3"), "^ basic")
check(satisfies("1.9.9", "^1.2.3"), "^ minor drift")
check(!satisfies("2.0.0", "^1.2.3"), "^ major bound")
check(satisfies("0.2.5", "^0.2.3"), "^0.x patch drift")
check(!satisfies("0.3.0", "^0.2.3"), "^0.x minor bound")
check(!satisfies("0.0.4", "^0.0.3"), "^0.0.x exact")
check(satisfies("1.2.9", "~1.2.3"), "~ patch drift")
check(!satisfies("1.3.0", "~1.2.3"), "~ minor bound")
check(satisfies("1.9.0", "~1"), "~ major-only")
check(satisfies("1.2.3", ">=1.0.0 <2.0.0"), "and-set")
check(satisfies("3.1.0", "^1.0.0 || ^3.0.0"), "or-set")
check(!satisfies("2.5.0", "^1.0.0 || ^3.0.0"), "or-set gap")
check(satisfies("1.5.0", "1.x"), "x-range")
check(!satisfies("2.0.0", "1.x"), "x-range bound")
check(satisfies("1.2.0", "1.2"), "partial as x-range")
check(satisfies("5.0.0", "*"), "star")
check(satisfies("1.2.3", "1.2.3"), "exact")
check(!satisfies("1.2.4", "1.2.3"), "exact miss")
check(satisfies("1.5.0", "1.2.3 - 2.0.0"), "hyphen")
check(!satisfies("2.0.1", "1.2.3 - 2.0.0"), "hyphen upper")
check(satisfies("2.0.0", ">=2.0.0-0"), "prerelease anchor allows release")
check(!satisfies("2.0.0-beta.1", "^1.0.0"), "prerelease hidden from plain range")
check(satisfies("2.0.0-beta.2", ">=2.0.0-beta.1"), "prerelease with anchor")
check(satisfies("1.2.3", ">1.2.2"), "gt")
check(satisfies("1.3.0", ">1.2"), "gt partial bumps")
check(!satisfies("1.2.9", ">1.2"), "gt partial excludes the partial itself")

if PackageManager.Semver("1.2.3-alpha")! < PackageManager.Semver("1.2.3")! {} else { failures += 1; print("FAIL: prerelease < release") }
check(PackageManager.Semver("1.2.3-alpha.2")! < PackageManager.Semver("1.2.3-alpha.10")!, "numeric prerelease compare")

print(failures == 0 ? "semver: all pass" : "semver: \(failures) failures")

// -- 2. resolution vs pnpm ---------------------------------------------------
let cases: [(name: String, requirement: String)] = [
    ("left-pad", "^1.3.0"),
    ("mkdirp", "^1.0.0"),
    ("debug", "^4.0.0"),
    ("chalk", "4.1.2"),
    ("glob", "^7.2.0"),
]

func pnpmResolve(_ name: String, _ requirement: String, scratch: URL) -> Set<String> {
    let dir = scratch.appendingPathComponent("pnpm-\(name.replacingOccurrences(of: "/", with: "_"))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pkg = ["name": "probe", "version": "1.0.0", "dependencies": [name: requirement]] as [String: Any]
    let data = try! JSONSerialization.data(withJSONObject: pkg)
    try! data.write(to: dir.appendingPathComponent("package.json"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/pnpm")
    // pnpm 11's default minimumReleaseAge (supply-chain gate) skips versions published
    // <24h ago; our resolver does pure semver. Disable it so the comparison tests
    // RESOLUTION, not release-age policy (which lost us a publish race mid-session).
    process.arguments = ["install", "--lockfile-only", "--ignore-scripts",
                         "--config.minimum-release-age=0"]
    process.currentDirectoryURL = dir
    // Fresh metadata cache per run: a stale pnpm cache loses publish races against our
    // live-registry resolver (brace-expansion@1.1.17 landed mid-session and pnpm kept
    // answering 1.1.16 from cache). XDG dirs point pnpm's cache into the scratch area.
    var environment = ProcessInfo.processInfo.environment
    environment["XDG_CACHE_HOME"] = dir.appendingPathComponent("xdg-cache").path
    environment["XDG_DATA_HOME"] = dir.appendingPathComponent("xdg-data").path
    environment["XDG_STATE_HOME"] = dir.appendingPathComponent("xdg-state").path
    process.environment = environment
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    guard let lock = try? String(contentsOf: dir.appendingPathComponent("pnpm-lock.yaml"), encoding: .utf8) else { return [] }
    var results = Set<String>()
    var inPackages = false
    for line in lock.split(separator: "\n", omittingEmptySubsequences: false) {
        if line == "packages:" { inPackages = true; continue }
        if inPackages {
            if !line.hasPrefix(" ") && !line.isEmpty { inPackages = false; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":"), trimmed.contains("@"), !trimmed.hasPrefix("resolution") {
                results.insert(String(trimmed.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")))
            }
        }
    }
    return results
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pkg-verify-\(getpid())")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

for testCase in cases {
    let session = PackageManager.Session()
    do {
        let placements = try await PackageManager.resolveTree(
            requirements: [testCase.name: testCase.requirement], session: session)
        let ours = Set(placements.map { "\($0.package.name)@\($0.package.version)" })
        let theirs = pnpmResolve(testCase.name, testCase.requirement, scratch: scratch)
        if ours != theirs {
            failures += 1
            print("FAIL: resolution \(testCase.name): ours=\(ours.sorted()) pnpm=\(theirs.sorted())")
        } else {
            print("resolution \(testCase.name): \(ours.count) packages match pnpm")
        }
    } catch {
        failures += 1
        print("FAIL: resolution \(testCase.name): \(error.localizedDescription)")
    }
}

// -- 3. real install, proven by real node ------------------------------------
let installRoot = scratch.appendingPathComponent("install-chalk")
try? FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
do {
    let report = try await PackageManager.install(requirements: ["chalk": "4.1.2"], into: installRoot)
    check(report.placements.contains { $0.package.name == "chalk" && $0.package.version == "4.1.2" }, "chalk placed")
    for placement in report.placements {
        let pkgJSON = installRoot.appendingPathComponent(placement.path).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            failures += 1; print("FAIL: missing package.json at \(placement.path)"); continue
        }
        check(json["version"] as? String == placement.package.version, "version on disk \(placement.path)")
    }

    let node = Process()
    node.executableURL = URL(fileURLWithPath: "/Users/thyfriendlyfox/.local/bin/node")
    node.arguments = ["-e", "const c = require('chalk'); if (typeof c.red !== 'function') process.exit(1); console.log(c.level >= 0 ? 'chalk-loads' : 'x')"]
    node.currentDirectoryURL = installRoot
    let out = Pipe()
    node.standardOutput = out
    node.standardError = Pipe()
    try node.run()
    node.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    check(node.terminationStatus == 0 && text.contains("chalk-loads"), "real node requires chalk from our tree")

    let manifest = PackageManager.readManifest(root: installRoot)
    check(manifest != nil && manifest!.packages.count == report.placements.count, "manifest records placements")
} catch {
    failures += 1
    print("FAIL: install: \(error.localizedDescription)")
}

// glob@7: a deeper tree; real node must resolve it from our layout.
let globRoot = scratch.appendingPathComponent("install-glob")
try? FileManager.default.createDirectory(at: globRoot, withIntermediateDirectories: true)
do {
    _ = try await PackageManager.install(requirements: ["glob": "^7.2.0"], into: globRoot)
    let node = Process()
    node.executableURL = URL(fileURLWithPath: "/Users/thyfriendlyfox/.local/bin/node")
    node.arguments = ["-e", "const g = require('glob'); if (typeof g.sync !== 'function') process.exit(1); console.log('glob-loads')"]
    node.currentDirectoryURL = globRoot
    let out = Pipe()
    node.standardOutput = out
    node.standardError = Pipe()
    try node.run()
    node.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    check(node.terminationStatus == 0 && text.contains("glob-loads"), "real node requires glob from our tree")
} catch {
    failures += 1
    print("FAIL: glob install: \(error.localizedDescription)")
}

// mkdirp has a bin — verify bin capture end to end.
let binRoot = scratch.appendingPathComponent("install-mkdirp")
try? FileManager.default.createDirectory(at: binRoot, withIntermediateDirectories: true)
do {
    let report = try await PackageManager.install(requirements: ["mkdirp": "^1.0.0"], into: binRoot)
    check(report.bins["mkdirp"] != nil, "mkdirp bin recorded")
    if let bin = report.bins["mkdirp"] {
        check(FileManager.default.fileExists(atPath: binRoot.appendingPathComponent(bin).path), "bin file exists")
    }
} catch {
    failures += 1
    print("FAIL: mkdirp install: \(error.localizedDescription)")
}

try? FileManager.default.removeItem(at: scratch)
print(failures == 0 ? "PHASE F: ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
