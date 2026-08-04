const add = (a, b) => a + b;
describe('arithmetic', () => {
  test('adds', () => { expect(add(1, 2)).toBe(3); });
  test('fails a comparison', () => { expect(add(2, 2)).toBe(5); });
  test('deep equality', () => { expect({ a: [1, 2] }).toEqual({ a: [1, 2] }); });
  test.skip('skipped', () => {});
  test('async resolves', async () => { await new Promise(r => setTimeout(r, 5)); expect(true).toBe(true); });
  test('throws', () => { expect(() => { throw new TypeError('bad'); }).toThrow(TypeError); });
});
