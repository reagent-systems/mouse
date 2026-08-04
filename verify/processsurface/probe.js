// The public half of what the module-surface audit still lists for `process`, plus the two
// entries that genuinely cannot work here and must say so.
const out = [];
const cpu = process.cpuUsage();
out.push('cpuUsage keys: ' + Object.keys(cpu).sort().join(','));
out.push('cpuUsage positive: ' + (cpu.user > 0 || cpu.system > 0));
// Burn some CPU, then confirm the counter MOVED — a stub returning zeros passes a shape check.
let sink = 0; for (let i = 0; i < 4e6; i++) sink += i;
const later = process.cpuUsage();
out.push('cpuUsage advances: ' + (later.user + later.system > cpu.user + cpu.system) + ' (sink ' + (sink > 0) + ')');
const delta = process.cpuUsage(cpu);
out.push('cpuUsage delta keys: ' + Object.keys(delta).sort().join(','));
out.push('cpuUsage delta smaller: ' + (delta.user <= later.user));
const thread = process.threadCpuUsage();
out.push('threadCpuUsage keys: ' + Object.keys(thread).sort().join(','));
out.push('threadCpuUsage delta keys: ' + Object.keys(process.threadCpuUsage(thread)).sort().join(','));
out.push('finalization keys: ' + Object.keys(process.finalization).sort().join(','));
try { process.assert(true, 'fine'); out.push('assert(true): no throw'); }
catch (e) { out.push('assert(true): THREW'); }
try { process.assert(false, 'boom'); out.push('assert(false): NO THROW'); }
catch (e) { out.push('assert(false): ' + e.constructor.name + ' ' + e.message); }
console.log(out.join('\n'));
