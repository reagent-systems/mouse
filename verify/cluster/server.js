const cluster = require('cluster');
const http = require('http');
const PORT = Number(process.env.CLUSTER_PORT);

if (cluster.isPrimary) {
  const log = [];
  const watchdog = setTimeout(() => { log.push('WATCHDOG'); console.log(log.join('\n')); process.exit(3); }, 25000);
  log.push('primary: isPrimary=' + cluster.isPrimary + ' isWorker=' + cluster.isWorker);
  let online = 0, listening = 0, greetings = 0;
  const COUNT = 3, REQUESTS = 12;
  const handledBy = {};

  for (let i = 0; i < COUNT; i++) cluster.fork({ WORKER_LABEL: 'w' + i });
  cluster.on('online', () => { online += 1; });
  cluster.on('message', (worker, message) => {
    if (message && message.hello) { greetings += 1; worker.send({ ack: worker.id }); }
  });

  cluster.on('listening', () => {
    listening += 1;
    if (listening < COUNT) return;
    log.push('workers online=' + online + ' listening=' + listening);
    log.push('worker ids: ' + Object.keys(cluster.workers).join(','));

    // CONCURRENT requests: round-robin only spreads work when there is work to spread. All of
    // them go to one port, which only the primary ever bound.
    let done = 0, bad = 0;
    for (let i = 0; i < REQUESTS; i++) {
      http.get({ port: PORT, path: '/who' }, res => {
        let body = '';
        res.on('data', c => body += c);
        res.on('end', () => {
          const parsed = JSON.parse(body);
          handledBy[parsed.id] = (handledBy[parsed.id] || 0) + 1;
          if (parsed.label !== 'w' + (parsed.id - 1)) bad += 1;
          if (++done === REQUESTS) finish();
        });
      }).on('error', e => { log.push('request error ' + e.code); clearTimeout(watchdog); console.log(log.join('\n')); process.exit(1); });
    }

    const finish = () => {
      const used = Object.keys(handledBy);
      log.push('requests answered: ' + done);
      log.push('all answers carried the right forked env: ' + (bad === 0));
      log.push('work reached more than one worker: ' + (used.length > 1));
      log.push('total across workers: ' + used.reduce((n, k) => n + handledBy[k], 0));
      log.push('greetings received: ' + greetings);

      // Losing a worker must not lose the PORT: the listening socket is the primary's. A
      // connection already handed to the dying worker can still reset — real node does that
      // too — so this retries, which is what any client would do.
      if (process.env.NO_KILL) {
        clearTimeout(watchdog);
        console.log(log.join('\n'));
        process.exit(0);
      }
      const victim = cluster.workers[Number(used.sort()[0])];
      victim.once('exit', () => {
        log.push('worker exited, alive now: ' + Object.keys(cluster.workers).length);
        let tries = 0;
        const probe = () => {
          tries += 1;
          http.get({ port: PORT, path: '/after' }, res => {
            let body = '';
            res.on('data', c => body += c);
            res.on('end', () => {
              log.push('served after a worker died: ' + (JSON.parse(body).ok === true));
              cluster.disconnect(() => {
                log.push('all workers disconnected: ' + (Object.keys(cluster.workers).length === 0));
                clearTimeout(watchdog);
                console.log(log.join('\n'));
                process.exit(0);
              });
            });
          }).on('error', () => {
            if (tries < 5) return setTimeout(probe, 100);
            log.push('served after a worker died: false');
            clearTimeout(watchdog);
            console.log(log.join('\n'));
            process.exit(1);
          });
        };
        probe();
      });
      victim.kill();
    };
  });
} else {
  process.send({ hello: cluster.worker.id });
  const id = cluster.worker.id;
  http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ id: id, label: process.env.WORKER_LABEL, ok: true }));
  }).listen(PORT);
}
