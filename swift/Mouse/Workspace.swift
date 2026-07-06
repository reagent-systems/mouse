import Foundation
import Compression

/// A ring's project: a working tree on local disk plus the cross-container state that makes the
/// ring's containers windows onto one thing (the file the viewer shows, later git state).
///
/// Phase 1 acquires the working tree from GitHub's tarball API (authenticated by `GitHubAuth`) and
/// extracts it natively — no git binary dependency yet. The Source Control phase brings libgit2,
/// which takes over acquisition (real clones) without changing this model's shape. The gunzip/tar
/// code here is shared infrastructure: the package manager (`pnpm install`) uses the same path.
@Observable
final class Workspace {
    let repoFullName: String
    let root: URL
    /// Path (relative to `root`) of the file the ring's viewer container shows.
    var openFilePath: String?

    enum Phase {
        case downloading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase

    /// Reopen an already-downloaded workspace (the restore path). Fails if the tree is gone.
    init?(existing repoFullName: String, openFilePath: String? = nil) {
        let dir = Self.directory(for: repoFullName)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        self.repoFullName = repoFullName
        self.root = dir
        self.openFilePath = openFilePath
        self.phase = .ready
    }

    /// A workspace whose download is in flight; call `finishReady`/`finishFailed` when it lands.
    init(downloading repoFullName: String) {
        self.repoFullName = repoFullName
        self.root = Self.directory(for: repoFullName)
        self.phase = .downloading
    }

    @MainActor func finishReady() { phase = .ready }
    @MainActor func finishFailed(_ message: String) { phase = .failed(message) }

    static func directory(for repoFullName: String) -> URL {
        let safe = repoFullName.replacingOccurrences(of: "/", with: "__")
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    /// Fetch the repo's tarball and extract it into the workspace directory (replacing whatever
    /// was there). Pure and nonisolated — runs off the main actor; callers update `phase`.
    static func fetchAndExtract(_ repoFullName: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repoFullName)/tarball")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TarGz.ExtractError("GitHub returned \(http.statusCode) for the download")
        }
        let dir = directory(for: repoFullName)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // GitHub tarballs wrap everything in a single "owner-repo-sha/" directory — strip it.
        try TarGz.extract(data, into: dir, stripComponents: 1)
    }
}

/// A repository the signed-in user can open, from `GET /user/repos`.
struct RepoSummary: Decodable, Identifiable, Sendable {
    let fullName: String
    let description: String?
    var id: String { fullName }

    static func fetchMine(token: String) async throws -> [RepoSummary] {
        var request = URLRequest(url: URL(string: "https://api.github.com/user/repos?per_page=100&sort=pushed")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TarGz.ExtractError("GitHub returned \(http.statusCode) listing repos")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([RepoSummary].self, from: data)
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
