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
    var night: NightSchedule

    static let `default` = DisplaySettings(
        rotateDisplay: false, brightness: 5, refreshInterval: 0.5,
        night: .default)
}

/// One refresh interval the Settings picker offers.
struct RefreshChoice: Identifiable, Sendable {
    let seconds: Double
    let label: String

    var id: Double { seconds }
}

struct Preferences {

    /// The refresh intervals the picker offers, in the order it shows them.
    ///
    /// The picker builds itself from this list rather than hardcoding the same
    /// values a second time, so a value the user can pick is by construction a
    /// value `load()` accepts. When those two lists were maintained separately,
    /// adding an option here and forgetting the other side would have silently
    /// reset the user's choice at the next launch — the exact bug that made
    /// persistence worth adding in the first place.
    static let refreshIntervalChoices: [RefreshChoice] = [
        RefreshChoice(seconds: 0.5, label: "0.5s (default)"),
        RefreshChoice(seconds: 1.0, label: "1.0s"),
        RefreshChoice(seconds: 2.0, label: "2.0s"),
    ]

    static let brightnessRange = 1...10

    /// `brightnessRange` as the `Double` range a `Slider` wants, so the slider
    /// cannot disagree with what `load()` clamps to.
    static var brightnessBounds: ClosedRange<Double> {
        Double(brightnessRange.lowerBound)...Double(brightnessRange.upperBound)
    }

    /// Internal rather than private so tests can plant values without
    /// duplicating the key strings.
    enum Key {
        static let rotateDisplay = "display.rotate"
        static let brightness = "display.brightness"
        static let refreshInterval = "display.refreshInterval"
        static let nightEnabled = "display.night.enabled"
        static let nightStartMinute = "display.night.startMinute"
        static let nightEndMinute = "display.night.endMinute"
    }

    /// The unprefixed keys used before `Key` gained its `display.` prefix.
    ///
    /// Read as a fallback so upgrading does not silently discard settings the
    /// app only just learned to remember. Nothing writes these any more, so
    /// they fade out on the first save.
    enum LegacyKey {
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
            rotateDisplay: read(Key.rotateDisplay, or: LegacyKey.rotateDisplay) as Bool?
                ?? DisplaySettings.default.rotateDisplay,
            brightness: Self.validBrightness(read(Key.brightness, or: LegacyKey.brightness)),
            refreshInterval: Self.validInterval(
                read(Key.refreshInterval, or: LegacyKey.refreshInterval)),
            night: NightSchedule(
                enabled: store.object(forKey: Key.nightEnabled) as? Bool
                    ?? NightSchedule.default.enabled,
                startMinute: Self.validMinute(
                    store.object(forKey: Key.nightStartMinute) as? Int,
                    default: NightSchedule.default.startMinute),
                endMinute: Self.validMinute(
                    store.object(forKey: Key.nightEndMinute) as? Int,
                    default: NightSchedule.default.endMinute)))
    }

    func save(_ settings: DisplaySettings) {
        store.set(settings.rotateDisplay, forKey: Key.rotateDisplay)
        store.set(Self.validBrightness(settings.brightness), forKey: Key.brightness)
        store.set(Self.validInterval(settings.refreshInterval), forKey: Key.refreshInterval)
        store.set(settings.night.enabled, forKey: Key.nightEnabled)
        store.set(Self.validMinute(settings.night.startMinute,
                                   default: NightSchedule.default.startMinute),
                  forKey: Key.nightStartMinute)
        store.set(Self.validMinute(settings.night.endMinute,
                                   default: NightSchedule.default.endMinute),
                  forKey: Key.nightEndMinute)
    }

    /// Current key first, pre-prefix key second.
    private func read<T>(_ key: String, or legacyKey: String) -> T? {
        store.object(forKey: key) as? T ?? store.object(forKey: legacyKey) as? T
    }

    /// Out of range means the slider's bounds moved or someone used `defaults
    /// write`; the nearest legal level is closer to intent than the default.
    private static func validBrightness(_ raw: Int?) -> Int {
        guard let raw else { return DisplaySettings.default.brightness }
        return min(brightnessRange.upperBound, max(brightnessRange.lowerBound, raw))
    }

    /// A time of day outside the day falls back rather than clamping: 25:00 says
    /// the value was never a time, so there is no nearer one to honour.
    private static func validMinute(_ raw: Int?, default fallback: Int) -> Int {
        guard let raw, (0..<NightSchedule.minutesPerDay).contains(raw) else { return fallback }
        return raw
    }

    /// An interval the picker doesn't offer is treated as corrupt rather than
    /// clamped — there's no sensible nearest value among the choices.
    private static func validInterval(_ raw: Double?) -> Double {
        guard let raw, refreshIntervalChoices.contains(where: { $0.seconds == raw }) else {
            return DisplaySettings.default.refreshInterval
        }
        return raw
    }
}
