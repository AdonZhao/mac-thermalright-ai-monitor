// FrameTimingTests.swift — the frame deadline step must not truncate to ms.

import Foundation
import Testing

@testable import MacTR

@Test("15fps step is 66,666,666ns, not a truncated 66ms")
func fifteenFPSStepIsNanosecondPrecise() {
    // Int(1/15 * 1000) = 66ms ran the loop at 15.15fps — ~1% extra frames.
    #expect(DisplayEngine.frameDeadlineStep(1.0 / 15.0) == .nanoseconds(66_666_666))
}

@Test("plain intervals stay exact")
func plainIntervalsStayExact() {
    #expect(DisplayEngine.frameDeadlineStep(0.5) == .nanoseconds(500_000_000))
    #expect(DisplayEngine.frameDeadlineStep(3.0) == .nanoseconds(3_000_000_000))
}
