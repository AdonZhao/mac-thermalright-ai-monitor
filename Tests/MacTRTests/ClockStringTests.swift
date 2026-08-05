// ClockStringTests.swift — the clock string is cached per whole second, so
// 15fps frames stop re-creating DateFormatters for an unchanged "HH:mm:ss".

import Foundation
import Testing

@testable import MacTR

@Test("clock string formats HH:mm:ss, stays stable within a second, changes across")
func clockStringCachesPerSecond() {
    let renderer = MonitorRenderer()
    let t = 1_700_000_000.5

    let expected: String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t))
    }()

    #expect(renderer.clockString(t: t) == expected)
    #expect(renderer.clockString(t: t + 0.4) == expected)
    #expect(renderer.clockString(t: t + 1.0) != expected)
}
