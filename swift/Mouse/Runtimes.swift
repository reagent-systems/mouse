import Foundation
import CryptoKit

/// Language runtimes that arrive as WebAssembly.
///
/// The rule this file exists to keep: a runtime is DOWNLOADED, never bundled. Shipping CPython
/// inside the app would add 45 MB to every install for a language most projects never touch, and
/// would freeze its version to whenever the app was last released. `pkg install python` fetches
/// the official wasm32-wasi build, checks it against a recorded hash, and unpacks it into the
/// app's Application Support directory — not Caches, because iOS may evict Caches under pressure
/// and a language silently disappearing mid-project is worse than the disk it costs.
///
/// What runs the artifact is the phase-G engine's own `node:wasi`: every one of python.wasm's 42
/// imports is `wasi_snapshot_preview1`, and every one of those is already implemented here.
enum RuntimeCatalog {
    struct Entry {
        let name: String
        let version: String
        let url: URL
        /// The download's size and SHA-256. The size is what the install line quotes before it
        /// starts; the hash is what makes the install refuse a corrupted or substituted archive.
        let downloadBytes: Int
        let sha256: String
        /// The interpreter inside the archive, and the directory its standard library lives in.
        let wasm: String
        let library: String?
        /// A one-line description of what the runtime is, for `pkg list`.
        let summary: String
    }

    static let python = Entry(
        name: "python",
        version: "3.14.6",
        url: URL(string: "https://github.com/brettcannon/cpython-wasi-build/releases/download/v3.14.6/python-3.14.6-wasi_sdk-24.zip")!,
        downloadBytes: 14_231_464,
        sha256: "73bf2e9774c4d8820d0877ec5db0b963df3a9611fc2a63838aeaee29dfd034e6",
        wasm: "python.wasm",
        library: "lib",
        summary: "CPython, the official wasm32-wasi build"
    )

    static let all: [Entry] = [python]

    static func entry(named name: String) -> Entry? {
        all.first { $0.name == name }
    }
}

/// Where installed runtimes live, and how they get there.
enum RuntimeStore {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("MouseRuntimes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    struct Installed {
        let name: String
        let version: String
        let directory: URL
        let wasm: URL
        let library: URL?
    }

    static func installed(_ name: String) -> Installed? {
        guard let entry = RuntimeCatalog.entry(named: name) else { return nil }
        let directory = root.appendingPathComponent(entry.name, isDirectory: true)
        let wasm = directory.appendingPathComponent(entry.wasm)
        guard FileManager.default.fileExists(atPath: wasm.path) else { return nil }
        let library = entry.library.map { directory.appendingPathComponent($0, isDirectory: true) }
        return Installed(name: entry.name, version: entry.version, directory: directory,
                         wasm: wasm, library: library)
    }

    static func installedNames() -> [String] {
        RuntimeCatalog.all.compactMap { installed($0.name) != nil ? $0.name : nil }
    }

    enum InstallError: Error, CustomStringConvertible {
        case download(String)
        case integrity(expected: String, got: String)
        case unpack(String)
        case missingInterpreter(String)

        var description: String {
            switch self {
            case .download(let why): "download failed: \(why)"
            // Naming both hashes matters: it separates "the network mangled it" from "this is not
            // the archive we recorded", and only the second is alarming.
            case .integrity(let expected, let got):
                "the download does not match its recorded hash\n  expected \(expected)\n  got      \(got)"
            case .unpack(let why): "could not unpack the archive: \(why)"
            case .missingInterpreter(let name): "the archive did not contain \(name)"
            }
        }
    }

    /// Download, verify, unpack, reporting progress as it goes — a multi-megabyte download with
    /// no output is indistinguishable from a hang.
    ///
    /// Progress arrives as a STREAM rather than through a callback the caller hands in: the work
    /// runs off the main actor (a 30 MB inflate has no business on the UI thread) while the
    /// caller consumes each line on whatever actor it lives on, so no closure has to cross
    /// between them. A `(String) -> Void` parameter here does not compile under strict
    /// concurrency, and the honest reason is that it would genuinely be a data race.
    static func install(_ entry: RuntimeCatalog.Entry) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task.detached {
                do {
                    try await performInstall(entry) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func performInstall(_ entry: RuntimeCatalog.Entry,
                                       note: @Sendable (String) -> Void) async throws {
        note("fetching \(entry.name) \(entry.version) (\(entry.downloadBytes / 1_000_000) MB)")
        let data: Data
        do {
            let (downloaded, response) = try await URLSession.shared.data(from: entry.url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw InstallError.download("HTTP \(http.statusCode)")
            }
            data = downloaded
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.download(error.localizedDescription)
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else {
            throw InstallError.integrity(expected: entry.sha256, got: digest)
        }

        let directory = root.appendingPathComponent(entry.name, isDirectory: true)
        // A half-written runtime is worse than none: unpack beside the target and swap, so an
        // interrupted install leaves the previous one intact.
        let staging = root.appendingPathComponent(".\(entry.name).incoming", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try ZipArchive.extract(data, to: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw InstallError.unpack("\(error)")
        }
        guard FileManager.default.fileExists(atPath: staging.appendingPathComponent(entry.wasm).path) else {
            try? FileManager.default.removeItem(at: staging)
            throw InstallError.missingInterpreter(entry.wasm)
        }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: staging, to: directory)
        note("installed \(entry.name) \(entry.version)")
    }

    static func remove(_ name: String) -> Bool {
        guard let entry = RuntimeCatalog.entry(named: name) else { return false }
        let directory = root.appendingPathComponent(entry.name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        try? FileManager.default.removeItem(at: directory)
        return true
    }
}

/// A reader for the ZIP format, because iOS has no `unzip` and the runtimes upstream publishes
/// are zips. Only what an unpack needs: walk the central directory, then copy stored entries and
/// inflate deflated ones. The inflate itself is the one `TarGz` already uses for npm
/// tarballs — Apple's `compression` framework in raw-DEFLATE mode, which is exactly what a zip
/// entry holds.
enum ZipArchive {
    struct FormatError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func extract(_ data: Data, to destination: URL) throws {
        let bytes = [UInt8](data)
        guard let eocd = endOfCentralDirectory(bytes) else {
            throw FormatError("no end-of-central-directory record — not a zip")
        }
        var offset = eocd.centralDirectoryOffset
        let manager = FileManager.default

        for _ in 0..<eocd.entryCount {
            guard offset + 46 <= bytes.count,
                  read32(bytes, offset) == 0x0201_4b50 else {
                throw FormatError("central directory entry is malformed")
            }
            let method = Int(read16(bytes, offset + 10))
            let compressedSize = Int(read32(bytes, offset + 20))
            let uncompressedSize = Int(read32(bytes, offset + 24))
            let nameLength = Int(read16(bytes, offset + 28))
            let extraLength = Int(read16(bytes, offset + 30))
            let commentLength = Int(read16(bytes, offset + 32))
            let localOffset = Int(read32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else {
                throw FormatError("entry name runs past the end of the archive")
            }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            // An entry naming `..` or an absolute path can write anywhere on disk. Archives are
            // downloads; refusing this is not paranoia, it is the whole reason to parse rather
            // than shell out.
            let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !name.hasPrefix("/"), !components.contains("..") else {
                throw FormatError("archive entry escapes its directory: \(name)")
            }
            let target = components.reduce(destination) { $0.appendingPathComponent($1) }
            if name.hasSuffix("/") {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            guard localOffset + 30 <= bytes.count, read32(bytes, localOffset) == 0x0403_4b50 else {
                throw FormatError("local header for \(name) is malformed")
            }
            // The local header repeats the name and extra-field lengths, and its own extra field
            // is frequently a different length from the central directory's — reading the
            // central one here lands in the middle of the data.
            let localNameLength = Int(read16(bytes, localOffset + 26))
            let localExtraLength = Int(read16(bytes, localOffset + 28))
            let start = localOffset + 30 + localNameLength + localExtraLength
            guard start + compressedSize <= bytes.count else {
                throw FormatError("data for \(name) runs past the end of the archive")
            }
            let payload = data.subdata(in: start..<(start + compressedSize))

            let contents: Data
            switch method {
            case 0: contents = payload
            case 8: contents = try TarGz.inflateRaw(payload)
            default: throw FormatError("\(name) uses compression method \(method), which is not deflate or stored")
            }
            guard contents.count == uncompressedSize else {
                throw FormatError("\(name) unpacked to \(contents.count) bytes, not the \(uncompressedSize) it declares")
            }
            try manager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            try contents.write(to: target)
        }
    }

    private struct EndRecord {
        let entryCount: Int
        let centralDirectoryOffset: Int
    }

    /// The EOCD sits at the end, after a comment of unknown length, so it is found by scanning
    /// backwards for its signature.
    private static func endOfCentralDirectory(_ bytes: [UInt8]) -> EndRecord? {
        guard bytes.count >= 22 else { return nil }
        var index = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 0xffff)
        while index >= floor {
            if read32(bytes, index) == 0x0605_4b50 {
                return EndRecord(entryCount: Int(read16(bytes, index + 10)),
                                 centralDirectoryOffset: Int(read32(bytes, index + 16)))
            }
            index -= 1
        }
        return nil
    }

    private static func read16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }

    private static func read32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8)
            | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }
}
