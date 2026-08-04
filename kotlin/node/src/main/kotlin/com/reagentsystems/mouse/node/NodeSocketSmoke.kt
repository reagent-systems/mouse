package com.reagentsystems.mouse.node

/**
 * Milestone 3c's program: `net`, `http`, `dns` and `dgram`, end to end.
 *
 * Same discipline as [NodeSmoke] and [NodeFsSmoke] — one source, one grader, run by `:nodecheck`
 * under real `node` against a JavaScript stand-in for the host, and by `NodeCheckReceiver` on a
 * device through the real WebView. If the two gates graded different programs, an on-device
 * MISMATCH would never say whether the WebView was wrong or the corpus was.
 *
 * ## Why this one matters more than the JVM corpus around it
 *
 * `:nodecheck` grades the Kotlin socket table directly, against real `node` peers, and that is a
 * strong check — but it is a check on a desktop JVM with a full POSIX underneath it. Milestone 3b
 * shipped two bugs that a green 310-check JVM gate could not see and that failed 31 of 45 checks on
 * a phone (`Files.getFileStore` throws where an app cannot read the mount table; app-private files
 * are 0600). The socket layer has the same shape of exposure — a permission that is granted or is
 * not, an IPv6 loopback that resolves differently, an emulator whose network is a NAT — so the
 * only gate that can see it is one that runs in the app.
 *
 * ## Everything is loopback, deliberately
 *
 * Not one check here needs a network. A device gate that depended on the internet would fail for
 * reasons that have nothing to do with the code, and a flaky gate is one nobody reads. `dns.lookup`
 * is asked for a literal and for `localhost`, both of which the resolver answers without a query;
 * the `dns.resolve*` family, which does need a nameserver, is graded off-device against real node
 * in `:nodecheck` instead.
 */
object NodeSocketSmoke {

    /** The process the program is run against, on both hosts. */
    val CONFIG: NodeProcessConfig = NodeProcessConfig(
        argv = listOf("/usr/local/bin/node", "/net.js"),
        env = mapOf("MOUSE_CHECK" to "1"),
        cwd = "/",
    )

    const val ENTRY_PATH: String = "/net.js"

    private const val EXIT_CODE = 9

    val PROGRAM: String = """
        const net = require('net');
        const http = require('http');
        const dns = require('dns');
        const dgram = require('dgram');
        const out = [];
        const say = (key, value) => out.push(key + '=' + value);
        const codeOf = (fn) => { try { fn(); return 'no-throw'; } catch (e) { return e.code || e.message; } };

        // A hang is a worse bug than an error (AGENTS.md), and on a device a hang is an ANR rather
        // than a verdict. So every step is behind one watchdog: whatever has been established by
        // then is reported, and the missing keys fail by name instead of by silence.
        let finished = false;
        function finish() {
          if (finished) return;
          finished = true;
          console.log(out.join('\n'));
          process.exit($EXIT_CODE);
        }
        const watchdog = setTimeout(function(){ say('timedout', 'yes'); finish(); }, 12000);
        watchdog.unref && watchdog.unref();

        // ------------------------------------------------------------------ 1. net ----
        // A server and a client in one engine. Each socket's OWN event sequence is asserted and
        // never the order BETWEEN two sockets — node reports a server's 'connection' before the
        // connecting client's 'connect' and this engine may report either order, because a
        // loopback handshake can complete inside connect(). That is a recorded divergence on iOS
        // and it is not a contract node states either.
        const serverEvents = [];
        const clientEvents = [];
        let echoed = '';

        const server = net.createServer(function (socket) {
          serverEvents.push('connection');
          socket.on('data', function (chunk) {
            serverEvents.push('data');
            socket.write('echo:' + chunk.toString());
          });
          // The peer's FIN. Half-close is real: this side is still writable here, and node's
          // allowHalfOpen=false default is what ends it.
          socket.on('end', function () { serverEvents.push('end'); socket.end(); });
        });

        server.listen(0, '127.0.0.1', function () {
          const address = server.address();
          say('listening', typeof address.port === 'number' && address.port > 0);
          say('family', address.family);

          const client = net.connect(address.port, '127.0.0.1');
          client.on('connect', function () {
            clientEvents.push('connect');
            say('remoteport', client.remotePort === address.port);
            client.write('ping');
          });
          client.on('data', function (chunk) {
            clientEvents.push('data');
            echoed += chunk.toString();
            client.end();
          });
          client.on('end', function () { clientEvents.push('end'); });
          client.on('close', function () {
            clientEvents.push('close');
            say('echo', echoed);
            say('clientevents', clientEvents.join(','));
            say('bytes', client.bytesRead + ',' + client.bytesWritten);
            server.close(function () {
              say('serverevents', serverEvents.join(','));
              refused();
            });
          });
        });

        // ------------------------------------------------------- 2. a refused connect ----
        // Port 1 needs root to bind, so nothing can be listening there. An error a caller can act
        // on, followed by 'close' — a socket that errored and never closed is a hang.
        function refused() {
          const doomed = net.connect(1, '127.0.0.1');
          let code = 'none';
          doomed.on('error', function (e) { code = e.code; });
          doomed.on('close', function () {
            say('refused', code);
            serve();
          });
        }

        // ----------------------------------------------------------------- 3. http ----
        // The whole point of the milestone: an http server inside the engine, answering a real
        // request. Both ends are ours here; the WIRE is graded against real node off-device.
        function serve() {
          const app = http.createServer(function (request, response) {
            let body = '';
            request.on('data', function (chunk) { body += chunk; });
            request.on('end', function () {
              response.writeHead(201, { 'Content-Type': 'text/plain', 'X-Made': 'thing' });
              response.end('got:' + request.method + ':' + request.url + ':' + body);
            });
          });
          app.listen(0, '127.0.0.1', function () {
            const port = app.address().port;
            const request = http.request(
              { host: '127.0.0.1', port: port, path: '/thing', method: 'POST' },
              function (response) {
                let body = '';
                response.on('data', function (chunk) { body += chunk; });
                response.on('end', function () {
                  say('status', response.statusCode);
                  say('header', response.headers['x-made']);
                  say('body', body);
                  app.close(function () { lookup(); });
                });
              });
            request.end('payload');
          });
        }

        // ------------------------------------------------------------------ 4. dns ----
        // Literals and `localhost` only — see the note on why nothing here needs a network.
        function lookup() {
          dns.lookup('127.0.0.1', function (error, address, family) {
            say('literal', (error ? 'err:' + error.code : address + '/' + family));
            dns.lookup('localhost', function (error2, address2) {
              // An IPv6-only loopback is a legitimate answer on some images, so both are accepted
              // and the check is that a NAME resolved at all.
              say('localhost', error2 ? 'err:' + error2.code : (address2 === '127.0.0.1' || address2 === '::1'));
              datagram();
            });
          });
        }

        // ---------------------------------------------------------------- 5. dgram ----
        function datagram() {
          const socket = dgram.createSocket('udp4');
          socket.on('message', function (message, from) {
            say('datagram', message.toString() + '/' + (from.port > 0));
            socket.close();
            refusals();
          });
          socket.bind(0, '127.0.0.1', function () {
            const port = socket.address().port;
            socket.send(Buffer.from('udp-hello'), port, '127.0.0.1');
          });
        }

        // ------------------------------------------------------------- 6. refusals ----
        // The surfaces that stayed deferred, probed through the API a program would actually use
        // rather than through the bridge — a refusal is only worth something if the thing above it
        // agrees. Both directions are already probed name-by-name in NodeFsSmoke.
        function refusals() {
          say('unixsock', codeOf(function () { net.connect({ path: '/tmp/mouse-nothing.sock' }); }));
          say('websocket', codeOf(function () { new globalThis.WebSocket('ws://127.0.0.1:1'); }));
          finish();
        }
    """.trimIndent()

    private val EXPECTED: List<Triple<String, String, String>> = listOf(
        Triple("listening", "true", "listen(0) binds an ephemeral port and reports it"),
        Triple("family", "IPv4", "server.address() carries the address family"),
        Triple("remoteport", "true", "a connected socket knows its peer's port"),
        Triple("echo", "echo:ping", "bytes round-trip through the kernel in both directions"),
        Triple(
            "clientevents", "connect,data,end,close",
            "a socket's own event sequence: connect, data, the peer's FIN, then close",
        ),
        Triple("bytes", "9,4", "bytesRead and bytesWritten count the real bytes"),
        Triple(
            "serverevents", "connection,data,end",
            "the server saw its accepted socket's events, routed by id",
        ),
        Triple("refused", "ECONNREFUSED", "a refused connect reports the code and then closes"),
        Triple("status", "201", "an http server inside the engine answers its own client"),
        Triple("header", "thing", "response headers survive the wire"),
        Triple("body", "got:POST:/thing:payload", "method, path and a request body all arrive"),
        Triple("literal", "127.0.0.1/4", "dns.lookup answers an IP literal without a query"),
        Triple("localhost", "true", "dns.lookup resolves a hosts-file name"),
        Triple("datagram", "udp-hello/true", "a UDP packet round-trips with its sender's port"),
        Triple(
            "unixsock", "ERR_MOUSE_NO_HOST_BINDING",
            "a unix-domain socket refuses by name — AF_UNIX is API 34 against minSdk 26",
        ),
        Triple(
            "websocket", "ERR_MOUSE_NO_HOST_BINDING",
            "the WebSocket global refuses by name — no platform WebSocket client to ride",
        ),
    )

    /** How many checks [grade] performs. Reported in the verdict line. */
    val CHECK_COUNT: Int = EXPECTED.size + 2

    /** Grade a run. Returns one line per failing check; empty means MATCH. */
    fun grade(stdout: String, stderr: String, exitCode: Int): List<String> {
        val failures = ArrayList<String>()
        val values = stdout.lineSequence().filter { it.contains('=') }
            .associate { it.substringBefore('=') to it.substringAfter('=') }
        for ((key, want, label) in EXPECTED) {
            val got = values[key]
            if (got != want) failures.add("$label — $key was ${got ?: "<absent>"}, expected $want")
        }
        // The watchdog fired. Everything after the step that stalled is missing above, so this
        // line says WHICH failure mode it was rather than leaving a dozen absent keys to read.
        if (values.containsKey("timedout")) {
            failures.add("every step completed — the watchdog fired, so one of them never called back")
        }
        if (exitCode != EXIT_CODE) {
            failures.add(
                "the program ran to its end — exit was $exitCode, expected $EXIT_CODE" +
                    if (stderr.isBlank()) "" else " (stderr: ${stderr.take(400)})",
            )
        }
        return failures
    }
}
