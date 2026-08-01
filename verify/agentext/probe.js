// An Agent subclass that overrides createConnection is how EVERY proxy agent works: the socket
// it returns goes somewhere other than the requested host. If the client ignores the override,
// the agent is inert and the request quietly goes direct — which is a security-relevant silent
// failure, not just a missing feature.
const http = require('http'), https = require('https'), net = require('net');
const out = [];
// Each protocol keeps its own global agent, and callers read these to decide a default port.
out.push('http globalAgent: ' + http.globalAgent.protocol + ' ' + http.globalAgent.defaultPort);
out.push('https globalAgent: ' + https.globalAgent.protocol + ' ' + https.globalAgent.defaultPort);
out.push('distinct Agent classes: ' + (https.Agent !== http.Agent));

// Two servers. The request asks for A; the agent hands back a socket to B.
const real = http.createServer((req, res) => { res.end('REAL'); });
const decoy = http.createServer((req, res) => { res.end('DECOY'); });

real.listen(0, '127.0.0.1', () => decoy.listen(0, '127.0.0.1', () => {
  const realPort = real.address().port, decoyPort = decoy.address().port;
  class RoutingAgent extends http.Agent {
    createConnection(options) {
      out.push('createConnection saw the requested port: ' + (options.port === decoyPort));
      return net.connect({ host: '127.0.0.1', port: realPort });
    }
  }
  const agent = new RoutingAgent({ keepAlive: false });
  out.push('agent reports: protocol=' + agent.protocol + ' defaultPort=' + agent.defaultPort +
           ' maxTotalSockets=' + agent.maxTotalSockets + ' totalSocketCount=' + agent.totalSocketCount);
  // Ask for the DECOY; the agent must redirect us to the real one.
  http.get({ host: '127.0.0.1', port: decoyPort, agent: agent }, (res) => {
    let body = '';
    res.on('data', c => { body += c; });
    res.on('end', () => {
      out.push('body came from: ' + body);
      out.push('agent was used: ' + (body === 'REAL'));
      real.close(); decoy.close();
      console.log(out.join('\n'));
    });
  });
}));
