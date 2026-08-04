package com.reagentsystems.mouse.node

import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.PBEKeySpec
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
 * Nothing here is framework. `MessageDigest`, `Mac` and `SecretKeyFactory` are JDK classes that
 * Android ships too, so this compiles and RUNS in a bare JVM harness — which means `:nodecheck`
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

    /** And for PBKDF2, where the JCA folds the digest into the factory's name. */
    private val KDFS = mapOf(
        "sha1" to "PBKDF2WithHmacSHA1",
        "sha224" to "PBKDF2WithHmacSHA224",
        "sha256" to "PBKDF2WithHmacSHA256",
        "sha384" to "PBKDF2WithHmacSHA384",
        "sha512" to "PBKDF2WithHmacSHA512",
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
     * `crypto.pbkdf2` / `pbkdf2Sync`.
     *
     * `PBEKeySpec` takes the password as CHARS, which would put it through a charset and corrupt
     * any byte over 0x7f. PBKDF2 is defined on bytes, so the password is mapped one byte to one
     * char through latin-1 — the only encoding where that round-trips — and the JCA turns it back
     * into the same bytes.
     */
    fun pbkdf2(
        passwordBase64: String,
        saltBase64: String,
        iterations: Int,
        keyLength: Int,
        digest: String,
    ): String? {
        val name = KDFS[digest.lowercase()] ?: return null
        val password = decode(passwordBase64) ?: return null
        val salt = decode(saltBase64) ?: return null
        if (iterations <= 0 || keyLength <= 0) return null
        return runCatching {
            val chars = CharArray(password.size) { (password[it].toInt() and 0xff).toChar() }
            val spec = PBEKeySpec(chars, salt, iterations, keyLength * 8)
            encode(SecretKeyFactory.getInstance(name).generateSecret(spec).encoded)
        }.getOrNull()
    }

    /** `crypto.randomUUID()`. Lower-case v4, which is what node returns and what iOS lower-cases. */
    fun randomUUID(): String = UUID.randomUUID().toString()

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
