import CommonCrypto
import Foundation

/// scrypt for the Node layer (system.md phase G): the KDF `crypto.scrypt`/`scryptSync` expose.
///
/// The refusal here said "scrypt has no system implementation", which was true and beside the
/// point — neither CryptoKit nor CommonCrypto has scrypt, but scrypt is not a primitive. It is
/// PBKDF2-HMAC-SHA256 (which CommonCrypto does have) wrapped around a memory-hard mixing step
/// built from Salsa20/8. So the missing piece was the mixing, which is arithmetic, and RFC 7914
/// publishes vectors to prove it byte for byte.
///
/// Structure follows RFC 7914 directly so it can be read against the spec:
/// `scrypt` → `romix` → `blockMix` → `salsa20_8`.
enum NodeScrypt {

    /// RFC 7914 §2: the Salsa20/8 core — 8 rounds over 16 little-endian words.
    private static func salsa20_8(_ block: inout [UInt32]) {
        var x = block
        // 8 rounds = 4 double rounds, each a column round then a row round.
        for _ in 0..<4 {
            // column
            x[4] ^= rotate(x[0] &+ x[12], 7);   x[8] ^= rotate(x[4] &+ x[0], 9)
            x[12] ^= rotate(x[8] &+ x[4], 13);  x[0] ^= rotate(x[12] &+ x[8], 18)
            x[9] ^= rotate(x[5] &+ x[1], 7);    x[13] ^= rotate(x[9] &+ x[5], 9)
            x[1] ^= rotate(x[13] &+ x[9], 13);  x[5] ^= rotate(x[1] &+ x[13], 18)
            x[14] ^= rotate(x[10] &+ x[6], 7);  x[2] ^= rotate(x[14] &+ x[10], 9)
            x[6] ^= rotate(x[2] &+ x[14], 13);  x[10] ^= rotate(x[6] &+ x[2], 18)
            x[3] ^= rotate(x[15] &+ x[11], 7);  x[7] ^= rotate(x[3] &+ x[15], 9)
            x[11] ^= rotate(x[7] &+ x[3], 13);  x[15] ^= rotate(x[11] &+ x[7], 18)
            // row
            x[1] ^= rotate(x[0] &+ x[3], 7);    x[2] ^= rotate(x[1] &+ x[0], 9)
            x[3] ^= rotate(x[2] &+ x[1], 13);   x[0] ^= rotate(x[3] &+ x[2], 18)
            x[6] ^= rotate(x[5] &+ x[4], 7);    x[7] ^= rotate(x[6] &+ x[5], 9)
            x[4] ^= rotate(x[7] &+ x[6], 13);   x[5] ^= rotate(x[4] &+ x[7], 18)
            x[11] ^= rotate(x[10] &+ x[9], 7);  x[8] ^= rotate(x[11] &+ x[10], 9)
            x[9] ^= rotate(x[8] &+ x[11], 13);  x[10] ^= rotate(x[9] &+ x[8], 18)
            x[12] ^= rotate(x[15] &+ x[14], 7); x[13] ^= rotate(x[12] &+ x[15], 9)
            x[14] ^= rotate(x[13] &+ x[12], 13); x[15] ^= rotate(x[14] &+ x[13], 18)
        }
        for i in 0..<16 { block[i] = block[i] &+ x[i] }
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    /// RFC 7914 §3: BlockMix over 2r 64-byte blocks, shuffling even blocks before odd ones.
    /// Words rather than bytes throughout — the whole cost of scrypt is in this loop, and
    /// converting per block would dominate it.
    private static func blockMix(_ input: [UInt32], _ output: inout [UInt32], _ r: Int) {
        var x = Array(input[((2 * r - 1) * 16)..<(2 * r * 16)])
        var block = [UInt32](repeating: 0, count: 16)
        for i in 0..<(2 * r) {
            let base = i * 16
            for w in 0..<16 { block[w] = x[w] ^ input[base + w] }
            salsa20_8(&block)
            x = block
            // Even blocks land in the first half, odd blocks in the second.
            let destination = (i % 2 == 0 ? (i / 2) : (r + i / 2)) * 16
            for w in 0..<16 { output[destination + w] = block[w] }
        }
    }

    /// RFC 7914 §4: ROMix — fill V with N successive BlockMix states, then walk it pseudo-randomly.
    /// This is the memory-hard part: V is 128 * N * r bytes, which is why node polices `maxmem`.
    private static func romix(_ block: inout [UInt32], _ n: Int, _ r: Int) {
        let words = 32 * r
        var v = [UInt32](repeating: 0, count: words * n)
        var x = block
        var y = [UInt32](repeating: 0, count: words)
        for i in 0..<n {
            let base = i * words
            for w in 0..<words { v[base + w] = x[w] }
            blockMix(x, &y, r)
            swap(&x, &y)
        }
        for _ in 0..<n {
            // Integerify: the last 64-byte block's first word, little-endian, mod N. N is a power
            // of two, so the mask is the modulo.
            let j = Int(x[(2 * r - 1) * 16] & UInt32(n - 1))
            let base = j * words
            for w in 0..<words { y[w] = x[w] ^ v[base + w] }
            blockMix(y, &x, r)
        }
        block = x
    }

    /// PBKDF2-HMAC-SHA256 with one iteration, which is all scrypt asks of it.
    private static func pbkdf2(_ password: Data, _ salt: Data, _ length: Int) -> Data? {
        guard length > 0 else { return Data() }
        var derived = [UInt8](repeating: 0, count: length)
        // An empty password or salt still has to work (RFC 7914's first vector uses both), and a
        // zero-length Data has no base address — hence the explicit empty byte.
        let passwordBytes = password.isEmpty ? Data([0]) : password
        let saltBytes = salt.isEmpty ? Data([0]) : salt
        let status = passwordBytes.withUnsafeBytes { p in
            saltBytes.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    p.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                    s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(UInt32(kCCPRFHmacAlgSHA256)), 1,
                    &derived, length)
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(derived)
    }

    private static func words(from data: Data) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: data.count / 4)
        for i in 0..<out.count {
            let base = data.startIndex + i * 4
            out[i] = UInt32(data[base]) | (UInt32(data[base + 1]) << 8) |
                     (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
        }
        return out
    }

    private static func bytes(from words: [UInt32]) -> Data {
        var out = Data(capacity: words.count * 4)
        for word in words {
            out.append(UInt8(word & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 24) & 0xff))
        }
        return out
    }

    /// The whole thing. `nil` on any parameter node would also reject, so the JS side can raise
    /// node's ERR_CRYPTO_INVALID_SCRYPT_PARAMS without duplicating the arithmetic.
    static func derive(password: Data, salt: Data, n: Int, r: Int, p: Int, length: Int) -> Data? {
        guard n > 1, n & (n - 1) == 0, r > 0, p > 0, length > 0 else { return nil }
        // The same overflow guards node applies, so a huge r or p fails rather than allocating.
        guard r <= 1 << 24, p <= 1 << 24, n <= 1 << 24 else { return nil }
        let blockBytes = 128 * r
        guard let initial = pbkdf2(password, salt, blockBytes * p) else { return nil }

        var mixed = Data(capacity: blockBytes * p)
        for i in 0..<p {
            let chunk = initial.subdata(in: (i * blockBytes)..<((i + 1) * blockBytes))
            var block = words(from: chunk)
            romix(&block, n, r)
            mixed.append(bytes(from: block))
        }
        return pbkdf2(password, mixed, length)
    }
}
