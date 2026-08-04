// Byte-vs-character confusion, probed rather than theorised. An IDE moves USER text: emoji,
// CJK, combining marks, and astral-plane characters that are two UTF-16 units each.
const fs = require('fs'), path = require('path'), os = require('os');
const out = [];
const samples = {
  ascii: 'hello',
  cjk: '日本語テキスト',
  emoji: '🎉🚀',
  zwj: '👨‍👩‍👧',          // one grapheme, several code points joined
  combining: 'é',       // e + combining acute
  astral: '𝕳𝖊𝖑𝖑𝖔',
  mixed: 'a日🎉b',
  rtl: 'مرحبا',
};
for (const [name, text] of Object.entries(samples)) {
  const buf = Buffer.from(text, 'utf8');
  out.push(name + ' len=' + text.length + ' points=' + [...text].length +
           ' bytes=' + Buffer.byteLength(text) + ' bufLen=' + buf.length +
           ' roundtrip=' + (buf.toString('utf8') === text));
}
// File I/O must not corrupt any of it, including in the FILENAME.
for (const [name, text] of Object.entries(samples)) {
  // A relative directory, so this runs the same on the host and on the workspace-virtual root.
  fs.mkdirSync('u', { recursive: true });
  const base = 'f-' + name + '-' + text.slice(0, 3) + '.txt';
  const file = 'u/' + base;
  try {
    fs.writeFileSync(file, text);
    const back = fs.readFileSync(file, 'utf8');
    const stat = fs.statSync(file);
    out.push('io ' + name + ' same=' + (back === text) + ' size=' + stat.size +
             ' listed=' + fs.readdirSync('u').includes(base));
  } catch (e) { out.push('io ' + name + ' THREW ' + e.code); }
}
// Slicing a Buffer mid-character and decoding the halves separately: the classic corruption.
const emoji = Buffer.from('🎉🚀', 'utf8');
out.push('split decode: ' + JSON.stringify(emoji.slice(0, 3).toString('utf8') + '|' + emoji.slice(3).toString('utf8')));
const { StringDecoder } = require('string_decoder');
const d = new StringDecoder('utf8');
out.push('StringDecoder holds: ' + JSON.stringify(d.write(emoji.slice(0, 3)) + d.write(emoji.slice(3))));
// Encodings that cannot represent the text must degrade the way node's do.
out.push('latin1 lossy: ' + JSON.stringify(Buffer.from('日', 'latin1').toString('latin1')));
out.push('ascii lossy: ' + JSON.stringify(Buffer.from('🎉', 'ascii').toString('ascii')));
out.push('base64 rt: ' + (Buffer.from(Buffer.from('🎉日', 'utf8').toString('base64'), 'base64').toString('utf8') === '🎉日'));
out.push('hex rt: ' + (Buffer.from(Buffer.from('🎉日').toString('hex'), 'hex').toString('utf8') === '🎉日'));
// Paths and URLs.
out.push('basename: ' + path.basename('/a/日本🎉.txt'));
out.push('pathToFileURL: ' + require('url').pathToFileURL('/a/日本🎉.txt').href);
out.push('JSON rt: ' + (JSON.parse(JSON.stringify({ t: '🎉日́' })).t === '🎉日́'));
console.log(out.join('\n'));
