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

    func testAndroidReferenceSupportedFormulaFamiliesAreAccepted() {
        let samples = [
            "a*b", "a<=b", "a≈b", "a∝b", "x->y", "5!", "10%",
            "sin(x)", "asin(x)", "sinh(x)", "log(x)", "exp(x)", "min(x,y)",
            "floor(x)", "ceil(x)", "⌊x⌋", "root(3,x)", "abs(x)", "norm(v)", "||v||",
            "alpha", "Gamma", "π", "∞", "prod(i=1,n,i)", "int(a,b,f)",
            "lim(x->0,f(x))", "forall x in A", "vec(v)", "dot(x)", "underline(x)",
            "\\frac{a}{\\frac{b}{c}}", "\\sqrt[3]{x}", "\\left|x+y\\right|",
            "\\lfloor x\\rfloor", "\\left\\lfloor x\\right\\rfloor",
            "\\langle x,y\\rangle", "\\sum_{i=1}^{n}i^2",
            "\\prod_{i=1}^{n}i", "\\int_0^1x\\,dx", "\\iint_D f", "\\iiint_V f",
            "\\oint_C f", "\\lim_{x\\to0}f(x)", "\\partial_x f", "\\nabla f",
            "\\mathbb{R}", "\\forall x\\in A", "\\vec{v}", "\\hat{x}",
            "\\bar{y}", "\\dot{z}", "\\ddot{z}", "\\tilde{x}", "\\mathcal{F}"
        ]

        for source in samples {
            XCTAssertNotNil(AndroidFormulaCandidatePolicy.parse(source), source)
        }
    }

    func testAndroidFormulaFamilyUnicodeAndTexOutputs() {
        let expected: [String: AndroidFormulaRendering] = [
            "a→b": .init(unicodeText: "a→b", normalizedTex: "a\\to b"),
            "a⇒b": .init(unicodeText: "a⇒b", normalizedTex: "a\\Rightarrow b"),
            "a∝b": .init(unicodeText: "a∝b", normalizedTex: "a\\propto b"),
            "abs(x)": .init(unicodeText: "|x|", normalizedTex: "|x|"),
            "norm(v)": .init(unicodeText: "‖v‖", normalizedTex: "\\Vert v\\Vert"),
            "floor(x)": .init(unicodeText: "⌊x⌋", normalizedTex: "\\lfloor x\\rfloor"),
            "ceil(x)": .init(unicodeText: "⌈x⌉", normalizedTex: "\\lceil x\\rceil"),
            // The Android FormulaNode model consumes commas as argument separators and omits them from its rendered row.
            "min(x,y)": .init(unicodeText: "min(xy)", normalizedTex: "\\min(xy)"),
            "vec(v)": .init(unicodeText: "v⃗", normalizedTex: "\\vec{v}"),
            "dot(z)": .init(unicodeText: "ż", normalizedTex: "\\dot{z}"),
            "\\left|x+y\\right|": .init(unicodeText: "|x+y|", normalizedTex: "\\left|x+y\\right|"),
            "\\left\\lfloor x\\right\\rfloor": .init(unicodeText: "⌊x⌋", normalizedTex: "\\left\\lfloor x\\right\\rfloor"),
            "\\langle x,y\\rangle": .init(unicodeText: "⟨x,y⟩", normalizedTex: "\\langle x,y\\rangle"),
            "\\sum_{i=1}^{n}i^2": .init(unicodeText: "∑ᵢ₌₁ⁿ i²", normalizedTex: "\\sum_{i=1}^{n}i^{2}")
        ]

        for (source, rendering) in expected {
            XCTAssertEqual(AndroidFormulaCandidatePolicy.parse(source), rendering, source)
        }
    }

    func testMinusAndSquareBracketScriptMatchAndroidRendering() {
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("x−y^2"),
            .init(unicodeText: "x−y²", normalizedTex: "x−y^{2}")
        )
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("−x^2"),
            .init(unicodeText: "−x²", normalizedTex: "−x^{2}")
        )
        XCTAssertNil(AndroidFormulaCandidatePolicy.parse("x–y^2"), "Android does not normalize en dash to minus")
        XCTAssertNil(AndroidFormulaCandidatePolicy.parse("x—y^2"), "Android does not normalize em dash to minus")
        XCTAssertNil(AndroidFormulaCandidatePolicy.parse("–x^2"), "En dash is not a formula prefix operator")
        XCTAssertNil(AndroidFormulaCandidatePolicy.parse("—x^2"), "Em dash is not a formula prefix operator")
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("x^[n+1]"),
            .init(unicodeText: "x[ⁿ⁺¹]", normalizedTex: "x^{[n+1]}")
        )
        XCTAssertNil(AndroidFormulaCandidatePolicy.parse("x^[n+1"), "Reject an unfinished square-bracket group")
    }

    func testGroupedScriptParenthesesMatchAndroidUnicodeOutput() {
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("x^(n)"),
            .init(unicodeText: "xⁿ", normalizedTex: "x^{n}")
        )
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("x^(n+1)"),
            .init(unicodeText: "x⁽ⁿ⁺¹⁾", normalizedTex: "x^{n+1}")
        )
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("x^{n+1}"),
            .init(unicodeText: "x⁽ⁿ⁺¹⁾", normalizedTex: "x^{n+1}")
        )
    }

    func testMiddleDotAndCaseInsensitiveFunctionNamesMatchAndroid() {
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("x·y"),
            .init(unicodeText: "x⋅y", normalizedTex: "x\\cdot y")
        )
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("SIN(x)"),
            AndroidFormulaCandidatePolicy.parse("sin(x)")
        )
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("x MOD y"),
            .init(unicodeText: "xmod y", normalizedTex: "x\\bmod y")
        )
        XCTAssertNil(AndroidFormulaCandidatePolicy.parse("x module y"), "Do not treat a mod identifier prefix as an operator")
    }

    func testLeadingDecimalAndBracketAdjacencyMatchAndroid() {
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse(".5^2"),
            .init(unicodeText: ".5²", normalizedTex: ".5^{2}")
        )
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("x^2[1]"),
            .init(unicodeText: "x²[1]", normalizedTex: "x^{2}[1]")
        )
        XCTAssertNil(AndroidFormulaCandidatePolicy.parse("½^2"), "Android does not treat a Unicode fraction as a decimal digit")
        XCTAssertNil(AndroidFormulaCandidatePolicy.parse("x⌊1⌋"), "Android does not allow a floor delimiter as implicit multiplication")
    }

    func testDelimitedFunctionAliasesPassAndroidFormulaGate() {
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("absolute(x)"),
            AndroidFormulaCandidatePolicy.parse("abs(x)")
        )
        XCTAssertEqual(
            AndroidFormulaCandidatePolicy.parse("ceiling(x)"),
            AndroidFormulaCandidatePolicy.parse("ceil(x)")
        )
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
