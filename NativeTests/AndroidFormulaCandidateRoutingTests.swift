import XCTest
import UIKit
@testable import SumireCore
@testable import Sumire

@MainActor final class AndroidFormulaCandidateRoutingTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func modeButton(in surface: Sumire.KeyboardSurface) throws -> UIButton {
        try XCTUnwrap(descendants(surface).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "tenkey-mode"
        })
    }

    private func flickKey(_ id: String, in surface: Sumire.KeyboardSurface) throws -> Sumire.FlickKey {
        try XCTUnwrap(descendants(surface).compactMap { $0 as? Sumire.FlickKey }.first {
            $0.accessibilityIdentifier == id
        })
    }

    private func enter25Squared(_ surface: Sumire.KeyboardSurface) throws {
        let mode = try modeButton(in: surface)
        mode.sendActions(for: .touchUpInside) // あ → a
        mode.sendActions(for: .touchUpInside) // a → 1
        let two = try flickKey("tenkey-0-1", in: surface)
        let five = try flickKey("tenkey-1-1", in: surface)
        let script = try flickKey("tenkey-2-2", in: surface)
        two.onFlick?(.tap) // 2
        five.onFlick?(.tap) // 5
        script.onFlick?(.left) // ^
        two.onFlick?(.tap) // 2
    }

    private func waitForCandidates(_ surface: Sumire.KeyboardSurface, containing value: String? = nil) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !surface.candidateBar.isUpdating && (value == nil || surface.candidateBar.candidates.contains(value!))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed,
                       "candidates=\(surface.candidateBar.candidates)")
    }

    func testDisplayedFormulaCandidateCommitsItsOwnTextWithoutNativeCandidateID() throws {
        let domain = "AndroidFormulaCandidateRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let surface = Sumire.KeyboardSurface()
        defer { surface.invalidateComposition() }
        surface.configureAppearancePreview(.tenKey, defaults: defaults)
        var commits: [String] = []
        surface.commitMarkedText = { commits.append($0) }

        try enter25Squared(surface)
        waitForCandidates(surface, containing: "25²")

        let displayed = try XCTUnwrap(surface.candidateBar.candidates.firstIndex(of: "25²"))
        XCTAssertEqual(surface.candidateBar.candidates[displayed + 1], "25^{2}")
        let presented = try XCTUnwrap(
            Mirror(reflecting: surface).children.first { $0.label == "presentedCandidates" }?.value
                as? [Sumire.ConversionCandidate]
        )
        XCTAssertEqual(presented[displayed].formulaCandidateCommitText, "25²")
        XCTAssertEqual(presented[displayed + 1].formulaCandidateCommitText, "25^{2}")

        surface.candidateBar.onSelect?(displayed)
        XCTAssertEqual(commits, ["25²"])
        XCTAssertTrue(surface.candidateBar.candidates.isEmpty)
    }

    func testDisabledPreferenceOmitsFormulaCandidates() throws {
        let domain = "AndroidFormulaCandidateRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: AndroidFormulaCandidatePolicy.enabledKey)
        let surface = Sumire.KeyboardSurface()
        defer { surface.invalidateComposition() }
        surface.configureAppearancePreview(.tenKey, defaults: defaults)

        try enter25Squared(surface)
        waitForCandidates(surface)
        XCTAssertFalse(surface.candidateBar.candidates.contains("25²"))
        XCTAssertFalse(surface.candidateBar.candidates.contains("25^{2}"))
    }

    func testCanonicalTexSourceIsNotDuplicatedAsTheLiteralCandidate() {
        let surface = Sumire.KeyboardSurface()
        defer { surface.invalidateComposition() }
        let source = "\\frac{1}{2}"
        let native = Sumire.ConversionCandidate(
            id: 41, text: source, score: 0,
            range: NSRange(location: 0, length: source.utf16.count),
            dictionaries: ["utility_literal"]
        )

        let candidates = surface.composeFormulaCandidates(
            query: source, nativeCandidates: [native], enabled: true
        )

        XCTAssertEqual(candidates.map(\.text), ["½", source])
        XCTAssertTrue(candidates.allSatisfy { $0.formulaCandidateCommitText != nil })
    }

    func testFormulaVariantsWithTheSameTextRemainSeparatelyLabeled() {
        let surface = Sumire.KeyboardSurface()
        defer { surface.invalidateComposition() }

        let candidates = surface.composeFormulaCandidates(
            query: "1 + 1", nativeCandidates: [], enabled: true
        )
        let sameText = candidates.filter { $0.text == "1+1" }
        let formulas = sameText.filter { $0.formulaCandidateKind != nil }

        XCTAssertEqual(candidates.map(\.text), ["1 + 1", "1+1", "1+1"])
        XCTAssertEqual(sameText.count, 2, "Keep same-text Unicode and TeX rows")
        XCTAssertEqual(formulas.map(\.formulaCandidateKind), [.unicode, .tex])
        XCTAssertEqual(formulas.map(\.displayAnnotation), ["[文字]", "[TeX]"])
        XCTAssertTrue(formulas.allSatisfy { $0.formulaCandidateCommitText == "1+1" })
    }

    func testFormulaKindAndCommitTextSurviveDisplayMergeReconstruction() {
        let formula = Sumire.ConversionCandidate(
            id: 51, text: "25²", score: 2,
            range: NSRange(location: 0, length: 4), dictionaries: ["formula_candidate"],
            formulaCandidateCommitText: "25²", formulaCandidateKind: .unicode,
            classifiedCategories: ["term"]
        )
        let duplicate = Sumire.ConversionCandidate(
            id: 52, text: "25²", score: 1,
            range: NSRange(location: 0, length: 4), dictionaries: ["native"],
            classifiedCategories: ["person"]
        )

        let merged = Sumire.ConversionCandidate.mergedForDisplay([formula, duplicate])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].formulaCandidateKind, .unicode)
        XCTAssertEqual(merged[0].formulaCandidateCommitText, "25²")
        XCTAssertEqual(merged[0].displayAnnotation, "[文字] [人名・用語]")
    }
}
