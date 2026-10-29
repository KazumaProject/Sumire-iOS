import XCTest
@testable import SumireCore

final class KeyFeedbackSettingsTests: XCTestCase {
    func testDefaultsMatchPinnedAndroidPreferences() {
        let settings = KeyFeedbackSettings()

        XCTAssertTrue(settings.isVibrationEnabled)
        XCTAssertEqual(settings.vibrationTiming, .both)
        XCTAssertFalse(settings.isKeySoundEnabled)
        XCTAssertEqual(settings.keySoundVolumePercent, 0)
        XCTAssertNil(settings.soundVolumeMultiplier, "zero delegates to the system default")
        XCTAssertTrue(settings.shouldVibrate(at: .press))
        XCTAssertTrue(settings.shouldVibrate(at: .release))
        XCTAssertFalse(settings.shouldPlaySound(at: .press, isRingerModeNormal: true))
    }

    func testVibrationTimingCoversPressReleaseBothAndDisabled() {
        var settings = KeyFeedbackSettings()

        settings.vibrationTiming = .press
        XCTAssertTrue(settings.shouldVibrate(at: .press))
        XCTAssertFalse(settings.shouldVibrate(at: .release))

        settings.vibrationTiming = .release
        XCTAssertFalse(settings.shouldVibrate(at: .press))
        XCTAssertTrue(settings.shouldVibrate(at: .release))

        settings.vibrationTiming = .both
        XCTAssertTrue(settings.shouldVibrate(at: .press))
        XCTAssertTrue(settings.shouldVibrate(at: .release))

        settings.vibrationTiming = .disabled
        XCTAssertFalse(settings.shouldVibrate(at: .press))
        XCTAssertFalse(settings.shouldVibrate(at: .release))

        settings.vibrationTiming = .both
        settings.isVibrationEnabled = false
        XCTAssertFalse(settings.shouldVibrate(at: .press))
        XCTAssertFalse(settings.shouldVibrate(at: .release))
    }

    func testUnknownAndroidVibrationTimingFailsClosed() throws {
        let data = Data(#"{"isVibrationEnabled":true,"vibrationTiming":"unknown"}"#.utf8)
        let settings = try JSONDecoder().decode(KeyFeedbackSettings.self, from: data)

        XCTAssertEqual(settings.vibrationTiming, .disabled)
        XCTAssertFalse(settings.shouldVibrate(at: .press))
        XCTAssertFalse(settings.shouldVibrate(at: .release))
        XCTAssertFalse(settings.isKeySoundEnabled)
        XCTAssertEqual(settings.keySoundVolumePercent, 0)
    }

    func testMissingFieldsRetainAndroidDefaults() throws {
        let data = Data(#"{"isKeySoundEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(KeyFeedbackSettings.self, from: data)

        XCTAssertTrue(settings.isVibrationEnabled)
        XCTAssertEqual(settings.vibrationTiming, .both)
        XCTAssertTrue(settings.isKeySoundEnabled)
        XCTAssertEqual(settings.keySoundVolumePercent, 0)
    }

    func testNullVibrationTimingUsesAndroidDefault() throws {
        let data = Data(#"{"vibrationTiming":null}"#.utf8)
        let settings = try JSONDecoder().decode(KeyFeedbackSettings.self, from: data)

        XCTAssertEqual(settings.vibrationTiming, .both)
    }

    func testNullFieldsUseAndroidReferenceDefaults() throws {
        let data = Data(#"{"isVibrationEnabled":null,"vibrationTiming":null,"isKeySoundEnabled":null,"keySoundVolumePercent":null}"#.utf8)
        let settings = try JSONDecoder().decode(KeyFeedbackSettings.self, from: data)

        XCTAssertTrue(settings.isVibrationEnabled)
        XCTAssertEqual(settings.vibrationTiming, .both)
        XCTAssertFalse(settings.isKeySoundEnabled)
        XCTAssertEqual(settings.keySoundVolumePercent, 0)
    }

    func testWrongTypedFieldsUseSafeReferenceDefaults() throws {
        let data = Data(#"{"isVibrationEnabled":"yes","vibrationTiming":4,"isKeySoundEnabled":"true","keySoundVolumePercent":"50"}"#.utf8)
        let settings = try JSONDecoder().decode(KeyFeedbackSettings.self, from: data)

        XCTAssertTrue(settings.isVibrationEnabled)
        XCTAssertEqual(settings.vibrationTiming, .disabled)
        XCTAssertFalse(settings.isKeySoundEnabled)
        XCTAssertEqual(settings.keySoundVolumePercent, 0)
        XCTAssertFalse(settings.shouldVibrate(at: .press))
    }

    func testSoundRequiresEnabledPreferenceAndNormalRingerMode() {
        var settings = KeyFeedbackSettings()
        settings.isKeySoundEnabled = true

        XCTAssertTrue(settings.shouldPlaySound(at: .press, isRingerModeNormal: true))
        XCTAssertFalse(settings.shouldPlaySound(at: .press, isRingerModeNormal: false))
        XCTAssertFalse(settings.shouldPlaySound(at: .release, isRingerModeNormal: true))

        settings.isKeySoundEnabled = false
        XCTAssertFalse(settings.shouldPlaySound(at: .press, isRingerModeNormal: true))
    }

    func testFeedbackIsSuppressedDuringKeyboardLayoutEditing() {
        var settings = KeyFeedbackSettings()
        settings.isKeySoundEnabled = true

        for moment in KeyFeedbackMoment.allCases {
            XCTAssertTrue(settings.shouldVibrate(at: moment))
            XCTAssertFalse(settings.shouldVibrate(at: moment, isKeyboardLayoutEditing: true))
            XCTAssertFalse(settings.shouldPlaySound(
                at: moment,
                isRingerModeNormal: true,
                isKeyboardLayoutEditing: true
            ))
        }

        XCTAssertTrue(settings.shouldPlaySound(at: .press, isRingerModeNormal: true))
    }

    func testSoundVolumeClampsAndZeroMeansSystemDefault() {
        var settings = KeyFeedbackSettings()
        settings.keySoundVolumePercent = -5
        XCTAssertEqual(settings.normalized.keySoundVolumePercent, 0)
        XCTAssertNil(settings.soundVolumeMultiplier)

        settings.keySoundVolumePercent = 40
        XCTAssertEqual(settings.soundVolumeMultiplier ?? -1, 0.4, accuracy: 0.000_001)

        settings.keySoundVolumePercent = 130
        XCTAssertEqual(settings.normalized.keySoundVolumePercent, 100)
        XCTAssertEqual(settings.soundVolumeMultiplier ?? -1, 1)
    }

    func testSoundTypesMatchAndroidKeyCategories() {
        XCTAssertEqual(KeyFeedbackSoundType.allCases.map(\.rawValue), ["standard", "delete", "enter"])
        XCTAssertEqual(KeyFeedbackKeyKind.ordinary.soundType, .standard)
        XCTAssertEqual(KeyFeedbackKeyKind.delete.soundType, .delete)
        XCTAssertEqual(KeyFeedbackKeyKind.enter.soundType, .enter)
    }

    func testKeyKindResolvesDeleteAndEnterFromUIKitMetadata() {
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(identifier: "gojuon-delete", label: "削除", title: nil), .delete)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(identifier: "sumire-deleteBackward", label: "⌫", title: nil), .delete)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(identifier: "qwerty-enter", label: "改行", title: nil), .enter)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(identifier: "custom-input-mode-return", label: "カスタム配列に戻る", title: "あa1"), .ordinary)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(identifier: "qwerty-return", label: "改行", title: nil), .enter)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(identifier: "custom-42", label: "かな", title: "かな"), .ordinary)
    }

    func testCustomActionSoundCategoryUsesActionInsteadOfDisplayText() {
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(action: .command(.delete)), .delete)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(action: .command(.backspace)), .delete)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(action: .command(.deleteUntilBoundary)), .delete)
        XCTAssertNil(KeyFeedbackKeyKind.resolve(action: .command(.doNothing)))
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(action: .command(.enter)), .enter)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(action: .command(.newLine)), .enter)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(action: .command(.confirm)), .enter)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(action: .text("⌫")), .ordinary)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(action: .command(.forceNewLine)), .ordinary)
        XCTAssertEqual(KeyFeedbackKeyKind.resolve(action: .switchLayout("layout-id")), .ordinary)
    }

    func testDefaultsRoundTripThroughBoundedStorage() {
        let suite = "KeyFeedbackSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = KeyFeedbackSettings()
        settings.isVibrationEnabled = false
        settings.vibrationTiming = .release
        settings.isKeySoundEnabled = true
        settings.keySoundVolumePercent = 65
        settings.save(defaults: defaults)

        XCTAssertEqual(KeyFeedbackSettings.load(defaults: defaults), settings)

        defaults.set(Data(repeating: 0x20, count: KeyFeedbackSettings.maximumStorageBytes + 1), forKey: KeyFeedbackSettings.storageKey)
        XCTAssertEqual(KeyFeedbackSettings.load(defaults: defaults), KeyFeedbackSettings())
    }

    func testLoadNormalizesPersistedVolumeToAndroidRange() throws {
        let suite = "KeyFeedbackVolumeNormalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(
            Data(#"{"keySoundVolumePercent":140}"#.utf8),
            forKey: KeyFeedbackSettings.storageKey
        )
        let aboveMaximum = KeyFeedbackSettings.load(defaults: defaults)
        XCTAssertEqual(aboveMaximum.keySoundVolumePercent, 100)
        XCTAssertEqual(aboveMaximum.soundVolumeMultiplier ?? -1, 1)

        defaults.set(
            Data(#"{"keySoundVolumePercent":-12}"#.utf8),
            forKey: KeyFeedbackSettings.storageKey
        )
        let belowMinimum = KeyFeedbackSettings.load(defaults: defaults)
        XCTAssertEqual(belowMinimum.keySoundVolumePercent, 0)
        XCTAssertNil(belowMinimum.soundVolumeMultiplier)
    }

    func testMalformedStorageUsesReferenceDefaults() {
        let suite = "KeyFeedbackMalformedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("not-json".utf8), forKey: KeyFeedbackSettings.storageKey)
        XCTAssertEqual(KeyFeedbackSettings.load(defaults: defaults), KeyFeedbackSettings())
    }

    func testKeyboardSettingsSnapshotRoundTripsAndValidatesKeyFeedback() throws {
        let suite = "KeyFeedbackSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = KeyFeedbackSettings()
        settings.isVibrationEnabled = false
        settings.vibrationTiming = .release
        settings.isKeySoundEnabled = true
        settings.keySoundVolumePercent = 65
        settings.save(defaults: defaults)

        let snapshot = try KeyboardSettingsSnapshot.capture(defaults: defaults)
        defaults.removeObject(forKey: KeyFeedbackSettings.storageKey)
        try snapshot.restore(defaults: defaults)
        XCTAssertEqual(KeyFeedbackSettings.load(defaults: defaults), settings)

        var invalid = snapshot
        invalid.values[KeyFeedbackSettings.storageKey] = .data(
            Data(#"{"keySoundVolumePercent":101}"#.utf8)
        )
        XCTAssertThrowsError(try invalid.validate())
    }
}
