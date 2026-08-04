// The SEMANTICS behind the messages: what deep-equal actually decides, and whether an expected
// error is really checked. The old deepStrictEqual was JSON.stringify comparison, and
// assert.throws ignored its expected argument entirely.
const assert = require('assert'), util = require('util');
const t = (label, fn) => { try { fn(); console.log(label + ': pass'); }
                           catch (e) { console.log(label + ': THROW ' + String(e.message).split('\n')[0].slice(0, 46)); } };
t('NaN deep',            () => assert.deepStrictEqual({ x: NaN }, { x: NaN }));
t('key order',           () => assert.deepStrictEqual({ a: 1, b: 2 }, { b: 2, a: 1 }));
t('undef vs missing',    () => assert.deepStrictEqual({ a: undefined }, {}));
t('map',                 () => assert.deepStrictEqual(new Map([[1, 2]]), new Map([[1, 2]])));
t('map differs',         () => assert.deepStrictEqual(new Map([[1, 2]]), new Map([[1, 3]])));
t('map object key',      () => assert.deepStrictEqual(new Map([[{ k: 1 }, 2]]), new Map([[{ k: 1 }, 2]])));
t('set',                 () => assert.deepStrictEqual(new Set([1]), new Set([1])));
t('set differs',         () => assert.deepStrictEqual(new Set([1]), new Set([2])));
t('date',                () => assert.deepStrictEqual(new Date(5), new Date(5)));
t('date differs',        () => assert.deepStrictEqual(new Date(5), new Date(6)));
t('regex',               () => assert.deepStrictEqual(/a/g, /a/g));
t('regex flags differ',  () => assert.deepStrictEqual(/a/g, /a/i));
t('buffer',              () => assert.deepStrictEqual(Buffer.from([1]), Buffer.from([1])));
t('buffer differs',      () => assert.deepStrictEqual(Buffer.from([1]), Buffer.from([2])));
t('circular',            () => { const x = {}; x.self = x; const y = {}; y.self = y; assert.deepStrictEqual(x, y); });
t('proto differs',       () => assert.deepStrictEqual(Object.create(null), {}));
t('loose 1 vs str',      () => assert.deepEqual({ a: 1 }, { a: '1' }));
t('strict 1 vs str',     () => assert.deepStrictEqual({ a: 1 }, { a: '1' }));
t('nested arrays',       () => assert.deepStrictEqual([[1, [2]]], [[1, [2]]]));
t('array length',        () => assert.deepStrictEqual([1, 2], [1, 2, 3]));
t('throws regex match',  () => assert.throws(() => { throw new Error('abc'); }, /b/));
t('throws regex miss',   () => assert.throws(() => { throw new Error('abc'); }, /xyz/));
t('throws class match',  () => assert.throws(() => { throw new TypeError('x'); }, TypeError));
t('throws class miss',   () => assert.throws(() => { throw new TypeError('x'); }, RangeError));
t('throws object match', () => assert.throws(() => { const e = new Error('x'); e.code = 'E1'; throw e; }, { code: 'E1' }));
t('throws object miss',  () => assert.throws(() => { const e = new Error('x'); e.code = 'E1'; throw e; }, { code: 'E2' }));
t('doesNotThrow clean',  () => assert.doesNotThrow(() => {}));
t('isDeepStrictEqual T', () => assert.ok(util.isDeepStrictEqual({ a: [1] }, { a: [1] })));
t('isDeepStrictEqual F', () => assert.ok(!util.isDeepStrictEqual({ a: 1 }, { a: '1' })));
t('isDeep key order',    () => assert.ok(util.isDeepStrictEqual({ a: 1, b: 2 }, { b: 2, a: 1 })));
// The full multi-line messages, byte for byte.
const full = (label, fn) => { try { fn(); } catch (e) { console.log(label + ' MSG ' + JSON.stringify(e.message)); } };
full('strictEqual',        () => assert.strictEqual(4, 5));
full('deepStrictEqual',    () => assert.deepStrictEqual({ a: [1, 2] }, { a: [1, 3] }));
full('deepEqual',          () => assert.deepEqual([1, 2], [1, 2, 3]));
full('notDeepStrictEqual', () => assert.notDeepStrictEqual({ a: 1 }, { a: 1 }));
full('nestedDiff',         () => assert.deepStrictEqual({ a: 1, b: { c: 2 } }, { a: 1, b: { c: 9 } }));
full('throwsClass',        () => assert.throws(() => { throw new TypeError('x'); }, RangeError));
full('doesNotThrow',       () => assert.doesNotThrow(() => { throw new Error('z'); }));
