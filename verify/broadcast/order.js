const { MessageChannel } = require('worker_threads');
// Port delivery is its own loop phase in node: after nextTick and microtasks, before immediates.
const a = new MessageChannel();
const first = [];
a.port2.on('message', () => first.push('port'));
process.nextTick(() => first.push('nextTick'));
setImmediate(() => first.push('setImmediate'));
Promise.resolve().then(() => first.push('promise'));
a.port1.postMessage(1);

setTimeout(() => {
  console.log('post last: ', first.join(' -> '));
  // And the harder case: everything queued AFTER the postMessage still runs before the port.
  const b = new MessageChannel();
  const second = [];
  b.port2.on('message', () => second.push('port'));
  b.port1.postMessage(1);
  Promise.resolve().then(() => second.push('promise-after-post'));
  process.nextTick(() => second.push('nextTick-after-post'));
  setTimeout(() => {
    console.log('post first: ', second.join(' -> '));
    a.port1.close(); a.port2.close(); b.port1.close(); b.port2.close();
  }, 20);
}, 20);
