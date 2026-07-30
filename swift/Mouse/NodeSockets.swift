import Darwin
import Foundation

/// TCP for the Node layer (system.md phase G): what `net` stands on, and through it
/// `http.createServer` — the dev-server story. POSIX sockets, Darwin only, no framework
/// above them: `Network.framework` would give TLS and happy-eyeballs for free but its
/// connections are async-only objects, and the shape `net` needs is a file descriptor we
/// can half-close (`shutdown(SHUT_WR)`) and hand to a Duplex.
///
/// Threading: every fd mutation happens on `queue`, one serial queue for the whole table,
/// so a read handler and a `write` from the JS thread can never race on the same buffer.
/// Sockets are non-blocking and driven by `DispatchSource`, NOT a thread each — a dev
/// server with 50 keep-alive connections must not cost 50 threads. Name resolution and
/// connect never block that queue either (see `connect`).
/// Events cross back to JavaScript through `deliver`, which is the engine's `enqueueJob`:
/// handlers then run ON the JS thread as event-loop jobs, like the URLSession path.
///
/// Every event carries its socket id, and a SERVER's handler receives its accepted sockets'
/// events too. That is what closes the window this layer originally got wrong: there is no
/// moment when a connection exists here but has no handler in JavaScript, because the
/// server's handler is installed before it can accept anything and `.connection` is
/// necessarily the first event delivered for a new id. Handing accepted sockets a
/// placeholder handler instead — and swapping it in later — silently dropped whatever the
/// peer said inside that window, including the FIN that ends the socket.
final class SocketTable: @unchecked Sendable {

    /// `(socket id, event)`. For `.connection` the id is the SERVER's; the new socket's id
    /// rides in the event.
    typealias Handler = @Sendable (Int, Event) -> Void

    /// One event, named the way the JS side switches on it.
    enum Event {
        case connect(local: Address, remote: Address)
        case listening(Address)
        /// A server accepted someone: the connection is already a live socket in the table.
        case connection(id: Int, local: Address, remote: Address)
        case data(Data)
        /// The peer half-closed (FIN): no more data will arrive, we may still write.
        case end
        /// The write queue emptied after a `write` reported backpressure.
        case drain
        case close
        case error(message: String, code: String)
    }

    struct Address {
        var address = ""
        var port = 0
        var family = "IPv4"
    }

    /// Anything a socket does that the event loop must stay awake for. The engine holds the
    /// count; `unref()` drops it without closing (node's semantics — a server that has
    /// `unref`'d does not by itself keep the process alive).
    private let deliver: (@escaping @Sendable () -> Void) -> Void
    private let retain: @Sendable () -> Void
    private let release: @Sendable () -> Void

    private let queue = DispatchQueue(label: "mouse.node.net")
    /// Name resolution only. Concurrent and separate from `queue` because `getaddrinfo`
    /// blocks for as long as DNS takes, and no other socket's I/O should wait on it.
    private let resolvers = DispatchQueue(label: "mouse.node.net.dns", attributes: .concurrent)
    private var entries: [Int: Entry] = [:]
    private var nextID = 1
    private let idLock = NSLock()

    /// 64 KB, node's default socket high-water mark: `write` returns false past it.
    private static let highWaterMark = 64 * 1024

    /// Every field is read and written on `queue` only — that confinement is what makes the
    /// unchecked annotation true, and it is the same discipline the engine uses for `TTY`.
    private final class Entry: @unchecked Sendable {
        let id: Int
        let fd: Int32
        var isServer = false
        var handler: Handler
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var pending = Data()
        /// `write` said "full" — the JS side is owed a `drain` when the queue empties.
        var needsDrain = false
        /// `end()` was called: shut the write side down once `pending` flushes.
        var shutdownAfterFlush = false
        /// The peer sent FIN. NOT a reason to close: a half-open socket may still be
        /// written to, and any bytes already read are still owed to JavaScript.
        var readEOF = false
        /// We sent FIN. Together with `readEOF` this is what retires the fd.
        var writeShutdown = false
        var paused = false
        /// The handshake hasn't settled: `write()` may queue bytes, but sending them now
        /// would be ENOTCONN. `finishConnect` flushes whatever accumulated.
        var connecting = false
        /// Data that arrived while paused, replayed on resume (a Readable that stops
        /// reading must not lose bytes — `http` pauses between requests).
        var buffered = Data()
        var refed = true
        var closed = false
        var local = Address()
        var remote = Address()

        init(id: Int, fd: Int32, handler: @escaping Handler) {
            self.id = id
            self.fd = fd
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

    // MARK: - Connect

    /// Resolve and connect. Returns the id synchronously (JS needs a handle to return from
    /// `net.connect`); every outcome after that arrives as an event.
    ///
    /// Nothing here blocks `queue`, and that is deliberate on two counts. Name resolution
    /// runs on `resolvers` because `getaddrinfo` can take seconds on a bad network, and it
    /// would otherwise stall every other socket's I/O. The connect itself is non-blocking
    /// with a write source for completion, for the same reason.
    func connect(host: String, port: Int, handler: @escaping Handler) -> Int {
        let id = claimID()
        retain()
        resolvers.async { [self] in
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                                 ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, String(port), &hints, &list)
            guard status == 0, let first = list else {
                let text = String(cString: gai_strerror(status))
                queue.async {
                    self.fail(id: id, handler: handler,
                              message: "getaddrinfo \(text) \(host)", code: "ENOTFOUND")
                }
                return
            }
            // Copy the address out before freeing the list — the socket work happens on
            // another queue, by which point `list` is gone.
            var target = sockaddr_storage()
            memcpy(&target, first.pointee.ai_addr, Int(first.pointee.ai_addrlen))
            let length = first.pointee.ai_addrlen
            let family = first.pointee.ai_family
            freeaddrinfo(list)

            let resolved = target      // hand the closure a value, not a mutable var
            queue.async {
                self.beginConnect(id: id, family: family, address: resolved,
                                  length: length, host: host, port: port, handler: handler)
            }
        }
        return id
    }

    private func beginConnect(id: Int, family: Int32, address: sockaddr_storage,
                              length: socklen_t, host: String, port: Int,
                              handler: @escaping Handler) {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fail(id: id, handler: handler, message: "socket failed", code: errnoCode())
            return
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setNonBlocking(fd)

        var target = address
        let result = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        let entry = Entry(id: id, fd: fd, handler: handler)
        entries[id] = entry

        if result == 0 {
            // Loopback completes the handshake inside connect(). Node would report the
            // server's 'connection' before this client's 'connect' (its poll pass reaches the
            // listening handle first); we report them the other way, and deferring this
            // delivery by a queue turn does NOT change that — a ready dispatch source is not
            // ordered against a queued block. Recorded as a divergence rather than papered
            // over: it is the relative order of events on two DIFFERENT sockets, which node
            // does not specify either.
            finishConnect(entry)
            return
        }
        guard errno == EINPROGRESS else {
            let code = errnoCode()
            entries[id] = nil
            close(fd)
            fail(id: id, handler: handler, message: "connect \(code) \(host):\(port)", code: code)
            return
        }
        // In flight: the socket becomes WRITABLE when the handshake settles, success or not.
        entry.connecting = true
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak entry] in
            guard let self, let entry, !entry.closed else { return }
            entry.writeSource?.cancel()
            entry.writeSource = nil
            var problem: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &problem, &size)
            if problem != 0 {
                errno = problem
                let code = self.errnoCode()
                self.emit(entry, .error(message: "connect \(code) \(host):\(port)", code: code))
                self.teardown(entry, emitClose: true)
                return
            }
            self.finishConnect(entry)
        }
        entry.writeSource = source
        source.resume()
    }

    private func finishConnect(_ entry: Entry) {
        entry.connecting = false
        entry.local = localAddress(entry.fd)
        entry.remote = peerAddress(entry.fd)
        startReading(entry)
        emit(entry, .connect(local: entry.local, remote: entry.remote))
        // Anything JS queued with write() before the handshake landed goes out now.
        if !entry.pending.isEmpty || entry.shutdownAfterFlush { flush(entry) }
    }

    // MARK: - Resolve

    /// `getaddrinfo` for its own sake — what `dns.lookup` is. Runs on `resolvers` (it blocks
    /// for as long as the network takes) and answers on the JS thread through `deliver`.
    func resolve(host: String, family: Int, completion: @escaping @Sendable ([Address], String?) -> Void) {
        retain()
        resolvers.async { [self] in
            var hints = addrinfo(ai_flags: 0,
                                 ai_family: family == 4 ? AF_INET : (family == 6 ? AF_INET6 : AF_UNSPEC),
                                 ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                                 ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &list)
            guard status == 0, let first = list else {
                deliver { completion([], "ENOTFOUND") }
                release()
                return
            }
            var found: [Address] = []
            var node: UnsafeMutablePointer<addrinfo>? = first
            while let current = node {
                var storage = sockaddr_storage()
                memcpy(&storage, current.pointee.ai_addr, Int(current.pointee.ai_addrlen))
                let address = describe(storage)
                // getaddrinfo repeats an address once per socket type; dns.lookup does not.
                if !address.address.isEmpty, !found.contains(where: { $0.address == address.address }) {
                    found.append(address)
                }
                node = current.pointee.ai_next
            }
            freeaddrinfo(list)
            let addresses = found
            deliver { completion(addresses, addresses.isEmpty ? "ENOTFOUND" : nil) }
            release()
        }
    }

    // MARK: - Listen

    /// Bind and listen. Port 0 means "any" — the assigned port comes back in `.listening`,
    /// which is how a dev server on an ephemeral port learns its own URL.
    func listen(host: String, port: Int, backlog: Int, handler: @escaping Handler) -> Int {
        let id = claimID()
        retain()
        queue.async { [self] in
            var hints = addrinfo(ai_flags: AI_PASSIVE, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                                 ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            let name = host.isEmpty ? "0.0.0.0" : host
            let status = getaddrinfo(name, String(port), &hints, &list)
            guard status == 0, let first = list else {
                fail(id: id, handler: handler, message: "getaddrinfo \(host)", code: "EADDRNOTAVAIL")
                return
            }
            defer { freeaddrinfo(list) }

            let fd = socket(first.pointee.ai_family, SOCK_STREAM, 0)
            guard fd >= 0 else {
                fail(id: id, handler: handler, message: "socket failed", code: errnoCode())
                return
            }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard bind(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
                let code = errnoCode()
                close(fd)
                fail(id: id, handler: handler, message: "listen \(code) \(name):\(port)", code: code)
                return
            }
            guard Darwin.listen(fd, Int32(backlog)) == 0 else {
                let code = errnoCode()
                close(fd)
                fail(id: id, handler: handler, message: "listen \(code)", code: code)
                return
            }
            setNonBlocking(fd)

            let entry = Entry(id: id, fd: fd, handler: handler)
            entry.isServer = true
            entry.local = localAddress(fd)
            entries[id] = entry
            startAccepting(entry)
            emit(entry, .listening(entry.local))
        }
        return id
    }

    // MARK: - Write side

    /// Queue bytes. Returns false when the queue is past the high-water mark — the JS side
    /// turns that into `write()`'s false and waits for `drain`.
    func write(id: Int, data: Data) -> Bool {
        var accepted = true
        queue.sync {
            guard let entry = entries[id], !entry.closed else { return }
            entry.pending.append(data)
            flush(entry)
            if entry.pending.count >= Self.highWaterMark {
                entry.needsDrain = true
                accepted = false
            }
        }
        return accepted
    }

    /// Half-close: flush what's queued, then FIN. The peer sees EOF while we can still read
    /// its reply — the shape a request/response protocol needs.
    func end(id: Int) {
        queue.async { [self] in
            guard let entry = entries[id], !entry.closed else { return }
            entry.shutdownAfterFlush = true
            flush(entry)
        }
    }

    func destroy(id: Int) {
        queue.async { [self] in
            guard let entry = entries[id] else { return }
            // A server closing while a completed handshake still sits in the backlog: the
            // connection EXISTS as far as the peer is concerned, so accept it before
            // dropping the listening fd. Otherwise the event loop can go quiescent and the
            // program exit with that connection never delivered (`server.close()` called
            // from a client's own 'close' handler hits this every time).
            if entry.isServer, !entry.closed { acceptAvailable(entry) }
            teardown(entry, emitClose: true)
        }
    }

    // MARK: - Flow control

    func pause(id: Int) {
        queue.async { [self] in entries[id]?.paused = true }
    }

    func resume(id: Int) {
        queue.async { [self] in
            guard let entry = entries[id], entry.paused else { return }
            entry.paused = false
            if !entry.buffered.isEmpty {
                let held = entry.buffered
                entry.buffered = Data()
                emit(entry, .data(held))
            }
            maybeClose(entry)
        }
    }

    /// node's `ref`/`unref`: whether this handle keeps the event loop awake.
    func setRef(id: Int, refed: Bool) {
        queue.async { [self] in
            guard let entry = entries[id], entry.refed != refed, !entry.closed else { return }
            entry.refed = refed
            if refed { retain() } else { release() }
        }
    }

    func setNoDelay(id: Int, _ on: Bool) {
        queue.async { [self] in
            guard let entry = entries[id] else { return }
            var value: Int32 = on ? 1 : 0
            setsockopt(entry.fd, IPPROTO_TCP, TCP_NODELAY, &value, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    func setKeepAlive(id: Int, _ on: Bool, delay: Int) {
        queue.async { [self] in
            guard let entry = entries[id] else { return }
            var value: Int32 = on ? 1 : 0
            setsockopt(entry.fd, SOL_SOCKET, SO_KEEPALIVE, &value, socklen_t(MemoryLayout<Int32>.size))
            if on, delay > 0 {
                var seconds = Int32(delay / 1000)
                setsockopt(entry.fd, IPPROTO_TCP, TCP_KEEPALIVE, &seconds, socklen_t(MemoryLayout<Int32>.size))
            }
        }
    }

    /// Close every handle — the engine calls this when a program exits so a forgotten
    /// server can't outlive it and hold the port.
    func closeAll() {
        queue.sync {
            for entry in entries.values { teardown(entry) }
        }
    }

    // MARK: - Internals (all on `queue`)

    private func emit(_ entry: Entry, _ event: Event) {
        let handler = entry.handler, id = entry.id
        deliver { handler(id, event) }
    }

    private func claimID() -> Int {
        idLock.lock()
        defer { idLock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private func startReading(_ entry: Entry) {
        let source = DispatchSource.makeReadSource(fileDescriptor: entry.fd, queue: queue)
        source.setEventHandler { [weak self, weak entry] in
            guard let self, let entry, !entry.closed else { return }
            self.readAvailable(entry)
        }
        entry.readSource = source
        source.resume()
    }

    private func readAvailable(_ entry: Entry) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = recv(entry.fd, &buffer, buffer.count, 0)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                if entry.paused { entry.buffered.append(chunk) } else { emit(entry, .data(chunk)) }
                continue
            }
            if count == 0 {
                // FIN, and nothing more. Closing here would be a data-loss bug — bytes
                // already read are still owed to JavaScript — and it is wrong for half-open
                // sockets, which stay writable after the peer is done. The fd retires in
                // `maybeClose`, once BOTH directions are finished.
                entry.readEOF = true
                emit(entry, .end)
                entry.readSource?.cancel()
                entry.readSource = nil
                maybeClose(entry)
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            let code = errnoCode()
            emit(entry, .error(message: "read \(code)", code: code))
            teardown(entry, emitClose: true)
            return
        }
    }

    private func startAccepting(_ entry: Entry) {
        let source = DispatchSource.makeReadSource(fileDescriptor: entry.fd, queue: queue)
        source.setEventHandler { [weak self, weak entry] in
            guard let self, let entry, !entry.closed else { return }
            self.acceptAvailable(entry)
        }
        entry.readSource = source
        source.resume()
    }

    private func acceptAvailable(_ server: Entry) {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let fd = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    accept(server.fd, address, &length)
                }
            }
            if fd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                let code = errnoCode()
                emit(server, .error(message: "accept \(code)", code: code))
                return
            }
            setNonBlocking(fd)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            let id = claimID()
            retain()
            // The accepted socket shares the SERVER's handler: JavaScript learns of it
            // through `.connection`, necessarily the first event for this id, and routes
            // everything after that by id.
            let entry = Entry(id: id, fd: fd, handler: server.handler)
            entry.local = localAddress(fd)
            entry.remote = peerAddress(fd)
            entries[id] = entry
            startReading(entry)
            emit(server, .connection(id: id, local: entry.local, remote: entry.remote))
        }
    }

    private func flush(_ entry: Entry) {
        guard !entry.connecting else { return }   // finishConnect flushes
        while !entry.pending.isEmpty {
            let sent = entry.pending.withUnsafeBytes { raw -> Int in
                send(entry.fd, raw.baseAddress, raw.count, 0)
            }
            if sent > 0 {
                entry.pending.removeFirst(sent)
                continue
            }
            if sent < 0, errno == EINTR { continue }
            if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                startWriting(entry)
                return
            }
            // EPIPE/ECONNRESET: the peer is gone. Report it and drop the queue.
            let code = errnoCode()
            entry.pending = Data()
            emit(entry, .error(message: "write \(code)", code: code))
            teardown(entry, emitClose: true)
            return
        }
        entry.writeSource?.cancel()
        entry.writeSource = nil
        if entry.needsDrain {
            entry.needsDrain = false
            emit(entry, .drain)
        }
        if entry.shutdownAfterFlush {
            shutdown(entry.fd, SHUT_WR)
            entry.shutdownAfterFlush = false
            entry.writeShutdown = true
            maybeClose(entry)
        }
    }

    private func startWriting(_ entry: Entry) {
        guard entry.writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: entry.fd, queue: queue)
        source.setEventHandler { [weak self, weak entry] in
            guard let self, let entry, !entry.closed else { return }
            self.flush(entry)
        }
        entry.writeSource = source
        source.resume()
    }

    /// Retire the fd only when nothing is left in either direction: the peer is done
    /// (`readEOF`), we are done (`writeShutdown`), the write queue drained, and every byte
    /// read has been handed to JavaScript.
    private func maybeClose(_ entry: Entry) {
        guard entry.readEOF, entry.writeShutdown,
              entry.pending.isEmpty, entry.buffered.isEmpty else { return }
        teardown(entry, emitClose: true)
    }

    private func teardown(_ entry: Entry, emitClose: Bool = false) {
        guard !entry.closed else { return }
        entry.closed = true
        entry.readSource?.cancel()
        entry.writeSource?.cancel()
        entry.readSource = nil
        entry.writeSource = nil
        close(entry.fd)
        entries[entry.id] = nil
        if entry.refed { release() }
        if emitClose { emit(entry, .close) }
    }

    private func fail(id: Int, handler: @escaping Handler, message: String, code: String) {
        entries[id] = nil
        release()
        deliver {
            handler(id, .error(message: message, code: code))
            handler(id, .close)
        }
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private func errnoCode() -> String {
        switch errno {
        case ECONNREFUSED: return "ECONNREFUSED"
        case ECONNRESET: return "ECONNRESET"
        case EPIPE: return "EPIPE"
        case EADDRINUSE: return "EADDRINUSE"
        case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
        case EACCES, EPERM: return "EACCES"
        case ETIMEDOUT: return "ETIMEDOUT"
        case EHOSTUNREACH: return "EHOSTUNREACH"
        case ENETUNREACH: return "ENETUNREACH"
        case ENOTCONN: return "ENOTCONN"
        default:
            let text = strerror(errno).map { String(cString: $0) } ?? "UNKNOWN"
            return "E" + text.uppercased().replacingOccurrences(of: " ", with: "")
        }
    }

    private func localAddress(_ fd: Int32) -> Address {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return ok == 0 ? describe(storage) : Address()
    }

    private func peerAddress(_ fd: Int32) -> Address {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
        }
        return ok == 0 ? describe(storage) : Address()
    }

    private func describe(_ storage: sockaddr_storage) -> Address {
        var result = Address()
        var mutable = storage
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if Int32(storage.ss_family) == AF_INET {
            withUnsafeMutablePointer(to: &mutable) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                    var addr = inet.pointee.sin_addr
                    inet_ntop(AF_INET, &addr, &text, socklen_t(text.count))
                    result.port = Int(UInt16(bigEndian: inet.pointee.sin_port))
                }
            }
            result.family = "IPv4"
        } else if Int32(storage.ss_family) == AF_INET6 {
            withUnsafeMutablePointer(to: &mutable) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet in
                    var addr = inet.pointee.sin6_addr
                    inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count))
                    result.port = Int(UInt16(bigEndian: inet.pointee.sin6_port))
                }
            }
            result.family = "IPv6"
        }
        result.address = text.withUnsafeBufferPointer { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return result
    }
}
