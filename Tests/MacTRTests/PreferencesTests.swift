// PreferencesTests.swift — settings must survive a relaunch, and survive
// nonsense in the store (it's system-wide and writable from outside the app).

import Foundation
import Testing

@testable import MacTR

@Test("an empty store yields the defaults")
func emptyStoreYieldsDefaults() throws {
    try withThrowawayStore { store in
        #expect(Preferences(store: store).load() == DisplaySettings.default)
    }
}

@Test("saved settings come back unchanged")
func savedSettingsRoundTrip() throws {
    try withThrowawayStore { store in
        let prefs = Preferences(store: store)
        let settings = DisplaySettings(rotateDisplay: true, brightness: 8, refreshInterval: 2.0)
        prefs.save(settings)
        #expect(prefs.load() == settings)
    }
}

@Test("an out-of-range brightness is clamped, not discarded")
func brightnessIsClamped() throws {
    try withThrowawayStore { store in
        store.set(99, forKey: Preferences.Key.brightness)
        #expect(Preferences(store: store).load().brightness == 10)

        store.set(-5, forKey: Preferences.Key.brightness)
        #expect(Preferences(store: store).load().brightness == 1)
    }
}

@Test("a refresh interval the picker doesn't offer falls back to the default")
func unsupportedIntervalFallsBack() throws {
    try withThrowawayStore { store in
        store.set(7.5, forKey: Preferences.Key.refreshInterval)
        #expect(Preferences(store: store).load().refreshInterval
            == DisplaySettings.default.refreshInterval)
    }
}
