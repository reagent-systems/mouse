// The ERROR CODE audit. Real code branches on error.code — `if (e.code === 'ENOENT') create()` —
// so a missing or wrong code silently takes the wrong path, which is worse than a wrong message.
// Each case is isolated; each reports code + syscall so a near-miss is visible.
const fs = require('fs');
const net = require('net');
const out = [];
const shape = e => !e ? 'NO ERROR' : [e.code || '(no code)', e.syscall || '-'].join(' ');
const check = (label, fn) => {
  try { fn(); out.push(label + ': NO ERROR'); }
  catch (error) { out.push(label + ': ' + shape(error)); }
};
const acheck = (label, build) => new Promise(resolve => {
  let settled = false;
  const finish = e => { if (!settled) { settled = true; out.push(label + ': ' + shape(e)); resolve(); } };
  setTimeout(() => finish({ code: 'NEVER SETTLED' }), 1000);
  try { build(finish); } catch (e) { finish(e); }
});

fs.rmSync('ec', { recursive: true, force: true });
fs.mkdirSync('ec');
fs.writeFileSync('ec/file.txt', 'x');

check('readFileSync missing', () => fs.readFileSync('ec/nope.txt'));
check('readFileSync on a directory', () => fs.readFileSync('ec'));
check('statSync missing', () => fs.statSync('ec/nope.txt'));
check('mkdirSync existing', () => fs.mkdirSync('ec'));
check('mkdirSync missing parent', () => fs.mkdirSync('ec/a/b/c'));
check('unlinkSync missing', () => fs.unlinkSync('ec/nope.txt'));
check('rmdirSync a file', () => fs.rmdirSync('ec/file.txt'));
check('readdirSync a file', () => fs.readdirSync('ec/file.txt'));
check('renameSync missing source', () => fs.renameSync('ec/nope.txt', 'ec/other.txt'));
check('openSync missing, read mode', () => fs.openSync('ec/nope.txt', 'r'));
check('writeFileSync into a missing dir', () => fs.writeFileSync('ec/no/where.txt', 'x'));
check('accessSync missing', () => fs.accessSync('ec/nope.txt'));
check('copyFileSync missing source', () => fs.copyFileSync('ec/nope.txt', 'ec/copy.txt'));
check('JSON.parse bad input', () => JSON.parse('{oops'));

(async () => {
  await acheck('connect refused', finish => {
    // Port 1 is reserved and never listening.
    const socket = net.connect(1, '127.0.0.1');
    socket.on('error', finish);
    socket.on('connect', () => finish(null));
  });
  await acheck('lookup bogus host', finish => {
    require('dns').lookup('nope.invalid', error => finish(error));
  });
  await acheck('readFile callback missing', finish => {
    fs.readFile('ec/nope.txt', error => finish(error));
  });
  await acheck('promises readFile missing', finish => {
    fs.promises.readFile('ec/nope.txt').then(() => finish(null)).catch(finish);
  });
  fs.rmSync('ec', { recursive: true, force: true });
  console.log(out.join('\n'));
  process.exit(0);
})();
