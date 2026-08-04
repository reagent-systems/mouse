const { BroadcastChannel, workerData } = require('worker_threads');
const channel = new BroadcastChannel('room');
channel.onmessage = event => {
  if (event.data === 'ping') channel.postMessage('pong from ' + workerData.id);
  if (event.data === 'stop') channel.close();
};
channel.postMessage('ready:' + workerData.id);
