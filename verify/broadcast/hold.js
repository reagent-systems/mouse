const { Worker, BroadcastChannel } = require('worker_threads');
const channel = new BroadcastChannel('late');
channel.onmessage = event => {
  console.log('heard while only the channel held the loop:', event.data);
  channel.close();
};
// unref'd: this worker is NOT what keeps the process alive.
new Worker('./lw.js').unref();
