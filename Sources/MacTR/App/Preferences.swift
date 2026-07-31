// Preferences.swift — the display settings that survive a relaunch.
//
// The backing store is injected rather than reached for, so tests get a
// throwaway suite instead of the real user defaults.

import Foundation

/// The user-adjustable display settings, as one value.
struct DisplaySettings: Equatable, Sendable {
    var rotateDisplay: Bool
    var brightness: Int
    var refreshInterval: Double

    static let `default` = DisplaySettings(
        rotateDisplay: false, brightness: 5, refreshInterval: 0.5)
}

struct Preferences {

    /// The intervals the Settings picker offers. Anything else is treated as
    /// corrupt rather than clamped — there's no sensible nearest value.
    static let allowedRefreshIntervals: Set<Double> = [0.5, 1.0, 2.0]
    static let brightnessRange = 1...10

    /// Internal rather than private so tests can plant values without
    /// duplicating the key strings.
    enum Key {
        static let rotateDisplay = "rotateDisplay"
        static let brightness = "brightness"
        static let refreshInterval = "refreshInterval"
    }

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
    }

    func load() -> DisplaySettings {
        DisplaySettings(
            rotateDisplay: store.object(forKey: Key.rotateDisplay) as? Bool
                ?? DisplaySettings.default.rotateDisplay,
            brightness: Self.validBrightness(store.object(forKey: Key.brightness) as? Int),
            refreshInterval: Self.validInterval(
                store.object(forKey: Key.refreshInterval) as? Double))
    }

    func save(_ settings: DisplaySettings) {
        store.set(settings.rotateDisplay, forKey: Key.rotateDisplay)
        store.set(Self.validBrightness(settings.brightness), forKey: Key.brightness)
        store.set(Self.validInterval(settings.refreshInterval), forKey: Key.refreshInterval)
    }

    /// Out of range means the slider's bounds moved or someone used `defaults
    /// write`; the nearest legal level is closer to intent than the default.
    private static func validBrightness(_ raw: Int?) -> Int {
        guard let raw else { return DisplaySettings.default.brightness }
        return min(brightnessRange.upperBound, max(brightnessRange.lowerBound, raw))
    }

    private static func validInterval(_ raw: Double?) -> Double {
        guard let raw, allowedRefreshIntervals.contains(raw) else {
            return DisplaySettings.default.refreshInterval
        }
        return raw
    }
}
