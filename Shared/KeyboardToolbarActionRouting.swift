extension KeyboardSurface: KeyboardToolbarActionRouting {
    var keyboardToolbarLiveConversionEnabled: Bool { liveConversion }

    @discardableResult
    func toggleKeyboardToolbarLiveConversion() -> Bool {
        let enabled = !liveConversion
        liveConversion = enabled
        (settingsWriteDefaults ?? settingsDefaults).set(enabled, forKey: "liveConversion")
        onSettingsWritten?(["liveConversion"])
        return enabled
    }

    var keyboardToolbarLearningPaused: Bool { learningPausedForSession }

    @discardableResult
    func toggleKeyboardToolbarLearningPause() -> Bool {
        toggleLearningPauseForSession()
    }
}
