import Foundation

/// `pip install`, the subset a wasi CPython can honour: pure-Python wheels.
///
/// The on-device Python has no pip and no ensurepip, and its wasi build cannot load a compiled
/// extension at all — so a real pip would mostly be a machine for producing confusing failures.
/// What CAN work is exactly this: a wheel is a zip (`ZipArchive` already reads those), PyPI's
/// JSON API is the registry, and a `py3-none-any` wheel unpacked into a site-packages directory
/// on `PYTHONPATH` is a working install. A package whose only wheels are compiled says so in one
/// line instead of failing at import time.
///
/// This is the first stage of embedding Hermes: the agent loop is pure Python, and the pieces
/// that are not get delegated to Mouse itself.
enum Pip {

    struct PipError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    /// Where installed wheels land: inside the python runtime's directory, which the shell
    /// mounts at `/usr/lib/python` — Runtimes.json puts `{root}/site-packages` on PYTHONPATH.
    static var sitePackages: URL {
        RuntimeStore.root.appendingPathComponent("python/site-packages", isDirectory: true)
    }

    /// Install packages and their dependency closure. `names` accepts `name` or `name==1.2.3`.
    /// Every landed wheel is reported through `note`; already-present packages are skipped.
    ///
    /// A package that CANNOT land (no pure wheel) is fatal only when it was asked for by name.
    /// A transitive one is skipped and reported instead — one compiled dep deep in a closure
    /// used to abandon everything still queued behind it, so `openai` lost its own dependencies
    /// to hermes's pyyaml. Whether a skipped dep actually matters is measured at import time,
    /// which is a real answer; refusing the whole closure was a guess.
    static func install(_ names: [String], into destination: URL? = nil,
                        note: @escaping @Sendable (String) -> Void) async throws {
        let target = destination ?? sitePackages
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let requested = Set(names.map { canonicalize(split($0).name) })
        var queue = names
        var seen: Set<String> = []
        var skipped: [String] = []
        while !queue.isEmpty {
            let spec = queue.removeFirst()
            let (name, pin) = split(spec)
            let canonical = canonicalize(name)
            guard seen.insert(canonical).inserted else { continue }
            // Substitutes come BEFORE the installed check so their adapter is refreshed on
            // every ask — an adapter that grows a missing name must reach installs that
            // already exist.
            if let substitute = substitutes[canonical] {
                note("\(canonical) has no pure wheel — installing \(substitute.install) in its place")
                queue.append(substitute.install)
                if let file = substitute.adapterFile, let source = substitute.adapterSource {
                    try source.write(to: target.appendingPathComponent(file),
                                     atomically: true, encoding: .utf8)
                }
                // A dist-info of its own, so "is pyyaml here" answers yes and the closure never
                // asks again.
                let dist = target.appendingPathComponent("\(canonical)-0.0.0.substituted.dist-info")
                try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
                try "Metadata-Version: 2.1\nName: \(canonical)\nVersion: 0.0.0.substituted\n"
                    .write(to: dist.appendingPathComponent("METADATA"), atomically: true, encoding: .utf8)
                continue
            }
            if installed(canonical, in: target) {
                note("\(canonical) is already installed")
                continue
            }
            do {
                let wheel = try await resolve(canonical, pin: pin)
                note("fetching \(canonical) \(wheel.version) (\(wheel.size / 1024) kB)")
                let data = try await download(wheel.url)
                try ZipArchive.extract(data, to: target)
                note("installed \(canonical) \(wheel.version)")
                // The wheel's own METADATA names what it needs. Markered requirements (extras,
                // other platforms, older pythons) are skipped whole: the one platform this runs
                // on is the one no marker anticipates, and an extra is opt-in by definition.
                queue.append(contentsOf: try requirements(of: canonical, version: wheel.version, in: target))
            } catch where !requested.contains(canonical) {
                skipped.append(canonical)
                note("skipped \(canonical): \("\(error)".replacingOccurrences(of: "pip: ", with: ""))")
            }
        }
        if !skipped.isEmpty {
            note("skipped \(skipped.count): \(skipped.joined(separator: ", ")) — imports needing them will say so")
        }
    }

    // MARK: - Substitutes

    /// The Python face of the house substitution pattern (`rollup` -> `@rollup/wasm-node`):
    /// a package that only exists compiled, replaced by a pure-published equivalent under the
    /// importable name the requester's code actually uses.
    ///
    /// pyyaml is the one that matters today — hermes's `utils.py` does `import yaml` on its
    /// first page — and ruamel.yaml is no stranger standing in: it BEGAN as a PyYAML fork,
    /// hermes already pins it, and its author publishes it pure. The adapter is the PyYAML
    /// surface callers actually use, expressed as ruamel calls.
    private static let substitutes: [String: (install: String, adapterFile: String?, adapterSource: String?)] = [
        "pyyaml": ("ruamel.yaml", "yaml.py", "# pyyaml has no pure-Python wheel, and this Python cannot load compiled extensions.\n# Installed by Mouse's pip as the `yaml` module: PyYAML's common surface over\n# ruamel.yaml (itself a PyYAML fork), which is pure and installed alongside.\nfrom ruamel.yaml import YAML as _YAML\nfrom ruamel.yaml.error import YAMLError  # noqa: F401  (PyYAML's name, re-exported)\nimport io as _io\n\ndef _load(stream, typ):\n    data = stream.read() if hasattr(stream, \"read\") else stream\n    return _YAML(typ=typ, pure=True).load(data)\n\ndef safe_load(stream): return _load(stream, \"safe\")\ndef load(stream, Loader=None): return _load(stream, \"safe\" if Loader is None else \"unsafe\")\ndef full_load(stream): return _load(stream, \"unsafe\")\n\ndef safe_load_all(stream):\n    data = stream.read() if hasattr(stream, \"read\") else stream\n    return _YAML(typ=\"safe\", pure=True).load_all(data)\n\ndef _dump(data, stream, typ, **kw):\n    yml = _YAML(typ=typ, pure=True)\n    yml.default_flow_style = kw.get(\"default_flow_style\", False)\n    if stream is None:\n        out = _io.StringIO()\n        yml.dump(data, out)\n        return out.getvalue()\n    yml.dump(data, stream)\n    return None\n\ndef safe_dump(data, stream=None, **kw): return _dump(data, stream, \"safe\", **kw)\ndef dump(data, stream=None, **kw): return _dump(data, stream, \"rt\", **kw)\n\nclass SafeLoader:  # noqa: N801 — PyYAML's names, kept for isinstance/subclass users\n    pass\nclass Loader(SafeLoader):\n    pass\n\nclass SafeDumper:  # subclassed in the wild (hermes's IndentDumper); representers are a no-op\n    @classmethod\n    def add_representer(cls, data_type, representer):\n        pass\nclass Dumper(SafeDumper):\n    pass\n\ndef add_representer(data_type, representer, Dumper=Dumper):\n    pass\n"),
    ]

    // MARK: - The registry

    private struct Wheel {
        let url: URL
        let version: String
        let size: Int
    }

    /// PyPI's JSON API. A pinned version asks for that release; otherwise the latest. Only a
    /// pure wheel (`…-none-any.whl`) is acceptable — anything else needs a compiled extension
    /// this Python can never load, and the error says that rather than "not found".
    private static func resolve(_ name: String, pin: String?) async throws -> Wheel {
        let path = pin.map { "pypi/\(name)/\($0)/json" } ?? "pypi/\(name)/json"
        guard let url = URL(string: "https://pypi.org/\(path)") else {
            throw PipError("pip: \(name) is not a package name")
        }
        let data = try await download(url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["urls"] as? [[String: Any]],
              let info = json["info"] as? [String: Any],
              let version = info["version"] as? String else {
            throw PipError("pip: no such package: \(name)" + (pin.map { "==\($0)" } ?? ""))
        }
        for file in files {
            guard let filename = file["filename"] as? String,
                  filename.hasSuffix("-none-any.whl"),
                  let location = file["url"] as? String,
                  let wheelURL = URL(string: location) else { continue }
            return Wheel(url: wheelURL, version: version, size: file["size"] as? Int ?? 0)
        }
        throw PipError("pip: \(name) \(version) has no pure-Python wheel — it needs a compiled "
            + "extension, which this Python cannot load")
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PipError("pip: \(url.host ?? "pypi") answered \(http.statusCode) for \(url.lastPathComponent)")
        }
        return data
    }

    // MARK: - The wheel's own manifest

    /// `Requires-Dist` from the unpacked `*.dist-info/METADATA`, minus anything markered.
    private static func requirements(of name: String, version: String, in target: URL) throws -> [String] {
        guard let metadata = metadataFile(name, in: target) else { return [] }
        let text = try String(contentsOf: metadata, encoding: .utf8)
        var wanted: [String] = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("Requires-Dist:") else { continue }
            let requirement = line.dropFirst("Requires-Dist:".count).trimmingCharacters(in: .whitespaces)
            guard !requirement.contains(";") else { continue }   // markered: extras, other platforms
            // "urllib3 (<3,>=1.21.1)" or "idna>=2.5" — the name stops at the first non-name char.
            let depName = requirement.prefix { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            if !depName.isEmpty { wanted.append(String(depName)) }
        }
        return wanted
    }

    private static func installed(_ name: String, in target: URL) -> Bool {
        metadataFile(name, in: target) != nil
    }

    /// The dist-info directory a wheel of `name` leaves behind, at any version. Wheel directory
    /// names use `_` where the package name has `-`.
    private static func metadataFile(_ name: String, in target: URL) -> URL? {
        let stem = name.replacingOccurrences(of: "-", with: "_").lowercased()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
        for entry in entries where entry.lowercased().hasPrefix(stem + "-") && entry.hasSuffix(".dist-info") {
            let file = target.appendingPathComponent(entry).appendingPathComponent("METADATA")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    // MARK: - Names

    /// PEP 503: comparisons happen on the lowercased name with runs of `-`, `_`, `.` as one `-`.
    static func canonicalize(_ name: String) -> String {
        var out = ""
        var dash = false
        for character in name.lowercased() {
            if "-_.".contains(character) {
                dash = true
            } else {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out.append(character)
            }
        }
        return out
    }

    /// `name==1.2.3` → (name, pin). Other operators are refused rather than misread: this
    /// installer resolves exact pins and latest, and pretending `>=` resolved would install
    /// something the requester did not ask for.
    static func split(_ spec: String) -> (name: String, pin: String?) {
        if let range = spec.range(of: "==") {
            return (String(spec[..<range.lowerBound]), String(spec[range.upperBound...]))
        }
        return (spec, nil)
    }
}
