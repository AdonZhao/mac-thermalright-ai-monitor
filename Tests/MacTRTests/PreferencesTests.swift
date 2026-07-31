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
        let settings = DisplaySettings(rotateDisplay: true, brightness: 8, refreshInterval: 2.0, night: .default)
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

/// The picker and the validator read the same list, so this holds by
/// construction — which is the point. It fails the moment someone reintroduces a
/// second hardcoded list of options, the mistake that would silently reset a
/// user's choice at the next launch.
@Test("every interval the picker offers survives a round trip")
func everyOfferedIntervalRoundTrips() throws {
    try withThrowawayStore { store in
        let prefs = Preferences(store: store)
        for choice in Preferences.refreshIntervalChoices {
            prefs.save(DisplaySettings(
                rotateDisplay: false, brightness: 5, refreshInterval: choice.seconds, night: .default))
            #expect(prefs.load().refreshInterval == choice.seconds,
                    "\(choice.label) did not survive")
        }
    }
}

/// Settings written before the keys gained their `display.` prefix must still be
/// honoured — this app only just learned to remember them, so dropping them on
/// the very next upgrade would undo the point.
@Test("settings stored under the pre-prefix keys are still read")
func legacyKeysAreStillRead() throws {
    try withThrowawayStore { store in
        store.set(true, forKey: Preferences.LegacyKey.rotateDisplay)
        store.set(8, forKey: Preferences.LegacyKey.brightness)
        store.set(2.0, forKey: Preferences.LegacyKey.refreshInterval)

        #expect(Preferences(store: store).load()
            == DisplaySettings(rotateDisplay: true, brightness: 8, refreshInterval: 2.0, night: .default))
    }
}

@Test("the night schedule survives a round trip, switched off included")
func nightScheduleRoundTrips() throws {
    try withThrowawayStore { store in
        let prefs = Preferences(store: store)
        var settings = DisplaySettings.default
        settings.night = NightSchedule(enabled: false, startMinute: 20 * 60, endMinute: 7 * 60)

        prefs.save(settings)

        #expect(prefs.load().night == settings.night)
    }
}

/// A time of day outside the day was never a time, so there is no nearer one to
/// honour — unlike brightness, which clamps.
@Test("an out-of-day night time falls back to the default")
func outOfRangeNightTimeFallsBack() throws {
    try withThrowawayStore { store in
        store.set(24 * 60, forKey: Preferences.Key.nightStartMinute)   // 24:00 is not a time
        store.set(-30, forKey: Preferences.Key.nightEndMinute)

        let night = Preferences(store: store).load().night
        #expect(night.startMinute == NightSchedule.default.startMinute)
        #expect(night.endMinute == NightSchedule.default.endMinute)
    }
}

/// The comment on `LegacyKey` claims saving retires the old keys. This is the
/// assertion that makes that claim true rather than aspirational — and it is what
/// lets the fallback be deleted in a release or two.
@Test("saving retires the pre-prefix keys")
func savingRemovesLegacyKeys() throws {
    try withThrowawayStore { store in
        store.set(true, forKey: Preferences.LegacyKey.rotateDisplay)
        store.set(8, forKey: Preferences.LegacyKey.brightness)
        store.set(2.0, forKey: Preferences.LegacyKey.refreshInterval)

        let prefs = Preferences(store: store)
        prefs.save(prefs.load())   // what the first settings change does

        #expect(store.object(forKey: Preferences.LegacyKey.rotateDisplay) == nil)
        #expect(store.object(forKey: Preferences.LegacyKey.brightness) == nil)
        #expect(store.object(forKey: Preferences.LegacyKey.refreshInterval) == nil)
        // and the values themselves survived the move
        #expect(prefs.load()
            == DisplaySettings(rotateDisplay: true, brightness: 8,
                               refreshInterval: 2.0, night: .default))
    }
}

@Test("a current key wins over a leftover legacy key")
func currentKeyWinsOverLegacy() throws {
    try withThrowawayStore { store in
        store.set(3, forKey: Preferences.LegacyKey.brightness)
        store.set(9, forKey: Preferences.Key.brightness)

        #expect(Preferences(store: store).load().brightness == 9)
    }
}
