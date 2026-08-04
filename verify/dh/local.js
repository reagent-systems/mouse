const crypto = require('crypto');
// Both sides of the agreement inside one engine, for every curve node's diffieHellman covers.
for (const spec of [['x25519', null], ['ec', 'prime256v1'], ['ec', 'secp384r1'], ['ec', 'secp521r1']]) {
  const [type, curve] = spec;
  const options = curve ? { namedCurve: curve } : undefined;
  const a = crypto.generateKeyPairSync(type, options);
  const b = crypto.generateKeyPairSync(type, options);
  const s1 = crypto.diffieHellman({ privateKey: a.privateKey, publicKey: b.publicKey });
  const s2 = crypto.diffieHellman({ privateKey: b.privateKey, publicKey: a.publicKey });
  console.log(`${curve || type}: agree=${s1.equals(s2)} bytes=${s1.length}`);
}
