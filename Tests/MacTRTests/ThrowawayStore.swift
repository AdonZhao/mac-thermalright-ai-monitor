// ThrowawayStore.swift — a defaults suite that tests can dirty freely.

import Foundation

struct ThrowawayStoreUnavailable: Error {}

/// Runs `body` against a private, empty UserDefaults suite and removes it
/// afterwards, so tests never read or clobber the real user settings.
func withThrowawayStore(_ body: (UserDefaults) throws -> Void) throws {
    let name = "com.m1ngli.MacTRAI.tests.\(UUID().uuidString)"
    // Throwing rather than trapping: a suite that won't open should fail the
    // test that needed it, not take the whole run down with it.
    guard let store = UserDefaults(suiteName: name) else {
        throw ThrowawayStoreUnavailable()
    }
    defer { store.removePersistentDomain(forName: name) }
    try body(store)
}
