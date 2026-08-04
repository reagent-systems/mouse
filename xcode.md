# xcode.md — building iOS apps on the phone

The `xcode` product branch's hardest question, answered concretely:

> *Can Mouse take an iOS app from source to running on this device, without
> a Mac in the loop?*

**Verdict: signing and installing are ours to build. Compiling is the wall.**

That split is the whole plan. The two halves are independent, and the
signing half is useful on its own long before the compiling half exists —
so it goes first.

## 1. What is actually blocked (and what isn't)

An earlier reading of this problem said "you can't sign on device, because
Apple's trust can't be manufactured locally." That conflated two different
things and got the answer wrong:

- **Minting new trust** is impossible on device. A phone cannot issue itself
  a certificate that iOS will honor. True, and permanent.
- **Using trust already granted** is ordinary cryptography. If the user
  holds an Apple-issued developer certificate, Apple *already* vouched for
  them. Doing the signing math locally does not weaken that chain.

The second case is the one that matters, and it is shipped, working
technology: **AltStore**, **SideStore**, **ESign**, and the `zsign` project
all sign iOS apps with a user-supplied certificate. `zsign` is a few
thousand lines of C++ that does nothing else. This is squarely in the
house tradition (tar, gzip, ICMP, git) — a documented binary format and a
documented crypto envelope, built from scratch.

| Step | Fate on device |
|---|---|
| Sign a bundle with the user's cert | **Feasible.** Proven by shipped apps |
| Install the signed bundle | **Feasible**, with a transport caveat (§5) |
| Compile Swift → arm64 iOS | **The wall.** Needs the toolchain + SDK (§6) |
| Issue a certificate | Impossible, and correctly so |

**Scope discipline:** this document covers a developer signing *their own*
app with *their own* Apple-issued certificate onto *their own* registered
device. That is what a developer account is for. Nothing here circumvents
DRM or Apple's trust chain — it exercises it.

### The bring-your-own rule

The principle that keeps this honest, and it generalizes past signing:

> **Mouse never manufactures credentials, licenses, or trust. It accepts
> what the user already holds, and does the work with it.**

The user brings the certificate (Apple issued it to them). The user brings
the provisioning profile (their developer account produced it, with their
device's UDID already in it). If on-device compilation is ever attempted,
the user brings the iOS SDK from their own Mac, under their own Apple
license — Mouse never redistributes it.

This is exactly the posture of every IDE: Xcode does not issue you a
certificate either. It asks for the one you have and signs with it. An IDE
that refuses to accept the user's own credentials isn't safer, it's just
less useful — and a tool that *fabricated* those credentials would be the
thing we refuse to build. The line is not "does Mouse sign?" but "whose
trust is being exercised, and did its owner hand it over on purpose?"

Two consequences worth stating plainly, because they are features:

- **Mouse cannot register a device**, so it cannot widen a profile's reach.
  iOS gives no API to read the device's own UDID; the profile arrives with
  the UDID already in it or signing fails the pre-flight check (§2).
- **Mouse cannot extend an expiry.** A 7-day free-account profile is 7 days
  here too. The re-sign affordance (§6) exists because the constraint is
  real, not because it can be worked around.

## 2. What signing actually is

An iOS app bundle is signed by adding three things and hashing everything:

1. **`embedded.mobileprovision`** — the user's provisioning profile,
   verbatim. A CMS-signed plist listing the app ID, allowed entitlements,
   team identifier, expiration, and the UDIDs of provisioned devices.
2. **`_CodeSignature/CodeResources`** — a plist of SHA-256 hashes of every
   resource file in the bundle (images, nibs, plists, frameworks).
3. **An `LC_CODE_SIGNATURE` blob** inside the Mach-O executable itself.

That last one is the real work. It's a **SuperBlob** (magic `0xfade0cc0`)
living at the end of `__LINKEDIT`, indexing several sub-blobs:

| Blob | Magic | Contents |
|---|---|---|
| CodeDirectory | `0xfade0c02` | SHA-256 of every 4 KB page of the binary, plus "special slots" hashing Info.plist, requirements, CodeResources, and entitlements |
| Requirements | `0xfade0c01` | The designated requirement expression |
| Entitlements | `0xfade7171` | The entitlements plist (XML) |
| DER entitlements | `0xfade7172` | The same, DER-encoded (required on modern iOS) |
| CMS signature | `0xfade0b01` | PKCS#7 SignedData over the CodeDirectory hash |

The signature covers the CodeDirectory; the CodeDirectory covers everything
else. Change one byte of one PNG and the chain breaks — which is exactly
what makes it verifiable.

**Entitlements must be a subset of what the profile permits.** This is the
most common signing failure and worth an explicit pre-flight check.

## 3. The crypto, on iOS specifically

The primitives exist in Security.framework, with one gap:

- `SecPKCS12Import` — imports the user's `.p12`, yielding a `SecIdentity`.
  **Available on iOS.**
- `SecIdentityCopyPrivateKey` + `SecKeyCreateSignature` with
  `.rsaSignatureMessagePKCS1v15SHA256` — the actual signature.
  **Available on iOS.**
- **The gap:** `CMSEncoder` is macOS-only. iOS has no API that assembles a
  PKCS#7 SignedData envelope.

So Mouse builds the CMS envelope by hand: a **from-scratch ASN.1 DER
writer** wrapping the signature, the signer's certificate chain, and the
signed attributes. This is the single most fiddly piece of the project, and
also the most house-style: a documented format, built correctly, verified
against the real tool.

## 4. Phase plan

Each phase ships something usable and is independently verifiable.

### Phase 0 — the artifact server (foundation, useful alone)

A local HTTP server in the terminal, serving files out of the workspace:

```
~ $ serve dist
serving dist on http://192.168.0.26:8080
```

Value on its own: get build artifacts, generated files, and zips *out* of
Mouse via Safari or another device. It's also the same dev-server engine
the Preview container needs, and the delivery mechanism OTA install needs
in Phase 5. Three roadmap items, one server.

- Pure-Swift HTTP/1.1 on `Network.framework`
- Serves from the workspace root only; no path escape
- Reports its LAN address (the `ip` builtin already prints it)

### Phase 1 — `MouseSign`: the signer

The core engine, Foundation-only so it verifies headlessly.

- **Mach-O reader/writer**: parse load commands, locate `__LINKEDIT`, find
  or append `LC_CODE_SIGNATURE`, rewrite segment sizes and offsets
- **CodeDirectory builder**: page hashes + special slots
- **ASN.1 DER writer + CMS SignedData** (§3)
- **`CodeResources` builder**: walk the bundle, hash every file
- **Profile parser**: read the `.mobileprovision` CMS plist for team ID,
  entitlements, expiry, and provisioned UDIDs
- **Pre-flight**: entitlements ⊆ profile, profile not expired, cert matches
  profile's `DeveloperCertificates`, device UDID present

Deliverable: `sign <app-or-ipa>` in the terminal, producing a bundle the
real `codesign` accepts.

### Phase 2 — credential handling

Non-negotiable, and worth its own phase because getting it wrong is worse
than not shipping.

- The `.p12` is imported **directly into the Keychain** with
  `SecPKCS12Import`. The private key never lands in the workspace, never
  appears in the file tree, never enters a git object, never prints.
- Import is an explicit, single-purpose flow with the passphrase entered
  once. Store with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- A `.gitignore` guard: refuse to sign if a `.p12` is found *inside* the
  workspace, and say why.
- The signing container shows: team, cert common name, expiry, provisioned
  device count. Never key material.
- `sign --forget` removes the identity from the Keychain.

### Phase 3 — re-signing (the first real product)

**This is the milestone that pays off before any compiler exists.** With
Phases 0–2, a complete loop already works:

```
~ $ git push                    # CI builds an unsigned .ipa
~ $ curl -O https://.../MyApp-unsigned.ipa
~ $ sign MyApp-unsigned.ipa
signed MyApp.ipa (team ABCDE12345, expires 2027-03-14)
~ $ serve .
```

A cloud Mac compiles; **the phone signs**. No Mac in the signing loop, and
no Apple credentials in CI — the private key never leaves the device.
That's a genuinely better security posture than the standard setup, where
teams upload signing keys to a build server.

### Phase 4 — install transport A: OTA

The `itms-services://` manifest flow — Apple's own over-the-air install:

```
itms-services://?action=download-manifest&url=https://…/manifest.plist
```

**Honest caveat:** iOS requires the manifest URL to be **HTTPS with a
publicly trusted certificate.** A plain `http://localhost` server will not
do it, and a self-signed cert will not do it. Options, in order of
preference:

1. The user's own domain with a real cert (they host the manifest; Mouse
   generates it and uploads the payload)
2. A tunnel service exposing the local server over trusted HTTPS
3. A trusted profile installed on device to accept a local CA — heavier,
   and asks the user for more trust than this feature deserves

Ship the manifest generator regardless; it's small, and it makes any of
the three work.

### Phase 5 — install transport B: lockdownd

The transport SideStore proved: talk to the device's own
`com.apple.mobile.installation_proxy` service.

- Requires a **pairing record** generated once by a computer
- Requires a loopback shim to reach the device's own usbmux socket from
  inside an app (SideStore uses a local VPN/`em_proxy` approach)

Higher complexity, more moving parts, and the pairing-file requirement
weakens the "no computer ever" claim. **Attempt only after Phase 4 ships**,
and only if OTA's HTTPS requirement proves too annoying in practice.

### Phase 6 — compiling (the wall, documented honestly)

Two paths, and the recommendation is not close:

**Path A — CI (recommended).** GitHub Actions macOS runners have Xcode
preinstalled, free for public repos. Mouse already owns the plumbing:
`git push` triggers the build; a CI container watches the run and reports
into the terminal; the artifact comes back and Phase 3 signs it on device.
Cost: minutes per cycle, not seconds. This is what every cloud IDE pays.

**Path B — on-device (research).** Needs `swiftc` targeting `arm64-ios`
running under the wasm/RISC-V interpreter, plus the **iOS SDK** — roughly
10 GB, Apple-licensed, not redistributable, so the user would supply it
from their own Mac. Interpreted compilation of a real project is plausibly
minutes to hours. Interesting; not the path to a working loop.

## 5. Verification plan

Per [AGENTS.md](AGENTS.md), `MouseSign` is Foundation-only and verifies
headlessly with `swiftc` + a scratch `main.swift`. Interop with the real
tools is mandatory:

| Component | Verified against |
|---|---|
| Whole-bundle signature | `codesign -vvv --deep --strict` reports valid |
| CodeDirectory | `codesign -d --entitlements - ` round-trips our entitlements |
| Page hashes | `codesign -d --verbose=4` cdhash matches ours |
| CMS envelope | `openssl cms -verify` / `security cms -D` parses it |
| ASN.1 writer | `openssl asn1parse` on every blob we emit |
| `CodeResources` | Byte-comparable to a `codesign`-produced bundle |
| Profile parser | Fields match `security cms -D -i profile.mobileprovision` |
| Mach-O surgery | `otool -l` shows a well-formed `LC_CODE_SIGNATURE`; the binary still runs |

The gold standard: sign a bundle with Mouse, sign the same bundle with
Apple's `codesign`, and **diff the two signatures blob by blob.**
Differences are either explained or fixed.

## 6. Practical frictions (state them up front)

- **Free accounts expire in 7 days** (paid: 1 year). Apps need periodic
  re-signing. A "re-sign" affordance in the signing container is not
  optional — it's the difference between a demo and a tool.
- **Free accounts cap at 3 apps** and 10 app IDs per week.
- **Device UDID must already be in the profile.** iOS gives no API to read
  its own UDID, so Mouse cannot register a device. The profile comes from
  the user's existing developer setup, where the UDID is already known.
  Mouse consumes profiles; it never creates them.
- **Entitlement mismatches** are the most common failure. The pre-flight
  check in Phase 1 exists to turn a cryptic install failure into one honest
  terminal line.

## 7. Distribution reality

The engineering is the easy part of shipping this.

- **App Review would very likely reject** a Mouse build that ships general
  re-signing of arbitrary IPAs. This is why AltStore distributes outside the
  App Store.
- **Narrower framing is defensible**: signing *the user's own* project
  output, with *their own* certificate, as part of a development tool.
  Whether Review agrees is unknown until asked.
- **EU/DMA alternative marketplaces** are a real distribution path for the
  unrestricted version.
- **Decide the framing before Phase 3 ships**, because it determines whether
  this lives in the main app, behind a developer-mode flag, or in a
  separately distributed build.

## 8. Recommended order

```
Phase 0  artifact server          ← useful immediately, unblocks 3 roadmap items
Phase 1  MouseSign engine         ← the real work
Phase 2  credential handling      ← ships with Phase 1, never after
Phase 3  re-sign CI artifacts     ← the first complete loop, no compiler needed
Phase 4  OTA install              ← closes the loop on device
Phase 6a CI build integration     ← the practical "build my app" story
────────────────────────────────
Phase 5  lockdownd transport      ← only if OTA proves too annoying
Phase 6b on-device compilation    ← research, not a milestone
```

Phases 0–4 plus 6a is a working answer to "I want to build and run my iOS
app from my phone." It routes sixty seconds of compilation through a rented
Mac, and keeps the part that matters — **the signing key, and the trust it
represents — on the user's own device.**
