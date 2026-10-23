import Foundation
import XCTest
@testable import SumireCore

final class AndroidTextMacroCompilerTests: XCTestCase {
    private var fixedContext: AndroidTextMacroContext {
        AndroidTextMacroContext(
            selection: "{date}",
            clipboard: "{time}",
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "America/Toronto")!,
            timestamp: Date(timeIntervalSince1970: 1_788_098_706.123)
        )
    }

    func testExpandsVariablesAtOneTimestampAndUsesUTF16CursorOffset() throws {
        let expanded = try AndroidTextMacroCompiler.compile(
            "{date:yyyy-MM-dd}|{time:HH:mm:ss}|{selection}|{clipboard}|{newline}x{cursor}y"
        ).expand(context: fixedContext)

        XCTAssertEqual(expanded.text, "2026-08-30|10:05:06|{date}|{time}|\nxy")
        XCTAssertEqual(expanded.cursorOffset, expanded.text.utf16.count - 1)
    }

    func testJavaMillisecondAndIsoWeekdayFieldsKeepTheirJavaMeaning() throws {
        let context = AndroidTextMacroContext(
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "America/Toronto")!,
            timestamp: Date(timeIntervalSince1970: 1_788_098_706.005)
        )
        let expanded = try AndroidTextMacroCompiler.compile("{date:SS|SSS|u|uu}")
            .expand(context: context)

        XCTAssertEqual(expanded.text, "05|005|7|07")
    }

    func testQuotedPatternTextAndNonBMPLiteralsArePreserved() throws {
        let expanded = try AndroidTextMacroCompiler.compile("{date:yyyy-'😀'-'it''s'-'S'}")
            .expand(context: fixedContext)

        XCTAssertEqual(expanded.text, "2026-😀-it's-S")
    }

    func testIsoTimezonePatternAcceptsAndroidWidthsAndRejectsOversizedWidth() {
        for width in 1...3 {
            XCTAssertNoThrow(
                try AndroidTextMacroCompiler.compile("{date:\(String(repeating: "X", count: width))}")
            )
        }
        for width in 4...5 {
            XCTAssertThrowsError(
                try AndroidTextMacroCompiler.compile("{date:\(String(repeating: "X", count: width))}")
            )
        }
    }

    func testJavaTextAndTimezoneWidthsDoNotAcquireUnicodeNarrowForms() throws {
        func format(_ pattern: String) throws -> String {
            try AndroidTextMacroCompiler.compile("{date:\(pattern)}")
                .expand(context: fixedContext)
                .text
        }

        XCTAssertEqual(try format("EEEEE"), "Sunday")
        XCTAssertEqual(try format("MMMMM"), "August")
        XCTAssertEqual(try format("LLLLL"), "August")

        for (javaShort, javaWide) in [
            ("E", "EEE"),
            ("EEEE", "EEEEE"),
            ("MMMM", "MMMMM"),
            ("LLLL", "LLLLL"),
            ("G", "GGGGG"),
            ("a", "aaaaa"),
            ("z", "zzz"),
            ("zzzz", "zzzzz"),
            ("Z", "ZZZZZ")
        ] {
            XCTAssertEqual(try format(javaShort), try format(javaWide), "\(javaShort) vs \(javaWide)")
        }
    }

    func testEscapedBracesAndContextValuesAreNotRecursivelyExpanded() throws {
        let expanded = try AndroidTextMacroCompiler.compile("{{date}} {selection} {clipboard}")
            .expand(context: fixedContext)

        XCTAssertEqual(expanded.text, "{date} {date} {time}")
    }

    func testCursorCanFollowAnEmojiAndDefaultsToEnd() throws {
        let withCursor = try AndroidTextMacroCompiler.compile("😀{cursor}x")
            .expand(context: fixedContext)
        let withoutCursor = try AndroidTextMacroCompiler.compile("😀x")
            .expand(context: fixedContext)

        XCTAssertEqual(withCursor.text, "😀x")
        XCTAssertEqual(withCursor.cursorOffset, 2)
        XCTAssertEqual(withoutCursor.cursorOffset, 3)
    }

    func testCursorAdjustmentUsesUTF16AndAllowsEndAndGraphemeInteriorPositions() throws {
        let atEnd = try AndroidTextMacroCompiler.compile("😀{cursor}").expand(context: fixedContext)
        XCTAssertEqual(try atEnd.cursorAdjustmentUTF16(), 0)

        let beforeEmoji = try AndroidTextMacroCompiler.compile("a{cursor}😀").expand(context: fixedContext)
        XCTAssertEqual(try beforeEmoji.cursorAdjustmentUTF16(), -2)

        let betweenBaseAndCombiningMark = try AndroidTextMacroCompiler.compile("e{cursor}\u{0301}")
            .expand(context: fixedContext)
        XCTAssertEqual(try betweenBaseAndCombiningMark.cursorAdjustmentUTF16(), -1)
    }

    func testCursorAdjustmentRejectsOffsetsOutsideTextOrInsideSurrogatePair() {
        XCTAssertThrowsError(try AndroidExpandedTextMacro(text: "x", cursorOffset: 2).cursorAdjustmentUTF16())
        XCTAssertThrowsError(try AndroidExpandedTextMacro(text: "😀", cursorOffset: 1).cursorAdjustmentUTF16())
    }

    func testReportsUTF16SyntaxPositionAndRequiredContext() throws {
        XCTAssertThrowsError(try AndroidTextMacroCompiler.compile("😀{unknown}")) { error in
            XCTAssertEqual((error as? AndroidTextMacroSyntaxError)?.position, 2)
        }

        let emptyContext = AndroidTextMacroContext(
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        for token in ["{selection}", "{clipboard}"] {
            XCTAssertThrowsError(
                try AndroidTextMacroCompiler.compile(token).expand(context: emptyContext)
            )
        }
        XCTAssertEqual(
            try AndroidTextMacroCompiler.compile("{selection}{clipboard}{date}").requirements,
            [.selection, .clipboard]
        )
    }

    func testCandidatePolicyKeepsClipboardMacrosBehindExplicitConsentAndOmitsSelectionMacros() {
        let macros = [
            PersonalTextMacro(name: "Zeta", reading: "yomi", body: "{clipboard}"),
            PersonalTextMacro(name: "Alpha", reading: "yomi", body: "plain"),
            PersonalTextMacro(name: "Selected", reading: "yomi", body: "{selection}"),
            PersonalTextMacro(name: "Disabled", reading: "yomi", body: "plain", enabled: false),
            PersonalTextMacro(name: "Different", reading: "Yomi", body: "plain")
        ]

        XCTAssertEqual(
            AndroidTextMacroCandidatePolicy.candidates(in: macros, reading: "yomi", contextAllowed: true)
                .map(\.name),
            ["Alpha", "Zeta"]
        )
        XCTAssertEqual(
            AndroidTextMacroCandidatePolicy.candidates(in: macros, reading: "yomi", contextAllowed: false)
                .map(\.name),
            ["Alpha"]
        )
    }

    func testCandidatePolicyUsesAndroidLimitAndASCIINameOrder() {
        let macros = (1...10).reversed().map { index in
            PersonalTextMacro(name: "Macro \(index)", reading: "yomi", body: "\(index)")
        }

        XCTAssertEqual(
            AndroidTextMacroCandidatePolicy.candidates(in: macros, reading: "yomi", contextAllowed: true)
                .map(\.name),
            ["Macro 1", "Macro 10", "Macro 2", "Macro 3", "Macro 4", "Macro 5", "Macro 6", "Macro 7"]
        )
    }

    func testMacroOrderingUsesSQLiteNoCaseNulTerminationAndStableTies() {
        let macros = [
            PersonalTextMacro(name: "A\u{0}z", reading: "yomi", body: "first"),
            PersonalTextMacro(name: "B", reading: "yomi", body: "second"),
            PersonalTextMacro(name: "a\u{0}Y", reading: "yomi", body: "third")
        ]

        let expected = ["A\u{0}z", "a\u{0}Y", "B"]
        XCTAssertEqual(AndroidTextMacroCandidatePolicy.ordered(in: macros).map(\.name), expected)
        XCTAssertEqual(
            AndroidTextMacroCandidatePolicy.candidates(in: macros, reading: "yomi", contextAllowed: true)
                .map(\.name),
            expected
        )
    }

    func testCandidatePolicyAppliesAndroidLimitBeforeContextFiltering() {
        let macros = (1...9).reversed().map { index in
            PersonalTextMacro(
                name: String(format: "Macro %02d", index),
                reading: "yomi",
                body: index == 9 ? "visible only after promotion" : "{clipboard}"
            )
        }

        // Android first limits the SQL result to the first eight ordered rows,
        // then hides contextual macros when clipboard access was not consented.
        // The ninth row must not be promoted to fill the resulting empty list.
        XCTAssertEqual(
            AndroidTextMacroCandidatePolicy.candidates(in: macros, reading: "yomi", contextAllowed: false)
                .map(\.name),
            []
        )
    }

    func testRejectsMalformedTokensPatternsAndDuplicateCursor() {
        for body in [
            "{date",
            "}",
            "{clipboard:x}",
            "{date:}",
            "{date:'}",
            "{date:Q}",
            "{cursor}{cursor}",
            "{outer:{date}}"
        ] {
            XCTAssertThrowsError(try AndroidTextMacroCompiler.compile(body), body)
        }
    }

    func testEnforcesAndroidDefinitionAndExpansionLimits() {
        XCTAssertThrowsError(
            try AndroidTextMacroValidator.validateDefinition(name: "n".repeating(81), reading: nil, body: "body")
        )
        XCTAssertThrowsError(
            try AndroidTextMacroValidator.validateDefinition(name: "name", reading: "r".repeating(65), body: "body")
        )
        XCTAssertThrowsError(
            try AndroidTextMacroCompiler.compile(String(repeating: "😀", count: 5_001))
        )
        XCTAssertThrowsError(
            try AndroidTextMacroCompiler.compile("{date:\(String(repeating: "y", count: 128))}")
        )

        let context = AndroidTextMacroContext(selection: String(repeating: "s", count: 100_001))
        XCTAssertThrowsError(
            try AndroidTextMacroCompiler.compile("{selection}").expand(context: context)
        )
    }
}

private extension String {
    func repeating(_ count: Int) -> String { String(repeating: self, count: count) }
}
