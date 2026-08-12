const url = require('url');
const out = [];
const paths = ['/a/b.js', '/a/b c.js', '/a/b#c.js', '/a/b?c.js', '/a/%.js', '/dir/', '/',
               '/a/b&c=d.js', "/a/b'c.js", '/a/ünïcode.js', '/a/b\tc.js', '/a/plus+.js',
               '/a/b%20already.js', '/deep/nested/path/to/mod.mjs', '/a/[br].js', '/a/b;c.js'];
for (const p of paths) {
  const u = url.pathToFileURL(p);
  out.push('to   ' + JSON.stringify(p) + ' -> ' + u.href + ' | URL=' + (u instanceof URL));
  out.push('back ' + JSON.stringify(p) + ' -> ' + JSON.stringify(url.fileURLToPath(u.href)) +
           ' | roundtrip=' + (url.fileURLToPath(u.href) === p));
}
// searchParams is why eslint needs a real URL: cache-busting an ESM config import by mtime.
const u = url.pathToFileURL('/cfg/eslint.config.mjs');
u.searchParams.append('mtime', '12345');
out.push('cachebust ' + u.href);
const w = url.pathToFileURL('/a/b c.js'); w.searchParams.append('mtime', '7');
out.push('cachebust encoded ' + w.href);
// fileURLToPath accepts a URL object as well as a string.
out.push('accepts URL object ' + url.fileURLToPath(url.pathToFileURL('/a/b c.js')));
out.push('accepts localhost ' + url.fileURLToPath('file://localhost/a/b.js'));
// `file:` is a SPECIAL scheme: one slash after it is the same URL as three, and `localhost`
// IS the empty host. esbuild's import.meta.url polyfill writes the one-slash form — it is
// literally `new URL('file:' + __filename)` — and lightningcss-wasm reads its own .wasm through
// the result, so a URL left at `file:/…` reached fs as a filename beginning with "file:".
for (const one of ['file:/a/b.js', 'file:', 'file://localhost/a/b.js']) {
  const u = new URL(one);
  out.push('special ' + one + ' -> ' + u.href + ' host=' + JSON.stringify(u.host) + ' origin=' + u.origin);
}
out.push('special relative ' + new URL('c.wasm', 'file:/a/b/i.js').href);
out.push('special toPath ' + url.fileURLToPath('file:/a/b.js'));

// And rejects what is not a file URL.
for (const bad of ['https://example.com/a', 'file://otherhost/a']) {
  try { url.fileURLToPath(bad); out.push('reject ' + bad + ' -> NO THROW'); }
  catch (e) { out.push('reject ' + bad + ' -> ' + e.code); }
}
console.log(out.join('\n'));
