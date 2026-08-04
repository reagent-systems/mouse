// Deterministic properties only — keys are random every run, so what is compared is what must
// hold on both engines, plus the group constants which must be byte-identical.
const c = require('crypto');
const out = [];
for (const name of ['modp1','modp2','modp5','modp14','modp15','modp16','modp17','modp18']) {
  const d = c.getDiffieHellman(name);
  out.push(name + ' bits=' + d.getPrime().length * 8 + ' gen=' + d.getGenerator().toString('hex') +
           ' sha=' + c.createHash('sha256').update(d.getPrime()).digest('hex').slice(0, 16));
}
// A round trip inside one engine: two parties must agree.
const a = c.getDiffieHellman('modp14'), b = c.getDiffieHellman('modp14');
a.generateKeys(); b.generateKeys();
const s1 = a.computeSecret(b.getPublicKey()), s2 = b.computeSecret(a.getPublicKey());
out.push('agree=' + s1.equals(s2) + ' len=' + s1.length + ' pub=' + a.getPublicKey().length);
// createDiffieHellman from an explicit prime reproduces the same group.
const d2 = c.createDiffieHellman(a.getPrime(), a.getGenerator());
out.push('fromPrime=' + d2.getPrime().equals(a.getPrime()) + ' gen=' + d2.getGenerator().toString('hex'));
// Primality: known primes, known composites, and a Mersenne prime.
const primes = [2n, 3n, 7n, 97n, 7919n, 104729n, 2147483647n, BigInt('170141183460469231731687303715884105727')];
const composites = [1n, 4n, 9n, 100n, 7917n, 104730n, 2147483649n, BigInt('170141183460469231731687303715884105725')];
out.push('primes=' + primes.map(p => c.checkPrimeSync(p) ? 1 : 0).join(''));
out.push('composites=' + composites.map(p => c.checkPrimeSync(p) ? 1 : 0).join(''));
// Carmichael numbers defeat a naive Fermat test; Miller-Rabin must reject them.
out.push('carmichael=' + [561n, 1105n, 1729n, 2465n, 6601n, 8911n].map(n => c.checkPrimeSync(n) ? 1 : 0).join(''));
// Generated primes must actually be prime, the requested width, and odd.
for (const bits of [64, 128, 256]) {
  const p = c.generatePrimeSync(bits, { bigint: true });
  out.push('gen' + bits + ' prime=' + c.checkPrimeSync(p) + ' bits=' + p.toString(2).length + ' odd=' + ((p & 1n) === 1n));
}
const safe = c.generatePrimeSync(64, { safe: true, bigint: true });
out.push('safe prime=' + c.checkPrimeSync(safe) + ' halfPrime=' + c.checkPrimeSync((safe - 1n) / 2n));
const buf = c.generatePrimeSync(64);
out.push('default type=' + (buf instanceof ArrayBuffer) + ' bytes=' + buf.byteLength);
console.log(out.join('\n'));
