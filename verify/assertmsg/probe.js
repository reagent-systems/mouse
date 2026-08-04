// An assertion's MESSAGE is its whole product: a test runner prints it and a human reads it to
// find the bug. "not deeply equal" names no value and locates nothing.
const assert = require('assert');
const cases = [
  ['strictEqual num',    () => assert.strictEqual(4, 5)],
  ['strictEqual str',    () => assert.strictEqual('a', 'b')],
  ['strictEqual type',   () => assert.strictEqual(1, '1')],
  ['equal',              () => assert.equal(1, 2)],
  ['notStrictEqual',     () => assert.notStrictEqual(3, 3)],
  ['deepStrictEqual',    () => assert.deepStrictEqual({ a: [1, 2] }, { a: [1, 3] })],
  ['deepEqual arrays',   () => assert.deepEqual([1, 2], [1, 2, 3])],
  ['notDeepStrictEqual', () => assert.notDeepStrictEqual({ a: 1 }, { a: 1 })],
  ['ok false',           () => assert.ok(false)],
  ['ok undefined',       () => assert.ok(undefined)],
  ['assert(0)',          () => assert(0)],
  ['fail',               () => assert.fail()],
  ['fail message',       () => assert.fail('custom')],
  ['custom message',     () => assert.strictEqual(1, 2, 'my message')],
  ['throws no throw',    () => assert.throws(() => {})],
  ['match',              () => assert.match('abc', /xyz/)],
  ['doesNotMatch',       () => assert.doesNotMatch('abc', /b/)],
  ['ifError',            () => assert.ifError(new Error('inner'))],
];
for (const [label, fn] of cases) {
  try { fn(); console.log(label + ' -> NO THROW'); }
  catch (e) {
    // First line of the message, plus the machine-readable fields a runner keys on.
    console.log(label + ' -> ' + e.constructor.name + ' | code=' + e.code +
                ' | op=' + e.operator + ' | gen=' + e.generatedMessage +
                ' | ' + String(e.message).split('\n')[0].slice(0, 70));
  }
}
