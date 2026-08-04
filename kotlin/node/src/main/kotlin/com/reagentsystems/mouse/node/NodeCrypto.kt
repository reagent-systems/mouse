package com.reagentsystems.mouse.node

import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Digests, HMACs and key derivation — the half of `crypto` that is arithmetic.
 *
 * `NodeEngine.swift` reaches for CryptoKit here; the Android counterpart is the JCA, which is the
 * platform's own and therefore not a dependency (invariant #4). Both are the same primitives with
 * different spellings, and the spellings are the whole of the work: node says `sha256`, CryptoKit
 * says `SHA256`, the JCA says `SHA-256`, and its HMAC names have no separator at all.
 *
 * ## Why this is in `:node` rather than the app
 *
 * Nothing here is framework. `MessageDigest` and `Mac` are JDK classes Android ships too, so this compiles and RUNS in a bare JVM harness — which means `:nodecheck`
 * can grade it against real `node`'s own digests rather than against a table someone typed. The
 * socket layer is in this module for the same reason.
 *
 * Everything crosses as base64, because the bridge carries strings and the bootstrap already does
 * `Buffer.from(…, 'base64')` on both sides. A null answer means "I do not know that algorithm",
 * which is the shape the bootstrap branches on to raise node's own error.
 */
object NodeCrypto {

    /** node's digest names → the JCA's, for [MessageDigest]. */
    private val DIGESTS = mapOf(
        "md5" to "MD5",
        "sha1" to "SHA-1",
        "sha224" to "SHA-224",
        "sha256" to "SHA-256",
        "sha384" to "SHA-384",
        "sha512" to "SHA-512",
    )

    /** The same list for [Mac], whose names are spelled without the separator. */
    private val MACS = mapOf(
        "md5" to "HmacMD5",
        "sha1" to "HmacSHA1",
        "sha224" to "HmacSHA224",
        "sha256" to "HmacSHA256",
        "sha384" to "HmacSHA384",
        "sha512" to "HmacSHA512",
    )

    private fun decode(base64: String): ByteArray? =
        runCatching { Base64.getDecoder().decode(base64) }.getOrNull()

    private fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    /** `crypto.createHash(algorithm)` — the whole message at once, base64 in and out. */
    fun hash(algorithm: String, base64: String): String? {
        val name = DIGESTS[algorithm.lowercase()] ?: return null
        val data = decode(base64) ?: return null
        return runCatching { encode(MessageDigest.getInstance(name).digest(data)) }.getOrNull()
    }

    /** `crypto.createHmac(algorithm, key)`. An EMPTY key is legal and not the same as no key. */
    fun hmac(algorithm: String, keyBase64: String, base64: String): String? {
        val name = MACS[algorithm.lowercase()] ?: return null
        val key = decode(keyBase64) ?: return null
        val data = decode(base64) ?: return null
        return runCatching {
            val mac = Mac.getInstance(name)
            // The JCA rejects a zero-length key; node does not, and hashes it as the spec says by
            // padding it to the block size. An all-zero byte is the same thing to HMAC's inner
            // padding, which is what makes this substitution exact rather than approximate.
            mac.init(SecretKeySpec(if (key.isEmpty()) ByteArray(1) else key, name))
            encode(mac.doFinal(data))
        }.getOrNull()
    }

    /**
     * `crypto.pbkdf2` / `pbkdf2Sync` — RFC 2898, computed over BYTES.
     *
     * This used to go through `SecretKeyFactory`, and the comment justifying it was wrong in a way
     * that shipped. `PBEKeySpec` takes the password as CHARS; the note here claimed a latin-1
     * mapping round-trips through the JCA, so any byte would survive. It does not. The JDK's
     * PBKDF2 encodes those chars as **UTF-8**, so every byte from 0x80 up becomes TWO bytes and the
     * derived key silently disagrees with node's. Measured, not reasoned about — for the password
     * `ff fe 41`, salt `salt`, 1000 rounds, SHA-256:
     *
     *     via PBEKeySpec:  QQyzjJHux0okFa4R7RUQSuRRKp6Lvu7JgfIR69ySFs8=
     *     real node:       hq8W7wUZmc1vKOER23TSD6hik1+rHQTaNH+/I+KfmC4=
     *
     * The corpus could not see it because every case in it used an ASCII password, where UTF-8 and
     * latin-1 agree. A non-ASCII passphrase is not an exotic input — it is what a user with an
     * accent in their password has.
     *
     * PBKDF2 is a short construction over HMAC, which is already here, so it is written out and the
     * charset never enters. That also makes `md5` work, which the factory route could not offer and
     * node does.
     */
    fun pbkdf2(
        passwordBase64: String,
        saltBase64: String,
        iterations: Int,
        keyLength: Int,
        digest: String,
    ): String? {
        val algorithm = digest.lowercase()
        if (!MACS.containsKey(algorithm)) return null
        val password = decode(passwordBase64) ?: return null
        val salt = decode(saltBase64) ?: return null
        if (iterations <= 0 || keyLength <= 0) return null
        return runCatching { encode(pbkdf2Raw(algorithm, password, salt, iterations, keyLength)) }
            .getOrNull()
    }

    /** RFC 2898's block loop. `T_i = U_1 xor … xor U_c`, with `U_1 = HMAC(P, S || INT32BE(i))`. */
    private fun pbkdf2Raw(
        algorithm: String,
        password: ByteArray,
        salt: ByteArray,
        iterations: Int,
        length: Int,
    ): ByteArray {
        val output = ByteArray(length)
        var written = 0
        var block = 1
        while (written < length) {
            val counter = byteArrayOf(
                (block ushr 24).toByte(), (block ushr 16).toByte(),
                (block ushr 8).toByte(), block.toByte(),
            )
            var u = mac(algorithm, password, salt + counter)
            val t = u.copyOf()
            for (round in 2..iterations) {
                u = mac(algorithm, password, u)
                for (i in t.indices) t[i] = (t[i].toInt() xor u[i].toInt()).toByte()
            }
            val take = minOf(t.size, length - written)
            t.copyInto(output, written, 0, take)
            written += take
            block += 1
        }
        return output
    }

    /** `crypto.randomUUID()`. Lower-case v4, which is what node returns and what iOS lower-cases. */
    fun randomUUID(): String = UUID.randomUUID().toString()

    // ----------------------------------------------------------------------- KDFs ----
    //
    // Neither has a JCA factory at any level this app supports: scrypt is not a JCA algorithm
    // at all, and HKDF reached the JDK only at 24 against an Android platform that has never
    // shipped it. Both are short constructions over `Mac`, as PBKDF2 above turned out to be, so
    // all three are written out and none of them depends on a provider's spelling.

    /** Raw HMAC over already-decoded bytes — the primitive both constructions below are built on. */
    private fun mac(algorithm: String, key: ByteArray, data: ByteArray): ByteArray {
        val name = MACS[algorithm] ?: throw IllegalArgumentException(algorithm)
        val instance = Mac.getInstance(name)
        // Same zero-length rule as `hmac`: the JCA rejects an empty key, HMAC's padding does not
        // distinguish it from a single zero byte, and HKDF's extract step uses an empty salt by
        // default — so this path is reached by ordinary callers, not only odd ones.
        instance.init(SecretKeySpec(if (key.isEmpty()) ByteArray(1) else key, name))
        return instance.doFinal(data)
    }

    /**
     * `crypto.hkdfSync` — RFC 5869, extract then expand.
     *
     * Extract turns arbitrary input keying material into a fixed-width pseudorandom key; expand
     * stretches that to the requested length. The two are separate steps for a reason worth not
     * collapsing: the salt goes in at extract and the `info` label at expand, and swapping them
     * produces a plausible-looking key that agrees with nothing.
     */
    fun hkdf(
        digest: String,
        keyBase64: String,
        saltBase64: String,
        infoBase64: String,
        length: Int,
    ): String? {
        val algorithm = digest.lowercase()
        if (!MACS.containsKey(algorithm)) return null
        val key = decode(keyBase64) ?: return null
        val salt = decode(saltBase64) ?: return null
        val info = decode(infoBase64) ?: return null
        if (length < 0) return null
        return runCatching {
            val prk = mac(algorithm, salt, key)
            // RFC 5869 caps output at 255 blocks, because the counter is one byte.
            val blockSize = prk.size
            if (length > 255 * blockSize) return null
            val output = ByteArray(length)
            var previous = ByteArray(0)
            var written = 0
            var counter = 1
            while (written < length) {
                previous = mac(algorithm, prk, previous + info + byteArrayOf(counter.toByte()))
                val take = minOf(blockSize, length - written)
                previous.copyInto(output, written, 0, take)
                written += take
                counter += 1
            }
            encode(output)
        }.getOrNull()
    }

    /**
     * `crypto.scryptSync` — RFC 7914.
     *
     * PBKDF2 to fill a buffer, ROMix over each block to make it memory-hard, PBKDF2 again to
     * squeeze it back down. The middle step is the whole point of scrypt: it forces the attacker
     * to hold `128 * N * r` bytes, which is why the caller's parameters are memory and not just
     * time. The bootstrap has already checked them against `maxmem` before calling.
     */
    fun scrypt(
        passwordBase64: String,
        saltBase64: String,
        n: Int,
        r: Int,
        p: Int,
        length: Int,
    ): String? {
        val password = decode(passwordBase64) ?: return null
        val salt = decode(saltBase64) ?: return null
        // N must be a power of two greater than 1 — ROMix indexes into its buffer with `mod N`,
        // and the construction is only defined for that shape.
        if (n < 2 || (n and (n - 1)) != 0) return null
        if (r < 1 || p < 1 || length < 1) return null
        if (r.toLong() * p > 1 shl 30) return null
        return runCatching {
            val blockLength = 128 * r
            val buffer = pbkdf2Raw("sha256", password, salt, 1, p * blockLength)
            for (i in 0 until p) {
                romix(buffer, i * blockLength, r, n)
            }
            encode(pbkdf2Raw("sha256", password, buffer, 1, length))
        }.getOrNull()
    }

    /** ROMix: N rounds filling a table, then N rounds mixing back out of it at random indices. */
    private fun romix(buffer: ByteArray, offset: Int, r: Int, n: Int) {
        val blockLength = 128 * r
        val x = buffer.copyOfRange(offset, offset + blockLength)
        val v = ByteArray(blockLength * n)
        for (i in 0 until n) {
            x.copyInto(v, i * blockLength)
            blockMix(x, r)
        }
        for (i in 0 until n) {
            // The index is the last 64-byte block's first word, which is what makes the access
            // pattern depend on the data and therefore unpredictable to a hardware attacker.
            val j = integerify(x, r) and (n - 1)
            for (k in 0 until blockLength) x[k] = (x[k].toInt() xor v[j * blockLength + k].toInt()).toByte()
            blockMix(x, r)
        }
        x.copyInto(buffer, offset)
    }

    /** BlockMix over Salsa20/8: 2r 64-byte blocks in, the same out, interleaved even-then-odd. */
    private fun blockMix(block: ByteArray, r: Int) {
        val x = block.copyOfRange(block.size - 64, block.size)
        val out = ByteArray(block.size)
        for (i in 0 until 2 * r) {
            for (k in 0 until 64) x[k] = (x[k].toInt() xor block[i * 64 + k].toInt()).toByte()
            salsa20(x)
            // Even blocks land in the first half, odd in the second — the shuffle scrypt specifies.
            val target = if (i % 2 == 0) (i / 2) * 64 else (r + i / 2) * 64
            x.copyInto(out, target)
        }
        out.copyInto(block)
    }

    /** The first word of the last 64-byte block, little-endian. */
    private fun integerify(block: ByteArray, r: Int): Int {
        val at = (2 * r - 1) * 64
        return (block[at].toInt() and 0xff) or
            ((block[at + 1].toInt() and 0xff) shl 8) or
            ((block[at + 2].toInt() and 0xff) shl 16) or
            ((block[at + 3].toInt() and 0xff) shl 24)
    }

    /** Salsa20/8 core, in place over 64 bytes. */
    private fun salsa20(block: ByteArray) {
        val x = IntArray(16)
        for (i in 0 until 16) {
            x[i] = (block[i * 4].toInt() and 0xff) or
                ((block[i * 4 + 1].toInt() and 0xff) shl 8) or
                ((block[i * 4 + 2].toInt() and 0xff) shl 16) or
                ((block[i * 4 + 3].toInt() and 0xff) shl 24)
        }
        val start = x.copyOf()
        // Eight rounds — four double-rounds, columns then rows.
        for (round in 0 until 4) {
            x[4] = x[4] xor Integer.rotateLeft(x[0] + x[12], 7)
            x[8] = x[8] xor Integer.rotateLeft(x[4] + x[0], 9)
            x[12] = x[12] xor Integer.rotateLeft(x[8] + x[4], 13)
            x[0] = x[0] xor Integer.rotateLeft(x[12] + x[8], 18)
            x[9] = x[9] xor Integer.rotateLeft(x[5] + x[1], 7)
            x[13] = x[13] xor Integer.rotateLeft(x[9] + x[5], 9)
            x[1] = x[1] xor Integer.rotateLeft(x[13] + x[9], 13)
            x[5] = x[5] xor Integer.rotateLeft(x[1] + x[13], 18)
            x[14] = x[14] xor Integer.rotateLeft(x[10] + x[6], 7)
            x[2] = x[2] xor Integer.rotateLeft(x[14] + x[10], 9)
            x[6] = x[6] xor Integer.rotateLeft(x[2] + x[14], 13)
            x[10] = x[10] xor Integer.rotateLeft(x[6] + x[2], 18)
            x[3] = x[3] xor Integer.rotateLeft(x[15] + x[11], 7)
            x[7] = x[7] xor Integer.rotateLeft(x[3] + x[15], 9)
            x[11] = x[11] xor Integer.rotateLeft(x[7] + x[3], 13)
            x[15] = x[15] xor Integer.rotateLeft(x[11] + x[7], 18)
            x[1] = x[1] xor Integer.rotateLeft(x[0] + x[3], 7)
            x[2] = x[2] xor Integer.rotateLeft(x[1] + x[0], 9)
            x[3] = x[3] xor Integer.rotateLeft(x[2] + x[1], 13)
            x[0] = x[0] xor Integer.rotateLeft(x[3] + x[2], 18)
            x[6] = x[6] xor Integer.rotateLeft(x[5] + x[4], 7)
            x[7] = x[7] xor Integer.rotateLeft(x[6] + x[5], 9)
            x[4] = x[4] xor Integer.rotateLeft(x[7] + x[6], 13)
            x[5] = x[5] xor Integer.rotateLeft(x[4] + x[7], 18)
            x[11] = x[11] xor Integer.rotateLeft(x[10] + x[9], 7)
            x[8] = x[8] xor Integer.rotateLeft(x[11] + x[10], 9)
            x[9] = x[9] xor Integer.rotateLeft(x[8] + x[11], 13)
            x[10] = x[10] xor Integer.rotateLeft(x[9] + x[8], 18)
            x[12] = x[12] xor Integer.rotateLeft(x[15] + x[14], 7)
            x[13] = x[13] xor Integer.rotateLeft(x[12] + x[15], 9)
            x[14] = x[14] xor Integer.rotateLeft(x[13] + x[12], 13)
            x[15] = x[15] xor Integer.rotateLeft(x[14] + x[13], 18)
        }
        for (i in 0 until 16) {
            val value = x[i] + start[i]
            block[i * 4] = value.toByte()
            block[i * 4 + 1] = (value ushr 8).toByte()
            block[i * 4 + 2] = (value ushr 16).toByte()
            block[i * 4 + 3] = (value ushr 24).toByte()
        }
    }

    // ------------------------------------------------------------------- ciphers ----
    //
    // Symmetric ciphers over a key the CALLER supplies — arithmetic, like the digests above, and
    // not key management. iOS reaches for CryptoKit's AEADs and CommonCrypto for the block modes;
    // the JCA has all of it under one `Cipher`, with the transformation string doing the work the
    // two Apple APIs split between them.

    /** How many bytes of key `aes-128-…` and its siblings require. Null if the name is unknown. */
    private fun aesKeySize(algorithm: String): Int? = when {
        algorithm.startsWith("aes-128") -> 16
        algorithm.startsWith("aes-192") -> 24
        algorithm.startsWith("aes-256") -> 32
        else -> null
    }

    /** The JCA transformation for a block mode, matching what `commonCrypt` selects on iOS. */
    private fun blockTransformation(algorithm: String): String? = when {
        algorithm.endsWith("-cbc") -> "AES/CBC/PKCS5Padding"
        algorithm.endsWith("-ctr") -> "AES/CTR/NoPadding"
        algorithm.endsWith("-ecb") -> "AES/ECB/PKCS5Padding"
        else -> null
    }

    /**
     * `cipher.final()` — encrypt, and for an AEAD return the tag beside the ciphertext.
     *
     * The pair is returned rather than concatenated because that is the shape the bootstrap reads
     * (`{data, tag}`), and because node's own `getAuthTag()` is a separate call. The JCA
     * concatenates the tag onto the ciphertext, so it is split back off here — 16 bytes, which is
     * the only tag length either AEAD here produces.
     */
    fun cipherSeal(
        algorithm: String,
        keyBase64: String,
        ivBase64: String,
        plainBase64: String,
        aadBase64: String,
    ): Pair<String, String>? {
        val name = algorithm.lowercase()
        val key = decode(keyBase64) ?: return null
        val iv = decode(ivBase64) ?: return null
        val plain = decode(plainBase64) ?: return null
        val aad = decode(aadBase64) ?: ByteArray(0)
        return runCatching {
            when {
                name.endsWith("-gcm") -> {
                    if (aesKeySize(name) != key.size) return null
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, iv))
                    if (aad.isNotEmpty()) cipher.updateAAD(aad)
                    split(cipher.doFinal(plain))
                }
                name == "chacha20-poly1305" -> {
                    val cipher = Cipher.getInstance("ChaCha20-Poly1305")
                    cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(iv))
                    if (aad.isNotEmpty()) cipher.updateAAD(aad)
                    split(cipher.doFinal(plain))
                }
                else -> {
                    val transformation = blockTransformation(name) ?: return null
                    if (aesKeySize(name) != key.size) return null
                    val cipher = Cipher.getInstance(transformation)
                    if (transformation.contains("/ECB/")) {
                        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
                    } else {
                        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
                    }
                    // A block mode has no tag; the empty string is what the bootstrap reads as
                    // "there is none", the same as iOS returning only `data`.
                    encode(cipher.doFinal(plain)) to ""
                }
            }
        }.getOrNull()
    }

    /** `decipher.final()`. A failed AEAD tag answers null, which is node's own error. */
    fun cipherOpen(
        algorithm: String,
        keyBase64: String,
        ivBase64: String,
        cipherBase64: String,
        tagBase64: String,
        aadBase64: String,
    ): String? {
        val name = algorithm.lowercase()
        val key = decode(keyBase64) ?: return null
        val iv = decode(ivBase64) ?: return null
        val body = decode(cipherBase64) ?: return null
        val tag = decode(tagBase64) ?: ByteArray(0)
        val aad = decode(aadBase64) ?: ByteArray(0)
        return runCatching {
            when {
                name.endsWith("-gcm") -> {
                    if (aesKeySize(name) != key.size) return null
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, iv))
                    if (aad.isNotEmpty()) cipher.updateAAD(aad)
                    encode(cipher.doFinal(body + tag))
                }
                name == "chacha20-poly1305" -> {
                    val cipher = Cipher.getInstance("ChaCha20-Poly1305")
                    cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(iv))
                    if (aad.isNotEmpty()) cipher.updateAAD(aad)
                    encode(cipher.doFinal(body + tag))
                }
                else -> {
                    val transformation = blockTransformation(name) ?: return null
                    if (aesKeySize(name) != key.size) return null
                    val cipher = Cipher.getInstance(transformation)
                    if (transformation.contains("/ECB/")) {
                        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"))
                    } else {
                        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
                    }
                    encode(cipher.doFinal(body))
                }
            }
        }.getOrNull()
    }

    /** 128 bits — the only tag length AES-GCM and ChaCha20-Poly1305 produce here, and node's. */
    private const val TAG_BITS = 128

    /** The JCA appends the tag to the ciphertext; node keeps them apart, and so does the bridge. */
    private fun split(sealed: ByteArray): Pair<String, String> {
        val tagBytes = TAG_BITS / 8
        if (sealed.size < tagBytes) return encode(sealed) to ""
        return encode(sealed.copyOfRange(0, sealed.size - tagBytes)) to
            encode(sealed.copyOfRange(sealed.size - tagBytes, sealed.size))
    }
}
