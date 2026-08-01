'use strict';
// `util.inspect.defaultOptions` and the `[util.inspect.custom]` hook — the two things n8n's bin
// touches in its first 31 lines, and neither existed. The hook is the interesting one: a type's
// own opinion of how it prints, which we never once called, so every package that defines one
// was printing its raw fields instead. `customInspect: false` is only meaningful as a way to
// turn something OFF, so proving the flag works means proving the default is on.
const util = require('util');

function line(name, value) { console.log(name + '\t' + value); }
function attempt(name, fn) {
  try { line(name, String(fn())); }
  catch (error) { line(name, 'THREW ' + (error && (error.name + '/' + error.message))); }
}

attempt('defaultOptions-exists', () => typeof util.inspect.defaultOptions);
attempt('defaultOptions-keys', () => Object.keys(util.inspect.defaultOptions).sort().join(','));
attempt('defaultOptions-values', () => JSON.stringify(util.inspect.defaultOptions));
attempt('custom-symbol', () => String(util.inspect.custom));

const withHook = { plain: 1, [util.inspect.custom](depth, options) { return 'HOOK<' + depth + '>'; } };

attempt('hook-is-called', () => util.inspect(withHook));
attempt('hook-sees-depth', () => util.inspect(withHook, { depth: 5 }));
attempt('hook-off-per-call', () => util.inspect(withHook, { customInspect: false }).indexOf('HOOK') >= 0);
attempt('hook-via-console-format', () => util.format('%s', withHook).indexOf('HOOK') >= 0);

attempt('hook-returning-an-object', () => {
  // A non-string return is FORMATTED, not stringified — the difference between `{ a: 1 }` and
  // `[object Object]`.
  const value = { [util.inspect.custom]() { return { a: 1, b: [2, 3] }; } };
  return util.inspect(value);
});

attempt('hook-on-a-nested-value', () => {
  return util.inspect({ outer: withHook });
});

attempt('defaultOptions-mutation-takes-effect', () => {
  util.inspect.defaultOptions.customInspect = false;
  const off = util.inspect(withHook).indexOf('HOOK') >= 0;
  util.inspect.defaultOptions.customInspect = true;
  const on = util.inspect(withHook).indexOf('HOOK') >= 0;
  return 'whileOff=' + off + ' whenRestored=' + on;
});

attempt('defaultOptions-depth-mutation', () => {
  const deep = { a: { b: { c: { d: { e: 1 } } } } };
  const atTwo = util.inspect(deep);
  util.inspect.defaultOptions.depth = 4;
  const atFour = util.inspect(deep);
  util.inspect.defaultOptions.depth = 2;
  return 'differs=' + (atTwo !== atFour) + ' deeperShowsMore=' + (atFour.length > atTwo.length);
});

attempt('per-call-beats-default', () => {
  util.inspect.defaultOptions.depth = 0;
  const explicit = util.inspect({ a: { b: { c: 1 } } }, { depth: 3 });
  util.inspect.defaultOptions.depth = 2;
  return explicit;
});

// The legacy positional forms must keep meaning what they meant.
attempt('positional-depth', () => util.inspect({ a: { b: { c: { d: 1 } } } }, 0));
attempt('no-options', () => util.inspect({ a: { b: { c: { d: 1 } } } }));
attempt('plain-values', () => [
  util.inspect('text'), util.inspect(42), util.inspect(null), util.inspect(undefined),
  util.inspect([1, 2, 3]), util.inspect(new Date(0)),
].join(' | '));
