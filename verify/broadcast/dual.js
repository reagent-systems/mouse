const wt = require('worker_threads');
const { MessageChannel, receiveMessageOnPort } = wt;
console.log('globals are the module classes:',
  wt.MessagePort === globalThis.MessagePort,
  wt.MessageChannel === globalThis.MessageChannel,
  wt.BroadcastChannel === globalThis.BroadcastChannel);

// All three surfaces fire for one message; EventEmitter gets the raw value.
const { port1, port2 } = new MessageChannel();
const log = [];
port2.on('message', v => log.push('on:' + JSON.stringify(v)));
port2.addEventListener('message', e => log.push('ael:' + JSON.stringify(e.data)));
port2.onmessage = e => log.push('onmessage:' + JSON.stringify(e.data));
port1.postMessage({ a: 1 });

setTimeout(() => {
  console.log(log.sort().join(' | '));

  // A GLOBAL channel's port must work with the module's synchronous drain — the whole point
  // of there being one class.
  const global = new globalThis.MessageChannel();
  global.port1.postMessage('from-global');
  console.log('global port drains:', JSON.stringify(receiveMessageOnPort(global.port2)));
  global.port1.close(); global.port2.close();

  // onmessage alone starts a port that had no listener at all.
  const late = new MessageChannel();
  late.port1.postMessage('queued-first');
  late.port2.onmessage = e => {
    console.log('onmessage alone started it:', e.data);
    late.port1.close(); late.port2.close();
    port1.close(); port2.close();
  };
}, 40);
