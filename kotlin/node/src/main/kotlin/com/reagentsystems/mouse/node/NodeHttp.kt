package com.reagentsystems.mouse.node

import com.reagentsystems.mouse.packages.Json
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Base64
import java.util.concurrent.Executors

/**
 * The TLS-capable HTTP transport — `bridge.httpRequest` and `bridge.httpStream`, which is what
 * `fetch`, `https.request` and the `https` module ride.
 *
 * ## Why this is a second transport at all
 *
 * The split is deliberate and it is iOS's: plaintext `http.request` rides `net` (so bodies arrive
 * incrementally, request bodies can stream, and a 101 hands the socket over — the WebSocket path),
 * while `https.request` stays on the system's own HTTP client, because TLS is a handshake we
 * cannot put on a raw socket. On iOS that client is URLSession; here it is
 * `HttpURLConnection`/`HttpsURLConnection`, which is the same bargain — the platform owns the
 * handshake, the certificate chain and the trust store, and this file owns only delivery.
 *
 * Nothing about that changes when the socket layer lands. A raw `SocketChannel` can carry HTTP; it
 * cannot carry TLS without a TLS implementation, and writing one would be a far larger and far
 * worse idea than using the one the OS already ships.
 *
 * ## Streaming is the point, and it is verified by TIMING, not by content
 *
 * AGENTS.md records why the URLSession path hid a bug here for so long: a fixture that compares
 * only the concatenated body passes just as happily against a transport that buffers everything.
 * So the head is reported the moment the status line and headers are in, and every chunk goes out
 * as it is read — `fetch` settles when the HEAD arrives, not when the body finishes.
 *
 * ## Threading
 *
 * Every request runs on a daemon pool. `HttpURLConnection.getResponseCode()` performs the whole
 * connect-and-read-headers dance synchronously, so calling it anywhere near the main looper is a
 * `NetworkOnMainThreadException` — this is the file where that trap is closest.
 */
class NodeHttp(
    /** Deliver one event to the callback registered under `handlerId`, applied to `args`. */
    private val post: (handlerId: Int, argsJson: String, final: Boolean) -> Unit,
    private val retain: () -> Unit,
    private val release: () -> Unit,
) {

    private val pool = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "mouse.node.http").apply { isDaemon = true }
    }

    /**
     * One request, delivered whole. `bridge.httpRequest`'s callback takes ONE object: `{error}` or
     * `{status, headers, body}` with the body base64-encoded.
     */
    fun request(handlerId: Int, urlText: String, method: String, headersJson: String, bodyBase64: String) {
        retain()
        pool.execute {
            try {
                val body = java.io.ByteArrayOutputStream()
                val head = perform(
                    urlText, method, headersJson, bodyBase64,
                    onHead = {},
                    onChunk = { chunk, length -> body.write(chunk, 0, length) },
                )
                post(
                    handlerId,
                    Json.write(
                        listOf(
                            mapOf(
                                "status" to head.status,
                                "headers" to head.headers,
                                "body" to Base64.getEncoder().encodeToString(body.toByteArray()),
                            ),
                        ),
                    ),
                    true,
                )
            } catch (failure: Exception) {
                post(handlerId, Json.write(listOf(mapOf("error" to describe(failure)))), true)
            } finally {
                release()
            }
        }
    }

    /**
     * The same transport, delivered INCREMENTALLY. The callback takes `(event, payload)`:
     * `head` with `{status, headers}`, then `data` with a base64 chunk per read, then `end`; an
     * `error` before the head fails the fetch, and after it fails the stream.
     */
    fun stream(handlerId: Int, urlText: String, method: String, headersJson: String, bodyBase64: String) {
        retain()
        pool.execute {
            try {
                perform(
                    urlText, method, headersJson, bodyBase64,
                    onHead = { head ->
                        post(
                            handlerId,
                            Json.write(
                                listOf("head", mapOf("status" to head.status, "headers" to head.headers)),
                            ),
                            false,
                        )
                    },
                    onChunk = { chunk, length ->
                        post(
                            handlerId,
                            Json.write(
                                listOf("data", Base64.getEncoder().encodeToString(chunk.copyOf(length))),
                            ),
                            false,
                        )
                    },
                )
                post(handlerId, Json.write(listOf("end", null)), true)
            } catch (failure: Exception) {
                post(handlerId, Json.write(listOf("error", describe(failure))), true)
            } finally {
                release()
            }
        }
    }

    // -------------------------------------------------------------------------- detail ----

    private class Head(val status: Int, val headers: Map<String, String>)

    /**
     * Connect, report the head, then read the body a chunk at a time.
     *
     * Redirects are followed here rather than left to `HttpURLConnection`, because its own
     * follower stops at a PROTOCOL change — an `http://` that redirects to `https://` silently
     * returns the 301 instead of the resource, which reads as a broken server rather than a client
     * that gave up. `fetch` follows twenty; so does this.
     */
    private fun perform(
        urlText: String,
        method: String,
        headersJson: String,
        bodyBase64: String,
        onHead: (Head) -> Unit,
        onChunk: (ByteArray, Int) -> Unit,
    ): Head {
        var url = try {
            URL(urlText)
        } catch (_: Exception) {
            throw IOException("invalid URL: $urlText")
        }
        val headers = parseHeaders(headersJson)
        val body = if (bodyBase64.isEmpty()) null else Base64.getDecoder().decode(bodyBase64)

        var hops = 0
        while (true) {
            val connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = method.uppercase().ifEmpty { "GET" }
                // Followed by hand — see the note above.
                instanceFollowRedirects = false
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
                for ((name, value) in headers) setRequestProperty(name, value)
                if (body != null) {
                    doOutput = true
                    setFixedLengthStreamingMode(body.size)
                }
            }
            if (body != null) {
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            if (status in 300..399 && hops < MAX_REDIRECTS) {
                val location = connection.getHeaderField("Location")
                if (!location.isNullOrEmpty()) {
                    connection.disconnect()
                    url = try {
                        URL(url, location)
                    } catch (_: Exception) {
                        throw IOException("invalid redirect target: $location")
                    }
                    hops += 1
                    continue
                }
            }
            val head = Head(status, headerMap(connection))
            // The head goes out BEFORE the body is read, which is the whole of what makes this a
            // stream: `fetch` settles when the head arrives, not when the body finishes.
            onHead(head)
            // A 4xx or 5xx body arrives on the ERROR stream, and it is still a body: node's fetch
            // resolves a 404 with its content rather than failing.
            val input: InputStream? = try {
                connection.inputStream
            } catch (_: IOException) {
                connection.errorStream
            }
            if (input != null) {
                input.use { stream ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = stream.read(buffer)
                        if (read < 0) break
                        if (read > 0) onChunk(buffer, read)
                    }
                }
            }
            connection.disconnect()
            return head
        }
    }

    private fun parseHeaders(json: String): Map<String, String> {
        if (json.isBlank()) return emptyMap()
        val parsed = Json.parse(json) as? Map<*, *> ?: return emptyMap()
        val out = LinkedHashMap<String, String>()
        for ((key, value) in parsed) out[key.toString()] = value?.toString() ?: ""
        return out
    }

    /**
     * Header names LOWERCASED, which is what node reports and what the iOS block does. A repeated
     * header joins with ", ", as every HTTP client does — the exception real code depends on is
     * `set-cookie`, which node keeps as a list; that is a shared-bootstrap concern rather than a
     * transport one, and neither platform splits it here.
     */
    private fun headerMap(connection: HttpURLConnection): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for ((name, values) in connection.headerFields) {
            // The status line arrives under a null key.
            if (name == null) continue
            out[name.lowercase()] = values.joinToString(", ")
        }
        return out
    }

    private fun describe(failure: Throwable): String =
        failure.message?.takeIf { it.isNotBlank() } ?: failure.javaClass.simpleName

    /** Release the pool. Nothing outlives a program's engine. */
    fun close() {
        pool.shutdownNow()
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 30_000
        const val READ_TIMEOUT_MS = 120_000

        /** `fetch`'s own limit. Twenty hops is a redirect loop by any reading. */
        const val MAX_REDIRECTS = 20
    }
}
