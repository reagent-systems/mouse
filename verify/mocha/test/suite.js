const assert = require('assert');
describe('sync', function () {
  before(function () { this.shared = 1; });
  beforeEach(function () { this.n = (this.n || 0) + 1; });
  it('passes', function () { assert.strictEqual(1 + 1, 2); });
  it('fails on a value', function () { assert.strictEqual(2 + 2, 5); });
  it('fails on a throw', function () { throw new Error('deliberate'); });
  it('is pending');
  it('is skipped', function () { this.skip(); });
  after(function () { /* teardown runs even after failures */ });
});
describe('async', function () {
  it('resolves', async function () { await new Promise(r => setTimeout(r, 5)); assert.ok(true); });
  it('rejects', async function () { await Promise.reject(new Error('async boom')); });
  it('callback style', function (done) { setImmediate(() => done()); });
  it('callback reports an error', function (done) { setImmediate(() => done(new Error('cb boom'))); });
  it('times out', async function () { this.timeout(30); await new Promise(r => setTimeout(r, 200)); });
});
describe('deep equality', function () {
  it('compares objects', function () { assert.deepStrictEqual({ a: [1, 2] }, { a: [1, 3] }); });
});
