import XCTest
@testable import SumireCore

final class AndroidFormulaLayoutTests: XCTestCase {
    private let measure = { (value: String, size: Double) in Double(value.count) * size * 0.6 }

    func testFractionNumeratorAndDenominatorStayOnOppositeSidesOfRule() throws {
        let layout = try XCTUnwrap(AndroidFormulaCandidatePolicy.layout(
            for: "\\frac{12}{34}",
            config: AndroidFormulaLayoutConfig(fontSize: 20),
            measureText: measure
        ))
        let texts = layout.operations.compactMap { operation -> (String, Double, Double)? in
            guard case .text(let value, let x, let baseline, _, _) = operation else { return nil }
            return (value, x, baseline)
        }
        let rule = try XCTUnwrap(layout.operations.compactMap { operation -> (Double, Double, Double)? in
            guard case .line(let startX, let startY, let endX, _, _) = operation else { return nil }
            return (startX, startY, endX)
        }.first)
        let numerator = try XCTUnwrap(texts.first { $0.0 == "12" })
        let denominator = try XCTUnwrap(texts.first { $0.0 == "34" })

        XCTAssertLessThan(numerator.2, rule.1)
        XCTAssertGreaterThan(denominator.2, rule.1)
        XCTAssertGreaterThan(numerator.1, 0)
        XCTAssertGreaterThan(denominator.1, 0)
        XCTAssertGreaterThanOrEqual(layout.width, numerator.1 + 2 * 20 * 0.82 * 0.6)
        XCTAssertGreaterThan(rule.2, rule.0)
    }

    func testSquareRootShorthandUsesRadicalBarLayout() throws {
        let layout = try XCTUnwrap(AndroidFormulaCandidatePolicy.layout(for: "√x"))

        XCTAssertTrue(layout.operations.contains { operation in
            if case .line = operation { return true }
            return false
        })
        XCTAssertTrue(layout.operations.contains { operation in
            if case .text("√", _, _, _, _) = operation { return true }
            return false
        })
        XCTAssertTrue(layout.operations.contains { operation in
            if case .text("x", _, _, _, _) = operation { return true }
            return false
        })
    }

    func testNestedScriptsAndLargeOperatorProduceFiniteBounds() throws {
        let layout = try XCTUnwrap(AndroidFormulaCandidatePolicy.layout(
            for: "sum(i=1,n,i^2)",
            config: AndroidFormulaLayoutConfig(fontSize: 18),
            measureText: measure
        ))

        XCTAssertGreaterThan(layout.width, 0)
        XCTAssertGreaterThan(layout.height, 0)
        XCTAssertTrue(layout.operations.allSatisfy { operation in
            switch operation {
            case .text(_, let x, let baseline, let size, _):
                return x >= 0 && baseline.isFinite && size.isFinite
            case .line(let startX, let startY, let endX, let endY, let width):
                return startX >= 0 && startY.isFinite && endX >= startX && endY.isFinite && width.isFinite
            }
        })
    }

    func testDefaultTextMeasurementUsesAndroidUTF16Length() throws {
        let formula = "𝑥+1"
        let defaultLayout = try XCTUnwrap(AndroidFormulaCandidatePolicy.layout(for: formula))
        let utf16Layout = try XCTUnwrap(AndroidFormulaCandidatePolicy.layout(
            for: formula,
            measureText: { value, size in Double(value.utf16.count) * size * 0.58 }
        ))
        let characterCountLayout = try XCTUnwrap(AndroidFormulaCandidatePolicy.layout(
            for: formula,
            measureText: { value, size in Double(value.count) * size * 0.58 }
        ))

        XCTAssertEqual(defaultLayout.width, utf16Layout.width, accuracy: 0.000_001)
        XCTAssertGreaterThan(defaultLayout.width, characterCountLayout.width)
    }

    func testAllDrawingOperationsFitReportedVerticalBounds() throws {
        let config = AndroidFormulaLayoutConfig(fontSize: 18)
        let layout = try XCTUnwrap(AndroidFormulaCandidatePolicy.layout(
            for: "\\hat{x_1^2}+\\sum_{i=1}^{n}i^2",
            config: config,
            measureText: measure
        ))

        XCTAssertTrue(layout.operations.allSatisfy { operation in
            switch operation {
            case .text(_, _, let baseline, let size, _):
                return baseline - size * config.ascentRatio >= -layout.ascent - 0.001 &&
                    baseline + size * config.descentRatio <= layout.descent + 0.001
            case .line(_, let startY, _, let endY, let strokeWidth):
                let halfStroke = strokeWidth / 2
                return startY - halfStroke >= -layout.ascent - 0.001 &&
                    endY + halfStroke <= layout.descent + 0.001
            }
        })
    }

    func testUnrecognizedFormulaDoesNotProduceLayout() {
        XCTAssertNil(AndroidFormulaCandidatePolicy.layout(for: "hello world", measureText: measure))
    }
}
