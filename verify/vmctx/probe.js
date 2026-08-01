// node's vm contract, checked point by point. A contextified sandbox has its own global, its
// own built-ins, no view of the host's globals, and LIVE reads and writes against the object.
const vm = require('vm');
const out = [];
const sandbox = { a: 1, f: (n) => n * 2 };
const context = vm.createContext(sandbox);
out.push('isContext: ' + vm.isContext(context) + ' ' + vm.isContext({}));
out.push('read across: ' + vm.runInContext('a', context));
out.push('call across: ' + vm.runInContext('f(21)', context));
vm.runInContext('b = a + 41', context);
out.push('write lands on sandbox: ' + sandbox.b);
sandbox.a = 10;
out.push('live read after outside write: ' + vm.runInContext('a', context));
vm.runInContext('a = 99', context);
out.push('inside write visible outside: ' + sandbox.a);
out.push('own builtins: ' + vm.runInContext('typeof JSON + "," + typeof Math + "," + typeof Promise', context));
out.push('this is global: ' + vm.runInContext('this === globalThis', context));
out.push('returns objects: ' + vm.runInContext('({x: 7})', context).x);
out.push('returns functions: ' + (typeof vm.runInContext('(function(){ return 5 })', context)));
out.push('throw propagates: ' + (() => { try { vm.runInContext('throw new Error("in-vm")', context); return 'NO THROW'; }
                                          catch (e) { return e.message; } })());
out.push('syntax error: ' + (() => { try { vm.runInContext('function(', context); return 'NO THROW'; }
                                      catch (e) { return e.constructor.name; } })());
out.push('runInNewContext: ' + vm.runInNewContext('g(3)', { g: (n) => n + 1 }));
out.push('separate contexts: ' + (() => { const c1 = vm.createContext({}), c2 = vm.createContext({});
  vm.runInContext('z = 1', c1); return vm.runInContext('typeof z', c2); })());
out.push('Script reuse: ' + (() => { const s = new vm.Script('a * 2');
  return s.runInContext(context) + ',' + s.runInContext(vm.createContext({ a: 4 })); })());
out.push('runInThisContext: ' + vm.runInThisContext('1 + 1'));
out.push('compileFunction: ' + vm.compileFunction('return p + q', ['p', 'q'])(2, 3));
out.push('nested objects cross: ' + vm.runInContext('JSON.stringify({n: [1, {m: 2}]})', context));
console.log(out.join('\n'));
