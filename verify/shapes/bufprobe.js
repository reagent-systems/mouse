// Which of Buffer's DOCUMENTED methods are actually missing here? The sweep's list mixes node
// internals (utf8Slice, asciiWrite) with real public API, and only the second kind matters.
const b = Buffer.alloc(8);
const documented = ['readBigInt64BE','readBigInt64LE','readBigUInt64BE','readBigUInt64LE',
  'writeBigInt64BE','writeBigInt64LE','writeBigUInt64BE','writeBigUInt64LE',
  'readBigUint64BE','readBigUint64LE','writeBigUint64BE','writeBigUint64LE',
  'readIntBE','readIntLE','readUIntBE','readUIntLE','writeIntBE','writeIntLE',
  'writeUIntBE','writeUIntLE','readUint8','readUint16BE','readUint16LE','readUint32BE',
  'readUint32LE','readUintBE','readUintLE','writeUint8','writeUint16BE','writeUint16LE',
  'writeUint32BE','writeUint32LE','writeUintBE','writeUintLE','swap16','swap32','swap64',
  'readUInt8','readUInt16BE','readInt32LE','writeFloatBE','writeFloatLE','writeDoubleBE',
  'readFloatBE','readDoubleLE','subarray','copy','equals','compare','indexOf','includes',
  'lastIndexOf','fill','write','toJSON','entries','keys','values'];
console.log('missing: ' + documented.filter(n => typeof b[n] !== 'function').join(' '));
console.log('statics missing: ' + ['copyBytesFrom','concat','from','of','alloc','isBuffer','byteLength','compare','isEncoding','allocUnsafe','allocUnsafeSlow']
  .filter(n => typeof Buffer[n] !== 'function').join(' '));
