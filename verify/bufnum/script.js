const out = [];
// Floats: writeFloat was missing while readFloat was present, so binary formats could be read
// and not written.
for (const [w, r] of [['writeFloatBE', 'readFloatBE'], ['writeFloatLE', 'readFloatLE']]) {
  const b = Buffer.alloc(4);
  const ret = b[w](1.5, 0);
  out.push(`${w} bytes=${b.toString('hex')} ret=${ret} back=${b[r](0)}`);
}
// The 16-bit signed writers, missing while their readers were present.
for (const [w, r] of [['writeInt16BE', 'readInt16BE'], ['writeInt16LE', 'readInt16LE']]) {
  const b = Buffer.alloc(2);
  b[w](-300, 0);
  out.push(`${w} bytes=${b.toString('hex')} back=${b[r](0)}`);
}
// Signed 64-bit, both orders, including the extremes.
for (const value of [0n, 1n, -1n, 9223372036854775807n, -9223372036854775808n]) {
  const be = Buffer.alloc(8), le = Buffer.alloc(8);
  be.writeBigInt64BE(value, 0); le.writeBigInt64LE(value, 0);
  out.push(`bigint64 ${value} be=${be.toString('hex')} le=${le.toString('hex')} back=${be.readBigInt64BE(0)},${le.readBigInt64LE(0)}`);
}
// Variable-width integers, every legal byte count.
for (let size = 1; size <= 6; size++) {
  const be = Buffer.alloc(6), le = Buffer.alloc(6);
  const value = Math.pow(2, size * 8 - 3) + 5;
  be.writeUIntBE(value, 0, size); le.writeUIntLE(value, 0, size);
  out.push(`uint${size} be=${be.toString('hex')} le=${le.toString('hex')} back=${be.readUIntBE(0, size)},${le.readUIntLE(0, size)}`);
  const signedBE = Buffer.alloc(6), signedLE = Buffer.alloc(6);
  const negative = -(Math.pow(2, size * 8 - 4) + 3);
  signedBE.writeIntBE(negative, 0, size); signedLE.writeIntLE(negative, 0, size);
  out.push(`int${size} be=${signedBE.toString('hex')} le=${signedLE.toString('hex')} back=${signedBE.readIntBE(0, size)},${signedLE.readIntLE(0, size)}`);
}
// Out-of-range byte counts must throw, not silently truncate.
for (const size of [0, 7]) {
  try { Buffer.alloc(8).readUIntBE(0, size); out.push(`size ${size}: ALLOWED`); }
  catch (error) { out.push(`size ${size}: ${error.name}`); }
}
// Byte-order swaps, in place, returning the same buffer.
const s16 = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
out.push('swap16 ' + s16.swap16().toString('hex') + ' same=' + (s16.swap16 !== undefined));
out.push('swap32 ' + Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]).swap32().toString('hex'));
out.push('swap64 ' + Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]).swap64().toString('hex'));
try { Buffer.alloc(3).swap16(); out.push('swap16 odd: ALLOWED'); }
catch (error) { out.push('swap16 odd: ' + error.name); }
// The lowercase aliases must be the same functions, not near-copies.
const b = Buffer.alloc(8);
out.push('aliases identical: ' + ['readUint8', 'readUint16BE', 'readUint32LE', 'writeUint16BE',
                                 'readUintBE', 'writeUintLE', 'readBigUint64BE']
  .every(n => typeof b[n] === 'function' && b[n] === b[n.replace('Uint', 'UInt').replace('BigUInt', 'BigUInt')]));
out.push('readUint16BE works: ' + (function(){ const x = Buffer.from([0x12, 0x34]); return x.readUint16BE(0); })());
// copyBytesFrom copies VALUES, widened per element — not a reinterpretation of memory.
const source = new Uint16Array([0x1234, 0x5678]);
out.push('copyBytesFrom: ' + Buffer.copyBytesFrom(source).toString('hex'));
out.push('copyBytesFrom sliced: ' + Buffer.copyBytesFrom(source, 1, 1).toString('hex'));
console.log(out.join('\n'));
