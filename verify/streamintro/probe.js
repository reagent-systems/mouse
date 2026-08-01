// The stream introspection getters the shapes sweep listed across six different rows. They tell
// a consumer whether a stream was CUT SHORT or completed — the difference between a truncated
// body and a whole one.
const { Readable, Writable } = require('stream');
const out = [];
const r = new Readable({ read() { this.push('x'); this.push(null); } });
out.push('readableAborted before: ' + r.readableAborted);
out.push('readableDidRead before: ' + r.readableDidRead);
r.on('data', () => {});
setTimeout(() => {
  out.push('readableDidRead after reading: ' + r.readableDidRead);
  out.push('readableAborted after full read: ' + r.readableAborted);
  const w = new Writable({ write(c, e, cb) { cb(); } });
  out.push('writableAborted before: ' + w.writableAborted);
  w.destroy();
  const d = new Readable({ read() {} });
  d.destroy();
  setTimeout(() => {
    out.push('writableAborted after destroy: ' + w.writableAborted);
    out.push('readableAborted after destroy: ' + d.readableAborted);
    out.push('unread stream didRead: ' + new Readable({ read() {} }).readableDidRead);
    console.log(out.join('\n'));
  }, 10);
}, 10);
