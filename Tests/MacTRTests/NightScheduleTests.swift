// NightScheduleTests.swift — when the LCD is meant to be dark.
//
// Uses covers(minute:) rather than isNight so the assertions don't depend on what
// time the suite happens to run.

import Foundation
import Testing

@testable import MacTR

private func minute(_ hour: Int, _ min: Int = 0) -> Int { hour * 60 + min }

@Test("a window spanning midnight covers the hours either side of it")
func spanningMidnight() {
    // The shipped default: dark from 18:30 until 09:00.
    let s = NightSchedule.default

    #expect(s.covers(minute: minute(19)))       // evening
    #expect(s.covers(minute: minute(23, 59)))   // just before midnight
    #expect(s.covers(minute: minute(0)))        // midnight itself
    #expect(s.covers(minute: minute(8, 59)))    // just before the end

    #expect(!s.covers(minute: minute(9)))       // the end is exclusive
    #expect(!s.covers(minute: minute(12)))      // midday
    #expect(!s.covers(minute: minute(18, 29)))  // one minute early
    #expect(s.covers(minute: minute(18, 30)))   // the start is inclusive
}

@Test("a window inside one day covers only that stretch")
func sameDayWindow() {
    let s = NightSchedule(enabled: true, startMinute: minute(1), endMinute: minute(6))

    #expect(s.covers(minute: minute(1)))
    #expect(s.covers(minute: minute(3)))
    #expect(!s.covers(minute: minute(6)))       // exclusive end
    #expect(!s.covers(minute: minute(0, 59)))
    #expect(!s.covers(minute: minute(20)))
}

@Test("switching it off covers nothing, whatever the times say")
func disabledCoversNothing() {
    var s = NightSchedule.default
    s.enabled = false

    #expect(!s.covers(minute: minute(19)))
    #expect(!s.covers(minute: minute(3)))
}

/// Dragging both ends together reads as "stop blanking", not "blank all day" —
/// the alternative would black the panel out around the clock with no obvious way
/// back other than realising the two times had met.
@Test("a zero-length window covers nothing")
func zeroLengthWindowCoversNothing() {
    let s = NightSchedule(enabled: true, startMinute: minute(9), endMinute: minute(9))

    #expect(!s.covers(minute: minute(9)))
    #expect(!s.covers(minute: minute(21)))
}

// MARK: - Date bridging
//
// The DatePicker conversion is where the awkward cases live, so these cover it
// directly. Every minute of the day round-trips, including the ones a
// spring-forward day does not contain — the pickers must not quietly rewrite a
// stored time just because today skipped it.

@Test("every minute of the day survives the Date round trip")
func everyMinuteRoundTrips() {
    for m in 0..<NightSchedule.minutesPerDay {
        let back = NightSchedule.minuteOfDay(of: NightSchedule.time(atMinute: m))
        #expect(back == m, "minute \(m) came back as \(back)")
    }
}

/// 02:30 does not exist on a spring-forward date. Building the picker's Date from
/// "today" made Calendar skip to the next valid time, so a stored 02:30 displayed
/// as 03:00 and one nudge made that permanent. A fixed reference day avoids it.
@Test("times inside a spring-forward gap still round trip")
func springForwardGapRoundTrips() {
    // America/Los_Angeles jumps 02:00 -> 03:00; Europe/London jumps 01:00 -> 02:00.
    for zoneName in ["America/Los_Angeles", "Europe/London", "Australia/Sydney"] {
        guard let zone = TimeZone(identifier: zoneName) else {
            Issue.record("unknown time zone \(zoneName)"); continue
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        for m in [minute(1), minute(1, 30), minute(2), minute(2, 30), minute(3)] {
            var c = DateComponents()
            c.year = 2001; c.month = 1; c.day = 1
            c.hour = m / 60
            c.minute = m % 60
            guard let date = calendar.date(from: c) else {
                Issue.record("\(zoneName): could not build \(m)"); continue
            }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let back = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            #expect(back == m, "\(zoneName): minute \(m) came back as \(back)")
        }
    }
}
