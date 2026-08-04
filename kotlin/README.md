# Mouse for Android

The native Android app, in Kotlin + Jetpack Compose. Same product, same
design language ([DESIGN.md](../DESIGN.md)), same interaction spec as the
Swift app ([swift/README.md](../swift/README.md)) — built natively for its
platform, per the no-cross-platform-frameworks rule.

## Building

Requirements: **JDK 21** and the **Android SDK** (Android Studio installs both).

Android Studio: open this `kotlin/` folder. CLI:

```sh
cd kotlin
./gradlew assembleDebug
```

On macOS, if Gradle can't find the SDK:

```sh
ANDROID_HOME=~/Library/Android/sdk ./gradlew assembleDebug
```

Toolchain: Gradle 8.14, AGP 8.10, Kotlin 2.0, Compose (BOM 2024.09),
minSdk 26 / target 35. Zero third-party libraries beyond the platform +
Compose + coroutines — even tar/gzip (`GZIPInputStream` + a hand-written tar
reader), HTTP (`HttpURLConnection`) and checksums (`MessageDigest`) are the
SDK's own. JSON is `org.json` inside `:app`, and a hand-written reader/writer
in `:packages`: `org.json` ships in the Android framework but not the JDK, so
a pure-JVM module that used it would need a third-party artifact and would
stop building off-device.

## Modules

| Module | What it is |
|---|---|
| `:app` | The Android app — Compose, the carousel, workspaces, git, GitHub, `msh` |
| `:terminal` | The terminal screen engine: grid, ANSI parser, Unicode width table, key encoding. Pure Kotlin/JVM — no Compose, no `android.*`, kotlin-stdlib only |
| `:screencheck` | The headless gate for `:terminal` |
| `:packages` | The package manager: semver, the npm registry client, the hoisting tree resolver, integrity-checked installs, the `node_modules` manifest, and `TarGz`. Pure Kotlin/JVM, JDK-only |
| `:pkgcheck` | The headless gate for `:packages` |
| `:node` | The Node layer's portable half: the bootstrap's extraction from the iOS source, the `__mouse` bridge protocol, the process globals, the event loop's bookkeeping, the workspace-virtual filesystem (`NodeFs`), node's module-resolution algorithm (`ModuleResolver`), the Java NIO socket table (`NodeSockets`), the DNS wire client (`NodeDns`) and the TLS-capable HTTP transport (`NodeHttp`). Pure Kotlin/JVM |
| `:nodecheck` | The headless gate for `:node` — including the bootstrap-drift check |

`:terminal`, `:packages` and `:node` are modules rather than files in `:app` for
the reason phase T learned on iOS: logic that shares a file with UI is logic no
harness can reach. They run on a JVM, so the screen, the whole npm install path
and everything about the Node layer except the WebView are gated without an
emulator.

## Verifying the terminal screen

```sh
cd kotlin
ANDROID_HOME=~/Library/Android/sdk ./gradlew :screencheck:run
```

The corpus is the iOS one ported assertion for assertion (`verify/main.swift`,
`verify/altscreen`, `verify/widechars`, `verify/widetui`, `verify/tty`),
reading the same checked-in fixtures — `verify/widechars/widths.txt` and the
captured claude-code frame `verify/tty/cc-frame.bin` with pyte's rendering of
it. Two platforms gated by different corpora is a parity claim nobody can
falsify. There is no JUnit (zero third-party dependencies): the harness is a
`main()` printing one verdict line ending in MATCH or MISMATCH, exiting
non-zero on mismatch, like the Swift harnesses in `verify/`.

## Verifying the package manager

```sh
cd kotlin
ANDROID_HOME=~/Library/Android/sdk ./gradlew :pkgcheck:run
```

Same shape, same rule, and the corpus is the iOS one again (`verify/pkg`,
`verify/npmalias`, the resolution half of `verify/napiwasi`). It talks to the
real npm registry, grades resolution against a real `pnpm install
--lockfile-only`, and proves the installed layout by running real `node` in
the tree and requiring out of it — a mocked registry grades the mock. Needs
`pnpm` and `node` on the machine. Tarballs are immutable and integrity-checked,
so they cache under `~/.cache/mouse-verify/npm-tarballs`; packuments are
deliberately fetched every time, because a cached one loses a publish race
against the live pnpm it is compared with.

## Verifying the Node layer

```sh
cd kotlin
ANDROID_HOME=~/Library/Android/sdk ./gradlew :nodecheck:run
```

Same shape, one verdict line. The load-bearing check is **drift**. The engine's
JavaScript half — 13,993 lines, the portable 72 % measured in
`plans/android-parity.md` — is not rewritten for Android: it is copied verbatim
out of the Swift raw-string literal in `swift/Mouse/NodeEngine.swift` into
`app/src/main/assets/node-bootstrap.js`. A copy that diverges silently is worse
than no copy, because it *looks* like the gated engine, so the copy is never
trusted: the harness re-extracts it from the shipping Swift file on every run
and diffs. Same trick as `:screencheck` reading `verify/` fixtures instead of
copying them.

The transform is explicit and part of the comparison — Swift's own
multiline-literal indentation stripping, and a hard failure on any `\#`
raw-string escape, since one would mean the copy is not verbatim. `--sync`
rewrites the asset using the *same* code that grades it:

```sh
./gradlew :nodecheck:run --args=--sync
```

Also gated there: the bridge partition (every `bridge.<name>` the shipping
bootstrap calls is either implemented by the Android host or explicitly
deferred, exactly once — so an iOS-side addition turns up as a red gate rather
than as `undefined is not a function` inside 14,000 lines), the reason attached
to each deferred name, the process globals the bootstrap reads while it loads,
the event loop's bookkeeping, the `/proc/self/stat` reader behind
`process.cpuUsage()`, `node --check` on the extracted bootstrap and on
`node-host.js`, and runs of the engine under real `node` with a JavaScript
stand-in for `__mouseHost`: `NodeSmoke` (console, `process`, timers, tick
order), `NodeFsSmoke` (the filesystem and `require` over `node_modules`) and
`NodeSocketSmoke` (`net`, `http`, `dns`, `dgram`) — all three the same programs
the on-device gate runs, graded by the same graders — plus `verify/fsparity`,
`verify/neterrors` and `verify/reqsock`, read straight out of `verify/` and
graded against the same `node.txt` iOS is graded against.

The filesystem and the resolver are gated **against real `node` itself**, which
is what makes the parity claim falsifiable: `NodeFs.stat` is compared with
node's own `Stats` for the same file, and `ModuleResolver` is compared with
`require.resolve` case by case in one real tree (relative and bare specifiers,
`.` and `..`, "exports" maps with pattern keys, a subpath outside the map, a
scoped package, a dual package, the walk-up). A resolver graded against
hand-written expectations is graded against whatever its author believed node
does.

### Verifying the socket layer

`NodeSockets` is graded the same way and for the same reason, one layer down.
The JavaScript stand-in in the harness is real node's own `net`, so it proves
`node-host.js` and the bootstrap's `net`/`http` modules above it and says
nothing at all about the Kotlin underneath. So the NIO table is *also* driven
directly, against real peers on a real wire: a plain JVM socket for the
deterministic cases (accept, echo, half-close, backpressure past the 64 KB
high-water mark, pause/resume losing no bytes, ECONNREFUSED, EADDRINUSE,
ref/unref, a UDP round trip), and **real `node` for the two that matter** — a
node CLIENT against our server and our client against a node SERVER. "It works
when both ends are ours" proves nothing about the wire; that is the same rule
`verify/net` states from the other side.

`NodeDns` is graded twice over. The parse half runs against a response
assembled byte by byte in the harness **with compression pointers in it**,
because name expansion is the one piece of this layer with no reference
implementation to lean on — iOS gets `res_9_dn_expand` from libresolv and a JVM
has no equivalent, and a plain byte scan reads a compressed name as a truncated
one without ever failing. The live half asks a real nameserver for
`verify/dnsres`'s own record types and compares with real node asking for the
same thing; it skips rather than fails when there is no resolver or no network.

`NodeHttp` is graded on the ORDER of its events, not only their contents —
`head,data,data,end` for a response written in two pieces. A fixture comparing
only the concatenated body passes just as happily against a transport that
buffers everything, which is how the equivalent bug hid on the URLSession path
for so long.

The JavaScript loader in `node-host.js` and the Kotlin resolver under it are
gated separately off-device — the stand-in host resolves through node's own
resolver rather than through a second copy of ours, because grading our loader
against our own resolver would prove nothing about either. The two meet for the
first time on a device.

### On the device

The WebView cannot be reached from a JVM, so the host itself is gated on a
device or emulator. Debug builds carry an exported receiver for it:

```sh
adb shell am broadcast \
  -n com.reagentsystems.mouse/com.reagentsystems.mouse.nodehost.NodeCheckReceiver \
  -a com.reagentsystems.mouse.NODECHECK
```

`am broadcast` prints the verdict as the result data (`Broadcast completed:
result=0, data="NODE WEBVIEW: … MATCH"`). It is also in logcat, with a line per
failing check ahead of it:

```sh
adb logcat -d -s MouseNodeCheck
```

The app does not need to be running; the broadcast starts it. Because the
programs and their grading are shared with `:nodecheck`, an on-device MISMATCH
means the WebView rather than the corpus.

Three programs run in sequence, each in its own engine and its own empty
directory: `NodeSmoke`, `NodeFsSmoke`, then `NodeSocketSmoke`. The last two are
the ones no JVM harness can reach — `NodeFsSmoke` is the only place `NodeFs` and
`ModuleResolver` meet the JavaScript loader, and `NodeSocketSmoke` is the only
place the NIO socket table meets the shim, over loopback: a TCP echo with a
half-close, an `http` server answering its own client, `dns.lookup`, a UDP round
trip, and the two refusals a program would actually hit (a unix-domain socket
and the `WebSocket` global).

Nothing in it needs a network. A device gate that depended on the internet would
fail for reasons that have nothing to do with the code, and a flaky gate is one
nobody reads.

## Running on an emulator

### Android Studio (easiest)

1. Install [Android Studio](https://developer.android.com/studio).
2. **File → Open** → select this `kotlin/` folder (not the repo root).
3. **Tools → Device Manager → Create Device** — pick a phone (e.g. Pixel 9)
   and a recent system image (API 35 or similar). Start the virtual device.
4. Click **Run** (green play button). Android Studio builds, installs, and
   launches the app on the emulator.

### CLI

Build the APK (see above), then boot an emulator and install:

```sh
# macOS — add SDK tools to PATH if needed
export ANDROID_HOME=~/Library/Android/sdk
export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$PATH"

# List virtual devices, then boot one (use a name from the list)
emulator -list-avds
emulator -avd Pixel_9 &

adb wait-for-device
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.reagentsystems.mouse/.MainActivity
```

On Windows (PowerShell), set `ANDROID_HOME` to
`$env:LOCALAPPDATA\Android\Sdk` and add `\emulator` and `\platform-tools`
to `PATH` before the same `adb` / `emulator` commands.

### If something fails

| Problem | Fix |
|---|---|
| `emulator` or `adb` not found | Add `$ANDROID_HOME/emulator` and `.../platform-tools` to `PATH` |
| No AVDs listed | Create one in Android Studio → Device Manager |
| Gradle / SDK errors | Open `kotlin/` in Android Studio once; let it sync and download SDK components |
| Emulator won't start | Enable CPU virtualization in BIOS, or use a physical device with USB debugging |

## Parity

Feature parity with the iOS app, built natively in Compose:

- **The gesture shell** — ring/lane/strip, the gesture law (axis-locked drag
  detectors: horizontal drives the shell, vertical is content), edge-swipe
  ring travel, divider resize, pinch to add/remove lanes
- **Onboarding ring** — the self-teaching lesson chain (Swipe? → Drag? → …)
- **GitHub sign-in** — OAuth Device Flow against a classic OAuth App with
  `repo` scope (all the user's repos, no installation step); tokens in
  app-private storage
- **Workspaces** — clone via the tarball API, extracted by the hand-written
  `TarGz` in `:packages` (platform GZIP + hand tar — the same reader the npm
  installer uses); one workspace per repo, app-wide
- **Files / Viewer / Graph** — lazy tree, in-place editing with shared
  `FileBuffer`s across rings, the commit graph with colored rails
- **Push / pull** — corner chips; one real commit via the Git Data API
- **Persistence** — the whole strip survives relaunch (JSON snapshot)
- **Terminal** — two engines behind the switcher: `msh` (the same
  from-scratch shell as iOS, ported) and the device's **real
  `/system/bin/sh`** as a persistent process — Android's honest advantage
- **Terminal screen** (`:terminal`) — the VT100/xterm cell grid, ANSI parser,
  Unicode width table and key encoding, gated by `:screencheck`
- **Package manager** (`:packages`) — semver (ranges, caret/tilde, prerelease
  ordering), the npm registry client, breadth-first resolution with classic
  hoisting, integrity-checked installs, `npm:` aliases, the wasm/wasi
  substitutions and the `node_modules` manifest, gated by `:pkgcheck`. The
  shell commands that drive it (`npm install`, `npx`, `npm run`) are phase G's
  job on this platform, because they need the Node layer to run what they
  install
- **Node layer, foundation** (`:node` + `nodehost/`) — the iOS engine's
  JavaScript bootstrap, verbatim, running in a headless WebView with a Kotlin
  bridge under it: `console`, `process` (argv, env, cwd, version, exit code)
  and timers with node's tick discipline. Gated by `:nodecheck` off-device and
  by a debug broadcast on-device
- **Node layer, filesystem and modules** — `fs` over workspace-virtual paths
  (`NodeFs`: read, write, append, stat/lstat with node's full field set,
  readdir, mkdir, remove, rename, chmod, statfs) and a real CommonJS `require`
  over `node_modules` (`ModuleResolver` plus the loader in `node-host.js`):
  relative and bare specifiers, the walk-up, `package.json` "main"/"exports"/
  "imports"/"type", extension probing, index fallback, `.json` modules, the
  module cache, circular requires reading live partial exports, and
  `require.resolve` with `.paths`
- **Node layer, sockets** (`NodeSockets`, `NodeDns`, `NodeHttp`) — real TCP and
  UDP on one Java NIO selector thread (not a thread per socket), `net` and
  through it `http.createServer`, `dns.lookup` plus the whole `dns.resolve*`
  family on the wire, and `fetch`/`https.request` over the platform's own TLS
  client. `fs.watch`, ES modules, unix-domain sockets, the `cluster` descriptor
  handoff, the `WebSocket` global, crypto, compression, `vm`, workers and child
  processes are not wired and refuse by name, each with its own reason

## Known Android nuances

- **`statfs` cannot use `Files.getFileStore` on Android, and the JVM gate
  cannot see that.** Resolving a `FileStore` means matching the path against
  the mount table, and an app cannot read enough of `/proc/mounts` to do it —
  so it throws, `statfs` returned null, and the bootstrap raised
  `ENOENT: statfs '/'`, which killed the program on its first fs call and took
  30 downstream device checks with it while the desktop harness stayed green.
  `NodeFs.statfs` now falls back to `File`'s space methods, which need no mount
  table. The block size is the one casualty: 4096 as a fallback rather than a
  measurement.
- **An app's private files are `0600`, so `4 & stats.mode` is false on
  Android.** The mode is real and correctly reported; the others-read bit is
  genuinely clear. The practical consequence is that **chokidar hides every
  file in a watched tree**, because it gates each entry on exactly that bit.
  Reporting a `0644` the file does not have would fix chokidar by lying to
  everything else, so it is recorded here instead. Anything that needs to know
  whether *this process* can read a file should test owner-read (`0o400`).
- **`process.platform` reports `darwin`, and will until iOS makes it a host
  value.** It is a constant inside the shared bootstrap
  (`platform: 'darwin'`, `arch: 'arm64'`), not something the host supplies —
  unlike `argv`, `env` and `cwd`, which arrive through `__argv`/`__env`/`__cwd`.
  Correcting it means adding a `__platform` global on the Swift side, and
  `swift/` is frozen for this loop, so it is recorded rather than fixed.
- **The WebView's global object is a `Window`, and the bootstrap assigns over
  parts of it.** `globalThis.crypto = {…}` against an accessor with no setter
  throws in strict mode — at line 768 of 13,993, taking the whole engine with
  it. JavaScriptCore never sees this: its global owns almost nothing. So the
  host redefines every global the bootstrap assigns as a plain writable
  property first (`Bootstrap.unlockGlobalsScript`), and the list is derived
  from the shipping bootstrap rather than written by hand.
- **`fs.renameSync` does not overwrite, on either platform.** The bootstrap
  ignores what `bridge.rename` answers, and both hosts refuse a move onto an
  existing name — iOS because `FileManager.moveItem` does, Android because
  `NodeFs.rename` was written to match it. Real node overwrites. So a rename
  onto an existing file silently does nothing on both. This is a bug in the
  SHARED design (the fix belongs in the bootstrap, which is `swift/`, frozen
  for this loop), so it is recorded rather than fixed — fixing it on Android
  alone would make the two platforms disagree while looking like a repair.
- **`process.exit()` from an async continuation is reported as an unhandled
  rejection.** `process.exit` records the code through `bridge.exit` and then
  unwinds by throwing a sentinel. Thrown from a synchronous frame the shim
  catches it; thrown from a promise continuation it lands in the microtask
  checkpoint at the *end* of a turn, outside any `try`/`catch` — where a
  WebView logs it to its console. The run still ends with the right code,
  because the code was recorded before the throw. iOS never sees this:
  JavaScriptCore drains microtasks inside the native call, so its
  `exceptionHandler` catches the sentinel and ignores it.
- **`Stats` fields the JDK cannot name are derived, not measured.**
  `st_blocks` is computed from the size in 512-byte units and `st_blksize`
  answers 4096; `statfs` reports `type`, `files` and `ffree` as 0. Where the
  `unix:*` attribute view is missing (it is on Android), `mode` is rebuilt
  from the POSIX permission set plus the type bits, and `ino` falls back to
  the file key's identity. Everything a program branches on — the type bits,
  the permission bits, size, and all four timestamps — is real.
- **`chmod` carries the nine permission bits and no more.** The JDK's POSIX
  view has no spelling for setuid/setgid/sticky. The case the iOS block exists
  for — a program writing a secret with `mode: 0o600` and getting a
  world-readable file — is entirely within those nine.
- **`socket.setKeepAlive(on, delay)` honours the flag and drops the delay.**
  `SO_KEEPALIVE` is `StandardSocketOptions`; the idle interval the iOS block
  sets with `TCP_KEEPALIVE` has no portable Java spelling — `TCP_KEEPIDLE` lives
  in `jdk.net.ExtendedSocketOptions`, which Android does not ship. So keep-alive
  is on or off as asked and the interval is the system default. This is an
  accepted-and-dropped OPTION, which AGENTS.md calls the worst of three, so it
  is written down rather than left to be discovered: the alternative is throwing
  on a call every HTTP agent makes.
- **`dns.resolve*` needs the host to say where to ask.** Android has no
  `/etc/resolv.conf`, and the JDK exposes no resolver API at all — `javax.naming`
  is absent on Android, so a resolver built on it would gate green on a desktop
  and be missing on a phone. `NodeDns` therefore speaks DNS on the wire and takes
  its nameservers from `ConnectivityManager.getLinkProperties(…).dnsServers`
  (hence `ACCESS_NETWORK_STATE` in the manifest). With no network, or with the
  permission refused, the list is empty and every `dns.resolve*` answers
  `ESERVFAIL` — deliberately not a public resolver, which would send a user's
  lookups somewhere they did not choose and would be wrong on any split-horizon
  network. `dns.lookup` is unaffected: that is `getaddrinfo`.
- **`dns.lookupService` gets its service names from a table.** There is no
  `getservbyport` in Java. The names come from `/etc/services` where it is
  readable (it is on Android) and from the IANA well-known list otherwise; a
  port with neither answers its own number, which is what `getnameinfo` does
  without `NI_NUMERICSERV`.
- **Unix-domain sockets, the `cluster` fd handoff and the `WebSocket` global are
  the three socket surfaces that stayed deferred, and none of them is "later".**
  `AF_UNIX` in `java.nio` is `UnixDomainSocketAddress`, JDK 16 and Android API
  34, against this app's minSdk 26 — the class is absent on most devices it
  targets, and `android.net.LocalSocket` is not a `SelectableChannel` and cannot
  join the selector. `netAdopt`/`netListenHandoff` want a `SocketChannel` around
  a descriptor the JVM did not open, which `java.nio` will not build. And there
  is no WebSocket client in the JDK or the framework, so the global would need a
  third-party artifact (invariant #4) or a hand-written RFC 6455 stack that
  still could not do `wss://`. The `ws` PACKAGE is unaffected — it rides these
  sockets for `ws://`.
- **The relative order of events on two DIFFERENT sockets is not asserted, on
  either platform.** node reports a server's `connection` before the connecting
  client's `connect`; iOS reports the reverse, because a loopback handshake
  completes inside `connect()`. A non-blocking `SocketChannel.connect` on this
  platform may land either way. Every fixture here asserts each socket's OWN
  sequence instead, which is the same disposition `verify/net` records.
- **`dns.lookup('localhost')` may answer `::1`.** Some images resolve loopback to
  IPv6 first. The gate accepts either and asserts that a NAME resolved at all;
  a fixture pinned to `127.0.0.1` would be asserting an image, not the engine.
- **The live half of the DNS cross-check compares two resolvers.** It asks a real
  nameserver and compares with real node asking for the same records, which is
  the only way to grade the wire format honestly — and it is the same exposure
  `verify/dnsres` has on iOS. It skips when there is no resolver or the network
  does not answer in 30 s, but a partial answer from one side would read as a
  mismatch. If that ever fires alone, re-run before believing it.
- **TypeScript `paths` aliases are not tried.** iOS asks the bootstrap's
  TypeScript bridge for a project's `tsconfig` aliases before walking
  `node_modules`; that needs a compiler loaded through the very loader being
  built, and Android has none wired. A project using one gets
  MODULE_NOT_FOUND — which is also what real node gives.
- **Edge-swipe vs. the system back gesture.** On gesture-navigation devices,
  Android reserves the screen edges for the back gesture. The ring edge-swipe
  claims those bands with `Modifier.systemGestureExclusion()` (the standard
  API), but the OS caps exclusion at 200 dp per edge, so on gesture-nav a
  swipe from the extreme edge may still go back. This is inherently a
  real-device / real-finger behavior (`adb input` near the edge is
  intercepted by the system's back-gesture handler and can't test it
  faithfully). No conflict on 3-button navigation.
- **Pixels ring-swipe in the gaps.** On Google Pixels (runtime check:
  `Build.MANUFACTURER == "Google"` + `Build.MODEL` contains "Pixel", one APK
  for everyone), the edge strips stand down and ring travel moves to the
  negative space between containers: a **horizontal drag in a divider gap**
  swipes the ring. The gap keeps both gestures — the axis-locked detectors
  mean vertical still resizes lanes, horizontal swipes rings, and whichever
  axis crosses touch slop first claims the drag. Direction locks on the
  first movement so a mid-drag wobble can't flip neighbors. A one-lane ring
  has no gap, so the edge strips remain its travel path there.

## Platform differences (by design)

- **`sh` engine**: Android runs the real system shell; iOS can't (no
  fork/exec), so iOS has only `msh`. Both platforms share `msh`.
- **`ping`**: uses `InetAddress.isReachable` (no raw sockets / NDK); iOS
  hand-builds ICMP packets on an unprivileged datagram socket.
- **Token storage**: app-private `SharedPreferences` (the Android sandbox);
  iOS uses the Keychain. A Keystore upgrade is a future nicety.
