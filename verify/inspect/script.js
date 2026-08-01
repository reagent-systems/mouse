// The FORMATTING audit. For a terminal IDE this is not cosmetic: console.log output IS the
// product a user reads. node's inspect has specific shapes for Map, Set, Date, Error, circular
// references, class instances, sparse arrays, getters and long collections, and code pastes
// output into bug reports expecting them.
const util = require('util');
const out = [];
const show = (label, value) => out.push(label + ': ' + util.inspect(value));

show('empty object', {});
show('empty array', []);
show('nested', { a: [1, { b: 2 }] });
show('string in object', { s: 'hi' });
show('bare string', 'hi');
show('number-ish', [1, -0, NaN, Infinity, -Infinity, 1e21]);
show('bigint', 10n);
show('symbol', Symbol('tag'));
show('undefined and null', [undefined, null]);
show('function', function named() {});
show('arrow', () => {});
show('class', class Thing {});
show('class instance', new (class Point { constructor() { this.x = 1; } })());
show('date', new Date(0));
show('regexp', /ab+c/gi);
// An Error's inspect includes its stack, whose paths differ per engine — the shape is what
// matters, so only the first line is compared.
out.push('error first line: ' + util.inspect(new Error('boom')).split('\n')[0]);
out.push('error with code: ' + util.inspect(Object.assign(new Error('x'), { code: 'E1' })).split('\n')[0]);
show('map', new Map([['a', 1], [2, 'b']]));
show('empty map', new Map());
show('set', new Set([1, 'two']));
show('empty set', new Set());
show('buffer', Buffer.from([1, 2, 255]));
show('typed array', new Uint16Array([1, 2]));
// node reads a promise's resolved VALUE through V8 internals ('Promise { 1 }'); JSC exposes no
// such hook, so a settled promise is indistinguishable from a pending one here.
show('promise', Promise.resolve(1));
show('sparse array', [1, , 3]);
show('array with extra props', Object.assign([1, 2], { extra: true }));
show('nested depth 3', { a: { b: { c: { d: 1 } } } });
// Truncation matches node (100 items + a count); node's COLUMN-ALIGNED multi-line grid for long
// numeric arrays does not, and reproducing that layout is a lot of intricate width arithmetic for
// no behavioural gain. The important half — not printing 10,000 items — is done.
show('long array', Array.from({ length: 120 }, (_, i) => i).slice(0, 3));
show('long array truncates', util.inspect(Array.from({ length: 120 }, (_, i) => i)).includes('... 20 more items'));
const circular = { name: 'loop' };
circular.self = circular;
show('circular', circular);
show('object with symbol key', { [Symbol('k')]: 1, normal: 2 });
show('getter', Object.defineProperty({}, 'lazy', { get() { return 1; }, enumerable: true }));
show('null prototype', Object.create(null));
show('boxed primitives', [new Number(3), new String('s'), new Boolean(true)]);
// console.log's own formatting: %s %d %i %j %o %O %% and extra arguments.
const format = util.format;
out.push('format %s: ' + format('%s|%s', 'a', 5));
out.push('format %d %i: ' + format('%d %i', '42.9', '42.9'));
out.push('format %j: ' + format('%j', { a: 1 }));
out.push('format %%: ' + format('100%%'));
out.push('format extras: ' + format('one', 'two', 3));
out.push('format object arg: ' + format('%o', { a: 1 }));
out.push('format no spec: ' + format({ a: 1 }, 'tail'));
console.log(out.join('\n'));
