// NightScheduleTests.swift — when the LCD is meant to be dark.
//
// Uses covers(minute:) rather than isNight so the assertions don't depend on what
// time the suite happens to run.

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
