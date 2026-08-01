const { BroadcastChannel } = require('worker_threads');
// Deliberately late: if the channel does not hold the main thread's loop, main exits first.
setTimeout(() => {
  const channel = new BroadcastChannel('late');
  channel.postMessage('arrived');
  channel.close();
}, 300);
