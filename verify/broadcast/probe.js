const { MessageChannel, receiveMessageOnPort } = require('worker_threads');
const { port1, port2 } = new MessageChannel();
port1.postMessage({ n: 1 });
port1.postMessage({ n: 2 });
console.log('sync drain 1:', JSON.stringify(receiveMessageOnPort(port2)));
console.log('sync drain 2:', JSON.stringify(receiveMessageOnPort(port2)));
console.log('sync drain 3:', JSON.stringify(receiveMessageOnPort(port2)));
console.log('returns undefined when empty:', receiveMessageOnPort(port2) === undefined);
port1.close(); port2.close();

const a = new BroadcastChannel('room');
const b = new BroadcastChannel('room');
const other = new BroadcastChannel('elsewhere');
const heard = [];
b.onmessage = e => heard.push('b:' + e.data);
other.onmessage = e => heard.push('other:' + e.data);
a.onmessage = e => heard.push('a:' + e.data);
a.postMessage('hello');
setTimeout(() => {
  console.log('heard:', heard.join(',') || '(nothing)');
  console.log('sender hears itself:', heard.some(h => h.startsWith('a:')));
  console.log('global BroadcastChannel:', typeof BroadcastChannel);
  a.close(); b.close(); other.close();
}, 50);
