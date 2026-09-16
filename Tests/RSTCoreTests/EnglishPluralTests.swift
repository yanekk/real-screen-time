import Testing
@testable import RSTCore

/// ``EnglishPlural`` — the choice of singular or plural for the wizard's final screen (CR-01
/// §4). A plural chosen inside a view cannot be tested; this is why the rule is in Core.
@Suite("English plural")
struct EnglishPluralTests {

    @Test("one is singular; zero and everything above one are plural")
    func form() {
        #expect(EnglishPlural.form(1) == .one)
        #expect(EnglishPlural.form(0) == .many)
        #expect(EnglishPlural.form(2) == .many)
        #expect(EnglishPlural.form(4) == .many)
    }
}
