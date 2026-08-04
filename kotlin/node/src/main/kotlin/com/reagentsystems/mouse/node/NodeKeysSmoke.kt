package com.reagentsystems.mouse.node

/**
 * Asymmetric keys on the DEVICE — the second program in this suite that only runs there, and for a
 * different reason than [NodeVmSmoke]'s.
 *
 * `vm` is device-only because real node has no DOM. This one is device-only because of WHOSE
 * cryptography runs. `:nodecheck` grades [NodeKeys] far more thoroughly than this does — against
 * real node, in both directions, over 200-odd checks — but it grades it on a JDK, where the
 * providers are SunEC, SunJCE and SunRsaSign. Android has never used those. It ships **Conscrypt**,
 * a different implementation with its own opinions about which transformation strings exist, which
 * key specs it will accept, and which algorithms are present at which API level.
 *
 * So a green JVM corpus says the DER, the encodings and the algorithm choices are right, and says
 * nothing at all about whether the phone's provider will do them. That gap is the same one this
 * project keeps paying for: milestone 3b shipped two bugs invisible to a green 310-check desktop
 * run and fatal to 31 of 45 checks on a phone, and 3c shipped three more.
 *
 * What it checks is therefore narrow and deliberate — one operation of each KIND that could be
 * absent or spelled differently on Conscrypt, rather than a second copy of the corpus:
 *
 *  - EC key generation and ECDSA, in both signature encodings
 *  - RSA generation, PKCS#1 v1.5 and PSS
 *  - RSA as a cipher under OAEP, whose transformation name and explicit parameters are the most
 *    provider-specific thing here
 *  - ECDH between two locally generated pairs
 *
 * Ed25519 is asked for LAST and its absence is not a failure: it arrived at API 33 against this
 * app's minSdk 26, so the honest assertion is that it either works or refuses cleanly — never that
 * it is present.
 */
object NodeKeysSmoke {

    val CONFIG: NodeProcessConfig = NodeProcessConfig(
        argv = listOf("/usr/local/bin/node", "/keys.js"),
        cwd = "/",
    )

    const val ENTRY_PATH: String = "/keys.js"

    private const val EXIT_CODE = 13

    val PROGRAM: String = """
        const crypto = require('crypto');
        const out = [];
        const say = (key, value) => out.push(key + '=' + value);
        const message = Buffer.from('device-side asymmetric keys', 'utf8');

        // ---- EC: generate, sign, verify, and the two signature encodings ----
        const ec = crypto.generateKeyPairSync('ec', {
          namedCurve: 'prime256v1',
          publicKeyEncoding: { type: 'spki', format: 'pem' },
          privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
        });
        say('ecType', crypto.createPrivateKey(ec.privateKey).asymmetricKeyType);
        say('ecCurve', crypto.createPrivateKey(ec.privateKey).asymmetricKeyDetails.namedCurve);
        const ecSig = crypto.sign('sha256', message, ec.privateKey);
        say('ecVerify', crypto.verify('sha256', message, ec.publicKey, ecSig));
        // A signature over other bytes must NOT verify — without this the check above passes on a
        // verify that returns true unconditionally.
        say('ecTamper', crypto.verify('sha256', Buffer.from('other'), ec.publicKey, ecSig));
        const flat = crypto.sign('sha256', message, { key: ec.privateKey, dsaEncoding: 'ieee-p1363' });
        say('p1363Size', flat.length);
        say('p1363Verify', crypto.verify('sha256', message,
          { key: ec.publicKey, dsaEncoding: 'ieee-p1363' }, flat));

        // ---- RSA: generate, both paddings, and OAEP as a cipher ----
        const rsa = crypto.generateKeyPairSync('rsa', {
          modulusLength: 2048,
          publicKeyEncoding: { type: 'spki', format: 'pem' },
          privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
        });
        say('rsaBits', crypto.createPrivateKey(rsa.privateKey).asymmetricKeyDetails.modulusLength);
        say('rsaVerify', crypto.verify('sha256', message, rsa.publicKey,
          crypto.sign('sha256', message, rsa.privateKey)));
        const pssKey = { key: rsa.privateKey, padding: crypto.constants.RSA_PKCS1_PSS_PADDING };
        const pssPub = { key: rsa.publicKey, padding: crypto.constants.RSA_PKCS1_PSS_PADDING };
        say('pssVerify', crypto.verify('sha256', message, pssPub,
          crypto.sign('sha256', message, pssKey)));
        const sealed = crypto.publicEncrypt(
          { key: rsa.publicKey, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
          message);
        const opened = crypto.privateDecrypt(
          { key: rsa.privateKey, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
          sealed);
        say('oaep', opened.toString('utf8') === message.toString('utf8'));
        say('type1', crypto.publicDecrypt(rsa.publicKey,
          crypto.privateEncrypt(rsa.privateKey, message)).toString('utf8') === message.toString('utf8'));

        // ---- ECDH: two pairs made here, and the secrets must agree ----
        const a = crypto.createECDH('prime256v1');
        const b = crypto.createECDH('prime256v1');
        const aPublic = a.generateKeys();
        const bPublic = b.generateKeys();
        const secretA = a.computeSecret(bPublic);
        const secretB = b.computeSecret(aPublic);
        say('ecdh', secretA.equals(secretB));
        say('ecdhSize', secretA.length);

        // ---- Ed25519 LAST: present or cleanly absent, never a crash ----
        let ed = 'absent';
        try {
          const k = crypto.generateKeyPairSync('ed25519', {
            publicKeyEncoding: { type: 'spki', format: 'pem' },
            privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
          });
          ed = crypto.verify(null, message, k.publicKey,
            crypto.sign(null, message, k.privateKey)) ? 'true' : 'false';
        } catch (e) {
          ed = (e && e.code) ? 'refused' : 'threw';
        }
        say('ed25519', ed);

        console.log(out.join('\n'));
        process.exit($EXIT_CODE);
    """.trimIndent()

    /** key → (expected, what the check is called). */
    private val EXPECTED: List<Triple<String, String, String>> = listOf(
        Triple("ecType", "ec", "an EC key generated on the device identifies as one"),
        Triple("ecCurve", "prime256v1", "and reports node's spelling of the curve, not the JCA's"),
        Triple("ecVerify", "true", "ECDSA signs and verifies through Android's own provider"),
        Triple("ecTamper", "false", "and refuses a signature over other bytes"),
        Triple("p1363Size", "64", "a P-256 ieee-p1363 signature is two 32-byte halves"),
        Triple("p1363Verify", "true", "and verifies as one"),
        Triple("rsaBits", "2048", "RSA generates at the size asked for"),
        Triple("rsaVerify", "true", "RSA PKCS#1 v1.5 signs and verifies"),
        Triple("pssVerify", "true", "RSA-PSS does too, parameters and all"),
        Triple("oaep", "true", "OAEP round-trips — the most provider-specific name here"),
        Triple("type1", "true", "the type-1 primitive round-trips: private seals, public opens"),
        Triple("ecdh", "true", "two ECDH pairs agree on a secret"),
        Triple("ecdhSize", "32", "which is the curve's X coordinate and nothing more"),
    )

    val CHECK_COUNT: Int = EXPECTED.size + 2

    /** Grade a run: the transcript's `key=value` lines, plus Ed25519 and the exit code. */
    fun grade(stdout: String, stderr: String, exit: Int): List<String> {
        val seen = HashMap<String, String>()
        for (line in stdout.lines()) {
            val at = line.indexOf('=')
            if (at > 0) seen[line.substring(0, at)] = line.substring(at + 1)
        }
        val failures = ArrayList<String>()
        for ((key, expected, label) in EXPECTED) {
            val got = seen[key] ?: "<absent>"
            if (got != expected) failures.add("$label — $key was $got, expected $expected")
        }
        // Ed25519 needs API 33 against minSdk 26. Working and refusing are BOTH correct; only a
        // wrong answer or a bare throw is not, and saying which one happened is the point.
        val ed = seen["ed25519"] ?: "<absent>"
        if (ed != "true" && ed != "refused" && ed != "absent") {
            failures.add(
                "ed25519 either works or refuses by name on this API level — got $ed",
            )
        }
        if (exit != EXIT_CODE) {
            failures.add("the program ran to its end — exit was $exit, expected $EXIT_CODE")
        }
        if (stderr.isNotBlank()) failures.add("nothing was written to stderr — got: ${stderr.take(300)}")
        return failures
    }
}
