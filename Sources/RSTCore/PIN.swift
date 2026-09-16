import CryptoKit
import Foundation

/// The PIN: PBKDF2-HMAC-SHA256, 200 000 rounds, 32-byte random per-install salt.
///
/// **The PIN is a speed bump, not a security boundary** (DESIGN §2.5). Anyone with admin
/// rights on this Mac ends the app in one command, and that is accepted. The hashing is
/// here so that four digits are not sitting in a file in plain text next to a curious
/// ten-year-old — that is the whole threat model.

/// Rounds. High enough that guessing 10 000 four-digit PINs offline is minutes rather
/// than milliseconds; low enough that a child typing a PIN into the cover does not wait.
///
/// Measured on this Mac: **~0.5s per derivation optimised, ~1s in a debug build.** That is
/// slower than CommonCrypto would be, because the loop below allocates a `Data` per
/// iteration — acceptable for something typed a few times a day, but it means T13 must
/// verify off the main thread rather than freeze the cover while it thinks. Lowering the
/// rounds is not the fix.
public let pinRounds = 200_000

/// **How many digits a PIN has, and now a rule rather than an assumption.**
///
/// DESIGN §2.5 has said "four digits" throughout and nothing enforced it: the hash reveals
/// no length, so a hand-set six-digit PIN worked perfectly well. T13's prompt is four boxes
/// that submit themselves on the fourth digit (changed by the user 2026-08-25), and a PIN
/// longer or shorter than this can no longer be typed into it at all.
///
/// It lives here rather than beside those boxes in `RSTApp` because **T16's wizard has to
/// hold the parent to the same number**. A wizard that accepted five digits would write a
/// hash nothing in the app could ever unlock — a cover with no key, which is the one failure
/// §2.5 exists to prevent.
public let pinDigits = 4

/// Salt bytes. Per install, not per PIN — there is one PIN.
public let pinSaltByteCount = 32

/// Derived-key bytes. One SHA-256 block, and **fixed** — the length of the derivation is
/// never taken from the stored hash.
///
/// It used to be: `verifyPIN` derived as many bytes as `pin_hash` decoded to, which made
/// both the cost and the strength of a PIN check a property of a file the parent edits by
/// hand. Measured on this Mac at the shipped rounds: a 3200-byte `pin_hash` costs ~39s per
/// attempt and a megabyte of it costs hours — under the cover, where a PIN dialog that
/// never answers is the one failure this app must not have. A *short* hash is the same bug
/// pointing the other way: a one-byte `pin_hash` accepts any wrong PIN once in 256.
public let pinHashByteCount = 32

/// A fresh random salt. CryptoKit's key generator rather than `UInt8.random`, so the
/// source is unambiguously the cryptographic one.
public func newPINSalt(byteCount: Int = pinSaltByteCount) -> Data {
    SymmetricKey(size: .init(bitCount: byteCount * 8)).withUnsafeBytes { Data($0) }
}

/// Hashes a PIN. Base64, because that is what goes into JSON.
///
/// **An empty PIN hashes to the empty string, deliberately.** DESIGN §6 defines "the app
/// is configured" as a non-empty `pin_hash`, and §2.5 forbids covering the screen without
/// a PIN — a cover nobody can lift is the one failure this app must not have. Returning a
/// perfectly good hash of "" would make an unusable PIN look like a configured one, so the
/// empty case is closed here at the source rather than in every caller.
public func hashPIN(_ pin: String, salt: Data, rounds: Int = pinRounds) -> String {
    guard !pin.isEmpty, !salt.isEmpty else { return "" }
    return pbkdf2SHA256(
        password: Data(pin.utf8), salt: salt, rounds: rounds, keyByteCount: pinHashByteCount
    ).base64EncodedString()
}

/// Checks a PIN against a stored hash. Constant time.
///
/// Empty PIN, empty hash or empty salt are all rejected outright: an unconfigured install
/// must not be unlockable by pressing Enter. So is a hash that is not exactly
/// `pinHashByteCount` bytes — see the constant for why the length is checked rather than
/// followed.
public func verifyPIN(_ pin: String, hash: String, salt: Data, rounds: Int = pinRounds) -> Bool {
    guard !pin.isEmpty, !hash.isEmpty, !salt.isEmpty else { return false }
    guard let expected = Data(base64Encoded: hash),
          expected.count == pinHashByteCount
    else { return false }
    let actual = pbkdf2SHA256(
        password: Data(pin.utf8), salt: salt, rounds: rounds, keyByteCount: pinHashByteCount
    )
    return constantTimeEquals(actual, expected)
}

/// Byte comparison that does not return early.
///
/// `Data`'s `==` is free to stop at the first differing byte, which times how many leading
/// bytes a guess got right. Irrelevant against a local child and free to get right anyway.
/// Length is compared first and does leak — it is the length of a base64 hash constant.
func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for (x, y) in zip(a, b) { difference |= x ^ y }
    return difference == 0
}

/// PBKDF2-HMAC-SHA256 (RFC 2898 §5.2), built here on CryptoKit's HMAC.
///
/// **CryptoKit has no PBKDF2.** It offers HKDF, which is key *expansion* and deliberately
/// cheap — the opposite of what a PIN needs. The system's PBKDF2 lives in CommonCrypto,
/// which `RSTCore` may not import (Foundation + CryptoKit only). So the KDF is the twenty
/// lines below: the iteration is the entire algorithm, and `PINTests` pins it to reference
/// vectors from Python's `hashlib`, so a mistake here is a failing test, not a silent
/// weakening.
func pbkdf2SHA256(password: Data, salt: Data, rounds: Int, keyByteCount: Int) -> Data {
    precondition(rounds >= 1, "PBKDF2 needs at least one round")
    precondition(keyByteCount >= 1, "PBKDF2 needs a positive key length")

    let key = SymmetricKey(data: password)
    var derived = Data()
    var blockIndex: UInt32 = 1

    // dkLen is 32 here, one SHA-256 block, so this loop runs once. It is written for the
    // general case regardless: a one-block-only KDF is the kind of thing that is correct
    // until someone asks for a 64-byte key.
    while derived.count < keyByteCount {
        var seed = salt
        withUnsafeBytes(of: blockIndex.bigEndian) { seed.append(contentsOf: $0) }

        var u = Data(HMAC<SHA256>.authenticationCode(for: seed, using: key))
        var block = u
        for _ in 1..<rounds {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
            for i in block.indices { block[i] ^= u[i] }
        }

        derived.append(block)
        blockIndex += 1
    }

    // Re-wrapped rather than returned as a slice: a `Data` slice keeps the parent's
    // indices, and the XOR loop above would then read out of bounds if this ever fed back.
    return Data(derived.prefix(keyByteCount))
}
