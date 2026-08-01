// Fourth detector: options that are ACCEPTED AND IGNORED. Invisible to an export sweep, a shape
// sweep and a globals sweep — TextDecoder's dropped {stream:true} was exactly this. Each line
// below exercises an option whose effect is OBSERVABLE, so silence shows up as a wrong answer.
const fs = require('fs');
const { Readable, Writable } = require('stream');
const zlib = require('zlib');
const out = [];
const say = (label, value) => out.push(label + ': ' + value);

fs.rmSync('opt', { recursive: true, force: true });
fs.mkdirSync('opt/deep/deeper', { recursive: true });
say('mkdir recursive', fs.existsSync('opt/deep/deeper'));
fs.writeFileSync('opt/a.txt', 'hello');
fs.writeFileSync('opt/deep/b.txt', 'world');
fs.writeFileSync('opt/deep/deeper/c.txt', 'again');

// fs.readdirSync's recursive option (node 20+): silence here means a shallow listing.
say('readdir recursive', JSON.stringify(fs.readdirSync('opt', { recursive: true }).map(String).sort()));
say('readdir withFileTypes', JSON.stringify(fs.readdirSync('opt', { withFileTypes: true })
      .map(d => d.name + (d.isDirectory() ? '/' : '')).sort()));
// encoding as an option vs a bare string.
say('readFile encoding option', JSON.stringify(fs.readFileSync('opt/a.txt', { encoding: 'utf8' })));
say('readFile hex', JSON.stringify(fs.readFileSync('opt/a.txt', 'hex')));
// flag: 'a' must append rather than truncate.
fs.writeFileSync('opt/a.txt', '+more', { flag: 'a' });
say('writeFile flag a', JSON.stringify(fs.readFileSync('opt/a.txt', 'utf8')));
// mode on writeFile, read back through stat.
fs.writeFileSync('opt/m.txt', 'x', { mode: 0o600 });
say('writeFile mode', (fs.statSync('opt/m.txt').mode & 0o777).toString(8));
// rm without recursive must refuse a non-empty directory.
try { fs.rmSync('opt/deep'); say('rm non-recursive', 'ALLOWED'); }
catch (error) { say('rm non-recursive', error.code); }
// force silences a missing path.
try { fs.rmSync('opt/nope', { force: true }); say('rm force missing', 'silent'); }
catch (error) { say('rm force missing', error.code); }

// Stream options with observable effects.
const objects = new Readable({ objectMode: true, read() {} });
objects.push({ a: 1 }); objects.push(null);
say('readable objectMode', JSON.stringify(objects.read()));
const encoded = new Readable({ encoding: 'hex', read() {} });
encoded.push(Buffer.from([0xab, 0xcd])); encoded.push(null);
say('readable encoding option', JSON.stringify(encoded.read()));
const small = new Writable({ highWaterMark: 2, write(c, e, cb) { setTimeout(cb, 5); } });
say('writable highWaterMark respected', small.write('abcd') === false);

// zlib level: 0 must not compress, 9 must compress harder than 1 on repetitive data.
const payload = Buffer.from('ab'.repeat(400));
const none = zlib.gzipSync(payload, { level: 0 }).length;
const nine = zlib.gzipSync(payload, { level: 9 }).length;
say('gzip level 0 is larger than level 9', none > nine);
say('gzip level 0 exceeds input', none > payload.length);
fs.rmSync('opt', { recursive: true, force: true });
console.log(out.join('\n'));
