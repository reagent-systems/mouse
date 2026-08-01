const { Worker, BroadcastChannel } = require('worker_threads');
const channel = new BroadcastChannel('room');
const seen = [];
const watchdog = setTimeout(() => { console.log('WATCHDOG', seen.join(',')); process.exit(3); }, 20000);
channel.onmessage = event => {
  seen.push(String(event.data));
  if (seen.filter(s => s.startsWith('ready')).length === 2 && !seen.includes('sent-ping')) {
    seen.push('sent-ping');
    channel.postMessage('ping');
  }
  if (seen.filter(s => s.startsWith('pong')).length === 2) {
    channel.postMessage('stop');
    setTimeout(() => {
      console.log('ready messages:', seen.filter(s => s.startsWith('ready')).sort().join(','));
      console.log('pongs:', seen.filter(s => s.startsWith('pong')).sort().join(','));
      console.log('main never heard its own ping:', !seen.includes('ping'));
      clearTimeout(watchdog);
      channel.close();
      workers.forEach(w => w.terminate());
    }, 80);
  }
};
const workers = [1, 2].map(id => new Worker('./w.js', { workerData: { id } }));
