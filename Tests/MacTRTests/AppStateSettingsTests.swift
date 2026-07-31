// AppStateSettingsTests.swift — the wiring between AppState and the store.

import Foundation
import Testing

@testable import MacTR

@Test("a fresh AppState picks up what was saved")
@MainActor
func appStateLoadsSavedSettings() throws {
    try withThrowawayStore { store in
        Preferences(store: store).save(
            DisplaySettings(rotateDisplay: true, brightness: 8, refreshInterval: 1.0, night: .default))

        let state = AppState(preferences: Preferences(store: store))

        #expect(state.rotateDisplay == true)
        #expect(state.brightness == 8)
        #expect(state.refreshInterval == 1.0)
    }
}

@Test("applySettings writes the current values out")
@MainActor
func applySettingsPersists() throws {
    try withThrowawayStore { store in
        let prefs = Preferences(store: store)
        let state = AppState(preferences: prefs)

        state.rotateDisplay = true
        state.brightness = 8
        state.applySettings()

        #expect(prefs.load()
            == DisplaySettings(rotateDisplay: true, brightness: 8, refreshInterval: 0.5, night: .default))
    }
}
