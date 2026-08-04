// The Android half of the `__mouse` bridge — the shim the JS bootstrap talks to.
//
// This file is ANDROID-ONLY. It has no counterpart in swift/: on iOS the bridge is a dictionary
// of Swift blocks handed straight to JavaScriptCore, so `bridge.setTimer(fn, …)` can pass the
// callback ITSELF to the host. Android's @JavascriptInterface carries only primitives and
// strings, in either direction, so the callback has to stay in JavaScript and only an id may
// cross. That is the whole job here: present the iOS-shaped `__mouse` API to the bootstrap, keep
// the functions in a registry on this side, and let the host re-enter through __mouseDispatch.
//
// Load order (NodeWebView.kt): this file, then the deferred-stub script, then the process
// globals, then node-bootstrap.js. The bootstrap reads `__mouse` and `__argv`/`__env`/`__cwd` at
// the top level of its IIFE, so both must already exist when it is evaluated.
//
// The bridge surface split — what is implemented and what refuses — lives in
// kotlin/node/.../HostBridge.kt, and `./gradlew :nodecheck:run` grades it against the names the
// shipping bootstrap actually calls.
(function () {
  'use strict';

  var host = globalThis.__mouseHost;
  if (!host) throw new Error('__mouseHost is not installed; addJavascriptInterface ran too late');

  // id -> { fn, args, repeat }. The host owns the SCHEDULE (NodeLoop.kt); this owns the callbacks.
  var timers = Object.create(null);
  var immediates = Object.create(null);

  // id -> fn, for everything the host calls back ASYNCHRONOUSLY: socket events, DNS answers, HTTP
  // chunks. Same reason the timer registry exists — @JavascriptInterface cannot carry a function,
  // so the callback stays here and the host holds only the id it was given.
  //
  // A socket's handler is registered under the id `netConnect`/`netListen` returned and stays
  // until that socket closes; a SERVER's handler receives its accepted sockets' events too, which
  // is why the id the host dispatches under is the OWNER's rather than the event's. The host says
  // when an entry may go (the `final` flag), because only the host knows whether the handle is
  // gone — inferring it from the event name here would drop a server's handler on the first
  // connection's close and silently kill every later one.
  var handlers = Object.create(null);

  var bridge = Object.create(null);

  // ---- console / stdio sinks -------------------------------------------------------------
  bridge.stdout = function (text) { host.stdout(String(text)); };
  bridge.stderr = function (text) { host.stderr(String(text)); };

  // ---- process ---------------------------------------------------------------------------
  // The flag is read by the immediate batch: once a program has exited, the rest of a batch that
  // was already snapshotted must not run. iOS gets this from `guard exitCode == nil` inside its
  // own loop; here the batch is running inside one JS turn, so the check has to be in JS.
  bridge.exit = function (code) {
    globalThis.__mouseExited = true;
    host.exit(code | 0);
  };

  // A DECIMAL STRING, not a number. The bootstrap does `BigInt(bridge.monotonicNanos())`, and a
  // nanosecond clock passes 2^53 after about fourteen weeks of uptime — past which a JS number is
  // no longer an integer and BigInt() throws. A string has no such ceiling.
  bridge.monotonicNanos = function () { return host.monotonicNanos(); };

  // ---- event loop holds ------------------------------------------------------------------
  bridge.loopHold = function (on) { host.loopHold(!!on); };
  bridge.stdinActive = function (on) { host.stdinActive(!!on); };

  // ---- timers ----------------------------------------------------------------------------
  bridge.setTimer = function (fn, delay, repeat, args) {
    var id = host.setTimer(Number(delay) || 1, !!repeat);
    timers[id] = { fn: fn, args: args || [], repeat: !!repeat };
    return id;
  };
  bridge.clearTimer = function (id) {
    id = id | 0;
    delete timers[id];
    host.clearTimer(id);
  };
  bridge.timerRef = function (id, refed) { host.timerRef(id | 0, !!refed); };
  bridge.timerRefresh = function (id) { host.timerRefresh(id | 0); };
  bridge.setImmediate = function (fn, args) {
    var id = host.setImmediate();
    immediates[id] = { fn: fn, args: args || [] };
    return id;
  };
  bridge.clearImmediate = function (id) {
    id = id | 0;
    delete immediates[id];
    host.clearImmediate(id);
  };

  // ---- filesystem ------------------------------------------------------------------------
  //
  // Primitives only. Every RULE about when they may be called — ENOENT for a missing parent,
  // EISDIR for reading a directory, EEXIST, ENOTDIR, refusing to delete a tree without
  // `recursive` — lives in the shared bootstrap, which Android runs verbatim, so all of that
  // hard-won strictness arrives with it and none of it is restated here.
  //
  // The marshalling is the whole of what this section adds. iOS hands JavaScriptCore a Swift
  // dictionary and JSC converts it; @JavascriptInterface carries nothing but primitives and
  // strings, so a structured answer crosses as JSON and is parsed back into the shape the
  // bootstrap already expects. Content crosses as base64 on BOTH platforms — the bootstrap does
  // `Buffer.from(base64, 'base64')` either way — so binary survives the String hop.
  //
  // `null` is load-bearing. It is how every one of these reports failure, and the bootstrap
  // branches on it (`if (!raw) return …`), so a wrapper that turned a null into `undefined` or
  // into an empty object would disable a rule written somewhere else.
  function parsedOrNull(raw) {
    return (raw === null || raw === undefined) ? null : JSON.parse(raw);
  }

  bridge.stat = function (path, followLinks) {
    return parsedOrNull(host.stat(String(path), !!followLinks));
  };
  bridge.statfs = function (path) { return parsedOrNull(host.statfs(String(path))); };
  bridge.readdir = function (path) { return parsedOrNull(host.readdir(String(path))); };
  bridge.readFile = function (path) {
    var base64 = host.readFile(String(path));
    return (base64 === null || base64 === undefined) ? null : base64;
  };
  bridge.writeFile = function (path, base64, append) {
    return host.writeFile(String(path), String(base64), !!append);
  };
  bridge.mkdir = function (path) { return host.mkdir(String(path)); };
  bridge.remove = function (path) { return host.remove(String(path)); };
  bridge.rename = function (from, to) { return host.rename(String(from), String(to)); };
  bridge.chmodPath = function (path, mode) { return host.chmodPath(String(path), Number(mode) | 0); };

  // ---- process / loop instrumentation ----------------------------------------------------
  bridge.cpuUsage = function () { return JSON.parse(host.cpuUsage()); };
  bridge.loopUtilization = function () { return JSON.parse(host.loopUtilization()); };
  // No terminal is attached to a headless host, so this does nothing — which is exactly what the
  // iOS block does with `tty == nil`. A faithful port of a no-op, not a stub standing in for one.
  bridge.setRawMode = function (raw) { host.setRawMode(!!raw); };

  // ---- crypto ------------------------------------------------------------------------------
  // Only entropy so far. It is bound ahead of the rest of the crypto surface because CPython's
  // WASI start asks for it before a script's first line runs — see HostBridge.DEFERRED for what
  // is still refused and why.
  bridge.randomBytes = function (count) { return host.randomBytes(Number(count) | 0); };
  bridge.randomUUID = function () { return host.randomUUID(); };
  // `null` is the contract for "unknown algorithm" and the bootstrap branches on it to raise
  // node's own error, so an empty string would be a wrong answer rather than a missing one.
  bridge.cryptoHash = function (algorithm, base64) {
    return host.cryptoHash(String(algorithm), String(base64));
  };
  bridge.cryptoHmac = function (algorithm, keyBase64, base64) {
    return host.cryptoHmac(String(algorithm), String(keyBase64), String(base64));
  };
  bridge.pbkdf2 = function (password, salt, iterations, keylen, digest) {
    return host.pbkdf2(String(password), String(salt), Number(iterations) | 0,
                       Number(keylen) | 0, String(digest));
  };

  // ---- sockets, dns and the TLS transport --------------------------------------------------
  //
  // iOS hands JavaScriptCore the callback itself: `bridge.netConnect(host, port, fn)` and the
  // Swift side calls `fn(id, event, payload)` whenever the socket does something. Nothing about
  // that survives @JavascriptInterface, so the callback is registered here and the host is given
  // an id; the host re-enters through __mouseDispatch.jobs with `(id, argsJson, final)` and the
  // arguments are applied unchanged. The bootstrap's `_hostEvent` switch never learns any of this.
  //
  // Payloads cross as JSON for the same reason `stat` does — an object cannot cross — and socket
  // DATA crosses as base64 inside it, exactly as on iOS, so binary survives the String hop.
  // Register AFTER the host has answered, which is safe because a job cannot be delivered inside
  // this turn: the host queues it and only `pump()` dispatches, and `pump()` dispatches by calling
  // evaluateJavascript, which the WebView runs after the script currently executing. So there is
  // no window in which an event arrives for an id nothing is listening to yet.
  function remember(fn) {
    return function (assigned) {
      var id = assigned | 0;
      handlers[id] = fn;
      return id;
    };
  }

  // `hostname`, never `host`: the host OBJECT is in scope under that name for the whole file, and
  // a parameter called `host` would shadow it — the call inside would go to the string. This is
  // the same shape as the bootstrap's `interface`-as-a-parameter trap, and just as invisible.
  bridge.netConnect = function (hostname, port, fn) {
    return remember(fn)(host.netConnect(String(hostname), Number(port) | 0));
  };
  bridge.netListen = function (hostname, port, backlog, fn) {
    return remember(fn)(host.netListen(String(hostname), Number(port) | 0, Number(backlog) | 0));
  };
  bridge.netWrite = function (id, base64) { return host.netWrite(id | 0, String(base64)); };
  bridge.netEnd = function (id) { host.netEnd(id | 0); };
  bridge.netDestroy = function (id) { host.netDestroy(id | 0); };
  bridge.netPause = function (id) { host.netPause(id | 0); };
  bridge.netResume = function (id) { host.netResume(id | 0); };
  bridge.netRef = function (id, refed) { host.netRef(id | 0, !!refed); };
  bridge.netNoDelay = function (id, on) { host.netNoDelay(id | 0, on === undefined ? true : !!on); };
  bridge.netKeepAlive = function (id, on, delay) {
    host.netKeepAlive(id | 0, on === undefined ? true : !!on, Number(delay) | 0);
  };
  // dns.lookup. One-shot: the answer arrives once and the entry goes with it.
  bridge.netResolve = function (hostname, family, fn) {
    remember(fn)(host.netResolve(String(hostname), Number(family) | 0));
  };

  // The dns.resolve* family. `dnsDone` is the bootstrap giving the loop handle back after each
  // answer — it is called from JS, not delivered from the host, so it stays a plain crossing.
  bridge.dnsResolve = function (name, type, fn) {
    remember(fn)(host.dnsResolve(String(name), String(type)));
  };
  bridge.dnsReverse = function (address, fn) {
    remember(fn)(host.dnsReverse(String(address)));
  };
  bridge.dnsService = function (address, port, fn) {
    remember(fn)(host.dnsService(String(address), Number(port) | 0));
  };
  bridge.dnsDone = function () { host.dnsDone(); };

  // fetch and https.request. `headers` is an object on iOS and cannot cross, so it travels as
  // JSON; the body is base64 on both platforms already.
  bridge.httpRequest = function (url, method, headers, bodyBase64, fn) {
    remember(fn)(host.httpRequest(String(url), String(method),
                                  JSON.stringify(headers || {}), String(bodyBase64 || '')));
  };
  bridge.httpStream = function (url, method, headers, bodyBase64, fn) {
    remember(fn)(host.httpStream(String(url), String(method),
                                 JSON.stringify(headers || {}), String(bodyBase64 || '')));
  };

  // UDP.
  bridge.dgramBind = function (hostname, port, broadcast, fn) {
    return remember(fn)(host.dgramBind(String(hostname), Number(port) | 0, !!broadcast));
  };
  bridge.dgramSend = function (id, base64, hostname, port, fn) {
    remember(fn)(host.dgramSend(id | 0, String(base64), String(hostname), Number(port) | 0));
  };
  // Synchronous, and the empty string means SUCCESS — the iOS rule this layer paid for once:
  // coalescing "no problem" to a code reported every successful join as a failure.
  bridge.dgramMembership = function (id, group, iface, join) {
    return host.dgramMembership(id | 0, String(group), String(iface || ''), !!join);
  };
  // -1 means "leave this one alone": each knob is set independently.
  bridge.dgramOption = function (id, ttl, loopback, iface) {
    host.dgramOption(id | 0, Number(ttl) | 0, Number(loopback) | 0, String(iface || ''));
  };

  // ---- require ---------------------------------------------------------------------------
  //
  // `require(x)` is two jobs that look like one, and iOS splits them the same way this does.
  // RESOLUTION — the node_modules walk, package.json "exports"/"main"/"imports", extension
  // probing, index files — is `NodeEngine.resolveModule` in Swift and `ModuleResolver` in Kotlin,
  // where a harness can reach it. LOADING — reading the file, wrapping it in the module function,
  // evaluating it — can only happen in the JavaScript engine, so it is here.
  //
  // The cache is per ENGINE, not per require: `require('./a')` from two different files must hand
  // back the same object, which is what makes a module's state its own.
  var moduleCache = Object.create(null);
  var coreCache = Object.create(null);
  // A module still being evaluated. A circular require reads exports LIVE off the module object,
  // so `module.exports = Class` before the cycle closes is visible to the partner — the iOS
  // `modulesInProgress` map, and the reason this is not simply "cache it when it finishes".
  var inProgress = Object.create(null);

  function coded(message, code) {
    var error = new Error(message);
    error.code = code;
    return error;
  }

  // No newline after the wrapper: the body's first line must BE the file's first line, or every
  // line number in every stack trace is off by one — which for an editor means the click lands on
  // the wrong line, all day. node wraps this way for the same reason, and so does iOS.
  //
  // `__mouseRequire` is a SEPARATE parameter carrying the same value as `require`, because a
  // module doing `const require = createRequire(...)` — legal, and what several dual packages do
  // — shadows the `require` PARAMETER scope-wide.
  function wrapModule(source, id, async) {
    var body = source;
    if (body.slice(0, 2) === '#!') {
      var newline = body.indexOf('\n');
      body = newline < 0 ? '' : body.slice(newline);
    }
    // An ES module is wrapped ASYNC. The transpiled source emits `await` at its top level —
    // every import site awaits a dependency that turns out to be pending — so the wrapper has to
    // be a function that may suspend. A module that never awaits anything real still settles in
    // the same turn, which is why sync modules stay sync under it.
    return (0, eval)(
      '(' + (async ? 'async ' : '')
      + 'function(exports, require, module, __filename, __dirname, __mouseRequire, __mouseFilename){'
      + body + '\n})\n//# sourceURL=mouse://' + id);
  }

  function loadJson(id) {
    if (id in moduleCache) return moduleCache[id];
    var text = host.readText(id);
    if (text === null || text === undefined) throw coded("Cannot read '" + id + "'", 'MODULE_NOT_FOUND');
    var value = (0, eval)('(' + text + ')');
    moduleCache[id] = value;
    return value;
  }

  function loadFile(id) {
    if (id in inProgress) return inProgress[id].exports;
    if (id in moduleCache) return moduleCache[id];

    var payload = host.loadModule(id);
    if (payload === null || payload === undefined) {
      throw coded("Cannot read '" + id + "'", 'MODULE_NOT_FOUND');
    }
    var info = JSON.parse(payload);
    var directory = host.virtualDirname(id);
    var fn;
    try {
      fn = wrapModule(info.source, id, info.esm);
    } catch (e) {
      // A SyntaxError here is the FILE failing to parse, and the message is the only thing that
      // says where. Swallowing it leaves "Cannot parse '<2 MB file>'", which is unactionable.
      throw coded("Cannot parse '" + id + "': " + ((e && e.message) || e), 'ERR_MOUSE_PARSE');
    }

    var module = { exports: {} };
    inProgress[id] = module;
    var required = makeRequire(directory, false);
    var result;
    try {
      result = fn(module.exports, required, module, id, directory, required, id);
    } catch (e) {
      // A module that throws mid-evaluation must not linger as partial exports: evict, and let
      // the ORIGINAL error reach the requiring frame.
      delete inProgress[id];
      delete moduleCache[id];
      throw e;
    }
    // An ES module's wrapper is async, so `require()` of one answers a PROMISE of its exports.
    // That is not a wart: it is the contract the transpiled import site already expects — every
    // one of them reads `if (x instanceof Promise) x = await x`. It is also the only honest
    // answer, because a module with top-level await genuinely is not finished yet.
    if (info.esm && result && typeof result.then === 'function') {
      var settled = result.then(function () {
        delete inProgress[id];
        moduleCache[id] = module.exports;
        return module.exports;
      }, function (e) {
        delete inProgress[id];
        delete moduleCache[id];
        throw e;
      });
      // Cached as the PROMISE, so a second require during the same evaluation joins the first
      // rather than running the module twice.
      moduleCache[id] = settled;
      return settled;
    }
    delete inProgress[id];
    moduleCache[id] = module.exports;
    return module.exports;
  }

  function resolveAnswer(specifier, fromDir, esm) {
    return JSON.parse(host.resolveModule(String(specifier), fromDir, !!esm));
  }

  function requireFrom(fromDir, esm, specifier) {
    var answer = resolveAnswer(specifier, fromDir, esm);
    if (answer.kind === 'core') {
      if (answer.id in coreCache) return coreCache[answer.id];
      var core = globalThis.__coreModule(answer.id);
      coreCache[answer.id] = core;
      return core;
    }
    if (answer.kind === 'json') return loadJson(answer.id);
    if (answer.kind === 'file') return loadFile(answer.id);
    // 'addon' and 'error' both arrive with the message and the code the caller should see —
    // ERR_DLOPEN_FAILED is a different fact from MODULE_NOT_FOUND, and tools branch on it.
    throw coded(answer.message, answer.code);
  }

  function makeRequire(fromDir, esm) {
    var required = function (specifier) { return requireFrom(fromDir, !!esm, specifier); };
    required.resolve = function (specifier) {
      var answer = resolveAnswer(specifier, fromDir, esm);
      if (answer.kind === 'core') return 'node:' + answer.id;
      if (answer.kind === 'error') throw coded(answer.message, answer.code);
      return answer.id;
    };
    // `require.resolve.paths(request)`: the directories that WOULD be searched. jest asks for
    // these to build its own module registry, so a missing one stops it at startup.
    required.resolve.paths = function (specifier) {
      return JSON.parse(host.resolvePaths(String(specifier), fromDir));
    };
    // `import()` resolves on the "import" condition WHATEVER the importing file is: node keys the
    // condition to the syntax, not to the file's format, and a dual package ships genuinely
    // different files behind the two.
    required.__importCondition = function (specifier) {
      try {
        return requireFrom(fromDir, true, specifier);
      } catch (e) {
        if (e && e.code === 'MODULE_NOT_FOUND') e.code = 'ERR_MODULE_NOT_FOUND';
        throw e;
      }
    };
    return required;
  }

  // Called at the TOP LEVEL of the bootstrap (`globalThis.__mouseRequire`), so it can never be
  // one of the throwing stubs — it has to hand back a function.
  bridge.createRequire = function (fromPath) {
    var from = String(fromPath === undefined || fromPath === null ? '/' : fromPath);
    if (from.indexOf('file://') === 0) from = from.slice(7);
    return makeRequire(host.virtualDirname(from), false);
  };

  globalThis.__mouse = bridge;

  // ---- loading the rest of the engine ----------------------------------------------------
  //
  // evaluateJavascript reports a broken script by handing back `null` and writing to the
  // console — a caller can act on neither, and a gate can see neither. Indirect eval inside a
  // try/catch turns a syntax error and a top-level throw alike into a string.
  //
  // The bootstrap arrives by NAME rather than as a literal: it is ~700 KB, and embedding it in
  // the script that evaluates it would mean escaping and shipping it twice. A synchronous
  // @JavascriptInterface String return carries it once.
  globalThis.__mouseEval = function (source, label) {
    try {
      (0, eval)(source + '\n//# sourceURL=' + label);
      return null;
    } catch (e) {
      return (e && e.stack) ? String(e.stack) : String(e);
    }
  };
  globalThis.__mouseEvalAsset = function (name) {
    return globalThis.__mouseEval(host.asset(name), name);
  };

  // ---- the host's way back in ------------------------------------------------------------
  //
  // Every re-entry is one turn of the loop, and a turn has the shape the iOS `runEventLoop` has:
  //
  //     drainTicks(); … run the ready work …
  //
  // The LEADING drain is the one Swift performs after `invoke()` returns — ticks queued from
  // inside the microtask checkpoint JSC runs as a callback's stack unwinds, which node runs once
  // the checkpoint is done rather than partway through it. Here the checkpoint belongs to the
  // PREVIOUS evaluateJavascript turn and runs when that script ends, so "after the checkpoint" is
  // the top of the next turn: this line. The trailing drain — before the stack unwinds, ahead of
  // any promise reaction — is `__invoke`'s own `finally`, unchanged from iOS.
  // A throw out of a host-invoked callback must not escape into the WebView, where it becomes a
  // console line nobody reads and a turn that silently did half its work. iOS contains this in
  // `context.exceptionHandler`; there is no such hook here, so the containment is the dispatch
  // boundary itself — and it does what node does: `uncaughtException` gets first refusal, and an
  // unhandled one is a printed stack and exit 1.
  function turn(work) {
    globalThis.__drainTicks();
    try {
      work();
    } catch (e) {
      var text = (e && e.message) ? String(e.message) : String(e);
      // process.exit unwinds by throwing. That is not a failure.
      if (text.indexOf('__mouse_exit__') >= 0) return;
      var handled = false;
      try {
        handled = !!(globalThis.__mouseEmitUncaught && globalThis.__mouseEmitUncaught(e));
      } catch (inner) {
        handled = false;
      }
      if (handled) return;
      host.stderr(((e && e.stack) ? String(e.stack) : text) + '\n');
      globalThis.__mouseExited = true;
      host.exit(1);
    }
  }

  globalThis.__mouseDispatch = {
    // I/O completions — socket events, DNS answers, HTTP chunks. This is the iOS `enqueueJob`
    // queue, and the loop drains it FIRST, ahead of immediates and timers, on both platforms.
    //
    // A batch, snapshot by the host before it runs, for the same reason immediates are: an event
    // that arrives WHILE this batch runs belongs to the next turn. `__mouseExited` stops the rest
    // of a batch once a program has exited, which is `guard exitCode == nil` inside the iOS loop.
    //
    // Each entry is `[handlerId, argsJson, final]`. The arguments are applied unchanged, so the
    // bootstrap's socket callback receives exactly `(id, event, payload)` — the same three the
    // Swift dispatcher passes.
    jobs: function (batch) {
      turn(function () {
        for (var i = 0; i < batch.length; i++) {
          if (globalThis.__mouseExited) return;
          var entry = batch[i];
          var fn = handlers[entry[0]];
          if (entry[2]) delete handlers[entry[0]];
          if (!fn) continue;
          globalThis.__invoke(fn, JSON.parse(entry[1]));
        }
      });
    },
    timer: function (id) {
      turn(function () {
        var entry = timers[id];
        if (!entry) return;
        if (!entry.repeat) delete timers[id];
        globalThis.__invoke(entry.fn, entry.args);
      });
    },
    // A batch, snapshot before it runs: an immediate scheduled BY an immediate belongs to the
    // next turn. Draining a live queue instead starves timers forever, which is why the iOS loop
    // takes `let batch = immediates; immediates = []` rather than iterating in place.
    immediates: function (ids) {
      turn(function () {
        for (var i = 0; i < ids.length; i++) {
          if (globalThis.__mouseExited) return;
          var entry = immediates[ids[i]];
          if (!entry) continue;
          delete immediates[ids[i]];
          globalThis.__invoke(entry.fn, entry.args);
        }
      });
    },
    // The entry script's synchronous frame. After it, `hostFrame` is false and nextTick has to
    // schedule its own drain — the bootstrap's comment on why is worth reading before touching
    // any of this.
    //
    // The entry is a MODULE, not a loose script: `NodeEngine.runOnQueue` wraps it exactly like
    // anything it requires, with its own `module`, `exports`, `__filename`, `__dirname` and a
    // `require` rooted at its directory. A plain global eval — which is what this was before the
    // loader existed — leaves `require` undefined in the one file a user is most likely to write.
    entry: function (source, url, async) {
      var result = { ok: true, error: '' };
      try {
        var id = host.normalizePath(String(url || '/main.js'));
        var directory = host.virtualDirname(id);
        var fn = wrapModule(String(source), id, !!async);
        var module = { exports: {} };
        var required = makeRequire(directory, false);
        var settled = fn(module.exports, required, module, id, directory, required, id);
        // An ESM entry's body runs inside an async wrapper, so a throw after its first `await`
        // rejects the promise instead of unwinding through the try below. Without this the
        // program would report success and print nothing, which is the same silent shape the
        // loop's quiescence bug had.
        if (settled && typeof settled.then === 'function') {
          globalThis.__mouseEntrySettled = settled;
          settled.catch(function (e) {
            var text = (e && e.stack) ? String(e.stack) : String((e && e.message) || e);
            if (text.indexOf('__mouse_exit__') >= 0) return;
            host.stderr(text + '\n');
            globalThis.__mouseExited = true;
            host.exit(1);
          });
        }
      } catch (e) {
        // process.exit unwinds by throwing; that is not a failure.
        var text = e && e.message ? String(e.message) : String(e);
        if (text.indexOf('__mouse_exit__') < 0) {
          result.ok = false;
          result.error = (e && e.stack) ? String(e.stack) : text;
        }
      }
      if (globalThis.__leaveEntryFrame) globalThis.__leaveEntryFrame();
      return JSON.stringify(result);
    },
    // The loop has emptied. iOS drains once more after the `while` exits, for the same reason the
    // leading drain exists: the last callback's checkpoint has only just finished.
    finish: function () {
      globalThis.__drainTicks();
    },
  };
})();
