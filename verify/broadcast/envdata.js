const w = require('worker_threads');
w.setEnvironmentData('k', 'v');
console.log('parent reads back:', w.getEnvironmentData('k'));
console.log('unset key is undefined:', w.getEnvironmentData('nope') === undefined);
const worker = new w.Worker(
  'const w=require("worker_threads"); w.parentPort.postMessage({inherited:w.getEnvironmentData("k"), late:w.getEnvironmentData("late")});',
  { eval: true });
w.setEnvironmentData('late', 'after-spawn');   // too late for this worker, as node has it
worker.on('message', message => {
  console.log('worker saw:', JSON.stringify(message));
  w.setEnvironmentData('k');                    // omitted value deletes
  console.log('deleted:', w.getEnvironmentData('k') === undefined);
  worker.terminate();
});
