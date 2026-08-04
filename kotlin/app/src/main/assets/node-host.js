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

  // ---- require ---------------------------------------------------------------------------
  // Called at the TOP LEVEL of the bootstrap (`globalThis.__mouseRequire`), so it cannot be one
  // of the throwing stubs — it has to hand back a function. The function is what refuses, which
  // is also the honest shape: the loader exists nowhere on this platform yet, so every request
  // fails, and it fails by name at the point of use rather than at load.
  bridge.createRequire = function () {
    var refuse = function (specifier) {
      var error = new Error("Cannot find module '" + specifier + "': the Android Node layer has "
        + 'no module loader — CommonJS resolution over node_modules is not part of the '
        + 'console/process/timer bridge');
      error.code = 'MODULE_NOT_FOUND';
      throw error;
    };
    refuse.resolve = refuse;
    refuse.cache = Object.create(null);
    refuse.extensions = Object.create(null);
    refuse.main = undefined;
    return refuse;
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
    entry: function (source, url) {
      var result = { ok: true, error: '' };
      try {
        (0, eval)(source + (url ? '\n//# sourceURL=' + url : ''));
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
