import XCTest
@testable import SumireCore

final class AndroidZenzPolicyTests: XCTestCase {
    private let enabledSettings = AndroidZenzRequestSettings(
        zenzEnabled: true,
        longPressConversionEnabled: true,
        hardwareKeyboardConnected: false,
        rerankEnabled: false,
        zenzaiEnabled: false
    )

    func testLiveAndBunsetsuRequestsFollowEnabledAndRerankGates() {
        XCTAssertNil(AndroidZenzRequestPolicy.blockReason(
            for: "あ?ー。",
            source: .automaticLive,
            settings: enabledSettings
        ))
        XCTAssertNil(AndroidZenzRequestPolicy.blockReason(
            for: "あいう",
            source: .bunsetsuSegment,
            settings: enabledSettings
        ))

        let rerankWithoutZenzai = AndroidZenzRequestSettings(
            zenzEnabled: true,
            longPressConversionEnabled: true,
            hardwareKeyboardConnected: false,
            rerankEnabled: true,
            zenzaiEnabled: false
        )
        XCTAssertEqual(
            AndroidZenzRequestPolicy.blockReason(
                for: "あいう",
                source: .automaticLive,
                settings: rerankWithoutZenzai
            ),
            .rerankRequiresZenzai
        )
        XCTAssertEqual(
            AndroidZenzRequestPolicy.blockReason(
                for: "あいう",
                source: .bunsetsuSegment,
                settings: rerankWithoutZenzai
            ),
            .rerankRequiresZenzai
        )
    }

    func testManualLongPressUsesItsOwnSettingAndSkipsLiveRerankGate() {
        let settings = AndroidZenzRequestSettings(
            zenzEnabled: false,
            longPressConversionEnabled: true,
            hardwareKeyboardConnected: false,
            rerankEnabled: true,
            zenzaiEnabled: false
        )
        XCTAssertNil(AndroidZenzRequestPolicy.blockReason(
            for: "あいう",
            source: .manualConvertLongPress,
            settings: settings
        ))
        XCTAssertEqual(
            AndroidZenzRequestPolicy.blockReason(
                for: "あいう",
                source: .manualConvertLongPress,
                settings: AndroidZenzRequestSettings(
                    zenzEnabled: true,
                    longPressConversionEnabled: false,
                    hardwareKeyboardConnected: false,
                    rerankEnabled: false,
                    zenzaiEnabled: true
                )
            ),
            .longPressConversionDisabled
        )
    }

    func testRequestBlockReasonPrecedenceAndUTF16LengthMatchAndroid() {
        XCTAssertEqual(AndroidZenzRequestPolicy.blockReason(
            for: "",
            source: .manualConvertLongPress,
            settings: AndroidZenzRequestSettings(
                zenzEnabled: false,
                longPressConversionEnabled: false,
                hardwareKeyboardConnected: true,
                rerankEnabled: true,
                zenzaiEnabled: false
            )
        ), .emptyInput)

        XCTAssertEqual(AndroidZenzRequestPolicy.blockReason(
            for: "あ",
            source: .automaticLive,
            settings: enabledSettings
        ), .inputTooShort)
        XCTAssertEqual(AndroidZenzRequestPolicy.blockReason(
            for: "😀",
            source: .automaticLive,
            settings: enabledSettings
        ), .inputNotHiraganaWithSymbols)
        XCTAssertEqual(AndroidZenzRequestPolicy.blockReason(
            for: "カナ",
            source: .automaticLive,
            settings: enabledSettings
        ), .inputNotHiraganaWithSymbols)
    }

    func testHiraganaPredicateMatchesExactAndroidBMPSetAndPunctuation() {
        for allowed in ["ぁ", "ゖ", "ー", "-", "？", "?", "！", "!", "。", "、"] {
            XCTAssertTrue(AndroidZenzRequestPolicy.isAllHiraganaWithSymbols("あ\(allowed)"), allowed)
        }
        for rejected in ["", "ゝ", "ゟ", "　", "\n", "😀"] {
            XCTAssertFalse(AndroidZenzRequestPolicy.isAllHiraganaWithSymbols(rejected), rejected)
        }
    }

    func testHardwareKeyboardAndGeneralPreferenceBlockRequests() {
        let hardwareKeyboard = AndroidZenzRequestSettings(
            zenzEnabled: true,
            longPressConversionEnabled: true,
            hardwareKeyboardConnected: true,
            rerankEnabled: false,
            zenzaiEnabled: true
        )
        XCTAssertEqual(AndroidZenzRequestPolicy.blockReason(
            for: "あいう",
            source: .automaticLive,
            settings: hardwareKeyboard
        ), .hardwareKeyboardConnected)

        let disabled = AndroidZenzRequestSettings(
            zenzEnabled: false,
            longPressConversionEnabled: true,
            hardwareKeyboardConnected: false,
            rerankEnabled: false,
            zenzaiEnabled: true
        )
        XCTAssertEqual(AndroidZenzRequestPolicy.blockReason(
            for: "あいう",
            source: .bunsetsuSegment,
            settings: disabled
        ), .zenzDisabled)
    }

    func testRequestBlockReasonPreservesAndroidGatePrecedence() {
        let bothManualPreferenceAndHardwareFail = AndroidZenzRequestSettings(
            zenzEnabled: false,
            longPressConversionEnabled: false,
            hardwareKeyboardConnected: true,
            rerankEnabled: true,
            zenzaiEnabled: false
        )
        XCTAssertEqual(AndroidZenzRequestPolicy.blockReason(
            for: "あいう",
            source: .manualConvertLongPress,
            settings: bothManualPreferenceAndHardwareFail
        ), .longPressConversionDisabled)

        let bothGeneralPreferenceAndHardwareFail = AndroidZenzRequestSettings(
            zenzEnabled: false,
            longPressConversionEnabled: true,
            hardwareKeyboardConnected: true,
            rerankEnabled: false,
            zenzaiEnabled: true
        )
        XCTAssertEqual(AndroidZenzRequestPolicy.blockReason(
            for: "あいう",
            source: .automaticLive,
            settings: bothGeneralPreferenceAndHardwareFail
        ), .zenzDisabled)

        let hardwareAndLengthFail = AndroidZenzRequestSettings(
            zenzEnabled: true,
            longPressConversionEnabled: true,
            hardwareKeyboardConnected: true,
            rerankEnabled: false,
            zenzaiEnabled: true
        )
        XCTAssertEqual(AndroidZenzRequestPolicy.blockReason(
            for: "あ",
            source: .automaticLive,
            settings: hardwareAndLengthFail
        ), .hardwareKeyboardConnected)
    }

    func testOutputPolicyRejectsEmptyMarkersControlsReplacementAndMalformedSurrogates() {
        XCTAssertNil(AndroidZenzOutputPolicy.acceptedTextOrNil(nil))
        XCTAssertNil(AndroidZenzOutputPolicy.acceptedTextOrNil(""))
        for marker in 0xEE00...0xEE0F {
            let text = "末\(UnicodeScalar(UInt32(marker))!)まつ"
            XCTAssertNil(AndroidZenzOutputPolicy.acceptedTextOrNil(text), "U+\(String(marker, radix: 16))")
        }
        for unsafe in ["末\u{0000}", "末\n", "末\u{007F}", "末\u{FFFD}"] {
            XCTAssertNil(AndroidZenzOutputPolicy.acceptedTextOrNil(unsafe))
        }
        XCTAssertFalse(AndroidZenzOutputPolicy.isSafeUTF16CodeUnits([0xD800]))
        XCTAssertFalse(AndroidZenzOutputPolicy.isSafeUTF16CodeUnits([0xDC00]))
        XCTAssertFalse(AndroidZenzOutputPolicy.isSafeUTF16CodeUnits([0xD800, 0x0041]))
    }

    func testOutputPolicyAcceptsOrdinaryAndValidSupplementaryTextWithoutLengthHeuristic() {
        let longText = String(repeating: "意味のある変換結果", count: 8)
        XCTAssertEqual(AndroidZenzOutputPolicy.acceptedTextOrNil("末"), "末")
        XCTAssertEqual(AndroidZenzOutputPolicy.acceptedTextOrNil(longText), longText)
        XCTAssertEqual(AndroidZenzOutputPolicy.acceptedTextOrNil("😀"), "😀")
    }
}
