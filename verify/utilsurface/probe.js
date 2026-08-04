// The public APIs the module-surface audit had been naming as missing, checked against node.
const util = require('util'), events = require('events');
const out = [];
const m = new util.MIMEType('text/html;charset=UTF-8;boundary=x');
out.push('parse: ' + m.type + ' ' + m.subtype + ' ' + m.essence + ' ' + m.toString());
out.push('params: ' + m.params.get('charset') + ' ' + m.params.has('boundary') + ' ' + m.params.get('nope'));
m.params.set('charset', 'iso-8859-1');
out.push('after set: ' + m.toString());
m.params.delete('boundary');
out.push('after delete: ' + m.toString());
out.push('entries: ' + JSON.stringify([...m.params.entries()]));
m.type = 'application'; m.subtype = 'json';
out.push('after retype: ' + m.toString());
for (const t of ['text/plain', 'TEXT/PLAIN', 'text/plain; charset=utf-8', 'a/b;x="quoted;val"', 'image/png;']) {
  out.push('case ' + JSON.stringify(t) + ': ' + new util.MIMEType(t).toString());
}
for (const bad of ['nope', 'a/', '/b', '']) {
  try { new util.MIMEType(bad); out.push('invalid ' + JSON.stringify(bad) + ': NO THROW'); }
  catch (e) { out.push('invalid ' + JSON.stringify(bad) + ': ' + e.constructor.name); }
}
out.push('parseEnv: ' + JSON.stringify(util.parseEnv('A=1\nB="two words"\n# comment\n\nC=three\nD=\n')));
out.push('diff string: ' + JSON.stringify(util.diff('abc', 'abd')));
out.push('diff array: ' + JSON.stringify(util.diff(['a', 'b'], ['a', 'c'])));
out.push('diff same: ' + JSON.stringify(util.diff('ab', 'ab')));
const sites = (function inner() { return util.getCallSites(); })();
out.push('callSites: ' + (sites.length > 0) + ' ' + Object.keys(sites[0]).sort().join(','));
out.push('EventEmitterAsyncResource: ' + typeof events.EventEmitterAsyncResource);
const r = new events.EventEmitterAsyncResource({ name: 'probe' });
let heard = null; r.on('ping', v => { heard = v; }); r.emit('ping', 42);
out.push('emitter half works: ' + (heard === 42) + ' type=' + r.asyncResource.type);
out.push('symbols: ' + typeof events.kMaxEventTargetListeners + ' ' + typeof events.kMaxEventTargetListenersWarned);
console.log(out.join('\n'));
