import Foundation
import Security

/// RSA for the Node layer (system.md phase G): what `crypto` needs for RS256 — by far the most
/// common JWT algorithm — plus package-signature verification and OAEP encryption.
///
/// CryptoKit has no RSA, so this rides Security framework's `SecKey`. The catch is format:
/// `SecKey` speaks **PKCS#1** (`RSAPrivateKey` / `RSAPublicKey`), while node hands out
/// **PKCS#8** and **SPKI** ("BEGIN PRIVATE KEY" / "BEGIN PUBLIC KEY"). Both wrappers are a
/// fixed ASN.1 shape around the PKCS#1 body, so the DER here is a deliberately small reader
/// and writer for exactly that unwrap and rewrap — not a general ASN.1 implementation, which
/// would be a much larger thing to get right.
enum NodeKeys {

    // MARK: - Minimal DER

    /// One TLV: its tag, the range of its contents, and where the next one starts.
    private struct Element {
        let tag: UInt8
        let contents: Range<Int>
        let end: Int
    }

    /// Read the element starting at `index`. Returns nil on anything malformed rather than
    /// guessing — a key we cannot parse must fail loudly, not silently half-work.
    private static func element(in data: Data, at index: Int) -> Element? {
        guard index < data.count else { return nil }
        let tag = data[data.startIndex + index]
        var cursor = index + 1
        guard cursor < data.count else { return nil }
        let first = data[data.startIndex + cursor]
        cursor += 1
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7f)
            guard count > 0, count <= 4, cursor + count <= data.count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(data[data.startIndex + cursor])
                cursor += 1
            }
        }
        guard cursor + length <= data.count else { return nil }
        return Element(tag: tag, contents: cursor..<(cursor + length), end: cursor + length)
    }

    private static func body(_ data: Data, _ range: Range<Int>) -> Data {
        Data(data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)])
    }

    /// DER length bytes for a given content length.
    private static func lengthBytes(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func wrap(_ tag: UInt8, _ contents: Data) -> Data {
        Data([tag]) + lengthBytes(contents.count) + contents
    }

    /// `SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }` — the rsaEncryption algorithm identifier
    /// both wrappers carry.
    private static let rsaAlgorithmIdentifier = Data([
        0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
    ])

    // MARK: - Between node's formats and SecKey's

    /// PKCS#8 `PrivateKeyInfo` → the PKCS#1 `RSAPrivateKey` inside it. A key that is already
    /// PKCS#1 passes through, which is what "BEGIN RSA PRIVATE KEY" PEMs contain.
    static func pkcs1PrivateKey(from der: Data) -> Data? {
        guard let outer = element(in: der, at: 0), outer.tag == 0x30 else { return nil }
        guard let version = element(in: der, at: outer.contents.lowerBound) else { return nil }
        // PKCS#1 begins INTEGER(0) then INTEGER(modulus); PKCS#8 begins INTEGER(0) then SEQUENCE.
        guard let second = element(in: der, at: version.end) else { return nil }
        if second.tag == 0x02 { return der }                       // already PKCS#1
        guard second.tag == 0x30 else { return nil }               // AlgorithmIdentifier
        guard let key = element(in: der, at: second.end), key.tag == 0x04 else { return nil }
        return body(der, key.contents)
    }

    /// SPKI `SubjectPublicKeyInfo` → the PKCS#1 `RSAPublicKey` in its BIT STRING.
    static func pkcs1PublicKey(from der: Data) -> Data? {
        guard let outer = element(in: der, at: 0), outer.tag == 0x30 else { return nil }
        guard let first = element(in: der, at: outer.contents.lowerBound) else { return nil }
        if first.tag == 0x02 { return der }                        // already PKCS#1
        guard first.tag == 0x30 else { return nil }
        guard let bits = element(in: der, at: first.end), bits.tag == 0x03 else { return nil }
        let contents = body(der, bits.contents)
        // A BIT STRING's first byte counts unused bits; for a key it is always zero.
        guard let unused = contents.first, unused == 0 else { return nil }
        return contents.dropFirst()
    }

    static func pkcs8(from pkcs1: Data) -> Data {
        let version = wrap(0x02, Data([0x00]))
        return wrap(0x30, version + rsaAlgorithmIdentifier + wrap(0x04, pkcs1))
    }

    static func spki(from pkcs1: Data) -> Data {
        wrap(0x30, rsaAlgorithmIdentifier + wrap(0x03, Data([0x00]) + pkcs1))
    }

    static func pem(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }

    static func der(fromPEM pem: String) -> Data? {
        let joined = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: joined)
    }

    /// Is this PEM an RSA key at all? Cheap enough to answer by looking for the algorithm
    /// identifier rather than importing.
    static func isRSA(pem: String) -> Bool {
        guard let der = der(fromPEM: pem) else { return false }
        if pem.contains("BEGIN RSA") { return true }
        return der.range(of: rsaAlgorithmIdentifier) != nil
    }

    // MARK: - SecKey

    private static func secKey(pem: String, isPrivate: Bool) -> SecKey? {
        guard let der = der(fromPEM: pem) else { return nil }
        let body: Data?
        if isPrivate { body = pkcs1PrivateKey(from: der) } else { body = pkcs1PublicKey(from: der) }
        guard let body else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(body as CFData, attributes as CFDictionary, nil)
    }

    /// A private PEM can answer public questions too, which is what node allows.
    private static func verificationKey(pem: String) -> SecKey? {
        if let key = secKey(pem: pem, isPrivate: false) { return key }
        if let priv = secKey(pem: pem, isPrivate: true) { return SecKeyCopyPublicKey(priv) }
        return nil
    }

    private static func signatureAlgorithm(_ digest: String, pss: Bool) -> SecKeyAlgorithm? {
        switch digest {
        case "sha1": return pss ? .rsaSignatureMessagePSSSHA1 : .rsaSignatureMessagePKCS1v15SHA1
        case "sha256": return pss ? .rsaSignatureMessagePSSSHA256 : .rsaSignatureMessagePKCS1v15SHA256
        case "sha384": return pss ? .rsaSignatureMessagePSSSHA384 : .rsaSignatureMessagePKCS1v15SHA384
        case "sha512": return pss ? .rsaSignatureMessagePSSSHA512 : .rsaSignatureMessagePKCS1v15SHA512
        default: return nil
        }
    }

    static func sign(pem: String, message: Data, digest: String, pss: Bool) -> Data? {
        guard let key = secKey(pem: pem, isPrivate: true),
              let algorithm = signatureAlgorithm(digest, pss: pss),
              SecKeyIsAlgorithmSupported(key, .sign, algorithm) else { return nil }
        return SecKeyCreateSignature(key, algorithm, message as CFData, nil) as Data?
    }

    static func verify(pem: String, message: Data, signature: Data, digest: String, pss: Bool) -> Bool {
        guard let key = verificationKey(pem: pem),
              let algorithm = signatureAlgorithm(digest, pss: pss),
              SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { return false }
        return SecKeyVerifySignature(key, algorithm, message as CFData, signature as CFData, nil)
    }

    /// node's padding constants: 1 = PKCS1v15, 4 = OAEP (its default for publicEncrypt).
    private static func encryptionAlgorithm(padding: Int, digest: String) -> SecKeyAlgorithm? {
        if padding == 1 { return .rsaEncryptionPKCS1 }
        switch digest {
        case "sha1": return .rsaEncryptionOAEPSHA1
        case "sha256": return .rsaEncryptionOAEPSHA256
        case "sha384": return .rsaEncryptionOAEPSHA384
        case "sha512": return .rsaEncryptionOAEPSHA512
        default: return nil
        }
    }

    static func encrypt(pem: String, plain: Data, padding: Int, digest: String) -> Data? {
        guard let key = verificationKey(pem: pem),
              let algorithm = encryptionAlgorithm(padding: padding, digest: digest),
              SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else { return nil }
        return SecKeyCreateEncryptedData(key, algorithm, plain as CFData, nil) as Data?
    }

    static func decrypt(pem: String, cipher: Data, padding: Int, digest: String) -> Data? {
        guard let key = secKey(pem: pem, isPrivate: true),
              let algorithm = encryptionAlgorithm(padding: padding, digest: digest),
              SecKeyIsAlgorithmSupported(key, .decrypt, algorithm) else { return nil }
        return SecKeyCreateDecryptedData(key, algorithm, cipher as CFData, nil) as Data?
    }

    /// Generate a key pair and hand back node-shaped PEMs. The key is NOT put in the keychain
    /// (`kSecAttrIsPermanent: false`): a JS program's key is its own, and leaving copies in the
    /// keychain would outlive the program that made it.
    static func generate(modulusLength: Int) -> (privatePEM: String, publicPEM: String)? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: modulusLength,
            kSecAttrIsPermanent: false,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(key),
              let privateBody = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let publicBody = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        return (pem(pkcs8(from: privateBody), label: "PRIVATE KEY"),
                pem(spki(from: publicBody), label: "PUBLIC KEY"))
    }

    /// Bits in the modulus, for `asymmetricKeyDetails`.
    static func modulusLength(pem: String) -> Int {
        guard let key = secKey(pem: pem, isPrivate: true) ?? verificationKey(pem: pem) else { return 0 }
        return SecKeyGetBlockSize(key) * 8
    }
}
