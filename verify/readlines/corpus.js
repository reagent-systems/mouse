'use strict';
// readline: how every CLI that is not a full TUI reads input. All of it is drivable from a plain
// stream, so none of this needs a terminal — which is why there is no excuse for the line rules
// never having been compared. The ones that bite are about BOUNDARIES: a line split across two
// chunks, a \r\n arriving as two writes, and a final line with no newline after it at all.
const readline = require('readline');
const readlinePromises = require('readline/promises');
const { PassThrough, Writable } = require('stream');

function line(name, value) { console.log(name + '\t' + value); }
function show(error) {
  if (!error) return String(error);
  if (typeof error !== 'object') return typeof error + ':' + String(error);
  return (error.name || 'Error') + '/' + (error.code || 'no-code');
}
function attempt(name, fn) {
  try { line(name, String(fn())); }
  catch (error) { line(name, 'THREW ' + show(error)); }
}

function collect(write) {
  const input = new PassThrough();
  const rl = readline.createInterface({ input: input });
  const lines = [];
  rl.on('line', (value) => lines.push(value));
  return new Promise((resolve) => {
    rl.on('close', () => resolve(lines));
    write(input);
  });
}

// ---- the escape sequences, which are pure output ------------------------------------------------
attempt('cursor-helpers-write-real-escapes', () => {
  const written = [];
  const out = new Writable({ write(chunk, enc, cb) { written.push(String(chunk)); cb(); } });
  readline.cursorTo(out, 4, 2);
  readline.moveCursor(out, -3, 1);
  readline.clearLine(out, 0);
  readline.clearLine(out, -1);
  readline.clearLine(out, 1);
  readline.clearScreenDown(out);
  return JSON.stringify(written.join('|'));
});

attempt('cursorTo-column-only', () => {
  const written = [];
  const out = new Writable({ write(chunk, enc, cb) { written.push(String(chunk)); cb(); } });
  readline.cursorTo(out, 7);
  return JSON.stringify(written.join(''));
});

attempt('module-surface', () => {
  return ['createInterface', 'cursorTo', 'moveCursor', 'clearLine', 'clearScreenDown',
          'emitKeypressEvents', 'promises'].map((n) => n + '=' + typeof readline[n]).join(' ')
    + ' | promises.createInterface=' + typeof readlinePromises.createInterface;
});

attempt('interface-surface', () => {
  const rl = readline.createInterface({ input: new PassThrough() });
  const shape = ['question', 'close', 'pause', 'resume', 'write', 'prompt', 'setPrompt', 'getPrompt']
    .map((n) => n + '=' + typeof rl[n]).join(' ');
  const extras = ' line=' + JSON.stringify(rl.line) + ' cursor=' + rl.cursor
    + ' terminal=' + rl.terminal + ' iterable=' + (typeof rl[Symbol.asyncIterator]);
  rl.close();
  return shape + extras;
});

async function asyncScenarios() {
  const namedThen = async (name, fn) => {
    try { line(name, String(await fn())); }
    catch (error) { line(name, 'REJECTED ' + show(error)); }
  };

  // ---- where a line ENDS -----------------------------------------------------------------------
  await namedThen('lines-basic', async () => {
    const lines = await collect((input) => { input.end('one\ntwo\nthree\n'); });
    return JSON.stringify(lines);
  });

  await namedThen('trailing-line-without-newline', async () => {
    const lines = await collect((input) => { input.end('alpha\nbeta'); });
    return JSON.stringify(lines);
  });

  await namedThen('crlf', async () => {
    const lines = await collect((input) => { input.end('a\r\nb\r\n'); });
    return JSON.stringify(lines);
  });

  await namedThen('split-across-chunks', async () => {
    const lines = await collect((input) => {
      input.write('par');
      input.write('tial line\nsec');
      input.end('ond\n');
    });
    return JSON.stringify(lines);
  });

  // The hard one: \r and \n arriving in DIFFERENT writes. Treating the \r as its own line break
  // turns one line into two, and the second one is empty.
  await namedThen('crlf-split-across-chunks', async () => {
    const lines = await collect((input) => {
      input.write('first\r');
      setTimeout(() => input.end('\nsecond\n'), 10);
    });
    return JSON.stringify(lines);
  });

  await namedThen('empty-lines-are-lines', async () => {
    const lines = await collect((input) => { input.end('\n\na\n\n'); });
    return JSON.stringify(lines);
  });

  await namedThen('empty-input', async () => {
    const lines = await collect((input) => { input.end(''); });
    return JSON.stringify(lines);
  });

  await namedThen('bare-cr-only', async () => {
    const lines = await collect((input) => { input.end('x\ry\r'); });
    return JSON.stringify(lines);
  });

  // ---- iteration ---------------------------------------------------------------------------------
  await namedThen('async-iteration', async () => {
    const input = new PassThrough();
    const rl = readline.createInterface({ input: input });
    // Written after the loop is running, which is the shape real code has: a line that arrives
    // while the body is busy has to be queued, not dropped.
    setTimeout(() => input.end('i1\ni2\ni3\n'), 10);
    const got = [];
    for await (const value of rl) got.push(value);
    return JSON.stringify(got);
  });

  await namedThen('async-iteration-with-break', async () => {
    const input = new PassThrough();
    const rl = readline.createInterface({ input: input });
    setTimeout(() => input.end('k1\nk2\nk3\n'), 10);
    const got = [];
    for await (const value of rl) { got.push(value); if (got.length === 2) break; }
    return JSON.stringify(got) + ' closed=' + rl.closed;
  });

  // ---- question ------------------------------------------------------------------------------------
  await namedThen('question-callback', async () => {
    const input = new PassThrough();
    const written = [];
    const output = new Writable({ write(chunk, enc, cb) { written.push(String(chunk)); cb(); } });
    const rl = readline.createInterface({ input: input, output: output });
    const answer = await new Promise((resolve) => {
      rl.question('name? ', resolve);
      setTimeout(() => input.write('mouse\n'), 10);
    });
    rl.close();
    return JSON.stringify(answer) + ' prompted=' + JSON.stringify(written.join(''));
  });

  await namedThen('question-promises', async () => {
    const input = new PassThrough();
    const output = new Writable({ write(chunk, enc, cb) { cb(); } });
    const rl = readlinePromises.createInterface({ input: input, output: output });
    setTimeout(() => input.write('answered\n'), 10);
    const answer = await rl.question('q? ');
    rl.close();
    return JSON.stringify(answer);
  });

  await namedThen('question-abort', async () => {
    const input = new PassThrough();
    const output = new Writable({ write(chunk, enc, cb) { cb(); } });
    const rl = readlinePromises.createInterface({ input: input, output: output });
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 10);
    try {
      await rl.question('never? ', { signal: controller.signal });
      rl.close();
      return 'resolved anyway';
    } catch (error) { rl.close(); return 'REJECTED ' + show(error); }
  });

  // node rejects with its OWN AbortError here, discarding whatever reason the caller aborted
  // with — the opposite of timers/promises, which rejects with the reason. Asserted because the
  // two are easy to assume identical.
  await namedThen('question-abort-custom-reason', async () => {
    const input = new PassThrough();
    const output = new Writable({ write(chunk, enc, cb) { cb(); } });
    const rl = readlinePromises.createInterface({ input: input, output: output });
    const controller = new AbortController();
    setTimeout(() => controller.abort(Object.assign(new Error('mine'), { code: 'EMINE' })), 10);
    try {
      await rl.question('never? ', { signal: controller.signal });
      rl.close();
      return 'resolved anyway';
    } catch (error) { rl.close(); return 'REJECTED ' + show(error) + ' ' + JSON.stringify(error.message); }
  });

  await namedThen('question-already-aborted', async () => {
    const input = new PassThrough();
    const output = new Writable({ write(chunk, enc, cb) { cb(); } });
    const rl = readlinePromises.createInterface({ input: input, output: output });
    const controller = new AbortController();
    controller.abort();
    try {
      await rl.question('never? ', { signal: controller.signal });
      rl.close();
      return 'resolved anyway';
    } catch (error) { rl.close(); return 'REJECTED ' + show(error); }
  });

  // ---- prompts and closing --------------------------------------------------------------------------
  await namedThen('setPrompt-and-prompt', async () => {
    const written = [];
    const output = new Writable({ write(chunk, enc, cb) { written.push(String(chunk)); cb(); } });
    const rl = readline.createInterface({ input: new PassThrough(), output: output });
    rl.setPrompt('> ');
    const got = rl.getPrompt();
    rl.prompt();
    rl.close();
    return JSON.stringify(got) + ' wrote=' + JSON.stringify(written.join(''));
  });

  await namedThen('close-is-once', async () => {
    const input = new PassThrough();
    const rl = readline.createInterface({ input: input });
    let closes = 0;
    rl.on('close', () => { closes += 1; });
    rl.close();
    rl.close();
    await new Promise((resolve) => setTimeout(resolve, 20));
    return 'closes=' + closes + ' closed=' + rl.closed;
  });

  await namedThen('lines-stop-after-close', async () => {
    const input = new PassThrough();
    const rl = readline.createInterface({ input: input });
    const seen = [];
    rl.on('line', (value) => seen.push(value));
    input.write('before\n');
    await new Promise((resolve) => setTimeout(resolve, 10));
    rl.close();
    input.write('after\n');
    await new Promise((resolve) => setTimeout(resolve, 20));
    return JSON.stringify(seen);
  });

  await namedThen('pause-and-resume', async () => {
    const input = new PassThrough();
    const rl = readline.createInterface({ input: input });
    const seen = [];
    rl.on('line', (value) => seen.push(value));
    rl.pause();
    input.write('while paused\n');
    await new Promise((resolve) => setTimeout(resolve, 15));
    const duringPause = seen.length;
    rl.resume();
    await new Promise((resolve) => setTimeout(resolve, 20));
    rl.close();
    return 'duringPause=' + duringPause + ' after=' + JSON.stringify(seen);
  });
}

asyncScenarios().then(() => line('done', 'yes'),
                      (error) => line('done', 'FAILED ' + show(error)));
