// SYNC/ASYNC/PROMISE parity. I made the sync fs functions much stricter — ENOENT for a missing
// parent, EEXIST, ENOTDIR, refusing to delete a tree — and never checked that the callback and
// promise forms agree. Three APIs for one operation is three chances to diverge.
const fs = require('fs');
const out = [];
const shape = e => !e ? 'ok' : (e.code || e.name);
const trio = async (label, syncFn, asyncFn, promiseFn) => {
  let s, a, p;
  try { syncFn(); s = 'ok'; } catch (e) { s = shape(e); }
  a = await new Promise(res => { try { asyncFn(e => res(shape(e))); } catch (e) { res('THREW ' + shape(e)); } });
  p = await promiseFn().then(() => 'ok', e => shape(e));
  out.push(label + ': sync=' + s + ' cb=' + a + ' promise=' + p + (s === a && a === p ? '' : '  <-- DIVERGES'));
};

(async () => {
  fs.rmSync('par', { recursive: true, force: true });
  fs.mkdirSync('par');
  fs.writeFileSync('par/f.txt', 'x');
  fs.mkdirSync('par/dir');
  fs.writeFileSync('par/dir/inner.txt', 'y');

  await trio('read missing',
    () => fs.readFileSync('par/nope'),
    cb => fs.readFile('par/nope', cb),
    () => fs.promises.readFile('par/nope'));
  await trio('read a directory',
    () => fs.readFileSync('par/dir'),
    cb => fs.readFile('par/dir', cb),
    () => fs.promises.readFile('par/dir'));
  await trio('mkdir existing',
    () => fs.mkdirSync('par/dir'),
    cb => fs.mkdir('par/dir', cb),
    () => fs.promises.mkdir('par/dir'));
  await trio('mkdir missing parent',
    () => fs.mkdirSync('par/a/b'),
    cb => fs.mkdir('par/a/b', cb),
    () => fs.promises.mkdir('par/a/b'));
  await trio('rm a directory without recursive',
    () => fs.rmSync('par/dir'),
    cb => fs.rm('par/dir', cb),
    () => fs.promises.rm('par/dir'));
  await trio('rm missing without force',
    () => fs.rmSync('par/gone'),
    cb => fs.rm('par/gone', cb),
    () => fs.promises.rm('par/gone'));
  await trio('rmdir non-empty',
    () => fs.rmdirSync('par/dir'),
    cb => fs.rmdir('par/dir', cb),
    () => fs.promises.rmdir('par/dir'));
  await trio('readdir a file',
    () => fs.readdirSync('par/f.txt'),
    cb => fs.readdir('par/f.txt', cb),
    () => fs.promises.readdir('par/f.txt'));
  await trio('rename missing source',
    () => fs.renameSync('par/gone', 'par/other'),
    cb => fs.rename('par/gone', 'par/other', cb),
    () => fs.promises.rename('par/gone', 'par/other'));
  await trio('write into a missing directory',
    () => fs.writeFileSync('par/no/where.txt', 'x'),
    cb => fs.writeFile('par/no/where.txt', 'x', cb),
    () => fs.promises.writeFile('par/no/where.txt', 'x'));
  await trio('copy missing source',
    () => fs.copyFileSync('par/gone', 'par/copy'),
    cb => fs.copyFile('par/gone', 'par/copy', cb),
    () => fs.promises.copyFile('par/gone', 'par/copy'));
  await trio('stat missing',
    () => fs.statSync('par/gone'),
    cb => fs.stat('par/gone', cb),
    () => fs.promises.stat('par/gone'));
  fs.rmSync('par', { recursive: true, force: true });
  console.log(out.join('\n'));
  process.exit(0);
})();
