import Foundation
import Testing
@testable import RSTCore

/// The KDF is hand-written because CryptoKit has no PBKDF2 and CommonCrypto is outside the
/// Core boundary, so it is pinned to reference vectors from another implementation. A
/// home-grown KDF that only agrees with itself proves nothing.
@Suite("PIN")
struct PINTests {

    /// PBKDF2-HMAC-SHA256, dkLen 32, generated with Python's `hashlib.pbkdf2_hmac`.
    ///
    /// These three are the widely circulated SHA-256 analogues of RFC 6070's parameters,
    /// not published vectors in their own right — the review corrected a comment claiming
    /// otherwise. An actually published vector is pinned separately below, so the KDF is
    /// checked against a standards document as well as against another implementation.
    @Test("PBKDF2-HMAC-SHA256 matches reference vectors", arguments: [
        (1,    "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
        (2,    "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
        (4096, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
    ])
    func pbkdf2MatchesReferenceVectors(rounds: Int, expected: String) {
        let derived = pbkdf2SHA256(
            password: Data("password".utf8), salt: Data("salt".utf8),
            rounds: rounds, keyByteCount: 32
        )
        #expect(hex(derived) == expected)
    }

    /// RFC 7914 §11's first PBKDF2-HMAC-SHA256 vector, copied from the RFC itself.
    ///
    /// This is the one that makes the KDF agree with something outside this project: a
    /// hand-written KDF pinned only to values another implementation produced is pinned to
    /// a second opinion, not to the standard. dkLen 64 also puts the block loop on a
    /// published vector rather than on a self-consistency check.
    @Test("PBKDF2-HMAC-SHA256 matches RFC 7914 §11")
    func pbkdf2MatchesRFC7914() {
        let derived = pbkdf2SHA256(
            password: Data("passwd".utf8), salt: Data("salt".utf8), rounds: 1, keyByteCount: 64
        )
        #expect(hex(derived) == """
            55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc\
            49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783
            """)
    }

    @Test("PBKDF2 produces keys longer than one SHA-256 block correctly")
    func pbkdf2MultiBlock() {
        // 64 bytes is two blocks; the first 32 must equal the single-block derivation, so
        // the block loop is wired up right rather than merely running.
        let long = pbkdf2SHA256(
            password: Data("password".utf8), salt: Data("salt".utf8), rounds: 2, keyByteCount: 64
        )
        #expect(long.count == 64)
        #expect(hex(Data(long.prefix(32))) == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
    }

    @Test("hash then verify accepts the PIN and rejects every near miss")
    func hashAndVerify() {
        let salt = newPINSalt()
        let hash = hashPIN("4271", salt: salt, rounds: testRounds)

        #expect(verifyPIN("4271", hash: hash, salt: salt, rounds: testRounds))
        #expect(!verifyPIN("4272", hash: hash, salt: salt, rounds: testRounds))
        #expect(!verifyPIN("427", hash: hash, salt: salt, rounds: testRounds))
        #expect(!verifyPIN("42710", hash: hash, salt: salt, rounds: testRounds))
        // A different salt is a different install: the same PIN must not verify.
        #expect(!verifyPIN("4271", hash: hash, salt: newPINSalt(), rounds: testRounds))
    }

    @Test("the shipped 200 000 rounds work end to end")
    func defaultRoundsRoundTrip() {
        // The only test that pays the real cost, and it is the one that matters: the
        // constants the app actually ships with, so nobody can tune `pinRounds` into
        // something no test ever exercises. Two derivations and no more — each one is
        // ~0.5s optimised and ~1s in a debug build, and rejection logic is identical at
        // `testRounds`, where it is checked thoroughly.
        let salt = newPINSalt()
        let hash = hashPIN("1234", salt: salt)
        #expect(verifyPIN("1234", hash: hash, salt: salt))
    }

    @Test("an empty PIN cannot be stored and cannot unlock anything")
    func emptyPINRejected() {
        let salt = newPINSalt()

        // Hashing nothing yields nothing: DESIGN §6 reads "configured" as a non-empty
        // pin_hash, so an empty PIN must not be able to look like a configured install.
        #expect(hashPIN("", salt: salt) == "")

        let real = hashPIN("4271", salt: salt, rounds: testRounds)
        #expect(!verifyPIN("", hash: real, salt: salt, rounds: testRounds))
        #expect(!verifyPIN("4271", hash: "", salt: salt, rounds: testRounds))
        #expect(!verifyPIN("4271", hash: real, salt: Data(), rounds: testRounds))
        // Pressing Enter on an unconfigured install must not open anything.
        #expect(!verifyPIN("", hash: "", salt: Data(), rounds: testRounds))
    }

    @Test("a non-base64 hash is rejected rather than trusted")
    func malformedHashRejected() {
        let salt = newPINSalt()
        #expect(!verifyPIN("4271", hash: "not base64!!", salt: salt, rounds: testRounds))
    }

    @Test("a hash of the wrong length is rejected, not followed")
    func wrongLengthHashRejected() {
        let salt = newPINSalt()
        let real = hashPIN("4271", salt: salt, rounds: testRounds)
        #expect(Data(base64Encoded: real)?.count == pinHashByteCount)

        // A truncated `pin_hash` — a hand edit, a torn write — used to shorten the
        // comparison to whatever survived, so a one-byte hash accepted any PIN once in
        // 256. The length is a property of the algorithm, never of the file.
        for prefix in [1, 8, 31] {
            let truncated = Data(Data(base64Encoded: real)!.prefix(prefix)).base64EncodedString()
            #expect(!verifyPIN("4271", hash: truncated, salt: salt, rounds: testRounds))
        }
        let overlong = (Data(base64Encoded: real)! + Data(repeating: 0, count: 8))
            .base64EncodedString()
        #expect(!verifyPIN("4271", hash: overlong, salt: salt, rounds: testRounds))
    }

    @Test("the cost of a PIN check does not depend on what is in config.json")
    func checkCostIsBounded() {
        // The derivation used to run one PBKDF2 block per 32 bytes of *stored* hash, so a
        // hand-edited `pin_hash` set the price of every attempt: measured at the shipped
        // rounds, 3200 bytes cost ~39s and this test's 64KB cost over half an hour. That is
        // a PIN dialog that never answers, under a cover only the PIN lifts.
        //
        // Deliberately at low rounds. The property is "work is bounded by the algorithm,
        // not by the file", and it holds at any round count — while at `pinRounds` a
        // regression would hang the suite for the better part of an hour instead of
        // failing it. 2048 blocks × 100 rounds is ~0.5s of real work if the bug comes
        // back, against microseconds when the length is checked first: a margin wide
        // enough that the threshold is not a race.
        let salt = newPINSalt()
        let huge = Data(repeating: 0, count: 64 * 1024).base64EncodedString()

        let started = ContinuousClock.now
        #expect(!verifyPIN("4271", hash: huge, salt: salt, rounds: 100))
        #expect(ContinuousClock.now - started < .milliseconds(100))
    }

    @Test("two installs with the same PIN produce different hashes")
    func saltIsUsed() {
        // If this fails the salt is not reaching the KDF, and one rainbow table covers
        // every install of the app.
        let a = hashPIN("4271", salt: newPINSalt(), rounds: testRounds)
        let b = hashPIN("4271", salt: newPINSalt(), rounds: testRounds)
        #expect(a != b)
        #expect(!a.isEmpty)
    }

    @Test("salts are 32 random bytes")
    func saltShape() {
        let salts = (0..<8).map { _ in newPINSalt() }
        #expect(salts.allSatisfy { $0.count == pinSaltByteCount })
        #expect(Set(salts).count == salts.count)
        #expect(pinSaltByteCount == 32)
    }

    @Test("the comparison is constant time and still correct")
    func constantTimeComparison() {
        #expect(constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))   // differs at the end
        #expect(!constantTimeEquals(Data([1, 2, 3]), Data([9, 2, 3])))   // differs at the start
        #expect(!constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
        #expect(constantTimeEquals(Data(), Data()))
        // Slices carry their parent's indices; the comparison must not care.
        #expect(constantTimeEquals(Data([0, 1, 2, 3]).dropFirst(2), Data([2, 3])))
    }

    // MARK: - Helpers

    /// Fast rounds for the logic tests. The real 200 000 are exercised once, above:
    /// paying 0.1s per assertion would make the suite slow enough to stop being run.
    private let testRounds = 1_000

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
