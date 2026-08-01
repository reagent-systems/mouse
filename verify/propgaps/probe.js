// The remaining public PROPERTY gaps the (now trustworthy) shapes sweep names. Values, not
// stubs: node reports real configuration and real counters, and zeros would repeat the
// process.cpuUsage mistake.
const http = require('http'), net = require('net'), zlib = require('zlib');
const { StringDecoder } = require('string_decoder'), { MessageChannel } = require('worker_threads');
const out = [];
const s = http.createServer();
out.push('http defaults: ' + ['httpAllowHalfOpen','maxRequestsPerSocket','requireHostHeader','rejectNonStandardBodyWrites','connectionsCheckingInterval','maxHeaderSize','insecureHTTPParser','joinDuplicateHeaders'].map(k => k + '=' + JSON.stringify(s[k])).join(' '));
const ns = net.createServer();
out.push('net defaults: ' + ['noDelay','keepAlive','keepAliveInitialDelay','pauseOnConnect','highWaterMark'].map(k => k + '=' + JSON.stringify(ns[k])).join(' '));
const configured = net.createServer({ noDelay: true, keepAlive: true, keepAliveInitialDelay: 250, pauseOnConnect: true });
out.push('net configured: ' + ['noDelay','keepAlive','keepAliveInitialDelay','pauseOnConnect'].map(k => k + '=' + JSON.stringify(configured[k])).join(' '));
const g = zlib.createGzip();
out.push('zlib initial: bytesWritten=' + g.bytesWritten + ' allowHalfOpen=' + g.allowHalfOpen);
// Read AFTER the stream finishes: node processes asynchronously, so a reading taken right
// after write() reports 0 there and the true total here — a timing artifact, not a contract.
// What both engines must agree on is the total once the data has actually gone through.
g.on('data', () => {});
let finished = false;
g.on('finish', () => { finished = true; });
g.end(Buffer.concat([Buffer.alloc(100), Buffer.alloc(50)]));
const d = new StringDecoder('utf8');
out.push('decoder idle: lastNeed=' + d.lastNeed + ' lastTotal=' + d.lastTotal + ' lastChar=' + d.lastChar.length);
d.write(Buffer.from([0xE6, 0x97]));   // two bytes of a three-byte character
out.push('decoder holding: lastNeed=' + d.lastNeed + ' lastTotal=' + d.lastTotal);
const { port1 } = new MessageChannel();
out.push('port: hasRef=' + port1.hasRef() + ' onmessageerror=' + JSON.stringify(port1.onmessageerror));
port1.unref();
out.push('port after unref: hasRef=' + port1.hasRef());
s.close(); ns.close(); configured.close(); port1.close();
// Poll rather than listen, so the reading is taken once the stream has actually finished on
// EITHER engine regardless of when that happens.
(function report() {
  if (!finished) return setTimeout(report, 10);
  out.push('zlib total after finish: bytesWritten=' + g.bytesWritten);
  console.log(out.join('\n'));
})();
