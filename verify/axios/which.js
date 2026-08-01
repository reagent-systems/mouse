const axios = require('./project/node_modules/axios');
const out = [];
out.push('default adapter list: ' + JSON.stringify(axios.defaults.adapter));
// Which adapters does this environment report as usable?
const adapters = require('./project/node_modules/axios/lib/adapters/adapters.js').default
  || require('./project/node_modules/axios/lib/adapters/adapters.js');
try {
  for (const name of ['xhr', 'http', 'fetch']) {
    const a = adapters.adapters ? adapters.adapters[name] : undefined;
    out.push(name + ': ' + (a === undefined ? 'undefined' : (a === false ? 'false' : typeof a)));
  }
} catch (e) { out.push('adapter table: ' + e.message.slice(0, 60)); }
out.push('has fetch global: ' + (typeof fetch));
out.push('process kind: ' + Object.prototype.toString.call(process));
console.log(out.join('\n'));
