import Darwin
import Foundation

/// File watching for the Node layer (system.md phase G): what `fs.watch` is. Every watching
/// tool an IDE runs needs it — `tsc --watch`, a dev server's HMR, `nodemon`, `jest --watch` —
/// and so does Mouse itself when a program rewrites a file the editor has open.
///
/// kqueue through `DispatchSource.makeFileSystemObjectSource`, because FSEvents is macOS-only.
/// kqueue reports that a DIRECTORY changed, never which entry, so a directory watch keeps a
/// snapshot of its listing and diffs it to name the file — which is also how it tells a
/// create from a delete. Recursive watching is a watch per subdirectory, added and dropped as
/// directories appear and vanish, since kqueue has no recursive mode.
///
/// Threading matches the socket layer: all state on one serial queue, events delivered to the
/// JS thread through `deliver` (the engine's `enqueueJob`), and an open watcher holds a handle
/// so the event loop stays awake exactly like node's.
final class WatchTable: @unchecked Sendable {

    /// node's two event names. `rename` covers appearing, disappearing and moving; `change`
    /// is a write to a watched file's contents.
    enum Event {
        case rename(String)
        case change(String)
    }

    private let deliver: (@escaping @Sendable () -> Void) -> Void
    private let retain: @Sendable () -> Void
    private let release: @Sendable () -> Void

    private let queue = DispatchQueue(label: "mouse.node.watch")
    private var watchers: [Int: Watcher] = [:]
    private var nextID = 1
    private let idLock = NSLock()

    /// One `fs.watch()` call. A recursive watch owns several kqueue sources but is one
    /// watcher to JavaScript.
    /// Confined to `queue`, like the socket table's Entry.
    private final class Watcher: @unchecked Sendable {
        let id: Int
        let root: String
        let recursive: Bool
        let handler: @Sendable (Event) -> Void
        var sources: [String: (source: DispatchSourceFileSystemObject, fd: Int32)] = [:]
        /// Directory listings, for diffing a kqueue "something changed" into a filename.
        var listings: [String: Set<String>] = [:]
        var closed = false

        init(id: Int, root: String, recursive: Bool, handler: @escaping @Sendable (Event) -> Void) {
            self.id = id
            self.root = root
            self.recursive = recursive
            self.handler = handler
        }
    }

    init(deliver: @escaping (@escaping @Sendable () -> Void) -> Void,
         retain: @escaping @Sendable () -> Void,
         release: @escaping @Sendable () -> Void) {
        self.deliver = deliver
        self.retain = retain
        self.release = release
    }

    /// Start watching. Returns the id synchronously; `nil` back through `failure` when the
    /// path cannot be opened (node throws ENOENT for that, so the caller needs to know).
    func watch(path: String, recursive: Bool, handler: @escaping @Sendable (Event) -> Void) -> Int? {
        var probe = stat()
        guard lstat(path, &probe) == 0 else { return nil }
        // Read before the queue hop: the closure below must capture values, not a mutable var.
        let isDirectory = (probe.st_mode & S_IFMT) == S_IFDIR

        let id = claimID()
        retain()
        queue.async { [self] in
            let watcher = Watcher(id: id, root: path, recursive: recursive, handler: handler)
            watchers[id] = watcher
            if isDirectory {
                addDirectory(watcher, path)
                if recursive { for child in subdirectories(of: path) { addDirectory(watcher, child) } }
            } else {
                addFile(watcher, path, isRoot: true)
            }
        }
        return id
    }

    func close(id: Int) {
        queue.async { [self] in
            guard let watcher = watchers[id], !watcher.closed else { return }
            watcher.closed = true
            for (_, entry) in watcher.sources { entry.source.cancel() }
            watcher.sources = [:]
            watchers[id] = nil
            release()
        }
    }

    /// Close every watcher — the engine calls this when a program exits.
    func closeAll() {
        queue.sync {
            for watcher in watchers.values where !watcher.closed {
                watcher.closed = true
                for (_, entry) in watcher.sources { entry.source.cancel() }
                watcher.sources = [:]
                release()
            }
            watchers = [:]
        }
    }

    // MARK: - Internals (on `queue`)

    private func claimID() -> Int {
        idLock.lock()
        defer { idLock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    /// Descriptors are finite, and a recursive watch over `node_modules` would happily eat
    /// every one. Past the cap a directory keeps its own watch (so entries appearing and
    /// disappearing are still reported) but modifications inside it are reported against the
    /// directory rather than named.
    private static let maxSourcesPerWatcher = 1024

    private func addFile(_ watcher: Watcher, _ path: String, isRoot: Bool = false) {
        guard watcher.sources[path] == nil else { return }
        guard isRoot || watcher.sources.count < Self.maxSourcesPerWatcher else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib, .extend], queue: queue)
        source.setEventHandler { [weak self, weak watcher] in
            guard let self, let watcher, !watcher.closed else { return }
            let data = source.data
            // node names a file relative to what was watched: the basename when the file IS
            // the watch, otherwise its path within the watched directory.
            let name = self.reported(path, watcher) ?? (path as NSString).lastPathComponent
            if data.contains(.delete) || data.contains(.rename) {
                // Inside a directory watch the listing diff already reports this — emitting
                // here too would double every delete. The root-file watch has no diff, so it
                // must report it itself.
                if isRoot { self.emit(watcher, .rename(name)) }
                // The inode is gone; a rewritten file (write-to-temp-then-rename, which is
                // what editors and bundlers do) needs the watch re-established on the NEW
                // inode or every later change is invisible.
                self.reopen(watcher, path, isRoot: isRoot)
            } else {
                self.emit(watcher, .change(name))
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        watcher.sources[path] = (source, fd)
        source.resume()
    }

    private func addDirectory(_ watcher: Watcher, _ path: String) {
        guard watcher.sources[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watcher.listings[path] = listing(of: path)
        // Watch the files too: kqueue says "this directory changed" without naming the entry,
        // so a per-file watch is what lets a modification be reported with its name — which
        // is what watching tools key on.
        for name in (watcher.listings[path] ?? []).sorted() {
            let full = (path as NSString).appendingPathComponent(name)
            if !isDirectory(full) { addFile(watcher, full) }
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self, weak watcher] in
            guard let self, let watcher, !watcher.closed else { return }
            self.directoryChanged(watcher, path, source.data)
        }
        source.setCancelHandler { Darwin.close(fd) }
        watcher.sources[path] = (source, fd)
        source.resume()
    }

    /// kqueue said this directory changed but not how: diff the listing to find out.
    private func directoryChanged(_ watcher: Watcher, _ path: String, _ data: DispatchSource.FileSystemEvent) {
        if data.contains(.delete) || data.contains(.rename) {
            // The directory itself went away.
            let name = relative(path, to: watcher.root) ?? (path as NSString).lastPathComponent
            emit(watcher, .rename(name))
            watcher.sources[path]?.source.cancel()
            watcher.sources[path] = nil
            watcher.listings[path] = nil
            return
        }
        let before = watcher.listings[path] ?? []
        let after = listing(of: path)
        watcher.listings[path] = after

        for name in after.subtracting(before).sorted() {
            let full = (path as NSString).appendingPathComponent(name)
            emit(watcher, .rename(reported(full, watcher) ?? name))
            if isDirectory(full) {
                if watcher.recursive {
                    addDirectory(watcher, full)
                    for child in subdirectories(of: full) { addDirectory(watcher, child) }
                }
            } else {
                addFile(watcher, full)   // so later writes to it are named
            }
        }
        for name in before.subtracting(after).sorted() {
            let full = (path as NSString).appendingPathComponent(name)
            emit(watcher, .rename(reported(full, watcher) ?? name))
            if let entry = watcher.sources[full] {
                entry.source.cancel()
                watcher.sources[full] = nil
                watcher.listings[full] = nil
            }
        }
        // A write with no entry added or removed is reported by that file's OWN source, which
        // can name it — nothing to add here. Only past the descriptor cap, where files go
        // unwatched, does the directory report the change itself.
        if after == before, data.contains(.write), watcher.sources.count >= Self.maxSourcesPerWatcher {
            emit(watcher, .change(reported(path, watcher) ?? (path as NSString).lastPathComponent))
        }
    }

    /// A file replaced by rename keeps its path but not its inode.
    private func reopen(_ watcher: Watcher, _ path: String, isRoot: Bool) {
        guard !watcher.closed else { return }
        watcher.sources[path]?.source.cancel()
        watcher.sources[path] = nil
        // The replacement may not exist yet; retry briefly rather than giving up on the watch.
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self, weak watcher] in
            guard let self, let watcher, !watcher.closed else { return }
            if self.exists(path) { self.addFile(watcher, path, isRoot: isRoot) }
        }
    }

    private func emit(_ watcher: Watcher, _ event: Event) {
        let handler = watcher.handler
        deliver { handler(event) }
    }

    /// node reports a path RELATIVE to the watched root (and just the basename when the root
    /// is the file itself).
    private func reported(_ full: String, _ watcher: Watcher) -> String? {
        relative(full, to: watcher.root)
    }

    private func relative(_ path: String, to root: String) -> String? {
        guard path != root else { return (path as NSString).lastPathComponent }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func listing(of path: String) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return Set(names)
    }

    private func subdirectories(of path: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        var found: [String] = []
        for name in names.sorted() {
            let full = (path as NSString).appendingPathComponent(name)
            if isDirectory(full) {
                found.append(full)
                found.append(contentsOf: subdirectories(of: full))
            }
        }
        return found
    }

    private func isDirectory(_ path: String) -> Bool {
        var stats = stat()
        guard lstat(path, &stats) == 0 else { return false }
        return (stats.st_mode & S_IFMT) == S_IFDIR
    }

    private func exists(_ path: String) -> Bool {
        var stats = stat()
        return lstat(path, &stats) == 0
    }
}
