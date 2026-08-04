// A port moved into a vm context. The refusal for this read "contexts are separate engines with
// no shared memory" — true when a vm context WAS another engine, and expired the moment they
// became a second JSContext in the same virtual machine.
const { MessageChannel, moveMessagePortToContext } = require('worker_threads');
const vm = require('vm');
const out = [];
const ctx = vm.createContext({});
const { port1, port2 } = new MessageChannel();
const moved = moveMessagePortToContext(port2, ctx);
// node returns the WEB-shaped port: postMessage and onmessage, no EventEmitter surface.
out.push('shape: post=' + typeof moved.postMessage + ' on=' + typeof moved.on +
         ' close=' + typeof moved.close + ' start=' + typeof moved.start);
let heard = 0;
port1.on('message', m => { out.push('peer received: ' + JSON.stringify(m)); heard++; });
moved.onmessage = (event) => { out.push('moved heard: ' + JSON.stringify(event.data)); heard++; };
// A web-shaped port stays closed until it is STARTED — assigning onmessage is not enough here,
// which is the detail that separates node's behaviour from a plausible guess at it.
moved.start();
moved.postMessage({ from: 'moved' });
port1.postMessage({ from: 'peer' });
// A non-context second argument must be refused the way node refuses it.
try { moveMessagePortToContext(port1, {}); out.push('bad context: NO THROW'); }
catch (e) { out.push('bad context: ' + e.code); }
setTimeout(() => { port1.close(); out.push('both directions: ' + (heard === 2)); console.log(out.sort().join('\n')); }, 300);
