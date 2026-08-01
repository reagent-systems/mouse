const fs = require('fs');
fs.rmSync('p2', { recursive: true, force: true });
fs.mkdirSync('p2');
fs.writeFileSync('p2/f.txt', 'data');
// Does rmdirSync on a FILE delete it?
try { fs.rmdirSync('p2/f.txt'); } catch (e) {}
console.log('file still there after rmdir on it: ' + fs.existsSync('p2/f.txt'));
// Does writeFileSync into a missing directory actually write anything?
try { fs.writeFileSync('p2/missing/deep.txt', 'x'); } catch (e) { console.log('writeFile threw: ' + e.code); }
console.log('nested file exists: ' + fs.existsSync('p2/missing/deep.txt'));
// Does mkdirSync create a whole tree without recursive?
try { fs.mkdirSync('p2/a/b/c'); } catch (e) { console.log('mkdir threw: ' + e.code); }
console.log('tree created without recursive: ' + fs.existsSync('p2/a/b/c'));
fs.rmSync('p2', { recursive: true, force: true });
