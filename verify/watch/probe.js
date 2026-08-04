// What does real node actually emit? Measure before asserting.
const fs = require('fs');
const path = require('path');
const events = [];
fs.mkdirSync('dir', { recursive: true });
fs.writeFileSync('dir/existing.txt', 'one');
const dirWatcher = fs.watch('dir', (type, name) => events.push('dir:' + type + ':' + name));
const fileWatcher = fs.watch('dir/existing.txt', (type, name) => events.push('file:' + type + ':' + name));
const steps = [
  () => fs.writeFileSync('dir/existing.txt', 'two'),
  () => fs.writeFileSync('dir/created.txt', 'new'),
  () => fs.unlinkSync('dir/created.txt'),
  () => fs.mkdirSync('dir/sub'),
];
let i = 0;
function step() {
  if (i < steps.length) { steps[i++](); setTimeout(step, 300); return; }
  setTimeout(() => {
    dirWatcher.close();
    fileWatcher.close();
    console.log(events.join('\n'));
    process.exit(0);
  }, 300);
}
setTimeout(step, 300);
