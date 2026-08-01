// Call every function export with no arguments and CLASSIFY the failure. Our refusals all say
// "is not available:", so they are distinguishable from a function that merely wants arguments.
// Anything we refuse and node does not is a candidate reachable gap — the sweep that generalises
// six gaps found one at a time by hand.
// One module per process: a function that blocks then costs one module instead of the run, and
// says which one. (inspector.waitForDebugger is exactly that hazard.)
const modules = [process.argv[2]];
// Calling these has consequences, or blocks, so they are never invoked.
const forbidden = new Set(['exit', 'abort', 'reallyExit', '_exit', 'kill', 'chdir', 'umask',
  'setuid', 'setgid', 'seteuid', 'setegid', 'setgroups', 'initgroups', 'disconnect', 'dlopen',
  'binding', '_linkedBinding', 'openStdin', 'runInThisContext', 'runInNewContext', 'setUncaughtExceptionCaptureCallback',
  'fork', 'spawn', 'exec', 'execSync', 'execFile', 'execFileSync', 'spawnSync', 'spawnAsync',
  'rm', 'rmSync', 'rmdir', 'rmdirSync', 'unlink', 'unlinkSync', 'truncate', 'truncateSync',
  'writeFile', 'writeFileSync', 'appendFile', 'appendFileSync', 'mkdir', 'mkdirSync', 'mkdtemp',
  'watch', 'watchFile', 'unwatchFile', 'createWriteStream', 'takeCoverage', 'stopCoverage',
  'writeHeapSnapshot', 'getHeapSnapshot', 'setFlagsFromString', 'queryObjects', 'Worker', 'close',
  // Timers with no arguments leave a live handle and the process never exits.
  'setInterval', 'setTimeout', 'setImmediate', 'clearInterval', 'clearTimeout', 'clearImmediate',
  'createServer', 'createSocket', 'createInterface', 'connect', 'request', 'get', 'monitorEventLoopDelay']);

const rows = [];
for (const name of modules) {
  let target;
  try { target = require(name); } catch (error) { rows.push(name + '\t<module>\tmodule-refused'); continue; }
  if (!target || typeof target !== 'object') continue;
  for (const key of Object.keys(target).sort()) {
    if (forbidden.has(key)) continue;
    let value;
    try { value = target[key]; } catch (error) { continue; }
    if (typeof value !== 'function') continue;
    // Constructors are skipped: calling them without `new` throws for reasons of its own.
    if (/^[A-Z]/.test(key)) continue;
    let verdict;
    try { value(); verdict = 'ok'; }
    catch (error) {
      const message = String(error && error.message || '');
      verdict = /is not available|not implemented|ERR_METHOD_NOT_IMPLEMENTED/.test(message) ||
                error.code === 'ERR_METHOD_NOT_IMPLEMENTED' ? 'refused' : 'other';
    }
    rows.push(name + '\t' + key + '\t' + verdict);
  }
}
console.log(rows.join('\n'));
// Nothing here should hold the loop, but do not rely on it.
process.exit(0);
