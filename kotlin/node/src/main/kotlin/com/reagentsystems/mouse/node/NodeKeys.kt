package com.reagentsystems.mouse.node

import java.util.Base64

/**
 * Asymmetric keys — the PARSER half, which is the half that is actually work.
 *
 * The JCA has every primitive these bridge methods need: `KeyPairGenerator`, `Signature`,
 * `KeyAgreement`, `KeyFactory`. What it does not have is a way in. `KeyFactory` takes a
 * `PKCS8EncodedKeySpec` or an `X509EncodedKeySpec` — raw DER, already identified — and node's
 * callers hold PEM and expect the engine to work out what it is. So every one of the fourteen
 * methods starts here, and they share one reader rather than fourteen guesses.
 *
 * ## Why the OID and not a trial import
 *
 * `NodeEngine.swift` identifies a key by TRYING it: `P256.Signing.PrivateKey(pemRepresentation:)`,
 * then P384, then P521, then Ed25519, and whichever import does not throw names the type. That is
 * reasonable against CryptoKit, whose importers are cheap and total. It is a bad fit here for two
 * reasons: the JCA throws provider-specific exceptions that differ across API levels, so "did not
 * throw" is not a portable answer; and a trial import cannot tell X25519 from Ed25519 — same
 * wrapper shape, both 32 raw bytes — which is exactly the case `NodeEngine.swift` has to special-
 * case with a byte-prefix comparison after its trials fail.
 *
 * Reading the algorithm identifier answers all of it directly, because that is what the field is
 * FOR. An `AlgorithmIdentifier` OID is present in both structures node hands over, and the curve
 * is in its parameters.
 *
 * ## The structures, and why there are five
 *
 * PEM labels are not decoration — they say which grammar the DER follows, and the same key can
 * arrive under any of them:
 *
 *  - `PRIVATE KEY` — PKCS#8 `PrivateKeyInfo`: `SEQ { INT version, AlgorithmIdentifier, OCTET STRING }`
 *  - `PUBLIC KEY` — SPKI `SubjectPublicKeyInfo`: `SEQ { AlgorithmIdentifier, BIT STRING }`
 *  - `EC PRIVATE KEY` — SEC1: `SEQ { INT 1, OCTET STRING, [0] curve OID, [1] BIT STRING }`
 *  - `RSA PRIVATE KEY` — PKCS#1: `SEQ { INT 0, INT n, INT e, … }`
 *  - `RSA PUBLIC KEY` — PKCS#1: `SEQ { INT n, INT e }`
 *
 * The two PKCS#1 forms carry NO algorithm identifier at all — the label is the only thing that
 * says "RSA", which is why the label is read first and not thrown away.
 *
 * Nothing here validates a key cryptographically. It answers what a key IS; whether it is sound is
 * the JCA's job at the moment it is used, and duplicating that check would only produce a second
 * opinion that could disagree.
 */
object NodeKeys {

    /** What [identify] answers. `curve` is empty for everything that is not EC. */
    data class Identity(
        val type: String,
        val curve: String = "",
        val modulusLength: Int = 0,
    )

    // -------------------------------------------------------------------- OIDs ----

    private const val OID_RSA = "1.2.840.113549.1.1.1"
    private const val OID_EC = "1.2.840.10045.2.1"
    private const val OID_ED25519 = "1.3.101.112"
    private const val OID_ED448 = "1.3.101.113"
    private const val OID_X25519 = "1.3.101.110"
    private const val OID_X448 = "1.3.101.111"

    /** Curve OID → the name node reports. node uses OpenSSL's spelling, not the SEC's. */
    private val CURVES = mapOf(
        "1.2.840.10045.3.1.7" to "prime256v1",
        "1.3.132.0.34" to "secp384r1",
        "1.3.132.0.35" to "secp521r1",
    )

    /** The name node reports → the curve OID, for going the other way. */
    val CURVE_OIDS: Map<String, String> = CURVES.entries.associate { (oid, name) -> name to oid }

    /**
     * node's curve name → the JCA's, for `ECGenParameterSpec`.
     *
     * P-256 is the one that differs: node and OpenSSL call it `prime256v1`, the JDK and Android
     * call it `secp256r1`, and they are the same curve. Passing node's spelling to
     * `ECGenParameterSpec` throws — which is how this was found, with P-256 the only curve of the
     * three that failed to generate while P-384 and P-521 sailed through, since those two spell
     * the same in both worlds.
     */
    private val JCA_CURVES = mapOf(
        "prime256v1" to "secp256r1",
        "secp384r1" to "secp384r1",
        "secp521r1" to "secp521r1",
    )

    // --------------------------------------------------------------------- PEM ----

    private val PEM_BLOCK =
        Regex("-----BEGIN ([A-Z0-9 ]+)-----([A-Za-z0-9+/=\\s]*)-----END \\1-----")

    /** The label of the first PEM block, e.g. `EC PRIVATE KEY`. Null when the text has none. */
    fun label(pem: String): String? = PEM_BLOCK.find(pem)?.groupValues?.get(1)

    /**
     * The DER body of the first PEM block.
     *
     * Whitespace inside base64 is stripped rather than rejected: a PEM is line-wrapped by
     * definition, and callers paste them with every line ending there is.
     */
    fun der(pem: String): ByteArray? {
        val match = PEM_BLOCK.find(pem) ?: return null
        val body = match.groupValues[2].filterNot { it.isWhitespace() }
        return runCatching { Base64.getDecoder().decode(body) }.getOrNull()
    }

    // --------------------------------------------------------------- DER reading ----

    private const val TAG_INTEGER = 0x02
    private const val TAG_BIT_STRING = 0x03
    private const val TAG_OCTET_STRING = 0x04
    private const val TAG_OID = 0x06
    private const val TAG_SEQUENCE = 0x30

    /** One TLV: its tag, where its contents start and end, and where the NEXT one starts. */
    private data class Tlv(val tag: Int, val from: Int, val until: Int, val next: Int)

    /**
     * Read the TLV at [at].
     *
     * Returns null rather than throwing on anything malformed — a caller here is always asking
     * "is it shaped like this?", and every one of them has a next thing to try.
     */
    private fun tlv(bytes: ByteArray, at: Int, limit: Int = bytes.size): Tlv? {
        if (at < 0 || at + 2 > limit) return null
        val tag = bytes[at].toInt() and 0xff
        val first = bytes[at + 1].toInt() and 0xff
        var length: Int
        var from: Int
        if (first < 0x80) {
            length = first
            from = at + 2
        } else {
            // Long form: the low bits count the LENGTH bytes that follow. More than four would
            // not fit an Int, and no key structure is anywhere near that big.
            val count = first and 0x7f
            if (count == 0 || count > 4 || at + 2 + count > limit) return null
            length = 0
            for (i in 0 until count) {
                length = (length shl 8) or (bytes[at + 2 + i].toInt() and 0xff)
            }
            if (length < 0) return null
            from = at + 2 + count
        }
        val until = from + length
        if (until > limit || until < from) return null
        return Tlv(tag, from, until, until)
    }

    /** Decode an OID's contents to dotted form. */
    private fun oid(bytes: ByteArray, from: Int, until: Int): String? {
        if (from >= until) return null
        val out = StringBuilder()
        // The first byte packs the first TWO components: 40 * a + b.
        val first = bytes[from].toInt() and 0xff
        out.append(first / 40).append('.').append(first % 40)
        var value = 0L
        for (i in (from + 1) until until) {
            val byte = bytes[i].toInt() and 0xff
            value = (value shl 7) or (byte and 0x7f).toLong()
            if (byte and 0x80 == 0) {
                out.append('.').append(value)
                value = 0
            } else if (value > (Long.MAX_VALUE shr 7)) {
                return null
            }
        }
        return out.toString()
    }

    /**
     * The bit length of a DER INTEGER's contents, ignoring the sign byte DER adds.
     *
     * The leading-zero skip is NOT what makes the modulus come out right, and an earlier version of
     * this comment claimed it was ("counting it would report a 2048-bit modulus as 2056"). That was
     * false, and deleting the skip and re-running the corpus is what showed it: a zero top byte
     * contributes zero bits, and the whole-bytes term counts the same either way, so both spellings
     * answer 2048. What the skip actually buys is the degenerate case — an all-zero INTEGER answers
     * 0 instead of a byte count times eight.
     */
    private fun bitLength(bytes: ByteArray, from: Int, until: Int): Int {
        var at = from
        while (at < until && bytes[at].toInt() == 0) at += 1
        if (at >= until) return 0
        val top = bytes[at].toInt() and 0xff
        var bits = 0
        var probe = top
        while (probe != 0) {
            bits += 1
            probe = probe shr 1
        }
        return bits + (until - at - 1) * 8
    }

    // ------------------------------------------------------------------ identify ----

    /**
     * What kind of key this PEM holds. `type` is `unknown` when nothing here recognises it, which
     * is the answer the bootstrap turns into node's `ERR_CRYPTO_INVALID_KEY_OBJECT_TYPE`.
     */
    fun identify(pem: String): Identity {
        val label = label(pem) ?: return Identity("unknown")
        val der = der(pem) ?: return Identity("unknown")
        val outer = tlv(der, 0) ?: return Identity("unknown")
        if (outer.tag != TAG_SEQUENCE) return Identity("unknown")

        // PKCS#1 carries no algorithm identifier: the label is the only thing that says RSA.
        if (label == "RSA PRIVATE KEY") {
            // SEQ { INT version, INT modulus, … } — the modulus is the SECOND integer.
            val version = tlv(der, outer.from, outer.until) ?: return Identity("unknown")
            val modulus = tlv(der, version.next, outer.until) ?: return Identity("unknown")
            if (modulus.tag != TAG_INTEGER) return Identity("unknown")
            return Identity("rsa", "", bitLength(der, modulus.from, modulus.until))
        }
        if (label == "RSA PUBLIC KEY") {
            // SEQ { INT modulus, INT exponent } — here it is the FIRST.
            val modulus = tlv(der, outer.from, outer.until) ?: return Identity("unknown")
            if (modulus.tag != TAG_INTEGER) return Identity("unknown")
            return Identity("rsa", "", bitLength(der, modulus.from, modulus.until))
        }
        if (label == "EC PRIVATE KEY") {
            // SEC1: SEQ { INT 1, OCTET STRING, [0] { curve OID }, [1] { BIT STRING } }. The curve
            // lives in a context-specific [0], so its OID is one level in.
            val version = tlv(der, outer.from, outer.until) ?: return Identity("unknown")
            val privateKey = tlv(der, version.next, outer.until) ?: return Identity("unknown")
            var at = privateKey.next
            while (at < outer.until) {
                val element = tlv(der, at, outer.until) ?: return Identity("unknown")
                if (element.tag == 0xa0) {
                    val curveOid = tlv(der, element.from, element.until) ?: return Identity("unknown")
                    if (curveOid.tag != TAG_OID) return Identity("unknown")
                    val name = CURVES[oid(der, curveOid.from, curveOid.until)]
                        ?: return Identity("unknown")
                    return Identity("ec", name)
                }
                at = element.next
            }
            return Identity("unknown")
        }

        // PKCS#8 and SPKI both begin with an AlgorithmIdentifier, at different depths: PKCS#8 puts
        // an INTEGER version in front of it, SPKI leads with it.
        val first = tlv(der, outer.from, outer.until) ?: return Identity("unknown")
        val algorithm = when (first.tag) {
            TAG_INTEGER -> tlv(der, first.next, outer.until)
            TAG_SEQUENCE -> first
            else -> null
        } ?: return Identity("unknown")
        if (algorithm.tag != TAG_SEQUENCE) return Identity("unknown")

        val algorithmOid = tlv(der, algorithm.from, algorithm.until) ?: return Identity("unknown")
        if (algorithmOid.tag != TAG_OID) return Identity("unknown")
        return when (oid(der, algorithmOid.from, algorithmOid.until)) {
            OID_ED25519 -> Identity("ed25519")
            OID_ED448 -> Identity("ed448")
            OID_X25519 -> Identity("x25519")
            OID_X448 -> Identity("x448")
            OID_EC -> {
                // The curve is the AlgorithmIdentifier's PARAMETERS, beside the OID.
                val parameters = tlv(der, algorithmOid.next, algorithm.until)
                    ?: return Identity("unknown")
                if (parameters.tag != TAG_OID) return Identity("unknown")
                val curve = CURVES[oid(der, parameters.from, parameters.until)]
                    ?: return Identity("unknown")
                Identity("ec", curve)
            }
            OID_RSA -> Identity("rsa", "", rsaModulusLength(der, first, algorithm, outer))
            else -> Identity("unknown")
        }
    }

    /**
     * The modulus length of an RSA key wrapped in PKCS#8 or SPKI.
     *
     * Both wrappers hold a PKCS#1 structure inside — an OCTET STRING for the private form, a BIT
     * STRING for the public one — so the modulus is one decode further in. A BIT STRING's contents
     * begin with a count of unused trailing bits, which is 0 here and is skipped rather than parsed
     * as DER.
     */
    private fun rsaModulusLength(der: ByteArray, first: Tlv, algorithm: Tlv, outer: Tlv): Int {
        val wrapper = tlv(der, algorithm.next, outer.until) ?: return 0
        val inner = when (wrapper.tag) {
            TAG_OCTET_STRING -> wrapper.from
            TAG_BIT_STRING -> wrapper.from + 1
            else -> return 0
        }
        val sequence = tlv(der, inner, wrapper.until) ?: return 0
        if (sequence.tag != TAG_SEQUENCE) return 0
        val leading = tlv(der, sequence.from, sequence.until) ?: return 0
        // PKCS#8 wraps an RSAPrivateKey, which leads with a version INTEGER before the modulus;
        // SPKI wraps an RSAPublicKey, whose first INTEGER already IS the modulus. `first.tag`
        // says which wrapper this was.
        val modulus = if (first.tag == TAG_INTEGER) {
            tlv(der, leading.next, sequence.until) ?: return 0
        } else {
            leading
        }
        if (modulus.tag != TAG_INTEGER) return 0
        return bitLength(der, modulus.from, modulus.until)
    }

    // --------------------------------------------------------------- DER writing ----
    //
    // The JCA accepts exactly two encodings — `PKCS8EncodedKeySpec` and `X509EncodedKeySpec` — and
    // node's callers hand over four more. SEC1 and both PKCS#1 forms are the same key material
    // under a thinner wrapper, so they are re-wrapped rather than re-parsed: the inner bytes are
    // copied through untouched and only the envelope is built here.

    /** A DER length header: short form under 128, long form above it. */
    private fun length(size: Int): ByteArray {
        if (size < 0x80) return byteArrayOf(size.toByte())
        var bytes = 0
        var probe = size
        while (probe > 0) {
            bytes += 1
            probe = probe ushr 8
        }
        val out = ByteArray(bytes + 1)
        out[0] = (0x80 or bytes).toByte()
        for (i in 0 until bytes) out[bytes - i] = (size ushr (8 * i)).toByte()
        return out
    }

    /** Tag, length, value. */
    private fun encode(tag: Int, content: ByteArray): ByteArray {
        val header = length(content.size)
        val out = ByteArray(1 + header.size + content.size)
        out[0] = tag.toByte()
        header.copyInto(out, 1)
        content.copyInto(out, 1 + header.size)
        return out
    }

    private fun sequence(vararg parts: ByteArray): ByteArray =
        encode(TAG_SEQUENCE, parts.reduceOrNull { a, b -> a + b } ?: ByteArray(0))

    /** A dotted OID back to its DER contents — the inverse of [oid]. */
    private fun oidDer(dotted: String): ByteArray {
        val parts = dotted.split('.').map { it.toLong() }
        val body = ArrayList<Byte>()
        body.add((parts[0] * 40 + parts[1]).toByte())
        for (part in parts.drop(2)) {
            // Base 128, most significant group first, every group but the last flagged.
            val group = ArrayList<Byte>()
            var value = part
            do {
                group.add(0, (value and 0x7f).toByte())
                value = value shr 7
            } while (value > 0)
            for (i in 0 until group.size - 1) group[i] = (group[i].toInt() or 0x80).toByte()
            body.addAll(group)
        }
        return encode(TAG_OID, body.toByteArray())
    }

    /** ASN.1 NULL, which RSA's AlgorithmIdentifier carries as its parameters. */
    private val DER_NULL = byteArrayOf(0x05, 0x00)

    /**
     * Any private key PEM as PKCS#8 DER, which is the only private encoding `KeyFactory` reads.
     *
     * PKCS#8 passes through. SEC1 and PKCS#1 are wrapped: their bodies are already the exact
     * `privateKey` OCTET STRING contents that PKCS#8 expects, so the only new bytes are the
     * version, the algorithm identifier, and two headers.
     */
    fun pkcs8(pem: String): ByteArray? {
        val label = label(pem) ?: return null
        val der = der(pem) ?: return null
        val identity = identify(pem)
        return when (label) {
            "PRIVATE KEY" -> der
            "EC PRIVATE KEY" -> {
                val curve = CURVE_OIDS[identity.curve] ?: return null
                sequence(
                    encode(TAG_INTEGER, byteArrayOf(0)),
                    sequence(oidDer(OID_EC), oidDer(curve)),
                    encode(TAG_OCTET_STRING, der),
                )
            }
            "RSA PRIVATE KEY" -> sequence(
                encode(TAG_INTEGER, byteArrayOf(0)),
                sequence(oidDer(OID_RSA), DER_NULL),
                encode(TAG_OCTET_STRING, der),
            )
            else -> null
        }
    }

    /**
     * Any public key PEM as SPKI DER.
     *
     * The BIT STRING gets a leading 0x00 — its count of unused trailing bits, which is always zero
     * for a whole number of bytes. Omitting it shifts every byte of the key by one position and
     * produces a key that parses and is wrong.
     */
    fun spki(pem: String): ByteArray? {
        val label = label(pem) ?: return null
        val der = der(pem) ?: return null
        return when (label) {
            "PUBLIC KEY" -> der
            "RSA PUBLIC KEY" -> sequence(
                sequence(oidDer(OID_RSA), DER_NULL),
                encode(TAG_BIT_STRING, byteArrayOf(0) + der),
            )
            else -> null
        }
    }

    // ------------------------------------------------------------ signing the JCA ----

    /** node's key type → the JCA's `KeyFactory`/`Signature` family name. */
    private fun family(type: String): String? = when (type) {
        "ec" -> "EC"
        "rsa" -> "RSA"
        "ed25519" -> "Ed25519"
        "ed448" -> "Ed448"
        else -> null
    }

    /** node's digest name → the JCA's, for the `<digest>with<family>` signature names. */
    private val SIGNATURE_DIGESTS = mapOf(
        "sha1" to "SHA1", "sha224" to "SHA224", "sha256" to "SHA256",
        "sha384" to "SHA384", "sha512" to "SHA512",
    )

    /**
     * OpenSSL's legacy digest names, which real libraries actually use.
     *
     * `crypto.createSign` takes an OpenSSL algorithm name, not a bare digest, and node accepts the
     * whole family: `jwa` signs RS256 by asking for **`RSA-SHA256`**, certificates use
     * `ecdsa-with-SHA256`, and the prefix is historical — it works for any key type in node, not
     * only the one it names.
     *
     * This is a straight port of `NodeEngine.swift`'s `digestName`, which exists for the same
     * reason and was NOT ported when the signing half landed. The corpus could not see the gap
     * because every check in it passes the digest node's short way, the way a hand-written test
     * does; `jsonwebtoken` on the device found it in one run, which is what a real package is for.
     */
    private fun digestName(raw: String): String {
        var normalized = raw.lowercase().replace("-", "")
        for (prefix in listOf("rsassapss", "rsa", "ecdsawith", "ecdsa")) {
            if (normalized.startsWith(prefix)) {
                normalized = normalized.drop(prefix.length)
                break
            }
        }
        return normalized
    }

    /**
     * The `Signature` algorithm for a key and a digest.
     *
     * Ed25519 takes NO digest — it signs the message itself, which is why the bootstrap raises
     * node's `ERR_OSSL_INVALID_DIGEST` when a caller names one — so its algorithm is the bare
     * curve name and the digest argument is ignored here rather than folded in.
     */
    private fun signatureName(type: String, digest: String): String? = when (type) {
        "ed25519" -> "Ed25519"
        "ed448" -> "Ed448"
        "ec" -> SIGNATURE_DIGESTS[digestName(digest)]?.let { "${it}withECDSA" }
        "rsa" -> SIGNATURE_DIGESTS[digestName(digest)]?.let { "${it}withRSA" }
        else -> null
    }

    private fun privateKey(pem: String, identity: Identity): java.security.PrivateKey? {
        val name = family(identity.type) ?: return null
        val der = pkcs8(pem) ?: return null
        return runCatching {
            java.security.KeyFactory.getInstance(name)
                .generatePrivate(java.security.spec.PKCS8EncodedKeySpec(der))
        }.getOrNull()
    }

    private fun publicKey(pem: String, identity: Identity): java.security.PublicKey? {
        val name = family(identity.type) ?: return null
        val der = spki(pem) ?: return null
        return runCatching {
            java.security.KeyFactory.getInstance(name)
                .generatePublic(java.security.spec.X509EncodedKeySpec(der))
        }.getOrNull()
    }

    /**
     * How many bytes each half of a raw ECDSA signature occupies.
     *
     * P-521 is the one that catches people: 521 bits rounds UP to 66 bytes, not 65, and a
     * signature built at 65 is silently wrong for one key in every few hundred.
     */
    private fun coordinateSize(curve: String): Int? = when (curve) {
        "prime256v1" -> 32
        "secp384r1" -> 48
        "secp521r1" -> 66
        else -> null
    }

    /**
     * A DER `SEQUENCE { INTEGER r, INTEGER s }` to the fixed-width `r || s` node calls
     * `ieee-p1363`.
     *
     * The JCA only ever emits DER; node emits whichever the caller asked for, so this conversion
     * is not optional for anyone using `dsaEncoding: 'ieee-p1363'` — WebCrypto and JWT libraries
     * being the common cases.
     */
    private fun derToRaw(signature: ByteArray, width: Int): ByteArray? {
        val outer = tlv(signature, 0) ?: return null
        if (outer.tag != TAG_SEQUENCE) return null
        val r = tlv(signature, outer.from, outer.until) ?: return null
        val s = tlv(signature, r.next, outer.until) ?: return null
        if (r.tag != TAG_INTEGER || s.tag != TAG_INTEGER) return null
        val out = ByteArray(width * 2)
        if (!place(signature, r, out, 0, width)) return null
        if (!place(signature, s, out, width, width)) return null
        return out
    }

    /** Right-align one DER INTEGER's magnitude into a fixed-width slot. */
    private fun place(source: ByteArray, value: Tlv, into: ByteArray, at: Int, width: Int): Boolean {
        var from = value.from
        while (from < value.until && source[from].toInt() == 0) from += 1
        val size = value.until - from
        if (size > width) return false
        source.copyInto(into, at + width - size, from, value.until)
        return true
    }

    /** The inverse: fixed-width `r || s` back to DER, for verifying a raw signature. */
    private fun rawToDer(signature: ByteArray): ByteArray? {
        if (signature.size % 2 != 0 || signature.isEmpty()) return null
        val half = signature.size / 2
        val r = java.math.BigInteger(1, signature.copyOfRange(0, half))
        val s = java.math.BigInteger(1, signature.copyOfRange(half, signature.size))
        return sequence(
            encode(TAG_INTEGER, r.toByteArray()),
            encode(TAG_INTEGER, s.toByteArray()),
        )
    }

    /**
     * `crypto.sign` for EC and Ed25519 — the bridge's `keySign`.
     *
     * Null means "I could not", which is what the bootstrap turns into node's
     * `ERR_CRYPTO_OPERATION_FAILED`. Every failure route answers null rather than throwing,
     * including a key type this does not handle and a JCA that has no provider for it — Ed25519
     * arrived at API 33 against this app's minSdk 26, so on an older device the provider genuinely
     * is not there and a refusal is the honest answer.
     */
    fun sign(pem: String, dataBase64: String, algorithm: String, raw: Boolean): String? {
        val identity = identify(pem)
        val data = decode(dataBase64) ?: return null
        val name = signatureName(identity.type, algorithm) ?: return null
        val key = privateKey(pem, identity) ?: return null
        val signature = runCatching {
            val signer = java.security.Signature.getInstance(name)
            signer.initSign(key)
            signer.update(data)
            signer.sign()
        }.getOrNull() ?: return null
        if (!raw || identity.type != "ec") return Base64.getEncoder().encodeToString(signature)
        val width = coordinateSize(identity.curve) ?: return null
        val flat = derToRaw(signature, width) ?: return null
        return Base64.getEncoder().encodeToString(flat)
    }

    /** `crypto.verify` — the bridge's `keyVerify`. A malformed signature is `false`, never a throw. */
    fun verify(
        pem: String,
        dataBase64: String,
        signatureBase64: String,
        algorithm: String,
        raw: Boolean,
    ): Boolean {
        val identity = identify(pem)
        val data = decode(dataBase64) ?: return false
        val given = decode(signatureBase64) ?: return false
        val name = signatureName(identity.type, algorithm) ?: return false
        // A public operation accepts either half of the pair: node lets you verify with the
        // private key, and a caller who has one often does not have the other to hand.
        val key = publicKey(pem, identity)
            ?: privateKey(pem, identity)?.let { derivePublic(it, identity) }
            ?: return false
        val signature = if (raw && identity.type == "ec") rawToDer(given) ?: return false else given
        return runCatching {
            val verifier = java.security.Signature.getInstance(name)
            verifier.initVerify(key)
            verifier.update(data)
            verifier.verify(signature)
        }.getOrDefault(false)
    }

    /**
     * The public key that belongs to a private one, so that `verify` accepts either half — node
     * does, and a caller holding one often does not have the other to hand.
     *
     * The JCA has no "give me the public half" call, and computing one means multiplying the
     * private scalar by the curve's generator: real curve arithmetic, which this module has no
     * business implementing by hand. So each type is served by whatever route avoids that:
     *
     *  - RSA — the private key already CARRIES the public pair. A CRT key exposes the modulus and
     *    the public exponent, and those two numbers are the whole public key.
     *  - EC — the SEC1 body carries the public point as its `[1]` field, and PKCS#8 keeps that body
     *    verbatim, so it is read back out rather than recomputed.
     *  - Ed25519/Ed448 — NEITHER route exists. The encoded private key is the 32-byte seed and
     *    nothing else, and the public half is SHA-512 of that seed followed by a scalar
     *    multiplication on the Edwards curve. So this answers null and `verify` refuses, which is a
     *    real divergence from node and is gated as one rather than left to be discovered.
     */
    private fun derivePublic(
        key: java.security.PrivateKey,
        identity: Identity,
    ): java.security.PublicKey? = when (identity.type) {
        "rsa" -> (key as? java.security.interfaces.RSAPrivateCrtKey)?.let { crt ->
            runCatching {
                java.security.KeyFactory.getInstance("RSA").generatePublic(
                    java.security.spec.RSAPublicKeySpec(crt.modulus, crt.publicExponent),
                )
            }.getOrNull()
        }
        "ec" -> {
            val point = key.encoded?.let { ecPublicPoint(it) }
            val curve = CURVE_OIDS[identity.curve]
            if (point == null || curve == null) {
                null
            } else {
                runCatching {
                    java.security.KeyFactory.getInstance("EC").generatePublic(
                        java.security.spec.X509EncodedKeySpec(
                            sequence(
                                sequence(oidDer(OID_EC), oidDer(curve)),
                                encode(TAG_BIT_STRING, byteArrayOf(0) + point),
                            ),
                        ),
                    )
                }.getOrNull()
            }
        }
        else -> null
    }

    /** The `[1] BIT STRING` public point inside a PKCS#8-wrapped SEC1 `ECPrivateKey`. */
    private fun ecPublicPoint(pkcs8: ByteArray): ByteArray? {
        val outer = tlv(pkcs8, 0) ?: return null
        val version = tlv(pkcs8, outer.from, outer.until) ?: return null
        val algorithm = tlv(pkcs8, version.next, outer.until) ?: return null
        val wrapper = tlv(pkcs8, algorithm.next, outer.until) ?: return null
        if (wrapper.tag != TAG_OCTET_STRING) return null
        val sec1 = tlv(pkcs8, wrapper.from, wrapper.until) ?: return null
        if (sec1.tag != TAG_SEQUENCE) return null
        var at = sec1.from
        while (at < sec1.until) {
            val element = tlv(pkcs8, at, sec1.until) ?: return null
            if (element.tag == 0xa1) {
                val bits = tlv(pkcs8, element.from, element.until) ?: return null
                if (bits.tag != TAG_BIT_STRING) return null
                // Past the unused-bits count, which is the byte the BIT STRING leads with.
                return pkcs8.copyOfRange(bits.from + 1, bits.until)
            }
            at = element.next
        }
        return null
    }

    private fun decode(base64: String): ByteArray? =
        runCatching { Base64.getDecoder().decode(base64) }.getOrNull()

    // ------------------------------------------------------------------ RSA-PSS ----

    /**
     * `crypto.sign`/`verify` for RSA — the bridge's `rsaSign` and `rsaVerify`.
     *
     * PKCS#1 v1.5 goes through the same `Signature` as everything else; PSS needs its parameters
     * spelled out, because the JCA's `RSASSA-PSS` has no defaults worth relying on. The salt is the
     * digest's own length, which is what node uses when a caller names PSS padding without saying
     * more, and MGF1 over the same digest — get either wrong and signatures verify nowhere.
     */
    fun rsaSign(pem: String, dataBase64: String, algorithm: String, pss: Boolean): String? {
        if (!pss) return sign(pem, dataBase64, algorithm, false)
        val identity = identify(pem)
        if (identity.type != "rsa") return null
        val data = decode(dataBase64) ?: return null
        val key = privateKey(pem, identity) ?: return null
        val signer = pssSignature(algorithm) ?: return null
        return runCatching {
            signer.initSign(key)
            signer.update(data)
            Base64.getEncoder().encodeToString(signer.sign())
        }.getOrNull()
    }

    /** @see rsaSign */
    fun rsaVerify(
        pem: String,
        dataBase64: String,
        signatureBase64: String,
        algorithm: String,
        pss: Boolean,
    ): Boolean {
        if (!pss) return verify(pem, dataBase64, signatureBase64, algorithm, false)
        val identity = identify(pem)
        if (identity.type != "rsa") return false
        val data = decode(dataBase64) ?: return false
        val signature = decode(signatureBase64) ?: return false
        val key = publicKey(pem, identity)
            ?: privateKey(pem, identity)?.let { derivePublic(it, identity) }
            ?: return false
        val verifier = pssSignature(algorithm) ?: return false
        return runCatching {
            verifier.initVerify(key)
            verifier.update(data)
            verifier.verify(signature)
        }.getOrDefault(false)
    }

    /**
     * A `Signature` set up for RSA-PSS, under whichever name this platform registers it.
     *
     * The two providers do not agree, and the JVM corpus could not have told us: a JDK harness gets
     * SunRsaSign, which registers the generic `RSASSA-PSS` and takes its parameters through
     * `setParameter`. Android ships **Conscrypt**, which does not register that name at all — it
     * registers `SHA256withRSA/PSS` and its siblings, with the digest baked into the name. Asking
     * for `RSASSA-PSS` there throws `NoSuchAlgorithmException`, `rsaSign` answered null, and the
     * bootstrap raised node's `ERR_CRYPTO_OPERATION_FAILED`.
     *
     * That is precisely what [NodeKeysSmoke] exists to catch, and it caught it on its first run
     * with 781 JVM checks green: plain PKCS#1 v1.5 signing passed on the phone and PSS did not.
     *
     * Parameters are set explicitly on BOTH paths where the provider allows it. Conscrypt's
     * digest-named algorithms already default to MGF1 over the same digest with a salt the length
     * of that digest — which is what node uses and what the JVM corpus pins — but relying on a
     * default to agree with another provider's default is how the two silently drift apart.
     */
    private fun pssSignature(algorithm: String): java.security.Signature? {
        val digest = SIGNATURE_DIGESTS[digestName(algorithm)] ?: return null
        val parameters = pssParameters(algorithm) ?: return null
        val generic = runCatching {
            java.security.Signature.getInstance("RSASSA-PSS").also { it.setParameter(parameters) }
        }.getOrNull()
        if (generic != null) return generic
        val named = runCatching {
            java.security.Signature.getInstance("${digest}withRSA/PSS")
        }.getOrNull() ?: return null
        // Conscrypt accepts these; if a provider does not, its own defaults are already the values
        // being asked for, so the signature is the same either way.
        runCatching { named.setParameter(parameters) }
        return named
    }

    private fun pssParameters(algorithm: String): java.security.spec.PSSParameterSpec? {
        val digest = SIGNATURE_DIGESTS[digestName(algorithm)] ?: return null
        val jca = when (digest) {
            "SHA1" -> "SHA-1"
            else -> digest.replaceFirst("SHA", "SHA-")
        }
        val saltLength = when (digest) {
            "SHA1" -> 20
            "SHA224" -> 28
            "SHA256" -> 32
            "SHA384" -> 48
            "SHA512" -> 64
            else -> return null
        }
        return java.security.spec.PSSParameterSpec(
            jca, "MGF1", java.security.spec.MGF1ParameterSpec(jca), saltLength, 1,
        )
    }

    // --------------------------------------------------------------- generation ----

    /** DER to a PEM block, wrapped at 64 characters as every other producer writes it. */
    private fun pem(label: String, der: ByteArray): String {
        val body = Base64.getEncoder().encodeToString(der)
        val lines = StringBuilder()
        var at = 0
        while (at < body.length) {
            val end = minOf(at + 64, body.length)
            lines.append(body, at, end).append('\n')
            at = end
        }
        return "-----BEGIN $label-----\n$lines-----END $label-----\n"
    }

    /**
     * `crypto.generateKeyPairSync` for EC, Ed25519 and X25519 — the bridge's `keyGenerate`.
     *
     * Returns (public PEM, private PEM). The JCA hands back SPKI and PKCS#8 from `getEncoded`,
     * which are exactly the two encodings [identify] reads, so a generated key goes straight back
     * through the front door.
     *
     * A null answer covers both "no such curve" and "this device has no provider for it" — the
     * second is real on Android, where Ed25519 and X25519 arrived at API 33 against a minSdk of
     * 26. The bootstrap raises `ERR_CRYPTO_INVALID_CURVE` either way, which is the honest error
     * when the key cannot be made here.
     */
    fun generate(kind: String, curve: String): Pair<String, String>? {
        val algorithm = when (kind) {
            "ec" -> "EC"
            "ed25519" -> "Ed25519"
            "ed448" -> "Ed448"
            "x25519" -> "X25519"
            "x448" -> "X448"
            else -> return null
        }
        val jcaCurve = if (kind == "ec") JCA_CURVES[curve] ?: return null else ""
        return runCatching {
            val generator = java.security.KeyPairGenerator.getInstance(algorithm)
            if (kind == "ec") generator.initialize(java.security.spec.ECGenParameterSpec(jcaCurve))
            val pair = generator.generateKeyPair()
            pem("PUBLIC KEY", pair.public.encoded) to pem("PRIVATE KEY", pair.private.encoded)
        }.getOrNull()
    }

    /** `crypto.generateKeyPairSync('rsa', …)` — the bridge's `rsaGenerate`. */
    fun rsaGenerate(modulusLength: Int): Pair<String, String>? {
        if (modulusLength < 512 || modulusLength > 8192) return null
        return runCatching {
            val generator = java.security.KeyPairGenerator.getInstance("RSA")
            generator.initialize(modulusLength)
            val pair = generator.generateKeyPair()
            pem("PUBLIC KEY", pair.public.encoded) to pem("PRIVATE KEY", pair.private.encoded)
        }.getOrNull()
    }

    // --------------------------------------------------------------------- ECDH ----
    //
    // `createECDH` does NOT speak PEM. Its keys are raw: the private one is the scalar, and the
    // public one is the uncompressed point `0x04 || X || Y` that node calls a public key and
    // OpenSSL calls octet form. So this half of the work is the opposite of the parser's — the
    // key material arrives with no envelope at all, and the curve's parameters have to be fetched
    // by name to give it meaning.

    /** The JCA's parameters for a named curve, which raw key material needs to be interpreted. */
    private fun curveParameters(curve: String): java.security.spec.ECParameterSpec? =
        runCatching {
            val parameters = java.security.AlgorithmParameters.getInstance("EC")
            parameters.init(java.security.spec.ECGenParameterSpec(JCA_CURVES[curve] ?: curve))
            parameters.getParameterSpec(java.security.spec.ECParameterSpec::class.java)
        }.getOrNull()

    /** Fixed-width big-endian bytes, which is how a coordinate and a scalar both travel. */
    private fun fixed(value: java.math.BigInteger, width: Int): ByteArray? {
        val bytes = value.toByteArray()
        val from = if (bytes.size > width && bytes[0].toInt() == 0) 1 else 0
        val size = bytes.size - from
        if (size > width) return null
        val out = ByteArray(width)
        bytes.copyInto(out, width - size, from, bytes.size)
        return out
    }

    /** `ecdh.generateKeys()` — (private scalar, uncompressed point), both base64. */
    fun ecdhGenerate(curve: String): Pair<String, String>? {
        val width = coordinateSize(curve) ?: return null
        val jcaCurve = JCA_CURVES[curve] ?: return null
        return runCatching {
            val generator = java.security.KeyPairGenerator.getInstance("EC")
            generator.initialize(java.security.spec.ECGenParameterSpec(jcaCurve))
            val pair = generator.generateKeyPair()
            val private = pair.private as java.security.interfaces.ECPrivateKey
            val public = pair.public as java.security.interfaces.ECPublicKey
            val scalar = fixed(private.s, width) ?: return null
            val x = fixed(public.w.affineX, width) ?: return null
            val y = fixed(public.w.affineY, width) ?: return null
            Base64.getEncoder().encodeToString(scalar) to
                Base64.getEncoder().encodeToString(byteArrayOf(0x04) + x + y)
        }.getOrNull()
    }

    /**
     * `ecdh.computeSecret(peer)` — the bridge's `ecdhCompute`.
     *
     * The secret is the X coordinate of the shared point and nothing else, which is what
     * `KeyAgreement.generateSecret()` returns and what node returns. Neither hashes it; a caller
     * who wants a key runs it through a KDF, and doing that here would silently change the answer.
     */
    fun ecdhCompute(curve: String, privateBase64: String, peerBase64: String): String? {
        val width = coordinateSize(curve) ?: return null
        val parameters = curveParameters(curve) ?: return null
        val scalar = decode(privateBase64) ?: return null
        val peer = decode(peerBase64) ?: return null
        // Only the uncompressed form is accepted. A compressed point would need the curve equation
        // solved for Y, and answering null is what raises node's ERR_CRYPTO_ECDH_INVALID_PUBLIC_KEY.
        if (peer.size != 1 + width * 2 || peer[0].toInt() != 0x04) return null
        return runCatching {
            val factory = java.security.KeyFactory.getInstance("EC")
            val private = factory.generatePrivate(
                java.security.spec.ECPrivateKeySpec(java.math.BigInteger(1, scalar), parameters),
            )
            val point = java.security.spec.ECPoint(
                java.math.BigInteger(1, peer.copyOfRange(1, 1 + width)),
                java.math.BigInteger(1, peer.copyOfRange(1 + width, peer.size)),
            )
            val public = factory.generatePublic(
                java.security.spec.ECPublicKeySpec(point, parameters),
            )
            val agreement = javax.crypto.KeyAgreement.getInstance("ECDH")
            agreement.init(private)
            agreement.doPhase(public, true)
            Base64.getEncoder().encodeToString(agreement.generateSecret())
        }.getOrNull()
    }

    /**
     * `crypto.diffieHellman({ privateKey, publicKey })` — the bridge's `keyAgree`, over PEM.
     *
     * X25519 and X448 agree through `XDH`; the NIST curves through `ECDH`. The algorithm name has
     * to match the key, so it comes from the identity rather than from a guess.
     */
    fun agree(privatePem: String, publicPem: String): String? {
        val identity = identify(privatePem)
        val algorithm = when (identity.type) {
            "ec" -> "ECDH"
            "x25519", "x448" -> "XDH"
            else -> return null
        }
        val family = when (identity.type) {
            "ec" -> "EC"
            "x25519" -> "X25519"
            else -> "X448"
        }
        val privateDer = pkcs8(privatePem) ?: return null
        val publicDer = spki(publicPem) ?: return null
        return runCatching {
            val factory = java.security.KeyFactory.getInstance(family)
            val private = factory.generatePrivate(
                java.security.spec.PKCS8EncodedKeySpec(privateDer),
            )
            val public = factory.generatePublic(java.security.spec.X509EncodedKeySpec(publicDer))
            val agreement = javax.crypto.KeyAgreement.getInstance(algorithm)
            agreement.init(private)
            agreement.doPhase(public, true)
            Base64.getEncoder().encodeToString(agreement.generateSecret())
        }.getOrNull()
    }

    // ------------------------------------------------------------- RSA as a cipher ----

    /** node's padding constants, as `crypto.constants` numbers the bootstrap passes through. */
    private const val PADDING_PKCS1 = 1
    private const val PADDING_OAEP = 4

    /**
     * OAEP parameters, spelled out rather than folded into a transformation name.
     *
     * `RSA/ECB/OAEPWithSHA-256AndMGF1Padding` looks like the shorter route and is a trap: on some
     * providers that name uses SHA-256 for the digest and SHA-1 for MGF1, which is not what node
     * does and produces ciphertext the other side cannot open. Naming both explicitly removes the
     * ambiguity.
     */
    private fun oaepParameters(digest: String): javax.crypto.spec.OAEPParameterSpec? {
        val name = when (digestName(digest)) {
            "sha1" -> "SHA-1"
            "sha224" -> "SHA-224"
            "sha256" -> "SHA-256"
            "sha384" -> "SHA-384"
            "sha512" -> "SHA-512"
            else -> return null
        }
        val mgf1 = when (name) {
            "SHA-1" -> java.security.spec.MGF1ParameterSpec.SHA1
            "SHA-224" -> java.security.spec.MGF1ParameterSpec.SHA224
            "SHA-256" -> java.security.spec.MGF1ParameterSpec.SHA256
            "SHA-384" -> java.security.spec.MGF1ParameterSpec.SHA384
            else -> java.security.spec.MGF1ParameterSpec.SHA512
        }
        return javax.crypto.spec.OAEPParameterSpec(
            name, "MGF1", mgf1, javax.crypto.spec.PSource.PSpecified.DEFAULT,
        )
    }

    /** `crypto.publicEncrypt` — the bridge's `rsaEncrypt`. */
    fun rsaEncrypt(pem: String, dataBase64: String, padding: Int, digest: String): String? {
        val identity = identify(pem)
        if (identity.type != "rsa") return null
        val data = decode(dataBase64) ?: return null
        val key = publicKey(pem, identity)
            ?: privateKey(pem, identity)?.let { derivePublic(it, identity) }
            ?: return null
        return runCatching {
            val cipher = when (padding) {
                PADDING_OAEP -> javax.crypto.Cipher.getInstance("RSA/ECB/OAEPPadding").also {
                    it.init(javax.crypto.Cipher.ENCRYPT_MODE, key, oaepParameters(digest) ?: return null)
                }
                PADDING_PKCS1 -> javax.crypto.Cipher.getInstance("RSA/ECB/PKCS1Padding").also {
                    it.init(javax.crypto.Cipher.ENCRYPT_MODE, key)
                }
                else -> return null
            }
            Base64.getEncoder().encodeToString(cipher.doFinal(data))
        }.getOrNull()
    }

    /** `crypto.privateDecrypt` — the bridge's `rsaDecrypt`. */
    fun rsaDecrypt(pem: String, dataBase64: String, padding: Int, digest: String): String? {
        val identity = identify(pem)
        if (identity.type != "rsa") return null
        val data = decode(dataBase64) ?: return null
        val key = privateKey(pem, identity) ?: return null
        return runCatching {
            val cipher = when (padding) {
                PADDING_OAEP -> javax.crypto.Cipher.getInstance("RSA/ECB/OAEPPadding").also {
                    it.init(javax.crypto.Cipher.DECRYPT_MODE, key, oaepParameters(digest) ?: return null)
                }
                PADDING_PKCS1 -> javax.crypto.Cipher.getInstance("RSA/ECB/PKCS1Padding").also {
                    it.init(javax.crypto.Cipher.DECRYPT_MODE, key)
                }
                else -> return null
            }
            Base64.getEncoder().encodeToString(cipher.doFinal(data))
        }.getOrNull()
    }

    /**
     * `crypto.privateEncrypt` — a PRIVATE-key exponentiation over PKCS#1 type 1 padding.
     *
     * This is the signing primitive used as a cipher, and it is what a caller reaches for to prove
     * origin without a digest — the pattern licence keys and some older token formats use. The JCA
     * reaches it by initialising the ordinary PKCS#1 cipher for ENCRYPT with a private key, which
     * selects type 1 padding; the same class does type 2 when the key is public.
     */
    fun rsaPrivateEncrypt(pem: String, dataBase64: String): String? {
        val identity = identify(pem)
        if (identity.type != "rsa") return null
        val data = decode(dataBase64) ?: return null
        val key = privateKey(pem, identity) ?: return null
        return runCatching {
            val cipher = javax.crypto.Cipher.getInstance("RSA/ECB/PKCS1Padding")
            cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, key)
            Base64.getEncoder().encodeToString(cipher.doFinal(data))
        }.getOrNull()
    }

    /** `crypto.publicDecrypt` — the other half of [rsaPrivateEncrypt]. */
    fun rsaPublicDecrypt(pem: String, dataBase64: String): String? {
        val identity = identify(pem)
        if (identity.type != "rsa") return null
        val data = decode(dataBase64) ?: return null
        val key = publicKey(pem, identity)
            ?: privateKey(pem, identity)?.let { derivePublic(it, identity) }
            ?: return null
        return runCatching {
            val cipher = javax.crypto.Cipher.getInstance("RSA/ECB/PKCS1Padding")
            cipher.init(javax.crypto.Cipher.DECRYPT_MODE, key)
            Base64.getEncoder().encodeToString(cipher.doFinal(data))
        }.getOrNull()
    }
}
