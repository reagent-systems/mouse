package com.reagentsystems.mouse.node

import com.reagentsystems.mouse.packages.Json
import java.io.IOException
import java.net.BindException
import java.net.ConnectException
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.NoRouteToHostException
import java.net.PortUnreachableException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.StandardProtocolFamily
import java.net.StandardSocketOptions
import java.net.UnknownHostException
import java.nio.ByteBuffer
import java.nio.channels.AlreadyBoundException
import java.nio.channels.CancelledKeyException
import java.nio.channels.ClosedChannelException
import java.nio.channels.DatagramChannel
import java.nio.channels.MembershipKey
import java.nio.channels.SelectableChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * TCP and UDP for the Android Node layer — what `net` stands on, and through it `http.createServer`,
 * which is the dev-server story. This is `swift/Mouse/NodeSockets.swift` rewritten against Java NIO.
 *
 * ## Why NIO, and not a thread per socket
 *
 * The iOS table is POSIX descriptors driven by `DispatchSource`, deliberately NOT a thread each:
 * "a dev server with 50 keep-alive connections must not cost 50 threads". That constraint is
 * sharper on Android, not weaker. `java.nio`'s `Selector` is the same shape — one thread watching
 * every channel for readiness — so the port keeps the property rather than the API.
 *
 * The alternative, `java.net.Socket` with blocking reads, is the thread-per-socket design the iOS
 * side rejected; and `AsynchronousSocketChannel` hands out completion callbacks on a pool, which
 * would put the serial confinement below back into contention for no gain.
 *
 * ## Threading, which is the whole safety argument
 *
 * One selector thread owns every channel and every [Entry] field. Work arriving from another
 * thread — the WebView's JavaBridge thread calling `netWrite`, a resolver thread finishing a
 * lookup — is posted as a task and run there, so a read handler and a `write` can never race on
 * the same buffer. That is `NodeSockets.swift`'s `queue`, spelled in the vocabulary this platform
 * has.
 *
 * Two deliberate exceptions, both forced:
 *
 *  - [write] must answer TRUE or FALSE synchronously, because that boolean IS node's backpressure
 *    signal (`socket.write()` returning false). So the write queue has its own lock and `write`
 *    appends under it, then wakes the selector to do the sending. Nothing else reads that queue
 *    off the selector thread.
 *  - Name resolution runs on a separate pool. `InetAddress.getByName` blocks for as long as DNS
 *    takes, and the iOS comment on this is the rule: "nothing may block the socket queue … or one
 *    slow host stalls every other socket's I/O".
 *
 * **Nothing here ever touches the main thread.** On Android that is not tidiness — a network call
 * on the main looper is a `NetworkOnMainThreadException`, and the WebView's JavaScript runs on the
 * main looper, so every one of these entry points is called from a thread that must not do I/O
 * itself.
 *
 * ## How an event reaches JavaScript
 *
 * iOS hands `SocketTable` a `JSValue` and calls it. Android's `@JavascriptInterface` cannot carry
 * a function, so the callback stays in JavaScript in a registry (`node-host.js`) keyed by the id
 * this table hands back, and an event crosses as `(handlerId, argsJson, final)` — see [post]. The
 * argument array is exactly iOS's `(id, event, payload)`, so the bootstrap's `_hostEvent` switch
 * is untouched.
 *
 * Every event carries its socket id, and a SERVER's handler receives its accepted sockets' events
 * too, tagged by id. That is the rule the iOS layer got wrong once and paid for: there is no
 * moment when a connection exists here but has no handler in JavaScript, because `.connection` is
 * necessarily the first event delivered for a new id and the server's handler is already
 * registered. Do not reintroduce a placeholder-then-adopt scheme.
 */
class NodeSockets(
    /**
     * Deliver one event to JavaScript. `handlerId` names the registry entry that owns the
     * callback, `argsJson` is a JSON array of the arguments, and `final` says the registry entry
     * may be dropped afterwards (its handle is gone).
     *
     * Called on the selector thread or a resolver thread — never the caller's.
     */
    private val post: (handlerId: Int, argsJson: String, final: Boolean) -> Unit,
    /** An open handle: the event loop must stay awake. iOS's `outstanding`/`hasOpenHandles`. */
    private val retain: () -> Unit,
    private val release: () -> Unit,
) {

    /** 64 KB, node's default socket high-water mark: `write` returns false past it. */
    private val highWaterMark = 64 * 1024

    private val ids = AtomicInteger(1)
    private val entries = ConcurrentHashMap<Int, Entry>()
    private val tasks = ConcurrentLinkedQueue<() -> Unit>()
    private val selector: Selector = Selector.open()

    /**
     * Name resolution only — separate from the selector thread because `InetAddress.getByName`
     * blocks for as long as the network takes, and no other socket's I/O should wait on it.
     * Daemon threads: a forgotten lookup must not keep the JVM (or the harness) alive.
     */
    private val resolvers = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "mouse.node.net.dns").apply { isDaemon = true }
    }

    @Volatile
    private var running = true

    private val pump = Thread({ loop() }, "mouse.node.net").apply { isDaemon = true; start() }

    // ------------------------------------------------------------------------ entries ----

    /**
     * One socket, server or datagram handle. Every field is read and written on the selector
     * thread, except the write queue — see the class note.
     */
    private class Entry(
        val id: Int,
        /** The registry id whose JavaScript handler receives this entry's events. */
        val ownerId: Int,
        val channel: SelectableChannel,
    ) {
        var key: SelectionKey? = null
        var isServer = false
        var isDatagram = false

        /** The handshake has not settled: `write` may queue bytes but sending them now is ENOTCONN. */
        var connecting = false

        /** The peer sent FIN. NOT a reason to close — a half-open socket is still writable. */
        var readEOF = false

        /** We sent FIN. Together with [readEOF] this is what retires the channel. */
        var writeShutdown = false

        var paused = false

        /** Data that arrived while paused, replayed on resume. `http` pauses between requests. */
        val buffered = ArrayList<ByteArray>()
        var bufferedBytes = 0

        var refed = true

        @Volatile
        var closed = false

        var local = Address()
        var remote = Address()

        /** Multicast groups this datagram socket joined, so they can be dropped by name. */
        val memberships = HashMap<String, MembershipKey>()

        // -- the write side, which `write()` touches from another thread --
        val writeLock = ReentrantLock()
        val pending = ArrayDeque<ByteBuffer>()
        var pendingBytes = 0

        /** `write` said "full" — JavaScript is owed a `drain` when the queue empties. */
        var needsDrain = false

        /** `end()` was called: shut the write side down once [pending] flushes. */
        var shutdownAfterFlush = false
    }

    /** An address as the bootstrap reads it: `{address, port, family}`. */
    data class Address(val address: String = "", val port: Int = 0, val family: String = "IPv4") {
        fun toMap(): Map<String, Any?> = mapOf("address" to address, "port" to port, "family" to family)
    }

    // ------------------------------------------------------------------- the selector ----

    private fun submit(task: () -> Unit) {
        tasks.add(task)
        selector.wakeup()
    }

    private fun loop() {
        while (running) {
            try {
                while (true) (tasks.poll() ?: break)()
                selector.select()
                val ready = selector.selectedKeys()
                val iterator = ready.iterator()
                while (iterator.hasNext()) {
                    val key = iterator.next()
                    iterator.remove()
                    val entry = key.attachment() as? Entry ?: continue
                    if (entry.closed) continue
                    try {
                        if (key.isValid && key.isAcceptable) acceptAvailable(entry)
                        if (key.isValid && key.isConnectable) completeConnect(entry)
                        if (key.isValid && key.isReadable) {
                            if (entry.isDatagram) receiveAvailable(entry) else readAvailable(entry)
                        }
                        if (key.isValid && key.isWritable) flush(entry)
                    } catch (_: CancelledKeyException) {
                        // The entry was torn down inside one of the handlers above; nothing left.
                    }
                }
            } catch (_: ClosedChannelException) {
                // A channel closed underneath the select pass. The entry is already gone.
            } catch (failure: IOException) {
                if (!running) return
                // A selector that itself failed is unrecoverable, and spinning on it would peg a
                // core. Stop rather than loop.
                running = false
                return
            }
        }
    }

    private fun register(entry: Entry, ops: Int) {
        entry.channel.configureBlocking(false)
        entry.key = entry.channel.register(selector, ops, entry)
    }

    private fun interest(entry: Entry, op: Int, on: Boolean) {
        val key = entry.key ?: return
        if (!key.isValid) return
        val now = key.interestOps()
        val next = if (on) now or op else now and op.inv()
        if (next != now) key.interestOps(next)
    }

    private fun claimId(): Int = ids.getAndIncrement()

    /**
     * An id from the same sequence, for a handle this table does not own — the iOS
     * `claimExternalID`, which exists so the WebSocket global's tasks cannot collide with socket
     * ids.
     */
    fun claimExternalId(): Int = claimId()

    // ---------------------------------------------------------------------- connect ----

    /**
     * Resolve and connect. Returns the id synchronously — JavaScript needs a handle to return from
     * `net.connect` — and every outcome after that arrives as an event.
     *
     * Nothing here blocks the selector thread, on two counts and both deliberate: the lookup runs
     * on [resolvers], and the connect is non-blocking with `OP_CONNECT` for completion.
     */
    fun connect(host: String, port: Int): Int {
        val id = claimId()
        retain()
        resolvers.execute {
            val target = try {
                InetAddress.getByName(if (host.isEmpty()) "localhost" else host)
            } catch (_: UnknownHostException) {
                submit { fail(id, "getaddrinfo ENOTFOUND $host", "ENOTFOUND") }
                return@execute
            } catch (_: SecurityException) {
                submit { fail(id, "getaddrinfo EACCES $host", "EACCES") }
                return@execute
            }
            submit { beginConnect(id, InetSocketAddress(target, port), host, port) }
        }
        return id
    }

    private fun beginConnect(id: Int, remote: InetSocketAddress, host: String, port: Int) {
        val channel = try {
            SocketChannel.open()
        } catch (failure: IOException) {
            fail(id, "socket ${codeFor(failure)}", codeFor(failure))
            return
        }
        val entry = Entry(id, id, channel)
        try {
            channel.configureBlocking(false)
            entries[id] = entry
            val settled = channel.connect(remote)
            register(entry, if (settled) SelectionKey.OP_READ else SelectionKey.OP_CONNECT)
            if (settled) {
                // A loopback handshake can complete inside connect(). node would report the
                // server's 'connection' before this client's 'connect'; whichever way this
                // platform lands, the relative order of events on two DIFFERENT sockets is not a
                // contract node states either — assert each socket's OWN sequence.
                finishConnect(entry)
            } else {
                entry.connecting = true
            }
        } catch (failure: IOException) {
            entries.remove(id)
            closeQuietly(channel)
            val code = codeFor(failure)
            fail(id, "connect $code $host:$port", code)
        }
    }

    private fun completeConnect(entry: Entry) {
        val channel = entry.channel as SocketChannel
        val remote = try {
            channel.remoteAddress
        } catch (_: IOException) {
            null
        }
        try {
            if (!channel.finishConnect()) return
        } catch (failure: IOException) {
            val code = codeFor(failure)
            val where = (remote as? InetSocketAddress)?.let { "${it.hostString}:${it.port}" } ?: ""
            emit(entry, "error", errorPayload("connect $code $where".trim(), code))
            teardown(entry, emitClose = true)
            return
        }
        interest(entry, SelectionKey.OP_CONNECT, false)
        interest(entry, SelectionKey.OP_READ, true)
        finishConnect(entry)
    }

    private fun finishConnect(entry: Entry) {
        entry.connecting = false
        val channel = entry.channel as SocketChannel
        entry.local = describe(runCatching { channel.localAddress }.getOrNull())
        entry.remote = describe(runCatching { channel.remoteAddress }.getOrNull())
        emit(entry, "connect", mapOf("local" to entry.local.toMap(), "remote" to entry.remote.toMap()))
        // Anything JavaScript queued with write() before the handshake landed goes out now.
        val waiting = entry.writeLock.withLock { entry.pending.isNotEmpty() || entry.shutdownAfterFlush }
        if (waiting) flush(entry)
    }

    // ----------------------------------------------------------------------- listen ----

    /**
     * Bind and listen. Port 0 means "any" — the assigned port comes back in `listening`, which is
     * how a dev server on an ephemeral port learns its own URL.
     */
    fun listen(host: String, port: Int, backlog: Int): Int {
        val id = claimId()
        retain()
        submit {
            val name = if (host.isEmpty()) "0.0.0.0" else host
            val bind = try {
                InetSocketAddress(InetAddress.getByName(name), port)
            } catch (_: UnknownHostException) {
                fail(id, "getaddrinfo EADDRNOTAVAIL $name", "EADDRNOTAVAIL")
                return@submit
            }
            val channel = try {
                ServerSocketChannel.open()
            } catch (failure: IOException) {
                fail(id, "socket ${codeFor(failure)}", codeFor(failure))
                return@submit
            }
            try {
                channel.configureBlocking(false)
                channel.setOption(StandardSocketOptions.SO_REUSEADDR, true)
                channel.bind(bind, if (backlog > 0) backlog else 511)
            } catch (failure: Exception) {
                closeQuietly(channel)
                val code = codeFor(failure)
                fail(id, "listen $code $name:$port", code)
                return@submit
            }
            val entry = Entry(id, id, channel)
            entry.isServer = true
            entry.local = describe(runCatching { channel.localAddress }.getOrNull())
            entries[id] = entry
            register(entry, SelectionKey.OP_ACCEPT)
            emit(entry, "listening", entry.local.toMap())
        }
        return id
    }

    private fun acceptAvailable(server: Entry) {
        val channel = server.channel as ServerSocketChannel
        while (true) {
            val accepted = try {
                channel.accept() ?: return
            } catch (failure: IOException) {
                val code = codeFor(failure)
                emit(server, "error", errorPayload("accept $code", code))
                return
            }
            val id = claimId()
            retain()
            // The accepted socket shares the SERVER's handler: JavaScript learns of it through
            // `connection`, necessarily the first event for this id, and routes everything after
            // that by id.
            val entry = Entry(id, server.ownerId, accepted)
            try {
                accepted.configureBlocking(false)
                entry.local = describe(runCatching { accepted.localAddress }.getOrNull())
                entry.remote = describe(runCatching { accepted.remoteAddress }.getOrNull())
                entries[id] = entry
                register(entry, SelectionKey.OP_READ)
            } catch (failure: IOException) {
                entries.remove(id)
                closeQuietly(accepted)
                release()
                continue
            }
            emit(
                server, "connection",
                mapOf("id" to id, "local" to entry.local.toMap(), "remote" to entry.remote.toMap()),
            )
        }
    }

    // ------------------------------------------------------------------- the read side ----

    private fun readAvailable(entry: Entry) {
        val channel = entry.channel as SocketChannel
        val buffer = ByteBuffer.allocate(64 * 1024)
        while (true) {
            buffer.clear()
            val count = try {
                channel.read(buffer)
            } catch (failure: IOException) {
                val code = codeFor(failure)
                emit(entry, "error", errorPayload("read $code", code))
                teardown(entry, emitClose = true)
                return
            }
            if (count > 0) {
                val bytes = ByteArray(count)
                buffer.flip()
                buffer.get(bytes)
                if (entry.paused) {
                    entry.buffered.add(bytes)
                    entry.bufferedBytes += count
                } else {
                    emitData(entry, bytes)
                }
                continue
            }
            if (count == 0) return
            // FIN, and nothing more. Closing here would be a data-loss bug — bytes already read
            // are still owed to JavaScript — and it is wrong for half-open sockets, which stay
            // writable after the peer is done. The channel retires in maybeClose, once BOTH
            // directions are finished.
            entry.readEOF = true
            interest(entry, SelectionKey.OP_READ, false)
            emit(entry, "end", null)
            maybeClose(entry)
            return
        }
    }

    // ------------------------------------------------------------------ the write side ----

    /**
     * Queue bytes. Returns false when the queue is past the high-water mark — JavaScript turns
     * that into `write()`'s false and waits for `drain`.
     *
     * Called from the JavaScript thread, which is why the queue has its own lock: the answer has
     * to be synchronous, and a rendezvous with the selector thread for every write would serialise
     * the whole engine behind one socket's send.
     */
    fun write(id: Int, data: ByteArray): Boolean {
        val entry = entries[id] ?: return true
        if (entry.closed) return true
        val accepted = entry.writeLock.withLock {
            entry.pending.addLast(ByteBuffer.wrap(data))
            entry.pendingBytes += data.size
            if (entry.pendingBytes >= highWaterMark) {
                entry.needsDrain = true
                false
            } else {
                true
            }
        }
        submit { if (!entry.closed) flush(entry) }
        return accepted
    }

    private fun flush(entry: Entry) {
        if (entry.connecting) return // finishConnect flushes
        val channel = entry.channel as? SocketChannel ?: return
        var drained = false
        var shutDown = false
        var failure: IOException? = null
        var wantsWritable = false

        entry.writeLock.withLock {
            while (entry.pending.isNotEmpty()) {
                val buffer = entry.pending.first()
                val sent = try {
                    channel.write(buffer)
                } catch (problem: IOException) {
                    // EPIPE / ECONNRESET: the peer is gone. Report it and drop the queue.
                    entry.pending.clear()
                    entry.pendingBytes = 0
                    failure = problem
                    return@withLock
                }
                entry.pendingBytes -= sent
                if (buffer.hasRemaining()) {
                    wantsWritable = true
                    return@withLock
                }
                entry.pending.removeFirst()
                if (sent == 0) {
                    wantsWritable = true
                    return@withLock
                }
            }
            if (entry.needsDrain) {
                entry.needsDrain = false
                drained = true
            }
            if (entry.shutdownAfterFlush) {
                entry.shutdownAfterFlush = false
                entry.writeShutdown = true
                shutDown = true
            }
        }

        val problem = failure
        if (problem != null) {
            val code = codeFor(problem)
            emit(entry, "error", errorPayload("write $code", code))
            teardown(entry, emitClose = true)
            return
        }
        interest(entry, SelectionKey.OP_WRITE, wantsWritable)
        if (drained) emit(entry, "drain", null)
        if (shutDown) {
            try {
                channel.shutdownOutput()
            } catch (_: IOException) {
                // The peer is already gone; the FIN it would have carried is moot.
            }
            maybeClose(entry)
        }
    }

    /**
     * Half-close: flush what is queued, then FIN. The peer sees EOF while we can still read its
     * reply — the shape a request/response protocol needs.
     */
    fun end(id: Int) {
        val entry = entries[id] ?: return
        entry.writeLock.withLock { entry.shutdownAfterFlush = true }
        submit { if (!entry.closed) flush(entry) }
    }

    fun destroy(id: Int) {
        submit {
            val entry = entries[id] ?: return@submit
            // A server closing while a completed handshake still sits in the backlog: the
            // connection EXISTS as far as the peer is concerned, so accept it before dropping the
            // listening channel. Otherwise the loop can go quiescent and the program exit with
            // that connection never delivered.
            if (entry.isServer && !entry.closed) acceptAvailable(entry)
            teardown(entry, emitClose = true)
        }
    }

    // ------------------------------------------------------------------ flow control ----

    fun pause(id: Int) {
        submit { entries[id]?.paused = true }
    }

    fun resume(id: Int) {
        submit {
            val entry = entries[id] ?: return@submit
            if (!entry.paused) return@submit
            entry.paused = false
            if (entry.buffered.isNotEmpty()) {
                val held = entry.buffered.toList()
                entry.buffered.clear()
                entry.bufferedBytes = 0
                for (chunk in held) emitData(entry, chunk)
            }
            maybeClose(entry)
        }
    }

    /** node's `ref`/`unref`: whether this handle keeps the event loop awake. */
    fun setRef(id: Int, refed: Boolean) {
        submit {
            val entry = entries[id] ?: return@submit
            if (entry.closed || entry.refed == refed) return@submit
            entry.refed = refed
            if (refed) retain() else release()
        }
    }

    fun setNoDelay(id: Int, on: Boolean) {
        submit {
            val channel = entries[id]?.channel as? SocketChannel ?: return@submit
            try {
                channel.setOption(StandardSocketOptions.TCP_NODELAY, on)
            } catch (_: IOException) {
            }
        }
    }

    /**
     * `SO_KEEPALIVE`, and only that. The iOS block also sets `TCP_KEEPALIVE` for the idle delay;
     * `java.net.StandardSocketOptions` has no portable spelling for it (`TCP_KEEPIDLE` is a JDK 11
     * `jdk.net.ExtendedSocketOptions` entry that Android does not ship), so the delay is accepted
     * and not applied — see kotlin/README.md.
     */
    fun setKeepAlive(id: Int, on: Boolean) {
        submit {
            val channel = entries[id]?.channel as? SocketChannel ?: return@submit
            try {
                channel.setOption(StandardSocketOptions.SO_KEEPALIVE, on)
            } catch (_: IOException) {
            }
        }
    }

    // -------------------------------------------------------------------- resolution ----

    /**
     * `getaddrinfo` for its own sake — what `dns.lookup` is. Runs on [resolvers] and answers
     * through [post] against the one-shot callback registered under [handlerId].
     *
     * `family` is 4, 6, or 0 for either.
     */
    fun resolve(handlerId: Int, host: String, family: Int) {
        retain()
        resolvers.execute {
            val found = try {
                InetAddress.getAllByName(host).toList()
            } catch (_: UnknownHostException) {
                emptyList()
            } catch (_: SecurityException) {
                emptyList()
            }
            val wanted = found.filter {
                when (family) {
                    4 -> it is Inet4Address
                    6 -> it is Inet6Address
                    else -> true
                }
            }
            // getaddrinfo repeats an address once per socket type; dns.lookup does not.
            val seen = LinkedHashMap<String, Map<String, Any?>>()
            for (address in wanted) {
                val text = address.hostAddress ?: continue
                seen.getOrPut(text) {
                    mapOf("address" to text, "family" to if (address is Inet6Address) 6 else 4)
                }
            }
            val list = seen.values.toList()
            post(handlerId, Json.write(listOf(list, if (list.isEmpty()) "ENOTFOUND" else "")), true)
            release()
        }
    }

    // -------------------------------------------------------------------- datagrams ----

    /**
     * Bind a UDP socket. Port 0 means "any", and the assigned one comes back in `listening`,
     * exactly as for a listener — that is how a program learns its own port.
     */
    fun bindDatagram(host: String, port: Int, broadcast: Boolean): Int {
        val id = claimId()
        retain()
        submit {
            val name = if (host.isEmpty()) "0.0.0.0" else host
            val target = try {
                InetAddress.getByName(name)
            } catch (_: UnknownHostException) {
                fail(id, "getaddrinfo EADDRNOTAVAIL $name", "EADDRNOTAVAIL")
                return@submit
            }
            // Opened with an explicit protocol family so `join()` is available: a DatagramChannel
            // created by the no-argument open() refuses multicast membership on some JDKs, and
            // that refusal would arrive much later, at the join.
            val family = if (target is Inet6Address) StandardProtocolFamily.INET6
            else StandardProtocolFamily.INET
            val channel = try {
                DatagramChannel.open(family)
            } catch (failure: IOException) {
                fail(id, "socket ${codeFor(failure)}", codeFor(failure))
                return@submit
            }
            try {
                channel.configureBlocking(false)
                channel.setOption(StandardSocketOptions.SO_REUSEADDR, true)
                if (broadcast) channel.setOption(StandardSocketOptions.SO_BROADCAST, true)
                channel.bind(InetSocketAddress(target, port))
            } catch (failure: Exception) {
                closeQuietly(channel)
                val code = codeFor(failure)
                fail(id, "bind $code $name:$port", code)
                return@submit
            }
            val entry = Entry(id, id, channel)
            entry.isDatagram = true
            entry.local = describe(runCatching { channel.localAddress }.getOrNull())
            entries[id] = entry
            register(entry, SelectionKey.OP_READ)
            emit(entry, "listening", entry.local.toMap())
        }
        return id
    }

    private fun receiveAvailable(entry: Entry) {
        val channel = entry.channel as DatagramChannel
        val buffer = ByteBuffer.allocate(65536)
        while (true) {
            buffer.clear()
            val from = try {
                channel.receive(buffer) ?: return
            } catch (failure: IOException) {
                val code = codeFor(failure)
                emit(entry, "error", errorPayload("recvfrom $code", code))
                return
            }
            buffer.flip()
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            // A datagram is delivered whole, with its sender: there is no stream to reassemble and
            // no partial read to buffer.
            emit(
                entry, "datagram",
                mapOf(
                    "data" to Base64.getEncoder().encodeToString(bytes),
                    "from" to describe(from).toMap(),
                ),
            )
        }
    }

    /** Send one datagram. Resolution happens on the resolver pool, like every other name. */
    fun sendDatagram(handlerId: Int, id: Int, data: ByteArray, host: String, port: Int) {
        resolvers.execute {
            val target = try {
                InetAddress.getByName(host)
            } catch (_: UnknownHostException) {
                post(handlerId, Json.write(listOf("ENOTFOUND")), true)
                return@execute
            }
            submit {
                val entry = entries[id]
                val channel = entry?.channel as? DatagramChannel
                if (entry == null || entry.closed || channel == null) {
                    post(handlerId, Json.write(listOf("EBADF")), true)
                    return@submit
                }
                val code = try {
                    channel.send(ByteBuffer.wrap(data), InetSocketAddress(target, port))
                    ""
                } catch (failure: IOException) {
                    codeFor(failure)
                }
                post(handlerId, Json.write(listOf(code)), true)
            }
        }
    }

    /**
     * Join or leave a multicast group. Returns an error code, or the empty string for success —
     * the iOS block's rule, which cost a boundary once: in the socket layer `nil` means SUCCESS,
     * and coalescing it to "EBADF" reported every successful join as a failure.
     */
    fun multicastMembership(id: Int, group: String, interfaceName: String, join: Boolean): String {
        val answer = ArrayList<String>(1)
        val done = java.util.concurrent.CountDownLatch(1)
        submit {
            try {
                val entry = entries[id]
                val channel = entry?.channel as? DatagramChannel
                if (entry == null || channel == null || !entry.isDatagram) {
                    answer.add("EBADF")
                    return@submit
                }
                val address = try {
                    InetAddress.getByName(group)
                } catch (_: UnknownHostException) {
                    answer.add("EINVAL")
                    return@submit
                }
                if (!address.isMulticastAddress) {
                    answer.add("EINVAL")
                    return@submit
                }
                val nic = multicastInterface(interfaceName)
                if (nic == null) {
                    answer.add("ENODEV")
                    return@submit
                }
                if (join) {
                    if (entry.memberships.containsKey(group)) {
                        answer.add("")
                        return@submit
                    }
                    entry.memberships[group] = channel.join(address, nic)
                } else {
                    entry.memberships.remove(group)?.drop()
                }
                answer.add("")
            } catch (failure: Exception) {
                answer.add(codeFor(failure))
            } finally {
                done.countDown()
            }
        }
        // A synchronous answer, because the iOS block is synchronous and the bootstrap reads the
        // return value. The selector thread never waits on this one, so there is no cycle.
        return if (done.await(5, java.util.concurrent.TimeUnit.SECONDS)) answer.firstOrNull() ?: "EBADF"
        else "ETIMEDOUT"
    }

    /**
     * The knobs that go with a group: how far packets travel, whether the sender sees its own, and
     * which interface they leave by. `null` for a knob means "leave this one alone".
     */
    fun multicastOption(id: Int, ttl: Int?, loopback: Boolean?, interfaceName: String?) {
        submit {
            val channel = entries[id]?.channel as? DatagramChannel ?: return@submit
            try {
                if (ttl != null) channel.setOption(StandardSocketOptions.IP_MULTICAST_TTL, ttl)
                if (loopback != null) channel.setOption(StandardSocketOptions.IP_MULTICAST_LOOP, loopback)
                if (!interfaceName.isNullOrEmpty()) {
                    multicastInterface(interfaceName)?.let {
                        channel.setOption(StandardSocketOptions.IP_MULTICAST_IF, it)
                    }
                }
            } catch (_: IOException) {
            }
        }
    }

    /**
     * The interface a multicast join happens on. iOS passes `INADDR_ANY` and lets the kernel pick;
     * `java.nio` requires the interface by name or address, so "any" becomes the first one that is
     * up and does multicast.
     */
    private fun multicastInterface(name: String): NetworkInterface? {
        if (name.isNotEmpty()) {
            val byAddress = try {
                NetworkInterface.getByInetAddress(InetAddress.getByName(name))
            } catch (_: Exception) {
                null
            }
            if (byAddress != null) return byAddress
            return try {
                NetworkInterface.getByName(name)
            } catch (_: Exception) {
                null
            }
        }
        return try {
            val all = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            all.firstOrNull { it.isUp && it.supportsMulticast() && !it.isLoopback }
                ?: all.firstOrNull { it.supportsMulticast() }
        } catch (_: Exception) {
            null
        }
    }

    // ------------------------------------------------------------------- teardown ----

    /**
     * Retire the channel only when nothing is left in either direction: the peer is done
     * ([Entry.readEOF]), we are done ([Entry.writeShutdown]), the write queue drained, and every
     * byte read has been handed to JavaScript.
     */
    private fun maybeClose(entry: Entry) {
        if (!entry.readEOF || !entry.writeShutdown) return
        val queued = entry.writeLock.withLock { entry.pendingBytes }
        if (queued > 0 || entry.buffered.isNotEmpty()) return
        teardown(entry, emitClose = true)
    }

    private fun teardown(entry: Entry, emitClose: Boolean) {
        if (entry.closed) return
        entry.closed = true
        try {
            entry.key?.cancel()
        } catch (_: Exception) {
        }
        for (membership in entry.memberships.values) {
            try {
                membership.drop()
            } catch (_: Exception) {
            }
        }
        entry.memberships.clear()
        closeQuietly(entry.channel)
        entries.remove(entry.id)
        if (entry.refed) release()
        // A handler may be dropped only when the OWNER and every socket routed through it are
        // gone. An accepted socket shares its server's handler, so "this entry is its own owner"
        // is not enough: `server.close()` retires the listener while its connections are still
        // finishing, and dropping the handler there loses their remaining events — which is
        // exactly a `server.close(cb)` whose callback never fires, because the connection's own
        // 'close' never reached the JavaScript that was counting them.
        val ownerGone = entry.id == entry.ownerId || entries[entry.ownerId] == null
        val lastOfOwner = entries.values.none { it.ownerId == entry.ownerId }
        if (emitClose) emit(entry, "close", null, final = ownerGone && lastOfOwner)
    }

    /**
     * Close every handle. The host calls this when a program exits, so a forgotten server cannot
     * outlive it and hold the port — the one failure mode that survives the process on a phone.
     */
    fun closeAll() {
        for (entry in entries.values.toList()) {
            entry.closed = true
            closeQuietly(entry.channel)
        }
        entries.clear()
        running = false
        selector.wakeup()
        resolvers.shutdownNow()
        try {
            selector.close()
        } catch (_: IOException) {
        }
    }

    private fun closeQuietly(channel: SelectableChannel) {
        try {
            channel.close()
        } catch (_: IOException) {
        }
    }

    // ---------------------------------------------------------------------- events ----

    private fun emit(entry: Entry, event: String, payload: Any?, final: Boolean = false) {
        post(entry.ownerId, Json.write(listOf(entry.id, event, payload)), final)
    }

    /**
     * Content crosses as base64, exactly as it does on iOS — the bootstrap does
     * `Buffer.from(payload, 'base64')` either way, so binary survives the String hop.
     */
    private fun emitData(entry: Entry, bytes: ByteArray) {
        post(
            entry.ownerId,
            Json.write(listOf(entry.id, "data", Base64.getEncoder().encodeToString(bytes))),
            false,
        )
    }

    private fun errorPayload(message: String, code: String): Map<String, Any?> =
        mapOf("message" to message, "code" to code)

    /**
     * An outcome that never became a socket. iOS emits `error` then `close` and drops the id; the
     * `close` is what lets a JavaScript Socket finish rather than wait forever, and the handler is
     * released with it.
     */
    private fun fail(id: Int, message: String, code: String) {
        entries.remove(id)
        release()
        post(id, Json.write(listOf(id, "error", errorPayload(message, code))), false)
        post(id, Json.write(listOf(id, "close", null)), true)
    }

    // --------------------------------------------------------------------- details ----

    private fun describe(address: java.net.SocketAddress?): Address {
        val inet = address as? InetSocketAddress ?: return Address()
        val host = inet.address
        return Address(
            address = host?.hostAddress ?: "",
            port = inet.port,
            family = if (host is Inet6Address) "IPv6" else "IPv4",
        )
    }

    /**
     * A POSIX error name for a Java exception.
     *
     * The bootstrap's `net` module branches on `error.code`, and real code branches on it after
     * that (AGENTS.md: "audit error CODES, not just error presence"), so this has to answer what
     * the iOS `errnoCode()` answers for the same failure. Java reports most of them as an
     * exception TYPE, which is more reliable than its message; the message check is the fallback
     * for the ones that share `SocketException`.
     */
    fun codeFor(failure: Throwable): String {
        when (failure) {
            is ConnectException -> {
                val text = failure.message.orEmpty().lowercase()
                return when {
                    text.contains("timed out") -> "ETIMEDOUT"
                    text.contains("network is unreachable") -> "ENETUNREACH"
                    else -> "ECONNREFUSED"
                }
            }
            is BindException -> {
                val text = failure.message.orEmpty().lowercase()
                return when {
                    text.contains("permission") -> "EACCES"
                    text.contains("cannot assign") -> "EADDRNOTAVAIL"
                    else -> "EADDRINUSE"
                }
            }
            is AlreadyBoundException -> return "EADDRINUSE"
            is NoRouteToHostException -> return "EHOSTUNREACH"
            is UnknownHostException -> return "ENOTFOUND"
            is SocketTimeoutException -> return "ETIMEDOUT"
            is PortUnreachableException -> return "ECONNREFUSED"
            is ClosedChannelException -> return "EBADF"
            is SecurityException -> return "EACCES"
        }
        val text = failure.message.orEmpty().lowercase()
        return when {
            text.contains("connection reset") -> "ECONNRESET"
            text.contains("broken pipe") -> "EPIPE"
            text.contains("connection refused") -> "ECONNREFUSED"
            text.contains("address already in use") -> "EADDRINUSE"
            text.contains("cannot assign requested address") -> "EADDRNOTAVAIL"
            text.contains("permission denied") -> "EACCES"
            text.contains("network is unreachable") -> "ENETUNREACH"
            text.contains("no route to host") -> "EHOSTUNREACH"
            text.contains("not connected") -> "ENOTCONN"
            failure is SocketException || failure is IOException -> "ECONNRESET"
            else -> "EUNKNOWN"
        }
    }

    /** How many handles this table currently owns. For the gate; nothing in the engine reads it. */
    fun openCount(): Int = entries.size
}
