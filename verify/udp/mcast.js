// Multicast on the loopback interface: join a group, send to it, and receive your own packet
// because loopback is on. If the platform refuses multicast on lo0 both engines say so equally.
const dgram = require('dgram');
const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
const group = '239.255.42.99';
const seen = [];
socket.on('message', (message, rinfo) => {
  seen.push(String(message) + '@' + (rinfo.port > 0 ? 'port' : 'noport'));
  console.log('received: ' + seen.join(' | '));
  socket.close();
});
socket.bind(Number(process.argv[2]), () => {
  try {
    socket.setMulticastInterface('127.0.0.1');
    socket.setMulticastLoopback(true);
    socket.setMulticastTTL(1);
    socket.addMembership(group, '127.0.0.1');
    console.log('joined ' + group);
    socket.send('hello group', Number(process.argv[2]), group, error => {
      if (error) { console.log('send failed: ' + error.code); socket.close(); }
    });
  } catch (error) {
    console.log('multicast refused: ' + error.code);
    socket.close();
  }
});
setTimeout(() => { console.log('no packet: ' + seen.length); process.exit(0); }, 2500);
