package com.reagentsystems.mouse.node

import com.reagentsystems.mouse.packages.Json
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.Executors

/**
 * DNS record lookups for the Android Node layer — the `dns.resolve*` family, and the Kotlin half of
 * `swift/Mouse/NodeDNS.swift`.
 *
 * ## Why this exists at all, and why it is not `InetAddress`
 *
 * `dns.lookup` has always been the easy one: it is `getaddrinfo`, which is
 * `InetAddress.getAllByName`, and it lives in [NodeSockets.resolve]. The RESOLVERS are a different
 * thing — node asks a DNS SERVER for a specific record type through c-ares — and no Java API
 * reaches them. `javax.naming.directory` with the JDK's DNS context factory would, on a desktop
 * JVM; Android ships no JNDI at all, so a resolver built on it would gate green off-device and be
 * absent on a phone. That is the exact failure shape milestone 3b paid for twice.
 *
 * So the query is built and parsed here, over a plain UDP socket, with TCP fallback when the
 * server truncates. The wire format is the load-bearing part and it is shared with iOS by
 * REASONING rather than by code: iOS gets `res_9_query` and `res_9_dn_expand` from libresolv and
 * only parses the answer section; this parses the same answer section and additionally has to
 * write the question and expand the names itself, because a JVM has neither function.
 *
 * ## Where the nameservers come from
 *
 * AGENTS.md: "Only the host knows what the host knows." A resolver address is precisely that. On a
 * desktop JVM `/etc/resolv.conf` is readable and is what every tool on the machine uses; on Android
 * it does not exist, and the answer lives behind `ConnectivityManager.getLinkProperties(...)
 * .dnsServers`, which is framework and cannot be reached from this module. So the host SETS them
 * ([servers]) and the file is only the fallback that makes the JVM gate work. Guessing a public
 * resolver instead would be a lie about the user's network — and on a captive or split-horizon
 * network, a wrong answer with no error near it.
 *
 * ## Threading
 *
 * Every query blocks for as long as the network takes, so all of them run on a small daemon pool
 * and answer through the same one-shot callback registry the socket layer uses. Nothing here is
 * ever called on the main thread; on Android that would be a `NetworkOnMainThreadException`
 * rather than a slow answer.
 */
class NodeDns(
    /** Deliver one answer: the one-shot callback registered under `handlerId`, applied to `args`. */
    private val post: (handlerId: Int, argsJson: String, final: Boolean) -> Unit,
) {

    /**
     * The nameservers to ask, in order. The host sets this from the platform; the default is
     * whatever `/etc/resolv.conf` names, which is right on a JVM and empty on Android.
     */
    @Volatile
    var servers: List<String> = readResolvConf()

    private val pool = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "mouse.node.dns").apply { isDaemon = true }
    }

    /** node's record types, by the numbers the wire format uses. Exactly the iOS list. */
    fun typeNumber(name: String): Int? = when (name.uppercase()) {
        "A" -> 1
        "NS" -> 2
        "CNAME" -> 5
        "SOA" -> 6
        "PTR" -> 12
        "MX" -> 15
        "TXT" -> 16
        "AAAA" -> 28
        "SRV" -> 33
        "NAPTR" -> 35
        "TLSA" -> 52
        "CAA" -> 257
        else -> null
    }

    // ---------------------------------------------------------------------- resolve ----

    /**
     * One query, off the calling thread. The answer is `[records, code]` — an empty code string
     * means success, which is the shape the bootstrap's `resolver()` reads.
     */
    fun resolve(handlerId: Int, name: String, type: String) {
        val number = typeNumber(type)
        if (number == null) {
            post(handlerId, Json.write(listOf(emptyList<Any?>(), "ENOTIMP")), true)
            return
        }
        pool.execute {
            val answer = query(name, number)
            if (answer.code != null) {
                post(handlerId, Json.write(listOf(emptyList<Any?>(), answer.code)), true)
                return@execute
            }
            val records = parse(answer.message!!, number)
            post(
                handlerId,
                Json.write(listOf(records, if (records.isEmpty()) "ENODATA" else "")),
                true,
            )
        }
    }

    /**
     * `dns.reverse`: a PTR lookup by address. iOS asks `getnameinfo`, which does the in-addr.arpa
     * dance itself; here the name is built and the same query path is used, so one code path
     * carries every record type and the error codes agree with the rest of the family.
     */
    fun reverse(handlerId: Int, address: String) {
        val name = reverseName(address)
        if (name == null) {
            post(handlerId, Json.write(listOf(emptyList<Any?>(), "EINVAL")), true)
            return
        }
        pool.execute {
            val answer = query(name, 12)
            if (answer.code != null) {
                post(handlerId, Json.write(listOf(emptyList<Any?>(), answer.code)), true)
                return@execute
            }
            val names = parse(answer.message!!, 12).mapNotNull { it["value"] as? String }
            post(
                handlerId,
                Json.write(listOf(names, if (names.isEmpty()) "ENOTFOUND" else "")),
                true,
            )
        }
    }

    /**
     * `dns.lookupService`: an address and port to a hostname and a SERVICE NAME.
     *
     * The hostname half is a PTR query. The service half is `getservbyport`, which the JDK does
     * not expose in any form — so it is `/etc/services` where that exists (it does on Android, in
     * bionic's copy) and the IANA well-known list otherwise. A port with no name answers its own
     * number, which is what `getnameinfo` does without `NI_NUMERICSERV`.
     */
    fun lookupService(handlerId: Int, address: String, port: Int) {
        val name = reverseName(address)
        if (name == null) {
            post(handlerId, Json.write(listOf("", "", "EINVAL")), true)
            return
        }
        pool.execute {
            val answer = query(name, 12)
            val host = if (answer.code != null) null
            else parse(answer.message!!, 12).mapNotNull { it["value"] as? String }.firstOrNull()
            if (host == null) {
                post(handlerId, Json.write(listOf("", "", "ENOTFOUND")), true)
                return@execute
            }
            post(handlerId, Json.write(listOf(host, serviceName(port), "")), true)
        }
    }

    // ------------------------------------------------------------------ the transport ----

    private class Answer(val message: ByteArray?, val code: String?)

    /**
     * Ask each nameserver in turn until one answers. UDP first, and TCP when the reply comes back
     * truncated — a TXT or a DNSKEY routinely passes 512 bytes, and a truncated answer parsed as
     * if it were whole is a wrong answer with no error near it.
     */
    private fun query(name: String, type: Int): Answer {
        val list = servers
        if (list.isEmpty()) {
            // Not "try a public resolver". A host that has not told this layer where to ask has
            // not told it, and inventing 8.8.8.8 would send the user's lookups somewhere they did
            // not choose. ESERVFAIL is what a resolver with no server says.
            return Answer(null, "ESERVFAIL")
        }
        val question = buildQuery(name, type)
        var last = "ESERVFAIL"
        for (server in list) {
            val target = try {
                InetAddress.getByName(server)
            } catch (_: UnknownHostException) {
                continue
            }
            val viaUdp = askUdp(target, question)
            val message = if (viaUdp != null && truncated(viaUdp)) askTcp(target, question) ?: viaUdp
            else viaUdp
            if (message == null) {
                last = "ETIMEOUT"
                continue
            }
            // RCODE lives in the low four bits of the second header byte. node reports the
            // difference between "no such name" and "no record of this type", and so must this —
            // h_errno is what the iOS side reads for the same split.
            return when (message[3].toInt() and 0x0f) {
                0 -> Answer(message, null)
                1 -> Answer(null, "EFORMERR")
                2 -> Answer(null, "ESERVFAIL")
                3 -> Answer(null, "ENOTFOUND")
                4 -> Answer(null, "ENOTIMP")
                5 -> Answer(null, "EREFUSED")
                else -> Answer(null, "ESERVFAIL")
            }
        }
        return Answer(null, last)
    }

    private fun truncated(message: ByteArray): Boolean =
        message.size > 2 && (message[2].toInt() and 0x02) != 0

    private fun askUdp(server: InetAddress, question: ByteArray): ByteArray? = try {
        DatagramSocket().use { socket ->
            socket.soTimeout = TIMEOUT_MS
            socket.send(DatagramPacket(question, question.size, server, 53))
            val buffer = ByteArray(4096)
            val reply = DatagramPacket(buffer, buffer.size)
            socket.receive(reply)
            buffer.copyOf(reply.length)
        }
    } catch (_: SocketTimeoutException) {
        null
    } catch (_: Exception) {
        null
    }

    /** DNS over TCP is the same message behind a two-byte length prefix. */
    private fun askTcp(server: InetAddress, question: ByteArray): ByteArray? = try {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(server, 53), TIMEOUT_MS)
            socket.soTimeout = TIMEOUT_MS
            val out = socket.getOutputStream()
            out.write(question.size shr 8)
            out.write(question.size and 0xff)
            out.write(question)
            out.flush()
            val input = socket.getInputStream()
            val header = ByteArray(2)
            if (readFully(input, header) != 2) return null
            val length = (header[0].toInt() and 0xff shl 8) or (header[1].toInt() and 0xff)
            val body = ByteArray(length)
            if (readFully(input, body) != length) null else body
        }
    } catch (_: Exception) {
        null
    }

    private fun readFully(input: java.io.InputStream, into: ByteArray): Int {
        var at = 0
        while (at < into.size) {
            val read = input.read(into, at, into.size - at)
            if (read < 0) break
            at += read
        }
        return at
    }

    // ----------------------------------------------------------------- the wire format ----

    /** A standard recursive query for one name and type. */
    private fun buildQuery(name: String, type: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val id = (System.nanoTime() and 0xffff).toInt()
        out.write(id shr 8); out.write(id and 0xff)
        out.write(0x01); out.write(0x00) // RD — ask the server to recurse, as res_query does
        out.write(0x00); out.write(0x01) // one question
        out.write(0x00); out.write(0x00) // no answers
        out.write(0x00); out.write(0x00) // no authority
        out.write(0x00); out.write(0x00) // no additional
        for (label in name.trim('.').split(".")) {
            if (label.isEmpty()) continue
            val bytes = label.toByteArray(Charsets.UTF_8)
            out.write(bytes.size.coerceAtMost(63))
            out.write(bytes, 0, bytes.size.coerceAtMost(63))
        }
        out.write(0x00)
        out.write(type shr 8); out.write(type and 0xff)
        out.write(0x00); out.write(0x01) // IN
        return out.toByteArray()
    }

    /**
     * Expand a name at [at], following compression pointers. This is `res_9_dn_expand`, which the
     * iOS side gets from libresolv — a plain byte scan cannot read a DNS name, because any label
     * may be a two-byte pointer back into the message.
     *
     * Returns the name and the offset just past it IN THE ORIGINAL RUN (a pointer does not advance
     * the cursor past its two bytes). The jump budget is what stops a malicious or corrupt message
     * pointing at itself forever.
     */
    private fun expand(message: ByteArray, at: Int): Pair<String, Int>? {
        val labels = ArrayList<String>()
        var cursor = at
        var after = -1
        var jumps = 0
        while (true) {
            if (cursor < 0 || cursor >= message.size) return null
            val length = message[cursor].toInt() and 0xff
            if (length == 0) {
                if (after < 0) after = cursor + 1
                return labels.joinToString(".") to after
            }
            if (length and 0xc0 == 0xc0) {
                if (cursor + 1 >= message.size) return null
                if (++jumps > 64) return null
                val target = ((length and 0x3f) shl 8) or (message[cursor + 1].toInt() and 0xff)
                if (after < 0) after = cursor + 2
                cursor = target
                continue
            }
            if (cursor + 1 + length > message.size) return null
            labels.add(String(message, cursor + 1, length, Charsets.UTF_8))
            cursor += 1 + length
        }
    }

    private fun short(message: ByteArray, at: Int): Int {
        if (at + 1 >= message.size) return 0
        return ((message[at].toInt() and 0xff) shl 8) or (message[at + 1].toInt() and 0xff)
    }

    private fun long(message: ByteArray, at: Int): Long {
        if (at + 3 >= message.size) return 0
        return ((message[at].toLong() and 0xff) shl 24) or ((message[at + 1].toLong() and 0xff) shl 16) or
            ((message[at + 2].toLong() and 0xff) shl 8) or (message[at + 3].toLong() and 0xff)
    }

    /**
     * Walk the header, skip the questions, then read the answers of the type asked for. Records of
     * other types in the same answer — a CNAME chain, typically — are skipped rather than reported,
     * which is what node does.
     */
    fun parse(message: ByteArray, wanted: Int): List<Map<String, Any?>> {
        if (message.size <= 12) return emptyList()
        val questions = short(message, 4)
        val answers = short(message, 6)
        var cursor = 12
        repeat(questions) {
            val (_, next) = expand(message, cursor) ?: return emptyList()
            cursor = next + 4 // QTYPE + QCLASS
        }
        val out = ArrayList<Map<String, Any?>>()
        repeat(answers) {
            val (_, afterName) = expand(message, cursor) ?: return out
            var at = afterName
            val type = short(message, at)
            val ttl = long(message, at + 4)
            val dataLength = short(message, at + 8)
            at += 10
            if (type == wanted) record(message, at, dataLength, type, ttl)?.let { out.add(it) }
            cursor = at + dataLength
        }
        return out
    }

    /**
     * One record, in node's exact return shape for its type. The shapes differ per type more than
     * the docs suggest — TXT keeps its chunks SEPARATE, SOA is one object rather than a list, and
     * CAA names its property after the tag — so each is spelled out.
     */
    private fun record(message: ByteArray, start: Int, length: Int, type: Int, ttl: Long): Map<String, Any?>? {
        when (type) {
            1 -> { // A
                if (length != 4) return null
                val text = (0 until 4).joinToString(".") { (message[start + it].toInt() and 0xff).toString() }
                return mapOf("value" to text, "ttl" to ttl)
            }
            28 -> { // AAAA
                if (length != 16) return null
                val bytes = message.copyOfRange(start, start + 16)
                val text = try {
                    (InetAddress.getByAddress(bytes) as Inet6Address).hostAddress?.substringBefore('%')
                } catch (_: Exception) {
                    null
                } ?: return null
                return mapOf("value" to text, "ttl" to ttl)
            }
            2, 5, 12 -> { // NS, CNAME, PTR — a single name
                val (text, _) = expand(message, start) ?: return null
                return mapOf("value" to text, "ttl" to ttl)
            }
            15 -> { // MX
                val (exchange, _) = expand(message, start + 2) ?: return null
                return mapOf("priority" to short(message, start), "exchange" to exchange, "ttl" to ttl)
            }
            16 -> { // TXT — length-prefixed chunks, which node keeps SEPARATE
                val chunks = ArrayList<String>()
                var at = start
                while (at < start + length && at < message.size) {
                    val size = message[at].toInt() and 0xff
                    at += 1
                    if (at + size > message.size) break
                    chunks.add(String(message, at, size, Charsets.UTF_8))
                    at += size
                }
                return mapOf("chunks" to chunks, "ttl" to ttl)
            }
            6 -> { // SOA
                val (nsname, afterNs) = expand(message, start) ?: return null
                val (hostmaster, afterHm) = expand(message, afterNs) ?: return null
                return mapOf(
                    "nsname" to nsname, "hostmaster" to hostmaster,
                    "serial" to long(message, afterHm),
                    "refresh" to long(message, afterHm + 4),
                    "retry" to long(message, afterHm + 8),
                    "expire" to long(message, afterHm + 12),
                    "minttl" to long(message, afterHm + 16), "ttl" to ttl,
                )
            }
            33 -> { // SRV
                val (target, _) = expand(message, start + 6) ?: return null
                return mapOf(
                    "priority" to short(message, start), "weight" to short(message, start + 2),
                    "port" to short(message, start + 4), "name" to target, "ttl" to ttl,
                )
            }
            35 -> { // NAPTR
                var at = start + 4
                val strings = ArrayList<String>(3)
                repeat(3) {
                    if (at >= message.size) return null
                    val size = message[at].toInt() and 0xff
                    at += 1
                    if (at + size > message.size) return null
                    strings.add(String(message, at, size, Charsets.UTF_8))
                    at += size
                }
                val (replacement, _) = expand(message, at) ?: return null
                if (strings.size != 3) return null
                return mapOf(
                    "order" to short(message, start), "preference" to short(message, start + 2),
                    "flags" to strings[0], "service" to strings[1], "regexp" to strings[2],
                    "replacement" to replacement, "ttl" to ttl,
                )
            }
            257 -> { // CAA — a flags byte, a length-prefixed tag, then the value to the end
                if (length < 2) return null
                val critical = message[start].toInt() and 0xff
                val tagLength = message[start + 1].toInt() and 0xff
                val tagStart = start + 2
                if (tagStart + tagLength > message.size) return null
                val tag = String(message, tagStart, tagLength, Charsets.UTF_8)
                val valueStart = tagStart + tagLength
                val valueEnd = start + length
                if (valueEnd > message.size || valueStart > valueEnd) return null
                return mapOf(
                    "critical" to critical, "tag" to tag,
                    "value" to String(message, valueStart, valueEnd - valueStart, Charsets.UTF_8),
                    "ttl" to ttl,
                )
            }
            52 -> { // TLSA — usage, selector, matching type, then the association data
                if (length < 4) return null
                val dataStart = start + 3
                val dataEnd = start + length
                if (dataEnd > message.size || dataStart > dataEnd) return null
                return mapOf(
                    "certUsage" to (message[start].toInt() and 0xff),
                    "selector" to (message[start + 1].toInt() and 0xff),
                    "match" to (message[start + 2].toInt() and 0xff),
                    "data" to (dataStart until dataEnd).map { message[it].toInt() and 0xff },
                    "ttl" to ttl,
                )
            }
            else -> return null
        }
    }

    // ----------------------------------------------------------------------- details ----

    /** `1.2.3.4` → `4.3.2.1.in-addr.arpa`, and the IPv6 nibble form. */
    fun reverseName(address: String): String? {
        val parsed = try {
            when {
                address.contains(':') -> InetAddress.getByName(address) as? Inet6Address
                else -> {
                    // Only a literal. A hostname here would silently become a lookup of the
                    // wrong thing, and node reports EINVAL for one.
                    val parts = address.split(".").map { it.toIntOrNull() }
                    if (parts.size != 4 || parts.any { it == null || it < 0 || it > 255 }) return null
                    InetAddress.getByAddress(ByteArray(4) { parts[it]!!.toByte() }) as? Inet4Address
                }
            }
        } catch (_: Exception) {
            null
        } ?: return null

        val bytes = parsed.address
        return if (parsed is Inet6Address) {
            bytes.reversed().joinToString(".") {
                val value = it.toInt() and 0xff
                "%x.%x".format(value and 0x0f, value shr 4)
            } + ".ip6.arpa"
        } else {
            bytes.reversed().joinToString(".") { (it.toInt() and 0xff).toString() } + ".in-addr.arpa"
        }
    }

    /** The name `getservbyport` would answer, from /etc/services or the well-known list. */
    fun serviceName(port: Int): String {
        etcServices[port]?.let { return it }
        return WELL_KNOWN[port] ?: port.toString()
    }

    private val etcServices: Map<Int, String> by lazy {
        val out = HashMap<Int, String>()
        val file = File("/etc/services")
        if (!file.canRead()) return@lazy out
        try {
            file.forEachLine { line ->
                val body = line.substringBefore('#').trim()
                if (body.isEmpty()) return@forEachLine
                val fields = body.split(Regex("\\s+"))
                if (fields.size < 2) return@forEachLine
                val portText = fields[1].substringBefore('/')
                val protocol = fields[1].substringAfter('/', "")
                if (protocol != "tcp") return@forEachLine
                val port = portText.toIntOrNull() ?: return@forEachLine
                out.putIfAbsent(port, fields[0])
            }
        } catch (_: Exception) {
        }
        out
    }

    private companion object {
        const val TIMEOUT_MS = 5_000

        /**
         * `/etc/services` is present on Android but has been trimmed on some images, so the ports
         * a program is actually likely to ask about are listed here as well. Anything else answers
         * its own number rather than a guess.
         */
        val WELL_KNOWN = mapOf(
            20 to "ftp-data", 21 to "ftp", 22 to "ssh", 23 to "telnet", 25 to "smtp",
            53 to "domain", 67 to "bootps", 68 to "bootpc", 69 to "tftp", 80 to "http",
            110 to "pop3", 119 to "nntp", 123 to "ntp", 143 to "imap", 161 to "snmp",
            194 to "irc", 389 to "ldap", 443 to "https", 445 to "microsoft-ds", 465 to "submissions",
            514 to "shell", 587 to "submission", 636 to "ldaps", 993 to "imaps", 995 to "pop3s",
            1080 to "socks", 3306 to "mysql", 5432 to "postgresql", 5900 to "rfb",
            6379 to "redis", 8080 to "http-alt", 8443 to "https-alt",
        )

        /**
         * The desktop fallback. Android has no `/etc/resolv.conf` — the host supplies the servers
         * there — but a JVM harness has one, and reading it is what lets the gate ask the same
         * resolver every other tool on the machine asks.
         */
        fun readResolvConf(): List<String> {
            val file = File("/etc/resolv.conf")
            if (!file.canRead()) return emptyList()
            return try {
                file.readLines().mapNotNull { line ->
                    val body = line.substringBefore('#').trim()
                    if (!body.startsWith("nameserver")) return@mapNotNull null
                    body.removePrefix("nameserver").trim().takeIf { it.isNotEmpty() }
                }
            } catch (_: Exception) {
                emptyList()
            }
        }
    }

    /** Release the pool. Nothing outlives a program's engine. */
    fun close() {
        pool.shutdownNow()
    }
}

