import Compression
import CryptoKit
import Foundation

/// The package manager (system.md phase F): resolve npm packages from the registry, verify
/// and unpack their tarballs (native `TarGz`), lay out a Node-compatible `node_modules`
/// tree, and record executables. `npm`/`pnpm`/`npx` in the terminal drive this engine.
///
/// Foundation-only by design: resolution verifies headlessly against a real `pnpm
/// install --lockfile-only`, and the installed tree against real `node` resolving it
/// (per AGENTS.md). Running the installed JavaScript is phase G's job — this phase makes
/// `node_modules` and `$PATH` truthful.
enum PackageManager {

    struct PackageError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - Semver

    struct Semver: Comparable, CustomStringConvertible {
        var major: Int
        var minor: Int
        var patch: Int
        /// Dot-separated prerelease identifiers; empty means a release version.
        var prerelease: [String]

        var description: String {
            "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
        }

        init?(_ text: String) {
            var text = text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("v") { text.removeFirst() }
            // Build metadata (+…) never affects precedence.
            if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
            var pre: [String] = []
            if let dash = text.firstIndex(of: "-") {
                pre = text[text.index(after: dash)...].split(separator: ".").map(String.init)
                text = String(text[..<dash])
            }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
            self.major = major
            self.minor = minor
            self.patch = patch
            self.prerelease = pre
        }

        init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
            self.major = major
            self.minor = minor
            self.patch = patch
            self.prerelease = prerelease
        }

        static func < (lhs: Semver, rhs: Semver) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            // A release outranks any of its prereleases.
            if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
            for (l, r) in zip(lhs.prerelease, rhs.prerelease) where l != r {
                switch (Int(l), Int(r)) {
                case (let li?, let ri?): return li < ri
                case (.some, .none): return true     // numeric < alphanumeric
                case (.none, .some): return false
                default: return l < r
                }
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }

        static func == (lhs: Semver, rhs: Semver) -> Bool {
            lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
                && lhs.prerelease == rhs.prerelease
        }
    }

    /// One comparator: an operator against a version.
    private struct Comparator {
        enum Op { case lt, le, gt, ge, eq }
        var op: Op
        var version: Semver

        func satisfied(by candidate: Semver) -> Bool {
            switch op {
            case .lt: return candidate < version
            case .le: return candidate <= version
            case .gt: return candidate > version
            case .ge: return candidate >= version
            case .eq: return candidate == version
            }
        }
    }

    /// A range: OR of comparator sets (`^1.2 || >=3.0.0 <4`). Each set ANDs its comparators.
    struct SemverRange {
        private var sets: [[Comparator]]
        /// Triples that appeared with a prerelease in the source range — the only versions
        /// whose prereleases the range may match (the semver prerelease rule).
        private var prereleaseAnchors: [[Int]]

        init?(_ text: String) {
            var sets: [[Comparator]] = []
            var anchors: [[Int]] = []
            for alternative in text.components(separatedBy: "||") {
                guard let set = Self.parseSet(alternative, anchors: &anchors) else { return nil }
                sets.append(set)
            }
            guard !sets.isEmpty else { return nil }
            self.sets = sets
            self.prereleaseAnchors = anchors
        }

        func satisfied(by candidate: Semver) -> Bool {
            if !candidate.prerelease.isEmpty {
                let triple = [candidate.major, candidate.minor, candidate.patch]
                guard prereleaseAnchors.contains(triple) else { return false }
            }
            return sets.contains { $0.allSatisfy { $0.satisfied(by: candidate) } }
        }

        private static func parseSet(_ text: String, anchors: inout [[Int]]) -> [Comparator]? {
            var comparators: [Comparator] = []
            // Hyphen ranges: "1.2.3 - 2.0.0" (the spaces are the syntax).
            let text = text.trimmingCharacters(in: .whitespaces)
            if let range = text.range(of: " - ") {
                let low = String(text[..<range.lowerBound])
                let high = String(text[range.upperBound...])
                guard let lower = fill(low, low: true) else { return nil }
                comparators.append(Comparator(op: .ge, version: lower))
                if let exact = Semver(high), countParts(high) == 3 {
                    comparators.append(Comparator(op: .le, version: exact))
                } else if let upper = fill(high, low: true) {
                    comparators.append(Comparator(op: .lt, version: bumpPartial(high, upper)))
                }
                return comparators
            }
            var tokens = text.split(separator: " ").map(String.init)
            // The spec allows whitespace between an operator and its version (">= 2.1.2
            // < 3.0.0", safer-buffer's published range): rejoin bare-operator tokens with
            // the version that follows.
            var joined: [String] = []
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                if ["<", "<=", ">", ">=", "=", "~", "^"].contains(token), index + 1 < tokens.count {
                    joined.append(token + tokens[index + 1])
                    index += 2
                } else {
                    joined.append(token)
                    index += 1
                }
            }
            tokens = joined
            if tokens.isEmpty { return [Comparator(op: .ge, version: Semver(major: 0, minor: 0, patch: 0))] }
            for token in tokens {
                guard let parsed = parseComparator(token, anchors: &anchors) else { return nil }
                comparators.append(contentsOf: parsed)
            }
            return comparators
        }

        private static func countParts(_ text: String) -> Int {
            var text = text
            if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
            return text.split(separator: ".").count
        }

        /// "1.2" → 1.2.0 (missing parts become 0; `x`/`*` too).
        private static func fill(_ text: String, low: Bool) -> Semver? {
            var text = text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("v") { text.removeFirst() }
            var pre: [String] = []
            if let dash = text.firstIndex(of: "-") {
                pre = text[text.index(after: dash)...].split(separator: ".").map(String.init)
                text = String(text[..<dash])
            }
            let raw = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            var parts: [Int] = []
            for piece in raw {
                if piece == "x" || piece == "X" || piece == "*" || piece.isEmpty { break }
                guard let value = Int(piece) else { return nil }
                parts.append(value)
            }
            while parts.count < 3 { parts.append(0) }
            return Semver(major: parts[0], minor: parts[1], patch: parts[2], prerelease: pre)
        }

        /// The exclusive upper bound implied by a partial: "1.2" → 1.3.0, "1" → 2.0.0.
        private static func bumpPartial(_ text: String, _ filled: Semver) -> Semver {
            switch countExplicit(text) {
            case 0: return Semver(major: Int.max, minor: 0, patch: 0)
            case 1: return Semver(major: filled.major + 1, minor: 0, patch: 0)
            case 2: return Semver(major: filled.major, minor: filled.minor + 1, patch: 0)
            default: return Semver(major: filled.major, minor: filled.minor, patch: filled.patch + 1)
            }
        }

        private static func countExplicit(_ text: String) -> Int {
            var text = text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("v") { text.removeFirst() }
            if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
            var count = 0
            for piece in text.split(separator: ".", omittingEmptySubsequences: false) {
                if piece == "x" || piece == "X" || piece == "*" || piece.isEmpty { break }
                guard Int(piece) != nil else { break }
                count += 1
            }
            return count
        }

        private static func parseComparator(_ token: String, anchors: inout [[Int]]) -> [Comparator]? {
            func anchor(_ version: Semver) {
                if !version.prerelease.isEmpty { anchors.append([version.major, version.minor, version.patch]) }
            }
            if token == "*" || token == "x" || token == "X" || token == "latest" {
                return [Comparator(op: .ge, version: Semver(major: 0, minor: 0, patch: 0))]
            }
            if token.hasPrefix("^") {
                let body = String(token.dropFirst())
                guard let version = fill(body, low: true) else { return nil }
                anchor(version)
                let upper: Semver
                let explicit = countExplicit(body)
                if version.major > 0 || explicit <= 1 {
                    upper = Semver(major: version.major + 1, minor: 0, patch: 0)
                } else if version.minor > 0 || explicit == 2 {
                    upper = Semver(major: 0, minor: version.minor + 1, patch: 0)
                } else {
                    upper = Semver(major: 0, minor: version.minor, patch: version.patch + 1)
                }
                return [Comparator(op: .ge, version: version), Comparator(op: .lt, version: upper)]
            }
            if token.hasPrefix("~") {
                let body = String(token.dropFirst())
                guard let version = fill(body, low: true) else { return nil }
                anchor(version)
                let upper = countExplicit(body) <= 1
                    ? Semver(major: version.major + 1, minor: 0, patch: 0)
                    : Semver(major: version.major, minor: version.minor + 1, patch: 0)
                return [Comparator(op: .ge, version: version), Comparator(op: .lt, version: upper)]
            }
            for (prefix, op) in [(">=", Comparator.Op.ge), ("<=", .le), (">", .gt), ("<", .lt), ("=", .eq)] {
                if token.hasPrefix(prefix) {
                    let body = String(token.dropFirst(prefix.count))
                    guard let version = fill(body, low: true) else { return nil }
                    anchor(version)
                    // ">1.2" on a partial means ">=1.3.0"; "<1.2" means "<1.2.0" (the fill).
                    if op == .gt, countExplicit(body) < 3 {
                        return [Comparator(op: .ge, version: bumpPartial(body, version))]
                    }
                    if op == .eq, countExplicit(body) < 3 {
                        return [Comparator(op: .ge, version: version),
                                Comparator(op: .lt, version: bumpPartial(body, version))]
                    }
                    return [Comparator(op: op, version: version)]
                }
            }
            // Bare version: exact when full, an x-range when partial ("1.2" == ">=1.2.0 <1.3.0").
            if countExplicit(token) == 3, let version = Semver(token) {
                anchor(version)
                return [Comparator(op: .eq, version: version)]
            }
            guard let version = fill(token, low: true) else { return nil }
            return [Comparator(op: .ge, version: version),
                    Comparator(op: .lt, version: bumpPartial(token, version))]
        }
    }

    // MARK: - Registry

    struct ResolvedPackage {
        let name: String
        let version: String
        let tarball: String
        let integrity: String?
        let shasum: String?
        let dependencies: [String: String]
        /// The per-platform binaries a package publishes. All of them are skipped except one:
        /// see `wasiBinding`.
        let optionalDependencies: [String: String]
        let bin: [String: String]
    }

    /// One resolution session: packument cache + the chosen set.
    final class Session {
        let registry: String
        var packuments: [String: [String: Any]] = [:]

        init(registry: String = "https://registry.npmjs.org") {
            self.registry = registry
        }

        func packument(for name: String) async throws -> [String: Any] {
            if let cached = packuments[name] { return cached }
            let encoded = name.replacingOccurrences(of: "/", with: "%2F")
            guard let url = URL(string: "\(registry)/\(encoded)") else {
                throw PackageError("bad package name: \(name)")
            }
            var request = URLRequest(url: url)
            // The abbreviated document: versions, deps, dist — an order of magnitude smaller.
            request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw PackageError(code == 404 ? "package not found: \(name)" : "registry returned \(code) for \(name)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PackageError("bad registry response for \(name)")
            }
            packuments[name] = json
            return json
        }

        /// Highest version satisfying the range (the npm rule). "latest"-style dist-tags
        /// resolve through `dist-tags` first.
        func resolve(name: String, requirement: String) async throws -> ResolvedPackage {
            // An ALIAS: `"local-name": "npm:real-name@range"` installs one package under a
            // different directory name, and a tree may depend on two versions of the same
            // package that way. Taking the alias to the registry asks for a package nobody
            // published — n8n's tree does exactly this, and the 404 failed the whole install.
            var name = name
            var requirement = requirement.trimmingCharacters(in: .whitespaces)
            if requirement.hasPrefix("npm:") {
                let spec = String(requirement.dropFirst(4))
                // The version separator is the LAST '@' that is not the scope's leading one,
                // so `npm:@scope/pkg@^1` splits after the package name, not inside the scope.
                let searchStart = spec.hasPrefix("@") ? spec.index(after: spec.startIndex) : spec.startIndex
                if let at = spec[searchStart...].lastIndex(of: "@") {
                    name = String(spec[spec.startIndex..<at])
                    requirement = String(spec[spec.index(after: at)...])
                } else {
                    name = spec
                    requirement = "*"
                }
                if requirement.isEmpty { requirement = "*" }
            }
            let packument = try await packument(for: name)
            let versions = packument["versions"] as? [String: Any] ?? [:]
            if requirement.isEmpty { requirement = "*" }
            if let tags = packument["dist-tags"] as? [String: String], let tagged = tags[requirement] {
                requirement = tagged
            }
            guard let range = SemverRange(requirement) else {
                throw PackageError("\(name): unsupported version range '\(requirement)'")
            }
            var best: (Semver, String)? = nil
            for versionText in versions.keys {
                guard let version = Semver(versionText), range.satisfied(by: version) else { continue }
                if best == nil || version > best!.0 { best = (version, versionText) }
            }
            guard let (_, chosen) = best, let meta = versions[chosen] as? [String: Any] else {
                throw PackageError("\(name): no version satisfies '\(requirement)'")
            }
            return Self.package(name: name, version: chosen, meta: meta)
        }

        private static func package(name: String, version: String, meta: [String: Any]) -> ResolvedPackage {
            let dist = meta["dist"] as? [String: Any] ?? [:]
            var bins: [String: String] = [:]
            if let bin = meta["bin"] as? String {
                // A lone string names the package itself.
                let short = name.split(separator: "/").last.map(String.init) ?? name
                bins[short] = bin
            } else if let bin = meta["bin"] as? [String: String] {
                bins = bin
            }
            return ResolvedPackage(
                name: name,
                version: version,
                tarball: dist["tarball"] as? String ?? "",
                integrity: dist["integrity"] as? String,
                shasum: dist["shasum"] as? String,
                dependencies: meta["dependencies"] as? [String: String] ?? [:],
                optionalDependencies: meta["optionalDependencies"] as? [String: String] ?? [:],
                bin: bins
            )
        }
    }

    // MARK: - Resolution (the whole tree)

    /// Breadth-first resolution with classic npm hoisting: first requirement of a name lands
    /// at the root; a conflicting version nests under its dependent. Returns every placement.
    struct Placement {
        let package: ResolvedPackage
        /// Directory relative to the project root, e.g. "node_modules/chalk" or
        /// "node_modules/chalk/node_modules/supports-color".
        let path: String
        /// The name this package was REQUESTED as, when it stands in for one — `rollup` for
        /// `@rollup/wasm-node`. nil when the package is itself.
        var installedAs: String? = nil
        /// Whether this placement sits at the root of node_modules (its bins join .bin).
        ///
        /// The test is "no FURTHER node_modules", not "no slash". A scoped package lives at
        /// `node_modules/@scope/name`, so the slash test called every one of them nested and
        /// dropped its bins — `npm i -g @anthropic-ai/claude-code` reported "added 1 packages"
        /// and left no `claude` command behind, and the same was true of every scoped CLI.
        var atRoot: Bool { !path.dropFirst("node_modules/".count).contains("node_modules/") }
    }

    /// Packages whose npm release is a per-platform NATIVE binary, mapped to the WebAssembly
    /// build their own authors publish for platforms they ship no binary for. iOS is such a
    /// platform and always will be: it can neither dlopen a `.node` addon nor exec a downloaded
    /// executable. The substitute is installed under the ORIGINAL name, so the package that
    /// depends on it is unmodified and never learns the difference — which is what makes vite
    /// build here at all, since it reaches for both of these.
    static let wasmSubstitutes: [String: String] = [
        "rollup": "@rollup/wasm-node",
        "esbuild": "esbuild-wasm",
        // lightningcss loads `lightningcss-<platform>-<arch>` or a sibling `.node` and has no
        // wasi branch to fall back to, so on a phone it is simply a missing module — and it is
        // not optional: vite reaches for it as a CSS transformer, and tailwind 4 pulls it in
        // through `@tailwindcss/node`. Its authors publish `lightningcss-wasm` at the SAME
        // version, and that package's `node` export condition is a synchronous build: it reads
        // its own wasm with `fs.readFileSync`, instantiates it at module scope, and exports the
        // same transform/bundle/Features/composeVisitors surface the native one does. No
        // `await init()` for the caller, which is what makes it substitutable at all — the
        // package that depends on it calls a sync function and gets one.
        "lightningcss": "lightningcss-wasm",
    ]

    /// The same idea as `wasmSubstitutes`, but for the shape napi-rs uses: a package lists its
    /// platform binaries in `optionalDependencies` and its loader tries them in turn, with
    /// `…-wasm32-wasi` — the author's own portable build — as the last resort. Every native one
    /// is skipped here (none can load on iOS) and the wasi one is installed, so the loader's
    /// last resort is the one that is present.
    ///
    /// Two shapes, because the ecosystem moved. Originally the wasi build sat IN
    /// `optionalDependencies` and this function just found it. rolldown 1.x STOPPED listing it
    /// — the natives are all that remain — which on a phone turned `npm run dev` of a vite 8
    /// project into rolldown's "Cannot find native binding" spew: the loader's wasi branch
    /// probes `@rolldown/binding-wasm32-wasi` by name, but nothing had installed it. So when
    /// the listing is gone, the name is DERIVED from the natives' own naming shape
    /// (`@scope/binding-<platform>-<arch>` → `…-wasm32-wasi`), pinned to the package's exact
    /// version — napi-rs publishes every binding in lockstep. A derived name is a GUESS about
    /// the registry, so it resolves as `optional`: a package with no wasi build installs
    /// exactly as before rather than failing the whole tree.
    static func wasiBinding(of package: ResolvedPackage) -> (name: String, requirement: String, derived: Bool)? {
        for (name, requirement) in package.optionalDependencies.sorted(by: { $0.key < $1.key })
        where name.hasSuffix("-wasm32-wasi") {
            return (name, requirement, false)
        }
        for name in package.optionalDependencies.keys.sorted() {
            for platform in ["-darwin-", "-linux-", "-win32-", "-freebsd-", "-android-", "-openharmony-"] {
                if let range = name.range(of: platform) {
                    let stem = String(name[..<range.lowerBound])
                    return (stem + "-wasm32-wasi", package.version, true)
                }
            }
        }
        return nil
    }

    static func resolveTree(requirements: [String: String], session: Session) async throws -> [Placement] {
        var placements: [Placement] = []
        var rootVersions: [String: String] = [:]
        var queue: [(name: String, requirement: String, dependentPath: String?)] = []
        var seen = Set<String>()

        for (name, requirement) in requirements.sorted(by: { $0.key < $1.key }) {
            queue.append((name, requirement, nil))
        }

        while !queue.isEmpty {
            let (name, requirement, dependentPath) = queue.removeFirst()
            // Resolved under the substitute's name, placed under the original's. Both projects
            // version their wasm build in lockstep with the native one, so the requirement
            // carries over unchanged.
            let package = try await session.resolve(name: wasmSubstitutes[name] ?? name, requirement: requirement)

            let path: String
            if let existing = rootVersions[name] {
                if existing == package.version { continue }   // hoisted copy already serves this
                guard let dependentPath else { continue }     // root conflict: first wins
                path = "\(dependentPath)/node_modules/\(name)"
                if seen.contains(path) { continue }
            } else {
                rootVersions[name] = package.version
                path = "node_modules/\(name)"
            }
            seen.insert(path)
            // "requested as X, is really Y" covers both cases now: a wasm substitute standing in
            // for a native package, and an npm: alias installing one package under another name.
            placements.append(Placement(package: package, path: path,
                                        installedAs: package.name == name ? nil : name))
            for (depName, depRequirement) in package.dependencies.sorted(by: { $0.key < $1.key }) {
                queue.append((depName, depRequirement, path))
            }
            if let wasi = wasiBinding(of: package) {
                if wasi.derived {
                    // The guessed name may not exist; probe before it joins the tree, so a
                    // package that truly has no wasi build installs exactly as it always did.
                    if let probed = try? await session.resolve(name: wasi.name, requirement: wasi.requirement) {
                        _ = probed
                        queue.append((wasi.name, wasi.requirement, path))
                    }
                } else {
                    queue.append((wasi.name, wasi.requirement, path))
                }
            }
        }
        return placements
    }

    // MARK: - Install

    struct InstallReport {
        var placements: [Placement] = []
        var bins: [String: String] = [:]   // bin name → path relative to root
    }

    /// Resolve and install `requirements` into `root`. Downloads verify against the
    /// registry's integrity (sha512, sha1 fallback) before a byte is unpacked.
    static func install(requirements: [String: String], into root: URL,
                        session: Session = Session(),
                        progress: (String) -> Void = { _ in }) async throws -> InstallReport {
        let placements = try await resolveTree(requirements: requirements, session: session)
        var report = InstallReport()
        report.placements = placements
        for placement in placements {
            let package = placement.package
            guard let url = URL(string: package.tarball) else {
                throw PackageError("\(package.name): bad tarball URL")
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PackageError("\(package.name): tarball download failed")
            }
            try verifyIntegrity(data, package: package)
            let destination = root.appendingPathComponent(placement.path)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try TarGz.extract(data, into: destination, stripComponents: 1)
            if let requested = placement.installedAs {
                progress("\(requested)@\(package.version) as \(package.name)")
            } else {
                progress("\(package.name)@\(package.version)")
            }
            if placement.atRoot {
                for (bin, file) in package.bin {
                    report.bins[bin] = "\(placement.path)/\(file.hasPrefix("./") ? String(file.dropFirst(2)) : file)"
                }
            }
        }
        try writeManifest(report, root: root)
        return report
    }

    private static func verifyIntegrity(_ data: Data, package: ResolvedPackage) throws {
        if let integrity = package.integrity {
            let pieces = integrity.split(separator: "-", maxSplits: 1)
            guard pieces.count == 2 else { return }
            let algorithm = pieces[0]
            let expected = String(pieces[1])
            let actual: String
            switch algorithm {
            case "sha512": actual = Data(SHA512.hash(data: data)).base64EncodedString()
            case "sha256": actual = Data(SHA256.hash(data: data)).base64EncodedString()
            case "sha1": actual = Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
            default: return
            }
            guard actual == expected else {
                throw PackageError("\(package.name): integrity check failed")
            }
        } else if let shasum = package.shasum {
            let actual = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == shasum else {
                throw PackageError("\(package.name): integrity check failed")
            }
        }
    }

    // MARK: - Manifest ($PATH's view of node_modules)

    static let manifestPath = "node_modules/.mouse-manifest.json"

    static func writeManifest(_ report: InstallReport, root: URL) throws {
        var existing = readManifest(root: root) ?? (packages: [:], bins: [:])
        for placement in report.placements {
            existing.packages["\(placement.path)"] = placement.package.version
        }
        for (bin, path) in report.bins { existing.bins[bin] = path }
        let json: [String: Any] = ["packages": existing.packages, "bins": existing.bins]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let url = root.appendingPathComponent(manifestPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func readManifest(root: URL) -> (packages: [String: String], bins: [String: String])? {
        let url = root.appendingPathComponent(manifestPath)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (packages: json["packages"] as? [String: String] ?? [:],
                bins: json["bins"] as? [String: String] ?? [:])
    }

    // MARK: - package.json

    static func readPackageJSON(root: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    static func writePackageJSON(_ json: [String: Any], root: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("package.json"))
    }
}

/// Native .tar.gz extraction: gzip via the Compression framework, tar parsed by hand (ustar +
/// GNU longname + pax path records — enough for GitHub tarballs and npm registry tarballs).
enum TarGz {
    struct ExtractError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func extract(_ tgz: Data, into destination: URL, stripComponents: Int = 0) throws {
        let tar = try gunzip(tgz)
        let fm = FileManager.default
        var offset = 0
        var pendingLongName: String?
        var pendingPaxPath: String?

        while offset + 512 <= tar.count {
            let header = tar.subdata(in: offset..<(offset + 512))
            offset += 512
            if header.allSatisfy({ $0 == 0 }) { continue }  // end-of-archive padding

            let size = numeric(header, 124, 12)
            let typeflag = header[156]
            var name = field(header, 0, 100)
            let prefix = field(header, 345, 155)
            if !prefix.isEmpty { name = prefix + "/" + name }
            if let long = pendingLongName { name = long; pendingLongName = nil }
            if let pax = pendingPaxPath { name = pax; pendingPaxPath = nil }

            let content = size > 0 ? tar.subdata(in: offset..<min(offset + size, tar.count)) : Data()
            offset += (size + 511) / 512 * 512

            switch typeflag {
            case UInt8(ascii: "L"):  // GNU long name: content is the next entry's path
                pendingLongName = String(decoding: content, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                continue
            case UInt8(ascii: "x"):  // pax extended header: may override the next entry's path
                pendingPaxPath = paxValue(content, key: "path")
                continue
            case UInt8(ascii: "g"):  // pax global header: ignore
                continue
            default:
                break
            }

            var components = name.split(separator: "/").map(String.init)
            guard components.count > stripComponents else { continue }
            components.removeFirst(stripComponents)
            // Never let an archive write outside the destination.
            guard !components.contains(".."), !components.isEmpty else { continue }
            let target = components.reduce(destination) { $0.appendingPathComponent($1) }

            switch typeflag {
            case UInt8(ascii: "5"):
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target)
            case UInt8(ascii: "2"):
                let linkTarget = field(header, 157, 100)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                try? fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
            default:
                break  // hardlinks, fifos, devices: skip
            }
        }
    }

    /// NUL-terminated fixed-width text field.
    private static func field(_ header: Data, _ start: Int, _ len: Int) -> String {
        var bytes: [UInt8] = []
        for i in start..<(start + len) {
            let c = header[i]
            if c == 0 { break }
            bytes.append(c)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// Octal size field, with GNU base-256 fallback for huge entries.
    private static func numeric(_ header: Data, _ start: Int, _ len: Int) -> Int {
        if header[start] & 0x80 != 0 {
            var value = 0
            for i in 1..<len { value = value << 8 | Int(header[start + i]) }
            return value
        }
        var value = 0
        for i in start..<(start + len) {
            let c = header[i]
            if c >= 0x30 && c <= 0x37 { value = value * 8 + Int(c - 0x30) }
            else if value > 0 { break }
        }
        return value
    }

    /// Parse a pax record stream ("<len> <key>=<value>\n"...) for one key.
    private static func paxValue(_ content: Data, key: String) -> String? {
        guard let text = String(data: content, encoding: .utf8) else { return nil }
        var rest = Substring(text)
        while let space = rest.firstIndex(of: " ") {
            guard let length = Int(rest[..<space]), length > 0,
                  let end = rest.index(rest.startIndex, offsetBy: length, limitedBy: rest.endIndex)
            else { return nil }
            let record = rest[rest.index(after: space)..<end].dropLast()  // trailing \n
            if record.hasPrefix("\(key)=") { return String(record.dropFirst(key.count + 1)) }
            rest = rest[end...]
        }
        return nil
    }

    /// Decode a gzip member: parse the header by hand, inflate the raw DEFLATE payload via the
    /// Compression framework (its ZLIB mode is raw DEFLATE, which is exactly gzip's payload).
    static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else {
            throw ExtractError("not a gzip archive")
        }
        let flags = data[3]
        var idx = 10
        if flags & 0x04 != 0 {  // FEXTRA
            let xlen = Int(data[idx]) | (Int(data[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if flags & 0x08 != 0 { while idx < data.count, data[idx] != 0 { idx += 1 }; idx += 1 }  // FNAME
        if flags & 0x10 != 0 { while idx < data.count, data[idx] != 0 { idx += 1 }; idx += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { idx += 2 }  // FHCRC
        guard idx < data.count else { throw ExtractError("truncated gzip archive") }
        return try inflate(data.subdata(in: idx..<data.count))
    }

    /// Raw DEFLATE, the same stream a zip entry holds — shared with `ZipArchive`, which unpacks
    /// downloaded language runtimes.
    static func inflateRaw(_ input: Data) throws -> Data { try inflate(input) }

    private static func inflate(_ input: Data) throws -> Data {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ExtractError("couldn't start the decompressor")
        }
        defer { compression_stream_destroy(streamPointer) }

        let chunkSize = 1 << 17
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw ExtractError("empty archive")
            }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = raw.count
            while true {
                streamPointer.pointee.dst_ptr = chunk
                streamPointer.pointee.dst_size = chunkSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(chunk, count: chunkSize - streamPointer.pointee.dst_size)
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw ExtractError("corrupt archive") }
            }
        }
        return output
    }
}
