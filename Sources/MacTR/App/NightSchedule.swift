// NightSchedule.swift — the window in which the LCD is blanked
//
// Lives next to DisplaySettings in spirit: it is one of the persisted settings.
// Kept in its own file because the Date bridging below is the fiddly part and
// deserves to be findable.

import Foundation

// MARK: - Night schedule

/// The window during which the LCD is blanked and the dashboard shows on the Mac
/// instead. A value rather than a global so the engine can be handed the user's
/// current schedule alongside the rest of the settings, and so it is testable
/// without waiting for the clock.
struct NightSchedule: Equatable, Sendable {
    var enabled: Bool
    /// Minutes since midnight, 0..<1440.
    var startMinute: Int
    var endMinute: Int

    static let `default` = NightSchedule(
        enabled: true,
        startMinute: 18 * 60 + 30,   // 18:30
        endMinute: 9 * 60)           // 09:00

    static let minutesPerDay = 24 * 60

    /// Whether `minute` (minutes since midnight) falls inside the window.
    ///
    /// A zero-length window means the user dragged both ends together, which
    /// reads as "stop blanking" rather than "blank around the clock" — so it
    /// behaves the same as switching the feature off.
    func covers(minute m: Int) -> Bool {
        guard enabled, startMinute != endMinute else { return false }
        return startMinute < endMinute
            ? (m >= startMinute && m < endMinute)      // same-day window
            : (m >= startMinute || m < endMinute)      // window spanning midnight
    }

    var isNight: Bool {
        covers(minute: Self.minuteOfDay(of: Date()))
    }

    // MARK: - Bridging to DatePicker
    //
    // DatePicker deals in Date, the schedule in minutes since midnight. These two
    // live here rather than in the view so they can be tested: the awkward cases
    // are all in this conversion, not in covers(minute:).

    /// The wall-clock time this schedule holds at `minute`, as a `Date`.
    ///
    /// Built from a fixed reference day rather than today, because "today" can be
    /// a day that has no 02:30 — on a spring-forward date `date(bySettingHour:)`
    /// skips to the next valid time, which would show a stored 02:30 as 03:00 and
    /// silently rewrite it the moment the user nudged the picker. Only the time of
    /// day is ever read back out, so the day itself is irrelevant.
    func time(atMinuteOf minute: WritableKeyPath<NightSchedule, Int>) -> Date {
        Self.time(atMinute: self[keyPath: minute])
    }

    static func time(atMinute m: Int) -> Date {
        var c = DateComponents()
        c.year = 2001; c.month = 1; c.day = 1   // a day with no DST transition anywhere
        c.hour = m / 60
        c.minute = m % 60
        // Components this explicit resolve on every calendar; the fallback is
        // unreachable in practice and deliberately not "now", which would show the
        // current time as if it were the configured one.
        return Calendar.current.date(from: c) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    static func minuteOfDay(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// For the log: `18:30→09:00`, not the raw minute counts, which had to be
    /// divided by 60 in your head at the exact moment you were debugging something.
    var logDescription: String {
        guard enabled else { return "off" }
        guard startMinute != endMinute else { return "off (both times equal)" }
        func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        return "\(hhmm(startMinute))→\(hhmm(endMinute))"
    }
}
