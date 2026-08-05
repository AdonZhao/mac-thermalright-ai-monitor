// StatusThrottleTests.swift — frame-stat updates go to the main thread at
// most once a second; state transitions always go through immediately.

import Foundation
import Testing

@testable import MacTR

@Test("first status always posts")
func firstStatusPosts() {
    var throttle = StatusThrottle()
    let posted1 = throttle.shouldPost(connected: true, connecting: false,
                                message: "Active", now: 100.0)
    #expect(posted1)
}

@Test("unchanged status inside one second is dropped")
func unchangedStatusInsideOneSecondIsDropped() {
    var throttle = StatusThrottle()
    _ = throttle.shouldPost(connected: true, connecting: false, message: "Active", now: 100.0)

    let posted2 = throttle.shouldPost(connected: true, connecting: false,
                                 message: "Active", now: 100.066)
    #expect(!posted2)
    let posted3 = throttle.shouldPost(connected: true, connecting: false,
                                 message: "Active", now: 100.933)
    #expect(!posted3)
}

@Test("unchanged status posts again after a second — frame stats stay fresh")
func unchangedStatusPostsAfterASecond() {
    var throttle = StatusThrottle()
    _ = throttle.shouldPost(connected: true, connecting: false, message: "Active", now: 100.0)

    let posted4 = throttle.shouldPost(connected: true, connecting: false,
                                message: "Active", now: 101.0)
    #expect(posted4)
}

@Test("a state transition posts immediately even inside the window")
func stateTransitionPostsImmediately() {
    var throttle = StatusThrottle()
    _ = throttle.shouldPost(connected: true, connecting: false, message: "Active", now: 100.0)

    let posted5 = throttle.shouldPost(connected: false, connecting: false,
                                message: "Device not found", now: 100.1)
    #expect(posted5)
    let posted6 = throttle.shouldPost(connected: false, connecting: true,
                                message: "Connecting...", now: 100.2)
    #expect(posted6)
}
