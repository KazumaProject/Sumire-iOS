import XCTest
@testable import SumireCore

final class AndroidFormulaCandidatesTests: XCTestCase {
    func testAndroidDocumentedShorthandOutputs() {
        let expected: [String: AndroidFormulaRendering] = [
            "25^2": .init(unicodeText: "25²", normalizedTex: "25^{2}"),
            "x_1^(n+1)": .init(unicodeText: "x₁⁽ⁿ⁺¹⁾", normalizedTex: "x_{1}^{n+1}"),
            "1/2": .init(unicodeText: "½", normalizedTex: "\\frac{1}{2}"),
            "12/34": .init(unicodeText: "¹²⁄₃₄", normalizedTex: "\\frac{12}{34}"),
            "sqrt(x^2+y^2)": .init(unicodeText: "√(x²+y²)", normalizedTex: "\\sqrt{x^{2}+y^{2}}"),
            "sum(i=1,n,i^2)": .init(unicodeText: "∑ᵢ₌₁ⁿ i²", normalizedTex: "\\sum_{i=1}^{n}i^{2}"),
            "prod(i=1,n,i)": .init(unicodeText: "∏ᵢ₌₁ⁿ i", normalizedTex: "\\prod_{i=1}^{n}i"),
            "int(a,b,f)": .init(unicodeText: "∫ₐᵇ f", normalizedTex: "\\int_{a}^{b}f"),
            "lim(x->0,f(x))": .init(unicodeText: "limₓ→₀ f(x)", normalizedTex: "\\lim_{x\\to0}f(x)"),
            "root(3,x)": .init(unicodeText: "√³⟨x⟩", normalizedTex: "\\sqrt[3]{x}"),
            "\\sqrt[3]{x}": .init(unicodeText: "√³⟨x⟩", normalizedTex: "\\sqrt[3]{x}"),
            "a*b": .init(unicodeText: "a×b", normalizedTex: "a\\times b"),
            "\\frac{a+b}{c+d}": .init(unicodeText: "(a+b)⁄(c+d)", normalizedTex: "\\frac{a+b}{c+d}"),
        ]

        for (source, rendering) in expected {
            XCTAssertEqual(AndroidFormulaCandidatePolicy.parse(source), rendering, source)
        }
    }

    func testCanonicalTexStillOffersBothUnicodeAndTexFormsWithoutAddingSourceLiteral() throws {
        let fraction = try XCTUnwrap(AndroidFormulaCandidatePolicy.candidates(for: "\\frac{1}{2}").first)
        XCTAssertEqual(fraction, .init(unicodeText: "½", normalizedTex: "\\frac{1}{2}"))
        XCTAssertTrue(AndroidFormulaCandidatePolicy.isCanonicalTexSource("\\frac{1}{2}", rendering: fraction))
        XCTAssertFalse(AndroidFormulaCandidatePolicy.isCanonicalTexSource("1/2", rendering: fraction))
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.candidates(for: "25^{2}").first,
            .init(unicodeText: "25²", normalizedTex: "25^{2}")
        )
    }

    func testFullWidthAsciiIsNormalizedWithoutChangingMeaningfulUnicode() {
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.candidates(for: "２５＾２").first,
            .init(unicodeText: "25²", normalizedTex: "25^{2}")
        )
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.candidates(for: "ℝ^2").first,
            .init(unicodeText: "ℝ²", normalizedTex: "\\mathbb{R}^{2}")
        )
    }

    func testDisabledSettingAndNonFormulaInputsProduceNoCandidates() {
        XCTAssertTrue(AndroidFormulaCandidatePolicy.candidates(for: "25^2", enabled: false).isEmpty)
        for input in [
            "ordinary text", "https://example.com/x^2", "mail@example.com", "a\n+b",
            "\\unknown{a}", "const x = a^2;", "if (x^2) { y++; }",
            "for(i=0;i<n;i++)", "return x^2"
        ] {
            XCTAssertNil(AndroidFormulaCandidatePolicy.parse(input), input)
            XCTAssertTrue(AndroidFormulaCandidatePolicy.candidates(for: input).isEmpty, input)
        }
        XCTAssertTrue(AndroidFormulaCandidatePolicy.candidates(for: String(repeating: "1", count: 256) + "^2").isEmpty)
    }

    func testPreferenceDefaultsToAndroidEnabledValue() {
        let suite = "AndroidFormulaCandidatesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AndroidFormulaCandidatePolicy.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AndroidFormulaCandidatePolicy.enabledKey)
        XCTAssertFalse(AndroidFormulaCandidatePolicy.isEnabled(defaults: defaults))
    }
}
